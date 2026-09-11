package com.example.decode_example

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.Camera
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Size
import android.view.Surface
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Camera capture that mirrors the OFFICIAL Android decoder (cfc's
 * `OpencvCameraView`) as closely as possible — copied from
 * `third_party/cfc/app/src/main/java/org/cimbar/camerafilecopy/`:
 *
 *  - `bestCameraFrameSize()` (copied verbatim): only frames whose SHORT
 *    side is in [960, 1080] qualify, and the one with the smallest width
 *    wins. On this device that is 1440x1080 — the sensor's native 4:3
 *    with the FULL vertical field of view, exactly the frame the official
 *    app decodes. No 16:9 crop anywhere.
 *  - NV21 preview format + CONTINUOUS_VIDEO focus + setRecordingHint(true)
 *    + double-buffered `setPreviewCallbackWithBuffer` (copied from cfc's
 *    initializeCamera).
 *  - Preview is rendered onto a FLUTTER texture (SurfaceTexture from the
 *    TextureRegistry), the equivalent of cfc drawing its camera Mat into
 *    its own view — Dart letterboxes/rotates it with its own widgets.
 *
 * EVERY camera frame is shipped to Dart over the frames EventChannel as a
 * raw NV21 byte array — no throttle, exactly like cfc handing every
 * preview frame to its decoder thread. The "busy → drop" rule lives on
 * the Dart side (CfcCameraCapture): while a decode runs, newer frames
 * overwrite the pending slot and older ones are dropped — the same
 * newest-wins rule as cfc's double-buffered mFrameChain.
 *
 * NOTE: `setDisplayOrientation` is deliberately NOT called. For
 * SurfaceTextures it only encodes a transform matrix that the Flutter
 * engine does not apply; instead Dart rotates the texture with RotatedBox
 * based on the `rotation` value returned from open().
 *
 * NOTE: this handler BYPASSES the camera plugin, so it must request the
 * CAMERA runtime permission itself (the plugin used to do it).
 */
class CfcCameraHandler(
    private val activity: android.app.Activity,
    private val messenger: BinaryMessenger,
    private val textureRegistry: TextureRegistry,
) {
    companion object {
        const val CHANNEL = "libcimbar/cfc_camera"
        const val FRAME_CHANNEL = "libcimbar/cfc_camera/frames"

        private const val TAG = "CfcCamera"

        private const val PERMISSION_REQUEST_CODE = 9001
    }

    private var camera: Camera? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var frameSink: EventChannel.EventSink? = null
    private var frameWidth = 0
    private var frameHeight = 0
    private var frameRotation = 0
    private var pendingOpenResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun configure() {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> mainHandler.post { open(result) }
                "close" -> mainHandler.post { close(result) }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, FRAME_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    frameSink = events
                }

                override fun onCancel(arguments: Any?) {
                    frameSink = null
                }
            })
    }

    /// Called by the Activity when a permission request completes.
    fun onPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST_CODE) return
        val result = pendingOpenResult
        pendingOpenResult = null
        if (result == null) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (granted) {
            Log.i(TAG, "CAMERA permission granted — opening camera")
            doOpen(result)
        } else {
            Log.e(TAG, "CAMERA permission denied")
            result.error("permission", "CAMERA 权限被拒绝", null)
        }
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun open(result: MethodChannel.Result) {
        if (camera != null) {
            Log.i(TAG, "open: already open")
            result.success(currentState())
            return
        }
        if (!hasCameraPermission()) {
            // This handler bypasses the camera plugin, so IT must request
            // the runtime permission (the plugin used to do it).
            Log.i(TAG, "open: requesting CAMERA permission")
            pendingOpenResult = result
            activity.requestPermissions(
                arrayOf(Manifest.permission.CAMERA), PERMISSION_REQUEST_CODE)
            return
        }
        Log.i(TAG, "open: permission already granted")
        doOpen(result)
    }

    /// cfc's initializeCamera core path, on Camera1 (android.hardware.Camera).
    @SuppressLint("DiscouragedPrivateApi")
    private fun doOpen(result: MethodChannel.Result) {
        if (camera != null) {
            result.success(currentState())
            return
        }
        try {
            // cfc: pick the back camera.
            var cameraId = -1
            val info = Camera.CameraInfo()
            for (i in 0 until Camera.getNumberOfCameras()) {
                Camera.getCameraInfo(i, info)
                if (info.facing == Camera.CameraInfo.CAMERA_FACING_BACK) {
                    cameraId = i
                    break
                }
            }
            if (cameraId < 0) {
                result.error("no-camera", "No back camera found", null)
                return
            }
            val cam = Camera.open(cameraId)
            Camera.getCameraInfo(cameraId, info)
            // OpenCV CameraBridgeViewBase.getFrameRotation: sensor
            // orientation vs screen rotation.
            val wm = activity.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val screenRotation = when (wm.defaultDisplay.rotation) {
                Surface.ROTATION_90 -> 90
                Surface.ROTATION_180 -> 180
                Surface.ROTATION_270 -> 270
                else -> 0
            }
            frameRotation = if (info.facing == Camera.CameraInfo.CAMERA_FACING_FRONT) {
                (info.orientation + screenRotation) % 360
            } else {
                (info.orientation - screenRotation + 360) % 360
            }
            Log.i(TAG, "open: camera $cameraId, frameRotation=$frameRotation")

            val params = cam.parameters
            // cfc bestCameraFrameSize: short side 960..1080, smallest width.
            // cfc is LANDSCAPE-LOCKED, so its surface bounds are always
            // (longSide x shortSide) and the size pick never depends on the
            // transient orientation. Feed the same long/short pair here:
            // with portrait bounds (e.g. 1080x2340) the primary loop would
            // REJECT 1440x1080 (width 1440 > 1080) and fall back to OpenCV's
            // "largest that fits" (~1 Mpx) — an upscaled, blurry preview and
            // a lower-resolution decode input than the official app.
            val dm = activity.resources.displayMetrics
            val surfaceW = maxOf(dm.widthPixels, dm.heightPixels)
            val surfaceH = minOf(dm.widthPixels, dm.heightPixels)
            val frameSize = bestCameraFrameSize(
                params.supportedPreviewSizes, surfaceW, surfaceH,
            ) ?: run {
                cam.release()
                Log.e(TAG, "open: no suitable preview size")
                result.error("no-size", "No suitable preview size", null)
                return
            }
            Log.i(TAG, "open: preview ${frameSize.width}x${frameSize.height}")

            params.previewFormat = ImageFormat.NV21
            params.setPreviewSize(frameSize.width, frameSize.height)
            if (params.supportedFocusModes.contains(
                    Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO)) {
                params.focusMode = Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO
            }
            // cfc (OpenCV's JavaCameraView): setRecordingHint(true) on
            // ICS+, except the GT-I9100 quirk. Hints the HAL that this
            // session is video-class.
            if (android.os.Build.VERSION.SDK_INT >= 14 &&
                android.os.Build.MODEL != "GT-I9100") {
                params.setRecordingHint(true)
            }
            cam.parameters = params

            // cfc re-reads the applied size from the HAL (it may clamp the
            // request) — report what is really streaming.
            frameWidth = cam.parameters.previewSize.width
            frameHeight = cam.parameters.previewSize.height

            // Preview on a FLUTTER texture (cfc draws its camera Mat into
            // its own view; we hand the SurfaceTexture to Flutter).
            val entry = textureRegistry.createSurfaceTexture()
            // Size the consumer buffers to the actual preview — the
            // SurfaceTexture default is 1x1 and producers are not obliged to
            // honor our size unless told (the Flutter camera plugin does the
            // same right after setPreviewTexture).
            entry.surfaceTexture().setDefaultBufferSize(frameWidth, frameHeight)
            cam.setPreviewTexture(entry.surfaceTexture())
            cam.startPreview()
            Log.i(TAG, "open: preview started, textureId=${entry.id()}")

            // NV21 frames, double-buffered (cfc: mBuffer + addCallbackBuffer).
            val bufSize = frameWidth * frameHeight *
                ImageFormat.getBitsPerPixel(ImageFormat.NV21) / 8
            cam.addCallbackBuffer(ByteArray(bufSize))
            cam.setPreviewCallbackWithBuffer { data, c ->
                pushFrame(data)
                c.addCallbackBuffer(data)
            }

            camera = cam
            textureEntry = entry
            result.success(currentState())
        } catch (e: Exception) {
            camera?.release()
            camera = null
            Log.e(TAG, "open failed", e)
            result.error("camera-error", e.message, null)
        }
    }

    private fun close(result: MethodChannel.Result) {
        Log.i(TAG, "close")
        camera?.let { cam ->
            cam.setPreviewCallbackWithBuffer(null)
            cam.stopPreview()
            cam.release()
        }
        camera = null
        textureEntry?.release()
        textureEntry = null
        frameWidth = 0
        frameHeight = 0
        result.success(null)
    }

    private fun currentState(): Map<String, Any> = mapOf(
        "textureId" to (textureEntry?.id() ?: -1L),
        "width" to frameWidth,
        "height" to frameHeight,
        "rotation" to frameRotation,
    )

    /// Ship the NV21 frame — EVERY camera frame, no throttle: cfc hands
    /// every preview frame to its decoder. The "busy → drop" behaviour
    /// lives on the Dart side (CfcCameraCapture's newest-wins slot), the
    /// equivalent of cfc's CameraWorker only ever taking the latest
    /// mFrameChain entry.
    private fun pushFrame(data: ByteArray) {
        frameSink?.success(data)
    }

    /// COPIED from cfc's OpencvCameraView.bestCameraFrameSize: keep only
    /// sizes whose short side is 960..1080, pick the smallest width that
    /// fits the surface; fall back to OpenCV's largest-that-fits.
    private fun bestCameraFrameSize(
        supportedSizes: List<Camera.Size>,
        surfaceWidth: Int,
        surfaceHeight: Int,
    ): Size? {
        var calcWidth = 10000000
        var calcHeight = 10000000
        for (size in supportedSizes) {
            val width = size.width
            val height = size.height
            val minDim = minOf(width, height)
            if (minDim < 960 || minDim > 1080) continue
            if (width <= surfaceWidth && height <= surfaceHeight) {
                if (width < calcWidth && height <= calcHeight) {
                    calcWidth = width
                    calcHeight = height
                }
            }
        }
        if (calcWidth < 10000000 && calcHeight < 10000000) {
            return Size(calcWidth, calcHeight)
        }
        // OpenCV CameraBridgeViewBase.calculateCameraFrameSize: the largest
        // size that fits the surface bounds.
        var bestW = 0
        var bestH = 0
        for (size in supportedSizes) {
            val width = size.width
            val height = size.height
            if (width <= surfaceWidth && height <= surfaceHeight) {
                if (width >= bestW && height >= bestH) {
                    bestW = width
                    bestH = height
                }
            }
        }
        if (bestW > 0) return Size(bestW, bestH)
        return null
    }
}

package com.example.decode_example

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.Camera
import android.os.Handler
import android.os.Looper
import android.util.Size
import android.view.Surface
import android.view.WindowManager
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
 *  - NV21 preview format + CONTINUOUS_VIDEO focus + double-buffered
 *    `setPreviewCallbackWithBuffer` (copied from cfc's initializeCamera).
 *  - Preview is rendered onto a FLUTTER texture (SurfaceTexture from the
 *    TextureRegistry), the equivalent of cfc drawing its camera Mat into
 *    its own view — Dart letterboxes/rotates it with its own widgets.
 *
 * Frames are throttled to the official 15 fps cadence and shipped to Dart
 * over the frames EventChannel as raw NV21 byte arrays (sensor direction —
 * Dart rotates for display and decodes orientation-independently).
 *
 * NOTE: `setDisplayOrientation` is deliberately NOT called. For
 * SurfaceTextures it only encodes a transform matrix that the Flutter
 * engine does not apply; instead Dart rotates the texture with RotatedBox
 * based on the `rotation` value returned from open().
 */
class CfcCameraHandler(
    private val context: Context,
    private val messenger: BinaryMessenger,
    private val textureRegistry: TextureRegistry,
) {
    companion object {
        const val CHANNEL = "libcimbar/cfc_camera"
        const val FRAME_CHANNEL = "libcimbar/cfc_camera/frames"

        /// Official cadence (recv.js frameRate ideal:15 / cfc every frame).
        private const val FRAME_INTERVAL_MS = 66L
    }

    private var camera: Camera? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var frameSink: EventChannel.EventSink? = null
    private var frameWidth = 0
    private var frameHeight = 0
    private var frameRotation = 0
    private var lastFrameAt = 0L
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

    /// cfc's initializeCamera core path, on Camera1 (android.hardware.Camera).
    @SuppressLint("DiscouragedPrivateApi")
    private fun open(result: MethodChannel.Result) {
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
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
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

            val params = cam.parameters
            // cfc bestCameraFrameSize: short side 960..1080, smallest width.
            // Surface bounds = the display in its CURRENT orientation, like
            // cfc's view bounds.
            val dm = context.resources.displayMetrics
            val frameSize = bestCameraFrameSize(
                params.supportedPreviewSizes, dm.widthPixels, dm.heightPixels,
            ) ?: run {
                cam.release()
                result.error("no-size", "No suitable preview size", null)
                return
            }

            params.previewFormat = ImageFormat.NV21
            params.setPreviewSize(frameSize.width, frameSize.height)
            if (params.supportedFocusModes.contains(
                    Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO)) {
                params.focusMode = Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO
            }
            cam.parameters = params

            frameWidth = frameSize.width
            frameHeight = frameSize.height

            // Preview on a FLUTTER texture (cfc draws its camera Mat into
            // its own view; we hand the SurfaceTexture to Flutter).
            val entry = textureRegistry.createSurfaceTexture()
            cam.setPreviewTexture(entry.surfaceTexture())
            cam.startPreview()

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
            result.error("camera-error", e.message, null)
        }
    }

    private fun close(result: MethodChannel.Result) {
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

    /// Throttle to the official cadence, then ship the NV21 frame.
    private fun pushFrame(data: ByteArray) {
        val now = System.currentTimeMillis()
        if (now - lastFrameAt < FRAME_INTERVAL_MS) return
        lastFrameAt = now
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

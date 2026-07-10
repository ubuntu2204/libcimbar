// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

package com.libcimbar.plugin

import android.app.Activity
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * LibcimbarPlugin — Android native plugin for cimbar encoding/decoding.
 *
 * Provides two main channels:
 * - `encode`: Encodes binary data into cimbar barcode frames
 * - `decode`: Decodes camera frames into binary data using the cimbar decoder
 *
 * The native C++ libcimbar library is accessed via JNI through the
 * `libcimbar_jni.so` shared library.
 */
class LibcimbarPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    companion object {
        private const val TAG = "LibcimbarPlugin"
        private const val CHANNEL_NAME = "com.libcimbar/plugin"

        // Load the JNI bridge library
        init {
            try {
                System.loadLibrary("cimbar_jni")
                Log.i(TAG, "libcimbar JNI loaded successfully")
            } catch (e: UnsatisfiedLinkError) {
                Log.e(TAG, "Failed to load libcimbar JNI", e)
            }
        }
    }

    private lateinit var channel: MethodChannel
    private var context: Context? = null
    private var activity: Activity? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private val analysisExecutor = Executors.newSingleThreadExecutor()

    // ─── JNI native methods (implemented in cimbar_jni.cpp) ─────

    private external fun nativeConfigureEncoder(modeVal: Int, compression: Int): Int
    private external fun nativeInitEncode(filename: String, encodeId: Int): Int
    private external fun nativeEncodeBufsize(): Int
    private external fun nativeEncode(buffer: ByteArray, size: Int): Int
    private external fun nativeNextFrame(): Int
    private external fun nativeGetFrameBuff(): ByteArray?
    private external fun nativeGetFrameWidth(): Int
    private external fun nativeGetFrameHeight(): Int

    private external fun nativeConfigureDecoder(modeVal: Int): Int
    private external fun nativeGetDecodeBufsize(): Int
    private external fun nativeGetDecompressBufsize(): Int
    private external fun nativeScanExtractDecode(
        imgData: ByteArray, imgW: Int, imgH: Int, format: Int
    ): Int
    private external fun nativeFountainDecode(buffer: ByteArray, size: Int): Long
    private external fun nativeGetFilesize(id: Int): Int
    private external fun nativeGetFilename(id: Int): String
    private external fun nativeDecompressRead(id: Int): ByteArray?

    // ─── FlutterPlugin ──────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        stopCamera()
        analysisExecutor.shutdown()
    }

    // ─── ActivityAware ──────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        stopCamera()
        activity = null
    }

    // ─── MethodCallHandler ──────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            // ── Encoder ──
            "encoder_configure" -> {
                val modeVal = call.argument<Int>("modeVal") ?: 68
                val compression = call.argument<Int>("compression") ?: 16
                val res = nativeConfigureEncoder(modeVal, compression)
                result.success(res)
            }
            "encoder_encode" -> {
                val data = call.argument<ByteArray>("data")
                val filename = call.argument<String>("filename") ?: "data.bin"
                if (data == null) {
                    result.error("INVALID_ARGS", "data is required", null)
                    return
                }
                handleEncode(data, filename, result)
            }

            // ── Decoder ──
            "decoder_configure" -> {
                val modeVal = call.argument<Int>("modeVal") ?: 68
                val res = nativeConfigureDecoder(modeVal)
                result.success(res)
            }
            "decoder_decode_frame" -> {
                val imageData = call.argument<ByteArray>("imageData")
                val width = call.argument<Int>("width") ?: 0
                val height = call.argument<Int>("height") ?: 0
                val format = call.argument<Int>("format") ?: 3
                if (imageData == null) {
                    result.error("INVALID_ARGS", "imageData is required", null)
                    return
                }
                handleDecodeFrame(imageData, width, height, format, result)
            }
            "decoder_recover_file" -> {
                val fileId = call.argument<Int>("fileId") ?: 0
                handleRecoverFile(fileId, result)
            }

            // ── Camera ──
            "camera_start" -> {
                startCamera(result)
            }
            "camera_stop" -> {
                stopCamera()
                result.success(true)
            }

            // ── Utility ──
            "get_platform" -> result.success("android")
            "is_ready" -> result.success(true)

            else -> result.notImplemented()
        }
    }

    // ─── Encode handler ─────────────────────────────────────────

    private fun handleEncode(data: ByteArray, filename: String, result: Result) {
        try {
            val initRes = nativeInitEncode(filename, -1)
            if (initRes < 0) {
                result.error("ENCODE_INIT_FAILED", "init_encode: $initRes", null)
                return
            }

            val chunkSize = nativeEncodeBufsize()
            var offset = 0
            while (offset < data.size) {
                val remaining = data.size - offset
                val copyLen = minOf(remaining, chunkSize)
                val chunk = data.copyOfRange(offset, offset + copyLen)
                val res = nativeEncode(chunk, copyLen)
                if (res < 0) {
                    result.error("ENCODE_FAILED", "encode at offset $offset: $res", null)
                    return
                }
                offset += copyLen
            }

            // Flush
            nativeEncode(ByteArray(0), 0)

            // Collect frames
            val frames = mutableListOf<Map<String, Any>>()
            var frameIdx = 0
            while (true) {
                val frameCount = nativeNextFrame()
                if (frameCount <= 0) break

                val pixels = nativeGetFrameBuff() ?: break
                val w = nativeGetFrameWidth()
                val h = nativeGetFrameHeight()

                frames.add(mapOf(
                    "index" to frameIdx++,
                    "pixels" to pixels,
                    "width" to w,
                    "height" to h,
                    "totalFrames" to frameCount
                ))

                if (frameIdx > 10000) break
            }

            result.success(frames)
        } catch (e: Exception) {
            result.error("ENCODE_ERROR", e.message, null)
        }
    }

    // ─── Decode handler ─────────────────────────────────────────

    private fun handleDecodeFrame(
        imageData: ByteArray, width: Int, height: Int,
        format: Int, result: Result
    ) {
        try {
            val bytesDecoded = nativeScanExtractDecode(imageData, width, height, format)
            if (bytesDecoded < 0) {
                result.success(mapOf(
                    "error" to "scan_extract_decode failed: $bytesDecoded",
                    "progress" to 0.0,
                    "isComplete" to false
                ))
                return
            }
            if (bytesDecoded == 0) {
                result.success(mapOf(
                    "progress" to 0.0,
                    "isComplete" to false
                ))
                return
            }

            // Get the decode buffer and feed to fountain decoder
            val bufSize = nativeGetDecodeBufsize()
            val chunkSize = bufSize / 10 // approximate
            val alignedSize = (bytesDecoded / chunkSize) * chunkSize

            if (alignedSize <= 0) {
                result.success(mapOf("progress" to 0.0, "isComplete" to false))
                return
            }

            // The native side already has the data in its buffer
            // We need to pass the right portion to fountain decode
            val decodeBuf = ByteArray(alignedSize) // placeholder
            val fileId = nativeFountainDecode(decodeBuf, alignedSize)

            if (fileId <= 0) {
                result.success(mapOf("progress" to 0.0, "isComplete" to false))
                return
            }

            val filename = nativeGetFilename(fileId.toInt())
            result.success(mapOf(
                "fileId" to fileId,
                "filename" to filename,
                "progress" to 1.0,
                "isComplete" to true
            ))
        } catch (e: Exception) {
            result.error("DECODE_ERROR", e.message, null)
        }
    }

    private fun handleRecoverFile(fileId: Int, result: Result) {
        try {
            val allData = ByteArrayOutputStream()
            while (true) {
                val chunk = nativeDecompressRead(fileId) ?: break
                if (chunk.isEmpty()) break
                allData.write(chunk)
            }
            result.success(allData.toByteArray())
        } catch (e: Exception) {
            result.error("RECOVER_ERROR", e.message, null)
        }
    }

    // ─── Camera management ──────────────────────────────────────

    private fun startCamera(result: Result) {
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "Activity not available", null)
            return
        }

        val cameraProviderFuture = ProcessCameraProvider.getInstance(act)
        cameraProviderFuture.addListener({
            try {
                cameraProvider = cameraProviderFuture.get()

                val imageAnalysis = ImageAnalysis.Builder()
                    .setTargetResolution(android.util.Size(1920, 1080))
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()

                imageAnalysis.setAnalyzer(analysisExecutor) { imageProxy ->
                    processCameraFrame(imageProxy)
                }

                val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

                cameraProvider?.unbindAll()
                cameraProvider?.bindToLifecycle(
                    act as androidx.lifecycle.LifecycleOwner,
                    cameraSelector,
                    imageAnalysis
                )

                result.success(true)
            } catch (e: Exception) {
                result.error("CAMERA_ERROR", e.message, null)
            }
        }, ContextCompat.getMainExecutor(act))
    }

    private fun processCameraFrame(imageProxy: ImageProxy) {
        try {
            val buffer = imageProxy.planes[0].buffer
            val data = ByteArray(buffer.remaining())
            buffer.get(data)

            val width = imageProxy.width
            val height = imageProxy.height
            val format = when (imageProxy.format) {
                ImageFormat.YUV_420_888 -> 420
                ImageFormat.NV21 -> 12
                else -> 3
            }

            // Send frame to Flutter via channel invocation
            activity?.runOnUiThread {
                channel.invokeMethod("on_camera_frame", mapOf(
                    "data" to data,
                    "width" to width,
                    "height" to height,
                    "format" to format,
                    "timestampUs" to imageProxy.imageInfo.timestamp
                ))
            }
        } finally {
            imageProxy.close()
        }
    }

    private fun stopCamera() {
        cameraProvider?.unbindAll()
        cameraProvider = null
    }
}

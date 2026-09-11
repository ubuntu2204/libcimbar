package com.example.decode_example

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var cfcCamera: CfcCameraHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // OFFICIAL-style camera capture (cfc): Camera1 + bestCameraFrameSize
        // + NV21 frames + Flutter-texture preview. See CfcCameraHandler.kt.
        cfcCamera = CfcCameraHandler(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
            flutterEngine.renderer,
        ).also { it.configure() }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        cfcCamera?.onPermissionsResult(requestCode, grantResults)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        cfcCamera = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

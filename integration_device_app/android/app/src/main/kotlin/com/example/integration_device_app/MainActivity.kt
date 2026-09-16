package com.example.integration_device_app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val channelName = "lpc_integration_device_app/permissions"
    private val requestCode = 4101
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                if (call.method != "requestBluetoothPermissions") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                requestBluetoothPermissions(result)
            }
    }

    private fun requestBluetoothPermissions(result: MethodChannel.Result) {
        val required = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        val missing = required.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        if (pendingResult != null) {
            result.error("PERMISSION_REQUEST_ACTIVE", "permission request already active", null)
            return
        }
        pendingResult = result
        requestPermissions(missing.toTypedArray(), requestCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != this.requestCode) return
        val result = pendingResult ?: return
        pendingResult = null
        result.success(grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED })
    }
}

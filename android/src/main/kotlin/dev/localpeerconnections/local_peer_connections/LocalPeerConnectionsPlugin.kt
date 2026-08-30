package dev.localpeerconnections.local_peer_connections

import io.flutter.embedding.engine.plugins.FlutterPlugin

/** Registration shell. BLE platform events are translated into the portable
 * backend contract; protocol logic remains in Dart and never depends on GATT. */
class LocalPeerConnectionsPlugin : FlutterPlugin {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) = Unit
}

package dev.localpeerconnections.local_peer_connections

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.security.KeyStore
import java.security.SecureRandom
import java.nio.ByteBuffer
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Registration shell. BLE platform events are translated into the portable
 * backend contract; protocol logic remains in Dart and never depends on GATT. */
class LocalPeerConnectionsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
  private lateinit var applicationContext: Context
  private lateinit var identityChannel: MethodChannel
  private lateinit var backendChannel: MethodChannel
  private lateinit var backendEvents: EventChannel
  private var eventSink: EventChannel.EventSink? = null
  private var advertiserCallback: AdvertiseCallback? = null
  private var scanCallback: ScanCallback? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    applicationContext = binding.applicationContext
    identityChannel = MethodChannel(binding.binaryMessenger, IDENTITY_CHANNEL)
    identityChannel.setMethodCallHandler(this)
    backendChannel = MethodChannel(binding.binaryMessenger, BACKEND_CHANNEL)
    backendChannel.setMethodCallHandler(this)
    backendEvents = EventChannel(binding.binaryMessenger, BACKEND_EVENTS_CHANNEL)
    backendEvents.setStreamHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    stopAdvertising()
    stopDiscovery()
    identityChannel.setMethodCallHandler(null)
    backendChannel.setMethodCallHandler(null)
    backendEvents.setStreamHandler(null)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "loadOrCreateEd25519Seed" -> try {
        result.success(loadOrCreateSeed())
      } catch (error: Exception) {
        // Corruption or keystore invalidation must surface to the caller; never
        // silently rotate an established protocol identity.
        result.error("IDENTITY_STORAGE", "Unable to access protected identity", null)
      }
      "queryCapabilities" -> runBackendValue(result) { queryCapabilities() }
      "startAdvertising" -> runBackend(result) { startAdvertising(serviceUuid(call), call.argument<String>("localName")) }
      "stopAdvertising" -> runBackend(result) { stopAdvertising() }
      "startDiscovery" -> runBackend(result) { startDiscovery(serviceUuid(call)) }
      "stopDiscovery" -> runBackend(result) { stopDiscovery() }
      else -> result.notImplemented()
    }
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { eventSink = events }
  override fun onCancel(arguments: Any?) { eventSink = null }

  private fun queryCapabilities(): List<String> {
    val adapter = adapterOrNull() ?: return emptyList()
    return buildList {
      if (adapter.bluetoothLeScanner != null) add("bleScan")
      if (adapter.bluetoothLeAdvertiser != null) add("bleAdvertise")
    }
  }

  private fun startAdvertising(serviceUuid: ParcelUuid, localName: String?) {
    if (localName != null) {
      // Android's BLE APIs expose only the adapter-global device name, which a
      // library must not mutate. Do not silently advertise a different name.
      throw BackendError("UNSUPPORTED_CAPABILITY", "custom BLE local name is unavailable on Android")
    }
    val advertiser = adapterOrThrow().bluetoothLeAdvertiser ?: throw BackendError("ADVERTISING_UNAVAILABLE")
    stopAdvertising()
    val data = AdvertiseData.Builder().addServiceUuid(serviceUuid).build()
    val settings = AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
      .setConnectable(true).setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM).build()
    advertiserCallback = object : AdvertiseCallback() {
      override fun onStartFailure(errorCode: Int) {
        eventSink?.error("ADVERTISING_UNAVAILABLE", "Android advertise error $errorCode", errorCode)
      }
    }
    advertiser.startAdvertising(settings, data, advertiserCallback)
  }

  private fun stopAdvertising() {
    advertiserCallback?.let { callback -> adapterOrNull()?.bluetoothLeAdvertiser?.stopAdvertising(callback) }
    advertiserCallback = null
  }

  private fun startDiscovery(serviceUuid: ParcelUuid) {
    val scanner = adapterOrThrow().bluetoothLeScanner ?: throw BackendError("DISCOVERY_UNAVAILABLE")
    stopDiscovery()
    val filters = listOf(ScanFilter.Builder().setServiceUuid(serviceUuid).build())
    val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
    scanCallback = object : ScanCallback() {
      override fun onScanResult(callbackType: Int, result: ScanResult) {
        eventSink?.success(mapOf("type" to "endpointFound", "endpointId" to result.device.address,
          "localName" to result.scanRecord?.deviceName, "rssi" to result.rssi))
      }
      override fun onScanFailed(errorCode: Int) {
        eventSink?.error("DISCOVERY_UNAVAILABLE", "Android scan error $errorCode", errorCode)
      }
    }
    scanner.startScan(filters, settings, scanCallback)
  }

  private fun stopDiscovery() {
    scanCallback?.let { callback -> adapterOrNull()?.bluetoothLeScanner?.stopScan(callback) }
    scanCallback = null
  }

  private fun serviceUuid(call: MethodCall): ParcelUuid {
    val bytes = call.argument<ByteArray>("serviceUuid") ?: throw BackendError("UNSUPPORTED_CAPABILITY")
    require(bytes.size == 16) { "serviceUuid must be 16 bytes" }
    val buffer = ByteBuffer.wrap(bytes)
    return ParcelUuid(UUID(buffer.long, buffer.long))
  }

  private fun adapterOrNull(): BluetoothAdapter? =
    (applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?)?.adapter
  private fun adapterOrThrow(): BluetoothAdapter {
    val adapter = adapterOrNull() ?: throw BackendError("BLUETOOTH_UNAVAILABLE")
    if (!adapter.isEnabled) throw BackendError("BLUETOOTH_POWERED_OFF")
    return adapter
  }

  private fun runBackend(result: MethodChannel.Result, block: () -> Unit) {
    try { block(); result.success(null) }
    catch (error: SecurityException) { result.error("PERMISSION_DENIED", error.message, null) }
    catch (error: BackendError) { result.error(error.code, error.message, null) }
    catch (error: Exception) { result.error("PLATFORM_ERROR", error.message, null) }
  }

  private fun runBackendValue(result: MethodChannel.Result, block: () -> Any?) {
    try { result.success(block()) }
    catch (error: SecurityException) { result.error("PERMISSION_DENIED", error.message, null) }
    catch (error: BackendError) { result.error(error.code, error.message, null) }
    catch (error: Exception) { result.error("PLATFORM_ERROR", error.message, null) }
  }

  private class BackendError(val code: String, override val message: String = code) : Exception(message)

  private fun loadOrCreateSeed(): ByteArray {
    val preferences = applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    val encoded = preferences.getString(SEED_ENTRY, null)
    if (encoded != null) {
      val packed = Base64.decode(encoded, Base64.NO_WRAP)
      require(packed.size > GCM_IV_BYTES) { "invalid encrypted identity" }
      val cipher = Cipher.getInstance("AES/GCM/NoPadding")
      cipher.init(Cipher.DECRYPT_MODE, storageKey(), GCMParameterSpec(GCM_TAG_BITS, packed, 0, GCM_IV_BYTES))
      val seed = cipher.doFinal(packed, GCM_IV_BYTES, packed.size - GCM_IV_BYTES)
      require(seed.size == SEED_BYTES) { "invalid identity seed length" }
      return seed
    }
    val seed = ByteArray(SEED_BYTES)
    SecureRandom().nextBytes(seed)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.ENCRYPT_MODE, storageKey())
    val packed = cipher.iv + cipher.doFinal(seed)
    check(preferences.edit().putString(SEED_ENTRY, Base64.encodeToString(packed, Base64.NO_WRAP)).commit()) {
      "failed to persist encrypted identity"
    }
    return seed
  }

  private fun storageKey(): SecretKey {
    val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
    val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
    generator.init(KeyGenParameterSpec.Builder(
      KEY_ALIAS,
      KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
    ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
      .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
      .setKeySize(256)
      .build())
    return generator.generateKey()
  }

  private companion object {
    const val IDENTITY_CHANNEL = "dev.localpeerconnections.local_peer_connections/identity"
    const val BACKEND_CHANNEL = "dev.localpeerconnections.local_peer_connections/backend"
    const val BACKEND_EVENTS_CHANNEL = "dev.localpeerconnections.local_peer_connections/backend_events"
    const val PREFERENCES = "local_peer_connections.identity"
    const val SEED_ENTRY = "ed25519_seed_v1"
    const val KEY_ALIAS = "local_peer_connections.ed25519_seed.v1"
    const val SEED_BYTES = 32
    const val GCM_IV_BYTES = 12
    const val GCM_TAG_BITS = 128
  }
}

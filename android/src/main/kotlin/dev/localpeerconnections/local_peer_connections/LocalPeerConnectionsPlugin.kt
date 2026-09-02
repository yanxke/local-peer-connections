package dev.localpeerconnections.local_peer_connections

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothProfile
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
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
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
  private val logTag = "LocalPeerConnections"
  private lateinit var applicationContext: Context
  private lateinit var identityChannel: MethodChannel
  private lateinit var backendChannel: MethodChannel
  private lateinit var backendEvents: EventChannel
  private var eventSink: EventChannel.EventSink? = null
  private var advertiserCallback: AdvertiseCallback? = null
  private var scanCallback: ScanCallback? = null
  private var gattServer: BluetoothGattServer? = null
  private val gattClients = mutableMapOf<String, GattClient>()
  private val gattServerPeers = mutableMapOf<String, BluetoothDevice>()
  private var activeServiceUuid: ParcelUuid? = null
  private val lastScanLogMs = mutableMapOf<String, Long>()

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
    stopGatt()
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
      "listenGatt" -> runBackend(result) { listenGatt(serviceUuid(call)) }
      "stopGatt" -> runBackend(result) { stopGatt() }
      "connectGatt" -> runBackend(result) { connectGatt(call.argument<String>("endpointId") ?: throw BackendError("ENDPOINT_LOST")) }
      "submitGattFragment" -> runBackendValue(result) { submitGattFragment(call) }
      "closeGattConnection" -> runBackend(result) { closeGattConnection(call.argument<String>("endpointId") ?: throw BackendError("ENDPOINT_LOST")) }
      else -> result.notImplemented()
    }
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { Log.d(logTag, "backend event stream listening"); eventSink = events }
  override fun onCancel(arguments: Any?) { Log.d(logTag, "backend event stream cancelled"); eventSink = null }

  private fun queryCapabilities(): List<String> {
    val adapter = adapterOrNull() ?: return emptyList()
    return buildList {
      if (adapter.bluetoothLeScanner != null) add("bleScan")
      if (adapter.bluetoothLeAdvertiser != null) add("bleAdvertise")
      if (adapter.bluetoothLeScanner != null) add("gattCentral")
      if (adapter.bluetoothLeAdvertiser != null) add("gattPeripheral")
    }
  }

  private fun startAdvertising(serviceUuid: ParcelUuid, localName: String?) {
    Log.d(logTag, "startAdvertising uuid=$serviceUuid")
    if (localName != null) {
      // Android's BLE APIs expose only the adapter-global device name, which a
      // library must not mutate. Do not silently advertise a different name.
      throw BackendError("UNSUPPORTED_CAPABILITY", "custom BLE local name is unavailable on Android")
    }
    val advertiser = adapterOrThrow().bluetoothLeAdvertiser ?: throw BackendError("ADVERTISING_UNAVAILABLE")
    stopAdvertising()
    val data = AdvertiseData.Builder()
      .addServiceUuid(serviceUuid)
      // Marker lets iOS identify LPC advertisements when Android places the
      // service UUID only in a scan response that CoreBluetooth omits.
      .addManufacturerData(0xFFFF, byteArrayOf(0x4c, 0x50, 0x43, 0x31))
      .build()
    val settings = AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
      .setConnectable(true).setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM).build()
    advertiserCallback = object : AdvertiseCallback() {
      override fun onStartFailure(errorCode: Int) {
        Log.e(logTag, "advertising failed code=$errorCode")
        emitError("ADVERTISING_UNAVAILABLE", "Android advertise error $errorCode", errorCode)
      }
    }
    advertiser.startAdvertising(settings, data, advertiserCallback)
    Log.d(logTag, "advertising requested")
  }

  private fun stopAdvertising() {
    advertiserCallback?.let { callback -> adapterOrNull()?.bluetoothLeAdvertiser?.stopAdvertising(callback) }
    advertiserCallback = null
  }

  private fun startDiscovery(serviceUuid: ParcelUuid) {
    Log.d(logTag, "startDiscovery uuid=$serviceUuid")
    val scanner = adapterOrThrow().bluetoothLeScanner ?: throw BackendError("DISCOVERY_UNAVAILABLE")
    activeServiceUuid = serviceUuid
    stopDiscovery()
    val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
    scanCallback = object : ScanCallback() {
      override fun onScanResult(callbackType: Int, result: ScanResult) {
        val advertised = result.scanRecord?.serviceUuids?.any { it == serviceUuid } == true
        if (!advertised) return
        val now = System.currentTimeMillis()
        val previous = lastScanLogMs[result.device.address] ?: 0L
        if (now - previous >= 5000L) {
          lastScanLogMs[result.device.address] = now
          Log.d(logTag, "scan match address=${result.device.address} name=${result.scanRecord?.deviceName} rssi=${result.rssi}")
        }
        emitSuccess(mapOf("type" to "endpointFound", "endpointId" to result.device.address,
          "localName" to result.scanRecord?.deviceName, "rssi" to result.rssi))
      }
      override fun onScanFailed(errorCode: Int) {
        Log.e(logTag, "scan failed code=$errorCode")
        emitError("DISCOVERY_UNAVAILABLE", "Android scan error $errorCode", errorCode)
      }
    }
    // Some Android stacks omit service UUIDs from the scan response when a
    // hardware ScanFilter is used. Scan broadly and apply the UUID check above
    // so discovery remains reliable across vendors.
    scanner.startScan(null, settings, scanCallback)
    Log.d(logTag, "discovery requested")
  }

  private fun stopDiscovery() {
    scanCallback?.let { callback -> adapterOrNull()?.bluetoothLeScanner?.stopScan(callback) }
    scanCallback = null
  }

  /** Hosts exactly the Section 11 primary service. Frame fragmentation and
   * protocol authentication remain in the portable backend above this API. */
  private fun listenGatt(serviceUuid: ParcelUuid) {
    val manager = applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
      ?: throw BackendError("BLUETOOTH_UNAVAILABLE")
    adapterOrThrow()
    activeServiceUuid = serviceUuid
    stopGatt()
    val server = manager.openGattServer(applicationContext, object : BluetoothGattServerCallback() {
      override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
        if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
          gattServerPeers[device.address] = device
        } else {
          gattServerPeers.remove(device.address)
          emitSuccess(mapOf("type" to "gattDisconnected", "endpointId" to device.address))
        }
        if (status != BluetoothGatt.GATT_SUCCESS) {
          emitError("PLATFORM_ERROR", "GATT connection error $status", status)
        }
      }
      override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int,
          characteristic: BluetoothGattCharacteristic, preparedWrite: Boolean,
          responseNeeded: Boolean, offset: Int, value: ByteArray) {
        if (characteristic.uuid == characteristicUuid(serviceUuid, 1) && !preparedWrite && offset == 0) {
          emitSuccess(mapOf("type" to "gattFragment", "endpointId" to device.address,
            "bytes" to value.map { it.toInt() and 0xff }))
          if (responseNeeded) sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        } else if (responseNeeded) {
          sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
        }
      }
      override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int,
          descriptor: BluetoothGattDescriptor, preparedWrite: Boolean,
          responseNeeded: Boolean, offset: Int, value: ByteArray) {
        if (descriptor.uuid == CLIENT_CONFIGURATION_UUID &&
            descriptor.characteristic.uuid == characteristicUuid(serviceUuid, 2) &&
            !preparedWrite && offset == 0 &&
            (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ||
             value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE))) {
          if (responseNeeded) sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
          emitSuccess(mapOf("type" to "gattConnected", "endpointId" to device.address,
              "localRole" to "peripheral", "platformSafeWriteSize" to 20))
        } else if (responseNeeded) {
          sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
        }
      }
    }) ?: throw BackendError("ADVERTISING_UNAVAILABLE", "unable to open GATT server")
    val service = BluetoothGattService(serviceUuid.uuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
    service.addCharacteristic(BluetoothGattCharacteristic(
      characteristicUuid(serviceUuid, 1),
      BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
      BluetoothGattCharacteristic.PERMISSION_WRITE
    ))
    service.addCharacteristic(BluetoothGattCharacteristic(
      characteristicUuid(serviceUuid, 2),
      BluetoothGattCharacteristic.PROPERTY_NOTIFY,
      0
    ).also { tx ->
      tx.addDescriptor(BluetoothGattDescriptor(CLIENT_CONFIGURATION_UUID,
        BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
    })
    service.addCharacteristic(BluetoothGattCharacteristic(
      characteristicUuid(serviceUuid, 3),
      BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
      BluetoothGattCharacteristic.PERMISSION_READ or BluetoothGattCharacteristic.PERMISSION_WRITE
    ))
    if (!server.addService(service)) {
      server.close()
      throw BackendError("ADVERTISING_UNAVAILABLE", "unable to add LPC GATT service")
    }
    gattServer = server
  }

  private fun stopGatt() {
    gattServer?.close()
    gattServer = null
    gattServerPeers.clear()
    for (client in gattClients.values) client.gatt.close()
    gattClients.clear()
  }

  /** Establishes a central/client link and accepts it only after the exact
   * Section 11 service and all three required characteristics are present. */
  private fun connectGatt(endpointId: String) {
    val serviceUuid = activeServiceUuid ?: throw BackendError(
      "UNSUPPORTED_CAPABILITY", "no configured LPC GATT service UUID")
    val rxUuid = characteristicUuid(serviceUuid, 1)
    val txUuid = characteristicUuid(serviceUuid, 2)
    val controlUuid = characteristicUuid(serviceUuid, 3)
    val device = try { adapterOrThrow().getRemoteDevice(endpointId) }
    catch (_: IllegalArgumentException) { throw BackendError("ENDPOINT_LOST", "unknown discovery endpoint") }
    val gatt = device.connectGatt(applicationContext, false, object : BluetoothGattCallback() {
      override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
        if (status != BluetoothGatt.GATT_SUCCESS || newState != BluetoothProfile.STATE_CONNECTED) {
          gattClients.remove(endpointId)?.gatt?.close()
          emitError("ENDPOINT_LOST", "GATT connection error $status", status)
          return
        }
        if (!gatt.discoverServices()) {
          gatt.close()
          gattClients.remove(endpointId)
          emitError("PLATFORM_ERROR", "GATT service discovery did not start", null)
        }
      }
      override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
        val service = gatt.getService(serviceUuid.uuid) ?: run {
          rejectGatt(endpointId, gatt, "LPC GATT service missing"); return
        }
        val rx = service.getCharacteristic(rxUuid)
        val tx = service.getCharacteristic(txUuid)
        val control = service.getCharacteristic(controlUuid)
        if (rx == null || tx == null || control == null) {
          rejectGatt(endpointId, gatt, "LPC GATT characteristics missing"); return
        }
        gattClients[endpointId] = GattClient(gatt, rx, tx, control)
        if (!gatt.setCharacteristicNotification(tx, true)) {
          rejectGatt(endpointId, gatt, "unable to enable LPC TX notifications"); return
        }
        val descriptor = tx.getDescriptor(CLIENT_CONFIGURATION_UUID) ?: run {
          rejectGatt(endpointId, gatt, "LPC TX configuration descriptor missing"); return
        }
        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        if (!gatt.writeDescriptor(descriptor)) {
          rejectGatt(endpointId, gatt, "unable to subscribe to LPC TX"); return
        }
      }
      override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
        if (descriptor.uuid != CLIENT_CONFIGURATION_UUID) return
        if (status != BluetoothGatt.GATT_SUCCESS) {
          rejectGatt(endpointId, gatt, "LPC TX subscription failed"); return
        }
        emitSuccess(mapOf("type" to "gattConnected", "endpointId" to endpointId,
            "localRole" to "central", "platformSafeWriteSize" to 20))
      }
      override fun onCharacteristicWrite(gatt: BluetoothGatt,
          characteristic: BluetoothGattCharacteristic, status: Int) {
        if (characteristic.uuid == rxUuid) {
          gattClients[endpointId]?.writeInFlight = false
          if (status == BluetoothGatt.GATT_SUCCESS) {
            emitSuccess(mapOf("type" to "gattWritable", "endpointId" to endpointId))
          } else {
            emitError("PLATFORM_ERROR", "GATT characteristic write failed $status", status)
          }
        }
      }
      override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        if (characteristic.uuid == txUuid) {
          characteristic.value?.let { value -> emitSuccess(mapOf("type" to "gattFragment",
              "endpointId" to endpointId, "bytes" to value.map { it.toInt() and 0xff })) }
        }
      }
    }) ?: throw BackendError("ENDPOINT_LOST", "GATT connection did not start")
  }

  private fun submitGattFragment(call: MethodCall): String {
    val endpointId = call.argument<String>("endpointId") ?: throw BackendError("ENDPOINT_LOST")
    val fragment = call.argument<ByteArray>("fragment") ?: throw BackendError("PLATFORM_ERROR", "missing GATT fragment")
    val transmission = call.argument<String>("transmission") ?: throw BackendError("PLATFORM_ERROR", "missing GATT transmission")
    val client = gattClients[endpointId]
    if (client == null) {
      val device = gattServerPeers[endpointId] ?: return "terminalFailure"
      val tx = gattServer?.getService(activeServiceUuid?.uuid ?: return "terminalFailure")
          ?.getCharacteristic(characteristicUuid(activeServiceUuid!!, 2)) ?: return "terminalFailure"
      tx.value = fragment
      return if (gattServer!!.notifyCharacteristicChanged(device, tx, false)) "submitted" else "temporarilyUnavailable"
    }
    if (transmission == "notify") return "terminalFailure"
    if (client.writeInFlight) return "temporarilyUnavailable"
    client.rx.value = fragment
    client.rx.writeType = if (transmission == "writeWithoutResponse")
      BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
    // `true` is the Android API submission boundary. A `false` result is a
    // transient local queue condition; it must not be treated as transport loss.
    client.writeInFlight = true
    return if (client.gatt.writeCharacteristic(client.rx)) "submitted" else {
      client.writeInFlight = false
      "temporarilyUnavailable"
    }
  }

  private fun closeGattConnection(endpointId: String) {
    gattClients.remove(endpointId)?.gatt?.let { gatt -> gatt.disconnect(); gatt.close() }
  }

  private fun sendResponse(device: BluetoothDevice, requestId: Int, status: Int,
      offset: Int, value: ByteArray?) {
    gattServer?.sendResponse(device, requestId, status, offset, value)
  }

  private fun rejectGatt(endpointId: String, gatt: BluetoothGatt, message: String) {
    gattClients.remove(endpointId)
    gatt.disconnect()
    gatt.close()
    emitError("PLATFORM_ERROR", message, null)
  }

  private fun characteristicUuid(serviceUuid: ParcelUuid, increment: Int): UUID {
    val bytes = ByteBuffer.allocate(16)
      .putLong(serviceUuid.uuid.mostSignificantBits)
      .putLong(serviceUuid.uuid.leastSignificantBits)
      .array()
    if ((bytes[3].toInt() and 0xff) > 0xff - increment) {
      throw BackendError("UNSUPPORTED_CAPABILITY", "GATT characteristic UUID arithmetic wraps")
    }
    bytes[3] = (bytes[3].toInt() + increment).toByte()
    val derived = ByteBuffer.wrap(bytes)
    return UUID(derived.long, derived.long)
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

  private fun emitSuccess(value: Any) {
    Handler(Looper.getMainLooper()).post { eventSink?.success(value) }
  }

  private fun emitError(code: String, message: String, details: Any?) {
    Handler(Looper.getMainLooper()).post { eventSink?.error(code, message, details) }
  }

  private fun runBackendValue(result: MethodChannel.Result, block: () -> Any?) {
    try { result.success(block()) }
    catch (error: SecurityException) { result.error("PERMISSION_DENIED", error.message, null) }
    catch (error: BackendError) { result.error(error.code, error.message, null) }
    catch (error: Exception) { result.error("PLATFORM_ERROR", error.message, null) }
  }

  private class BackendError(val code: String, override val message: String = code) : Exception(message)
  private data class GattClient(
    val gatt: BluetoothGatt,
    val rx: BluetoothGattCharacteristic,
    val tx: BluetoothGattCharacteristic,
    val control: BluetoothGattCharacteristic,
    var writeInFlight: Boolean = false
  )

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
    val CLIENT_CONFIGURATION_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
  }
}

import Flutter
import UIKit
import Security
import CoreBluetooth

public class LocalPeerConnectionsPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
                                          CBCentralManagerDelegate, CBPeripheralManagerDelegate,
                                          CBPeripheralDelegate {
  private static let identityChannel = "dev.localpeerconnections.local_peer_connections/identity"
  private static let backendChannel = "dev.localpeerconnections.local_peer_connections/backend"
  private static let backendEventsChannel = "dev.localpeerconnections.local_peer_connections/backend_events"
  private static let service = "dev.localpeerconnections.local_peer_connections.identity"
  private static let account = "ed25519_seed_v1"

  private var central: CBCentralManager!
  private var peripheral: CBPeripheralManager!
  private var eventSink: FlutterEventSink?
  private var gattService: CBMutableService?
  private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
  private var expectedGattServices: [UUID: CBUUID] = [:]
  private var activeServiceUuid: CBUUID?
  private var gattClients: [UUID: GattClient] = [:]
  private var gattServerCentrals: [UUID: CBCentral] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LocalPeerConnectionsPlugin()
    let identity = FlutterMethodChannel(name: identityChannel, binaryMessenger: registrar.messenger())
    let backend = FlutterMethodChannel(name: backendChannel, binaryMessenger: registrar.messenger())
    let events = FlutterEventChannel(name: backendEventsChannel, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: identity)
    registrar.addMethodCallDelegate(instance, channel: backend)
    events.setStreamHandler(instance)
    instance.central = CBCentralManager(delegate: instance, queue: nil)
    instance.peripheral = CBPeripheralManager(delegate: instance, queue: nil)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    print("[LocalPeerConnections] method \(call.method)")
    switch call.method {
    case "loadOrCreateEd25519Seed":
      do { result(try loadOrCreateSeed()) }
      catch {
        // Never replace a malformed or unavailable existing identity silently.
        result(FlutterError(code: "IDENTITY_STORAGE", message: "Unable to access protected identity", details: nil))
      }
    case "queryCapabilities":
      var capabilities: [String] = []
      if central.state != .unsupported { capabilities.append("bleScan") }
      if peripheral.state != .unsupported { capabilities.append("bleAdvertise") }
      if central.state != .unsupported { capabilities.append("gattCentral") }
      if peripheral.state != .unsupported { capabilities.append("gattPeripheral") }
      result(capabilities)
    case "startAdvertising":
      backend(call, result) { arguments in
        try self.requirePoweredOn(self.peripheral.state)
        let uuid = try self.serviceUuid(arguments)
        var advertisement: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [uuid]]
        if let localName = arguments["localName"] as? String {
          advertisement[CBAdvertisementDataLocalNameKey] = localName
        }
        self.peripheral.startAdvertising(advertisement)
        print("[LocalPeerConnections] advertising requested uuid=\(uuid.uuidString)")
      }
    case "stopAdvertising":
      peripheral.stopAdvertising(); result(nil)
    case "startDiscovery":
      backend(call, result) { arguments in
        try self.requirePoweredOn(self.central.state)
        let serviceUuid = try self.serviceUuid(arguments)
        self.activeServiceUuid = serviceUuid
        // Request duplicate advertisements so callers can maintain a live
        // endpoint/TTL view and RSSI updates instead of expiring entries while
        // the peripheral is still advertising.
        self.central.scanForPeripherals(
          withServices: [serviceUuid],
          options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        print("[LocalPeerConnections] discovery requested uuid=\(serviceUuid.uuidString)")
      }
    case "stopDiscovery":
      central.stopScan(); result(nil)
    case "listenGatt":
      backend(call, result) { arguments in
        try self.requirePoweredOn(self.peripheral.state)
        try self.listenGatt(try self.serviceUuid(arguments))
      }
    case "stopGatt":
      peripheral.removeAllServices(); gattService = nil; gattServerCentrals.removeAll(); result(nil)
    case "connectGatt":
      backend(call, result) { arguments in
        try self.requirePoweredOn(self.central.state)
        guard let endpointId = arguments["endpointId"] as? String,
              let identifier = UUID(uuidString: endpointId),
              let peripheral = self.discoveredPeripherals[identifier] else {
          throw BackendError("ENDPOINT_LOST", "unknown discovery endpoint")
        }
        guard let serviceUuid = self.activeServiceUuid else {
          throw BackendError("UNSUPPORTED_CAPABILITY", "no configured LPC GATT service UUID")
        }
        self.expectedGattServices[identifier] = serviceUuid
        self.central.connect(peripheral, options: nil)
      }
    case "submitGattFragment":
      backendValue(call, result) { arguments in try self.submitGattFragment(arguments) }
    case "closeGattConnection":
      backend(call, result) { arguments in
        guard let endpointId = arguments["endpointId"] as? String,
              let identifier = UUID(uuidString: endpointId),
              let client = self.gattClients.removeValue(forKey: identifier) else {
          throw BackendError("ENDPOINT_LOST", "unknown GATT connection")
        }
        self.central.cancelPeripheralConnection(client.peripheral)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }
  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    print("[LocalPeerConnections] central state=\(central.state.rawValue)")
  }
  public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    print("[LocalPeerConnections] peripheral state=\(peripheral.state.rawValue)")
  }
  public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                             advertisementData: [String : Any], rssi RSSI: NSNumber) {
    discoveredPeripherals[peripheral.identifier] = peripheral
    print("[LocalPeerConnections] endpoint found id=\(peripheral.identifier.uuidString) name=\(advertisementData[CBAdvertisementDataLocalNameKey] ?? "") rssi=\(RSSI)")
    eventSink?(["type": "endpointFound", "endpointId": peripheral.identifier.uuidString,
                "localName": advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                "rssi": RSSI.intValue])
  }
  public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard let service = expectedGattServices[peripheral.identifier] else {
      central.cancelPeripheralConnection(peripheral); return
    }
    peripheral.delegate = self
    peripheral.discoverServices([service])
  }
  public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                             error: Error?) {
    expectedGattServices.removeValue(forKey: peripheral.identifier)
    eventSink?(FlutterError(code: "ENDPOINT_LOST", message: error?.localizedDescription, details: nil))
  }
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard error == nil, let expected = expectedGattServices[peripheral.identifier],
          let service = peripheral.services?.first(where: { $0.uuid == expected }) else {
      rejectGatt(peripheral, message: "LPC GATT service missing"); return
    }
    do {
      try peripheral.discoverCharacteristics([
        try characteristicUuid(expected, increment: 1),
        try characteristicUuid(expected, increment: 2),
        try characteristicUuid(expected, increment: 3)
      ], for: service)
    } catch {
      rejectGatt(peripheral, message: error.localizedDescription)
    }
  }
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                         error: Error?) {
    guard error == nil, let expected = expectedGattServices[peripheral.identifier] else {
      rejectGatt(peripheral, message: "LPC GATT characteristic discovery failed"); return
    }
    do {
      let required = [
        try characteristicUuid(expected, increment: 1),
        try characteristicUuid(expected, increment: 2),
        try characteristicUuid(expected, increment: 3)
      ]
      let present = Set(service.characteristics?.map(\.uuid) ?? [])
      guard required.allSatisfy(present.contains) else {
        rejectGatt(peripheral, message: "LPC GATT characteristics missing"); return
      }
      guard let characteristics = service.characteristics,
            let rx = characteristics.first(where: { $0.uuid == required[0] }),
            let tx = characteristics.first(where: { $0.uuid == required[1] }),
            let control = characteristics.first(where: { $0.uuid == required[2] }) else {
        rejectGatt(peripheral, message: "LPC GATT characteristics missing"); return
      }
      gattClients[peripheral.identifier] = GattClient(peripheral: peripheral, rx: rx, tx: tx, control: control)
      peripheral.setNotifyValue(true, for: tx)
    } catch {
      rejectGatt(peripheral, message: error.localizedDescription)
    }
  }
  public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                         error: Error?) {
    guard error == nil, let client = gattClients[peripheral.identifier],
          characteristic.uuid == client.tx.uuid, characteristic.isNotifying else {
      rejectGatt(peripheral, message: error?.localizedDescription ?? "LPC TX subscription failed"); return
    }
    eventSink?(["type": "gattConnected", "endpointId": peripheral.identifier.uuidString,
                "localRole": "central", "platformSafeWriteSize": peripheral.maximumWriteValueLength(for: .withResponse)])
  }
  public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                         error: Error?) {
    guard error == nil, let client = gattClients[peripheral.identifier],
          characteristic.uuid == client.tx.uuid, let value = characteristic.value else { return }
    eventSink?(["type": "gattFragment", "endpointId": peripheral.identifier.uuidString,
                "bytes": [UInt8](value)])
  }
  public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                             error: Error?) {
    expectedGattServices.removeValue(forKey: peripheral.identifier)
    gattClients.removeValue(forKey: peripheral.identifier)
    eventSink?(["type": "gattDisconnected", "endpointId": peripheral.identifier.uuidString])
  }
  public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error {
      eventSink?(FlutterError(code: "ADVERTISING_UNAVAILABLE", message: error.localizedDescription, details: nil))
    }
  }
  public func peripheralManager(_ peripheral: CBPeripheralManager,
                                didReceiveWrite requests: [CBATTRequest]) {
    for request in requests {
      guard let service = activeServiceUuid,
            request.characteristic.uuid == (try? characteristicUuid(service, increment: 1)),
            request.offset == 0, let value = request.value else {
        peripheral.respond(to: request, withResult: .requestNotSupported); continue
      }
      eventSink?(["type": "gattFragment", "endpointId": request.central.identifier.uuidString,
                  "bytes": [UInt8](value)])
      peripheral.respond(to: request, withResult: .success)
    }
  }
  public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                didSubscribeTo characteristic: CBCharacteristic) {
    guard let service = gattService,
          characteristic.uuid == (try? characteristicUuid(service.uuid, increment: 2)) else { return }
    gattServerCentrals[central.identifier] = central
    eventSink?(["type": "gattConnected", "endpointId": central.identifier.uuidString,
                "localRole": "peripheral", "platformSafeWriteSize": 20])
  }
  public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                didUnsubscribeFrom characteristic: CBCharacteristic) {
    gattServerCentrals.removeValue(forKey: central.identifier)
    eventSink?(["type": "gattDisconnected", "endpointId": central.identifier.uuidString])
  }
  public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    // Dart owns the bounded fragment queue and will retry only after an
    // explicit writable signal.
    eventSink?(["type": "gattWritable"])
  }

  /// Hosts exactly the Section 11 service. The Dart GATT backend remains the
  /// owner of fragment framing and LPC protocol state.
  private func listenGatt(_ serviceUuid: CBUUID) throws {
    peripheral.removeAllServices()
    // The peripheral-side RX callback derives the exact service
    // characteristics from this value.  Discovery also sets this field for
    // central connections, but a peripheral-only host never starts scanning.
    // Without this assignment every valid incoming RX write was rejected.
    activeServiceUuid = serviceUuid
    let service = CBMutableService(type: serviceUuid, primary: true)
    let rx = CBMutableCharacteristic(
      type: try characteristicUuid(serviceUuid, increment: 1),
      properties: [.write, .writeWithoutResponse], value: nil,
      permissions: [.writeable])
    let tx = CBMutableCharacteristic(
      type: try characteristicUuid(serviceUuid, increment: 2),
      properties: [.notify], value: nil, permissions: [])
    let control = CBMutableCharacteristic(
      type: try characteristicUuid(serviceUuid, increment: 3),
      properties: [.read, .write, .notify], value: nil,
      permissions: [.readable, .writeable])
    service.characteristics = [rx, tx, control]
    peripheral.add(service)
    gattService = service
  }

  private func backend(_ call: FlutterMethodCall, _ result: @escaping FlutterResult,
                       _ action: ([String: Any]) throws -> Void) {
    guard let arguments = call.arguments as? [String: Any] else {
      result(FlutterError(code: "PLATFORM_ERROR", message: "missing arguments", details: nil)); return
    }
    do { try action(arguments); result(nil) }
    catch let error as BackendError { result(FlutterError(code: error.code, message: error.message, details: nil)) }
    catch { result(FlutterError(code: "PLATFORM_ERROR", message: error.localizedDescription, details: nil)) }
  }
  private func backendValue(_ call: FlutterMethodCall, _ result: @escaping FlutterResult,
                            _ action: ([String: Any]) throws -> Any) {
    guard let arguments = call.arguments as? [String: Any] else {
      result(FlutterError(code: "PLATFORM_ERROR", message: "missing arguments", details: nil)); return
    }
    do { result(try action(arguments)) }
    catch let error as BackendError { result(FlutterError(code: error.code, message: error.message, details: nil)) }
    catch { result(FlutterError(code: "PLATFORM_ERROR", message: error.localizedDescription, details: nil)) }
  }

  private func submitGattFragment(_ arguments: [String: Any]) throws -> String {
    guard let endpointId = arguments["endpointId"] as? String,
          let identifier = UUID(uuidString: endpointId),
          let fragment = arguments["fragment"] as? FlutterStandardTypedData,
          let transmission = arguments["transmission"] as? String else {
      throw BackendError("ENDPOINT_LOST", "unknown GATT connection")
    }
    if let central = gattServerCentrals[identifier], let service = gattService,
       let tx = service.characteristics?.first(where: { $0.uuid == (try? characteristicUuid(service.uuid, increment: 2)) }) as? CBMutableCharacteristic {
      return peripheral.updateValue(fragment.data, for: tx, onSubscribedCentrals: [central])
        ? "submitted" : "temporarilyUnavailable"
    }
    guard let client = gattClients[identifier] else {
      throw BackendError("ENDPOINT_LOST", "unknown GATT connection")
    }
    if transmission == "notify" { return "terminalFailure" }
    client.peripheral.writeValue(fragment.data, for: client.rx,
      type: transmission == "writeWithoutResponse" ? .withoutResponse : .withResponse)
    return "submitted"
  }

  private func serviceUuid(_ arguments: [String: Any]) throws -> CBUUID {
    guard let bytes = arguments["serviceUuid"] as? FlutterStandardTypedData, bytes.data.count == 16 else {
      throw BackendError("PLATFORM_ERROR", "serviceUuid must be 16 bytes")
    }
    return CBUUID(data: bytes.data)
  }
  private func characteristicUuid(_ service: CBUUID, increment: UInt8) throws -> CBUUID {
    var bytes = [UInt8](service.data)
    guard bytes.count == 16, bytes[3] <= UInt8.max - increment else {
      throw BackendError("UNSUPPORTED_CAPABILITY", "GATT characteristic UUID arithmetic wraps")
    }
    bytes[3] += increment
    return CBUUID(data: Data(bytes))
  }
  private func rejectGatt(_ peripheral: CBPeripheral, message: String) {
    expectedGattServices.removeValue(forKey: peripheral.identifier)
    gattClients.removeValue(forKey: peripheral.identifier)
    central.cancelPeripheralConnection(peripheral)
    eventSink?(FlutterError(code: "PLATFORM_ERROR", message: message, details: nil))
  }
  private func requirePoweredOn(_ state: CBManagerState) throws {
    switch state {
    case .poweredOn: return
    case .poweredOff: throw BackendError("BLUETOOTH_POWERED_OFF", "Bluetooth is powered off")
    case .unauthorized: throw BackendError("PERMISSION_DENIED", "Bluetooth permission denied")
    case .unsupported: throw BackendError("BLUETOOTH_UNAVAILABLE", "Bluetooth is unsupported")
    default: throw BackendError("BLUETOOTH_UNAVAILABLE", "Bluetooth is unavailable")
    }
  }
  private struct BackendError: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String? = nil) {
      self.code = code
      self.message = message ?? code
    }
  }

  private func loadOrCreateSeed() throws -> Data {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: Self.account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess {
      guard let seed = item as? Data, seed.count == 32 else { throw IdentityStorageError.invalidStoredSeed }
      return seed
    }
    guard status == errSecItemNotFound else { throw IdentityStorageError.keychain(status) }
    var seed = Data(count: 32)
    let randomStatus = seed.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    guard randomStatus == errSecSuccess else { throw IdentityStorageError.keychain(randomStatus) }
    var add = query
    add.removeValue(forKey: kSecReturnData); add.removeValue(forKey: kSecMatchLimit)
    add[kSecValueData] = seed
    add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw IdentityStorageError.keychain(addStatus) }
    return seed
  }

  private enum IdentityStorageError: Error { case invalidStoredSeed; case keychain(OSStatus) }
  private struct GattClient {
    let peripheral: CBPeripheral
    let rx: CBCharacteristic
    let tx: CBCharacteristic
    let control: CBCharacteristic
  }
}

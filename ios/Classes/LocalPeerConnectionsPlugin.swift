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
  private var expectedGattGenerations: [UUID: Int64] = [:]
  private var closingGattGenerations: [UUID: Int64] = [:]
  private var activeServiceUuid: CBUUID?
  private var gattClients: [UUID: GattClient] = [:]
  private var gattServerCentrals: [UUID: CBCentral] = [:]
  // A CBCentral UUID identifies the remote device, not a particular GATT
  // link. iOS can have an outbound central link and an inbound peripheral
  // link to the same device at the same time, so server links use an opaque
  // connection-scoped endpoint ID just like Android does.
  private var gattServerEndpointByCentral: [UUID: String] = [:]
  private var gattServerCentralByEndpoint: [String: UUID] = [:]
  private var gattServerGenerations: [String: Int64] = [:]
  private var nextGattGeneration: Int64 = 1
  private var nextServerEndpointId: Int64 = 1
  private var lastDiscoveryLog: [UUID: Date] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LocalPeerConnectionsPlugin()
    let identity = FlutterMethodChannel(name: identityChannel, binaryMessenger: registrar.messenger())
    let backend = FlutterMethodChannel(name: backendChannel, binaryMessenger: registrar.messenger())
    let events = FlutterEventChannel(name: backendEventsChannel, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: identity)
    registrar.addMethodCallDelegate(instance, channel: backend)
    events.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    print("[LocalPeerConnections] method \(call.method)")
    // CoreBluetooth can remain in .unknown when its managers are created
    // during plugin registration, before Flutter has presented the app. Defer
    // construction until the first backend call, when the host application is
    // active and iOS can initialize Bluetooth and present authorization.
    if call.method != "loadOrCreateEd25519Seed" {
      ensureBluetoothManagers()
    }
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
          // Android devices may place the 128-bit UUID in a scan response;
          // filtering in CoreBluetooth can then discard the advertisement.
          // Scan broadly and let the app present endpoints explicitly.
          withServices: nil,
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
      peripheral.removeAllServices()
      gattService = nil
      gattServerCentrals.removeAll()
      gattServerEndpointByCentral.removeAll()
      gattServerCentralByEndpoint.removeAll()
      gattServerGenerations.removeAll()
      result(nil)
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
        guard self.gattClients[identifier] == nil,
              self.expectedGattServices[identifier] == nil else {
          throw BackendError("ENDPOINT_BUSY", "GATT endpoint already has a client link")
        }
        let generation = self.nextGattGeneration
        self.nextGattGeneration += 1
        self.expectedGattServices[identifier] = serviceUuid
        self.expectedGattGenerations[identifier] = generation
        print("[LocalPeerConnections] client connect requested endpoint=\(endpointId) generation=\(generation)")
        self.central.connect(peripheral, options: nil)
      }
    case "submitGattFragment":
      backendValue(call, result) { arguments in try self.submitGattFragment(arguments) }
    case "closeGattConnection":
      backend(call, result) { arguments in
        guard let endpointId = arguments["endpointId"] as? String else {
          throw BackendError("ENDPOINT_LOST", "unknown GATT connection")
        }
        let requestedGeneration = (arguments["connectionGeneration"] as? NSNumber)?.int64Value

        // A peripheral-side endpoint is represented by an opaque local
        // handle. There is no CoreBluetooth API to actively cancel the
        // remote central, but removing our mapping makes close idempotent and
        // prevents late Dart writes from being delivered to that link.
        if let centralIdentifier = self.gattServerCentralByEndpoint[endpointId] {
          let currentGeneration = self.gattServerGenerations[endpointId]
          if let requestedGeneration, requestedGeneration != currentGeneration {
            let currentText = currentGeneration.map { String($0) } ?? "none"
            print("[LocalPeerConnections] ignore stale close endpoint=\(endpointId) generation=\(requestedGeneration) current=\(currentText)")
            return
          }
          self.gattServerCentralByEndpoint.removeValue(forKey: endpointId)
          self.gattServerEndpointByCentral.removeValue(forKey: centralIdentifier)
          self.gattServerCentrals.removeValue(forKey: centralIdentifier)
          self.gattServerGenerations.removeValue(forKey: endpointId)
          print("[LocalPeerConnections] closed server endpoint=\(endpointId)")
          return
        }

        // Server handles are local, opaque IDs. A disconnect callback may
        // remove the handle before a racing handshake cleanup reaches this
        // method, so an unknown server handle is also an idempotent no-op.
        if endpointId.hasPrefix("server-") {
          print("[LocalPeerConnections] close ignored; server endpoint already closed \(endpointId)")
          return
        }

        guard let identifier = UUID(uuidString: endpointId) else {
          throw BackendError("ENDPOINT_LOST", "unknown GATT connection")
        }
        let currentGeneration = self.gattClients[identifier]?.generation ?? self.expectedGattGenerations[identifier]
        if let requestedGeneration, requestedGeneration != currentGeneration {
          let currentText = currentGeneration.map { String($0) } ?? "none"
          print("[LocalPeerConnections] ignore stale close endpoint=\(endpointId) generation=\(requestedGeneration) current=\(currentText)")
          return
        }
        // Closing is idempotent across the platform backends. A disconnect
        // callback can remove the client before a racing handshake cleanup
        // reaches this method, so an already-closed endpoint is not an error.
        if let client = self.gattClients.removeValue(forKey: identifier) {
          self.expectedGattServices.removeValue(forKey: identifier)
          self.expectedGattGenerations.removeValue(forKey: identifier)
          self.closingGattGenerations[identifier] = client.generation
          self.central.cancelPeripheralConnection(client.peripheral)
        } else if let generation = self.expectedGattGenerations.removeValue(forKey: identifier) {
          self.expectedGattServices.removeValue(forKey: identifier)
          self.closingGattGenerations[identifier] = generation
          if let peripheral = self.discoveredPeripherals[identifier] {
            self.central.cancelPeripheralConnection(peripheral)
          }
        } else {
          self.expectedGattServices.removeValue(forKey: identifier)
          print("[LocalPeerConnections] close ignored; endpoint already closed \(endpointId)")
        }
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
    if let expected = activeServiceUuid {
      let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
        + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
      let marker = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
      let isLpcMarker = marker?.suffix(4).elementsEqual([0x4c, 0x50, 0x43, 0x31]) == true
      guard advertised.contains(expected) || isLpcMarker else { return }
    }
    discoveredPeripherals[peripheral.identifier] = peripheral
    let now = Date()
    if now.timeIntervalSince(lastDiscoveryLog[peripheral.identifier] ?? .distantPast) >= 5 {
      lastDiscoveryLog[peripheral.identifier] = now
      print("[LocalPeerConnections][\(ISO8601DateFormatter().string(from: now))] endpoint found id=\(peripheral.identifier.uuidString) name=\(advertisementData[CBAdvertisementDataLocalNameKey] ?? "") rssi=\(RSSI)")
    }
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
    if let closingGeneration = closingGattGenerations[peripheral.identifier],
       let replacementGeneration = expectedGattGenerations[peripheral.identifier],
       replacementGeneration != closingGeneration {
      closingGattGenerations.removeValue(forKey: peripheral.identifier)
      print("[LocalPeerConnections] ignore stale connect failure endpoint=\(peripheral.identifier.uuidString) generation=\(closingGeneration) replacement=\(replacementGeneration)")
      return
    }
    closingGattGenerations.removeValue(forKey: peripheral.identifier)
    expectedGattServices.removeValue(forKey: peripheral.identifier)
    expectedGattGenerations.removeValue(forKey: peripheral.identifier)
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
      guard let generation = expectedGattGenerations[peripheral.identifier] else {
        rejectGatt(peripheral, message: "LPC GATT connection generation missing"); return
      }
      gattClients[peripheral.identifier] = GattClient(peripheral: peripheral, rx: rx, tx: tx, control: control, generation: generation)
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
                "localRole": "central", "platformSafeWriteSize": peripheral.maximumWriteValueLength(for: .withResponse),
                "connectionGeneration": client.generation])
  }
  public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                         error: Error?) {
    guard error == nil, let client = gattClients[peripheral.identifier],
          characteristic.uuid == client.tx.uuid, let value = characteristic.value else { return }
    eventSink?(["type": "gattFragment", "endpointId": peripheral.identifier.uuidString,
                "connectionGeneration": client.generation,
                "bytes": [UInt8](value)])
  }
  public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                         error: Error?) {
    guard let client = gattClients[peripheral.identifier], characteristic.uuid == client.rx.uuid else { return }
    if let error {
      eventSink?(FlutterError(code: "PLATFORM_ERROR", message: error.localizedDescription, details: nil))
    } else {
      eventSink?(["type": "gattWritable", "endpointId": peripheral.identifier.uuidString,
                  "connectionGeneration": client.generation])
    }
  }
  public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                             error: Error?) {
    let closingGeneration = closingGattGenerations[peripheral.identifier]
    // CoreBluetooth can deliver the disconnect callback for a cancelled
    // connection after Dart has already started its replacement. Once a new
    // generation is expected, the old callback must not erase the new
    // expected service/client state or report a false disconnect for it.
    if let closingGeneration,
       let replacementGeneration = expectedGattGenerations[peripheral.identifier],
       replacementGeneration != closingGeneration {
      closingGattGenerations.removeValue(forKey: peripheral.identifier)
      print("[LocalPeerConnections] ignore stale disconnect endpoint=\(peripheral.identifier.uuidString) generation=\(closingGeneration) replacement=\(replacementGeneration)")
      return
    }
    let generation = closingGattGenerations.removeValue(forKey: peripheral.identifier)
      ?? gattClients[peripheral.identifier]?.generation
      ?? expectedGattGenerations[peripheral.identifier]
    expectedGattServices.removeValue(forKey: peripheral.identifier)
    expectedGattGenerations.removeValue(forKey: peripheral.identifier)
    gattClients.removeValue(forKey: peripheral.identifier)
    eventSink?(["type": "gattDisconnected", "endpointId": peripheral.identifier.uuidString,
                "connectionGeneration": generation as Any])
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
      guard let endpointId = gattServerEndpointByCentral[request.central.identifier] else {
        peripheral.respond(to: request, withResult: .requestNotSupported); continue
      }
      eventSink?(["type": "gattFragment", "endpointId": endpointId,
                  "connectionGeneration": gattServerGenerations[endpointId] as Any,
                  "bytes": [UInt8](value)])
      peripheral.respond(to: request, withResult: .success)
    }
  }
  public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                didSubscribeTo characteristic: CBCharacteristic) {
    guard let service = gattService,
          characteristic.uuid == (try? characteristicUuid(service.uuid, increment: 2)) else { return }
    if gattServerEndpointByCentral[central.identifier] != nil {
      print("[LocalPeerConnections] duplicate server subscription central=\(central.identifier.uuidString)")
      return
    }
    let endpointId = "server-\(nextServerEndpointId)"
    nextServerEndpointId += 1
    gattServerCentrals[central.identifier] = central
    gattServerEndpointByCentral[central.identifier] = endpointId
    gattServerCentralByEndpoint[endpointId] = central.identifier
    let generation = nextGattGeneration
    nextGattGeneration += 1
    gattServerGenerations[endpointId] = generation
    eventSink?(["type": "gattConnected", "endpointId": endpointId,
                "localRole": "peripheral", "platformSafeWriteSize": 20,
                "connectionGeneration": generation])
  }
  public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                didUnsubscribeFrom characteristic: CBCharacteristic) {
    guard let endpointId = gattServerEndpointByCentral.removeValue(forKey: central.identifier) else { return }
    gattServerCentralByEndpoint.removeValue(forKey: endpointId)
    gattServerCentrals.removeValue(forKey: central.identifier)
    let generation = gattServerGenerations.removeValue(forKey: endpointId)
    eventSink?(["type": "gattDisconnected", "endpointId": endpointId,
                "connectionGeneration": generation as Any])
  }
  public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    // Dart owns the bounded fragment queue and will retry only after an
    // explicit writable signal.
    eventSink?(["type": "gattWritable"])
  }

  private func ensureBluetoothManagers() {
    let initialize = {
      if self.central == nil {
        self.central = CBCentralManager(delegate: self, queue: DispatchQueue.main)
        print("[LocalPeerConnections] central manager initialized state=\(self.central.state.rawValue) \(self.authorizationDiagnostics()) appState=\(UIApplication.shared.applicationState.rawValue)")
      }
      if self.peripheral == nil {
        self.peripheral = CBPeripheralManager(delegate: self, queue: DispatchQueue.main)
        print("[LocalPeerConnections] peripheral manager initialized state=\(self.peripheral.state.rawValue) \(self.authorizationDiagnostics()) appState=\(UIApplication.shared.applicationState.rawValue)")
      }
    }
    if Thread.isMainThread {
      initialize()
    } else {
      DispatchQueue.main.sync(execute: initialize)
    }
  }

  private func authorizationDiagnostics() -> String {
    if #available(iOS 13.1, *) {
      return "centralAuthorization=\(CBCentralManager.authorization.rawValue) peripheralAuthorization=\(CBPeripheralManager.authorization.rawValue)"
    }
    return "authorization=unavailable"
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
          let fragment = arguments["fragment"] as? FlutterStandardTypedData,
          let transmission = arguments["transmission"] as? String else {
      throw BackendError("ENDPOINT_LOST", "unknown GATT connection")
    }
    let requestedGeneration = (arguments["connectionGeneration"] as? NSNumber)?.int64Value
    if let centralIdentifier = gattServerCentralByEndpoint[endpointId],
       let central = gattServerCentrals[centralIdentifier], let service = gattService,
       let tx = service.characteristics?.first(where: { $0.uuid == (try? characteristicUuid(service.uuid, increment: 2)) }) as? CBMutableCharacteristic {
      if let requestedGeneration,
         gattServerGenerations[endpointId] != requestedGeneration {
        throw BackendError("ENDPOINT_LOST", "stale GATT connection generation")
      }
      return peripheral.updateValue(fragment.data, for: tx, onSubscribedCentrals: [central])
        ? "submitted" : "temporarilyUnavailable"
    }
    guard let identifier = UUID(uuidString: endpointId) else {
      throw BackendError("ENDPOINT_LOST", "unknown GATT connection")
    }
    guard let client = gattClients[identifier] else {
      throw BackendError("ENDPOINT_LOST", "unknown GATT connection")
    }
    if let requestedGeneration, client.generation != requestedGeneration {
      throw BackendError("ENDPOINT_LOST", "stale GATT connection generation")
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
    let generation = gattClients[peripheral.identifier]?.generation
      ?? expectedGattGenerations[peripheral.identifier]
    expectedGattServices.removeValue(forKey: peripheral.identifier)
    expectedGattGenerations.removeValue(forKey: peripheral.identifier)
    gattClients.removeValue(forKey: peripheral.identifier)
    if let generation { closingGattGenerations[peripheral.identifier] = generation }
    central.cancelPeripheralConnection(peripheral)
    eventSink?(FlutterError(code: "PLATFORM_ERROR", message: message, details: nil))
  }
  private func requirePoweredOn(_ state: CBManagerState) throws {
    // Include the numeric CoreBluetooth state in diagnostics.  In particular,
    // .unknown during manager startup is different from .poweredOff or
    // .unauthorized, and collapsing them made real-device fixture failures
    // impossible to distinguish from a disabled radio.
    switch state {
    case .poweredOn: return
    case .poweredOff: throw BackendError("BLUETOOTH_POWERED_OFF", "Bluetooth is powered off")
    case .unauthorized: throw BackendError("PERMISSION_DENIED", "Bluetooth permission denied")
    case .unsupported: throw BackendError("BLUETOOTH_UNAVAILABLE", "Bluetooth is unsupported")
    default: throw BackendError("BLUETOOTH_UNAVAILABLE", "Bluetooth is unavailable (CoreBluetooth state=\(state.rawValue); \(authorizationDiagnostics()))")
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
    let generation: Int64
  }
}

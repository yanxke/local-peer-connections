#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import Security
import CoreBluetooth

public class LocalPeerConnectionsPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
                                          CBCentralManagerDelegate, CBPeripheralManagerDelegate,
                                          CBPeripheralDelegate {
  private static let identityChannel = "dev.localpeerconnections.local_peer_connections/identity"
  private static let backendChannel = "dev.localpeerconnections.local_peer_connections/backend"
  private static let backendEventsChannel = "dev.localpeerconnections.local_peer_connections/backend_events"
  #if os(macOS)
  // macOS keychain records are shared more broadly than iOS application
  // keychain records. Keep the desktop fixture's identity namespace separate
  // from mobile and older desktop builds; a stale protected record there can
  // block SecItemCopyMatching on the main Flutter thread before LPC starts.
  private static let service = "dev.localpeerconnections.local_peer_connections.identity.macos.v2"
  #else
  private static let service = "dev.localpeerconnections.local_peer_connections.identity"
  #endif
  private static let account = "ed25519_seed_v1"

  private var central: CBCentralManager!
  private var peripheral: CBPeripheralManager!
  private var eventSink: FlutterEventSink?
  // Keychain access can display a macOS authorization prompt and can block
  // inside Security.framework until that prompt is answered. Never perform
  // identity storage on Flutter's main thread: a pending prompt must not
  // freeze the control API, diagnostics, or the app's permission UI.
  private let identityQueue = DispatchQueue(
    label: "dev.localpeerconnections.identity-storage",
    qos: .userInitiated)
  private var gattService: CBMutableService?
  private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
  private var expectedGattServices: [UUID: CBUUID] = [:]
  private var expectedGattGenerations: [UUID: Int64] = [:]
  private var closingGattGenerations: [UUID: Int64] = [:]
  // CoreBluetooth can report a second didDisconnect callback for a canceled
  // generation after the replacement GATT connection has already connected.
  // The callback has no native generation token, so retain a short bounded
  // grace window after identifying the first stale callback. This prevents a
  // late old-generation callback from tearing down the newly resumed link;
  // the window is deliberately short so a real disconnect is still reported.
  private var staleDisconnectGraceUntil: [UUID: Date] = [:]
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
  private var gattServerLastActivity: [String: Date] = [:]
  private var pendingServerUnsubscribeChecks: [UUID: DispatchWorkItem] = [:]
  // CoreBluetooth has no API for a peripheral to cancel a remote central's
  // subscription.  Keep a server endpoint marked as closing until the
  // central's unsubscribe callback arrives (or the bounded grace period
  // expires), instead of deleting the mapping immediately.  Otherwise a
  // rejected RESUME candidate can leave CoreBluetooth subscribed to the old
  // link while the remote runtime opens a fresh probe; the new subscription
  // is then silently omitted and reconnect loops until the logical timeout.
  private var closingServerEndpoints: Set<String> = []
  private var serverCloseCleanup: [String: DispatchWorkItem] = [:]
  // CoreBluetooth does not always deliver peripheralManagerIsReady after a
  // rapid unsubscribe/subscribe transition. Keep at most one bounded retry
  // signal per endpoint so Dart's existing bounded fragment queue can retry a
  // temporarily unavailable notification without spinning a native queue.
  private var serverWritableRetryTimers: [String: DispatchWorkItem] = [:]
  // CoreBluetooth does not attach a subscription generation to
  // didUnsubscribeFrom. A delayed callback for an old subscription can
  // therefore arrive after a replacement subscription is active. Wait for a
  // bounded heartbeat/activity window before retiring the current endpoint.
  private let serverUnsubscribeGrace: TimeInterval = 3
  // LPC's minimum keepalive dead timeout is 6 seconds. Use a larger native
  // observation window so a quiet but healthy link is not replaced merely
  // because CoreBluetooth delivered another subscription callback. This is
  // only for deciding whether an opaque native binding is orphaned; LPC's
  // authenticated PeerId/liveness rules remain authoritative in Dart.
  private let staleServerBindingAfter: TimeInterval = 10
  private var nextGattGeneration: Int64 = 1
  private var nextServerEndpointId: Int64 = 1
  private var lastDiscoveryLog: [UUID: Date] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LocalPeerConnectionsPlugin()
    #if os(macOS)
    let messenger = registrar.messenger
    #else
    let messenger = registrar.messenger()
    #endif
    let identity = FlutterMethodChannel(name: identityChannel, binaryMessenger: messenger)
    let backend = FlutterMethodChannel(name: backendChannel, binaryMessenger: messenger)
    let events = FlutterEventChannel(name: backendEventsChannel, binaryMessenger: messenger)
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
      identityQueue.async { [weak self] in
        guard let self else { return }
        do {
          let seed = try self.loadOrCreateSeed()
          // Method-channel results are delivered on the engine's main queue;
          // only the protected storage operation is kept off that queue.
          DispatchQueue.main.async { result(seed) }
        } catch {
          // Never replace a malformed or unavailable existing identity silently.
          DispatchQueue.main.async {
            result(FlutterError(code: "IDENTITY_STORAGE", message: "Unable to access protected identity", details: nil))
          }
        }
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
        // A runtime reset recreates the GATT service while CoreBluetooth may
        // still retain CBPeripheral wrappers from the previous service
        // generation. Reusing those wrappers can report didConnect and then
        // tear down immediately after the first HELLO, especially when two
        // Apple runtimes probe each other at once. Active gattClients retain
        // their own references, so invalidate only discovery candidates for
        // this new scan generation.
        self.discoveredPeripherals.removeAll()
        self.lastDiscoveryLog.removeAll()
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
      // A Dart runtime can be recreated while the CoreBluetooth plugin
      // instance is still alive (for example after a Flutter hot restart or
      // an integration-test reset).  Release every central-side link before
      // clearing the bookkeeping; otherwise the next listen/connect sees the
      // old subscription and reports ENDPOINT_BUSY/duplicate subscription.
      for client in gattClients.values {
        central.cancelPeripheralConnection(client.peripheral)
      }
      // A native link can outlive the Dart binding that created it. Cancel
      // every discovered wrapper as well, not only wrappers still represented
      // by gattClients; otherwise a runtime reset can leave CoreBluetooth
      // subscribed to an orphaned peripheral and the next probe can stall
      // without a corresponding Dart endpoint.
      for peripheral in discoveredPeripherals.values {
        central.cancelPeripheralConnection(peripheral)
      }
      gattClients.removeAll()
      expectedGattServices.removeAll()
      expectedGattGenerations.removeAll()
      closingGattGenerations.removeAll()
      staleDisconnectGraceUntil.removeAll()
      gattServerCentrals.removeAll()
      gattServerEndpointByCentral.removeAll()
      gattServerCentralByEndpoint.removeAll()
      gattServerGenerations.removeAll()
      gattServerLastActivity.removeAll()
      pendingServerUnsubscribeChecks.values.forEach { $0.cancel() }
      pendingServerUnsubscribeChecks.removeAll()
      serverCloseCleanup.values.forEach { $0.cancel() }
      serverCloseCleanup.removeAll()
      serverWritableRetryTimers.values.forEach { $0.cancel() }
      serverWritableRetryTimers.removeAll()
      closingServerEndpoints.removeAll()
      // Do not carry a CBPeripheral discovered for the old local service
      // generation into a later runtime start. The wrapper is not an
      // authenticated LPC identity and can retain stale GATT service state.
      discoveredPeripherals.removeAll()
      lastDiscoveryLog.removeAll()
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
        if let serverEndpoint = self.gattServerEndpointByCentral[identifier] {
          // CoreBluetooth identifies the same remote device with the
          // peripheral UUID on the central side and the CBCentral UUID on the
          // peripheral side. If an inbound server link is already present,
          // opening a second central link to that same physical device makes
          // iOS/macOS deliver crossed subscribe/disconnect callbacks and can
          // tear down the healthy link. This is only same-device transport
          // arbitration; the authenticated LPC PeerId still decides logical
          // ownership, and probes for other devices remain independent.
          print("[LocalPeerConnections] reject duplicate central candidate endpoint=\(endpointId) serverEndpoint=\(serverEndpoint) has a server link")
          throw BackendError("ENDPOINT_BUSY", "GATT endpoint already has a server link")
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
    case "associateGattPeer":
      // CoreBluetooth does not expose the Android shared-ACL teardown hazard,
      // but accept the common lifecycle call so Dart can use authenticated
      // endpoint association uniformly on every platform.
      result(nil)
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
        // remote central. Keep a bounded closing marker so a replacement
        // subscription from that same central can be recognized even if the
        // platform delays didUnsubscribeFrom.
        if let centralIdentifier = self.gattServerCentralByEndpoint[endpointId] {
          let currentGeneration = self.gattServerGenerations[endpointId]
          if let requestedGeneration, let currentGeneration,
             requestedGeneration != currentGeneration {
            let currentText = String(currentGeneration)
            print("[LocalPeerConnections] ignore stale close endpoint=\(endpointId) generation=\(requestedGeneration) current=\(currentText)")
            return
          }
          self.closingServerEndpoints.insert(endpointId)
          self.pendingServerUnsubscribeChecks.removeValue(forKey: centralIdentifier)?.cancel()
          self.serverCloseCleanup.removeValue(forKey: endpointId)?.cancel()
          let cleanup = DispatchWorkItem { [weak self] in
            self?.retireClosingServerEndpoint(endpointId)
          }
          self.serverCloseCleanup[endpointId] = cleanup
          DispatchQueue.main.asyncAfter(
            deadline: .now() + self.serverUnsubscribeGrace,
            execute: cleanup)
          // CoreBluetooth does not provide a per-central cancel operation for
          // peripheral links. When this is the only server-side link, rebuild
          // the service immediately so the remote central cannot remain
          // subscribed to the closed characteristic while opening its fresh
          // known-peer probe. Do not do this when another server link is
          // active: resetting the shared service would unnecessarily disrupt
          // unrelated authenticated peers.
          if let serviceUuid = self.activeServiceUuid,
             self.gattServerGenerations.keys.allSatisfy({
               self.closingServerEndpoints.contains($0)
             }) {
            try? self.listenGatt(serviceUuid)
          }
          print("[LocalPeerConnections] marked server endpoint closing endpoint=\(endpointId)")
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
        let currentGeneration = self.gattClients[identifier]?.generation
          ?? self.expectedGattGenerations[identifier]
          ?? self.closingGattGenerations[identifier]
        if let requestedGeneration, let currentGeneration,
           requestedGeneration != currentGeneration {
          let currentText = String(currentGeneration)
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
          self.discoveredPeripherals.removeValue(forKey: identifier)
          self.lastDiscoveryLog.removeValue(forKey: identifier)
          self.central.cancelPeripheralConnection(client.peripheral)
        } else if let generation = self.expectedGattGenerations.removeValue(forKey: identifier) {
          self.expectedGattServices.removeValue(forKey: identifier)
          self.closingGattGenerations[identifier] = generation
          let peripheral = self.discoveredPeripherals.removeValue(forKey: identifier)
          self.lastDiscoveryLog.removeValue(forKey: identifier)
          if let peripheral {
            self.central.cancelPeripheralConnection(peripheral)
          }
        } else if let generation = self.closingGattGenerations.removeValue(forKey: identifier) {
          // CoreBluetooth may have delivered didDisconnectPeripheral before
          // the Dart binding cleanup. Keep the native peripheral cancelable
          // until that generation-scoped cleanup arrives; otherwise the next
          // connectGatt can report ENDPOINT_BUSY even though LPC has no live
          // binding in its maps.
          if let requestedGeneration, requestedGeneration != generation {
            self.closingGattGenerations[identifier] = generation
            print("[LocalPeerConnections] ignore stale closing cleanup endpoint=\(endpointId) generation=\(requestedGeneration) current=\(generation)")
            return
          }
          let peripheral = self.discoveredPeripherals.removeValue(forKey: identifier)
          self.lastDiscoveryLog.removeValue(forKey: identifier)
          if let peripheral {
            self.central.cancelPeripheralConnection(peripheral)
          }
        } else {
          self.expectedGattServices.removeValue(forKey: identifier)
          if let peripheral = self.discoveredPeripherals.removeValue(forKey: identifier) {
            self.central.cancelPeripheralConnection(peripheral)
            self.lastDiscoveryLog.removeValue(forKey: identifier)
          }
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
      // The configured service UUID is the only canonical discovery
      // discriminator.  A previous Android fallback accepted any
      // manufacturer payload ending in "LPC1" when CoreBluetooth omitted the
      // service UUID.  That made independent LPC/LPM/LPGE service namespaces
      // appear as each other's nearby devices (often with an old friendly
      // name), and could also make a stale advertiser look like a current
      // peer.  Keep the broad scan for platforms that put the UUID in a scan
      // response, but only surface the endpoint when CoreBluetooth reports
      // this runtime's configured UUID.
      guard advertised.contains(expected) else { return }
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
    let failedGeneration = closingGattGenerations[peripheral.identifier]
      ?? expectedGattGenerations[peripheral.identifier]
    closingGattGenerations.removeValue(forKey: peripheral.identifier)
    expectedGattServices.removeValue(forKey: peripheral.identifier)
    expectedGattGenerations.removeValue(forKey: peripheral.identifier)
    // A failed CoreBluetooth connection can leave the CBPeripheral wrapper
    // carrying stale service/notification state. Drop it so a later
    // advertisement supplies a fresh candidate instead of repeatedly
    // reconnecting a native object that immediately closes.
    discoveredPeripherals.removeValue(forKey: peripheral.identifier)
    lastDiscoveryLog.removeValue(forKey: peripheral.identifier)
    // didFailToConnect is an asynchronous transport event, not a method-call
    // result. Sending FlutterError through the EventChannel terminates the
    // shared stream for every Runtime listener and leaves reconnect/probe
    // state stranded. Translate it to the same generation-scoped disconnect
    // event used by Android and by the normal CoreBluetooth disconnect path.
    print("[LocalPeerConnections] client connection failed endpoint=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "none")")
    eventSink?(["type": "gattDisconnected", "endpointId": peripheral.identifier.uuidString,
                "connectionGeneration": failedGeneration as Any])
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
    guard error == nil, var client = gattClients[peripheral.identifier],
          characteristic.uuid == client.tx.uuid, characteristic.isNotifying else {
      rejectGatt(peripheral, message: error?.localizedDescription ?? "LPC TX subscription failed"); return
    }
    // CoreBluetooth may report the same CCCD/notification state more than
    // once while a reconnect is being unwound. Only the first callback may
    // publish the connection generation; duplicate gattConnected events can
    // otherwise start a second handshake on the same physical link and make
    // the peer parse READY as application data.
    if client.connectedEmitted {
      print("[LocalPeerConnections] duplicate client connected callback ignored endpoint=\(peripheral.identifier.uuidString) generation=\(client.generation)")
      return
    }
    client.connectedEmitted = true
    gattClients[peripheral.identifier] = client
    // Use the smaller capacity for the shared LPC fragmenter. Reliable/control
    // traffic uses Write With Response below, while realtime traffic uses
    // Write Without Response; both modes must fit the same encoded fragment.
    let responseWriteSize = peripheral.maximumWriteValueLength(for: .withResponse)
    let noResponseWriteSize = peripheral.maximumWriteValueLength(for: .withoutResponse)
    eventSink?(["type": "gattConnected", "endpointId": peripheral.identifier.uuidString,
                "localRole": "central", "platformSafeWriteSize": min(responseWriteSize, noResponseWriteSize),
                "physicalEndpointId": peripheral.identifier.uuidString,
                "connectionGeneration": client.generation])
  }

  public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    guard let client = gattClients[peripheral.identifier] else { return }
    eventSink?(["type": "gattWritable", "endpointId": peripheral.identifier.uuidString,
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

  public func peripheral(_ peripheral: CBPeripheral,
                         didModifyServices invalidatedServices: [CBService]) {
    guard let expected = expectedGattServices[peripheral.identifier],
          invalidatedServices.contains(where: { $0.uuid == expected }) else {
      return
    }
    // A remote peripheral can rebuild its service after its Dart runtime is
    // recreated, but CoreBluetooth keeps the central-side CBPeripheral
    // wrapper and old notification subscription alive unless the delegate
    // explicitly invalidates it. Without this callback the central keeps
    // writing to the replacement service while never receiving its TX
    // notifications, so LPC sees a permanently half-open link and cannot
    // start a bounded fresh probe. Treat service invalidation as a
    // generation-scoped transport close; normal discovery then supplies a
    // new wrapper/service binding.
    print("[LocalPeerConnections] client service invalidated endpoint=\(peripheral.identifier.uuidString)")
    rejectGatt(peripheral, message: "LPC GATT service invalidated")
  }

  public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                         error: Error?) {
    guard var client = gattClients[peripheral.identifier], characteristic.uuid == client.rx.uuid else { return }
    // CoreBluetooth permits only one outstanding write-with-response for a
    // characteristic. Release the gate only from this callback so LPC cannot
    // overlap response-required writes during bidirectional traffic.
    client.writeInFlight = false
    gattClients[peripheral.identifier] = client
    if let error {
      NSLog("LocalPeerConnections: GATT write failed endpoint=\(peripheral.identifier.uuidString) error=\(error.localizedDescription)")
      eventSink?(["type": "gattDisconnected", "endpointId": peripheral.identifier.uuidString,
                  "connectionGeneration": client.generation])
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
      staleDisconnectGraceUntil[peripheral.identifier] = Date().addingTimeInterval(2)
      print("[LocalPeerConnections] ignore stale disconnect endpoint=\(peripheral.identifier.uuidString) generation=\(closingGeneration) replacement=\(replacementGeneration)")
      return
    }
    if let graceUntil = staleDisconnectGraceUntil[peripheral.identifier] {
      if graceUntil > Date(), expectedGattGenerations[peripheral.identifier] != nil {
        print("[LocalPeerConnections] ignore duplicate stale disconnect endpoint=\(peripheral.identifier.uuidString)")
        return
      }
      staleDisconnectGraceUntil.removeValue(forKey: peripheral.identifier)
    }
    let generation = closingGattGenerations.removeValue(forKey: peripheral.identifier)
      ?? gattClients[peripheral.identifier]?.generation
      ?? expectedGattGenerations[peripheral.identifier]
    expectedGattServices.removeValue(forKey: peripheral.identifier)
    expectedGattGenerations.removeValue(forKey: peripheral.identifier)
    gattClients.removeValue(forKey: peripheral.identifier)
    // Force the next reconnect to use a CBPeripheral wrapper created by a
    // new discovery callback. CoreBluetooth may otherwise preserve a stale
    // notification subscription across the canceled generation, which is
    // invisible to the portable runtime and causes a repeated HELLO-without-
    // response loop after the remote app restarts.
    discoveredPeripherals.removeValue(forKey: peripheral.identifier)
    lastDiscoveryLog.removeValue(forKey: peripheral.identifier)
    if let generation { closingGattGenerations[peripheral.identifier] = generation }
    staleDisconnectGraceUntil.removeValue(forKey: peripheral.identifier)
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
      // CoreBluetooth can deliver the first RX write before
      // didSubscribeTo after a service rebuild or a rapid reconnect. Create
      // the endpoint lazily and publish gattConnected before the fragment so
      // Dart installs its binding before consuming the first HELLO.
      let endpointId = gattServerEndpointByCentral[request.central.identifier]
        ?? ensureServerEndpoint(for: request.central)
      guard let endpointId else {
        peripheral.respond(to: request, withResult: .requestNotSupported); continue
      }
      pendingServerUnsubscribeChecks.removeValue(forKey: request.central.identifier)?.cancel()
      gattServerLastActivity[endpointId] = Date()
      eventSink?(["type": "gattFragment", "endpointId": endpointId,
                  "connectionGeneration": gattServerGenerations[endpointId] as Any,
                  "bytes": [UInt8](value)])
      peripheral.respond(to: request, withResult: .success)
    }
  }

  private func ensureServerEndpoint(for central: CBCentral) -> String? {
    if let existing = gattServerEndpointByCentral[central.identifier] {
      if closingServerEndpoints.contains(existing) {
        retireClosingServerEndpoint(existing, emitEvent: true)
      } else {
        return existing
      }
    }
    guard gattService != nil else { return nil }
    let endpointId = "server-\(nextServerEndpointId)"
    nextServerEndpointId += 1
    gattServerCentrals[central.identifier] = central
    gattServerEndpointByCentral[central.identifier] = endpointId
    gattServerCentralByEndpoint[endpointId] = central.identifier
    let generation = nextGattGeneration
    nextGattGeneration += 1
    gattServerGenerations[endpointId] = generation
    gattServerLastActivity[endpointId] = Date()
    let platformSafeWriteSize = max(20, central.maximumUpdateValueLength)
    eventSink?(["type": "gattConnected", "endpointId": endpointId,
                "localRole": "peripheral", "platformSafeWriteSize": platformSafeWriteSize,
                "physicalEndpointId": central.identifier.uuidString,
                "connectionGeneration": generation])
    return endpointId
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                didSubscribeTo characteristic: CBCharacteristic) {
    guard let service = gattService,
          characteristic.uuid == (try? characteristicUuid(service.uuid, increment: 2)) else { return }
    if let oldEndpoint = gattServerEndpointByCentral[central.identifier] {
      if closingServerEndpoints.contains(oldEndpoint) {
        // A replacement subscription is the only reliable way for
        // CoreBluetooth to expose a new server-side link after the remote
        // central was canceled. Retire the old endpoint immediately in this
        // explicit close case, even when it has not been idle for the normal
        // stale-binding window.
        retireClosingServerEndpoint(oldEndpoint, emitEvent: true)
      } else {
      pendingServerUnsubscribeChecks.removeValue(forKey: central.identifier)?.cancel()
      let lastActivity = gattServerLastActivity[oldEndpoint] ?? Date()
      let idleFor = Date().timeIntervalSince(lastActivity)
      guard idleFor >= staleServerBindingAfter else {
        print("[LocalPeerConnections] active server subscription retained central=\(central.identifier.uuidString) endpoint=\(oldEndpoint) idleSeconds=\(String(format: "%.1f", idleFor))")
        return
      }
      // CoreBluetooth may keep a peripheral-side subscription after the
      // central has gone away without delivering didUnsubscribeTo promptly.
      // Only replace it after the binding has been idle for the bounded stale
      // window. Replacing every older callback would disconnect a healthy
      // active link and could create an endless subscribe/disconnect loop.
      // Retaining the old opaque handle while it is active is safe because
      // CoreBluetooth has not established a second usable subscription.
      // The endpoint ID is transport-scoped, so retire the old generation
      // before publishing the fresh one; PeerId authentication still happens
      // in the portable LPC runtime.
      let oldGeneration = gattServerGenerations.removeValue(forKey: oldEndpoint)
      gattServerLastActivity.removeValue(forKey: oldEndpoint)
      gattServerCentralByEndpoint.removeValue(forKey: oldEndpoint)
      gattServerEndpointByCentral.removeValue(forKey: central.identifier)
      gattServerCentrals.removeValue(forKey: central.identifier)
      print("[LocalPeerConnections] replacing stale server subscription central=\(central.identifier.uuidString) oldEndpoint=\(oldEndpoint)")
      eventSink?(["type": "gattDisconnected", "endpointId": oldEndpoint,
                  "connectionGeneration": oldGeneration as Any])
      }
    }
    _ = ensureServerEndpoint(for: central)
  }
  public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                didUnsubscribeFrom characteristic: CBCharacteristic) {
    guard let endpointId = gattServerEndpointByCentral[central.identifier] else { return }
    if closingServerEndpoints.contains(endpointId) {
      // The Dart side already closed this endpoint. The callback is used only
      // to release the native mapping so the next subscription can be
      // accepted; emitting another transport event would duplicate the
      // already terminal Dart binding.
      retireClosingServerEndpoint(endpointId)
      return
    }
    guard let generation = gattServerGenerations[endpointId] else { return }
    let observedAt = Date()
    pendingServerUnsubscribeChecks.removeValue(forKey: central.identifier)?.cancel()
    let check = DispatchWorkItem { [weak self] in
      guard let self else { return }
      guard self.gattServerEndpointByCentral[central.identifier] == endpointId,
            self.gattServerGenerations[endpointId] == generation else { return }
      self.pendingServerUnsubscribeChecks.removeValue(forKey: central.identifier)
      let lastActivity = self.gattServerLastActivity[endpointId] ?? .distantPast
      if lastActivity > observedAt {
        // The callback belonged to an older CoreBluetooth subscription. The
        // current endpoint kept exchanging LPC traffic, so retiring it would
        // create a native-only disconnect/reconnect loop.
        print("[LocalPeerConnections] ignore stale server unsubscribe central=\(central.identifier.uuidString) endpoint=\(endpointId)")
        return
      }
      self.gattServerEndpointByCentral.removeValue(forKey: central.identifier)
      self.gattServerCentralByEndpoint.removeValue(forKey: endpointId)
      self.gattServerCentrals.removeValue(forKey: central.identifier)
      self.gattServerGenerations.removeValue(forKey: endpointId)
      self.gattServerLastActivity.removeValue(forKey: endpointId)
      self.eventSink?(["type": "gattDisconnected", "endpointId": endpointId,
                       "connectionGeneration": generation as Any])
    }
    pendingServerUnsubscribeChecks[central.identifier] = check
    DispatchQueue.main.asyncAfter(deadline: .now() + serverUnsubscribeGrace, execute: check)
  }

  private func retireClosingServerEndpoint(_ endpointId: String,
                                           emitEvent: Bool = false) {
    guard closingServerEndpoints.remove(endpointId) != nil else { return }
    serverCloseCleanup.removeValue(forKey: endpointId)?.cancel()
    serverWritableRetryTimers.removeValue(forKey: endpointId)?.cancel()
    let centralIdentifier = gattServerCentralByEndpoint.removeValue(forKey: endpointId)
    if let centralIdentifier,
       gattServerEndpointByCentral[centralIdentifier] == endpointId {
      gattServerEndpointByCentral.removeValue(forKey: centralIdentifier)
      gattServerCentrals.removeValue(forKey: centralIdentifier)
      pendingServerUnsubscribeChecks.removeValue(forKey: centralIdentifier)?.cancel()
    }
    let generation = gattServerGenerations.removeValue(forKey: endpointId)
    gattServerLastActivity.removeValue(forKey: endpointId)
    if emitEvent {
      eventSink?(["type": "gattDisconnected", "endpointId": endpointId,
                  "connectionGeneration": generation as Any])
    }
    print("[LocalPeerConnections] retired closing server endpoint=\(endpointId)")
  }

  private func scheduleServerWritableRetry(_ endpointId: String) {
    guard serverWritableRetryTimers[endpointId] == nil,
          !closingServerEndpoints.contains(endpointId) else { return }
    let retry = DispatchWorkItem { [weak self] in
      guard let self,
            self.gattServerGenerations[endpointId] != nil,
            !self.closingServerEndpoints.contains(endpointId) else { return }
      self.serverWritableRetryTimers.removeValue(forKey: endpointId)
      self.eventSink?(["type": "gattWritable", "endpointId": endpointId,
                       "connectionGeneration": self.gattServerGenerations[endpointId] as Any])
    }
    serverWritableRetryTimers[endpointId] = retry
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: retry)
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
        print("[LocalPeerConnections] central manager initialized state=\(self.central.state.rawValue) \(self.authorizationDiagnostics())")
      }
      if self.peripheral == nil {
        self.peripheral = CBPeripheralManager(delegate: self, queue: DispatchQueue.main)
        print("[LocalPeerConnections] peripheral manager initialized state=\(self.peripheral.state.rawValue) \(self.authorizationDiagnostics())")
      }
    }
    if Thread.isMainThread {
      initialize()
    } else {
      DispatchQueue.main.sync(execute: initialize)
    }
  }

  private func authorizationDiagnostics() -> String {
    #if os(iOS)
    if #available(iOS 13.1, *) {
      return "centralAuthorization=\(CBCentralManager.authorization.rawValue) peripheralAuthorization=\(CBPeripheralManager.authorization.rawValue)"
    }
    return "authorization=unavailable"
    #else
    return "centralAuthorization=\(CBCentralManager.authorization.rawValue) peripheralAuthorization=\(CBPeripheralManager.authorization.rawValue)"
    #endif
  }

  /// Hosts exactly the Section 11 service. The Dart GATT backend remains the
  /// owner of fragment framing and LPC protocol state.
  private func listenGatt(_ serviceUuid: CBUUID) throws {
    // Runtime-owned listener demand is started only after the previous
    // listener demand has been released, but CoreBluetooth can deliver a
    // delayed subscription callback after that release. Clear any orphaned
    // peripheral-side endpoint mappings before installing the new service so
    // a remote central's first HELLO cannot be routed into a binding from the
    // previous Dart runtime generation. The authenticated PeerId arbitration
    // still happens in LPC; this only resets native transport bookkeeping.
    for endpointId in gattServerGenerations.keys {
      eventSink?(["type": "gattDisconnected", "endpointId": endpointId,
                  "connectionGeneration": gattServerGenerations[endpointId] as Any])
    }
    gattServerCentrals.removeAll()
    gattServerEndpointByCentral.removeAll()
    gattServerCentralByEndpoint.removeAll()
    gattServerGenerations.removeAll()
    gattServerLastActivity.removeAll()
    serverCloseCleanup.values.forEach { $0.cancel() }
    serverCloseCleanup.removeAll()
    serverWritableRetryTimers.values.forEach { $0.cancel() }
    serverWritableRetryTimers.removeAll()
    closingServerEndpoints.removeAll()
    pendingServerUnsubscribeChecks.values.forEach { $0.cancel() }
    pendingServerUnsubscribeChecks.removeAll()
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
      let submitted = peripheral.updateValue(
        fragment.data,
        for: tx,
        onSubscribedCentrals: [central]
      )
      if submitted {
        pendingServerUnsubscribeChecks.removeValue(forKey: centralIdentifier)?.cancel()
        serverWritableRetryTimers.removeValue(forKey: endpointId)?.cancel()
        gattServerLastActivity[endpointId] = Date()
      } else {
        scheduleServerWritableRetry(endpointId)
      }
      return submitted ? "submitted" : "temporarilyUnavailable"
    }
    guard let identifier = UUID(uuidString: endpointId) else {
      throw BackendError("ENDPOINT_LOST", "unknown GATT connection")
    }
    guard var client = gattClients[identifier] else {
      throw BackendError("ENDPOINT_LOST", "unknown GATT connection")
    }
    if let requestedGeneration, client.generation != requestedGeneration {
      throw BackendError("ENDPOINT_LOST", "stale GATT connection generation")
    }
    if transmission == "notify" { return "terminalFailure" }
    if transmission == "writeWithoutResponse" {
      // This is the Section 22 realtime path. CoreBluetooth exposes explicit
      // central-side flow control for it; a full transmit window is ordinary
      // bounded backpressure and must leave the LPC write pending.
      if !client.peripheral.canSendWriteWithoutResponse {
        return "temporarilyUnavailable"
      }
      client.peripheral.writeValue(fragment.data, for: client.rx,
        type: .withoutResponse)
      return "submitted"
    }

    // Reliable/control fragments use Write With Response. The response
    // callback is the per-fragment flow-control boundary, preventing a burst
    // of checkpoints and ACK/control frames from filling iOS's no-response
    // central buffer. LPC's own frame/operation ACKs remain authoritative;
    // this platform response only gates the next fragment submission.
    if client.writeInFlight {
      return "temporarilyUnavailable"
    }
    client.writeInFlight = true
    gattClients[identifier] = client
    client.peripheral.writeValue(fragment.data, for: client.rx,
      type: .withResponse)
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
    discoveredPeripherals.removeValue(forKey: peripheral.identifier)
    lastDiscoveryLog.removeValue(forKey: peripheral.identifier)
    if let generation { closingGattGenerations[peripheral.identifier] = generation }
    central.cancelPeripheralConnection(peripheral)
    // This callback is reached after a GATT readiness event, so report a
    // transport failure on the event stream. An EventChannel FlutterError
    // would poison the shared stream and prevent later auto-reconnect
    // candidates from being observed.
    print("[LocalPeerConnections] client GATT rejected endpoint=\(peripheral.identifier.uuidString) reason=\(message)")
    eventSink?(["type": "gattDisconnected", "endpointId": peripheral.identifier.uuidString,
                "connectionGeneration": generation as Any])
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
    let platformQuery = query
    var item: CFTypeRef?
    let status = SecItemCopyMatching(platformQuery as CFDictionary, &item)
    if status == errSecSuccess {
      guard let seed = item as? Data, seed.count == 32 else { throw IdentityStorageError.invalidStoredSeed }
      return seed
    }
    guard status == errSecItemNotFound else { throw IdentityStorageError.keychain(status) }
    var seed = Data(count: 32)
    let randomStatus = seed.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    guard randomStatus == errSecSuccess else { throw IdentityStorageError.keychain(randomStatus) }
    var add = platformQuery
    add.removeValue(forKey: kSecReturnData); add.removeValue(forKey: kSecMatchLimit)
    add[kSecValueData] = seed
    #if os(iOS)
    add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    #endif
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
    var writeInFlight: Bool = false
    var connectedEmitted: Bool = false
  }
}

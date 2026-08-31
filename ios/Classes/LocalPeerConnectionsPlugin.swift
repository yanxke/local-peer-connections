import Flutter
import UIKit
import Security
import CoreBluetooth

public class LocalPeerConnectionsPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
                                          CBCentralManagerDelegate, CBPeripheralManagerDelegate {
  private static let identityChannel = "dev.localpeerconnections.local_peer_connections/identity"
  private static let backendChannel = "dev.localpeerconnections.local_peer_connections/backend"
  private static let backendEventsChannel = "dev.localpeerconnections.local_peer_connections/backend_events"
  private static let service = "dev.localpeerconnections.local_peer_connections.identity"
  private static let account = "ed25519_seed_v1"

  private var central: CBCentralManager!
  private var peripheral: CBPeripheralManager!
  private var eventSink: FlutterEventSink?

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
      }
    case "stopAdvertising":
      peripheral.stopAdvertising(); result(nil)
    case "startDiscovery":
      backend(call, result) { arguments in
        try self.requirePoweredOn(self.central.state)
        self.central.scanForPeripherals(withServices: [try self.serviceUuid(arguments)], options: nil)
      }
    case "stopDiscovery":
      central.stopScan(); result(nil)
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

  public func centralManagerDidUpdateState(_ central: CBCentralManager) {}
  public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {}
  public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                             advertisementData: [String : Any], rssi RSSI: NSNumber) {
    eventSink?(["type": "endpointFound", "endpointId": peripheral.identifier.uuidString,
                "localName": advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                "rssi": RSSI.intValue])
  }
  public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error {
      eventSink?(FlutterError(code: "ADVERTISING_UNAVAILABLE", message: error.localizedDescription, details: nil))
    }
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

  private func serviceUuid(_ arguments: [String: Any]) throws -> CBUUID {
    guard let bytes = arguments["serviceUuid"] as? FlutterStandardTypedData, bytes.data.count == 16 else {
      throw BackendError("PLATFORM_ERROR", "serviceUuid must be 16 bytes")
    }
    return CBUUID(data: bytes.data)
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
  private struct BackendError: Error { let code: String; let message: String }

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
}

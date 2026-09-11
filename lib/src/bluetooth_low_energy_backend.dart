import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/services.dart';

import 'gatt_backend_connection.dart';
import 'platform_ble_events.dart';
import 'protocol/capabilities.dart';
import 'types.dart';

/// Windows BLE transport adapter backed by the federated
/// `bluetooth_low_energy` plugin.
///
/// The plugin owns WinRT scanning/GATT calls. This adapter owns the LPC
/// contract around those calls: opaque endpoint IDs, connection generations,
/// canonical Section 11 service construction, and fragment-level events.
class BluetoothLowEnergyBackend {
  BluetoothLowEnergyBackend({this.logger}) {
    _central = CentralManager();
    _peripheral = PeripheralManager();
    _subscriptions.add(_central.discovered.listen(_onDiscovered));
    _subscriptions.add(
      _central.connectionStateChanged.listen(_onCentralConnectionState),
    );
    _subscriptions.add(
      _central.characteristicNotified.listen(_onCharacteristicNotified),
    );
    _subscriptions.add(
      _peripheral.characteristicWriteRequested.listen(
        _onCharacteristicWriteRequested,
      ),
    );
    _subscriptions.add(
      _peripheral.characteristicNotifyStateChanged.listen(
        _onCharacteristicNotifyStateChanged,
      ),
    );
  }

  final void Function(String message)? logger;
  late final CentralManager _central;
  late final PeripheralManager _peripheral;
  final StreamController<PlatformBleEvent> _events =
      StreamController<PlatformBleEvent>.broadcast(sync: true);
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];
  final Map<String, Peripheral> _discovered = <String, Peripheral>{};
  final Map<String, _WindowsCentralLink> _centralLinks =
      <String, _WindowsCentralLink>{};
  final Map<String, _WindowsPeripheralLink> _peripheralLinks =
      <String, _WindowsPeripheralLink>{};
  final Map<String, String> _peripheralEndpointByCentral = <String, String>{};
  int _nextGeneration = 1;
  int _nextServerEndpoint = 1;
  UUID? _configuredServiceUuid;
  _WindowsPeripheralService? _service;

  Stream<PlatformBleEvent> get events => _events.stream;

  void _log(String message) {
    try {
      logger?.call(message);
    } on Object {
      // Diagnostics must never affect the transport event stream.
    }
  }

  Future<LocalRuntimeCapabilityBitmap> queryCapabilities() async {
    final capabilities = <LocalRuntimeCapability>[];
    if (_central.state != BluetoothLowEnergyState.unsupported) {
      capabilities
        ..add(LocalRuntimeCapability.bleScan)
        ..add(LocalRuntimeCapability.gattCentral);
    }
    if (_peripheral.state != BluetoothLowEnergyState.unsupported) {
      capabilities
        ..add(LocalRuntimeCapability.bleAdvertise)
        ..add(LocalRuntimeCapability.gattPeripheral);
    }
    return LocalRuntimeCapabilityBitmap(capabilities);
  }

  Future<void> startAdvertising(
    List<int> serviceUuid, {
    String? localName,
  }) async {
    final uuid = _uuid(serviceUuid);
    // Windows' BLE peripheral API does not accept a per-advertisement local
    // name. Section 33.1 permits the platform to omit that presentation hint.
    // bluetooth_low_energy starts the GATT service provider's advertisement
    // from addService on Windows. Starting its separate advertisement
    // publisher here would attempt a second publisher start and returns
    // E_INVALIDARG ("The parameter is incorrect") on WinRT.
    if (_service != null) {
      _log('Windows GATT service advertisement already active');
      return;
    }
    _log('Windows peripheral startAdvertising');
    await _run(
      () => _peripheral.startAdvertising(
        Advertisement(serviceUUIDs: <UUID>[uuid]),
      ),
    );
  }

  Future<void> stopAdvertising() => _run<void>(_peripheral.stopAdvertising);

  Future<void> startDiscovery(List<int> serviceUuid) async {
    _configuredServiceUuid = _uuid(serviceUuid);
    await _run(
      () => _central.startDiscovery(
        serviceUUIDs: <UUID>[_configuredServiceUuid!],
      ),
    );
  }

  Future<void> stopDiscovery() => _run<void>(_central.stopDiscovery);

  Future<void> listenGatt(List<int> serviceUuid) async {
    final uuid = _uuid(serviceUuid);
    final rx = GATTCharacteristic.mutable(
      uuid: UUID(_derivedUuid(serviceUuid, 1)),
      properties: <GATTCharacteristicProperty>[
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.writeWithoutResponse,
      ],
      permissions: <GATTCharacteristicPermission>[
        GATTCharacteristicPermission.write,
      ],
      descriptors: const <GATTDescriptor>[],
    );
    final tx = GATTCharacteristic.mutable(
      uuid: UUID(_derivedUuid(serviceUuid, 2)),
      properties: <GATTCharacteristicProperty>[
        GATTCharacteristicProperty.notify,
      ],
      permissions: const <GATTCharacteristicPermission>[],
      descriptors: const <GATTDescriptor>[],
    );
    final control = GATTCharacteristic.mutable(
      uuid: UUID(_derivedUuid(serviceUuid, 3)),
      properties: <GATTCharacteristicProperty>[
        GATTCharacteristicProperty.read,
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.notify,
      ],
      permissions: <GATTCharacteristicPermission>[
        GATTCharacteristicPermission.read,
        GATTCharacteristicPermission.write,
      ],
      descriptors: const <GATTDescriptor>[],
    );
    final service = GATTService(
      uuid: uuid,
      isPrimary: true,
      includedServices: const <GATTService>[],
      characteristics: <GATTCharacteristic>[rx, tx, control],
    );

    _log('Windows peripheral removeAllServices');
    await _run(_peripheral.removeAllServices);
    _log('Windows peripheral addService');
    await _run(() => _peripheral.addService(service));
    _configuredServiceUuid = uuid;
    _service = _WindowsPeripheralService(
      service: service,
      rx: rx,
      tx: tx,
      control: control,
    );
  }

  Future<void> stopGatt() async {
    final active = _peripheralLinks.values.toList(growable: false);
    for (final link in active) {
      _emitDisconnected(link.endpointId, link.generation);
    }
    _peripheralLinks.clear();
    _peripheralEndpointByCentral.clear();
    _service = null;
    await _run(_peripheral.removeAllServices);
  }

  Future<void> connectGatt(String discoveryEndpointId) async {
    final peripheral = _discovered[discoveryEndpointId];
    if (peripheral == null) {
      throw const LpcException(
        LpcErrorCode.endpointLost,
        'unknown discovery endpoint',
      );
    }
    if (_centralLinks.containsKey(discoveryEndpointId)) {
      throw const LpcException(
        LpcErrorCode.platformError,
        'GATT endpoint already connected',
      );
    }
    final serviceUuid = _configuredServiceUuid;
    if (serviceUuid == null) {
      throw const LpcException(
        LpcErrorCode.unsupportedCapability,
        'no configured LPC GATT service UUID',
      );
    }
    final generation = _nextGeneration++;
    var connected = false;
    try {
      await _run(() => _central.connect(peripheral));
      connected = true;
      final services = await _run(() => _central.discoverGATT(peripheral));
      final service = services.where((value) => value.uuid == serviceUuid);
      if (service.length != 1) {
        throw const LpcException(
          LpcErrorCode.protocolMismatch,
          'LPC GATT service missing',
        );
      }
      final characteristics = service.single.characteristics;
      final rx = _characteristic(
        characteristics,
        _derivedUuid(serviceUuid.value, 1),
      );
      final tx = _characteristic(
        characteristics,
        _derivedUuid(serviceUuid.value, 2),
      );
      final control = _characteristic(
        characteristics,
        _derivedUuid(serviceUuid.value, 3),
      );
      if (rx == null || tx == null || control == null) {
        throw const LpcException(
          LpcErrorCode.protocolMismatch,
          'LPC GATT characteristics missing',
        );
      }
      await _run(
        () =>
            _central.setCharacteristicNotifyState(peripheral, tx, state: true),
      );
      _centralLinks[discoveryEndpointId] = _WindowsCentralLink(
        peripheral: peripheral,
        rx: rx,
        tx: tx,
        control: control,
        generation: generation,
      );
      _events.add(
        PlatformGattConnected(
          discoveryEndpointId,
          'central',
          platformSafeWriteSize: 20,
          connectionGeneration: generation,
        ),
      );
    } on LpcException {
      if (connected) await _disconnectQuietly(peripheral);
      rethrow;
    } on Object catch (error) {
      if (connected) await _disconnectQuietly(peripheral);
      throw _asLpcError(error, fallback: LpcErrorCode.endpointLost);
    }
  }

  Future<void> _disconnectQuietly(Peripheral peripheral) async {
    try {
      await _central.disconnect(peripheral);
    } on Object catch (error) {
      _log('Windows central cleanup disconnect failed error=$error');
    }
  }

  Future<GattFragmentSubmission> submitGattFragment(
    String endpointId,
    Uint8List fragment, {
    required GattFragmentTransmission transmission,
    int? connectionGeneration,
  }) async {
    final centralLink = _centralLinks[endpointId];
    if (centralLink != null) {
      if (connectionGeneration != null &&
          connectionGeneration != centralLink.generation) {
        return GattFragmentSubmission.terminalFailure;
      }
      if (transmission == GattFragmentTransmission.notify) {
        return GattFragmentSubmission.terminalFailure;
      }
      try {
        await _central.writeCharacteristic(
          centralLink.peripheral,
          centralLink.rx,
          value: fragment,
          type: transmission == GattFragmentTransmission.writeWithoutResponse
              ? GATTCharacteristicWriteType.withoutResponse
              : GATTCharacteristicWriteType.withResponse,
        );
        return GattFragmentSubmission.submitted;
      } on Object catch (error) {
        _log(
          'Windows central fragment submission failed endpoint=$endpointId error=$error',
        );
        return GattFragmentSubmission.terminalFailure;
      }
    }

    final peripheralLink = _peripheralLinks[endpointId];
    if (peripheralLink == null ||
        (connectionGeneration != null &&
            connectionGeneration != peripheralLink.generation)) {
      return GattFragmentSubmission.terminalFailure;
    }
    // Ordinary control/data traffic reaches a peripheral as NORMAL; the
    // backend selects notify because the local role is already known.
    if (transmission == GattFragmentTransmission.writeWithoutResponse) {
      return GattFragmentSubmission.terminalFailure;
    }
    try {
      await _peripheral.notifyCharacteristic(
        peripheralLink.central,
        peripheralLink.tx,
        value: fragment,
      );
      return GattFragmentSubmission.submitted;
    } on Object catch (error) {
      _log(
        'Windows peripheral fragment submission failed endpoint=$endpointId error=$error',
      );
      return GattFragmentSubmission.terminalFailure;
    }
  }

  Future<void> closeGattConnection(
    String endpointId, {
    int? connectionGeneration,
  }) async {
    final centralLink = _centralLinks[endpointId];
    if (centralLink != null) {
      if (connectionGeneration != null &&
          connectionGeneration != centralLink.generation) {
        return;
      }
      _centralLinks.remove(endpointId);
      await _run(() => _central.disconnect(centralLink.peripheral));
      return;
    }
    final peripheralLink = _peripheralLinks[endpointId];
    if (peripheralLink == null) return;
    if (connectionGeneration != null &&
        connectionGeneration != peripheralLink.generation) {
      return;
    }
    _peripheralLinks.remove(endpointId);
    _peripheralEndpointByCentral.remove(peripheralLink.central.uuid.toString());
  }

  void _onDiscovered(DiscoveredEventArgs event) {
    final endpointId = event.peripheral.uuid.toString();
    _discovered[endpointId] = event.peripheral;
    String? localName;
    try {
      localName = event.advertisement.name;
    } on Object {
      // The Windows plugin does not expose a per-advertisement local name.
    }
    _events.add(
      PlatformEndpointFound(endpointId, rssi: event.rssi, localName: localName),
    );
  }

  void _onCentralConnectionState(
    PeripheralConnectionStateChangedEventArgs event,
  ) {
    if (event.state != ConnectionState.disconnected) return;
    final endpointId = event.peripheral.uuid.toString();
    final link = _centralLinks.remove(endpointId);
    if (link != null) _emitDisconnected(endpointId, link.generation);
  }

  void _onCharacteristicNotified(GATTCharacteristicNotifiedEventArgs event) {
    final endpointId = event.peripheral.uuid.toString();
    final link = _centralLinks[endpointId];
    if (link == null || event.characteristic.uuid != link.tx.uuid) return;
    _events.add(
      PlatformGattFragment(
        endpointId,
        event.value,
        connectionGeneration: link.generation,
      ),
    );
  }

  void _onCharacteristicWriteRequested(
    GATTCharacteristicWriteRequestedEventArgs event,
  ) {
    unawaited(_handleCharacteristicWriteRequested(event));
  }

  Future<void> _handleCharacteristicWriteRequested(
    GATTCharacteristicWriteRequestedEventArgs event,
  ) async {
    final service = _service;
    if (service == null) return;
    // Capture the value before acknowledging the WinRT request. The package
    // keeps the native request alive through a deferral, but it becomes
    // unusable as soon as RespondWriteRequest completes. In particular, the
    // Android write-with-response path can immediately issue the next
    // fragment, so emitting after an unawaited response races that lifetime.
    final value = Uint8List.fromList(event.request.value);
    final characteristicUuid = event.characteristic.uuid;
    await _respondWrite(event.request);
    if (characteristicUuid != service.rx.uuid) return;
    final link = _ensurePeripheralLink(event.central);
    _events.add(
      PlatformGattFragment(
        link.endpointId,
        value,
        connectionGeneration: link.generation,
      ),
    );
  }

  Future<void> _respondWrite(GATTWriteRequest request) async {
    try {
      await _peripheral.respondWriteRequest(request);
    } on Object catch (error) {
      _log('Windows GATT write response failed error=$error');
    }
  }

  void _onCharacteristicNotifyStateChanged(
    GATTCharacteristicNotifyStateChangedEventArgs event,
  ) {
    final service = _service;
    if (service == null || event.characteristic.uuid != service.tx.uuid) {
      return;
    }
    final centralKey = event.central.uuid.toString();
    if (event.state) {
      _ensurePeripheralLink(event.central);
    } else {
      final endpointId = _peripheralEndpointByCentral.remove(centralKey);
      if (endpointId != null) {
        final link = _peripheralLinks.remove(endpointId);
        if (link != null) _emitDisconnected(endpointId, link.generation);
      }
    }
  }

  _WindowsPeripheralLink _ensurePeripheralLink(Central central) {
    final centralKey = central.uuid.toString();
    final existingEndpoint = _peripheralEndpointByCentral[centralKey];
    if (existingEndpoint != null) return _peripheralLinks[existingEndpoint]!;
    final service = _service;
    if (service == null) {
      throw const LpcException(
        LpcErrorCode.unsupportedCapability,
        'LPC GATT service is not listening',
      );
    }
    final endpointId = 'server-${_nextServerEndpoint++}';
    final link = _WindowsPeripheralLink(
      endpointId: endpointId,
      central: central,
      tx: service.tx,
      generation: _nextGeneration++,
    );
    _peripheralLinks[endpointId] = link;
    _peripheralEndpointByCentral[centralKey] = endpointId;
    _events.add(
      PlatformGattConnected(
        endpointId,
        'peripheral',
        platformSafeWriteSize: 20,
        connectionGeneration: link.generation,
      ),
    );
    return link;
  }

  void _emitDisconnected(String endpointId, int generation) {
    _events.add(
      PlatformGattDisconnected(endpointId, connectionGeneration: generation),
    );
  }

  GATTCharacteristic? _characteristic(
    List<GATTCharacteristic> characteristics,
    List<int> uuid,
  ) {
    for (final characteristic in characteristics) {
      if (characteristic.uuid == UUID(uuid)) return characteristic;
    }
    return null;
  }

  UUID _uuid(List<int> bytes) => UUID(bytes);

  List<int> _derivedUuid(List<int> serviceUuid, int increment) {
    final derived = List<int>.from(serviceUuid);
    if (derived.length != 16 || derived[3] > 0xff - increment) {
      throw const LpcException(
        LpcErrorCode.invalidArgument,
        'invalid LPC service UUID',
      );
    }
    derived[3] += increment;
    return derived;
  }

  Future<T> _run<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on LpcException {
      rethrow;
    } on Object catch (error) {
      throw _asLpcError(error);
    }
  }

  LpcException _asLpcError(
    Object error, {
    LpcErrorCode fallback = LpcErrorCode.platformError,
  }) {
    final text = error is PlatformException
        ? '${error.code} ${error.message ?? ''}'
        : error.toString();
    final normalized = text.toLowerCase();
    final code =
        normalized.contains('unauthorized') || normalized.contains('permission')
        ? LpcErrorCode.permissionDenied
        : normalized.contains('poweredoff') ||
              normalized.contains('powered off')
        ? LpcErrorCode.bluetoothPoweredOff
        : normalized.contains('unsupported')
        ? LpcErrorCode.unsupportedCapability
        : fallback;
    return LpcException(code, text);
  }
}

class _WindowsPeripheralService {
  const _WindowsPeripheralService({
    required this.service,
    required this.rx,
    required this.tx,
    required this.control,
  });

  final GATTService service;
  final GATTCharacteristic rx;
  final GATTCharacteristic tx;
  final GATTCharacteristic control;
}

class _WindowsCentralLink {
  const _WindowsCentralLink({
    required this.peripheral,
    required this.rx,
    required this.tx,
    required this.control,
    required this.generation,
  });

  final Peripheral peripheral;
  final GATTCharacteristic rx;
  final GATTCharacteristic tx;
  final GATTCharacteristic control;
  final int generation;
}

class _WindowsPeripheralLink {
  const _WindowsPeripheralLink({
    required this.endpointId,
    required this.central,
    required this.tx,
    required this.generation,
  });

  final String endpointId;
  final Central central;
  final GATTCharacteristic tx;
  final int generation;
}

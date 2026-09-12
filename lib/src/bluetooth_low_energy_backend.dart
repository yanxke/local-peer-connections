import 'dart:async';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/services.dart';

import 'gatt_backend_connection.dart';
import 'platform_ble_events.dart';
import 'protocol/capabilities.dart';
import 'protocol/gatt_fragment.dart';
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
    // Keep both write properties on every platform. Windows GATT server does
    // not reliably raise WriteRequested for a characteristic advertised only
    // with WriteWithoutResponse, even though its central accepts that mode.
    // Normal/control writes use the response-bearing path for ordering, while
    // realtime central writes may select response-free mode explicitly. The
    // characteristic remains discoverable by Android, iOS, and Windows.
    final rxProperties = <GATTCharacteristicProperty>[
      GATTCharacteristicProperty.write,
      GATTCharacteristicProperty.writeWithoutResponse,
    ];
    final rx = GATTCharacteristic.mutable(
      uuid: UUID(_derivedUuid(serviceUuid, 1)),
      properties: rxProperties,
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
      link.dispose();
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
    peripheralLink.dispose();
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
    // Start the native response before handing the fragment to the protocol.
    // The value has already been copied, so the protocol can consume it while
    // the Windows GATT request is being completed. Waiting for the response
    // before emitting made the Android write-with-response path hold each
    // request across a Flutter round trip and eventually return GATT_ERROR
    // under sustained traffic.
    final response = _respondWrite(event.request);
    if (characteristicUuid == service.rx.uuid) {
      final link = _ensurePeripheralLink(event.central);
      link.addIncomingFragment(value);
    }
    await response;
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
        if (link != null) {
          link.dispose();
          _emitDisconnected(endpointId, link.generation);
        }
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
    final generation = _nextGeneration++;
    final link = _WindowsPeripheralLink(
      endpointId: endpointId,
      central: central,
      tx: service.tx,
      generation: generation,
      onIncomingFragment: (fragment) {
        _events.add(
          PlatformGattFragment(
            endpointId,
            fragment,
            connectionGeneration: generation,
          ),
        );
      },
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
  _WindowsPeripheralLink({
    required this.endpointId,
    required this.central,
    required this.tx,
    required this.generation,
    required void Function(Uint8List fragment) onIncomingFragment,
  }) : _incomingOrderer = WindowsGattFragmentOrderer(
         onDeliver: onIncomingFragment,
       );

  final String endpointId;
  final Central central;
  final GATTCharacteristic tx;
  final int generation;
  final WindowsGattFragmentOrderer _incomingOrderer;

  void addIncomingFragment(Uint8List fragment) =>
      _incomingOrderer.add(fragment);

  void dispose() => _incomingOrderer.dispose();
}

/// Repairs the Windows peripheral callback ordering for one LPC GATT link.
///
/// Bluetooth's ATT bearer is ordered. Some versions of the Windows plugin can
/// dispatch completed Write Without Response callbacks as `0, 2, 1` even when
/// they arrived in ATT order. This adapter restores the Section 12 order
/// before the protocol reassembler sees the fragments. It does not relax any
/// LPC validation: malformed fragments, duplicates, a full repair buffer, or
/// a two-second gap are passed to the normal reassembler as invalid input.
class WindowsGattFragmentOrderer {
  WindowsGattFragmentOrderer({
    required void Function(Uint8List fragment) onDeliver,
    this.maxBufferedFragments = 512,
    this.reorderTimeout = const Duration(seconds: 2),
  }) : assert(maxBufferedFragments > 0),
       assert(!reorderTimeout.isNegative && reorderTimeout > Duration.zero),
       _onDeliver = onDeliver;

  final void Function(Uint8List fragment) _onDeliver;

  /// The bound prevents a faulty platform callback source from accumulating
  /// unbounded raw GATT data. The repair path is ordinarily only one delayed
  /// callback; this larger cap permits a short scheduler burst without
  /// changing LPC's existing frame-size or queue limits.
  final int maxBufferedFragments;

  /// Section 12's no-progress limit for an incomplete GATT frame.
  final Duration reorderTimeout;

  final List<_WindowsGattFrameOrder> _frames = <_WindowsGattFrameOrder>[];
  var _bufferedFragmentCount = 0;
  Timer? _gapTimer;

  void add(Uint8List encoded) {
    late final GattFragment fragment;
    try {
      fragment = GattFragment.decode(encoded);
    } on Object {
      _invalidate(encoded);
      return;
    }
    final pending = _PendingWindowsGattFragment(fragment, encoded);

    if (fragment.start) {
      if (fragment.sequence != 0) {
        _invalidate(encoded);
        return;
      }
      if (_frames.isEmpty) {
        _frames.add(_WindowsGattFrameOrder(start: pending));
      } else if (_frames.first.start == null) {
        // A callback for fragment 1 can run before callback 0. Preserve these
        // pre-start candidates and drain them immediately after START arrives.
        _frames.first.setStart(pending);
        _frames.first.startBuffered = true;
        _bufferedFragmentCount++;
      } else if (!_queueFrameStart(pending)) {
        _invalidate(encoded);
        return;
      }
      _advance();
      _updateGapTimer();
      return;
    }

    final target = _targetFor(fragment.sequence);
    if (target == null || !_buffer(target, pending)) {
      _invalidate(encoded);
      return;
    }
    _advance();
    _updateGapTimer();
  }

  _WindowsGattFrameOrder? _targetFor(int sequence) {
    if (_frames.isEmpty) {
      final frame = _WindowsGattFrameOrder();
      _frames.add(frame);
      return frame;
    }
    final active = _frames.first;
    if (!active.started || sequence >= active.nextSequence!) return active;

    // An early START identifies the following frame. Once it exists, a lower
    // sequence belongs to that queued frame rather than being a duplicate of
    // the active one. This is the observed WinRT `...8, 0, 9...` callback
    // race; ATT itself still carries `...8, 9, 0...`.
    return _frames.length > 1 ? _frames[1] : null;
  }

  bool _queueFrameStart(_PendingWindowsGattFragment pending) {
    if (_bufferedFragmentCount >= maxBufferedFragments) return false;
    _frames.add(_WindowsGattFrameOrder(start: pending, startBuffered: true));
    _bufferedFragmentCount++;
    return true;
  }

  bool _buffer(
    _WindowsGattFrameOrder target,
    _PendingWindowsGattFragment pending,
  ) {
    final existing = target.pending[pending.fragment.sequence];
    if (existing != null) {
      return _sameBytes(existing.encoded, pending.encoded);
    }
    if (_bufferedFragmentCount >= maxBufferedFragments) return false;
    target.pending[pending.fragment.sequence] = pending;
    _bufferedFragmentCount++;
    return true;
  }

  void _advance() {
    while (_frames.isNotEmpty) {
      final active = _frames.first;
      final start = active.start;
      if (start == null) return;
      if (!active.started) {
        active.started = true;
        if (active.startBuffered) _bufferedFragmentCount--;
        _onDeliver(start.encoded);
        if (start.fragment.end) {
          _frames.removeAt(0);
          continue;
        }
        active.nextSequence = 1;
      }
      var completed = false;
      while (true) {
        final next = active.pending.remove(active.nextSequence);
        if (next == null) break;
        _bufferedFragmentCount--;
        _onDeliver(next.encoded);
        if (next.fragment.end) {
          _frames.removeAt(0);
          completed = true;
          break;
        }
        active.nextSequence = active.nextSequence! + 1;
      }
      if (!completed) return;
    }
  }

  void _expireGap() {
    _gapTimer = null;
    if (_frames.isEmpty || _bufferedFragmentCount == 0) return;
    // Do not manufacture an LPC error event here. Delivering one retained,
    // non-contiguous fragment delegates invalid-frame handling to the existing
    // Section 12 reassembler, exactly as an unrepaired platform event would.
    final first = _firstBufferedFragment();
    _clear();
    _onDeliver(first.encoded);
  }

  _PendingWindowsGattFragment _firstBufferedFragment() {
    for (final frame in _frames) {
      final start = frame.start;
      if (start != null && frame.startBuffered && !frame.started) return start;
      if (frame.pending.isNotEmpty) {
        return frame.pending.values.reduce(
          (left, right) =>
              left.fragment.sequence < right.fragment.sequence ? left : right,
        );
      }
    }
    throw StateError('no buffered Windows GATT fragment');
  }

  void _invalidate(Uint8List encoded) {
    _clear();
    _onDeliver(encoded);
  }

  void _clear() {
    _frames.clear();
    _bufferedFragmentCount = 0;
    _cancelGapTimer();
  }

  void _updateGapTimer() {
    if (_bufferedFragmentCount == 0) {
      _cancelGapTimer();
    } else {
      _gapTimer ??= Timer(reorderTimeout, _expireGap);
    }
  }

  void _cancelGapTimer() {
    _gapTimer?.cancel();
    _gapTimer = null;
  }

  void dispose() => _clear();

  static bool _sameBytes(Uint8List left, Uint8List right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

class _PendingWindowsGattFragment {
  const _PendingWindowsGattFragment(this.fragment, this.encoded);

  final GattFragment fragment;
  final Uint8List encoded;
}

class _WindowsGattFrameOrder {
  _WindowsGattFrameOrder({this.start, this.startBuffered = false});

  _PendingWindowsGattFragment? start;
  bool startBuffered;
  final Map<int, _PendingWindowsGattFragment> pending =
      <int, _PendingWindowsGattFragment>{};
  var started = false;
  int? nextSequence;

  void setStart(_PendingWindowsGattFragment value) {
    if (start != null) throw StateError('Windows GATT frame already has START');
    start = value;
  }
}

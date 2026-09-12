import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'bluetooth_low_energy_backend.dart';
import 'gatt_backend_connection.dart';
import 'protocol/capabilities.dart';
import 'platform_ble_events.dart';
import 'types.dart';

export 'platform_ble_events.dart';

/// Direction of a physical GATT fragment at the platform boundary.
///
/// A sent fragment has been accepted by the platform backend for submission;
/// it is not an acknowledgement that the remote application received it.
enum GattPacketDirection { sent, received }

/// Payload-free diagnostic information about a physical GATT fragment.
///
/// This deliberately reports fragment counts and lengths rather than message
/// payloads. It is intended for progress reporting and must not affect the
/// protocol transport or its delivery semantics.
class GattPacketDiagnostic {
  const GattPacketDiagnostic({
    required this.direction,
    required this.endpointId,
    required this.byteCount,
    this.connectionGeneration,
  });

  final GattPacketDirection direction;
  final String endpointId;
  final int byteCount;
  final int? connectionGeneration;
}

/// Native BLE discovery/advertising bridge for the Section 44 backend
/// operations. It deliberately exposes no protocol service data: the only
/// discovery filter and advertisement value is the supplied service UUID.
///
/// GATT connection and whole-frame transport are a separate backend concern
/// and are not claimed by this class.
class PlatformBleBackend {
  PlatformBleBackend({
    MethodChannel? methods,
    EventChannel? events,
    Stream<PlatformBleEvent>? eventStream,
    this.logger,
    this.gattPacketDiagnostic,
  }) : _methods = methods ?? const MethodChannel(_methodChannelName),
       _events = events ?? const EventChannel(_eventChannelName),
       _eventStream = eventStream,
       _bluetoothLowEnergy =
           methods == null &&
               events == null &&
               eventStream == null &&
               !kIsWeb &&
               defaultTargetPlatform == TargetPlatform.windows
           ? BluetoothLowEnergyBackend(logger: logger)
           : null;

  static const _methodChannelName =
      'dev.localpeerconnections.local_peer_connections/backend';
  static const _eventChannelName =
      'dev.localpeerconnections.local_peer_connections/backend_events';
  final MethodChannel _methods;
  final EventChannel _events;
  final Stream<PlatformBleEvent>? _eventStream;
  final BluetoothLowEnergyBackend? _bluetoothLowEnergy;

  /// Optional diagnostic sink. Raw GATT fragment bytes are summarized and
  /// never included in log output.
  final void Function(String message)? logger;

  /// Optional payload-free GATT fragment diagnostic sink.
  ///
  /// It is invoked only after an outgoing fragment is accepted for platform
  /// submission and when an incoming platform fragment is observed. Failures
  /// in the sink are ignored so diagnostics cannot affect connectivity.
  final void Function(GattPacketDiagnostic diagnostic)? gattPacketDiagnostic;
  late final Stream<PlatformBleEvent> _sharedEvents =
      (_eventStream ??
              _events.receiveBroadcastStream().map((Object? value) {
                final map = value is Map ? value : const <Object?, Object?>{};
                final type = map['type'];
                final endpoint = map['endpointId'];
                final key = '$type:$endpoint';
                final now = DateTime.now();
                final previous = _lastEventLog[key];
                if (previous == null ||
                    now.difference(previous) >= const Duration(seconds: 5) ||
                    type != 'endpointFound') {
                  _lastEventLog[key] = now;
                  _log('native ${_eventSummary(value)}');
                }
                return PlatformBleEvent.fromPlatform(value);
              }))
          .asBroadcastStream();
  final Map<String, DateTime> _lastEventLog = <String, DateTime>{};
  late final Stream<PlatformBleEvent> _eventsWithPacketDiagnostics =
      (_bluetoothLowEnergy?.events ?? _sharedEvents).map((event) {
        if (event is PlatformGattFragment) {
          _reportGattPacket(
            GattPacketDiagnostic(
              direction: GattPacketDirection.received,
              endpointId: event.endpointId,
              byteCount: event.bytes.length,
              connectionGeneration: event.connectionGeneration,
            ),
          );
        }
        return event;
      }).asBroadcastStream();

  void _log(String message) {
    try {
      if (logger != null) {
        logger!(message);
      } else {
        debugPrint('[LocalPeerConnections] $message');
      }
    } on Object {
      // Diagnostics must never affect the platform event stream.
    }
  }

  void _reportGattPacket(GattPacketDiagnostic diagnostic) {
    try {
      gattPacketDiagnostic?.call(diagnostic);
    } on Object {
      // Diagnostics must never affect the platform transport.
    }
  }

  /// A single shared stream is important: EventChannel has one native sink,
  /// while discovery, GATT bindings, and apps may all listen concurrently.
  Stream<PlatformBleEvent> get events => _eventsWithPacketDiagnostics;

  Future<LocalRuntimeCapabilityBitmap> queryCapabilities() async {
    final lowEnergy = _bluetoothLowEnergy;
    if (lowEnergy != null) return lowEnergy.queryCapabilities();
    final raw = await _invoke<List<Object?>>('queryCapabilities');
    final capabilities = <LocalRuntimeCapability>[];
    for (final entry in raw) {
      if (entry is! String) {
        throw const LpcException(
          LpcErrorCode.platformError,
          'invalid native capability response',
        );
      }
      final capability = _capabilitiesByWireName[entry];
      if (capability == null) {
        throw const LpcException(
          LpcErrorCode.platformError,
          'unknown native capability',
        );
      }
      capabilities.add(capability);
    }
    return LocalRuntimeCapabilityBitmap(capabilities);
  }

  Future<void> startAdvertising(
    List<int> serviceUuid, {
    String? localName,
  }) async {
    final lowEnergy = _bluetoothLowEnergy;
    if (lowEnergy != null) {
      return lowEnergy.startAdvertising(serviceUuid, localName: localName);
    }
    await _invoke<void>('startAdvertising', {
      'serviceUuid': _serviceUuid(serviceUuid),
      if (localName != null) 'localName': localName,
    });
  }

  Future<void> stopAdvertising() {
    final lowEnergy = _bluetoothLowEnergy;
    return lowEnergy == null
        ? _invoke<void>('stopAdvertising')
        : lowEnergy.stopAdvertising();
  }

  Future<void> startDiscovery(List<int> serviceUuid) {
    final lowEnergy = _bluetoothLowEnergy;
    return lowEnergy == null
        ? _invoke<void>('startDiscovery', {
            'serviceUuid': _serviceUuid(serviceUuid),
          })
        : lowEnergy.startDiscovery(serviceUuid);
  }

  Future<void> stopDiscovery() {
    final lowEnergy = _bluetoothLowEnergy;
    return lowEnergy == null
        ? _invoke<void>('stopDiscovery')
        : lowEnergy.stopDiscovery();
  }

  /// Starts the local Section 11 GATT service. The platform derives the
  /// required RX/TX/CONTROL UUIDs from [serviceUuid] using Section 4.
  Future<void> listenGatt(List<int> serviceUuid) {
    final lowEnergy = _bluetoothLowEnergy;
    return lowEnergy == null
        ? _invoke<void>('listenGatt', {
            'serviceUuid': _serviceUuid(serviceUuid),
          })
        : lowEnergy.listenGatt(serviceUuid);
  }

  Future<void> stopGatt() {
    final lowEnergy = _bluetoothLowEnergy;
    return lowEnergy == null ? _invoke<void>('stopGatt') : lowEnergy.stopGatt();
  }

  /// Begins a GATT client connection for an opaque discovery endpoint.
  /// Connection establishment is reported by [events].
  Future<void> connectGatt(String discoveryEndpointId) {
    final lowEnergy = _bluetoothLowEnergy;
    return lowEnergy == null
        ? _invoke<void>('connectGatt', {'endpointId': discoveryEndpointId})
        : lowEnergy.connectGatt(discoveryEndpointId);
  }

  Future<GattFragmentSubmission> submitGattFragment(
    String endpointId,
    Uint8List fragment, {
    required GattFragmentTransmission transmission,
    int? connectionGeneration,
  }) async {
    final lowEnergy = _bluetoothLowEnergy;
    final GattFragmentSubmission submission;
    if (lowEnergy != null) {
      submission = await lowEnergy.submitGattFragment(
        endpointId,
        fragment,
        transmission: transmission,
        connectionGeneration: connectionGeneration,
      );
    } else {
      final result = await _invoke<String>('submitGattFragment', {
        'endpointId': endpointId,
        'fragment': fragment,
        'transmission': transmission.name,
        if (connectionGeneration != null)
          'connectionGeneration': connectionGeneration,
      });
      submission = switch (result) {
        'submitted' => GattFragmentSubmission.submitted,
        'temporarilyUnavailable' =>
          GattFragmentSubmission.temporarilyUnavailable,
        'terminalFailure' => GattFragmentSubmission.terminalFailure,
        _ => throw const LpcException(
          LpcErrorCode.platformError,
          'invalid GATT submission response',
        ),
      };
    }
    if (submission == GattFragmentSubmission.submitted) {
      _reportGattPacket(
        GattPacketDiagnostic(
          direction: GattPacketDirection.sent,
          endpointId: endpointId,
          byteCount: fragment.length,
          connectionGeneration: connectionGeneration,
        ),
      );
    }
    return submission;
  }

  Future<void> closeGattConnection(
    String endpointId, {
    int? connectionGeneration,
  }) {
    final lowEnergy = _bluetoothLowEnergy;
    return lowEnergy == null
        ? _invoke<void>('closeGattConnection', {
            'endpointId': endpointId,
            if (connectionGeneration != null)
              'connectionGeneration': connectionGeneration,
          })
        : lowEnergy.closeGattConnection(
            endpointId,
            connectionGeneration: connectionGeneration,
          );
  }

  Uint8List _serviceUuid(List<int> value) {
    if (value.length != 16) {
      throw ArgumentError.value(value, 'serviceUuid', 'must be 16 bytes');
    }
    return Uint8List.fromList(value);
  }

  Future<T> _invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    // Fragment submission can occur dozens of times per frame and is already
    // summarized by the owning GATT connection. Logging every native method
    // call can starve the Flutter isolate and make the integration control
    // server appear hung on real devices. Keep lifecycle/error calls verbose;
    // retain the actual transport result for submit failures below.
    final logInvocation = method != 'submitGattFragment';
    if (logInvocation) {
      _log('invoke method=$method${_argumentsSummary(arguments)}');
    }
    try {
      final result = (await _methods.invokeMethod<T>(method, arguments)) as T;
      if (logInvocation) _log('invoke complete method=$method');
      return result;
    } on PlatformException catch (error) {
      _log(
        'invoke failed method=$method code=${error.code} message=${error.message ?? 'none'}',
      );
      throw LpcException(
        _errorCodes[error.code] ?? LpcErrorCode.platformError,
        error.message ?? 'native backend failure',
      );
    } on MissingPluginException {
      _log('invoke failed method=$method code=missing-plugin');
      throw const LpcException(LpcErrorCode.unsupportedCapability);
    }
  }
}

String _argumentsSummary(Map<String, Object?>? arguments) {
  if (arguments == null || arguments.isEmpty) return '';
  final parts = <String>[];
  for (final entry in arguments.entries) {
    final value = entry.value;
    final summary = value is Uint8List
        ? 'bytes(${value.length})'
        : value is List<int>
        ? 'list(${value.length})'
        : value is List
        ? 'list(${value.length})'
        : '$value';
    parts.add('${entry.key}=$summary');
  }
  return ' ${parts.join(' ')}';
}

String _eventSummary(Object? value) {
  if (value is! Map) return 'invalid-event';
  final type = value['type'] ?? 'unknown';
  final endpoint = value['endpointId'];
  final role = value['localRole'];
  final status = value['status'];
  final bytes = value['bytes'];
  return 'event=$type${endpoint == null ? '' : ' endpoint=$endpoint'}'
      '${role == null ? '' : ' role=$role'}'
      '${status == null ? '' : ' status=$status'}'
      '${bytes is List ? ' bytes=${bytes.length}' : ''}';
}

/// Flutter binding of the Section 44 GATT fragment submission boundary.
/// Received fragments and native writable/close events are deliberately
/// delivered separately to the owning [GattBackendConnection].
class PlatformGattFragmentPlatform implements GattFragmentPlatform {
  PlatformGattFragmentPlatform({
    required PlatformBleBackend backend,
    required this.endpointId,
    required this.platformSafeWriteSize,
    this.connectionGeneration,
  }) : _backend = backend {
    if (platformSafeWriteSize <= 7) {
      throw const LpcException(
        LpcErrorCode.resourceExhausted,
        'platform GATT write size is unusable',
      );
    }
  }

  final PlatformBleBackend _backend;
  final String endpointId;
  final int? connectionGeneration;
  @override
  final int platformSafeWriteSize;

  @override
  Future<GattFragmentSubmission> submitGattFragment(
    Uint8List fragment, {
    GattFragmentTransmission transmission = GattFragmentTransmission.normal,
  }) => _backend.submitGattFragment(
    endpointId,
    fragment,
    transmission: transmission,
    connectionGeneration: connectionGeneration,
  );

  @override
  Future<void> close() => _backend.closeGattConnection(
    endpointId,
    connectionGeneration: connectionGeneration,
  );
}

/// Connects native connection-scoped fragment events to one portable GATT
/// backend. The portable backend alone performs Section 12 reassembly.
class PlatformGattConnectionBinding {
  PlatformGattConnectionBinding({
    required PlatformBleBackend backend,
    required this.endpointId,
    required this.connection,
    this.connectionGeneration,
  }) {
    _subscription = backend.events.listen((event) {
      if (event is PlatformGattDisconnected && event.endpointId == endpointId) {
        connection.logger?.call(
          'platform disconnect eventGeneration=${event.connectionGeneration} bindingGeneration=$connectionGeneration',
        );
      }
      if (event is PlatformGattFragment &&
          event.endpointId == endpointId &&
          _matchesGeneration(event.connectionGeneration)) {
        connection.receiveGattFragment(event.bytes);
      }
      if (event is PlatformGattDisconnected &&
          event.endpointId == endpointId &&
          _matchesGeneration(event.connectionGeneration)) {
        connection.terminalFailure();
      }
      if (event is PlatformGattWritable &&
          (event.endpointId == null || event.endpointId == endpointId) &&
          _matchesGeneration(event.connectionGeneration)) {
        connection.writable();
      }
    }, onError: (_, __) => connection.terminalFailure());
  }

  final String endpointId;
  final GattBackendConnection connection;
  final int? connectionGeneration;
  late final StreamSubscription<PlatformBleEvent> _subscription;

  bool acceptsGeneration(int? eventGeneration) =>
      _matchesGeneration(eventGeneration);

  bool _matchesGeneration(int? eventGeneration) =>
      connectionGeneration == null ||
      eventGeneration == null ||
      connectionGeneration == eventGeneration;

  Future<void> close() => _subscription.cancel();
}

const _capabilitiesByWireName = <String, LocalRuntimeCapability>{
  'bleScan': LocalRuntimeCapability.bleScan,
  'bleAdvertise': LocalRuntimeCapability.bleAdvertise,
  'gattCentral': LocalRuntimeCapability.gattCentral,
  'gattPeripheral': LocalRuntimeCapability.gattPeripheral,
};

const _errorCodes = <String, LpcErrorCode>{
  'PERMISSION_DENIED': LpcErrorCode.permissionDenied,
  'BLUETOOTH_UNAVAILABLE': LpcErrorCode.bluetoothUnavailable,
  'BLUETOOTH_POWERED_OFF': LpcErrorCode.bluetoothPoweredOff,
  'ADVERTISING_UNAVAILABLE': LpcErrorCode.advertisingUnavailable,
  'DISCOVERY_UNAVAILABLE': LpcErrorCode.discoveryUnavailable,
  'ENDPOINT_LOST': LpcErrorCode.endpointLost,
  'UNSUPPORTED_CAPABILITY': LpcErrorCode.unsupportedCapability,
};

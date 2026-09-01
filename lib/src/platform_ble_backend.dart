import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'gatt_backend_connection.dart';
import 'protocol/capabilities.dart';
import 'types.dart';

/// Native BLE discovery/advertising bridge for the Section 44 backend
/// operations. It deliberately exposes no protocol service data: the only
/// discovery filter and advertisement value is the supplied service UUID.
///
/// GATT connection and whole-frame transport are a separate backend concern
/// and are not claimed by this class.
class PlatformBleBackend {
  PlatformBleBackend(
      {MethodChannel? methods,
      EventChannel? events,
      Stream<PlatformBleEvent>? eventStream})
      : _methods = methods ?? const MethodChannel(_methodChannelName),
        _events = events ?? const EventChannel(_eventChannelName),
        _eventStream = eventStream;

  static const _methodChannelName =
      'dev.localpeerconnections.local_peer_connections/backend';
  static const _eventChannelName =
      'dev.localpeerconnections.local_peer_connections/backend_events';
  final MethodChannel _methods;
  final EventChannel _events;
  final Stream<PlatformBleEvent>? _eventStream;
  late final Stream<PlatformBleEvent> _sharedEvents =
      (_eventStream ??
              _events.receiveBroadcastStream().map((Object? value) {
                debugPrint('[LocalPeerConnections] native event: $value');
                return PlatformBleEvent.fromPlatform(value);
              }))
          .asBroadcastStream();

  /// A single shared stream is important: EventChannel has one native sink,
  /// while discovery, GATT bindings, and apps may all listen concurrently.
  Stream<PlatformBleEvent> get events => _sharedEvents;

  Future<LocalRuntimeCapabilityBitmap> queryCapabilities() async {
    final raw = await _invoke<List<Object?>>('queryCapabilities');
    final capabilities = <LocalRuntimeCapability>[];
    for (final entry in raw) {
      if (entry is! String) {
        throw const LpcException(
            LpcErrorCode.platformError, 'invalid native capability response');
      }
      final capability = _capabilitiesByWireName[entry];
      if (capability == null) {
        throw const LpcException(
            LpcErrorCode.platformError, 'unknown native capability');
      }
      capabilities.add(capability);
    }
    return LocalRuntimeCapabilityBitmap(capabilities);
  }

  Future<void> startAdvertising(List<int> serviceUuid,
      {String? localName}) async {
    await _invoke<void>('startAdvertising', {
      'serviceUuid': _serviceUuid(serviceUuid),
      if (localName != null) 'localName': localName,
    });
  }

  Future<void> stopAdvertising() => _invoke<void>('stopAdvertising');

  Future<void> startDiscovery(List<int> serviceUuid) => _invoke<void>(
      'startDiscovery', {'serviceUuid': _serviceUuid(serviceUuid)});

  Future<void> stopDiscovery() => _invoke<void>('stopDiscovery');

  /// Starts the local Section 11 GATT service. The platform derives the
  /// required RX/TX/CONTROL UUIDs from [serviceUuid] using Section 4.
  Future<void> listenGatt(List<int> serviceUuid) =>
      _invoke<void>('listenGatt', {'serviceUuid': _serviceUuid(serviceUuid)});

  Future<void> stopGatt() => _invoke<void>('stopGatt');

  /// Begins a GATT client connection for an opaque discovery endpoint.
  /// Connection establishment is reported by [events].
  Future<void> connectGatt(String discoveryEndpointId) =>
      _invoke<void>('connectGatt', {'endpointId': discoveryEndpointId});

  Future<GattFragmentSubmission> submitGattFragment(
      String endpointId, Uint8List fragment,
      {required GattFragmentTransmission transmission}) async {
    final result = await _invoke<String>('submitGattFragment', {
      'endpointId': endpointId,
      'fragment': fragment,
      'transmission': transmission.name,
    });
    return switch (result) {
      'submitted' => GattFragmentSubmission.submitted,
      'temporarilyUnavailable' => GattFragmentSubmission.temporarilyUnavailable,
      'terminalFailure' => GattFragmentSubmission.terminalFailure,
      _ => throw const LpcException(
          LpcErrorCode.platformError, 'invalid GATT submission response'),
    };
  }

  Future<void> closeGattConnection(String endpointId) =>
      _invoke<void>('closeGattConnection', {'endpointId': endpointId});

  Uint8List _serviceUuid(List<int> value) {
    if (value.length != 16) {
      throw ArgumentError.value(value, 'serviceUuid', 'must be 16 bytes');
    }
    return Uint8List.fromList(value);
  }

  Future<T> _invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return (await _methods.invokeMethod<T>(method, arguments)) as T;
    } on PlatformException catch (error) {
      throw LpcException(_errorCodes[error.code] ?? LpcErrorCode.platformError,
          error.message ?? 'native backend failure');
    } on MissingPluginException {
      throw const LpcException(LpcErrorCode.unsupportedCapability);
    }
  }
}

/// Flutter binding of the Section 44 GATT fragment submission boundary.
/// Received fragments and native writable/close events are deliberately
/// delivered separately to the owning [GattBackendConnection].
class PlatformGattFragmentPlatform implements GattFragmentPlatform {
  PlatformGattFragmentPlatform({
    required PlatformBleBackend backend,
    required this.endpointId,
    required this.platformSafeWriteSize,
  }) : _backend = backend {
    if (platformSafeWriteSize <= 7) {
      throw const LpcException(LpcErrorCode.resourceExhausted,
          'platform GATT write size is unusable');
    }
  }

  final PlatformBleBackend _backend;
  final String endpointId;
  @override
  final int platformSafeWriteSize;

  @override
  Future<GattFragmentSubmission> submitGattFragment(Uint8List fragment,
          {GattFragmentTransmission transmission =
              GattFragmentTransmission.normal}) =>
      _backend.submitGattFragment(endpointId, fragment,
          transmission: transmission);

  @override
  Future<void> close() => _backend.closeGattConnection(endpointId);
}

/// Connects native connection-scoped fragment events to one portable GATT
/// backend. The portable backend alone performs Section 12 reassembly.
class PlatformGattConnectionBinding {
  PlatformGattConnectionBinding({
    required PlatformBleBackend backend,
    required this.endpointId,
    required this.connection,
  }) : _subscription = backend.events.listen(
          (event) {
            if (event is PlatformGattFragment &&
                event.endpointId == endpointId) {
              connection.receiveGattFragment(event.bytes);
            }
            if (event is PlatformGattDisconnected &&
                event.endpointId == endpointId) {
              connection.terminalFailure();
            }
            if (event is PlatformGattWritable &&
                (event.endpointId == null || event.endpointId == endpointId)) {
              connection.writable();
            }
          },
          onError: (_, __) => connection.terminalFailure(),
        );

  final String endpointId;
  final GattBackendConnection connection;
  final StreamSubscription<PlatformBleEvent> _subscription;

  Future<void> close() => _subscription.cancel();
}

sealed class PlatformBleEvent {
  const PlatformBleEvent();

  factory PlatformBleEvent.fromPlatform(Object? value) {
    if (value is! Map) {
      throw const LpcException(
          LpcErrorCode.platformError, 'invalid native backend event');
    }
    final type = value['type'];
    if (type == 'endpointFound' &&
        value['endpointId'] is String &&
        (value['localName'] == null || value['localName'] is String) &&
        value['rssi'] is int) {
      return PlatformEndpointFound(value['endpointId'] as String,
          localName: value['localName'] as String?, rssi: value['rssi'] as int);
    }
    if (type == 'gattConnected' &&
        value['endpointId'] is String &&
        value['localRole'] is String) {
      final role = value['localRole'] as String;
      if (role == 'central' || role == 'peripheral') {
        final safeWriteSize = value['platformSafeWriteSize'];
        return PlatformGattConnected(value['endpointId'] as String, role,
            platformSafeWriteSize:
                safeWriteSize is int && safeWriteSize > 7 ? safeWriteSize : 20);
      }
    }
    if (type == 'gattFragment' &&
        value['endpointId'] is String &&
        value['bytes'] is List) {
      final bytes = value['bytes'] as List;
      if (bytes.every((byte) => byte is int && byte >= 0 && byte <= 255)) {
        return PlatformGattFragment(
            value['endpointId'] as String, bytes.cast<int>());
      }
    }
    if (type == 'gattDisconnected' && value['endpointId'] is String) {
      return PlatformGattDisconnected(value['endpointId'] as String);
    }
    if (type == 'gattWritable' &&
        (value['endpointId'] == null || value['endpointId'] is String)) {
      return PlatformGattWritable(value['endpointId'] as String?);
    }
    throw const LpcException(
        LpcErrorCode.platformError, 'unknown native backend event');
  }
}

/// A platform-scoped discovery identifier. It is never a protocol PeerId.
class PlatformEndpointFound extends PlatformBleEvent {
  const PlatformEndpointFound(this.endpointId,
      {required this.rssi, this.localName});
  final String endpointId;
  final String? localName;
  final int rssi;
}

/// A physical GATT link has completed Section 11 service discovery. Its
/// endpoint ID remains platform-local and cannot be used as a protocol PeerId.
class PlatformGattConnected extends PlatformBleEvent {
  const PlatformGattConnected(this.endpointId, this.localRole,
      {this.platformSafeWriteSize = 20});
  final String endpointId;
  final String localRole;
  final int platformSafeWriteSize;
}

class PlatformGattFragment extends PlatformBleEvent {
  PlatformGattFragment(this.endpointId, List<int> bytes)
      : bytes = Uint8List.fromList(bytes);
  final String endpointId;
  final Uint8List bytes;
}

class PlatformGattDisconnected extends PlatformBleEvent {
  const PlatformGattDisconnected(this.endpointId);
  final String endpointId;
}

class PlatformGattWritable extends PlatformBleEvent {
  const PlatformGattWritable(this.endpointId);
  final String? endpointId;
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

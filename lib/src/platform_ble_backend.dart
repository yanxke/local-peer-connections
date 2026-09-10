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
      Stream<PlatformBleEvent>? eventStream,
      this.logger})
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

  /// Optional diagnostic sink. Raw GATT fragment bytes are summarized and
  /// never included in log output.
  final void Function(String message)? logger;
  late final Stream<PlatformBleEvent> _sharedEvents = (_eventStream ??
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
      {required GattFragmentTransmission transmission,
      int? connectionGeneration}) async {
    final result = await _invoke<String>('submitGattFragment', {
      'endpointId': endpointId,
      'fragment': fragment,
      'transmission': transmission.name,
      if (connectionGeneration != null)
        'connectionGeneration': connectionGeneration,
    });
    return switch (result) {
      'submitted' => GattFragmentSubmission.submitted,
      'temporarilyUnavailable' => GattFragmentSubmission.temporarilyUnavailable,
      'terminalFailure' => GattFragmentSubmission.terminalFailure,
      _ => throw const LpcException(
          LpcErrorCode.platformError, 'invalid GATT submission response'),
    };
  }

  Future<void> closeGattConnection(String endpointId,
          {int? connectionGeneration}) =>
      _invoke<void>('closeGattConnection', {
        'endpointId': endpointId,
        if (connectionGeneration != null)
          'connectionGeneration': connectionGeneration,
      });

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
    if (logInvocation)
      _log('invoke method=$method${_argumentsSummary(arguments)}');
    try {
      final result = (await _methods.invokeMethod<T>(method, arguments)) as T;
      if (logInvocation) _log('invoke complete method=$method');
      return result;
    } on PlatformException catch (error) {
      _log(
          'invoke failed method=$method code=${error.code} message=${error.message ?? 'none'}');
      throw LpcException(_errorCodes[error.code] ?? LpcErrorCode.platformError,
          error.message ?? 'native backend failure');
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
      throw const LpcException(LpcErrorCode.resourceExhausted,
          'platform GATT write size is unusable');
    }
  }

  final PlatformBleBackend _backend;
  final String endpointId;
  final int? connectionGeneration;
  @override
  final int platformSafeWriteSize;

  @override
  Future<GattFragmentSubmission> submitGattFragment(Uint8List fragment,
          {GattFragmentTransmission transmission =
              GattFragmentTransmission.normal}) =>
      _backend.submitGattFragment(endpointId, fragment,
          transmission: transmission,
          connectionGeneration: connectionGeneration);

  @override
  Future<void> close() => _backend.closeGattConnection(endpointId,
      connectionGeneration: connectionGeneration);
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
    _subscription = backend.events.listen(
      (event) {
        if (event is PlatformGattDisconnected &&
            event.endpointId == endpointId) {
          connection.logger?.call(
              'platform disconnect eventGeneration=${event.connectionGeneration} bindingGeneration=$connectionGeneration');
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
      },
      onError: (_, __) => connection.terminalFailure(),
    );
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
                safeWriteSize is int && safeWriteSize > 7 ? safeWriteSize : 20,
            connectionGeneration:
                (value['connectionGeneration'] as num?)?.toInt());
      }
    }
    if (type == 'gattFragment' &&
        value['endpointId'] is String &&
        value['bytes'] is List) {
      final bytes = value['bytes'] as List;
      // Android ByteArray payloads may arrive as signed values; normalize
      // them here as a defensive compatibility measure.
      if (bytes.every((byte) => byte is int && byte >= -128 && byte <= 255)) {
        return PlatformGattFragment(value['endpointId'] as String,
            bytes.cast<int>().map((byte) => byte & 0xff).toList(),
            connectionGeneration:
                (value['connectionGeneration'] as num?)?.toInt());
      }
    }
    if (type == 'gattDisconnected' && value['endpointId'] is String) {
      return PlatformGattDisconnected(value['endpointId'] as String,
          connectionGeneration:
              (value['connectionGeneration'] as num?)?.toInt());
    }
    if (type == 'gattWritable' &&
        (value['endpointId'] == null || value['endpointId'] is String)) {
      return PlatformGattWritable(value['endpointId'] as String?,
          connectionGeneration:
              (value['connectionGeneration'] as num?)?.toInt());
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
      {this.platformSafeWriteSize = 20, this.connectionGeneration});
  final String endpointId;
  final String localRole;
  final int platformSafeWriteSize;
  final int? connectionGeneration;
}

class PlatformGattFragment extends PlatformBleEvent {
  PlatformGattFragment(this.endpointId, List<int> bytes,
      {this.connectionGeneration})
      : bytes = Uint8List.fromList(bytes);
  final String endpointId;
  final Uint8List bytes;
  final int? connectionGeneration;
}

class PlatformGattDisconnected extends PlatformBleEvent {
  const PlatformGattDisconnected(this.endpointId, {this.connectionGeneration});
  final String endpointId;
  final int? connectionGeneration;
}

class PlatformGattWritable extends PlatformBleEvent {
  const PlatformGattWritable(this.endpointId, {this.connectionGeneration});
  final String? endpointId;
  final int? connectionGeneration;
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

import 'dart:async';
import 'package:flutter/services.dart';

import 'protocol/capabilities.dart';
import 'types.dart';

/// Native BLE discovery/advertising bridge for the Section 44 backend
/// operations. It deliberately exposes no protocol service data: the only
/// discovery filter and advertisement value is the supplied service UUID.
///
/// GATT connection and whole-frame transport are a separate backend concern
/// and are not claimed by this class.
class PlatformBleBackend {
  PlatformBleBackend({MethodChannel? methods, EventChannel? events})
      : _methods = methods ?? const MethodChannel(_methodChannelName),
        _events = events ?? const EventChannel(_eventChannelName);

  static const _methodChannelName =
      'dev.localpeerconnections.local_peer_connections/backend';
  static const _eventChannelName =
      'dev.localpeerconnections.local_peer_connections/backend_events';
  final MethodChannel _methods;
  final EventChannel _events;

  Stream<PlatformBleEvent> get events => _events
      .receiveBroadcastStream()
      .map((Object? value) => PlatformBleEvent.fromPlatform(value));

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

const _capabilitiesByWireName = <String, LocalRuntimeCapability>{
  'bleScan': LocalRuntimeCapability.bleScan,
  'bleAdvertise': LocalRuntimeCapability.bleAdvertise,
};

const _errorCodes = <String, LpcErrorCode>{
  'PERMISSION_DENIED': LpcErrorCode.permissionDenied,
  'BLUETOOTH_UNAVAILABLE': LpcErrorCode.bluetoothUnavailable,
  'BLUETOOTH_POWERED_OFF': LpcErrorCode.bluetoothPoweredOff,
  'ADVERTISING_UNAVAILABLE': LpcErrorCode.advertisingUnavailable,
  'DISCOVERY_UNAVAILABLE': LpcErrorCode.discoveryUnavailable,
  'UNSUPPORTED_CAPABILITY': LpcErrorCode.unsupportedCapability,
};

import 'dart:typed_data';

import 'types.dart';

sealed class PlatformBleEvent {
  const PlatformBleEvent();

  factory PlatformBleEvent.fromPlatform(Object? value) {
    if (value is! Map) {
      throw const LpcException(
        LpcErrorCode.platformError,
        'invalid native backend event',
      );
    }
    final type = value['type'];
    if (type == 'endpointFound' &&
        value['endpointId'] is String &&
        (value['localName'] == null || value['localName'] is String) &&
        value['rssi'] is int) {
      return PlatformEndpointFound(
        value['endpointId'] as String,
        localName: value['localName'] as String?,
        rssi: value['rssi'] as int,
      );
    }
    if (type == 'gattConnected' &&
        value['endpointId'] is String &&
        value['localRole'] is String) {
      final role = value['localRole'] as String;
      if (role == 'central' || role == 'peripheral') {
        final safeWriteSize = value['platformSafeWriteSize'];
        return PlatformGattConnected(
          value['endpointId'] as String,
          role,
          platformSafeWriteSize: safeWriteSize is int && safeWriteSize > 7
              ? safeWriteSize
              : 20,
          connectionGeneration: (value['connectionGeneration'] as num?)
              ?.toInt(),
        );
      }
    }
    if (type == 'gattFragment' &&
        value['endpointId'] is String &&
        value['bytes'] is List) {
      final bytes = value['bytes'] as List;
      // Android ByteArray payloads may arrive as signed values; normalize
      // them here as a defensive compatibility measure.
      if (bytes.every((byte) => byte is int && byte >= -128 && byte <= 255)) {
        return PlatformGattFragment(
          value['endpointId'] as String,
          bytes.cast<int>().map((byte) => byte & 0xff).toList(),
          connectionGeneration: (value['connectionGeneration'] as num?)
              ?.toInt(),
        );
      }
    }
    if (type == 'gattDisconnected' && value['endpointId'] is String) {
      return PlatformGattDisconnected(
        value['endpointId'] as String,
        connectionGeneration: (value['connectionGeneration'] as num?)?.toInt(),
      );
    }
    if (type == 'gattWritable' &&
        (value['endpointId'] == null || value['endpointId'] is String)) {
      return PlatformGattWritable(
        value['endpointId'] as String?,
        connectionGeneration: (value['connectionGeneration'] as num?)?.toInt(),
      );
    }
    throw const LpcException(
      LpcErrorCode.platformError,
      'unknown native backend event',
    );
  }
}

/// A platform-scoped discovery identifier. It is never a protocol PeerId.
class PlatformEndpointFound extends PlatformBleEvent {
  const PlatformEndpointFound(
    this.endpointId, {
    required this.rssi,
    this.localName,
  });
  final String endpointId;
  final String? localName;
  final int rssi;
}

/// A physical GATT link has completed Section 11 service discovery. Its
/// endpoint ID remains platform-local and cannot be used as a protocol PeerId.
class PlatformGattConnected extends PlatformBleEvent {
  const PlatformGattConnected(
    this.endpointId,
    this.localRole, {
    this.platformSafeWriteSize = 20,
    this.connectionGeneration,
  });
  final String endpointId;
  final String localRole;
  final int platformSafeWriteSize;
  final int? connectionGeneration;
}

class PlatformGattFragment extends PlatformBleEvent {
  PlatformGattFragment(
    this.endpointId,
    List<int> bytes, {
    this.connectionGeneration,
  }) : bytes = Uint8List.fromList(bytes);
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

import 'dart:typed_data';

/// Section 4/11 UUIDs for one LPC GATT service.
///
/// Characteristic derivation changes byte offset 3 (the low byte of the
/// leading big-endian 32-bit UUID field), matching the frozen default UUIDs.
class GattServiceUuids {
  GattServiceUuids.fromServiceUuid(List<int> serviceUuid)
      : service = _uuid(serviceUuid),
        rx = _derived(serviceUuid, 1),
        tx = _derived(serviceUuid, 2),
        control = _derived(serviceUuid, 3);

  /// Use when a platform cannot perform the Section 4 UUID arithmetic.
  GattServiceUuids.explicit({
    required List<int> service,
    required List<int> rx,
    required List<int> tx,
    required List<int> control,
  })  : service = _uuid(service),
        rx = _uuid(rx),
        tx = _uuid(tx),
        control = _uuid(control);

  final Uint8List service;
  final Uint8List rx;
  final Uint8List tx;
  final Uint8List control;

  static Uint8List _uuid(List<int> value) {
    if (value.length != 16) {
      throw ArgumentError.value(value, 'uuid', 'must be exactly 16 bytes');
    }
    return Uint8List.fromList(value);
  }

  static Uint8List _derived(List<int> serviceUuid, int increment) {
    final value = _uuid(serviceUuid);
    if (value[3] > 0xff - increment) {
      throw ArgumentError.value(
          serviceUuid, 'serviceUuid', 'characteristic UUID arithmetic wraps');
    }
    value[3] += increment;
    return value;
  }
}

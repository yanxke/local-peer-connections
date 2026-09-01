import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

List<int> _hex(String value) => List<int>.generate(value.length ~/ 2,
    (i) => int.parse(value.substring(i * 2, i * 2 + 2), radix: 16));

void main() {
  test('Section 4 GATT UUID derivation matches the published vector', () {
    final vector = jsonDecode(
            File('test/vectors/gatt_service_uuids.json').readAsStringSync())
        as Map<String, dynamic>;
    final uuids =
        GattServiceUuids.fromServiceUuid(_hex(vector['service_hex'] as String));

    expect(uuids.rx, _hex(vector['rx_hex'] as String));
    expect(uuids.tx, _hex(vector['tx_hex'] as String));
    expect(uuids.control, _hex(vector['control_hex'] as String));
  });

  test('Section 4 UUID arithmetic changes byte offset 3 only', () {
    final uuids = GattServiceUuids.fromServiceUuid(
        _hex('0102030405060708090a0b0c0d0e0f10'));
    expect(uuids.rx, _hex('0102030505060708090a0b0c0d0e0f10'));
    expect(uuids.tx, _hex('0102030605060708090a0b0c0d0e0f10'));
    expect(uuids.control, _hex('0102030705060708090a0b0c0d0e0f10'));
  });

  test('Section 4 UUID arithmetic rejects overflow', () {
    expect(
        () => GattServiceUuids.fromServiceUuid(
            _hex('010203fd05060708090a0b0c0d0e0f10')),
        throwsArgumentError);
  });
}

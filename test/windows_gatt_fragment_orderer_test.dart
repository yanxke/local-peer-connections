import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/src/bluetooth_low_energy_backend.dart';
import 'package:local_peer_connections/src/protocol/gatt_fragment.dart';

void main() {
  test(
    'UT-244 Windows callback repair restores response-free fragment order',
    () {
      final delivered = <Uint8List>[];
      final orderer = WindowsGattFragmentOrderer(onDeliver: delivered.add);
      add(orderer, 0, start: true);
      add(orderer, 2, end: true);
      add(orderer, 1);

      expect(delivered.map((value) => GattFragment.decode(value).sequence), [
        0,
        1,
        2,
      ]);
      orderer.dispose();
    },
  );

  test('UT-245 Windows callback repair accepts a delayed START callback', () {
    final delivered = <Uint8List>[];
    final orderer = WindowsGattFragmentOrderer(onDeliver: delivered.add);
    add(orderer, 1, end: true);
    add(orderer, 0, start: true);

    expect(delivered.map((value) => GattFragment.decode(value).sequence), [
      0,
      1,
    ]);
    orderer.dispose();
  });

  test('UT-246 Windows callback repair bounds unrecoverable reordering', () {
    final delivered = <Uint8List>[];
    final orderer = WindowsGattFragmentOrderer(
      maxBufferedFragments: 1,
      onDeliver: delivered.add,
    );
    add(orderer, 0, start: true);
    add(orderer, 2);
    add(orderer, 3, end: true);

    // Fragment 3 reaches the normal Section 12 reassembler, which will
    // reject its gap instead of letting this platform repair buffer grow.
    expect(delivered.map((value) => GattFragment.decode(value).sequence), [
      0,
      3,
    ]);
    orderer.dispose();
  });

  test('UT-247 Windows callback repair holds early next-frame START', () {
    final delivered = <Uint8List>[];
    final orderer = WindowsGattFragmentOrderer(onDeliver: delivered.add);
    add(orderer, 0, start: true);
    add(orderer, 0, start: true);
    add(orderer, 1, end: true);
    add(orderer, 1, end: true);

    expect(delivered.map((value) => GattFragment.decode(value).sequence), [
      0,
      1,
      0,
      1,
    ]);
    orderer.dispose();
  });
}

void add(
  WindowsGattFragmentOrderer orderer,
  int sequence, {
  bool start = false,
  bool end = false,
}) {
  orderer.add(
    GattFragment(sequence, [sequence], start: start, end: end).encode(),
  );
}

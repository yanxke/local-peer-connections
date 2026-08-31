import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-013 GATT sequence supports values above uint16', () {
    final fragment = GattFragment(65536, [1, 2], start: true);
    expect(GattFragment.decode(fragment.encode()).sequence, 65536);
  });

  test('UT-014 fragments use frozen flags, reset sequence, and reassemble', () {
    final fragments = GattFragmenter(10).split([1, 2, 3, 4, 5, 6, 7]);
    expect(fragments.map((fragment) => fragment.sequence), [0, 1, 2]);
    expect(fragments.first.start, isTrue);
    expect(fragments.first.end, isFalse);
    expect(fragments.last.end, isTrue);
    expect(GattFragment(0, [0xaa, 0xbb, 0xcc], start: true, end: true).encode(),
        [0, 0, 0, 0, 3, 0, 3, 0xaa, 0xbb, 0xcc]);

    final reassembler = GattReassembler();
    expect(reassembler.add(fragments[0], nowMs: 0), isNull);
    expect(reassembler.add(fragments[1], nowMs: 10), isNull);
    expect(reassembler.add(fragments[2], nowMs: 20), [1, 2, 3, 4, 5, 6, 7]);
  });

  test('GATT fragment binary vector is byte-for-byte stable', () {
    final vector = jsonDecode(
        File('test/vectors/gatt_fragment_single_frame.json')
            .readAsStringSync()) as Map<String, Object?>;
    final bytes =
        GattFragment(0, [0xaa, 0xbb, 0xcc], start: true, end: true).encode();
    expect(_hex(bytes), vector['hex']);
  });

  test('missing or expired fragment invalidates only the incomplete frame', () {
    final reassembler = GattReassembler();
    reassembler.add(GattFragment(0, [1], start: true), nowMs: 0);
    expect(reassembler.discardExpired(2000), isTrue);
    expect(() => reassembler.add(GattFragment(1, [2], end: true), nowMs: 2001),
        throwsA(isA<LpcException>()));
  });
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

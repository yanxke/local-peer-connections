import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  // UT-013: sequence remains uint32, including values above uint16.
  test('UT-013 GATT sequence supports values above 65535', () {
    final fragment = GattFragment(65536, [1, 2]);
    expect(GattFragment.decode(fragment.encode()).sequence, 65536);
  });
  test('fragment envelope uses a big-endian uint32 sequence', () {
    expect(GattFragment(0x01020304, [9]).encode(), [1, 2, 3, 4, 0, 1, 9]);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-011 PeerCapabilityBitmap uses the frozen HELLO bit positions', () {
    final capabilities = PeerCapabilityBitmap(
        [PeerCapability.gattBaseline, PeerCapability.lanUdpRealtime]);
    expect(capabilities.value, 0x101);
    expect(capabilities.contains(PeerCapability.lanUdpRealtime), isTrue);
    expect(() => PeerCapabilityBitmap.fromValue(0x200),
        throwsA(isA<LpcException>()));
  });

  test('UT-012 runtime capabilities cannot be used as HELLO capabilities', () {
    final local = LocalRuntimeCapabilityBitmap(
        [LocalRuntimeCapability.bleScan, LocalRuntimeCapability.lanUdp]);
    expect(local.value, 0x401);
    expect(local, isNot(isA<PeerCapabilityBitmap>()));
  });
}

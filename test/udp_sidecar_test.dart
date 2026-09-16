import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('RT-024 only the lexicographically smaller peer auto-initiates UDP', () {
    final smaller = PeerId([...List<int>.filled(15, 0), 1]);
    final larger = PeerId([...List<int>.filled(15, 0), 2]);
    expect(mayAutomaticallyInitiateUdp(smaller, larger), isTrue);
    expect(mayAutomaticallyInitiateUdp(larger, smaller), isFalse);
  });

  test('UDP_OFFER and ACCEPT preserve fixed endpoint and nonce layouts', () {
    final offer = UdpOffer(
        channelId: 1,
        addressFamily: UdpAddressFamily.ipv4,
        port: 1234,
        address: [192, 168, 1, 2, ...List.filled(12, 0)],
        offerNonce: List.filled(16, 3));
    expect(UdpOffer.decode(offer.encode()).offerNonce, List.filled(16, 3));
    final accept = UdpAccept(
        channelId: 1,
        addressFamily: UdpAddressFamily.ipv4,
        port: 4321,
        address: [10, 0, 0, 1, ...List.filled(12, 0)],
        offerNonce: offer.offerNonce,
        acceptNonce: List.filled(16, 4));
    expect(UdpAccept.decode(accept.encode()).offerNonce, offer.offerNonce);
  });

  test('UDP_CLOSE uses exact channel and reason fields', () {
    final close = UdpClose(1, UdpCloseReason.networkChanged);
    expect(close.encode(), [0, 0, 0, 1, 0, 3]);
    expect(
        UdpClose.decode(close.encode()).reason, UdpCloseReason.networkChanged);
  });

  test('UDP sidecar directional keys are distinct and deterministic', () async {
    final first = await deriveUdpSidecarKeys(
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        reliableGeneration: 1,
        channelId: 1,
        offerNonce: List.filled(16, 3),
        acceptNonce: List.filled(16, 4));
    final second = await deriveUdpSidecarKeys(
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        reliableGeneration: 1,
        channelId: 1,
        offerNonce: List.filled(16, 3),
        acceptNonce: List.filled(16, 4));
    expect(first.root, second.root);
    expect(first.key0To1, isNot(first.key1To0));
  });
}

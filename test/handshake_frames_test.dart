import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('HELLO plaintext frame uses the exact Section 16 zero header', () async {
    final key = List<int>.generate(32, (index) => index);
    final hello = HelloPayload(
        peerId: await PeerIdentity.peerIdForPublicKey(key),
        identityPublicKey: key,
        ephemeralPublicKey: List.filled(32, 2),
        connectionNonce: List.filled(16, 3),
        peerCapabilities: 1);
    final parsed = LpcFrame.decode(plaintextHelloFrame(hello).encode());
    expect(parsed.protocolMinor, 1);
    expect(parsed.transportGeneration, 0);
    expect(parsed.sequenceNumber, 0);
    expect(parsed.encrypted, isFalse);
    expect((await parsePlaintextHelloFrame(parsed)).peerId, hello.peerId);
  });

  test('AUTH plaintext frame is fixed to a 64-byte payload and zero header',
      () {
    final parsed = LpcFrame.decode(
        plaintextAuthFrame(senderMaxMinor: 1, authPayload: List.filled(64, 9))
            .encode());
    expect(parsePlaintextAuthFrame(parsed), List.filled(64, 9));
    expect(() => plaintextAuthFrame(senderMaxMinor: 1, authPayload: [1]),
        throwsA(isA<LpcException>()));
  });
}

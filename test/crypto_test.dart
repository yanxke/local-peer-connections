import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('Section 17 nonce is generation then sequence in big-endian order', () {
    expect(frameNonce(0x01020304, 5), [1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 5]);
  });
  test('ChaCha20-Poly1305 authenticates the LPC header prefix', () async {
    final plain = LpcFrame(
        type: FrameType.ready,
        flags: 0,
        transportGeneration: 1,
        sequenceNumber: 1,
        messageId: List.filled(8, 0),
        sessionId: List.filled(16, 2),
        nonce: List.filled(12, 0),
        payload: [1, 2]);
    final protected =
        await const FrameProtector().encrypt(plain, List.filled(32, 9));
    expect(protected.nonce, frameNonce(1, 1));
    expect(
        (await const FrameProtector().decrypt(protected, List.filled(32, 9)))
            .payload,
        [1, 2]);
    final tampered = LpcFrame(
        type: FrameType.ready,
        flags: 1,
        transportGeneration: 1,
        sequenceNumber: 1,
        messageId: List.filled(8, 0),
        sessionId: List.filled(16, 2),
        nonce: protected.nonce,
        payload: protected.payload,
        tag: protected.tag);
    expect(() => const FrameProtector().decrypt(tampered, List.filled(32, 9)),
        throwsA(isA<LpcException>()));
  });
  test('traffic keys are generation and direction scoped', () async {
    final root = List<int>.filled(32, 7);
    expect(await (await trafficKey(root, 1, 0)).extractBytes(),
        isNot(await (await trafficKey(root, 2, 0)).extractBytes()));
  });
}

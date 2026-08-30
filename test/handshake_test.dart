import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('transcript canonicalizes HELLO ordering', () async {
    const uuid = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
    expect(
        await handshakeTranscript(
            serviceUuid: uuid, localHello: [2], remoteHello: [1]),
        await handshakeTranscript(
            serviceUuid: uuid, localHello: [1], remoteHello: [2]));
  });
  test('session ID and secrets are deterministic, rather than random',
      () async {
    final first = await deriveHandshakeSecrets(
        baseRootKey: List.filled(32, 1), transcript: List.filled(32, 2));
    final second = await deriveHandshakeSecrets(
        baseRootKey: List.filled(32, 1), transcript: List.filled(32, 2));
    expect(first.sessionId, second.sessionId);
    expect(first.resumeSecret, second.resumeSecret);
  });
  test('UT-006 SAS is six decimal digits', () async {
    expect(
        await sasFor(
            baseRootKey: List.filled(32, 1), transcript: List.filled(32, 2)),
        matches(RegExp(r'^\d{6}$')));
  });
}

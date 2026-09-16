import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-022 initial SessionId is deterministic for one handshake', () async {
    final first = await deriveHandshakeSecrets(
        baseRootKey: List<int>.filled(32, 1),
        transcript: List<int>.filled(32, 2));
    final second = await deriveHandshakeSecrets(
        baseRootKey: List<int>.filled(32, 1),
        transcript: List<int>.filled(32, 2));
    expect(first.sessionId, second.sessionId);
    expect(first.sessionRootKey, second.sessionRootKey);
  });

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
  test('UT-006 SAS matches the HMAC-SHA256 known vector and is six digits',
      () async {
    expect(
        await sasFor(
            baseRootKey: List.filled(32, 1), transcript: List.filled(32, 2)),
        '213524');
  });

  test('UT-008 PSK_32 derives the specified base-root known vector', () async {
    final root = await deriveBaseRootKey(
        sharedSecret: List.filled(32, 3),
        transcript: List.filled(32, 2),
        trustMode: HandshakeTrustMode.psk32,
        psk32: List.filled(32, 1));

    expect(_hex(root),
        'fc91595e36940607b7464e119164c5c8f7b4664cfb86cf220c1bbc357f476c99');
  });
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

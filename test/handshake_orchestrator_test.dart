import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test(
      'portable handshake verifier validates remote AUTH and derives a SessionId',
      () async {
    const uuid = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
    final localIdentity =
        await Ed25519().newKeyPairFromSeed(List.filled(32, 1));
    final remoteIdentity =
        await Ed25519().newKeyPairFromSeed(List.filled(32, 2));
    final localEphemeral =
        await X25519().newKeyPairFromSeed(List.filled(32, 3));
    final remoteEphemeral =
        await X25519().newKeyPairFromSeed(List.filled(32, 4));
    final localHello = HelloPayload(
            peerId: await PeerIdentity.peerIdForPublicKey(
                (await localIdentity.extractPublicKey()).bytes),
            identityPublicKey: (await localIdentity.extractPublicKey()).bytes,
            ephemeralPublicKey: (await localEphemeral.extractPublicKey()).bytes,
            connectionNonce: List.filled(16, 5),
            peerCapabilities: 0x101,
            keepaliveIntervalMs: 2000)
        .encode();
    final remoteHello = HelloPayload(
            peerId: await PeerIdentity.peerIdForPublicKey(
                (await remoteIdentity.extractPublicKey()).bytes),
            identityPublicKey: (await remoteIdentity.extractPublicKey()).bytes,
            ephemeralPublicKey:
                (await remoteEphemeral.extractPublicKey()).bytes,
            connectionNonce: List.filled(16, 6),
            peerCapabilities: 0x003,
            keepaliveIntervalMs: 3000)
        .encode();
    final transcript = await handshakeTranscript(
        serviceUuid: uuid, localHello: localHello, remoteHello: remoteHello);
    final remoteAuth = await createAuthPayload(
        identityKeyPair: remoteIdentity, transcript: transcript);
    final result = await verifyHandshake(
        serviceUuid: uuid,
        localHelloBytes: localHello,
        remoteHelloBytes: remoteHello,
        localIdentityKeyPair: localIdentity,
        localEphemeralKeyPair: localEphemeral,
        remoteAuthPayload: remoteAuth,
        tofuStore: TofuIdentityStore());
    expect(result.secrets.sessionId.length, 16);
    final ready = result.createReady();
    expect(ready.peerCapabilities, 1);
    expect(ready.keepaliveIntervalMs, 3000);
    expect(ready.keepaliveDeadTimeoutMs, 9000);
    result.verifyRemoteReady(ready);
  });
}

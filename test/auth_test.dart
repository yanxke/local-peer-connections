import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-004 AUTH signature verifies only against its identity key',
      () async {
    final pair = await Ed25519().newKeyPairFromSeed(List.filled(32, 1));
    final public = await pair.extractPublicKey();
    final payload = await createAuthPayload(
        identityKeyPair: pair, transcript: List.filled(32, 2));
    await verifyAuthPayload(
        payload: payload,
        identityPublicKey: public.bytes,
        transcript: List.filled(32, 2));
    expect(
        () => verifyAuthPayload(
            payload: payload,
            identityPublicKey: List.filled(32, 3),
            transcript: List.filled(32, 2)),
        throwsA(isA<LpcException>()));
  });
  test('X25519 derives identical non-zero secrets in both directions',
      () async {
    final a = await X25519().newKeyPairFromSeed(List.filled(32, 1));
    final b = await X25519().newKeyPairFromSeed(List.filled(32, 2));
    expect(
        await x25519SharedSecret(
            localKeyPair: a,
            remotePublicKey: (await b.extractPublicKey()).bytes),
        await x25519SharedSecret(
            localKeyPair: b,
            remotePublicKey: (await a.extractPublicKey()).bytes));
  });
  test('UT-050 KNOWN_PEER allowlist admits only listed identities', () {
    final allowed = PeerId(List.filled(16, 1));
    verifyKnownPeerTrust(AllowlistedPeers([allowed]), allowed);
    expect(
        () => verifyKnownPeerTrust(
            AllowlistedPeers([allowed]), PeerId(List.filled(16, 2))),
        throwsA(isA<LpcException>()));
  });
}

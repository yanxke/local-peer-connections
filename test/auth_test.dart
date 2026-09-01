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
    // Ed25519 reference vector for seed 01*32 and
    // SHA256("LPC1-auth" || 02*32). This pins the exact Section 16.8 input,
    // not merely a sign-then-verify round trip.
    expect(
      _hex(payload),
      '4e445498cd7835b95d81edfec8030e1c'
      'e252d9b9a86a8523d21b1d52c080ec44'
      '7a8db0b1f6162de04f6d2f13410cf18e'
      '96462ee5d44b361400f68dd706324809',
    );
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

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

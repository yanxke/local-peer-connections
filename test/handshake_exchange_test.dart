import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

const _uuid = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];

Future<HandshakeExchange> _exchange(
    {required int identitySeed,
    required int ephemeralSeed,
    HandshakeTrustMode trustMode = HandshakeTrustMode.tofu,
    KnownPeerPolicy? knownPeerPolicy,
    int minMinor = 1,
    int maxMinor = 1}) async {
  final identity =
      await Ed25519().newKeyPairFromSeed(List.filled(32, identitySeed));
  final ephemeral =
      await X25519().newKeyPairFromSeed(List.filled(32, ephemeralSeed));
  final public = await identity.extractPublicKey();
  final ephemeralPublic = await ephemeral.extractPublicKey();
  return HandshakeExchange(
      serviceUuid: _uuid,
      localHello: HelloPayload(
          peerId: await PeerIdentity.peerIdForPublicKey(public.bytes),
          identityPublicKey: public.bytes,
          ephemeralPublicKey: ephemeralPublic.bytes,
          connectionNonce: List.filled(16, identitySeed),
          peerCapabilities: 1,
          minMinor: minMinor,
          maxMinor: maxMinor,
          trustMode: trustMode),
      localIdentityKeyPair: identity,
      localEphemeralKeyPair: ephemeral,
      knownPeerPolicy: knownPeerPolicy,
      tofuStore: TofuIdentityStore());
}

void main() {
  test('plaintext handshake controller authenticates HELLO then AUTH',
      () async {
    final a = await _exchange(identitySeed: 1, ephemeralSeed: 3);
    final b = await _exchange(identitySeed: 2, ephemeralSeed: 4);
    final helloA = a.createHello();
    final helloB = b.createHello();
    expect(await a.receivePlaintext(helloB), isNull);
    expect(await b.receivePlaintext(helloA), isNull);
    final authA = await a.createAuth();
    final authB = await b.createAuth();
    await a.receivePlaintext(authB);
    await b.receivePlaintext(authA);
    expect(a.state, HandshakeExchangeState.authenticated);
    expect(b.state, HandshakeExchangeState.authenticated);
    expect(a.result!.secrets.sessionId, b.result!.secrets.sessionId);
  });

  test(
      'UT-082/085 version mismatch returns a local-max pre-key ERROR then closes',
      () async {
    final a = await _exchange(
        identitySeed: 1, ephemeralSeed: 3, minMinor: 1, maxMinor: 1);
    final b = await _exchange(
        identitySeed: 2, ephemeralSeed: 4, minMinor: 0, maxMinor: 0);
    a.createHello();
    final response = await a.receivePlaintext(b.createHello());
    expect(response, isNotNull);
    expect(parsePreKeyProtocolMismatchError(response!).code,
        LpcErrorCode.protocolMismatch);
    expect(response.protocolMinor, a.localHello.maxMinor);
    expect(a.state, HandshakeExchangeState.closed);
    expect(() => a.createAuth(), throwsA(isA<LpcException>()));
  });

  test('UT-089 no minor-0 DATA path exists after negotiation failure',
      () async {
    final a = await _exchange(
      identitySeed: 1,
      ephemeralSeed: 3,
      minMinor: 1,
      maxMinor: 1,
    );
    final legacy = await _exchange(
      identitySeed: 2,
      ephemeralSeed: 4,
      minMinor: 0,
      maxMinor: 0,
    );

    a.createHello();
    final response = await a.receivePlaintext(legacy.createHello());
    expect(response!.type, FrameType.error);
    expect(response.protocolMinor, 1);
    expect(a.state, HandshakeExchangeState.closed);
    expect(() => a.createAuth(), throwsA(isA<LpcException>()));
  });

  test(
      'UT-005 substituted identity has a different PeerId and fails KNOWN_PEER',
      () async {
    final expectedIdentity =
        await Ed25519().newKeyPairFromSeed(List.filled(32, 2));
    final expectedPeerId = await PeerIdentity.peerIdForPublicKey(
        (await expectedIdentity.extractPublicKey()).bytes);
    final substitutedIdentity =
        await Ed25519().newKeyPairFromSeed(List.filled(32, 3));
    final substitutedPeerId = await PeerIdentity.peerIdForPublicKey(
        (await substitutedIdentity.extractPublicKey()).bytes);
    expect(substitutedPeerId, isNot(expectedPeerId));

    final local = await _exchange(
        identitySeed: 1,
        ephemeralSeed: 4,
        trustMode: HandshakeTrustMode.knownPeer,
        knownPeerPolicy: ExpectExactPeer(expectedPeerId));
    final substituted = await _exchange(
        identitySeed: 3,
        ephemeralSeed: 5,
        trustMode: HandshakeTrustMode.knownPeer);
    final localHello = local.createHello();
    final substitutedHello = substituted.createHello();
    await local.receivePlaintext(substitutedHello);
    await substituted.receivePlaintext(localHello);

    final substitutedAuth = await substituted.createAuth();
    expect(
        local.receivePlaintext(substitutedAuth), throwsA(isA<LpcException>()));
  });

  test('SAS remains blocked until explicitly confirmed', () async {
    final a = await _exchange(
        identitySeed: 1, ephemeralSeed: 3, trustMode: HandshakeTrustMode.sas);
    final b = await _exchange(
        identitySeed: 2, ephemeralSeed: 4, trustMode: HandshakeTrustMode.sas);
    final helloA = a.createHello();
    final helloB = b.createHello();
    await a.receivePlaintext(helloB);
    await b.receivePlaintext(helloA);
    final authA = await a.createAuth();
    final authB = await b.createAuth();
    await a.receivePlaintext(authB);
    await b.receivePlaintext(authA);
    expect(a.state, HandshakeExchangeState.awaitingSasConfirmation);
    a.confirmSas(true);
    expect(a.state, HandshakeExchangeState.authenticated);
  });

  test('UT-007 SAS rejection closes before READY can begin', () async {
    final a = await _exchange(
        identitySeed: 1, ephemeralSeed: 3, trustMode: HandshakeTrustMode.sas);
    final b = await _exchange(
        identitySeed: 2, ephemeralSeed: 4, trustMode: HandshakeTrustMode.sas);
    final helloA = a.createHello();
    final helloB = b.createHello();
    await a.receivePlaintext(helloB);
    await b.receivePlaintext(helloA);
    final authA = await a.createAuth();
    final authB = await b.createAuth();
    await a.receivePlaintext(authB);
    await b.receivePlaintext(authA);
    expect(() => a.confirmSas(false), throwsA(isA<LpcException>()));
    expect(a.state, HandshakeExchangeState.closed);
  });

  test('UT-084 plaintext ERROR is rejected after AUTH', () async {
    final a = await _exchange(identitySeed: 1, ephemeralSeed: 3);
    final b = await _exchange(identitySeed: 2, ephemeralSeed: 4);
    final helloA = a.createHello();
    final helloB = b.createHello();
    await a.receivePlaintext(helloB);
    await b.receivePlaintext(helloA);
    final authA = await a.createAuth();
    final authB = await b.createAuth();
    await a.receivePlaintext(authB);
    await b.receivePlaintext(authA);
    expect(a.state, HandshakeExchangeState.authenticated);

    expect(a.receivePlaintext(preKeyProtocolMismatchError(senderMaxMinor: 1)),
        throwsA(isA<LpcException>()));
  });
}

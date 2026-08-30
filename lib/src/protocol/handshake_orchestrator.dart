import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../types.dart';
import 'auth.dart';
import 'control_payload.dart';
import 'handshake.dart';
import 'hello.dart';
import 'keepalive.dart';

class HandshakeResult {
  HandshakeResult(
      {required this.localHello,
      required this.remoteHello,
      required this.localAuthPayload,
      required this.secrets,
      required this.negotiatedMinor,
      this.sas});
  final HelloPayload localHello;
  final HelloPayload remoteHello;
  final Uint8List localAuthPayload;
  final HandshakeSecrets secrets;
  final int negotiatedMinor;
  final String? sas;

  int get negotiatedPeerCapabilities =>
      localHello.peerCapabilities & remoteHello.peerCapabilities;
  KeepaliveTiming get keepaliveTiming => KeepaliveTiming.negotiate(
      localHello.keepaliveIntervalMs, remoteHello.keepaliveIntervalMs);

  ReadyPayload createReady() => ReadyPayload(
      sessionId: secrets.sessionId,
      peerCapabilities: negotiatedPeerCapabilities,
      keepaliveIntervalMs: keepaliveTiming.intervalMs,
      keepaliveDeadTimeoutMs: keepaliveTiming.deadTimeoutMs,
      securityLevel: _securityLevel(localHello.trustMode));

  void verifyRemoteReady(ReadyPayload remote) {
    final expected = createReady();
    if (!_same(remote.sessionId, expected.sessionId) ||
        remote.peerCapabilities != expected.peerCapabilities ||
        remote.keepaliveIntervalMs != expected.keepaliveIntervalMs ||
        remote.keepaliveDeadTimeoutMs != expected.keepaliveDeadTimeoutMs ||
        remote.securityLevel != _securityLevel(remoteHello.trustMode)) {
      throw const LpcException(LpcErrorCode.protocolMismatch,
          'READY does not match handshake agreement');
    }
  }
}

SecurityLevel _securityLevel(HandshakeTrustMode trustMode) =>
    switch (trustMode) {
      HandshakeTrustMode.knownPeer => SecurityLevel.authenticatedKnownPeer,
      HandshakeTrustMode.sas => SecurityLevel.authenticatedSas,
      HandshakeTrustMode.psk32 => SecurityLevel.authenticatedPsk,
      HandshakeTrustMode.tofu => SecurityLevel.encryptedTofu,
    };

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var value = 0;
  for (var i = 0; i < a.length; i++) {
    value |= a[i] ^ b[i];
  }
  return value == 0;
}

/// Completes the local validation side after both plaintext HELLO payloads and
/// the remote AUTH payload have arrived. SAS confirmation remains an explicit
/// application step; this function never promotes a connection to READY.
Future<HandshakeResult> verifyHandshake(
    {required List<int> serviceUuid,
    required List<int> localHelloBytes,
    required List<int> remoteHelloBytes,
    required SimpleKeyPair localIdentityKeyPair,
    required SimpleKeyPair localEphemeralKeyPair,
    required List<int> remoteAuthPayload,
    KnownPeerPolicy? knownPeerPolicy,
    TofuIdentityStore? tofuStore,
    List<int>? psk32}) async {
  final local = await HelloPayload.decode(localHelloBytes);
  final remote = await HelloPayload.decode(remoteHelloBytes);
  final minor = negotiateMinor(
      localMin: local.minMinor,
      localMax: local.maxMinor,
      remoteMin: remote.minMinor,
      remoteMax: remote.maxMinor);
  if (minor != 1 || local.trustMode != remote.trustMode)
    throw const LpcException(
        LpcErrorCode.authenticationFailed, 'incompatible handshake');
  final transcript = await handshakeTranscript(
      serviceUuid: serviceUuid,
      localHello: localHelloBytes,
      remoteHello: remoteHelloBytes);
  await verifyAuthPayload(
      payload: remoteAuthPayload,
      identityPublicKey: remote.identityPublicKey,
      transcript: transcript);
  if (remote.trustMode == HandshakeTrustMode.knownPeer) {
    if (knownPeerPolicy == null)
      throw const LpcException(LpcErrorCode.authenticationFailed);
    verifyKnownPeerTrust(knownPeerPolicy, remote.peerId);
  }
  if (remote.trustMode == HandshakeTrustMode.tofu) {
    if (tofuStore == null)
      throw const LpcException(LpcErrorCode.authenticationFailed);
    tofuStore.verifyOrRemember(remote.peerId, remote.identityPublicKey);
  }
  final shared = await x25519SharedSecret(
      localKeyPair: localEphemeralKeyPair,
      remotePublicKey: remote.ephemeralPublicKey);
  final base = await deriveBaseRootKey(
      sharedSecret: shared,
      transcript: transcript,
      trustMode: remote.trustMode,
      psk32: psk32);
  final secrets =
      await deriveHandshakeSecrets(baseRootKey: base, transcript: transcript);
  return HandshakeResult(
      localHello: local,
      remoteHello: remote,
      localAuthPayload: await createAuthPayload(
          identityKeyPair: localIdentityKeyPair, transcript: transcript),
      secrets: secrets,
      negotiatedMinor: minor!,
      sas: remote.trustMode == HandshakeTrustMode.sas
          ? await sasFor(baseRootKey: base, transcript: transcript)
          : null);
}

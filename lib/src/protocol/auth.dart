import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../types.dart';

/// Section 16.6 X25519 operation. The all-zero shared secret is invalid.
Future<Uint8List> x25519SharedSecret(
    {required SimpleKeyPair localKeyPair,
    required List<int> remotePublicKey}) async {
  if (remotePublicKey.length != 32)
    throw const LpcException(
        LpcErrorCode.authenticationFailed, 'invalid X25519 public key');
  final key = await X25519().sharedSecretKey(
      keyPair: localKeyPair,
      remotePublicKey:
          SimplePublicKey(remotePublicKey, type: KeyPairType.x25519));
  final bytes = Uint8List.fromList(await key.extractBytes());
  if (bytes.every((byte) => byte == 0))
    throw const LpcException(
        LpcErrorCode.authenticationFailed, 'invalid all-zero X25519 secret');
  return bytes;
}

/// Section 16.8 AUTH's payload is exactly an Ed25519 signature (64 bytes).
Future<Uint8List> createAuthPayload(
    {required SimpleKeyPair identityKeyPair,
    required List<int> transcript}) async {
  if (transcript.length != 32)
    throw ArgumentError.value(transcript, 'transcript');
  final digest =
      await Sha256().hash([...ascii.encode('LPC1-auth'), ...transcript]);
  final signature =
      await Ed25519().sign(digest.bytes, keyPair: identityKeyPair);
  if (signature.bytes.length != 64)
    throw StateError('Ed25519 signature length');
  return Uint8List.fromList(signature.bytes);
}

Future<void> verifyAuthPayload(
    {required List<int> payload,
    required List<int> identityPublicKey,
    required List<int> transcript}) async {
  if (payload.length != 64 ||
      identityPublicKey.length != 32 ||
      transcript.length != 32)
    throw const LpcException(LpcErrorCode.authenticationFailed, 'invalid AUTH');
  final digest =
      await Sha256().hash([...ascii.encode('LPC1-auth'), ...transcript]);
  final valid = await Ed25519().verify(digest.bytes,
      signature: Signature(payload,
          publicKey:
              SimplePublicKey(identityPublicKey, type: KeyPairType.ed25519)));
  if (!valid)
    throw const LpcException(LpcErrorCode.authenticationFailed,
        'AUTH signature verification failed');
}

/// Binding-owned persistent storage can use this small policy helper for TOFU.
class TofuIdentityStore {
  final Map<PeerId, Uint8List> _keys = {};
  void verifyOrRemember(PeerId peerId, List<int> publicKey) {
    final existing = _keys[peerId];
    if (existing != null && !_same(existing, publicKey))
      throw const LpcException(
          LpcErrorCode.authenticationFailed, 'TOFU identity changed');
    _keys.putIfAbsent(peerId, () => Uint8List.fromList(publicKey));
  }

  bool _same(List<int> a, List<int> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length, (i) => a[i] ^ b[i])
              .fold(0, (v, x) => v | x) ==
          0;
}

sealed class KnownPeerPolicy {
  const KnownPeerPolicy();
  void verify(PeerId peerId);
}

class ExpectExactPeer extends KnownPeerPolicy {
  const ExpectExactPeer(this.expectedPeerId);
  final PeerId expectedPeerId;
  @override
  void verify(PeerId peerId) {
    if (peerId != expectedPeerId)
      throw const LpcException(
          LpcErrorCode.authenticationFailed, 'unexpected authenticated PeerId');
  }
}

class AllowlistedPeers extends KnownPeerPolicy {
  AllowlistedPeers(Iterable<PeerId> peers) : peers = Set.unmodifiable(peers) {
    if (this.peers.isEmpty) throw ArgumentError.value(peers, 'peers');
  }
  final Set<PeerId> peers;
  @override
  void verify(PeerId peerId) {
    if (!peers.contains(peerId))
      throw const LpcException(LpcErrorCode.authenticationFailed,
          'authenticated PeerId is not allowed');
  }
}

void verifyKnownPeerTrust(KnownPeerPolicy policy, PeerId authenticatedPeerId) =>
    policy.verify(authenticatedPeerId);

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'identity.dart';
import 'types.dart';

/// Platform backends provide durable, protected storage for this key material.
/// The portable core never logs or serializes a private identity key.
abstract interface class IdentityStore {
  Future<SimpleKeyPair> loadOrCreateEd25519KeyPair();
}

class LocalIdentity {
  const LocalIdentity(this.keyPair, this.publicKey, this.peerId);
  final SimpleKeyPair keyPair;
  final SimplePublicKey publicKey;
  final PeerId peerId;
  static Future<LocalIdentity> load(IdentityStore store) async {
    final keyPair = await store.loadOrCreateEd25519KeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return LocalIdentity(keyPair, publicKey,
        await PeerIdentity.peerIdForPublicKey(publicKey.bytes));
  }
}

/// Test-only store. Production Android/iOS backends must replace this with
/// protected durable storage and never use it as a persistence substitute.
class InMemoryIdentityStore implements IdentityStore {
  InMemoryIdentityStore({SimpleKeyPair? keyPair}) : _keyPair = keyPair;
  SimpleKeyPair? _keyPair;
  @override
  Future<SimpleKeyPair> loadOrCreateEd25519KeyPair() async =>
      _keyPair ??= await Ed25519().newKeyPair();
}

/// Android/iOS implementation backed by the plugin's protected platform
/// storage. Only a 32-byte seed crosses into Dart so `cryptography` can use
/// the same Ed25519 implementation as the portable handshake code; it is
/// never persisted by Dart or emitted in diagnostics.
class PlatformIdentityStore implements IdentityStore {
  PlatformIdentityStore({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel(
                'dev.localpeerconnections.local_peer_connections/identity');
  final MethodChannel _channel;

  @override
  Future<SimpleKeyPair> loadOrCreateEd25519KeyPair() async {
    final seed =
        await _channel.invokeMethod<Uint8List>('loadOrCreateEd25519Seed');
    if (seed == null || seed.length != 32) {
      throw const LpcException(LpcErrorCode.platformError,
          'protected identity storage returned an invalid seed');
    }
    return Ed25519().newKeyPairFromSeed(seed);
  }
}

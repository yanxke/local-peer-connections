import 'package:cryptography/cryptography.dart';
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

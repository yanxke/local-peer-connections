import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'types.dart';

/// Section 7 identity helpers. The persistent key store is platform-owned;
/// this portable helper defines the wire-visible PeerId derivation exactly.
abstract final class PeerIdentity {
  static Future<PeerId> peerIdForPublicKey(List<int> ed25519PublicKey) async {
    if (ed25519PublicKey.length != 32) {
      throw ArgumentError.value(ed25519PublicKey.length, 'ed25519PublicKey',
          'Ed25519 public keys are 32 bytes');
    }
    final digest = await Sha256().hash(ed25519PublicKey);
    return PeerId(Uint8List.fromList(digest.bytes.sublist(0, 16)));
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  // UT-003: PeerId is the first 16 bytes of SHA-256(identity public key).
  test('UT-003 derives PeerId from a 32-byte identity key', () async {
    final id =
        await PeerIdentity.peerIdForPublicKey(List<int>.generate(32, (i) => i));
    expect(id.toString(), '630dcd2966c4336691125448bbb25b4f');
  });
}

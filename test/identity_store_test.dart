import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('identity store retains one stable PeerId across runtime initialization',
      () async {
    final store = InMemoryIdentityStore();
    expect((await LocalIdentity.load(store)).peerId,
        (await LocalIdentity.load(store)).peerId);
  });
  test('runtime uses injected identity storage for its local PeerId', () async {
    final store = InMemoryIdentityStore();
    final first = await createRuntime(identityStore: store);
    final second = await createRuntime(identityStore: store);
    expect(first.localPeerId, second.localPeerId);
    await first.close();
    await second.close();
  });
}

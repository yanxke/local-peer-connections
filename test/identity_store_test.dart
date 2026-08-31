import 'package:flutter/services.dart';
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
  test('platform identity store accepts only a 32-byte protected seed',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('identity-store-test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final seed = Uint8List.fromList(List<int>.generate(32, (i) => i));
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'loadOrCreateEd25519Seed');
      return seed;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final store = PlatformIdentityStore(channel: channel);
    expect((await LocalIdentity.load(store)).peerId,
        (await LocalIdentity.load(store)).peerId);
  });
}

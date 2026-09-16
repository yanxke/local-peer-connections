import 'package:flutter_test/flutter_test.dart';
import 'package:lpc_integration_device_app/known_peers.dart';
import 'package:local_peer_connections/local_peer_connections.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'known PeerIds persist and resolve independently of endpoint IDs',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final resolver = PersistentKnownPeerResolver(preferences, const []);
      final peer = PeerId(List<int>.generate(16, (index) => index));

      expect(resolver.hasPeers, isFalse);
      await resolver.remember(peer);
      expect(await resolver.isKnownPeer(peer), isTrue);
      expect(resolver.peerIds, [peer.toString()]);

      final reloaded = PersistentKnownPeerResolver(
        preferences,
        preferences.getStringList(PersistentKnownPeerResolver.storageKey)!,
      );
      expect(await reloaded.isKnownPeer(peer), isTrue);
      await reloaded.forget(peer);
      expect(await reloaded.isKnownPeer(peer), isFalse);
    },
  );

  test('invalid and duplicate persisted values are ignored', () async {
    SharedPreferences.setMockInitialValues({
      PersistentKnownPeerResolver.storageKey: [
        'NOT-A-PEER',
        '00112233445566778899aabbccddeeff',
        '00112233445566778899AABBCCDDEEFF',
      ],
    });
    final preferences = await SharedPreferences.getInstance();
    final resolver = PersistentKnownPeerResolver(
      preferences,
      preferences.getStringList(PersistentKnownPeerResolver.storageKey)!,
    );
    expect(resolver.peerIds, ['00112233445566778899aabbccddeeff']);
  });
}

import 'package:local_peer_connections/local_peer_connections.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistent, application-owned friend list for the LPC device fixture.
/// LPC authenticates the remote identity first; this resolver only decides
/// whether that authenticated PeerId is retained and reconnected.
class PersistentKnownPeerResolver implements KnownPeerResolver {
  PersistentKnownPeerResolver(this.preferences, Iterable<String> peerIds)
    : _peerIds = peerIds
          .where(_isPeerIdString)
          .map((value) => value.toLowerCase())
          .toSet();

  static const storageKey = 'lpc_harness_confirmed_peer_ids';

  final SharedPreferences preferences;
  final Set<String> _peerIds;

  static Future<PersistentKnownPeerResolver> load() async {
    final preferences = await SharedPreferences.getInstance();
    return PersistentKnownPeerResolver(
      preferences,
      preferences.getStringList(storageKey) ?? const <String>[],
    );
  }

  Iterable<String> get peerIds => List.unmodifiable(_peerIds.toList()..sort());
  bool get hasPeers => _peerIds.isNotEmpty;

  @override
  Future<bool> isKnownPeer(PeerId peerId) async =>
      _peerIds.contains(peerId.toString());

  Future<void> remember(PeerId peerId) async {
    if (_peerIds.add(peerId.toString())) await _persist();
  }

  Future<void> forget(PeerId peerId) async {
    if (_peerIds.remove(peerId.toString())) await _persist();
  }

  Future<void> clear() async {
    if (_peerIds.isEmpty) return;
    _peerIds.clear();
    await _persist();
  }

  Future<void> _persist() =>
      preferences.setStringList(storageKey, peerIds.toList());

  static bool _isPeerIdString(String value) =>
      RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(value);
}

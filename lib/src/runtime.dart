import 'dart:async';
import 'dart:math';
import 'group.dart';
import 'identity_store.dart';
import 'types.dart';

enum RuntimeState { created, initializing, ready, failed, closing, closed }

/// Top-level owner for LPC objects. Native BLE implementations are attached via
/// the platform backend; this portable core intentionally owns no BLE types.
class NearbyRuntime {
  NearbyRuntime._(this.config, this.localPeerId) : _state = RuntimeState.ready;
  final RuntimeConfig config;
  final PeerId localPeerId;
  RuntimeState _state;
  final List<GroupSession> _groups = [];
  RuntimeState get state => _state;
  static Future<NearbyRuntime> create(
      {RuntimeConfig config = const RuntimeConfig(),
      PeerId? localPeerId,
      IdentityStore? identityStore}) async {
    config.validate();
    if (localPeerId != null && identityStore != null) {
      throw ArgumentError('provide localPeerId or identityStore, not both');
    }
    final random = Random.secure();
    final peer = localPeerId ??
        (identityStore == null
            ? PeerId(List<int>.generate(16, (_) => random.nextInt(256)))
            : (await LocalIdentity.load(identityStore)).peerId);
    return NearbyRuntime._(config, peer);
  }

  GroupSession joinOrCreateGroup(GroupConfig config) {
    if (_state != RuntimeState.ready)
      throw const LpcException(LpcErrorCode.invalidState);
    final random = Random.secure();
    final group = GroupSession.internal(config, localPeerId,
        GroupId(List<int>.generate(16, (_) => random.nextInt(256))));
    _groups.add(group);
    return group;
  }

  Future<void> close() async {
    if (_state == RuntimeState.closed || _state == RuntimeState.closing) return;
    _state = RuntimeState.closing;
    for (final group in List<GroupSession>.from(_groups)) {
      group.close();
    }
    _groups.clear();
    _state = RuntimeState.closed;
  }
}

/// Convenience factory matching the specification's conceptual entry point.
Future<NearbyRuntime> createRuntime(
        {RuntimeConfig config = const RuntimeConfig(),
        PeerId? localPeerId,
        IdentityStore? identityStore}) =>
    NearbyRuntime.create(
        config: config, localPeerId: localPeerId, identityStore: identityStore);

import 'dart:async';
import 'dart:math';
import 'group.dart';
import 'identity_store.dart';
import 'types.dart';

enum RuntimeState { created, initializing, ready, failed, closing, closed }

sealed class DiscoveryEvent {
  const DiscoveryEvent();
}

class DiscoveryStopped extends DiscoveryEvent {
  const DiscoveryStopped();
}

/// Local opaque endpoint metadata. It is deliberately not a protocol PeerId.
class DiscoveredEndpoint {
  const DiscoveredEndpoint(this.id, {required this.rssi, this.localName});
  final String id;
  final int rssi;
  final String? localName;
}

/// Section 33.3 discovery lifecycle. Scanning is owned separately from any
/// PeerConnection that may have been created from an endpoint.
class DiscoverySession {
  DiscoverySession({Future<void> Function()? stopPlatformScan})
      : _stopPlatformScan = stopPlatformScan ?? _noOp;

  final Future<void> Function() _stopPlatformScan;
  final Map<String, DiscoveredEndpoint> _endpoints = {};
  final StreamController<DiscoveryEvent> _events =
      StreamController<DiscoveryEvent>.broadcast(sync: true);
  bool _stopped = false;

  bool get isStopped => _stopped;
  Stream<DiscoveryEvent> get events => _events.stream;
  List<DiscoveredEndpoint> currentEndpoints() =>
      List.unmodifiable(_endpoints.values.toList());

  /// Backend owners record active scan results here. Once stopped, no further
  /// endpoint changes are retained or emitted.
  void recordEndpoint(DiscoveredEndpoint endpoint) {
    if (_stopped) return;
    _endpoints[endpoint.id] = endpoint;
  }

  /// Stops scanning once and emits exactly one terminal discovery event. It
  /// intentionally neither owns nor closes established PeerConnections.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _stopPlatformScan();
    _events.add(const DiscoveryStopped());
  }
}

Future<void> _noOp() async {}

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

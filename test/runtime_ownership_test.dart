import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('UT-199 direct and group ownership reuse one authenticated connection',
      () async {
    final link = await _RuntimeLink.create();
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();

    final attempt = link.a.connect('link');
    final connection = await _connectedPeer(attempt);
    await _hostPeer(host);
    final group = link.a.joinOrCreateGroup(_groupConfig());
    group.commitMembership([
      GroupMember(link.a.localPeerId, 8),
      GroupMember(link.b.localPeerId, 8),
    ], coordinator: link.a.localPeerId);
    await Future<void>.delayed(Duration.zero);

    expect(group.members.map((member) => member.peerId),
        contains(link.b.localPeerId));
    expect(connection.state, PeerConnectionState.ready);
    expect((await _hostPeer(host)).state, PeerConnectionState.ready);
    expect(link.aGattConnected, 1);
    expect(link.bGattConnected, 0);

    await link.close();
  });

  test('UT-200 releasing HostSession ownership preserves group ownership',
      () async {
    final link = await _RuntimeLink.create();
    final host = link.a.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();

    final attempt = link.b.connect('link');
    final connection = await _connectedPeer(attempt);
    final hostPeer = await _hostPeer(host);
    final hostSnapshot = host.peers();
    expect(hostSnapshot, hasLength(1));
    expect(() => hostSnapshot.clear(), throwsUnsupportedError);
    final group = link.a.joinOrCreateGroup(_groupConfig());
    group.commitMembership([
      GroupMember(link.a.localPeerId, 8),
      GroupMember(link.b.localPeerId, 8),
    ], coordinator: link.a.localPeerId);
    await Future<void>.delayed(Duration.zero);

    await host.disconnect(hostPeer.peerId);
    expect(host.peers(), isEmpty);
    expect(hostSnapshot, hasLength(1));
    expect(connection.state, PeerConnectionState.ready);
    expect(link.aCloseCalls, 0);

    await link.close();
  });

  test('terminal ConnectionAttempt cancellation is a no-op', () async {
    final link = await _RuntimeLink.create();
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();

    final attempt = link.a.connect('link');
    final connection = await _connectedPeer(attempt);
    expect(connection.state, PeerConnectionState.ready);
    final closesBeforeCancel = link.aCloseCalls;

    await attempt.cancel();

    expect(link.aCloseCalls, closesBeforeCancel);
    expect(connection.state, PeerConnectionState.ready);
    await link.close();
  });

  test('PeerConnection disconnect is idempotent', () async {
    final link = await _RuntimeLink.create();
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();

    final connection = await _connectedPeer(link.a.connect('link'));
    final events = <PeerConnectionEvent>[];
    final subscription = connection.events.listen(events.add);

    await Future.wait([connection.disconnect(), connection.disconnect()]);
    await connection.disconnect();

    expect(connection.state, PeerConnectionState.disconnected);
    expect(events.whereType<PeerDisconnected>(), hasLength(1));
    await subscription.cancel();
    await link.close();
  });

  test('UT-203 releasing direct retention preserves group ownership', () async {
    final link = await _RuntimeLink.create();
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();

    final attempt = link.a.connect('link');
    final connection = await _connectedPeer(attempt);
    await _hostPeer(host);
    final group = link.a.joinOrCreateGroup(_groupConfig());
    group.commitMembership([
      GroupMember(link.a.localPeerId, 8),
      GroupMember(link.b.localPeerId, 8),
    ], coordinator: link.a.localPeerId);
    await Future<void>.delayed(Duration.zero);

    await link.a.releasePeerRetention(connection.peerId);
    expect(connection.state, PeerConnectionState.ready);
    expect(link.aCloseCalls, 0);

    await link.close();
  });

  test('UT-201 TOFU peer is not adopted by a GROUP_PSK_32 owner', () async {
    final link = await _RuntimeLink.create();
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();
    final attempt = link.a.connect('link');
    final connection = await _connectedPeer(attempt);
    await _hostPeer(host);

    final group = link.a.joinOrCreateGroup(GroupConfig(
      applicationNamespace: const [1],
      groupJoinToken: List<int>.filled(16, 2),
      groupTrustMode: GroupTrustMode.groupPsk32,
      groupPsk32: List<int>.filled(32, 4),
    ));
    group.commitMembership([
      GroupMember(link.a.localPeerId, 8),
      GroupMember(link.b.localPeerId, 8),
    ], coordinator: link.a.localPeerId);
    await Future<void>.delayed(Duration.zero);

    expect(group.members.map((member) => member.peerId),
        contains(connection.peerId));
    final send = group.send(connection.peerId, [1]);
    expect(await send.completed, SendState.failed);
    expect(connection.state, PeerConnectionState.ready);

    await link.close();
  });

  test('UT-204 releasePeerRetention invalidates known-peer cache', () async {
    final resolver = _CountingKnownPeerResolver();
    final link = await _RuntimeLink.create(
        configA: RuntimeConfig(
      trustMode: HandshakeTrustMode.tofu,
      autoConnectKnownPeers: true,
      knownPeerResolver: resolver,
      reconnectTimeoutMs: 1000,
    ));
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();
    final discovery = await link.a.startDiscovery();
    final first =
        link.a.events.firstWhere((event) => event is KnownPeerConnected);
    link.discoverA('known-endpoint');
    final firstEvent = await first as KnownPeerConnected;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await link.a.releasePeerRetention(firstEvent.connection.peerId);
    expect(resolver.lookups, 1);

    final second =
        link.a.events.firstWhere((event) => event is KnownPeerConnected);
    link.discoverA('known-endpoint');
    await second;
    expect(resolver.lookups, 2);

    await discovery.stop();
    await link.close();
  });

  test('UT-205 final HostSession release closes the connection', () async {
    final link = await _RuntimeLink.create();
    final host = link.a.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();
    final attempt = link.b.connect('link');
    final connection = await _connectedPeer(attempt);
    final hostPeer = await _hostPeer(host);

    await host.disconnect(hostPeer.peerId);
    expect(host.peers(), isEmpty);
    expect(link.aCloseCalls, 1);
    expect(connection.state, isNot(PeerConnectionState.ready));

    await link.close();
  });

  test('UT-206 connect reuses an existing READY connection', () async {
    final link = await _RuntimeLink.create();
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();
    final firstAttempt = link.a.connect('link');
    final first = await _connectedPeer(firstAttempt);
    await _hostPeer(host);
    expect(link.aGattConnected, 1);

    final secondAttempt = link.a.connect('link');
    final second = await _connectedPeer(secondAttempt);
    expect(identical(second, first), isTrue);
    expect(link.aGattConnected, 1);

    await link.close();
  });

  test('duplicate GATT readiness callbacks start one handshake', () async {
    final link = await _RuntimeLink.create(duplicateGattCallbacks: true);
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();
    final attempt = link.a.connect('link');
    final connection = await _connectedPeer(attempt);
    final hostPeer = await _hostPeer(host);

    expect(connection.state, PeerConnectionState.ready);
    expect(hostPeer.state, PeerConnectionState.ready);
    expect(link.aGattConnected, 1);
    expect(link.aGattCallbacks, 2);
    expect(link.bGattCallbacks, 2);
    expect(host.peers(), hasLength(1));

    await link.close();
  });

  test('central-side transport loss automatically resumes the peer', () async {
    final link = await _RuntimeLink.create(
      configA: RuntimeConfig(
        trustMode: HandshakeTrustMode.tofu,
        autoReconnect: true,
        reconnectTimeoutMs: 4000,
      ),
      configB: RuntimeConfig(
        trustMode: HandshakeTrustMode.tofu,
        autoReconnect: true,
        reconnectTimeoutMs: 4000,
      ),
    );
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();
    final attempt = link.a.connect('link');
    final connection = await _connectedPeer(attempt);
    await _hostPeer(host);

    link.dropBoth();
    await _waitForState(connection, PeerConnectionState.reconnecting);
    await _waitForState(connection, PeerConnectionState.ready,
        timeout: const Duration(seconds: 3));

    expect(connection.state, PeerConnectionState.ready);
    expect(link.aGattConnected, 2);
    expect(host.peers(), hasLength(1));

    await link.close();
  });

  test('connect while reconnecting reuses the existing logical peer', () async {
    final link = await _RuntimeLink.create(
      configA: const RuntimeConfig(
        trustMode: HandshakeTrustMode.tofu,
        autoReconnect: true,
        reconnectTimeoutMs: 4000,
      ),
      configB: const RuntimeConfig(
        trustMode: HandshakeTrustMode.tofu,
        autoReconnect: true,
        reconnectTimeoutMs: 4000,
      ),
    );
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();
    final first = await _connectedPeer(link.a.connect('link'));
    await _hostPeer(host);

    link.dropBoth();
    await _waitForState(first, PeerConnectionState.reconnecting);
    final reused = await _connectedPeer(link.a.connect('link'));

    expect(identical(reused, first), isTrue);
    expect(link.aGattConnected, 2);
    expect(host.peers(), hasLength(1));

    await link.close();
  });

  test('reconnect timeout terminally removes the peer from the host', () async {
    final link = await _RuntimeLink.create(
      configA: const RuntimeConfig(
        trustMode: HandshakeTrustMode.tofu,
        autoReconnect: true,
        reconnectTimeoutMs: 1000,
      ),
      configB: const RuntimeConfig(
        trustMode: HandshakeTrustMode.tofu,
        autoReconnect: true,
        reconnectTimeoutMs: 1000,
      ),
    );
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();
    final connection = await _connectedPeer(link.a.connect('link'));
    await _hostPeer(host);

    link.dropBoth(suppressReconnects: true);
    await _waitForState(connection, PeerConnectionState.reconnecting);
    await _waitForState(connection, PeerConnectionState.disconnected,
        timeout: const Duration(seconds: 2));
    await _waitFor(() => host.peers().isEmpty,
        timeout: const Duration(seconds: 2));

    expect(host.peers(), isEmpty);
    expect(link.aGattConnected, 2);
    expect(link.aGattCallbacks, 1);

    await link.close();
  });

  test('known-peer resolver runs after authentication and retains once',
      () async {
    final resolver = _CountingKnownPeerResolver();
    final link = await _RuntimeLink.create(
      configA: RuntimeConfig(
        trustMode: HandshakeTrustMode.tofu,
        autoConnectKnownPeers: true,
        knownPeerResolver: resolver,
        reconnectTimeoutMs: 1000,
      ),
    );
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();
    final discovery = await link.a.startDiscovery();
    final events = <RuntimeEvent>[];
    final subscription = link.a.events.listen(events.add);

    link.discoverA('known-endpoint');
    await _waitFor(() => events.whereType<KnownPeerConnected>().length == 1);
    final connected = events.whereType<KnownPeerConnected>().single;

    expect(resolver.lookups, 1);
    expect(resolver.peerIds, [link.b.localPeerId]);
    expect(connected.discoveryEndpointId, 'known-endpoint');
    expect(connected.connection.state, PeerConnectionState.ready);

    link.discoverA('known-endpoint');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events.whereType<KnownPeerConnected>(), hasLength(1));
    expect(resolver.lookups, 1);

    await subscription.cancel();
    await discovery.stop();
    expect(connected.connection.state, PeerConnectionState.ready);
    await link.close();
  });

  test('unknown automatic probe emits identification and releases peer',
      () async {
    final resolver = _CountingKnownPeerResolver(result: false);
    final link = await _RuntimeLink.create(
      configA: RuntimeConfig(
        trustMode: HandshakeTrustMode.tofu,
        autoConnectKnownPeers: true,
        knownPeerResolver: resolver,
        reconnectTimeoutMs: 1000,
      ),
    );
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();
    final discovery = await link.a.startDiscovery();
    final events = <RuntimeEvent>[];
    final subscription = link.a.events.listen(events.add);

    link.discoverA('unknown-endpoint');
    await _waitFor(() => events.whereType<UnknownPeerIdentified>().length == 1);
    final unknown = events.whereType<UnknownPeerIdentified>().single;

    expect(resolver.peerIds, [link.b.localPeerId]);
    expect(unknown.discoveryEndpointId, 'unknown-endpoint');
    expect(events.whereType<KnownPeerConnected>(), isEmpty);
    await _waitForState(unknown.connection, PeerConnectionState.disconnected);

    await subscription.cancel();
    await discovery.stop();
    await link.close();
  });

  test('UT-185 resolver failure is conservative for an automatic probe',
      () async {
    final link = await _RuntimeLink.create(
      configA: RuntimeConfig(
        trustMode: HandshakeTrustMode.tofu,
        autoConnectKnownPeers: true,
        knownPeerResolver: _ThrowingKnownPeerResolver(),
        reconnectTimeoutMs: 1000,
      ),
    );
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();
    final discovery = await link.a.startDiscovery();
    final events = <RuntimeEvent>[];
    final subscription = link.a.events.listen(events.add);

    link.discoverA('resolver-failure-endpoint');
    await _waitFor(() => events.whereType<UnknownPeerIdentified>().length == 1);
    final unknown = events.whereType<UnknownPeerIdentified>().single;

    expect(unknown.discoveryEndpointId, 'resolver-failure-endpoint');
    expect(events.whereType<KnownPeerConnected>(), isEmpty);
    await _waitForState(unknown.connection, PeerConnectionState.disconnected);

    await subscription.cancel();
    await discovery.stop();
    await link.close();
  });

  test('UT-185 resolver timeout is conservative for an automatic probe',
      () async {
    final resolver = _SlowKnownPeerResolver();
    final link = await _RuntimeLink.create(
      configA: RuntimeConfig(
        trustMode: HandshakeTrustMode.tofu,
        autoConnectKnownPeers: true,
        knownPeerResolver: resolver,
        knownPeerLookupTimeoutMs: 100,
        reconnectTimeoutMs: 1000,
      ),
    );
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();
    final discovery = await link.a.startDiscovery();
    final events = <RuntimeEvent>[];
    final subscription = link.a.events.listen(events.add);

    link.discoverA('resolver-timeout-endpoint');
    await _waitFor(() => events.whereType<UnknownPeerIdentified>().length == 1,
        timeout: const Duration(seconds: 2));
    final unknown = events.whereType<UnknownPeerIdentified>().single;

    expect(unknown.discoveryEndpointId, 'resolver-timeout-endpoint');
    expect(events.whereType<KnownPeerConnected>(), isEmpty);
    resolver.complete();
    await _waitForState(unknown.connection, PeerConnectionState.disconnected);

    await subscription.cancel();
    await discovery.stop();
    await link.close();
  });

  test('known peer can be rediscovered through a new endpoint', () async {
    final resolver = _CountingKnownPeerResolver();
    final link = await _RuntimeLink.create(
      configA: RuntimeConfig(
        trustMode: HandshakeTrustMode.tofu,
        autoConnectKnownPeers: true,
        knownPeerResolver: resolver,
        reconnectTimeoutMs: 1000,
      ),
    );
    final host = link.b.createHostSession(HostConfig(autoAccept: true));
    await host.startAdvertising();
    final discovery = await link.a.startDiscovery();
    final events = <RuntimeEvent>[];
    final subscription = link.a.events.listen(events.add);

    link.discoverA('first-endpoint');
    await _waitFor(() => events.whereType<KnownPeerConnected>().length == 1);
    final first = events.whereType<KnownPeerConnected>().single;
    await link.a.releasePeerRetention(first.connection.peerId);
    await _waitForState(first.connection, PeerConnectionState.disconnected);

    link.discoverA('second-endpoint');
    await _waitFor(() => events.whereType<KnownPeerConnected>().length == 2);
    final second = events.whereType<KnownPeerConnected>().last;

    expect(second.connection.peerId, first.connection.peerId);
    expect(second.discoveryEndpointId, 'second-endpoint');
    expect(resolver.lookups, 2);

    await subscription.cancel();
    await discovery.stop();
    await link.close();
  });
}

GroupConfig _groupConfig() => GroupConfig(
      applicationNamespace: const [1],
      groupJoinToken: List<int>.filled(16, 2),
      groupTrustMode: GroupTrustMode.openTofu,
    );

Future<PeerConnection> _connectedPeer(ConnectionAttempt attempt) async {
  final event = await attempt.events
      .firstWhere((event) => event is ConnectionAttemptConnected);
  return (event as ConnectionAttemptConnected).connection;
}

Future<PeerConnection> _hostPeer(HostSession host) async {
  for (var i = 0; i < 100 && host.peers().isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final peers = host.peers();
  if (peers.isEmpty) throw StateError('timed out waiting for host peer');
  return peers.single;
}

Future<void> _waitForState(PeerConnection connection, PeerConnectionState state,
    {Duration timeout = const Duration(seconds: 1)}) async {
  final deadline = DateTime.now().add(timeout);
  while (connection.state != state && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(connection.state, state);
}

Future<void> _waitFor(bool Function() condition,
    {Duration timeout = const Duration(seconds: 1)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

class _RuntimeLink {
  final MethodChannel _aMethods = const MethodChannel('runtime-link-a');
  final MethodChannel _bMethods = const MethodChannel('runtime-link-b');
  final StreamController<PlatformBleEvent> _aEvents =
      StreamController<PlatformBleEvent>.broadcast();
  final StreamController<PlatformBleEvent> _bEvents =
      StreamController<PlatformBleEvent>.broadcast();
  final bool duplicateGattCallbacks;
  bool suppressReconnects = false;
  late final NearbyRuntime a;
  late final NearbyRuntime b;
  int aGattConnected = 0;
  int bGattConnected = 0;
  int aGattCallbacks = 0;
  int bGattCallbacks = 0;
  int aCloseCalls = 0;
  int bCloseCalls = 0;

  void discoverA(String endpointId) {
    _aEvents.add(PlatformEndpointFound(endpointId, rssi: -40));
  }

  static Future<_RuntimeLink> create(
      {RuntimeConfig? configA,
      RuntimeConfig? configB,
      bool duplicateGattCallbacks = false}) async {
    final link = _RuntimeLink._(duplicateGattCallbacks);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(link._aMethods, link._handleA);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(link._bMethods, link._handleB);
    final config = RuntimeConfig(trustMode: HandshakeTrustMode.tofu);
    link.a = await createRuntime(
      config: configA ?? config,
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(
        methods: link._aMethods,
        eventStream: link._aEvents.stream,
      ),
    );
    link.b = await createRuntime(
      config: configB ?? config,
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(
        methods: link._bMethods,
        eventStream: link._bEvents.stream,
      ),
    );
    return link;
  }

  _RuntimeLink._(this.duplicateGattCallbacks);

  Future<Object?> _handleA(MethodCall call) => _handle(call, true);
  Future<Object?> _handleB(MethodCall call) => _handle(call, false);

  Future<Object?> _handle(MethodCall call, bool fromA) async {
    final ownEvents = fromA ? _aEvents : _bEvents;
    final peerEvents = fromA ? _bEvents : _aEvents;
    final arguments = call.arguments is Map
        ? call.arguments as Map<Object?, Object?>
        : const <Object?, Object?>{};
    final endpoint = arguments['endpointId'] as String?;
    switch (call.method) {
      case 'connectGatt':
        if (fromA) {
          aGattConnected++;
        } else {
          bGattConnected++;
        }
        if (suppressReconnects) return null;
        final linkEndpoint = endpoint ?? 'link';
        final callbacks = duplicateGattCallbacks ? 2 : 1;
        for (var remaining = callbacks; remaining > 0; remaining--) {
          if (fromA) {
            aGattCallbacks++;
            bGattCallbacks++;
          } else {
            bGattCallbacks++;
            aGattCallbacks++;
          }
          ownEvents.add(PlatformGattConnected(linkEndpoint, 'central'));
          peerEvents.add(PlatformGattConnected(linkEndpoint, 'peripheral'));
        }
        return null;
      case 'submitGattFragment':
        final fragment = arguments['fragment'] as Uint8List;
        peerEvents.add(PlatformGattFragment(endpoint ?? 'link', fragment));
        return 'submitted';
      case 'closeGattConnection':
        if (fromA) {
          aCloseCalls++;
        } else {
          bCloseCalls++;
        }
        peerEvents.add(PlatformGattDisconnected(endpoint ?? 'link'));
        return null;
      default:
        return null;
    }
  }

  void dropBoth({bool suppressReconnects = false}) {
    this.suppressReconnects = suppressReconnects;
    _aEvents.add(const PlatformGattDisconnected('link'));
    _bEvents.add(const PlatformGattDisconnected('link'));
  }

  Future<void> close() async {
    await a.close();
    await b.close();
    await _aEvents.close();
    await _bEvents.close();
  }
}

class _CountingKnownPeerResolver implements KnownPeerResolver {
  _CountingKnownPeerResolver({this.result = true});

  final bool result;
  int lookups = 0;
  final List<PeerId> peerIds = <PeerId>[];

  @override
  Future<bool> isKnownPeer(PeerId peerId) async {
    lookups++;
    peerIds.add(peerId);
    return result;
  }
}

class _ThrowingKnownPeerResolver implements KnownPeerResolver {
  @override
  Future<bool> isKnownPeer(PeerId peerId) async {
    throw StateError('resolver unavailable');
  }
}

class _SlowKnownPeerResolver implements KnownPeerResolver {
  final Completer<bool> _result = Completer<bool>();

  @override
  Future<bool> isKnownPeer(PeerId peerId) => _result.future;

  void complete() {
    if (!_result.isCompleted) _result.complete(true);
  }
}

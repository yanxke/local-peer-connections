import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('UT-187 known-peer resolver cache evicts by PeerId capacity', () async {
    final resolver = _CountingResolver();
    final link = await _ThreeRuntimeLink.create(
      configA: RuntimeConfig(
        trustMode: HandshakeTrustMode.tofu,
        autoConnectKnownPeers: true,
        knownPeerResolver: resolver,
        maxKnownPeerCacheEntries: 1,
        reconnectTimeoutMs: 1000,
      ),
    );
    final oneHost = link.one.createHostSession(HostConfig(autoAccept: true));
    final twoHost = link.two.createHostSession(HostConfig(autoAccept: true));
    await oneHost.startAdvertising();
    await twoHost.startAdvertising();
    final discovery = await link.a.startDiscovery();
    final events = <RuntimeEvent>[];
    final subscription = link.a.events.listen(events.add);

    link.discoverA('one-first');
    await _waitUntil(() => events.whereType<KnownPeerConnected>().length == 1,
        description: 'first known peer connects');
    final first = events.whereType<KnownPeerConnected>().first;

    link.discoverA('two-first');
    await _waitUntil(() => events.whereType<KnownPeerConnected>().length == 2,
        description: 'second known peer connects');
    final second = events.whereType<KnownPeerConnected>().last;
    expect(second.connection.peerId, isNot(first.connection.peerId));
    expect(resolver.lookups, 2);

    // Peer one remains connected, but its cache entry was evicted by peer two.
    // A new platform endpoint for the same authenticated PeerId must therefore
    // perform a future resolver lookup instead of relying on endpoint identity.
    link.discoverA('one-second');
    await _waitUntil(() => resolver.lookups == 3,
        description: 'evicted known peer is looked up again');
    await Future<void>.delayed(Duration.zero);
    expect(events.whereType<KnownPeerConnected>(), hasLength(3));
    final rediscovered = events.whereType<KnownPeerConnected>().last;

    expect(rediscovered.connection.peerId, first.connection.peerId);
    expect(rediscovered.discoveryEndpointId, 'one-second');
    expect(resolver.lookups, 3);

    await subscription.cancel();
    await discovery.stop();
    await link.close();
  });
}

Future<void> _waitUntil(bool Function() condition,
    {required String description,
    Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: description);
}

class _CountingResolver implements KnownPeerResolver {
  int lookups = 0;

  @override
  Future<bool> isKnownPeer(PeerId peerId) async {
    lookups++;
    return true;
  }
}

class _ThreeRuntimeLink {
  _ThreeRuntimeLink._();

  final MethodChannel _aMethods = const MethodChannel('runtime-cache-link-a');
  final MethodChannel _oneMethods =
      const MethodChannel('runtime-cache-link-one');
  final MethodChannel _twoMethods =
      const MethodChannel('runtime-cache-link-two');
  final StreamController<PlatformBleEvent> _aEvents =
      StreamController<PlatformBleEvent>.broadcast();
  final StreamController<PlatformBleEvent> _oneEvents =
      StreamController<PlatformBleEvent>.broadcast();
  final StreamController<PlatformBleEvent> _twoEvents =
      StreamController<PlatformBleEvent>.broadcast();
  late final NearbyRuntime a;
  late final NearbyRuntime one;
  late final NearbyRuntime two;

  static Future<_ThreeRuntimeLink> create({RuntimeConfig? configA}) async {
    final link = _ThreeRuntimeLink._();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(link._aMethods, link._handleA);
    messenger.setMockMethodCallHandler(link._oneMethods, link._handleOne);
    messenger.setMockMethodCallHandler(link._twoMethods, link._handleTwo);
    final config = const RuntimeConfig(trustMode: HandshakeTrustMode.tofu);
    link.a = await createRuntime(
      config: configA ?? config,
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(
        methods: link._aMethods,
        eventStream: link._aEvents.stream,
      ),
    );
    link.one = await createRuntime(
      config: config,
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(
        methods: link._oneMethods,
        eventStream: link._oneEvents.stream,
      ),
    );
    link.two = await createRuntime(
      config: config,
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(
        methods: link._twoMethods,
        eventStream: link._twoEvents.stream,
      ),
    );
    return link;
  }

  void discoverA(String endpointId) {
    _aEvents.add(PlatformEndpointFound(endpointId, rssi: -40));
  }

  Future<Object?> _handleA(MethodCall call) async {
    final arguments = call.arguments is Map
        ? call.arguments as Map<Object?, Object?>
        : const <Object?, Object?>{};
    final endpoint = arguments['endpointId'] as String? ?? 'one-first';
    final remote = endpoint.startsWith('two-') ? _twoEvents : _oneEvents;
    switch (call.method) {
      case 'connectGatt':
        _aEvents.add(PlatformGattConnected(endpoint, 'central'));
        remote.add(PlatformGattConnected(endpoint, 'peripheral'));
        return null;
      case 'submitGattFragment':
        remote.add(
            PlatformGattFragment(endpoint, arguments['fragment'] as Uint8List));
        return 'submitted';
      case 'closeGattConnection':
        remote.add(PlatformGattDisconnected(endpoint));
        return null;
      default:
        return null;
    }
  }

  Future<Object?> _handleOne(MethodCall call) => _handleRemote(call);

  Future<Object?> _handleTwo(MethodCall call) => _handleRemote(call);

  Future<Object?> _handleRemote(MethodCall call) async {
    final arguments = call.arguments is Map
        ? call.arguments as Map<Object?, Object?>
        : const <Object?, Object?>{};
    final endpoint = arguments['endpointId'] as String? ?? 'one-first';
    switch (call.method) {
      case 'submitGattFragment':
        _aEvents.add(
            PlatformGattFragment(endpoint, arguments['fragment'] as Uint8List));
        return 'submitted';
      case 'closeGattConnection':
        _aEvents.add(PlatformGattDisconnected(endpoint));
        return null;
      default:
        return null;
    }
  }

  Future<void> close() async {
    await a.close();
    await one.close();
    await two.close();
    await _aEvents.close();
    await _oneEvents.close();
    await _twoEvents.close();
  }
}

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('UT-158 runtime owns one service-scoped discovery session', () async {
    const methods = MethodChannel('runtime-discovery-test');
    var starts = 0;
    var stops = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'startDiscovery') starts++;
      if (call.method == 'stopDiscovery') stops++;
      return null;
    });
    final events = StreamController<PlatformBleEvent>.broadcast();
    final runtime = await createRuntime(
      localPeerId: PeerId(List.filled(16, 1)),
      platformBleBackend:
          PlatformBleBackend(methods: methods, eventStream: events.stream),
    );

    final discovery = await runtime.startDiscovery();
    expect(starts, 1);
    await expectLater(runtime.startDiscovery(), throwsA(isA<LpcException>()));
    events.add(const PlatformEndpointFound('endpoint', rssi: -40));
    await Future<void>.delayed(Duration.zero);
    expect(discovery.currentEndpoints().single.id, 'endpoint');

    await runtime.close();
    expect(stops, 1);
    expect(discovery.isStopped, isTrue);
    await events.close();
  });

  test('runtime without a platform backend does not claim discovery', () async {
    final runtime =
        await createRuntime(localPeerId: PeerId(List.filled(16, 1)));
    expect(runtime.capabilities(),
        completion(isA<LocalRuntimeCapabilityBitmap>()));
    await expectLater(runtime.startDiscovery(), throwsA(isA<LpcException>()));
  });

  test('UT-170 RuntimeConfig defaults to SAS and validates trust credentials',
      () {
    const defaults = RuntimeConfig();
    expect(defaults.trustMode, HandshakeTrustMode.sas);
    expect(
        () => RuntimeConfig(trustMode: HandshakeTrustMode.psk32).validate(),
        throwsA(isA<LpcException>()
            .having((error) => error.code, 'code', LpcErrorCode.invalidState)));
    expect(
        () => RuntimeConfig(trustMode: HandshakeTrustMode.knownPeer).validate(),
        throwsA(isA<LpcException>()
            .having((error) => error.code, 'code', LpcErrorCode.invalidState)));
    RuntimeConfig(
            trustMode: HandshakeTrustMode.knownPeer,
            expectedPeerId: PeerId(List.filled(16, 7)))
        .validate();
    RuntimeConfig(
            trustMode: HandshakeTrustMode.psk32, psk32: List.filled(32, 9))
        .validate();
  });

  test('UT-159 runtime multiplexes compatible HostSession advertising demand',
      () async {
    const methods = MethodChannel('runtime-host-test');
    var starts = 0;
    var stops = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'startAdvertising') starts++;
      if (call.method == 'stopAdvertising') stops++;
      return null;
    });
    final runtime = await createRuntime(
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(methods: methods),
    );
    final first = runtime.createHostSession(HostConfig());
    final second = runtime.createHostSession(HostConfig());

    await first.startAdvertising();
    await second.startAdvertising();
    expect(starts, 1);
    await first.stopAdvertising();
    expect(stops, 0);
    await runtime.close();
    expect(starts, 1);
    expect(stops, 1);
    expect(first.isClosed, isTrue);
    expect(second.isClosed, isTrue);
  });

  test('UT-192 RuntimeConfig validates local application metadata bounds', () {
    RuntimeConfig(applicationMetadata: const []).validate();
    RuntimeConfig(applicationMetadata: List.filled(31, 1)).validate();
    expect(
        () => RuntimeConfig(applicationMetadata: List.filled(32, 1)).validate(),
        throwsA(isA<LpcException>()));
  });

  test('UT-202 presentation refreshes advertising without changing identity',
      () async {
    const methods = MethodChannel('runtime-presentation-test');
    final names = <String?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'startAdvertising') {
        names.add((call.arguments as Map)['localName'] as String?);
      }
      return null;
    });
    final runtime = await createRuntime(
      config: const RuntimeConfig(discoveryDisplayName: 'Silver Otter 4827'),
      localPeerId: PeerId(List.filled(16, 9)),
      platformBleBackend: PlatformBleBackend(methods: methods),
    );
    final peerId = runtime.localPeerId;
    final host = runtime.createHostSession(HostConfig());
    await host.startAdvertising();
    await runtime.updateLocalPresentation(
        LocalPresentation(discoveryDisplayName: 'Quiet Maple 1934'));
    expect(names, ['Silver Otter 4827', 'Quiet Maple 1934']);
    expect(runtime.localPeerId, peerId);
    await runtime.close();
  });

  test('UT-196/197/198 shared Host, Group, and Discovery demand is multiplexed',
      () async {
    const methods = MethodChannel('runtime-shared-demand-test');
    var advertisingStarts = 0;
    var advertisingStops = 0;
    var scanStarts = 0;
    var scanStops = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'startAdvertising':
          advertisingStarts++;
          break;
        case 'stopAdvertising':
          advertisingStops++;
          break;
        case 'startDiscovery':
          scanStarts++;
          break;
        case 'stopDiscovery':
          scanStops++;
          break;
      }
      return null;
    });
    final runtime = await createRuntime(
      localPeerId: PeerId(List.filled(16, 4)),
      platformBleBackend: PlatformBleBackend(methods: methods),
    );
    final host = runtime.createHostSession(HostConfig());
    await host.startAdvertising();
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 3)));
    await Future<void>.delayed(Duration.zero);
    expect(advertisingStarts, 1);
    expect(scanStarts, 1);

    final discovery = await runtime.startDiscovery();
    expect(scanStarts, 1);
    await host.stopAdvertising();
    expect(advertisingStops, 0);
    group.close();
    await Future<void>.delayed(Duration.zero);
    expect(advertisingStops, 1);
    expect(scanStops, 0);
    await discovery.stop();
    expect(scanStops, 1);
    await runtime.close();
  });

  test('UT-164 runtime close cancels every nonterminal connection attempt',
      () async {
    const methods = MethodChannel('runtime-attempt-ownership-test');
    var connects = 0;
    var closes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'connectGatt') connects++;
      if (call.method == 'closeGattConnection') closes++;
      return null;
    });
    final runtime = await createRuntime(
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(methods: methods),
    );

    runtime.connect('opaque-endpoint');
    await Future<void>.delayed(Duration.zero);
    await runtime.close();

    expect(connects, 1);
    expect(closes, 1);
  });

  test('UT-165 HostSession snapshots peers and broadcasts an empty target set',
      () async {
    final runtime = await createRuntime(
      localPeerId: PeerId(List.filled(16, 1)),
      platformBleBackend:
          PlatformBleBackend(methods: const MethodChannel('host-empty-test')),
    );
    final host = runtime.createHostSession(HostConfig());

    expect(host.peers(), isEmpty);
    final broadcast = host.broadcast([1]);
    expect(broadcast.targetPeerIds, isEmpty);
    expect(await broadcast.completed, BroadcastState.completed);
    expect(
        () => host.send(PeerId(List.filled(16, 2)), [1]),
        throwsA(isA<LpcException>().having((error) => error.code, 'code',
            LpcErrorCode.destinationUnavailable)));
    await runtime.close();
  });

  test('UT-171 HostSession validates credentials for its trust-mode override',
      () async {
    final runtime = await createRuntime(
      localPeerId: PeerId(List.filled(16, 1)),
      platformBleBackend:
          PlatformBleBackend(methods: const MethodChannel('host-trust-test')),
    );
    expect(
        () => runtime.createHostSession(
            HostConfig(trustMode: HandshakeTrustMode.knownPeer)),
        throwsA(isA<LpcException>()
            .having((error) => error.code, 'code', LpcErrorCode.invalidState)));
    expect(
        runtime
            .createHostSession(HostConfig(trustMode: HandshakeTrustMode.sas))
            .config
            .trustMode,
        HandshakeTrustMode.sas);
    await runtime.close();
  });

  test('UT-172 disabled GATT cannot start discovery, host, or connection',
      () async {
    final runtime = await createRuntime(
      config: const RuntimeConfig(enableGatt: false),
      localPeerId: PeerId(List.filled(16, 1)),
      platformBleBackend: PlatformBleBackend(
          methods: const MethodChannel('gatt-disabled-runtime-test')),
    );
    expect(() => runtime.connect('opaque'), throwsA(isA<LpcException>()));
    await expectLater(runtime.startDiscovery(), throwsA(isA<LpcException>()));
    expect(() => runtime.createHostSession(HostConfig()),
        throwsA(isA<LpcException>()));
    await runtime.close();
  });
}

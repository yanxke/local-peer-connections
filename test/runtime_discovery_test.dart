import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('UT-158/191 runtime preserves pre-auth discovery local-name metadata',
      () async {
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
    events.add(
        const PlatformEndpointFound('endpoint', rssi: -40, localName: 'Maple'));
    await Future<void>.delayed(Duration.zero);
    expect(discovery.currentEndpoints().single.id, 'endpoint');
    expect(discovery.currentEndpoints().single.localName, 'Maple');

    await runtime.close();
    expect(stops, 1);
    expect(discovery.isStopped, isTrue);
    await events.close();
  });

  test('discovery emits found, updated, and lost endpoint lifecycle events',
      () async {
    var now = DateTime(2026, 1, 1);
    final discovery = DiscoverySession(
      now: () => now,
      endpointLostAfter: const Duration(milliseconds: 20),
    );
    final events = <DiscoveryEvent>[];
    final subscription = discovery.events.listen(events.add);

    discovery.recordEndpoint(
        const DiscoveredEndpoint('endpoint', rssi: -40, localName: 'Maple'));
    discovery.recordEndpoint(
        const DiscoveredEndpoint('endpoint', rssi: -52, localName: 'Maple'));
    discovery.recordEndpoint(
        const DiscoveredEndpoint('endpoint', rssi: -52, localName: 'Maple'));
    expect(discovery.currentEndpoints(), hasLength(1));
    expect(events[0], isA<EndpointFound>());
    expect(events[1], isA<EndpointUpdated>());
    expect(events, hasLength(2));

    now = now.add(const Duration(milliseconds: 25));
    await Future<void>.delayed(const Duration(milliseconds: 1050));
    expect(events[2], isA<EndpointLost>());
    expect(discovery.currentEndpoints(), isEmpty);

    await discovery.stop();
    await subscription.cancel();
  });

  test('currentEndpoints returns an immutable point-in-time snapshot',
      () async {
    final discovery = DiscoverySession();
    const first = DiscoveredEndpoint('first', rssi: -40);
    const replacement = DiscoveredEndpoint('first', rssi: -52);
    discovery.recordEndpoint(first);

    final snapshot = discovery.currentEndpoints();
    expect(snapshot, hasLength(1));
    expect(snapshot.single.rssi, -40);
    expect(() => snapshot.clear(), throwsUnsupportedError);

    discovery.recordEndpoint(replacement);
    expect(snapshot.single.rssi, -40);
    expect(discovery.currentEndpoints().single.rssi, -52);
    await discovery.stop();
  });

  test('stopped discovery emits no endpoint changes', () async {
    final discovery = DiscoverySession();
    final events = <DiscoveryEvent>[];
    final subscription = discovery.events.listen(events.add);
    await discovery.stop();
    discovery.recordEndpoint(const DiscoveredEndpoint('endpoint', rssi: -40));
    expect(events, hasLength(1));
    expect(events.single, isA<DiscoveryStopped>());
    expect(discovery.currentEndpoints(), isEmpty);
    await subscription.cancel();
  });

  test('DiscoverySession stop is idempotent under concurrent calls', () async {
    var platformStops = 0;
    var callbacks = 0;
    final discovery = DiscoverySession(
      stopPlatformScan: () async => platformStops++,
      onStopped: () async => callbacks++,
    );
    final events = <DiscoveryEvent>[];
    final subscription = discovery.events.listen(events.add);

    await Future.wait([discovery.stop(), discovery.stop()]);
    await discovery.stop();

    expect(platformStops, 1);
    expect(callbacks, 1);
    expect(events.whereType<DiscoveryStopped>(), hasLength(1));
    await subscription.cancel();
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
    expect(defaults.gattFragmentInactivityTimeoutMs, 5000);
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
    expect(() => RuntimeConfig(gattFragmentInactivityTimeoutMs: 999).validate(),
        throwsA(isA<LpcException>()));
    expect(
        () => RuntimeConfig(gattFragmentInactivityTimeoutMs: 10001).validate(),
        throwsA(isA<LpcException>()));
  });

  test('UT-178 automatic known-peer probing requires a resolver', () {
    expect(
        () => RuntimeConfig(autoConnectKnownPeers: true).validate(),
        throwsA(isA<LpcException>()
            .having((error) => error.code, 'code', LpcErrorCode.invalidState)));
  });

  test('UT-188 a large known-peer database creates no runtime probe state',
      () async {
    const methods = MethodChannel('runtime-large-known-database-test');
    var connects = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'connectGatt') connects++;
      return null;
    });
    final resolver = _LargeKnownPeerResolver();
    final runtime = await createRuntime(
      config: RuntimeConfig(
        autoConnectKnownPeers: true,
        knownPeerResolver: resolver,
      ),
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(methods: methods),
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(resolver.lookups, 0);
    expect(connects, 0);
    final discovery = await runtime.startDiscovery();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(resolver.lookups, 0);
    expect(connects, 0);

    await discovery.stop();
    await runtime.close();
  });

  test('runtime diagnostic logger reports discovery observations', () async {
    const methods = MethodChannel('runtime-logger-test');
    final logs = <String>[];
    final events = StreamController<PlatformBleEvent>.broadcast();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async => null);
    final runtime = await createRuntime(
      config: RuntimeConfig(logger: logs.add),
      localPeerId: PeerId(List.filled(16, 1)),
      platformBleBackend: PlatformBleBackend(
        methods: methods,
        eventStream: events.stream,
      ),
    );

    final discovery = await runtime.startDiscovery();
    events.add(const PlatformEndpointFound('diagnostic-endpoint', rssi: -42));
    await Future<void>.delayed(Duration.zero);

    expect(logs, contains(contains('endpoint found')));
    expect(logs, contains(contains('diagnostic-endpoint')));
    await discovery.stop();
    await runtime.close();
    await events.close();
  });

  test('a throwing runtime diagnostic logger cannot stop discovery', () async {
    const methods = MethodChannel('runtime-throwing-logger-test');
    final events = StreamController<PlatformBleEvent>.broadcast();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async => null);
    final runtime = await createRuntime(
      config: RuntimeConfig(logger: (_) => throw StateError('diagnostics')),
      localPeerId: PeerId(List.filled(16, 1)),
      platformBleBackend: PlatformBleBackend(
        methods: methods,
        eventStream: events.stream,
      ),
    );

    final discovery = await runtime.startDiscovery();
    events.add(const PlatformEndpointFound('still-works', rssi: -42));
    await Future<void>.delayed(Duration.zero);
    expect(discovery.currentEndpoints().single.id, 'still-works');

    await discovery.stop();
    await runtime.close();
    await events.close();
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

  test('UT-193 automatic known-peer probes put runtime metadata in HELLO',
      () async {
    const methods = MethodChannel('runtime-known-probe-metadata-test');
    final events = StreamController<PlatformBleEvent>.broadcast();
    final fragments = <int, Uint8List>{};
    Uint8List? helloBytes;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'connectGatt') {
        events.add(const PlatformGattConnected('metadata-endpoint', 'central'));
      } else if (call.method == 'submitGattFragment') {
        final arguments = call.arguments as Map<Object?, Object?>;
        final fragment = GattFragment.decode(
            (arguments['fragment'] as Uint8List).toList(growable: false));
        fragments[fragment.sequence] = fragment.bytes;
        if (fragment.end) {
          final bytes = BytesBuilder(copy: false);
          for (var sequence = 0; fragments.containsKey(sequence); sequence++) {
            bytes.add(fragments[sequence]!);
          }
          helloBytes = bytes.takeBytes();
        }
        return 'submitted';
      }
      return null;
    });

    final runtime = await createRuntime(
      config: RuntimeConfig(
        autoConnectKnownPeers: true,
        applicationMetadata: const [7, 8, 9],
        knownPeerResolver: _KnownPeerResolver(),
        reconnectTimeoutMs: 1000,
      ),
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(
        methods: methods,
        eventStream: events.stream,
      ),
    );
    final discovery = await runtime.startDiscovery();
    events.add(const PlatformEndpointFound('metadata-endpoint', rssi: -40));

    for (var i = 0; i < 100 && helloBytes == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(helloBytes, isNotNull);
    final frame = LpcFrame.decode(helloBytes!);
    expect(frame.type, FrameType.hello);
    final hello = await HelloPayload.decode(frame.payload);
    expect(hello.applicationMetadata, [7, 8, 9]);

    await discovery.stop();
    await runtime.close();
    await events.close();
  });

  test('UT-194 HostSession inherits and overrides runtime metadata', () async {
    const methods = MethodChannel('runtime-host-metadata-test');
    final events = StreamController<PlatformBleEvent>.broadcast();
    final capture = _OutgoingFrameCapture();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'submitGattFragment') {
        final arguments = call.arguments as Map<Object?, Object?>;
        capture.add(arguments['endpointId'] as String,
            arguments['fragment'] as Uint8List);
        return 'submitted';
      }
      return null;
    });

    final runtime = await createRuntime(
      config: RuntimeConfig(applicationMetadata: const [1, 2, 3]),
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(
        methods: methods,
        eventStream: events.stream,
      ),
    );

    final inherited = runtime.createHostSession(HostConfig(autoAccept: true));
    await inherited.startAdvertising();
    events.add(const PlatformGattConnected('inherited-endpoint', 'peripheral'));
    final inheritedFrame = await capture.waitFor('inherited-endpoint');
    final inheritedHello = await _helloFromFrame(inheritedFrame);
    expect(inheritedHello.applicationMetadata, [1, 2, 3]);
    await inherited.close();

    final overridden = runtime.createHostSession(
        HostConfig(autoAccept: true, applicationMetadata: const [9, 8]));
    await overridden.startAdvertising();
    events
        .add(const PlatformGattConnected('overridden-endpoint', 'peripheral'));
    final overriddenFrame = await capture.waitFor('overridden-endpoint');
    final overriddenHello = await _helloFromFrame(overriddenFrame);
    expect(overriddenHello.applicationMetadata, [9, 8]);

    await overridden.close();
    await runtime.close();
    await events.close();
  });

  test('UT-195 one runtime can advertise and discover concurrently', () async {
    const methods = MethodChannel('runtime-host-discovery-concurrent-test');
    var listenCalls = 0;
    var advertiseCalls = 0;
    var discoveryCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case 'listenGatt':
          listenCalls++;
          break;
        case 'startAdvertising':
          advertiseCalls++;
          break;
        case 'startDiscovery':
          discoveryCalls++;
          break;
      }
      return null;
    });
    final runtime = await createRuntime(
      localPeerId: PeerId(List.filled(16, 5)),
      platformBleBackend: PlatformBleBackend(methods: methods),
    );
    final host = runtime.createHostSession(HostConfig());
    await host.startAdvertising();
    final discovery = await runtime.startDiscovery();

    expect(listenCalls, 1);
    expect(advertiseCalls, 1);
    expect(discoveryCalls, 1);
    expect(host.isAdvertising, isTrue);
    expect(discovery.isStopped, isFalse);

    await discovery.stop();
    await host.close();
    await runtime.close();
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

  test('ConnectionAttempt cancellation is idempotent after the first cancel',
      () async {
    const methods = MethodChannel('runtime-attempt-cancel-idempotence-test');
    var closes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'closeGattConnection') closes++;
      return null;
    });
    final runtime = await createRuntime(
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(methods: methods),
    );
    final attempt = runtime.connect('opaque-endpoint');
    final events = <ConnectionAttemptEvent>[];
    final subscription = attempt.events.listen(events.add);

    await Future<void>.delayed(Duration.zero);
    await attempt.cancel();
    await attempt.cancel();

    expect(closes, 1);
    expect(events.whereType<ConnectionAttemptCancelled>(), hasLength(1));
    await subscription.cancel();
    await runtime.close();
  });

  test('ConnectionAttempt fails when the platform never completes connect',
      () async {
    const methods = MethodChannel('runtime-attempt-timeout-test');
    var closes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'closeGattConnection') closes++;
      // Deliberately omit a PlatformGattConnected/Disconnected event.
      return null;
    });
    final runtime = await createRuntime(
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(methods: methods),
    );
    final attempt = runtime.connect('opaque-endpoint');
    final failure = expectLater(
      attempt.events,
      emitsThrough(
        isA<ConnectionAttemptFailed>().having(
          (event) => event.error.code,
          'error code',
          LpcErrorCode.connectionTimeout,
        ),
      ),
    );

    await failure.timeout(const Duration(seconds: 12));
    expect(closes, 1);
    await runtime.close();
  });

  test('HostSession close is idempotent and emits one terminal event',
      () async {
    final runtime = await createRuntime(
      identityStore: InMemoryIdentityStore(),
      platformBleBackend:
          PlatformBleBackend(methods: const MethodChannel('host-close-test')),
    );
    final host = runtime.createHostSession(HostConfig());
    final events = <HostSessionEvent>[];
    final subscription = host.events.listen(events.add);

    await Future.wait([host.close(), host.close()]);
    await host.close();

    expect(host.isClosed, isTrue);
    expect(events.whereType<HostSessionClosed>(), hasLength(1));
    await subscription.cancel();
    await runtime.close();
  });

  test('automatic known-peer probes time out and release their endpoint',
      () async {
    const methods = MethodChannel('runtime-known-probe-timeout-test');
    var closes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'closeGattConnection') closes++;
      return null;
    });
    final events = StreamController<PlatformBleEvent>.broadcast();
    final runtimeEvents = <RuntimeEvent>[];
    final runtime = await createRuntime(
      config: RuntimeConfig(
        autoConnectKnownPeers: true,
        knownPeerResolver: _KnownPeerResolver(),
        reconnectTimeoutMs: 1000,
      ),
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(
        methods: methods,
        eventStream: events.stream,
      ),
    );
    final subscription = runtime.events.listen(runtimeEvents.add);
    final discovery = await runtime.startDiscovery();
    events.add(const PlatformEndpointFound('stalled-endpoint', rssi: -40));
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    final failed = runtimeEvents.whereType<KnownPeerProbeFailed>().single;
    expect(failed.discoveryEndpointId, 'stalled-endpoint');
    expect(failed.error.code, LpcErrorCode.connectionTimeout);
    expect(closes, 1);

    await subscription.cancel();
    await discovery.stop();
    await runtime.close();
    await events.close();
  });

  test('automatic probe protocol failure is reported and releases its slot',
      () async {
    const methods = MethodChannel('runtime-known-probe-protocol-failure-test');
    final events = StreamController<PlatformBleEvent>.broadcast();
    final runtimeEvents = <RuntimeEvent>[];
    var helloSubmitted = false;
    final logs = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'connectGatt') {
        final endpoint = (call.arguments as Map)['endpointId'] as String;
        events.add(PlatformGattConnected(endpoint, 'central'));
      }
      if (call.method == 'submitGattFragment') {
        helloSubmitted = true;
        return 'submitted';
      }
      return null;
    });
    final runtime = await createRuntime(
      config: RuntimeConfig(
        autoConnectKnownPeers: true,
        knownPeerResolver: _KnownPeerResolver(),
        reconnectTimeoutMs: 1000,
        logger: logs.add,
      ),
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(
        methods: methods,
        eventStream: events.stream,
      ),
    );
    final subscription = runtime.events.listen(runtimeEvents.add);
    final discovery = await runtime.startDiscovery();
    events.add(const PlatformEndpointFound('malformed-endpoint', rssi: -40));

    // Wait until the runtime has installed the connection-scoped binding,
    // then inject a validly encoded but non-contiguous fragment.  This is an
    // expected failed candidate, not an application-level uncaught error.
    await _waitUntil(
        () => runtimeEvents.whereType<KnownPeerProbeStarted>().isNotEmpty);
    await _waitUntil(() => helloSubmitted);
    events.add(PlatformGattFragment(
        'malformed-endpoint', GattFragment(1, [1], end: true).encode()));
    await _waitUntil(
        () => runtimeEvents.whereType<KnownPeerProbeFailed>().isNotEmpty);
    expect(runtimeEvents.whereType<KnownPeerProbeFailed>().single.error.code,
        LpcErrorCode.protocolMismatch);

    // The failed endpoint must be eligible for a later observation rather
    // than permanently consuming the bounded automatic-probe slot.
    events.add(const PlatformEndpointFound('malformed-endpoint', rssi: -41));
    await _waitUntil(
        () => runtimeEvents.whereType<KnownPeerProbeStarted>().length == 2);

    await subscription.cancel();
    await discovery.stop();
    await runtime.close();
    await events.close();
  });

  test('known-peer probes enforce concurrency and preserve dropped candidates',
      () async {
    const methods = MethodChannel('runtime-known-probe-queue-test');
    final events = StreamController<PlatformBleEvent>.broadcast();
    final connectedEndpoints = <String>[];
    final runtimeEvents = <RuntimeEvent>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'connectGatt') {
        final endpoint = (call.arguments as Map)['endpointId'] as String;
        connectedEndpoints.add(endpoint);
        events.add(PlatformGattConnected(endpoint, 'central'));
      }
      if (call.method == 'submitGattFragment') return 'submitted';
      return null;
    });
    final runtime = await createRuntime(
      config: RuntimeConfig(
        autoConnectKnownPeers: true,
        knownPeerResolver: _KnownPeerResolver(),
        maxConcurrentKnownPeerProbes: 1,
        maxPendingKnownPeerProbes: 1,
        reconnectTimeoutMs: 1000,
      ),
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(
        methods: methods,
        eventStream: events.stream,
      ),
    );
    final subscription = runtime.events.listen(runtimeEvents.add);
    final discovery = await runtime.startDiscovery();

    events.add(const PlatformEndpointFound('probe-1', rssi: -40));
    events.add(const PlatformEndpointFound('probe-2', rssi: -41));
    events.add(const PlatformEndpointFound('probe-3', rssi: -42));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(connectedEndpoints, ['probe-1']);
    expect(runtimeEvents.whereType<KnownPeerProbeStarted>(), hasLength(1));

    await _waitUntil(
        () => runtimeEvents.whereType<KnownPeerProbeStarted>().length == 2,
        timeout: const Duration(seconds: 2));
    expect(connectedEndpoints, ['probe-1', 'probe-2']);

    // probe-3 was over the pending limit and was not completed; a later
    // advertisement must make it eligible again.
    events.add(const PlatformEndpointFound('probe-3', rssi: -43));
    await _waitUntil(
        () => runtimeEvents.whereType<KnownPeerProbeStarted>().length == 3,
        timeout: const Duration(seconds: 2));
    expect(connectedEndpoints, ['probe-1', 'probe-2', 'probe-3']);

    await subscription.cancel();
    await discovery.stop();
    await runtime.close();
    await events.close();
  });

  test('repeated endpoint observations do not start duplicate probes',
      () async {
    const methods = MethodChannel('runtime-known-probe-dedup-test');
    final events = StreamController<PlatformBleEvent>.broadcast();
    var connects = 0;
    final runtimeEvents = <RuntimeEvent>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'connectGatt') {
        connects++;
        events.add(const PlatformGattConnected('same-endpoint', 'central'));
      }
      if (call.method == 'submitGattFragment') return 'submitted';
      return null;
    });
    final runtime = await createRuntime(
      config: RuntimeConfig(
        autoConnectKnownPeers: true,
        knownPeerResolver: _KnownPeerResolver(),
        reconnectTimeoutMs: 1000,
      ),
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(
        methods: methods,
        eventStream: events.stream,
      ),
    );
    final subscription = runtime.events.listen(runtimeEvents.add);
    final discovery = await runtime.startDiscovery();
    events.add(const PlatformEndpointFound('same-endpoint', rssi: -40));
    events.add(const PlatformEndpointFound('same-endpoint', rssi: -55));

    await _waitUntil(
        () => runtimeEvents.whereType<KnownPeerProbeStarted>().length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(connects, 1);

    await subscription.cancel();
    await discovery.stop();
    await runtime.close();
    await events.close();
  });

  test('failed transport probe backs off while advertisements continue',
      () async {
    const methods = MethodChannel('runtime-known-probe-backoff-test');
    final events = StreamController<PlatformBleEvent>.broadcast();
    final runtimeEvents = <RuntimeEvent>[];
    var connects = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'connectGatt') {
        connects++;
        events.add(const PlatformGattDisconnected('unstable-endpoint'));
      }
      return null;
    });
    final runtime = await createRuntime(
      config: RuntimeConfig(
        autoConnectKnownPeers: true,
        knownPeerResolver: _KnownPeerResolver(),
      ),
      identityStore: InMemoryIdentityStore(),
      platformBleBackend: PlatformBleBackend(
        methods: methods,
        eventStream: events.stream,
      ),
    );
    final subscription = runtime.events.listen(runtimeEvents.add);
    final discovery = await runtime.startDiscovery();
    events.add(const PlatformEndpointFound('unstable-endpoint', rssi: -40));
    await _waitUntil(
        () => runtimeEvents.whereType<KnownPeerProbeFailed>().isNotEmpty);
    events.add(const PlatformEndpointFound('unstable-endpoint', rssi: -41));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(connects, 1);

    await subscription.cancel();
    await discovery.stop();
    await runtime.close();
    await events.close();
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

class _KnownPeerResolver implements KnownPeerResolver {
  @override
  Future<bool> isKnownPeer(PeerId peerId) async => true;
}

class _LargeKnownPeerResolver implements KnownPeerResolver {
  _LargeKnownPeerResolver()
      : database = {
          for (var value = 0; value < 4096; value++)
            PeerId(List<int>.generate(
                16, (index) => (value >> ((index % 4) * 8)) & 0xff)),
        };

  final Set<PeerId> database;
  int lookups = 0;

  @override
  Future<bool> isKnownPeer(PeerId peerId) async {
    lookups++;
    return database.contains(peerId);
  }
}

Future<void> _waitUntil(bool Function() condition,
    {Duration timeout = const Duration(seconds: 1)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

class _OutgoingFrameCapture {
  final Map<String, Map<int, Uint8List>> _fragments = {};
  final Map<String, Uint8List> _frames = {};

  void add(String endpointId, Uint8List encodedFragment) {
    final fragment = GattFragment.decode(encodedFragment);
    final fragments = _fragments.putIfAbsent(endpointId, () => {});
    fragments[fragment.sequence] = fragment.bytes;
    if (!fragment.end) return;
    final bytes = BytesBuilder(copy: false);
    for (var sequence = 0; fragments.containsKey(sequence); sequence++) {
      bytes.add(fragments[sequence]!);
    }
    _frames[endpointId] = bytes.takeBytes();
  }

  Future<Uint8List> waitFor(String endpointId) async {
    for (var i = 0; i < 100 && !_frames.containsKey(endpointId); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final frame = _frames[endpointId];
    if (frame == null) {
      throw StateError('timed out waiting for frame from $endpointId');
    }
    return frame;
  }
}

Future<HelloPayload> _helloFromFrame(Uint8List bytes) async {
  final frame = LpcFrame.decode(bytes);
  expect(frame.type, FrameType.hello);
  return HelloPayload.decode(frame.payload);
}

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

  test('UT-159 runtime owns at most one advertising HostSession', () async {
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
      localPeerId: PeerId(List.filled(16, 1)),
      platformBleBackend: PlatformBleBackend(methods: methods),
    );
    final first = runtime.createHostSession(HostConfig());
    final second = runtime.createHostSession(HostConfig());

    await first.startAdvertising();
    await expectLater(second.startAdvertising(), throwsA(isA<LpcException>()));
    await runtime.close();
    expect(starts, 1);
    expect(stops, 1);
    expect(first.isClosed, isTrue);
    expect(second.isClosed, isTrue);
  });
}

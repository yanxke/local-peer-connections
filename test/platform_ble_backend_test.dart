import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('platform BLE backend maps only local runtime capabilities', () async {
    const channel = MethodChannel('platform-ble-backend-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'queryCapabilities');
          return <Object?>['bleScan', 'bleAdvertise'];
        });
    final backend = PlatformBleBackend(methods: channel);
    final capabilities = await backend.queryCapabilities();
    expect(capabilities.contains(LocalRuntimeCapability.bleScan), isTrue);
    expect(capabilities.contains(LocalRuntimeCapability.bleAdvertise), isTrue);
    expect(capabilities.contains(LocalRuntimeCapability.gattCentral), isFalse);
  });

  test('advertising sends only service UUID and optional local name', () async {
    const channel = MethodChannel('platform-ble-advertise-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'startAdvertising');
          final arguments = call.arguments as Map<Object?, Object?>;
          expect(
            arguments.keys,
            containsAll(<String>['serviceUuid', 'localName']),
          );
          expect(arguments['serviceUuid'], List.filled(16, 1));
          expect(arguments['localName'], 'LPC');
          return null;
        });
    await PlatformBleBackend(
      methods: channel,
    ).startAdvertising(List.filled(16, 1), localName: 'LPC');
  });

  test(
    'UT-001 canonical discovery filters solely by the service UUID',
    () async {
      const channel = MethodChannel('platform-ble-discovery-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'startDiscovery');
            final arguments = call.arguments as Map<Object?, Object?>;
            expect(arguments.keys, <String>['serviceUuid']);
            expect(arguments['serviceUuid'], List.filled(16, 1));
            return null;
          });
      await PlatformBleBackend(
        methods: channel,
      ).startDiscovery(List.filled(16, 1));
    },
  );

  test('GATT listener receives only the configured service UUID', () async {
    const channel = MethodChannel('platform-ble-gatt-listen-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'listenGatt');
          expect(call.arguments, {'serviceUuid': List.filled(16, 1)});
          return null;
        });
    await PlatformBleBackend(methods: channel).listenGatt(List.filled(16, 1));
  });

  test(
    'UT-160 GATT connect accepts only an opaque discovery endpoint ID',
    () async {
      const channel = MethodChannel('platform-ble-gatt-connect-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'connectGatt');
            expect(call.arguments, {'endpointId': 'platform-endpoint'});
            return null;
          });
      await PlatformBleBackend(
        methods: channel,
      ).connectGatt('platform-endpoint');
      expect(
        PlatformBleEvent.fromPlatform({
          'type': 'gattConnected',
          'endpointId': 'platform-endpoint',
          'localRole': 'central',
        }),
        isA<PlatformGattConnected>(),
      );
    },
  );

  test(
    'UT-161 platform GATT fragment outcome maps Section 44 states',
    () async {
      const channel = MethodChannel('platform-ble-gatt-fragment-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'submitGattFragment');
            expect(
              (call.arguments as Map)['transmission'],
              'writeWithoutResponse',
            );
            return 'temporarilyUnavailable';
          });
      final platform = PlatformGattFragmentPlatform(
        backend: PlatformBleBackend(methods: channel),
        endpointId: 'platform-endpoint',
        platformSafeWriteSize: 20,
      );
      expect(
        await platform.submitGattFragment(
          Uint8List.fromList([1]),
          transmission: GattFragmentTransmission.writeWithoutResponse,
        ),
        GattFragmentSubmission.temporarilyUnavailable,
      );
    },
  );

  test(
    'GATT packet diagnostics report submitted and received fragments',
    () async {
      final events = StreamController<PlatformBleEvent>.broadcast();
      const channel = MethodChannel('platform-ble-packet-diagnostics-test');
      final diagnostics = <GattPacketDiagnostic>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => 'submitted');
      final backend = PlatformBleBackend(
        methods: channel,
        eventStream: events.stream,
        gattPacketDiagnostic: diagnostics.add,
      );
      final subscription = backend.events.listen((_) {});

      await backend.submitGattFragment(
        'platform-endpoint',
        Uint8List.fromList([1, 2, 3]),
        transmission: GattFragmentTransmission.normal,
        connectionGeneration: 4,
      );
      events.add(
        PlatformGattFragment('platform-endpoint', [
          4,
          5,
        ], connectionGeneration: 4),
      );
      await Future<void>.delayed(Duration.zero);

      expect(diagnostics.map((diagnostic) => diagnostic.direction), [
        GattPacketDirection.sent,
        GattPacketDirection.received,
      ]);
      expect(diagnostics.map((diagnostic) => diagnostic.byteCount), [3, 2]);
      expect(
        diagnostics.every(
          (diagnostic) => diagnostic.endpointId == 'platform-endpoint',
        ),
        isTrue,
      );
      expect(
        diagnostics.every((diagnostic) => diagnostic.connectionGeneration == 4),
        isTrue,
      );

      await subscription.cancel();
      await events.close();
    },
  );

  test('native GATT fragment remains connection-scoped bytes', () {
    final event = PlatformBleEvent.fromPlatform({
      'type': 'gattFragment',
      'endpointId': 'platform-endpoint',
      'bytes': [1, 2],
    });
    expect(event, isA<PlatformGattFragment>());
    expect((event as PlatformGattFragment).bytes, [1, 2]);
  });

  test(
    'UT-161 GATT binding ignores terminal events for another endpoint',
    () async {
      final events = StreamController<PlatformBleEvent>.broadcast();
      const methods = MethodChannel('platform-ble-binding-scope-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, (call) async => null);
      final backend = PlatformBleBackend(
        methods: methods,
        eventStream: events.stream,
      );
      final connection = GattBackendConnection(
        connectionId: 'target',
        platform: PlatformGattFragmentPlatform(
          backend: backend,
          endpointId: 'target',
          platformSafeWriteSize: 20,
        ),
      );
      final binding = PlatformGattConnectionBinding(
        backend: backend,
        endpointId: 'target',
        connection: connection,
        connectionGeneration: 2,
      );

      events.add(const PlatformGattDisconnected('other'));
      await Future<void>.delayed(Duration.zero);
      expect(connection.state, TransportConnectionState.open);

      events.add(
        const PlatformGattDisconnected('target', connectionGeneration: 1),
      );
      await Future<void>.delayed(Duration.zero);
      expect(connection.state, TransportConnectionState.open);

      events.add(
        const PlatformGattDisconnected('target', connectionGeneration: 2),
      );
      await Future<void>.delayed(Duration.zero);
      expect(connection.state, TransportConnectionState.failed);

      await binding.close();
      await connection.close();
      await events.close();
    },
  );

  test('GATT terminal and writable events remain transport-scoped', () {
    final disconnected = PlatformBleEvent.fromPlatform({
      'type': 'gattDisconnected',
      'endpointId': 'native-id',
      'connectionGeneration': 7,
    });
    expect(disconnected, isA<PlatformGattDisconnected>());
    expect((disconnected as PlatformGattDisconnected).connectionGeneration, 7);
    expect(
      PlatformBleEvent.fromPlatform({'type': 'gattWritable'}),
      isA<PlatformGattWritable>(),
    );
  });

  test('native backend errors map to stable LPC errors', () async {
    const channel = MethodChannel('platform-ble-error-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'BLUETOOTH_POWERED_OFF');
        });
    await expectLater(
      PlatformBleBackend(methods: channel).startDiscovery(List.filled(16, 1)),
      throwsA(
        isA<LpcException>().having(
          (error) => error.code,
          'code',
          LpcErrorCode.bluetoothPoweredOff,
        ),
      ),
    );
  });

  test(
    'diagnostic logger samples fragment calls without payload bytes',
    () async {
      const channel = MethodChannel('platform-ble-logger-test');
      final logs = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => 'submitted');

      final backend = PlatformBleBackend(methods: channel, logger: logs.add);
      await backend.submitGattFragment(
        'opaque-endpoint',
        Uint8List.fromList([1, 2, 3]),
        transmission: GattFragmentTransmission.normal,
      );
      await backend.startDiscovery(List.filled(16, 1));

      // Per-fragment method-call logging is intentionally suppressed because it
      // can starve the Flutter isolate during real GATT traffic. Lifecycle
      // calls remain visible for diagnosing setup failures.
      expect(logs, isNot(contains(contains('submitGattFragment'))));
      expect(logs, contains(contains('invoke method=startDiscovery')));
      expect(logs.join('\n'), isNot(contains('[1, 2, 3]')));
    },
  );

  test(
    'a throwing diagnostic logger cannot break platform operations',
    () async {
      const channel = MethodChannel('platform-ble-throwing-logger-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => 'submitted');

      final result =
          await PlatformBleBackend(
            methods: channel,
            logger: (_) => throw StateError('diagnostics unavailable'),
          ).submitGattFragment(
            'opaque-endpoint',
            Uint8List.fromList([9]),
            transmission: GattFragmentTransmission.normal,
          );

      expect(result, GattFragmentSubmission.submitted);
    },
  );

  test('discovery endpoint event is explicitly not a protocol PeerId', () {
    final event = PlatformBleEvent.fromPlatform({
      'type': 'endpointFound',
      'endpointId': 'native-id',
      'rssi': -50,
      'localName': 'Maple',
    });
    expect(event, isA<PlatformEndpointFound>());
    final endpoint = event as PlatformEndpointFound;
    expect(endpoint.endpointId, 'native-id');
    expect(endpoint.localName, 'Maple');
  });
}

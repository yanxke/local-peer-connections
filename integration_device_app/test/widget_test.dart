import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lpc_integration_device_app/device_test_controller.dart';
import 'package:lpc_integration_device_app/main.dart';

class _SnapshotController extends DeviceTestController {
  _SnapshotController(this.value) : super(controlPort: 0);

  final Map<String, Object?> value;

  @override
  Map<String, Object?> snapshot() => value;
}

class _TrafficUpdateController extends DeviceTestController {
  _TrafficUpdateController()
    : value = {
        'runtimeState': 'ready',
        'localPeerId': '0123456789abcdef0123456789abcdef',
        'displayName': 'Test Device',
        'controlApi': 'disabled',
        'capabilities': 15,
        'presenceActive': true,
        'endpoints': const <Object?>[],
        'knownPeerIds': const <Object?>[],
        'connections': [
          {
            'peerId': 'fedcba9876543210fedcba9876543210',
            'state': 'ready',
            'security': 'encryptedTofu',
            'transport': 'gatt',
            'negotiatedMtu': 517,
            'sessionId': 'session',
          },
        ],
        'attempts': const <Object?>[],
        'telemetry': {
          'messagesSent': 0,
          'messagesReceived': 0,
          'bytesSent': 0,
          'bytesReceived': 0,
          'speedWindowMs': 5000,
          'connectionStatePercent': <String, Object?>{},
        },
        'trafficTests': {
          'direct': {
            'running': true,
            'sent': 2,
            'acked': 2,
            'pending': 0,
            'timedOut': 0,
            'lossRate': 0,
          },
          'group': {'running': false},
        },
        'checkpointingEnabled': false,
        'checkpointTest': {'running': false},
        'group': null,
        'eventSequence': 0,
      },
      super(controlPort: 0);

  final Map<String, Object?> value;
  final updates = <Map<String, Object?>>[];

  @override
  Map<String, Object?> snapshot() => value;

  @override
  Future<void> updateSendTest({
    int? messageSize,
    double? messagesPerSecond,
  }) async {
    updates.add({
      'messageSize': messageSize,
      'messagesPerSecond': messagesPerSecond,
    });
  }
}

void main() {
  testWidgets('device test app renders raw LPC state', (tester) async {
    final controller = DeviceTestController(displayName: 'Test Device');
    addTearDown(controller.dispose);
    await tester.pumpWidget(DeviceTestApp(controller: controller));

    expect(find.text('LPC Device Test'), findsOneWidget);
    expect(find.textContaining('Runtime: notInitialized'), findsOneWidget);
    expect(find.textContaining('PeerId: null'), findsOneWidget);
    expect(
      find.textContaining('Messages sent/received: 0 / 0'),
      findsOneWidget,
    );
    expect(find.textContaining('Connection time:'), findsOneWidget);
  });

  testWidgets('known authenticated peers do not show Remember', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: ConnectionTile(
            connection: {
              'peerId': '0123456789abcdef0123456789abcdef',
              'state': 'ready',
              'security': 'encryptedTofu',
              'endpointId': 'endpoint',
              'transport': 'gatt',
              'negotiatedMtu': 517,
              'sessionId': 'session',
            },
            isKnownPeer: true,
            onRemember: () {},
          ),
        ),
      ),
    );

    expect(find.text('Remember'), findsNothing);
    expect(find.textContaining('MTU=517'), findsOneWidget);
  });

  testWidgets('traffic sliders update an active run without restarting it', (
    tester,
  ) async {
    final controller = _TrafficUpdateController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(DeviceTestApp(controller: controller));

    final sizeSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('traffic-message-size-slider')),
    );
    final rateSlider = tester.widget<Slider>(
      find.byKey(const ValueKey('traffic-rate-slider')),
    );
    sizeSlider.onChanged!(6);
    rateSlider.onChanged!(3);
    await tester.pump();

    expect(controller.updates, [
      {'messageSize': 512, 'messagesPerSecond': 1.0},
      {'messageSize': 512, 'messagesPerSecond': 3.0},
    ]);
  });

  testWidgets('checkpoint panel exposes live size and rate controls', (
    tester,
  ) async {
    final controller = _SnapshotController({
      'runtimeState': 'ready',
      'localPeerId': '0123456789abcdef0123456789abcdef',
      'displayName': 'Test Device',
      'controlApi': 'disabled',
      'capabilities': 15,
      'presenceActive': true,
      'endpoints': const <Object?>[],
      'knownPeerIds': const <Object?>[],
      'connections': const <Object?>[],
      'attempts': const <Object?>[],
      'telemetry': {
        'messagesSent': 0,
        'messagesReceived': 0,
        'bytesSent': 0,
        'bytesReceived': 0,
        'speedWindowMs': 5000,
        'connectionStatePercent': <String, Object?>{},
      },
      'trafficTests': {
        'direct': {'running': false},
        'group': {'running': false},
      },
      'checkpointingEnabled': true,
      'checkpointTest': {
        'running': true,
        'accepted': 2,
        'completed': 1,
        'durable': 1,
        'failed': 0,
        'pending': 1,
        'acceptedBytes': 2048,
        'durableBytes': 1024,
        'lossRate': 0.0,
        'durationMs': 5000,
        'durableBandwidthBytesPerSecond': 204.8,
        'lastCompletionMs': 120,
        'averageCompletionMs': 120.0,
        'maxCompletionMs': 120,
      },
      'group': {
        'state': 'ready',
        'localIsCoordinator': true,
        'members': [
          '0123456789abcdef0123456789abcdef',
          'fedcba9876543210fedcba9876543210',
        ],
      },
      'eventSequence': 0,
    });
    addTearDown(controller.dispose);
    await tester.pumpWidget(DeviceTestApp(controller: controller));
    await tester.scrollUntilVisible(
      find.text('Coordinator checkpoint test'),
      500,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Coordinator checkpoint test'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('checkpoint-size-slider')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('checkpoint-rate-slider')),
      findsOneWidget,
    );
    expect(find.textContaining('durable 1'), findsOneWidget);
    expect(find.textContaining('bandwidth: 204.8 B/s'), findsOneWidget);
    expect(find.textContaining('loss 0.0%'), findsOneWidget);
    expect(find.textContaining('latency ms: last 120'), findsOneWidget);
  });

  testWidgets('unprovisioned authenticated peers show Remember', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: ConnectionTile(
            connection: {
              'peerId': 'fedcba9876543210fedcba9876543210',
              'state': 'ready',
              'security': 'encryptedTofu',
              'endpointId': 'endpoint',
              'transport': 'gatt',
              'negotiatedMtu': 23,
              'sessionId': 'session',
            },
            isKnownPeer: false,
            onRemember: () {},
          ),
        ),
      ),
    );

    expect(find.text('Remember'), findsOneWidget);
  });

  testWidgets('group traffic explains missing group and offers creation', (
    tester,
  ) async {
    final controller = _SnapshotController({
      'runtimeState': 'ready',
      'localPeerId': '0123456789abcdef0123456789abcdef',
      'displayName': 'Test Device',
      'controlApi': 'disabled',
      'capabilities': 15,
      'presenceActive': true,
      'endpoints': const <Object?>[],
      'knownPeerIds': const <Object?>[],
      'connections': [
        {
          'peerId': 'fedcba9876543210fedcba9876543210',
          'state': 'ready',
          'security': 'encryptedTofu',
          'transport': 'gatt',
          'negotiatedMtu': 517,
          'sessionId': 'session',
        },
      ],
      'attempts': const <Object?>[],
      'telemetry': {
        'messagesSent': 0,
        'messagesReceived': 0,
        'bytesSent': 0,
        'bytesReceived': 0,
        'speedWindowMs': 5000,
        'connectionStatePercent': <String, Object?>{},
      },
      'trafficTests': {
        'direct': {'running': false},
        'group': {'running': false},
      },
      'group': null,
    });
    addTearDown(controller.dispose);
    await tester.pumpWidget(DeviceTestApp(controller: controller));
    expect(
      tester.allWidgets.whereType<Text>().any(
        (text) =>
            text.data?.startsWith('Create a group on both devices') == true,
      ),
      isTrue,
    );
    expect(
      tester.allWidgets.whereType<Text>().any(
        (text) => text.data == 'Create group',
      ),
      isTrue,
    );
    final startButtons = tester.allWidgets.whereType<FilledButton>().where(
      (button) =>
          button.child is Text &&
          (button.child! as Text).data == 'Start sending',
    );
    expect(startButtons, hasLength(2));
    expect(startButtons.last.onPressed, isNull);
  });
}

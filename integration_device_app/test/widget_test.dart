import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lpc_integration_device_app/device_test_controller.dart';
import 'package:lpc_integration_device_app/main.dart';

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
}

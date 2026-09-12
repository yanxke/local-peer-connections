import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lpc_integration_device_app/device_test_controller.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('display names are safe and fit LPC presentation metadata', () {
    expect(boundedDisplayName('  Device A  '), 'Device A');
    expect(boundedDisplayName('line\nwith\tcontrols'), 'linewithcontrols');
    expect(
      utf8.encode(boundedDisplayName('😀' * 20)).length,
      lessThanOrEqualTo(24),
    );
  });

  test('payload arguments support bytes, text, and bounded generated data', () {
    expect(
      bytesFromArguments({
        'bytes': [1, 2, 3],
      }),
      [1, 2, 3],
    );
    expect(bytesFromArguments({'text': 'hello'}), [104, 101, 108, 108, 111]);
    expect(bytesFromArguments({'size': 4}), [0, 1, 2, 3]);
    expect(
      () => bytesFromArguments({'size': 1048577}),
      throwsA(isA<LpcException>()),
    );
  });

  test('payload digest is stable and covers the generated test payload', () {
    expect(payloadDigest(const []), '811c9dc5');
    expect(
      payloadDigest(List<int>.generate(32, (index) => index % 251)),
      '0913ad65',
    );
    expect(
      payloadDigest(List<int>.generate(64, (index) => index % 251)),
      '6d3a0905',
    );
  });

  test('delivery mode parser rejects realtime direct reliable sends', () {
    expect(deliveryModeFrom(null), DeliveryMode.reliableOrdered);
    expect(deliveryModeFrom('reliableAcked'), DeliveryMode.reliableAcked);
    expect(() => deliveryModeFrom('realtimeLatest'), throwsFormatException);
  });

  test('traffic mode parser exposes reliable ACK and realtime choices', () {
    expect(trafficDeliveryModeFrom(null), DeliveryMode.reliableAcked);
    expect(
      trafficDeliveryModeFrom('reliableAcked'),
      DeliveryMode.reliableAcked,
    );
    expect(
      trafficDeliveryModeFrom('realtimeLatest'),
      DeliveryMode.realtimeLatest,
    );
    expect(
      () => trafficDeliveryModeFrom('reliableOrdered'),
      throwsFormatException,
    );
  });

  test('throughput rates use only the recent five-second window', () {
    final window = RollingTelemetryWindow();
    window.add(timestampMs: 1000, sentMessages: 4, sentBytes: 40);
    window.add(timestampMs: 3000, receivedMessages: 2, receivedBytes: 20);

    // During startup, use the available three seconds of history.
    final startupRates = window.rates(nowMs: 3000);
    expect(startupRates['messagesSentPerSecond'], closeTo(4 / 3, 0.0001));
    expect(startupRates['bytesReceivedPerSecond'], closeTo(20 / 3, 0.0001));

    // At eight seconds, the t=1000 sample has aged out; t=3000 remains.
    final rollingRates = window.rates(nowMs: 8000);
    expect(rollingRates['messagesSentPerSecond'], 0);
    expect(rollingRates['messagesReceivedPerSecond'], closeTo(2 / 5, 0.0001));
    expect(rollingRates['bytesReceivedPerSecond'], closeTo(20 / 5, 0.0001));
  });

  test(
    'snapshot exposes message counters, rates, and connection percentages',
    () {
      final snapshot = DeviceTestController(controlPort: 0).snapshot();
      final telemetry = snapshot['telemetry']! as Map<String, Object?>;
      expect(telemetry['messagesSent'], 0);
      expect(telemetry['bytesSent'], 0);
      expect(telemetry['messagesReceived'], 0);
      expect(telemetry['bytesReceived'], 0);
      expect(telemetry['speedWindowMs'], 5000);
      expect(telemetry['messagesSentPerSecond'], isA<num>());
      expect(telemetry['bytesReceivedPerSecond'], isA<num>());
      final percentages =
          telemetry['connectionStatePercent']! as Map<String, Object?>;
      expect(
        percentages.keys,
        containsAll(<String>['connecting', 'reconnecting', 'connected']),
      );
      expect(percentages.values.every((value) => value is num), isTrue);
    },
  );

  test('snapshot exposes known-peer provisioning state', () {
    final snapshot = DeviceTestController(controlPort: 0).snapshot();
    expect(snapshot['knownPeerIds'], isEmpty);
    expect(snapshot['autoConnectKnownPeers'], isFalse);
  });
}

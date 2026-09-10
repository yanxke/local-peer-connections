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
}

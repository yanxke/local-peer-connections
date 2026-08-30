import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-018 derives dead timeout from the negotiated maximum interval', () {
    final timing = KeepaliveTiming.negotiate(2000, 3000);
    expect(timing.intervalMs, 3000);
    expect(timing.deadTimeoutMs, 9000);
    expect(KeepaliveTiming.negotiate(1000, 1000).deadTimeoutMs, 6000);
  });

  test('PING/PONG body has the exact 16-byte echo layout', () {
    final ping = PingPayload([1, 2, 3, 4, 5, 6, 7, 8], 9);
    expect(PingPayload.decode(ping.encode()).pingId, ping.pingId);
    expect(PingPayload.decode(ping.encode()).monotonicSenderTimeUs, 9);
  });

  test('authenticated traffic resets receive liveness', () {
    final tracker =
        KeepaliveTracker(KeepaliveTiming.negotiate(2000, 2000), nowMs: 0);
    expect(tracker.pingDue(2000), isTrue);
    tracker.encryptedFrameSent(2000);
    tracker.authenticatedFrameReceived(5999);
    expect(tracker.dead(6000), isFalse);
    expect(tracker.dead(11999), isTrue);
  });
}

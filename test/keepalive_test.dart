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

  test('keepalive controller waits for submission before scheduling next PING',
      () {
    final controller = KeepaliveController(
        KeepaliveTiming.negotiate(2000, 2000),
        nowMs: 0,
        nextPingId: () => List.filled(8, 7));
    expect(
        controller.poll(nowMs: 1999, monotonicUs: 1), isA<KeepaliveNoAction>());
    final first = controller.poll(nowMs: 2000, monotonicUs: 2);
    expect(first, isA<KeepalivePing>());
    expect((first as KeepalivePing).ping.encode(),
        PingPayload(List.filled(8, 7), 2).encode());
    expect(
        controller.poll(nowMs: 3000, monotonicUs: 3), isA<KeepaliveNoAction>());
    controller.pingSubmitted(3001);
    expect(
        controller.poll(nowMs: 5000, monotonicUs: 4), isA<KeepaliveNoAction>());
    expect(controller.poll(nowMs: 5001, monotonicUs: 5), isA<KeepalivePing>());
  });

  test('keepalive controller requests reconnect at dead timeout', () {
    final controller = KeepaliveController(
        KeepaliveTiming.negotiate(2000, 2000),
        nowMs: 0,
        nextPingId: () => List.filled(8, 7));
    expect(controller.poll(nowMs: 6000, monotonicUs: 1),
        isA<KeepaliveReconnect>());
  });
}

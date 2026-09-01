import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('Section 25 reconnect schedule uses the frozen backoff sequence', () {
    final schedule = ReconnectSchedule(startedAtMs: 100, timeoutMs: 15000);
    expect(schedule.attemptDue(100), isTrue); // attempt 1: immediately
    schedule.attemptFailed(100);
    expect(schedule.nextAttemptAtMs, 350);
    schedule.attemptFailed(350);
    expect(schedule.nextAttemptAtMs, 850);
    schedule.attemptFailed(850);
    expect(schedule.nextAttemptAtMs, 1850);
    schedule.attemptFailed(1850);
    expect(schedule.nextAttemptAtMs, 3850);
    schedule.attemptFailed(3850);
    expect(schedule.nextAttemptAtMs, 5850);
  });

  test('reconnect schedule stops at timeout or explicit cancellation', () {
    final timedOut = ReconnectSchedule(startedAtMs: 0, timeoutMs: 1000);
    expect(timedOut.attemptDue(999), isTrue);
    expect(timedOut.attemptDue(1000), isFalse);

    final cancelled = ReconnectSchedule(startedAtMs: 0, timeoutMs: 15000);
    cancelled.cancel();
    expect(cancelled.attemptDue(0), isFalse);
    expect(() => cancelled.attemptFailed(0), throwsA(isA<LpcException>()));
  });
}

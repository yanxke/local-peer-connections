import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('scheduler gives control precedence and replaces pending realtime key',
      () {
    final s = PeerScheduler();
    s.add(ScheduledItem(
        kind: ScheduledKind.realtime, bytes: [1], realtimeKey: 'a'));
    s.add(ScheduledItem(
        kind: ScheduledKind.realtime, bytes: [2], realtimeKey: 'a'));
    s.add(ScheduledItem(kind: ScheduledKind.control, bytes: [3]));
    expect(s.takeNext()!.bytes, [3]);
    expect(s.takeNext()!.bytes, [2]);
  });
  test('after eight realtime frames interactive reliable makes progress', () {
    final s = PeerScheduler();
    for (var i = 0; i < 9; i++) {
      s.add(ScheduledItem(
          kind: ScheduledKind.realtime, bytes: [i], realtimeKey: '$i'));
    }
    s.add(ScheduledItem(
        kind: ScheduledKind.reliable,
        bytes: [99],
        priority: SendPriority.interactive));
    for (var i = 0; i < 8; i++) {
      s.takeNext();
    }
    expect(s.takeNext()!.bytes, [99]);
  });
  test('UT-036 removes expired unsent work before physical transmission', () {
    final scheduler = PeerScheduler();
    scheduler.add(ScheduledItem(
        kind: ScheduledKind.reliable, bytes: [1, 2], expiresAtMs: 100));
    scheduler.add(ScheduledItem(
        kind: ScheduledKind.realtime,
        bytes: [3],
        realtimeKey: 'state',
        expiresAtMs: 101));
    expect(scheduler.removeExpired(100).single.bytes, [1, 2]);
    expect(scheduler.queuedBytes, 1);
    expect(scheduler.removeExpired(101).single.bytes, [3]);
    expect(scheduler.queuedMessages, 0);
  });
}

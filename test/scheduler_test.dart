import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-034 reliable application queue preserves FIFO send order', () {
    final scheduler = PeerScheduler();
    for (var value = 1; value <= 3; value++) {
      scheduler.add(ScheduledItem(
          kind: ScheduledKind.reliable,
          bytes: [value],
          priority: SendPriority.normal));
    }
    expect(scheduler.takeNext()!.bytes, [1]);
    expect(scheduler.takeNext()!.bytes, [2]);
    expect(scheduler.takeNext()!.bytes, [3]);
  });

  test('RT-003/004 realtime replacement is per key and control has precedence',
      () {
    final s = PeerScheduler();
    s.add(ScheduledItem(
        kind: ScheduledKind.realtime, bytes: [1], realtimeKey: 'a'));
    s.add(ScheduledItem(
        kind: ScheduledKind.realtime, bytes: [2], realtimeKey: 'a'));
    s.add(ScheduledItem(kind: ScheduledKind.control, bytes: [3]));
    s.add(ScheduledItem(
        kind: ScheduledKind.realtime, bytes: [4], realtimeKey: 'b'));
    expect(s.takeNext()!.bytes, [3]);
    expect(s.takeNext()!.bytes, [2]);
    expect(s.takeNext()!.bytes, [4]);
  });
  test('RT-014 after eight realtime frames interactive reliable makes progress',
      () {
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
  test('UT-017 PING control frame can interleave between DATA chunks', () {
    final scheduler = PeerScheduler();
    scheduler.add(ScheduledItem(kind: ScheduledKind.reliable, bytes: [1]));
    scheduler.add(ScheduledItem(kind: ScheduledKind.reliable, bytes: [2]));
    expect(scheduler.takeNext()!.bytes, [1]);

    scheduler.add(ScheduledItem(kind: ScheduledKind.control, bytes: [9]));
    expect(scheduler.takeNext()!.bytes, [9]);
    expect(scheduler.takeNext()!.bytes, [2]);
  });
  test('UT-035 scheduler enforces reliable queue byte and message bounds', () {
    final bytesBounded = PeerScheduler(maxQueuedBytes: 2, maxQueuedMessages: 2);
    bytesBounded
        .add(ScheduledItem(kind: ScheduledKind.reliable, bytes: [1, 2]));
    expect(
        () => bytesBounded
            .add(ScheduledItem(kind: ScheduledKind.reliable, bytes: [3])),
        throwsA(isA<LpcException>()));

    final messagesBounded =
        PeerScheduler(maxQueuedBytes: 3, maxQueuedMessages: 1);
    messagesBounded
        .add(ScheduledItem(kind: ScheduledKind.reliable, bytes: [1]));
    expect(
        () => messagesBounded
            .add(ScheduledItem(kind: ScheduledKind.reliable, bytes: [2])),
        throwsA(isA<LpcException>()));
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

  test('UT-135 cancelled queued reliable send emits no application frame',
      () async {
    final scheduler = PeerScheduler();
    final send = scheduler.enqueueReliable(
      bytes: [1, 2],
      priority: SendPriority.interactive,
    );
    expect(send.handle.state, SendState.queued);
    send.handle.cancel();
    expect(await send.handle.completed, SendState.cancelled);
    expect(scheduler.queuedMessages, 0);
    expect(scheduler.takeNext(), isNull);
  });

  test('RT-008 realtime queue defaults to a 100 ms expiry', () {
    final scheduler = PeerScheduler();
    scheduler.add(ScheduledItem.realtime(
        bytes: [1], realtimeKey: 'state', acceptedAtMs: 10));
    expect(scheduler.removeExpired(109), isEmpty);
    expect(scheduler.removeExpired(110).single.bytes, [1]);
  });

  test('RT-009 reconnect discards pending realtime but not reliable work', () {
    final scheduler = PeerScheduler();
    scheduler.add(ScheduledItem.realtime(
        bytes: [1], realtimeKey: 'state', acceptedAtMs: 0));
    scheduler.add(ScheduledItem(kind: ScheduledKind.reliable, bytes: [2]));
    expect(scheduler.discardRealtimeOnReconnect().single.bytes, [1]);
    expect(scheduler.takeNext()!.bytes, [2]);
  });
}

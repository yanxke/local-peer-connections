import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('RT-010 RESUME retains realtime counters while stale queued state drops',
      () {
    final destination = PeerId(List<int>.filled(16, 2));
    final counters = GroupRealtimeSequenceAllocator();
    final scheduler = PeerScheduler();
    expect(counters.allocate(destination, 7), 1);
    scheduler.add(ScheduledItem.realtime(
        bytes: [1], realtimeKey: '$destination:7', acceptedAtMs: 0));
    expect(scheduler.discardRealtimeOnReconnect(), hasLength(1));
    expect(counters.allocate(destination, 7), 2);
  });

  test(
      'GROUP_REALTIME_DATAGRAM preserves original source and fixed header fields',
      () {
    final d = GroupRealtimeDatagram(
        groupId: GroupId(List.filled(16, 1)),
        sourcePeerId: PeerId(List.filled(16, 2)),
        destinationPeerId: PeerId(List.filled(16, 3)),
        channelId: 1,
        sequence: 1,
        senderTick: 9,
        bytes: [7]);
    expect(
        GroupRealtimeDatagram.decode(d.encode()).sourcePeerId, d.sourcePeerId);
  });
  test('per destination/channel sequences are independent', () {
    final allocator = GroupRealtimeSequenceAllocator();
    final a = PeerId(List.filled(16, 1));
    final b = PeerId(List.filled(16, 2));
    expect(allocator.allocate(a, 1), 1);
    expect(allocator.allocate(a, 1), 2);
    expect(allocator.allocate(b, 1), 1);
  });

  test('coordinator realtime pending state coalesces by complete routing key',
      () {
    final pending = CoordinatorRealtimePending(maxPendingDatagrams: 2);
    final source = PeerId(List.filled(16, 1));
    final destination = PeerId(List.filled(16, 2));
    GroupRealtimeDatagram datagram(int sequence, int channel) =>
        GroupRealtimeDatagram(
          groupId: GroupId(List.filled(16, 3)),
          sourcePeerId: source,
          destinationPeerId: destination,
          channelId: channel,
          sequence: sequence,
          senderTick: 1,
          bytes: [sequence],
        );
    final members = <PeerId>{source, destination};

    expect(
      pending.enqueue(datagram(1, 1),
          committedMembers: members, destinationReady: true),
      CoordinatorRealtimeEnqueueResult.enqueued,
    );
    expect(
      pending.enqueue(datagram(2, 1),
          committedMembers: members, destinationReady: true),
      CoordinatorRealtimeEnqueueResult.replacedPending,
    );
    expect(
      pending.enqueue(datagram(1, 2),
          committedMembers: members, destinationReady: true),
      CoordinatorRealtimeEnqueueResult.enqueued,
    );
    expect(pending.take(source, destination, 1)!.sequence, 2);
    expect(pending.take(source, destination, 2)!.sequence, 1);
  });

  test('unavailable or removed destinations have no pending realtime relay',
      () {
    final pending = CoordinatorRealtimePending(maxPendingDatagrams: 1);
    final source = PeerId(List.filled(16, 1));
    final destination = PeerId(List.filled(16, 2));
    final datagram = GroupRealtimeDatagram(
      groupId: GroupId(List.filled(16, 3)),
      sourcePeerId: source,
      destinationPeerId: destination,
      channelId: 1,
      sequence: 1,
      senderTick: 1,
      bytes: [1],
    );
    expect(
      pending.enqueue(datagram,
          committedMembers: {source, destination}, destinationReady: false),
      CoordinatorRealtimeEnqueueResult.droppedDestinationUnavailable,
    );
    pending.enqueue(datagram,
        committedMembers: {source, destination}, destinationReady: true);
    pending.destinationRemoved(destination);
    expect(pending.length, 0);
    pending.coordinatorAuthorityLost();
    expect(pending.length, 0);
  });
}

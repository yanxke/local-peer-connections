import 'dart:async';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId peer(int n) => PeerId(List<int>.filled(16, n));

void main() {
  test('GroupConfig validates the normative scoped-token rules', () {
    expect(() => GroupConfig(applicationNamespace: [1]),
        throwsA(isA<LpcException>()));
    expect(
        () => GroupConfig(
            applicationNamespace: [1], groupJoinToken: List.filled(15, 0)),
        throwsA(isA<LpcException>()));
  });

  // UT-114: committed membership is visible before MemberJoined delivery.
  test('UT-114 committed membership is visible before MemberJoined', () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    final seen = Completer<bool>();
    final sub = group.events.listen((event) {
      if (event is MemberJoined)
        seen.complete(
            group.members.any((m) => m.peerId == event.member.peerId));
    });
    group.commitMembership([GroupMember(peer(1), 8), GroupMember(peer(2), 8)],
        coordinator: peer(1));
    expect(await seen.future, isTrue);
    await sub.cancel();
    await runtime.close();
  });

  test('UT-114 committed membership is visible before MemberLeft', () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    group.commitMembership([GroupMember(peer(1), 8), GroupMember(peer(2), 8)],
        coordinator: peer(1));
    final seen = Completer<bool>();
    final sub = group.events.listen((event) {
      if (event is MemberLeft) {
        seen.complete(group.members.every((m) => m.peerId != event.peerId));
      }
    });
    group.commitMembership([GroupMember(peer(1), 8)], coordinator: peer(1));
    expect(await seen.future, isTrue);
    await sub.cancel();
    await runtime.close();
  });

  test('UT-115 coordinator getter is updated before CoordinatorChanged',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    final seen = Completer<bool>();
    final sub = group.events.listen((event) {
      if (event is CoordinatorChanged) {
        seen.complete(group.coordinatorPeerId == event.current &&
            group.isCoordinator == event.localIsCoordinator);
      }
    });
    group.commitMembership([GroupMember(peer(1), 8), GroupMember(peer(2), 8)],
        coordinator: peer(2));
    expect(await seen.future, isTrue);
    await sub.cancel();
    await runtime.close();
  });

  test('COORD-004/005/010 migration preserves GroupId and committed members',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    final originalGroupId = group.groupId;
    final committed = [
      GroupMember(peer(1), 8),
      GroupMember(peer(2), 8),
      GroupMember(peer(3), 8),
    ];
    group.commitMembership(committed, coordinator: peer(1));

    // Election changes coordinator authority; it neither creates a new GroupId
    // nor discards the last authenticated committed membership snapshot.
    group.commitMembership(committed, coordinator: peer(2));
    expect(group.groupId, originalGroupId);
    expect(group.coordinatorPeerId, peer(2));
    expect(group.members.map((member) => member.peerId),
        [peer(1), peer(2), peer(3)]);
    await runtime.close();
  });

  test('COORD-011 promoted coordinator receives latest checkpoint', () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
      applicationNamespace: [1],
      groupJoinToken: List.filled(16, 0),
      coordinatorCheckpointing: true,
    ));
    final changes = <CoordinatorChanged>[];
    final sub = group.events.listen((event) {
      if (event is CoordinatorChanged) changes.add(event);
    });
    final members = [GroupMember(peer(1), 8), GroupMember(peer(2), 8)];
    group.commitMembership(members, coordinator: peer(1));
    group.publishCoordinatorCheckpoint([1, 2, 3]);
    group.commitMembership(members, coordinator: peer(2));
    group.commitMembership(members, coordinator: peer(1));

    expect(changes.last.localIsCoordinator, isTrue);
    expect(changes.last.latestCoordinatorCheckpoint, [1, 2, 3]);
    expect(group.latestCoordinatorCheckpoint(), [1, 2, 3]);
    await sub.cancel();
    await runtime.close();
  });

  test('checkpoint publishing is bounded to four accepted values per second',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
      applicationNamespace: [1],
      groupJoinToken: List.filled(16, 0),
      coordinatorCheckpointing: true,
    ));
    for (var value = 1; value <= 4; value++) {
      group.publishCoordinatorCheckpoint([value]);
    }
    expect(
      () => group.publishCoordinatorCheckpoint([5]),
      throwsA(isA<LpcException>().having(
          (error) => error.code, 'code', LpcErrorCode.resourceExhausted)),
    );
    expect(group.latestCoordinatorCheckpoint(), [4]);
    await runtime.close();
  });

  test('UT-116 GroupSession callbacks are serialized', () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    var activeCallbacks = 0;
    var maxActiveCallbacks = 0;
    var requestedNestedCommit = false;
    final sub = group.events.listen((event) {
      activeCallbacks++;
      maxActiveCallbacks = max(maxActiveCallbacks, activeCallbacks);
      if (event is MemberJoined && !requestedNestedCommit) {
        requestedNestedCommit = true;
        group.commitMembership(
          [
            GroupMember(peer(1), 8),
            GroupMember(peer(2), 8),
            GroupMember(peer(3), 8),
          ],
          coordinator: peer(1),
        );
      }
      activeCallbacks--;
    });
    group.commitMembership([GroupMember(peer(1), 8), GroupMember(peer(2), 8)],
        coordinator: peer(1));
    expect(maxActiveCallbacks, 1);
    expect(group.members.map((member) => member.peerId),
        [peer(1), peer(2), peer(3)]);
    await sub.cancel();
    await runtime.close();
  });

  test('UT-117 reentrant GroupSession send is queued without deadlock',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    final sent = Completer<SendState>();
    var sendWasQueuedDuringCallback = false;
    final sub = group.events.listen((event) {
      if (event is MemberJoined && event.member.peerId == peer(2)) {
        final handle = group.send(peer(2), [1]);
        sendWasQueuedDuringCallback = handle.state == SendState.queued;
        handle.completed.then(sent.complete);
      }
    });
    group.commitMembership([GroupMember(peer(1), 8), GroupMember(peer(2), 8)],
        coordinator: peer(1));
    expect(sendWasQueuedDuringCallback, isTrue);
    expect(await sent.future.timeout(const Duration(seconds: 1)),
        SendState.sentToTransport);
    await sub.cancel();
    await runtime.close();
  });

  test('GroupError is serialized without changing committed group state',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    final seen = Completer<GroupError>();
    final sub = group.events.listen((event) {
      if (event is GroupError && !seen.isCompleted) seen.complete(event);
    });

    group.reportError(
      LpcErrorCode.ackTimeout,
      peerId: peer(2),
      groupMessageId: GroupMessageId(List.filled(16, 3)),
      diagnostic: 'route signaling failure',
    );
    final event = await seen.future;
    expect(event.errorCode, LpcErrorCode.ackTimeout);
    expect(event.peerId, peer(2));
    expect(event.groupMessageId, GroupMessageId(List.filled(16, 3)));
    expect(group.state, GroupState.ready);
    await sub.cancel();
    await runtime.close();
  });

  test('UT-037 runtime close cascades to each GroupSession exactly once',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final first = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    final second = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [2], groupJoinToken: List.filled(16, 1)));
    var closedEvents = 0;
    final subscriptions = [first, second]
        .map((group) => group.events.listen((event) {
              if (event is GroupClosed) closedEvents++;
            }))
        .toList();

    await runtime.close();
    await runtime.close();

    expect(runtime.state, RuntimeState.closed);
    expect(first.state, GroupState.closed);
    expect(second.state, GroupState.closed);
    expect(closedEvents, 2);
    await Future.wait(
        subscriptions.map((subscription) => subscription.cancel()));
  });

  // UT-104: application destinations must be committed members.
  test('UT-104 rejects a destination absent from committed membership',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    final handle = group.send(peer(2), [1]);
    expect(await handle.completed, SendState.failed);
    await runtime.close();
  });

  test('realtime API rejects reserved channels and oversized payloads',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    group.commitMembership([GroupMember(peer(1), 8), GroupMember(peer(2), 8)],
        coordinator: peer(1));
    expect(
        await group.sendRealtime(peer(2), 0, [1]).completed, SendState.failed);
    expect(await group.sendRealtime(peer(2), 1, List.filled(1101, 0)).completed,
        SendState.failed);
    await runtime.close();
  });

  test('UT-113 realtime delivery exposes routed fields once per latest state',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    group.commitMembership([GroupMember(peer(1), 8), GroupMember(peer(2), 8)],
        coordinator: peer(1));
    final received = Completer<RealtimeDatagramReceived>();
    final sub = group.events.listen((event) {
      if (event is RealtimeDatagramReceived && !received.isCompleted) {
        received.complete(event);
      }
    });

    group.receiveRealtime(
      source: peer(2),
      channelId: 7,
      senderTick: 9,
      datagramSequence: 2,
      bytes: [3, 4],
    );
    // An older state from the same source/channel is silently suppressed.
    group.receiveRealtime(
      source: peer(2),
      channelId: 7,
      senderTick: 8,
      datagramSequence: 1,
      bytes: [5],
    );

    final event = await received.future;
    expect(event.sourcePeerId, peer(2));
    expect(event.channelId, 7);
    expect(event.senderTick, 9);
    expect(event.datagramSequence, 2);
    expect(event.bytes, [3, 4]);
    await sub.cancel();
    await runtime.close();
  });

  test('UT-112 reliable delivery exposes routed fields once', () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    group.commitMembership([GroupMember(peer(1), 8), GroupMember(peer(2), 8)],
        coordinator: peer(1));
    final received = Completer<ReliableMessageReceived>();
    final sub = group.events.listen((event) {
      if (event is ReliableMessageReceived && !received.isCompleted) {
        received.complete(event);
      }
    });
    final id = GroupMessageId(List.filled(16, 7));

    group.receiveReliable(
      source: peer(2),
      id: id,
      mode: DeliveryMode.reliableAcked,
      bytes: [3, 4],
    );
    // The completed GroupMessageId cache suppresses an identical relay.
    group.receiveReliable(
      source: peer(2),
      id: id,
      mode: DeliveryMode.reliableAcked,
      bytes: [3, 4],
    );

    final event = await received.future;
    expect(event.sourcePeerId, peer(2));
    expect(event.groupMessageId, id);
    expect(event.deliveryMode, DeliveryMode.reliableAcked);
    expect(event.bytes, [3, 4]);
    await sub.cancel();
    await runtime.close();
  });

  test('UT-118 different sources retain observation order, not a total order',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    group.commitMembership([
      GroupMember(peer(1), 8),
      GroupMember(peer(2), 8),
      GroupMember(peer(3), 8),
    ], coordinator: peer(1));
    final observedSources = <PeerId>[];
    final sub = group.events.listen((event) {
      if (event is ReliableMessageReceived) {
        observedSources.add(event.sourcePeerId);
      }
    });

    // Source 3 is observed first even though source 2 is lexicographically
    // earlier: there is no cross-source ordering rule to reorder them.
    group.receiveReliable(
      source: peer(3),
      id: GroupMessageId(List.filled(16, 3)),
      mode: DeliveryMode.reliableOrdered,
      bytes: [3],
    );
    group.receiveReliable(
      source: peer(2),
      id: GroupMessageId(List.filled(16, 2)),
      mode: DeliveryMode.reliableOrdered,
      bytes: [2],
    );

    expect(observedSources, [peer(3), peer(2)]);
    await sub.cancel();
    await runtime.close();
  });

  test('UT-109 broadcast excludes local peer and snapshots committed members',
      () async {
    final runtime = await createRuntime(localPeerId: peer(2));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    group.commitMembership([
      GroupMember(peer(2), 8),
      GroupMember(peer(3), 8),
      GroupMember(peer(1), 8)
    ], coordinator: peer(2));
    final broadcast = group.broadcast([1]);
    expect(broadcast.handles.length, 2);
    expect(broadcast.targetPeerIds, [peer(1), peer(3)]);
    expect(broadcast.results.keys, [peer(1), peer(3)]);
    group.commitMembership([
      GroupMember(peer(2), 8),
      GroupMember(peer(3), 8),
      GroupMember(peer(1), 8),
      GroupMember(peer(4), 8),
    ], coordinator: peer(2));
    expect(broadcast.targetPeerIds, [peer(1), peer(3)]);
    expect(broadcast.state, BroadcastState.completed);
    expect(await broadcast.completed, BroadcastState.completed);
    await runtime.close();
  });

  test('UT-110/COORD-058 broadcast snapshots remote members independently',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    group.commitMembership([GroupMember(peer(1), 8), GroupMember(peer(2), 8)],
        coordinator: peer(1));
    final broadcast = group.broadcast([1]);
    expect(broadcast.state, BroadcastState.completed);
    expect(await broadcast.completed, BroadcastState.completed);
    await runtime.close();
  });

  test('UT-111 RealtimeBroadcastHandle completes across its constituents',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    group.commitMembership([GroupMember(peer(1), 8), GroupMember(peer(2), 8)],
        coordinator: peer(1));
    final broadcast = group.broadcastRealtime(1, [1]);
    expect(await broadcast.completed, BroadcastState.completed);
    broadcast.cancel();
    expect(broadcast.state, BroadcastState.completed);
    await runtime.close();
  });
}

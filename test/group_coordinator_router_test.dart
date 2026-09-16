import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int value) => PeerId(List.filled(16, value));
GroupId _group(int value) => GroupId(List.filled(16, value));

GroupCoordinatorRouter _router() {
  final coordinator = _peer(1);
  final validator = GroupRoutingValidator(
    canonicalGroupId: _group(1),
    localPeerId: coordinator,
    currentCoordinatorPeerId: coordinator,
    committedMembers: {coordinator, _peer(2), _peer(3)},
  );
  final controller = CoordinatorRelayController(
    canonicalGroupId: _group(1),
    coordinatorPeerId: coordinator,
    relays: CoordinatorRelayTable(
      coordinatorPeerId: coordinator,
      maxReservedBytesPerDestination: 100,
      maxReservedMessagesPerDestination: 2,
    ),
  );
  return GroupCoordinatorRouter(
    validator: validator,
    reliableController: controller,
    realtimePending: CoordinatorRealtimePending(maxPendingDatagrams: 2),
  );
}

ReassembledGroupReliable _reliable() => ReassembledGroupReliable(
      pairwiseMessageId: List.filled(8, 9),
      groupId: _group(1),
      sourcePeerId: _peer(2),
      destinationPeerId: _peer(3),
      groupMessageId: GroupMessageId(List.filled(16, 4)),
      deliveryMode: DeliveryMode.reliableAcked,
      priority: SendPriority.interactive,
      bytes: [7],
    );

GroupRealtimeDatagram _realtime() => GroupRealtimeDatagram(
      groupId: _group(1),
      sourcePeerId: _peer(2),
      destinationPeerId: _peer(3),
      channelId: 1,
      sequence: 1,
      senderTick: 4,
      bytes: [8],
    );

void main() {
  test('router validates, admits, and exposes a reliable forwarding action',
      () {
    final router = _router();
    final actions = router.receiveReliableFromMember(
      _reliable(),
      authenticatedSendingPeerId: _peer(2),
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: List.filled(8, 6),
    );
    expect(actions.forward, isNotNull);
    expect(actions.sourceHopGenericAckMessageId, List.filled(8, 9));
  });

  test('UT-104/COORD-054 B-to-C relays through A without a B-C link', () {
    // This test constructs only coordinator A's routing owner. B submits the
    // source hop to A; A produces C's final hop with a distinct pairwise ID.
    final actions = _router().receiveReliableFromMember(
      _reliable(),
      authenticatedSendingPeerId: _peer(2),
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: List.filled(8, 6),
    );

    expect(actions.sourceHopGenericAckMessageId, List.filled(8, 9));
    expect(actions.forward, isNotNull);
    expect(actions.forward!.sourcePeerId, _peer(2));
    expect(actions.forward!.destinationPeerId, _peer(3));
    expect(actions.forward!.pairwiseMessageId, List.filled(8, 6));
    expect(actions.forward!.groupMessageId, _reliable().groupMessageId);
  });

  test('UT-108 router preserves realtime source through coordinator relay', () {
    final router = _router();
    expect(
      router.receiveRealtimeFromMember(
        _realtime(),
        authenticatedSendingPeerId: _peer(2),
        destinationReady: true,
      ),
      CoordinatorRealtimeEnqueueResult.enqueued,
    );
    expect(router.realtimePending.length, 1);
    final forwarded = router.realtimePending.take(_peer(2), _peer(3), 1);
    expect(forwarded!.sourcePeerId, _peer(2));
    expect(forwarded.destinationPeerId, _peer(3));
  });

  test('UT-122 unavailable destination rejects reliable and drops realtime',
      () {
    final router = _router();
    final reliable = router.receiveReliableFromMember(
      _reliable(),
      authenticatedSendingPeerId: _peer(2),
      destinationReady: false,
      reservationBytes: 10,
    );
    expect(reliable.sourceHopGenericAckMessageId, List.filled(8, 9));
    expect(
        reliable.relayStatus!.status, GroupRelayStatus.destinationUnavailable);
    expect(router.reliableController.relays.admittedRelayCount, 0);
    expect(
      router.receiveRealtimeFromMember(
        _realtime(),
        authenticatedSendingPeerId: _peer(2),
        destinationReady: false,
      ),
      CoordinatorRealtimeEnqueueResult.droppedDestinationUnavailable,
    );
  });

  test('UT-120 final-hop ACK timeout emits DESTINATION_ACK_TIMEOUT', () {
    final router = _router();
    final operation = _reliable();
    router.receiveReliableFromMember(
      operation,
      authenticatedSendingPeerId: _peer(2),
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: List.filled(8, 6),
    );

    final actions = router.reliableController.finalHopFailed(
      _peer(2),
      operation.groupMessageId,
      GroupRelayStatus.destinationAckTimeout,
    );
    expect(actions.relayStatus?.status, GroupRelayStatus.destinationAckTimeout);
    expect(actions.relayStatus?.errorCode, LpcErrorCode.ackTimeout);
    expect(router.reliableController.relays.admittedRelayCount, 0);
  });

  test('router removal and authority-loss clean both routing domains', () {
    final router = _router();
    router.receiveReliableFromMember(
      _reliable(),
      authenticatedSendingPeerId: _peer(2),
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: List.filled(8, 6),
    );
    router.receiveRealtimeFromMember(
      _realtime(),
      authenticatedSendingPeerId: _peer(2),
      destinationReady: true,
    );

    expect(router.destinationRemoved(_peer(3)).single.relayStatus!.status,
        GroupRelayStatus.destinationNotInGroup);
    expect(router.realtimePending.length, 0);

    router.receiveRealtimeFromMember(
      _realtime(),
      authenticatedSendingPeerId: _peer(2),
      destinationReady: true,
    );
    router.coordinatorAuthorityLost();
    expect(router.realtimePending.length, 0);
  });

  test('router retries retained final-hop relay only after destination RESUME',
      () {
    final router = _router();
    router.receiveReliableFromMember(
      _reliable(),
      authenticatedSendingPeerId: _peer(2),
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: List.filled(8, 6),
    );

    final retries = router.destinationResumeSucceeded(_peer(3));
    expect(retries.single.forward!.groupMessageId, _reliable().groupMessageId);

    final failures = router.destinationResumeFailed(_peer(3));
    expect(failures.single.relayStatus!.status,
        GroupRelayStatus.destinationUnavailable);
  });
}

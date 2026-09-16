import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int value) => PeerId(List.filled(16, value));
GroupId _group() => GroupId(List.filled(16, 1));
GroupMessageId _message() => GroupMessageId(List.filled(16, 4));

GroupMemberRouter _router({int coordinator = 1}) => GroupMemberRouter(
      validator: GroupRoutingValidator(
        canonicalGroupId: _group(),
        localPeerId: _peer(2),
        currentCoordinatorPeerId: _peer(coordinator),
        committedMembers: {_peer(1), _peer(2), _peer(3), _peer(4)},
      ),
      sends: RoutedSendTable(localPeerId: _peer(2)),
    );

StaleCoordinatorClassifier _formerCoordinator() => StaleCoordinatorClassifier(
      immediatelyPreviousCoordinator: _peer(1),
      historicalSessionId: List.filled(16, 9),
    );

RoutedGroupOperation _operation(
        {DeliveryMode mode = DeliveryMode.reliableAcked}) =>
    RoutedGroupOperation(
      groupId: _group(),
      sourcePeerId: _peer(2),
      destinationPeerId: _peer(3),
      groupMessageId: _message(),
      deliveryMode: mode,
      priority: SendPriority.interactive,
      bytes: [7],
    );

void main() {
  test(
      'member router retains ACKed sends until current coordinator delivery ACK',
      () {
    final router = _router();
    final operation = _operation();
    expect(router.begin(operation), SendState.transmitting);
    expect(router.coordinatorRouteLost(), [operation]);

    expect(
      router.receiveDeliveryAck(
        GroupDeliveryAck(
          groupId: _group(),
          sourcePeerId: _peer(2),
          destinationPeerId: _peer(3),
          groupMessageId: _message(),
        ),
        authenticatedSendingPeerId: _peer(1),
      ),
      SendState.remoteAcknowledged,
    );
    expect(router.coordinatorRouteLost(), isEmpty);
  });

  test('UT-105 RELIABLE_ACKED ignores source-hop ACK until delivery ACK', () {
    final router = _router();
    final operation = _operation();
    expect(router.begin(operation), SendState.transmitting);

    // The coordinator's generic ACK is hop-local. There is deliberately no
    // public-state transition for it, so the operation stays rerouteable.
    expect(router.sends.stateFor(operation.groupMessageId),
        SendState.transmitting);
    expect(router.coordinatorRouteLost(), [operation]);

    expect(
      router.receiveDeliveryAck(
        GroupDeliveryAck(
          groupId: _group(),
          sourcePeerId: _peer(2),
          destinationPeerId: _peer(3),
          groupMessageId: _message(),
        ),
        authenticatedSendingPeerId: _peer(1),
      ),
      SendState.remoteAcknowledged,
    );
    expect(router.sends.stateFor(operation.groupMessageId), isNull);
  });

  test('UT-119 source-hop final ACK timeout terminates the group send', () {
    final router = _router();
    final operation = _operation();
    router.begin(operation);

    final result = router.sourceHopAckTimedOut(operation.groupMessageId);
    expect(result?.state, SendState.failed);
    expect(result?.errorCode, LpcErrorCode.ackTimeout);
    expect(router.coordinatorRouteLost(), isEmpty);
  });

  test('UT-121 delivery ACK timeout reconnects and reroutes without redelivery',
      () {
    final source = _router();
    final operation = _operation();
    source.begin(operation);
    final destination = GroupDestinationRouter(
      validator: GroupRoutingValidator(
        canonicalGroupId: _group(),
        localPeerId: _peer(3),
        currentCoordinatorPeerId: _peer(1),
        committedMembers: {_peer(1), _peer(2), _peer(3)},
      ),
    );
    final delivered = ReassembledGroupReliable(
      pairwiseMessageId: List.filled(8, 9),
      groupId: _group(),
      sourcePeerId: _peer(2),
      destinationPeerId: _peer(3),
      groupMessageId: _message(),
      deliveryMode: DeliveryMode.reliableAcked,
      priority: SendPriority.interactive,
      bytes: [7],
    );
    expect(
      destination
          .receiveReliable(delivered, authenticatedSendingPeerId: _peer(1))
          .disposition,
      ReliableDestinationDisposition.deliver,
    );

    final timeout = GroupControlTimeoutRecovery().onFinalAckTimeout(
      type: FrameType.groupDeliveryAck,
      peerId: _peer(2),
      groupMessageId: _message(),
    ) as RouteSignalingTimeoutRecovery;
    expect(timeout.groupErrorCode, LpcErrorCode.ackTimeout);
    expect(timeout.requiresSourceLinkReconnect, isTrue);
    // The source never received the delivery ACK, so it retains the same
    // end-destination identity for the post-READY whole-operation reroute.
    expect(source.coordinatorRouteLost(), [operation]);

    final rerouted = ReassembledGroupReliable(
      pairwiseMessageId: List.filled(8, 6),
      groupId: _group(),
      sourcePeerId: _peer(2),
      destinationPeerId: _peer(3),
      groupMessageId: _message(),
      deliveryMode: DeliveryMode.reliableAcked,
      priority: SendPriority.interactive,
      bytes: [7],
    );
    expect(
      destination
          .receiveReliable(rerouted, authenticatedSendingPeerId: _peer(1))
          .disposition,
      ReliableDestinationDisposition.duplicate,
    );
  });

  test('member router permits ordered completion only from current coordinator',
      () {
    final router = _router();
    router.begin(_operation(mode: DeliveryMode.reliableOrdered));
    final status = GroupRelayStatusPayload(
      groupId: _group(),
      sourcePeerId: _peer(2),
      destinationPeerId: _peer(3),
      groupMessageId: _message(),
      status: GroupRelayStatus.sentToDestinationTransport,
    );
    expect(
      () => router.receiveRelayStatus(status,
          authenticatedSendingPeerId: _peer(3)),
      throwsA(isA<LpcException>()),
    );
    expect(
      router.receiveRelayStatus(status, authenticatedSendingPeerId: _peer(1)),
      SendState.sentToTransport,
    );
  });

  test('member router cancellation removes reroute ownership', () {
    final router = _router();
    final operation = _operation();
    router.begin(operation);
    expect(router.cancel(_message()), operation);
    expect(router.coordinatorRouteLost(), isEmpty);
  });

  test('UT-137/COORD-063 admitted relay may finish after source cancellation',
      () {
    final source = _router();
    final operation = _operation();
    source.begin(operation);
    final coordinator = CoordinatorRelayController(
      canonicalGroupId: _group(),
      coordinatorPeerId: _peer(1),
      relays: CoordinatorRelayTable(
        coordinatorPeerId: _peer(1),
        maxReservedBytesPerDestination: 100,
        maxReservedMessagesPerDestination: 1,
      ),
    );
    coordinator.admit(
      ReassembledGroupReliable(
        pairwiseMessageId: List.filled(8, 9),
        groupId: _group(),
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        groupMessageId: _message(),
        deliveryMode: DeliveryMode.reliableAcked,
        priority: SendPriority.interactive,
        bytes: [7],
      ),
      committedMembers: {_peer(1), _peer(2), _peer(3)},
      destinationReady: true,
      reservationBytes: 1,
      destinationPairwiseMessageId: List.filled(8, 6),
    );

    source.cancel(_message(), signalingSessionIds: [List.filled(16, 9)]);
    expect(source.coordinatorRouteLost(), isEmpty);
    final complete = coordinator.finalHopAcknowledged(_peer(2), _message());
    expect(complete.deliveryAck, isNotNull);
    expect(
      source
          .receiveDeliveryAckResult(
            complete.deliveryAck!,
            authenticatedSendingPeerId: _peer(1),
          )
          .disposition,
      GroupRouteSignalDisposition.cancelled,
    );
  });

  test('UT-149/COORD-066 authority loss stops admitted relay ownership', () {
    final source = _router();
    source.begin(_operation());
    final coordinator = CoordinatorRelayController(
      canonicalGroupId: _group(),
      coordinatorPeerId: _peer(1),
      relays: CoordinatorRelayTable(
        coordinatorPeerId: _peer(1),
        maxReservedBytesPerDestination: 100,
        maxReservedMessagesPerDestination: 1,
      ),
    );
    coordinator.admit(
      ReassembledGroupReliable(
        pairwiseMessageId: List.filled(8, 9),
        groupId: _group(),
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        groupMessageId: _message(),
        deliveryMode: DeliveryMode.reliableAcked,
        priority: SendPriority.interactive,
        bytes: [7],
      ),
      committedMembers: {_peer(1), _peer(2), _peer(3)},
      destinationReady: true,
      reservationBytes: 1,
      destinationPairwiseMessageId: List.filled(8, 6),
    );
    source.cancel(_message(), signalingSessionIds: [List.filled(16, 9)]);

    coordinator.coordinatorAuthorityLost();
    expect(coordinator.relays.admittedRelayCount, 0);
    expect(coordinator.destinationResumeSucceeded(_peer(3)), isEmpty);
    expect(source.coordinatorRouteLost(), isEmpty);
  });

  test('UT-140 CANCELLED does not prove destination non-delivery', () {
    final source = _router();
    source.begin(_operation());
    final coordinator = CoordinatorRelayController(
      canonicalGroupId: _group(),
      coordinatorPeerId: _peer(1),
      relays: CoordinatorRelayTable(
        coordinatorPeerId: _peer(1),
        maxReservedBytesPerDestination: 100,
        maxReservedMessagesPerDestination: 1,
      ),
    );
    final admitted = coordinator.admit(
      ReassembledGroupReliable(
        pairwiseMessageId: List.filled(8, 9),
        groupId: _group(),
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        groupMessageId: _message(),
        deliveryMode: DeliveryMode.reliableAcked,
        priority: SendPriority.interactive,
        bytes: [7],
      ),
      committedMembers: {_peer(1), _peer(2), _peer(3)},
      destinationReady: true,
      reservationBytes: 1,
      destinationPairwiseMessageId: List.filled(8, 6),
    );
    final destination = GroupDestinationRouter(
      validator: GroupRoutingValidator(
        canonicalGroupId: _group(),
        localPeerId: _peer(3),
        currentCoordinatorPeerId: _peer(1),
        committedMembers: {_peer(1), _peer(2), _peer(3)},
      ),
    );
    expect(
      destination
          .receiveReliable(admitted.forward!,
              authenticatedSendingPeerId: _peer(1))
          .disposition,
      ReliableDestinationDisposition.deliver,
    );

    source.cancel(_message(), signalingSessionIds: [List.filled(16, 9)]);
    final complete = coordinator.finalHopAcknowledged(_peer(2), _message());
    expect(
      source
          .receiveDeliveryAckResult(
            complete.deliveryAck!,
            authenticatedSendingPeerId: _peer(1),
          )
          .disposition,
      GroupRouteSignalDisposition.cancelled,
    );
  });

  test('UT-138 cancelled delivery ACK is generic-ACKed and discarded', () {
    final router = _router();
    router.begin(_operation());
    router.cancel(
      _message(),
      signalingSessionIds: [List.filled(16, 9)],
    );

    final result = router.receiveDeliveryAckResult(
      GroupDeliveryAck(
        groupId: _group(),
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        groupMessageId: _message(),
      ),
      authenticatedSendingPeerId: _peer(1),
    );
    expect(result.disposition, GroupRouteSignalDisposition.cancelled);
    expect(result.state, isNull);
    expect(result.requiresGenericAck, isTrue);
  });

  test('UT-139 cancelled relay status is generic-ACKed and discarded', () {
    final router = _router();
    router.begin(_operation());
    router.cancel(
      _message(),
      signalingSessionIds: [List.filled(16, 9)],
    );

    final result = router.receiveRelayStatusResult(
      GroupRelayStatusPayload(
        groupId: _group(),
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        groupMessageId: _message(),
        status: GroupRelayStatus.destinationUnavailable,
      ),
      authenticatedSendingPeerId: _peer(1),
    );
    expect(result.disposition, GroupRouteSignalDisposition.cancelled);
    expect(result.state, isNull);
    expect(result.requiresGenericAck, isTrue);
  });

  test('cancelled ordered send rejects impossible success signaling', () {
    final router = _router();
    router.begin(_operation(mode: DeliveryMode.reliableOrdered));
    router.cancel(
      _message(),
      signalingSessionIds: [List.filled(16, 9)],
    );

    expect(
      () => router.receiveDeliveryAckResult(
        GroupDeliveryAck(
          groupId: _group(),
          sourcePeerId: _peer(2),
          destinationPeerId: _peer(3),
          groupMessageId: _message(),
        ),
        authenticatedSendingPeerId: _peer(1),
      ),
      throwsA(isA<LpcException>()),
    );
  });

  test('cancel tombstone capacity is reserved when admitting routed sends', () {
    final router = GroupMemberRouter(
      validator: GroupRoutingValidator(
        canonicalGroupId: _group(),
        localPeerId: _peer(2),
        currentCoordinatorPeerId: _peer(1),
        committedMembers: {_peer(1), _peer(2), _peer(3)},
      ),
      sends: RoutedSendTable(localPeerId: _peer(2), capacity: 2),
      tombstones: CancellationTombstoneTable(capacity: 1),
    );
    router.begin(_operation());
    expect(
      () => router.begin(_operation()),
      throwsA(isA<LpcException>()),
    );
  });

  test('UT-143 GroupSession-close equivalent releases all tombstones', () {
    final router = _router();
    router.begin(_operation());
    router.cancel(
      _message(),
      signalingSessionIds: [List.filled(16, 9)],
    );
    expect(router.tombstones.length, 1);

    router.close();
    expect(router.tombstones.length, 0);
  });

  test('UT-145 stale former-coordinator signaling cannot complete active send',
      () {
    final router = _router();
    final operation = _operation();
    router.begin(operation);

    final result = router.receiveStaleDeliveryAck(
      GroupDeliveryAck(
        groupId: _group(),
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        groupMessageId: _message(),
      ),
      classifier: _formerCoordinator(),
      authenticatedSendingPeerId: _peer(1),
      sessionId: List.filled(16, 9),
      createdBeforeAuthorityLoss: true,
      historicalRouteIsValid: true,
      cryptographicallyAndSequenceValid: true,
      genericAckRequiredValid: true,
    );
    expect(result.disposition, GroupRouteSignalDisposition.stale);
    expect(result.requiresGenericAck, isTrue);
    expect(router.coordinatorRouteLost(), [operation]);
  });

  test('UT-144/COORD-065 stale former ACK preserves CANCELLED state', () {
    final router = _router();
    router.begin(_operation());
    router.cancel(
      _message(),
      signalingSessionIds: [List.filled(16, 9)],
    );

    final result = router.receiveStaleDeliveryAck(
      GroupDeliveryAck(
        groupId: _group(),
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        groupMessageId: _message(),
      ),
      classifier: _formerCoordinator(),
      authenticatedSendingPeerId: _peer(1),
      sessionId: List.filled(16, 9),
      createdBeforeAuthorityLoss: true,
      historicalRouteIsValid: true,
      cryptographicallyAndSequenceValid: true,
      genericAckRequiredValid: true,
    );
    expect(result.disposition, GroupRouteSignalDisposition.stale);
    expect(result.requiresGenericAck, isTrue);
    expect(router.coordinatorRouteLost(), isEmpty);
  });

  test('UT-150/COORD-068 old delivery ACK leaves active send nonterminal', () {
    final router = _router(coordinator: 4);
    final operation = _operation();
    router.begin(operation);

    final result = router.receiveStaleDeliveryAck(
      GroupDeliveryAck(
        groupId: _group(),
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        groupMessageId: _message(),
      ),
      classifier: _formerCoordinator(),
      authenticatedSendingPeerId: _peer(1),
      sessionId: List.filled(16, 9),
      createdBeforeAuthorityLoss: true,
      historicalRouteIsValid: true,
      cryptographicallyAndSequenceValid: true,
      genericAckRequiredValid: true,
    );
    expect(result.disposition, GroupRouteSignalDisposition.stale);
    expect(result.requiresGenericAck, isTrue);
    expect(router.coordinatorRouteLost(), [operation]);
  });

  test('UT-151 in-flight old relay status is ACKed and leaves send nonterminal',
      () {
    final router = _router(coordinator: 4);
    final operation = _operation();
    router.begin(operation);

    final result = router.receiveStaleRelayStatus(
      GroupRelayStatusPayload(
        groupId: _group(),
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        groupMessageId: _message(),
        status: GroupRelayStatus.destinationUnavailable,
      ),
      classifier: _formerCoordinator(),
      authenticatedSendingPeerId: _peer(1),
      sessionId: List.filled(16, 9),
      createdBeforeAuthorityLoss: true,
      historicalRouteIsValid: true,
      cryptographicallyAndSequenceValid: true,
      genericAckRequiredValid: true,
    );
    expect(result.disposition, GroupRouteSignalDisposition.stale);
    expect(result.requiresGenericAck, isTrue);
    expect(router.coordinatorRouteLost(), [operation]);
  });

  test('UT-146 new former-coordinator signaling remains a protocol error', () {
    final router = _router();
    expect(
      () => router.receiveStaleRelayStatus(
        GroupRelayStatusPayload(
          groupId: _group(),
          sourcePeerId: _peer(2),
          destinationPeerId: _peer(3),
          groupMessageId: _message(),
          status: GroupRelayStatus.destinationUnavailable,
        ),
        classifier: _formerCoordinator(),
        authenticatedSendingPeerId: _peer(1),
        sessionId: List.filled(16, 9),
        createdBeforeAuthorityLoss: false,
        historicalRouteIsValid: true,
        cryptographicallyAndSequenceValid: true,
        genericAckRequiredValid: true,
      ),
      throwsA(isA<LpcException>()),
    );
  });
}

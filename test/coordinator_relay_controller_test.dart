import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int value) => PeerId(List.filled(16, value));
GroupId _group(int value) => GroupId(List.filled(16, value));
GroupMessageId _message(int value) => GroupMessageId(List.filled(16, value));

ReassembledGroupReliable _operation({
  int destination = 3,
  int message = 4,
  DeliveryMode mode = DeliveryMode.reliableAcked,
  GroupId? groupId,
  List<int> bytes = const [7, 8],
}) =>
    ReassembledGroupReliable(
      pairwiseMessageId: List.filled(8, 9),
      groupId: groupId ?? _group(1),
      sourcePeerId: _peer(2),
      destinationPeerId: _peer(destination),
      groupMessageId: _message(message),
      deliveryMode: mode,
      priority: SendPriority.interactive,
      bytes: bytes,
    );

const _destinationHopMessageId = [6, 6, 6, 6, 6, 6, 6, 6];

CoordinatorRelayController _controller() {
  final coordinator = _peer(1);
  return CoordinatorRelayController(
    canonicalGroupId: _group(8),
    coordinatorPeerId: coordinator,
    relays: CoordinatorRelayTable(
      coordinatorPeerId: coordinator,
      maxReservedBytesPerDestination: 100,
      maxReservedMessagesPerDestination: 2,
    ),
  );
}

void main() {
  final members = <PeerId>{_peer(1), _peer(2), _peer(3)};

  test('UT-106 relay preserves GroupMessageId across independent hop IDs', () {
    final controller = _controller();
    final operation = _operation(mode: DeliveryMode.reliableOrdered);
    final admission = controller.admit(
      operation,
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );
    expect(admission.sourceHopGenericAckMessageId, List.filled(8, 9));
    expect(admission.forward!.groupId, _group(8));
    expect(admission.forward!.pairwiseMessageId, _destinationHopMessageId);
    expect(admission.forward!.groupMessageId, operation.groupMessageId);

    final complete = controller.finalHopSubmitted(_peer(2), _message(4));
    expect(
      complete.relayStatus!.status,
      GroupRelayStatus.sentToDestinationTransport,
    );
    expect(complete.relayStatus!.groupId, _group(8));
    expect(complete.deliveryAck, isNull);
  });

  test('ACK-required final hop emits destination-level delivery acknowledgment',
      () {
    final controller = _controller();
    controller.admit(
      _operation(),
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );

    final complete = controller.finalHopAcknowledged(_peer(2), _message(4));
    expect(complete.deliveryAck!.groupId, _group(8));
    expect(complete.deliveryAck!.sourcePeerId, _peer(2));
    expect(complete.relayStatus, isNull);
  });

  test('admission failure ACKs source hop but retains no relay', () {
    final controller = _controller();
    final actions = controller.admit(
      _operation(),
      committedMembers: members,
      destinationReady: false,
      reservationBytes: 10,
    );
    expect(actions.sourceHopGenericAckMessageId, List.filled(8, 9));
    expect(
        actions.relayStatus!.status, GroupRelayStatus.destinationUnavailable);
    expect(controller.relays.admittedRelayCount, 0);
  });

  test('UT-124/COORD-059 queue-full admission ACKs and retains no relay', () {
    final controller = CoordinatorRelayController(
      canonicalGroupId: _group(8),
      coordinatorPeerId: _peer(1),
      relays: CoordinatorRelayTable(
        coordinatorPeerId: _peer(1),
        maxReservedBytesPerDestination: 9,
        maxReservedMessagesPerDestination: 1,
      ),
    );
    final actions = controller.admit(
      _operation(),
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );
    expect(actions.sourceHopGenericAckMessageId, List.filled(8, 9));
    expect(actions.relayStatus!.status, GroupRelayStatus.relayQueueFull);
    expect(actions.relayStatus!.errorCode, LpcErrorCode.sendQueueFull);
    expect(actions.forward, isNull);
    expect(controller.relays.admittedRelayCount, 0);
    expect(controller.relays.reservedBytesFor(_peer(3)), 0);
  });

  test('UT-127 queue-full source hop is ACKed once with no retained retry', () {
    final controller = CoordinatorRelayController(
      canonicalGroupId: _group(8),
      coordinatorPeerId: _peer(1),
      relays: CoordinatorRelayTable(
        coordinatorPeerId: _peer(1),
        maxReservedBytesPerDestination: 1,
        maxReservedMessagesPerDestination: 1,
      ),
    );
    final largeSourceHop = _operation(bytes: List.filled(1024 * 1024, 7));

    final actions = controller.admit(
      largeSourceHop,
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 1024 * 1024,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );
    expect(
        actions.sourceHopGenericAckMessageId, largeSourceHop.pairwiseMessageId);
    expect(actions.relayStatus?.status, GroupRelayStatus.relayQueueFull);
    expect(actions.forward, isNull);
    expect(controller.relays.admittedRelayCount, 0);
    expect(controller.relays.reservedMessagesFor(_peer(3)), 0);
  });

  test('UT-126 admission reserves whole relay before source-hop ACK', () {
    final controller = _controller();
    final actions = controller.admit(
      _operation(),
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );
    // The returned ACK action is valid only after this complete-operation
    // reservation has committed; there is no partial relay state.
    expect(controller.relays.admittedRelayCount, 1);
    expect(controller.relays.reservedBytesFor(_peer(3)), 10);
    expect(controller.relays.reservedMessagesFor(_peer(3)), 1);
    expect(actions.sourceHopGenericAckMessageId, List.filled(8, 9));
    expect(actions.forward, isNotNull);
  });

  test('delivery to the coordinator is committed locally and acknowledged', () {
    final controller = _controller();
    final actions = controller.admit(
      _operation(destination: 1),
      committedMembers: members,
      destinationReady: false,
      reservationBytes: 10,
    );
    expect(actions.deliverLocally, isNotNull);
    expect(actions.deliveryAck, isNotNull);
    expect(actions.forward, isNull);
  });

  test('UT-141/COORD-064 destination removal terminates relays and releases',
      () {
    final controller = _controller();
    controller.admit(
      _operation(),
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );

    final actions = controller.destinationRemoved(_peer(3));
    expect(actions, hasLength(1));
    expect(actions.single.relayStatus!.status,
        GroupRelayStatus.destinationNotInGroup);
    expect(controller.relays.admittedRelayCount, 0);
    expect(controller.relays.reservedBytesFor(_peer(3)), 0);
    expect(controller.destinationResumeSucceeded(_peer(3)), isEmpty);
  });

  test('UT-148 authority loss releases relays and routing ownership', () {
    final controller = _controller();
    controller.admit(
      _operation(),
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );

    controller.coordinatorAuthorityLost();
    expect(controller.relays.admittedRelayCount, 0);
    expect(controller.relays.reservedBytesFor(_peer(3)), 0);
    expect(controller.destinationResumeSucceeded(_peer(3)), isEmpty);
  });

  test('coordinator preserves source/destination relay acceptance order', () {
    final controller = _controller();
    final first = _operation(message: 4);
    final second = _operation(message: 5);
    final firstAdmission = controller.admit(
      first,
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );
    final secondAdmission = controller.admit(
      second,
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );
    expect(firstAdmission.forward!.groupMessageId, first.groupMessageId);
    expect(secondAdmission.forward, isNull);

    final firstComplete = controller.finalHopAcknowledged(
        _peer(2), GroupMessageId(List.filled(16, 4)));
    expect(firstComplete.forward!.groupMessageId, second.groupMessageId);
  });

  test(
      'UT-129/COORD-060 partially submitted ordered final hop resumes from chunk 0',
      () {
    final controller = _controller();
    final operation = _operation(
      mode: DeliveryMode.reliableOrdered,
      bytes: List.filled(16301, 7),
    );
    final initial = controller.admit(
      operation,
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );

    // The first final-hop chunk was submitted before loss, but no terminal
    // final-hop action occurred. RESUME must replay the whole operation.
    expect(
      chunkGroupReliable(
        groupId: initial.forward!.groupId,
        source: initial.forward!.sourcePeerId,
        destination: initial.forward!.destinationPeerId,
        messageId: initial.forward!.groupMessageId,
        mode: initial.forward!.deliveryMode,
        priority: initial.forward!.priority,
        bytes: initial.forward!.bytes,
      ).first.chunkIndex,
      0,
    );

    final retry = controller.destinationResumeSucceeded(_peer(3));
    expect(retry, hasLength(1));
    expect(retry.single.forward!.groupMessageId, operation.groupMessageId);
    expect(retry.single.forward!.pairwiseMessageId, _destinationHopMessageId);
    expect(retry.single.forward!.bytes, operation.bytes);
    expect(controller.relays.reservedBytesFor(_peer(3)), 10);
  });

  test(
      'UT-130 partially submitted ACK-required final hop resumes as complete operation from chunk 0',
      () {
    final controller = _controller();
    final operation = _operation(bytes: List.filled(16301, 8));
    final initial = controller.admit(
      operation,
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );
    final initialChunks = chunkGroupReliable(
      groupId: initial.forward!.groupId,
      source: initial.forward!.sourcePeerId,
      destination: initial.forward!.destinationPeerId,
      messageId: initial.forward!.groupMessageId,
      mode: initial.forward!.deliveryMode,
      priority: initial.forward!.priority,
      bytes: initial.forward!.bytes,
    );
    expect(initialChunks.first.chunkIndex, 0);
    expect(initialChunks, hasLength(2));

    final resumed =
        controller.destinationResumeSucceeded(_peer(3)).single.forward!;
    final resumedChunks = chunkGroupReliable(
      groupId: resumed.groupId,
      source: resumed.sourcePeerId,
      destination: resumed.destinationPeerId,
      messageId: resumed.groupMessageId,
      mode: resumed.deliveryMode,
      priority: resumed.priority,
      bytes: resumed.bytes,
    );
    expect(resumedChunks.first.chunkIndex, 0);
    expect(resumed.pairwiseMessageId, _destinationHopMessageId);
    expect(resumed.groupMessageId, operation.groupMessageId);
    expect(resumed.bytes, operation.bytes);
  });

  test('UT-131/COORD-061 fully submitted ordered final hop is not retried', () {
    final controller = _controller();
    final operation = _operation(mode: DeliveryMode.reliableOrdered);
    controller.admit(
      operation,
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );

    controller.finalHopSubmitted(_peer(2), operation.groupMessageId);
    expect(controller.relays.admittedRelayCount, 0);
    expect(controller.destinationResumeSucceeded(_peer(3)), isEmpty);
  });

  test('UT-132 reconnecting destination retains its original relay reservation',
      () {
    final controller = _controller();
    final operation = _operation(mode: DeliveryMode.reliableOrdered);
    controller.admit(
      operation,
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );

    // Destination RECONNECTING does not remove an admitted, incomplete hop or
    // free capacity for an unrelated operation.
    expect(controller.relays.admittedRelayCount, 1);
    expect(controller.relays.reservedBytesFor(_peer(3)), 10);
    expect(controller.relays.reservedMessagesFor(_peer(3)), 1);
    final retained =
        controller.destinationResumeSucceeded(_peer(3)).single.forward!;
    expect(retained.groupMessageId, operation.groupMessageId);
    expect(retained.pairwiseMessageId, _destinationHopMessageId);
  });

  test('terminal destination reconnect failure releases retained relays', () {
    final controller = _controller();
    controller.admit(
      _operation(),
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );

    final failures = controller.destinationResumeFailed(_peer(3));
    expect(failures, hasLength(1));
    expect(failures.single.relayStatus!.status,
        GroupRelayStatus.destinationUnavailable);
    expect(controller.relays.admittedRelayCount, 0);
    expect(controller.relays.reservedBytesFor(_peer(3)), 0);
  });

  test('UT-133 ordered relay is discarded when destination RESUME fails', () {
    final controller = _controller();
    final operation = _operation(mode: DeliveryMode.reliableOrdered);
    controller.admit(
      operation,
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
      destinationPairwiseMessageId: _destinationHopMessageId,
    );

    final failures = controller.destinationResumeFailed(_peer(3));
    expect(failures.single.relayStatus?.status,
        GroupRelayStatus.destinationUnavailable);
    expect(failures.single.relayStatus?.errorCode,
        LpcErrorCode.destinationUnavailable);
    expect(controller.relays.admittedRelayCount, 0);
    expect(controller.relays.reservedBytesFor(_peer(3)), 0);
  });
}

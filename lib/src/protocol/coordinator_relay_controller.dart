import '../types.dart';
import 'group_relay.dart';
import 'group_reliable.dart';
import 'group_signaling.dart';

/// Declarative coordinator actions. The live PeerConnection integration turns
/// these into generic ACKs, encrypted control frames, application delivery,
/// and final-hop submissions in that order.
class CoordinatorRelayActions {
  const CoordinatorRelayActions({
    this.sourceHopGenericAckMessageId,
    this.deliverLocally,
    this.forward,
    this.deliveryAck,
    this.relayStatus,
    this.localSourceState,
  });

  final List<int>? sourceHopGenericAckMessageId;
  final ReassembledGroupReliable? deliverLocally;
  final ReassembledGroupReliable? forward;
  final GroupDeliveryAck? deliveryAck;
  final GroupRelayStatusPayload? relayStatus;
  final SendState? localSourceState;
}

/// Applies the coordinator-specific signaling consequences of relay admission
/// and final-hop completion (Sections 43.1.3, 43.1.5, and 43.1.6).
///
/// It does not perform I/O. Keeping the outcome declarative prevents a
/// source-hop generic ACK from accidentally being treated as public delivery
/// success before the live transport layer is attached.
class CoordinatorRelayController {
  CoordinatorRelayController({
    required this.canonicalGroupId,
    required this.coordinatorPeerId,
    required this.relays,
  }) : assert(relays.coordinatorPeerId == coordinatorPeerId);

  final GroupId canonicalGroupId;
  final PeerId coordinatorPeerId;
  final CoordinatorRelayTable relays;

  CoordinatorRelayActions admit(
    ReassembledGroupReliable incoming, {
    required Set<PeerId> committedMembers,
    required bool destinationReady,
    required int reservationBytes,
    List<int>? destinationPairwiseMessageId,
  }) {
    if (destinationPairwiseMessageId != null &&
        destinationPairwiseMessageId.length != 8) {
      throw ArgumentError.value(
          destinationPairwiseMessageId, 'destinationPairwiseMessageId');
    }
    final requiresDestinationHopId =
        incoming.destinationPeerId != coordinatorPeerId &&
            committedMembers.contains(incoming.destinationPeerId) &&
            destinationReady;
    if (requiresDestinationHopId && destinationPairwiseMessageId == null) {
      throw ArgumentError.value(
          destinationPairwiseMessageId, 'destinationPairwiseMessageId');
    }
    final operation = incoming.destinationPeerId == coordinatorPeerId
        ? _withCanonicalGroupId(incoming)
        : _withCanonicalGroupId(
            incoming,
            pairwiseMessageId:
                destinationPairwiseMessageId ?? incoming.pairwiseMessageId,
          );
    final admission = relays.admit(
      operation,
      committedMembers: committedMembers,
      destinationReady: destinationReady,
      reservationBytes: reservationBytes,
    );
    final genericAck = incoming.sourcePeerId == coordinatorPeerId
        ? null
        : incoming.pairwiseMessageId;
    return switch (admission.kind) {
      RelayAdmissionKind.forward => CoordinatorRelayActions(
          sourceHopGenericAckMessageId: genericAck,
          forward: admission.forwardImmediately ? admission.operation : null,
        ),
      RelayAdmissionKind.deliverLocally => CoordinatorRelayActions(
          sourceHopGenericAckMessageId: genericAck,
          deliverLocally: admission.operation,
          deliveryAck: incoming.sourcePeerId == coordinatorPeerId
              ? null
              : _deliveryAck(admission.operation!),
          localSourceState: incoming.sourcePeerId == coordinatorPeerId
              ? SendState.remoteAcknowledged
              : null,
        ),
      RelayAdmissionKind.status => _routeFailure(
          operation,
          admission.status!,
          genericAck,
        ),
    };
  }

  /// Called only once all ordered final-hop chunks have reached frame-level
  /// SENT_TO_TRANSPORT. RELIABLE_ACKED waits for [finalHopAcknowledged].
  CoordinatorRelayActions finalHopSubmitted(
      PeerId source, GroupMessageId groupMessageId) {
    final operation = relays.complete(source, groupMessageId);
    if (operation == null) return const CoordinatorRelayActions();
    if (operation.deliveryMode != DeliveryMode.reliableOrdered) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final next = relays.takeNextForward(source, operation.destinationPeerId);
    if (operation.sourcePeerId == coordinatorPeerId) {
      return CoordinatorRelayActions(
          localSourceState: SendState.sentToTransport, forward: next);
    }
    return CoordinatorRelayActions(
      forward: next,
      relayStatus:
          _relayStatus(operation, GroupRelayStatus.sentToDestinationTransport),
    );
  }

  /// Called only after generic ACK for the complete ACK-required final hop.
  CoordinatorRelayActions finalHopAcknowledged(
      PeerId source, GroupMessageId groupMessageId) {
    final operation = relays.complete(source, groupMessageId);
    if (operation == null) return const CoordinatorRelayActions();
    if (operation.deliveryMode != DeliveryMode.reliableAcked) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final next = relays.takeNextForward(source, operation.destinationPeerId);
    if (operation.sourcePeerId == coordinatorPeerId) {
      return CoordinatorRelayActions(
          localSourceState: SendState.remoteAcknowledged, forward: next);
    }
    return CoordinatorRelayActions(
        deliveryAck: _deliveryAck(operation), forward: next);
  }

  /// A terminal destination-hop error becomes the exact authoritative status
  /// for the original source, while releasing the admission reservation.
  CoordinatorRelayActions finalHopFailed(
    PeerId source,
    GroupMessageId groupMessageId,
    GroupRelayStatus status,
  ) {
    if (status == GroupRelayStatus.sentToDestinationTransport) {
      throw ArgumentError.value(status, 'status');
    }
    final operation = relays.complete(source, groupMessageId);
    if (operation == null) return const CoordinatorRelayActions();
    return _routeFailure(operation, status, null,
        forward: relays.takeNextForward(source, operation.destinationPeerId));
  }

  /// Section 43.1.8: after destination-hop RESUME, retained admitted relays
  /// restart as complete operations from chunk 0. The caller retains each
  /// operation's destination-hop MessageId while issuing fresh wire sequences.
  /// Operations that had already reached their terminal final-hop state were
  /// removed by [finalHopSubmitted] or [finalHopAcknowledged] and are absent.
  List<CoordinatorRelayActions> destinationResumeSucceeded(
          PeerId destination) =>
      List.unmodifiable(relays
          .forwardableForDestination(destination)
          .map((operation) => CoordinatorRelayActions(forward: operation)));

  /// Section 43.1.8: an ultimate destination reconnect failure terminates all
  /// still-admitted relays to that member and releases every reservation.
  List<CoordinatorRelayActions> destinationResumeFailed(PeerId destination) =>
      List.unmodifiable(relays.destinationUnavailable(destination).map(
          (operation) => _routeFailure(
              operation, GroupRelayStatus.destinationUnavailable, null)));

  /// Section 43.1.12: once removal is committed, every unfinished relay to
  /// that member stops immediately. Remote sources receive the exact terminal
  /// status when their route exists; local coordinator sources fail locally.
  List<CoordinatorRelayActions> destinationRemoved(PeerId destination) =>
      List.unmodifiable(relays.destinationRemoved(destination).map(
          (operation) => _routeFailure(
              operation, GroupRelayStatus.destinationNotInGroup, null)));

  /// Section 43.1.10: a former coordinator releases ownership but MUST NOT
  /// create new route signaling after it loses authority.
  void coordinatorAuthorityLost() {
    relays.coordinatorAuthorityLost();
  }

  CoordinatorRelayActions _routeFailure(ReassembledGroupReliable operation,
          GroupRelayStatus status, List<int>? genericAck,
          {ReassembledGroupReliable? forward}) =>
      operation.sourcePeerId == coordinatorPeerId
          ? CoordinatorRelayActions(
              sourceHopGenericAckMessageId: genericAck,
              localSourceState: SendState.failed,
              forward: forward,
            )
          : CoordinatorRelayActions(
              sourceHopGenericAckMessageId: genericAck,
              relayStatus: _relayStatus(operation, status),
              forward: forward,
            );

  GroupDeliveryAck _deliveryAck(ReassembledGroupReliable operation) =>
      GroupDeliveryAck(
        groupId: canonicalGroupId,
        sourcePeerId: operation.sourcePeerId,
        destinationPeerId: operation.destinationPeerId,
        groupMessageId: operation.groupMessageId,
      );

  GroupRelayStatusPayload _relayStatus(
    ReassembledGroupReliable operation,
    GroupRelayStatus status,
  ) =>
      GroupRelayStatusPayload(
        groupId: canonicalGroupId,
        sourcePeerId: operation.sourcePeerId,
        destinationPeerId: operation.destinationPeerId,
        groupMessageId: operation.groupMessageId,
        status: status,
      );

  ReassembledGroupReliable _withCanonicalGroupId(
    ReassembledGroupReliable operation, {
    List<int>? pairwiseMessageId,
  }) {
    if (operation.groupId == canonicalGroupId && pairwiseMessageId == null) {
      return operation;
    }
    return ReassembledGroupReliable(
      pairwiseMessageId: pairwiseMessageId ?? operation.pairwiseMessageId,
      groupId: canonicalGroupId,
      sourcePeerId: operation.sourcePeerId,
      destinationPeerId: operation.destinationPeerId,
      groupMessageId: operation.groupMessageId,
      deliveryMode: operation.deliveryMode,
      priority: operation.priority,
      bytes: operation.bytes,
    );
  }
}

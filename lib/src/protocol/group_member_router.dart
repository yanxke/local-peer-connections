import '../types.dart';
import 'cancellation.dart';
import 'group_routing_send.dart';
import 'group_routing_validation.dart';
import 'group_signaling.dart';
import 'stale_coordinator.dart';

enum GroupRouteSignalDisposition { applied, cancelled, stale, unknown }

/// Result after a fully authenticated ACK-required route signal. Callers
/// generic-ACK every result except an exception; [cancelled] means its
/// semantic result must be discarded while the public handle stays cancelled.
class GroupRouteSignalResult {
  const GroupRouteSignalResult(this.disposition, {this.state});
  final GroupRouteSignalDisposition disposition;
  final SendState? state;

  /// `GROUP_DELIVERY_ACK` and `GROUP_RELAY_STATUS` are ACK-required. A stale
  /// result is therefore ACKed normally even though it has no public effect.
  bool get requiresGenericAck =>
      disposition != GroupRouteSignalDisposition.unknown;
}

/// Terminal source-hop result after Section 23.5 exhausts generic ACK
/// retries. This failure is local to the group send and does not imply a
/// reliable PeerConnection failure.
class GroupSourceHopTimeoutResult {
  const GroupSourceHopTimeoutResult(this.state)
      : errorCode = LpcErrorCode.ackTimeout;
  final SendState state;
  final LpcErrorCode errorCode;
}

/// Non-coordinator source-side routing core. It owns only public routed-send
/// state; generic source-hop ACKs are intentionally ignored because they do
/// not prove final-hop delivery.
class GroupMemberRouter {
  GroupMemberRouter({
    required this.validator,
    required this.sends,
    CancellationTombstoneTable? tombstones,
  }) : tombstones = tombstones ?? CancellationTombstoneTable() {
    if (validator.localPeerId != sends.localPeerId) {
      throw ArgumentError(
          'validator and routed-send table disagree on local peer');
    }
  }

  final GroupRoutingValidator validator;
  final RoutedSendTable sends;
  final CancellationTombstoneTable tombstones;

  SendState begin(RoutedGroupOperation operation) {
    // Every accepted operation may later be cancelled after source-hop bytes
    // were accepted. Reserve bounded tombstone capacity at admission rather
    // than silently evicting a required late-signal correlation record.
    if (sends.length + tombstones.length >= tombstones.capacity) {
      throw const LpcException(LpcErrorCode.resourceExhausted);
    }
    validator.validateLocalSourceOperation(
      groupId: operation.groupId,
      source: operation.sourcePeerId,
      destination: operation.destinationPeerId,
    );
    return sends.register(operation);
  }

  /// Applies only current-coordinator signaling. A valid stale former-
  /// coordinator signal is classified and discarded before reaching here.
  SendState? receiveDeliveryAck(
    GroupDeliveryAck ack, {
    required PeerId authenticatedSendingPeerId,
  }) {
    return receiveDeliveryAckResult(
      ack,
      authenticatedSendingPeerId: authenticatedSendingPeerId,
    ).state;
  }

  GroupRouteSignalResult receiveDeliveryAckResult(
    GroupDeliveryAck ack, {
    required PeerId authenticatedSendingPeerId,
  }) {
    validator.validateCoordinatorRouteSignal(authenticatedSendingPeerId);
    final state = sends.onDeliveryAck(ack);
    if (state != null) {
      return GroupRouteSignalResult(GroupRouteSignalDisposition.applied,
          state: state);
    }
    final tombstone = tombstones.lookup(
      messageId: ack.groupMessageId,
      destination: ack.destinationPeerId,
    );
    if (tombstone == null) {
      return const GroupRouteSignalResult(GroupRouteSignalDisposition.unknown);
    }
    if (tombstone.deliveryMode != DeliveryMode.reliableAcked) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    _validateTombstoneSourceAndGroup(
      groupId: ack.groupId,
      source: ack.sourcePeerId,
    );
    return const GroupRouteSignalResult(GroupRouteSignalDisposition.cancelled);
  }

  SendState? receiveRelayStatus(
    GroupRelayStatusPayload status, {
    required PeerId authenticatedSendingPeerId,
  }) {
    return receiveRelayStatusResult(
      status,
      authenticatedSendingPeerId: authenticatedSendingPeerId,
    ).state;
  }

  GroupRouteSignalResult receiveRelayStatusResult(
    GroupRelayStatusPayload status, {
    required PeerId authenticatedSendingPeerId,
  }) {
    validator.validateCoordinatorRouteSignal(authenticatedSendingPeerId);
    final state = sends.onRelayStatus(status);
    if (state != null) {
      return GroupRouteSignalResult(GroupRouteSignalDisposition.applied,
          state: state);
    }
    final tombstone = tombstones.lookup(
      messageId: status.groupMessageId,
      destination: status.destinationPeerId,
    );
    if (tombstone == null) {
      return const GroupRouteSignalResult(GroupRouteSignalDisposition.unknown);
    }
    if (status.status == GroupRelayStatus.sentToDestinationTransport &&
        tombstone.deliveryMode != DeliveryMode.reliableOrdered) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    _validateTombstoneSourceAndGroup(
      groupId: status.groupId,
      source: status.sourcePeerId,
    );
    return const GroupRouteSignalResult(GroupRouteSignalDisposition.cancelled);
  }

  /// Applies the narrow Section 43.1.11 exception after the caller has
  /// established the historical-authority facts from authenticated transport
  /// state. A qualifying former-coordinator signal is ACKed and discarded;
  /// it must never reach [sends] or alter a cancellation tombstone.
  GroupRouteSignalResult receiveStaleDeliveryAck(
    GroupDeliveryAck ack, {
    required StaleCoordinatorClassifier classifier,
    required PeerId authenticatedSendingPeerId,
    required List<int> sessionId,
    required bool createdBeforeAuthorityLoss,
    required bool historicalRouteIsValid,
    required bool cryptographicallyAndSequenceValid,
    required bool genericAckRequiredValid,
  }) {
    _classifyStaleSignal(
      classifier: classifier,
      authenticatedSendingPeerId: authenticatedSendingPeerId,
      sessionId: sessionId,
      createdBeforeAuthorityLoss: createdBeforeAuthorityLoss,
      historicalRouteIsValid: historicalRouteIsValid,
      cryptographicallyAndSequenceValid: cryptographicallyAndSequenceValid,
      genericAckRequiredValid: genericAckRequiredValid,
      source: ack.sourcePeerId,
    );
    return const GroupRouteSignalResult(GroupRouteSignalDisposition.stale);
  }

  GroupRouteSignalResult receiveStaleRelayStatus(
    GroupRelayStatusPayload status, {
    required StaleCoordinatorClassifier classifier,
    required PeerId authenticatedSendingPeerId,
    required List<int> sessionId,
    required bool createdBeforeAuthorityLoss,
    required bool historicalRouteIsValid,
    required bool cryptographicallyAndSequenceValid,
    required bool genericAckRequiredValid,
  }) {
    _classifyStaleSignal(
      classifier: classifier,
      authenticatedSendingPeerId: authenticatedSendingPeerId,
      sessionId: sessionId,
      createdBeforeAuthorityLoss: createdBeforeAuthorityLoss,
      historicalRouteIsValid: historicalRouteIsValid,
      cryptographicallyAndSequenceValid: cryptographicallyAndSequenceValid,
      genericAckRequiredValid: genericAckRequiredValid,
      source: status.sourcePeerId,
    );
    return const GroupRouteSignalResult(GroupRouteSignalDisposition.stale);
  }

  /// Returns the unchanged end-destination operations for whole-operation
  /// retransmission through the newly READY coordinator route.
  List<RoutedGroupOperation> coordinatorRouteLost() =>
      sends.operationsToReroute();

  /// Applies the final source-to-coordinator ACK timeout for a
  /// RELIABLE_ACKED routed operation. The returned terminal result lets the
  /// public SendHandle complete with the required `ACK_TIMEOUT` error.
  GroupSourceHopTimeoutResult? sourceHopAckTimedOut(
      GroupMessageId groupMessageId) {
    final state = sends.onSourceHopAckTimeout(groupMessageId);
    return state == null ? null : GroupSourceHopTimeoutResult(state);
  }

  RoutedGroupOperation? cancel(
    GroupMessageId groupMessageId, {
    Iterable<List<int>> signalingSessionIds = const [],
  }) {
    final operation = sends.cancel(groupMessageId);
    if (operation == null) return null;
    tombstones.add(
      CancelledGroupSendTombstone(
        groupMessageId: operation.groupMessageId,
        destinationPeerId: operation.destinationPeerId,
        deliveryMode: operation.deliveryMode,
      ),
      signalingSessionIds: signalingSessionIds,
    );
    return operation;
  }

  void signalingSessionTerminated(List<int> sessionId) =>
      tombstones.sessionTerminated(sessionId);

  void close() => tombstones.clear();

  void _validateTombstoneSourceAndGroup({
    required GroupId groupId,
    required PeerId source,
  }) {
    if (groupId != validator.canonicalGroupId ||
        source != validator.localPeerId) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
  }

  void _classifyStaleSignal({
    required StaleCoordinatorClassifier classifier,
    required PeerId authenticatedSendingPeerId,
    required List<int> sessionId,
    required bool createdBeforeAuthorityLoss,
    required bool historicalRouteIsValid,
    required bool cryptographicallyAndSequenceValid,
    required bool genericAckRequiredValid,
    required PeerId source,
  }) {
    // The route validity fact is supplied by the committed historical routing
    // view; local correlation remains mandatory for this source-side router.
    if (source != validator.localPeerId) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final disposition = classifier.classifySignaling(
      authenticatedSender: authenticatedSendingPeerId,
      sessionId: sessionId,
      createdBeforeAuthorityLoss: createdBeforeAuthorityLoss,
      historicalRouteIsValid: historicalRouteIsValid,
      cryptographicallyAndSequenceValid: cryptographicallyAndSequenceValid,
      genericAckRequiredValid: genericAckRequiredValid,
    );
    if (disposition != StaleCoordinatorDisposition.genericAckAndDiscard) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
  }
}

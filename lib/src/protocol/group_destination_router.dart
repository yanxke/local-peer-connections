import '../types.dart';
import 'group_dedup.dart';
import 'group_realtime.dart';
import 'group_reliable.dart';
import 'group_routing_validation.dart';
import 'stale_coordinator.dart';

enum ReliableDestinationDisposition { deliver, duplicate }

class ReliableDestinationResult {
  const ReliableDestinationResult(this.disposition, this.operation);
  final ReliableDestinationDisposition disposition;
  final ReassembledGroupReliable operation;

  /// A complete ACK-required destination hop is generic-ACKed whether this is
  /// a first delivery or a completed GroupMessageId duplicate.
  bool get requiresGenericAck =>
      operation.deliveryMode == DeliveryMode.reliableAcked;
}

/// Destination-side group routing core. Current-coordinator traffic is
/// delivered normally; narrow proven former-coordinator migration races are
/// exposed through the explicit stale methods below.
class GroupDestinationRouter {
  GroupDestinationRouter({
    required this.validator,
    CompletedGroupMessageDedup? reliableDedup,
  }) : _reliableDedup = reliableDedup ?? CompletedGroupMessageDedup();

  final GroupRoutingValidator validator;
  final CompletedGroupMessageDedup _reliableDedup;
  final Map<String, int> _realtimeLastSequence = {};

  ReliableDestinationResult receiveReliable(
    ReassembledGroupReliable operation, {
    required PeerId authenticatedSendingPeerId,
  }) {
    validator.validateCoordinatorToDestination(
      operation,
      authenticatedSendingPeerId: authenticatedSendingPeerId,
    );
    final firstDelivery = _reliableDedup.accept(
      source: operation.sourcePeerId,
      messageId: operation.groupMessageId,
      destination: operation.destinationPeerId,
      mode: operation.deliveryMode,
      priority: operation.priority,
      bytes: operation.bytes,
    );
    return ReliableDestinationResult(
      firstDelivery
          ? ReliableDestinationDisposition.deliver
          : ReliableDestinationDisposition.duplicate,
      operation,
    );
  }

  /// Returns true only for a newly accepted destination realtime state. The
  /// ordering domain is `(source_peer_id, channel_id)`, not merely channel.
  bool receiveRealtime(
    GroupRealtimeDatagram datagram, {
    required PeerId authenticatedSendingPeerId,
  }) {
    validator.validateRealtimeCoordinatorToDestination(
      datagram,
      authenticatedSendingPeerId: authenticatedSendingPeerId,
    );
    final key = '${datagram.sourcePeerId}:${datagram.channelId}';
    final previous = _realtimeLastSequence[key];
    if (previous != null && !_newer(datagram.sequence, previous)) return false;
    _realtimeLastSequence[key] = datagram.sequence;
    return true;
  }

  /// Section 43.1.11 handling after coordinator migration. The caller has
  /// already discarded partial stale reassembly and supplies only a complete
  /// authenticated operation. No dedup or application-delivery state changes.
  StaleCoordinatorDisposition receiveStaleReliable(
    ReassembledGroupReliable operation, {
    required StaleCoordinatorClassifier classifier,
    required PeerId authenticatedSendingPeerId,
    required List<int> sessionId,
    required bool wasInFlightBeforeAuthorityLoss,
    required bool cryptographicallyAndFramingValid,
  }) {
    if (operation.destinationPeerId != validator.localPeerId) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final disposition = classifier.classifyReliable(
      authenticatedSender: authenticatedSendingPeerId,
      sessionId: sessionId,
      wasInFlightBeforeAuthorityLoss: wasInFlightBeforeAuthorityLoss,
      cryptographicallyAndFramingValid: cryptographicallyAndFramingValid,
      ackRequired: operation.deliveryMode == DeliveryMode.reliableAcked,
      completeOperation: true,
    );
    if (disposition == StaleCoordinatorDisposition.reject) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    return disposition;
  }

  /// A valid stale realtime datagram is discarded before it can mutate the
  /// destination `(source, channel)` latest-state filter.
  StaleCoordinatorDisposition receiveStaleRealtime(
    GroupRealtimeDatagram datagram, {
    required StaleCoordinatorClassifier classifier,
    required PeerId authenticatedSendingPeerId,
    required List<int> sessionId,
    required bool wasSubmittedBeforeAuthorityLoss,
    required bool cryptographicallyAndFramingValid,
  }) {
    if (datagram.destinationPeerId != validator.localPeerId) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final disposition = classifier.classifyRealtime(
      authenticatedSender: authenticatedSendingPeerId,
      sessionId: sessionId,
      wasSubmittedBeforeAuthorityLoss: wasSubmittedBeforeAuthorityLoss,
      cryptographicallyAndFramingValid: cryptographicallyAndFramingValid,
    );
    if (disposition == StaleCoordinatorDisposition.reject) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    return disposition;
  }

  bool _newer(int candidate, int previous) {
    final difference = (candidate - previous) & 0xffffffff;
    return difference != 0 && difference < 0x80000000;
  }
}

import 'dart:typed_data';

import '../types.dart';
import 'group_signaling.dart';

/// Source-owned end-destination operation identity. Pairwise MessageIds are
/// deliberately excluded: each retry through a coordinator uses a fresh hop
/// operation while retaining this [groupMessageId] (Section 43.1.7).
class RoutedGroupOperation {
  RoutedGroupOperation({
    required this.groupId,
    required this.sourcePeerId,
    required this.destinationPeerId,
    required this.groupMessageId,
    required this.deliveryMode,
    required this.priority,
    required List<int> bytes,
  }) : bytes = Uint8List.fromList(bytes) {
    if (deliveryMode == DeliveryMode.realtimeLatest || bytes.length > 1048576) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
  }

  final GroupId groupId;
  final PeerId sourcePeerId, destinationPeerId;
  final GroupMessageId groupMessageId;
  final DeliveryMode deliveryMode;
  final SendPriority priority;
  final Uint8List bytes;
}

/// Bounded source-side state for routed reliable sends.
///
/// The transport owner calls the signal methods only after authenticating the
/// hop and checking its sender against the current coordinator. A generic ACK
/// for the source hop intentionally has no method here: it never changes the
/// public end-destination result (Section 43.1.3).
class RoutedSendTable {
  RoutedSendTable({required this.localPeerId, this.capacity = 1024})
      : assert(capacity > 0);

  final PeerId localPeerId;
  final int capacity;
  final Map<GroupMessageId, _RoutedSend> _sends = {};

  int get length => _sends.length;

  SendState register(RoutedGroupOperation operation) {
    if (operation.sourcePeerId != localPeerId ||
        operation.destinationPeerId == localPeerId) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    if (_sends.containsKey(operation.groupMessageId)) {
      throw const LpcException(LpcErrorCode.messageIdCollision);
    }
    if (_sends.length >= capacity) {
      throw const LpcException(LpcErrorCode.resourceExhausted);
    }
    _sends[operation.groupMessageId] = _RoutedSend(operation);
    return SendState.transmitting;
  }

  SendState? stateFor(GroupMessageId groupMessageId) =>
      _sends[groupMessageId]?.state;

  /// A valid `GROUP_RELAY_STATUS` is authoritative for ordered final-hop
  /// submission and for terminal route failure. It never remotely acknowledges
  /// a RELIABLE_ACKED operation.
  SendState? onRelayStatus(GroupRelayStatusPayload payload) {
    final send = _matching(payload.groupId, payload.sourcePeerId,
        payload.destinationPeerId, payload.groupMessageId);
    if (send == null) return null;
    if (payload.status == GroupRelayStatus.sentToDestinationTransport) {
      if (send.operation.deliveryMode != DeliveryMode.reliableOrdered) {
        throw const LpcException(LpcErrorCode.protocolMismatch);
      }
      send.state = SendState.sentToTransport;
      _sends.remove(payload.groupMessageId);
      return send.state;
    }
    send.state = SendState.failed;
    _sends.remove(payload.groupMessageId);
    return send.state;
  }

  /// A valid `GROUP_DELIVERY_ACK` is the only remote-success proof for
  /// RELIABLE_ACKED (Section 43.1.5).
  SendState? onDeliveryAck(GroupDeliveryAck payload) {
    final send = _matching(payload.groupId, payload.sourcePeerId,
        payload.destinationPeerId, payload.groupMessageId);
    if (send == null) return null;
    if (send.operation.deliveryMode != DeliveryMode.reliableAcked) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    send.state = SendState.remoteAcknowledged;
    _sends.remove(payload.groupMessageId);
    return send.state;
  }

  /// Section 23.5: a final ACK timeout for the source-to-coordinator
  /// RELIABLE_ACKED hop terminates the end-destination operation. It is not a
  /// coordinator migration/reroute candidate.
  SendState? onSourceHopAckTimeout(GroupMessageId groupMessageId) {
    final send = _sends[groupMessageId];
    if (send == null) return null;
    if (send.operation.deliveryMode != DeliveryMode.reliableAcked) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    send.state = SendState.failed;
    _sends.remove(groupMessageId);
    return send.state;
  }

  /// Retains only nonterminal operations for retry after a coordinator route
  /// loss or migration. The caller re-encodes all chunks from chunk zero using
  /// new physical-hop MessageIds.
  List<RoutedGroupOperation> operationsToReroute() => List.unmodifiable(
      _sends.values.map((send) => send.operation).toList(growable: false));

  RoutedGroupOperation? cancel(GroupMessageId groupMessageId) {
    final send = _sends.remove(groupMessageId);
    if (send == null) return null;
    send.state = SendState.cancelled;
    return send.operation;
  }

  _RoutedSend? _matching(
    GroupId groupId,
    PeerId source,
    PeerId destination,
    GroupMessageId groupMessageId,
  ) {
    final send = _sends[groupMessageId];
    if (send == null) return null;
    final operation = send.operation;
    if (operation.groupId != groupId ||
        operation.sourcePeerId != source ||
        operation.destinationPeerId != destination) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    return send;
  }
}

class _RoutedSend {
  _RoutedSend(this.operation);
  final RoutedGroupOperation operation;
  SendState state = SendState.transmitting;
}

import '../types.dart';
import 'frame.dart';
import 'group_message_id.dart';

/// Section 23.5 committed-membership synchronization state. This remains
/// distinct from a peer's cryptographic transport state.
enum GroupSyncState { synchronized, unsynchronized }

/// Exact owner action required after a final ACK timeout for the covered
/// ACK-required control operation.
sealed class ControlAckTimeoutRecovery {
  const ControlAckTimeoutRecovery(this.peerId);
  final PeerId peerId;
}

/// Close the group connection and re-send current membership after normal
/// reconnect/RESUME. The peer is not eligible for membership-dependent work
/// until it ACKs that current snapshot.
class MembershipSnapshotTimeoutRecovery extends ControlAckTimeoutRecovery {
  const MembershipSnapshotTimeoutRecovery(super.peerId);
  LpcErrorCode get closeError => LpcErrorCode.groupStateSyncFailed;
  bool get requiresReconnectAndResync => true;
}

/// Preserve the committed merge while the target reboots from current group
/// information; a timeout never rolls the merge back.
class GroupMergeTimeoutRecovery extends ControlAckTimeoutRecovery {
  const GroupMergeTimeoutRecovery(super.peerId);
  LpcErrorCode get closeError => LpcErrorCode.groupStateSyncFailed;
  bool get requiresRebootstrap => true;
}

/// Report a failed replication only. It does not alter membership, term, or
/// the target connection.
class CheckpointReplicationTimeoutRecovery extends ControlAckTimeoutRecovery {
  const CheckpointReplicationTimeoutRecovery(
      super.peerId, this.checkpointSequence);
  final int checkpointSequence;
  bool get reportsReplicationFailure => true;
}

/// A delivery-acknowledgement or relay-status ACK was lost on the
/// coordinator-to-source link. The destination-side result is already
/// committed, so recovery is deliberately link-scoped: report the route
/// signaling failure and reconnect the source link. The source's retained
/// nonterminal GroupMessageId then follows ordinary whole-operation reroute.
class RouteSignalingTimeoutRecovery extends ControlAckTimeoutRecovery {
  const RouteSignalingTimeoutRecovery(
    super.peerId,
    this.groupMessageId,
    this.frameType,
  );

  final GroupMessageId groupMessageId;
  final FrameType frameType;

  /// The owning GroupSession emits this GroupError before closing the link.
  LpcErrorCode get groupErrorCode => LpcErrorCode.ackTimeout;
  bool get requiresSourceLinkReconnect => true;
}

/// Maps final control ACK timeouts to the frozen Section 23.5 recovery rule.
/// The GroupSession/connection owner performs the returned action.
class GroupControlTimeoutRecovery {
  final Map<PeerId, GroupSyncState> _sync = {};

  GroupSyncState syncState(PeerId peerId) =>
      _sync[peerId] ?? GroupSyncState.synchronized;

  ControlAckTimeoutRecovery onFinalAckTimeout({
    required FrameType type,
    required PeerId peerId,
    int? checkpointSequence,
    GroupMessageId? groupMessageId,
  }) {
    switch (type) {
      case FrameType.membershipSnapshot:
        _sync[peerId] = GroupSyncState.unsynchronized;
        return MembershipSnapshotTimeoutRecovery(peerId);
      case FrameType.groupMerge:
        _sync[peerId] = GroupSyncState.unsynchronized;
        return GroupMergeTimeoutRecovery(peerId);
      case FrameType.coordinatorCheckpoint:
        if (checkpointSequence == null || checkpointSequence < 1) {
          throw ArgumentError.value(checkpointSequence, 'checkpointSequence');
        }
        return CheckpointReplicationTimeoutRecovery(peerId, checkpointSequence);
      case FrameType.groupDeliveryAck:
      case FrameType.groupRelayStatus:
        if (groupMessageId == null) {
          throw ArgumentError.value(
              groupMessageId, 'groupMessageId', 'required for route signaling');
        }
        return RouteSignalingTimeoutRecovery(peerId, groupMessageId, type);
      default:
        throw ArgumentError.value(type, 'type', 'not a covered control frame');
    }
  }
}

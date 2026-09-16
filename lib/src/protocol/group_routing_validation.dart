import '../types.dart';
import 'group_realtime.dart';
import 'group_reliable.dart';

/// Immutable committed-membership routing view used after pairwise
/// authentication and before relay/reassembly state is mutated.
///
/// Stale former-coordinator traffic is intentionally not accepted here. The
/// Section 43.1.11 classifier must handle that narrow historical exception
/// before calling [validateCoordinatorToDestination].
class GroupRoutingValidator {
  GroupRoutingValidator({
    required this.canonicalGroupId,
    required this.localPeerId,
    required this.currentCoordinatorPeerId,
    required Set<PeerId> committedMembers,
    Iterable<GroupId> activeHistoricalAliases = const [],
  })  : committedMembers = Set.unmodifiable(committedMembers),
        activeHistoricalAliases = Set.unmodifiable(activeHistoricalAliases);

  final GroupId canonicalGroupId;
  final PeerId localPeerId, currentCoordinatorPeerId;
  final Set<PeerId> committedMembers;
  final Set<GroupId> activeHistoricalAliases;

  /// Validates a newly originated local operation. New sends use the current
  /// canonical GroupId; historical aliases are accepted only for already
  /// received source hops during merge transition.
  void validateLocalSourceOperation({
    required GroupId groupId,
    required PeerId source,
    required PeerId destination,
  }) {
    if (source != localPeerId ||
        groupId != canonicalGroupId ||
        !committedMembers.contains(source) ||
        !committedMembers.contains(destination) ||
        destination == source) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
  }

  void validateCoordinatorRouteSignal(PeerId authenticatedSendingPeerId) {
    if (authenticatedSendingPeerId != currentCoordinatorPeerId) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
  }

  /// Validates an authenticated member-to-coordinator reliable hop and
  /// returns the equivalent operation normalized for the destination hop.
  ReassembledGroupReliable validateMemberToCoordinator(
    ReassembledGroupReliable operation, {
    required PeerId authenticatedSendingPeerId,
  }) {
    _validateMemberToCoordinator(
      source: operation.sourcePeerId,
      destination: operation.destinationPeerId,
      groupId: operation.groupId,
      authenticatedSendingPeerId: authenticatedSendingPeerId,
    );
    return operation.groupId == canonicalGroupId
        ? operation
        : ReassembledGroupReliable(
            pairwiseMessageId: operation.pairwiseMessageId,
            groupId: canonicalGroupId,
            sourcePeerId: operation.sourcePeerId,
            destinationPeerId: operation.destinationPeerId,
            groupMessageId: operation.groupMessageId,
            deliveryMode: operation.deliveryMode,
            priority: operation.priority,
            bytes: operation.bytes,
          );
  }

  /// Validates a current-coordinator reliable destination hop.
  void validateCoordinatorToDestination(
    ReassembledGroupReliable operation, {
    required PeerId authenticatedSendingPeerId,
  }) {
    _validateCoordinatorToDestination(
      source: operation.sourcePeerId,
      destination: operation.destinationPeerId,
      groupId: operation.groupId,
      authenticatedSendingPeerId: authenticatedSendingPeerId,
    );
  }

  /// Validates and normalizes a member-to-coordinator realtime datagram.
  GroupRealtimeDatagram validateRealtimeMemberToCoordinator(
    GroupRealtimeDatagram datagram, {
    required PeerId authenticatedSendingPeerId,
  }) {
    _validateMemberToCoordinator(
      source: datagram.sourcePeerId,
      destination: datagram.destinationPeerId,
      groupId: datagram.groupId,
      authenticatedSendingPeerId: authenticatedSendingPeerId,
    );
    if (datagram.groupId == canonicalGroupId) return datagram;
    return GroupRealtimeDatagram(
      groupId: canonicalGroupId,
      sourcePeerId: datagram.sourcePeerId,
      destinationPeerId: datagram.destinationPeerId,
      channelId: datagram.channelId,
      sequence: datagram.sequence,
      senderTick: datagram.senderTick,
      bytes: datagram.bytes,
    );
  }

  /// Validates a current-coordinator realtime destination hop.
  void validateRealtimeCoordinatorToDestination(
    GroupRealtimeDatagram datagram, {
    required PeerId authenticatedSendingPeerId,
  }) {
    _validateCoordinatorToDestination(
      source: datagram.sourcePeerId,
      destination: datagram.destinationPeerId,
      groupId: datagram.groupId,
      authenticatedSendingPeerId: authenticatedSendingPeerId,
    );
  }

  void _validateMemberToCoordinator({
    required PeerId source,
    required PeerId destination,
    required GroupId groupId,
    required PeerId authenticatedSendingPeerId,
  }) {
    if (source != authenticatedSendingPeerId ||
        !committedMembers.contains(source) ||
        !committedMembers.contains(destination) ||
        destination == source ||
        (groupId != canonicalGroupId &&
            !activeHistoricalAliases.contains(groupId))) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
  }

  void _validateCoordinatorToDestination({
    required PeerId source,
    required PeerId destination,
    required GroupId groupId,
    required PeerId authenticatedSendingPeerId,
  }) {
    if (authenticatedSendingPeerId != currentCoordinatorPeerId ||
        !committedMembers.contains(source) ||
        destination != localPeerId ||
        destination == source ||
        groupId != canonicalGroupId) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
  }
}

import 'dart:typed_data';

import '../types.dart';
import 'election.dart';

/// Section 31.9 GROUP_LEAVE payload reason codes.
enum GroupLeaveReason { applicationLeave, sessionClosing, kicked }

/// Exact 44-byte GROUP_LEAVE plaintext. The enclosing LPC frame owns the
/// mandatory ACK_REQUIRED header bit and hop-local MessageId.
class GroupLeavePayload {
  const GroupLeavePayload({
    required this.groupId,
    required this.coordinatorTerm,
    required this.leavingPeerId,
    required this.reason,
  });

  final GroupId groupId;
  final int coordinatorTerm;
  final PeerId leavingPeerId;
  final GroupLeaveReason reason;

  Uint8List encode() {
    if (coordinatorTerm < 0) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final output = ByteData(44);
    output.buffer.asUint8List().setRange(0, 16, groupId.bytes);
    output.setUint64(16, coordinatorTerm);
    output.buffer.asUint8List().setRange(24, 40, leavingPeerId.bytes);
    output.setUint8(40, reason.index + 1);
    return output.buffer.asUint8List();
  }

  static GroupLeavePayload decode(List<int> input) {
    if (input.length != 44) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final bytes = Uint8List.fromList(input);
    final data = ByteData.sublistView(bytes);
    final reason = data.getUint8(40);
    if (reason < 1 ||
        reason > GroupLeaveReason.values.length ||
        bytes.sublist(41, 44).any((value) => value != 0)) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    return GroupLeavePayload(
      groupId: GroupId(bytes.sublist(0, 16)),
      coordinatorTerm: data.getUint64(16),
      leavingPeerId: PeerId(bytes.sublist(24, 40)),
      reason: GroupLeaveReason.values[reason - 1],
    );
  }
}

/// Committed-membership consequence of an authenticated GROUP_LEAVE. The
/// connection owner sends the ACK-required replacement MEMBERSHIP_SNAPSHOT
/// from [members] while retaining [coordinatorTerm] unchanged.
class GroupLeaveCommit {
  const GroupLeaveCommit({
    required this.members,
    required this.coordinatorTerm,
  });

  final List<GroupMember> members;
  final int coordinatorTerm;
}

/// Section 31.9 authorization and membership mutation boundary. It accepts
/// only complete authenticated GROUP_LEAVE payloads; timers, wire ACKs, and
/// physical connection closure remain owned by the caller.
class GroupLeaveMembershipController {
  GroupLeaveMembershipController({
    required this.groupId,
    required this.coordinatorTerm,
    required this.coordinatorPeerId,
    required Iterable<GroupMember> committedMembers,
  }) : _members = {
          for (final member in committedMembers) member.peerId: member
        };

  final GroupId groupId;
  final int coordinatorTerm;
  final PeerId coordinatorPeerId;
  final Map<PeerId, GroupMember> _members;

  List<GroupMember> get members => List.unmodifiable(_members.values.toList()
    ..sort((a, b) => _compare(a.peerId.bytes, b.peerId.bytes)));

  GroupLeaveCommit accept(
    GroupLeavePayload payload, {
    required PeerId authenticatedSender,
  }) {
    if (payload.groupId != groupId ||
        payload.coordinatorTerm != coordinatorTerm) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final leaving = payload.leavingPeerId;
    if (!_members.containsKey(leaving)) {
      throw const LpcException(LpcErrorCode.destinationNotInGroup);
    }
    if (payload.reason == GroupLeaveReason.kicked) {
      if (authenticatedSender != coordinatorPeerId ||
          leaving == coordinatorPeerId) {
        throw const LpcException(LpcErrorCode.authenticationFailed);
      }
    } else if (authenticatedSender != leaving ||
        authenticatedSender == coordinatorPeerId) {
      throw const LpcException(LpcErrorCode.authenticationFailed);
    }
    _members.remove(leaving);
    return GroupLeaveCommit(
      members: members,
      coordinatorTerm: coordinatorTerm,
    );
  }

  /// Section 31.9.5 terminal removal after the reconnect window expires.
  /// The caller invokes this only after the peer reached terminal
  /// DISCONNECTED; a reconnecting member remains committed.
  GroupLeaveCommit removeAbruptNonCoordinator(PeerId peerId) {
    if (peerId == coordinatorPeerId || !_members.containsKey(peerId)) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    _members.remove(peerId);
    return GroupLeaveCommit(
      members: members,
      coordinatorTerm: coordinatorTerm,
    );
  }

  /// Returns the membership for the replacement coordinator's first snapshot
  /// after a valid coordinator resignation. The replacement election owns the
  /// incremented term; this controller only removes the old coordinator.
  GroupLeaveCommit removeResignedCoordinator(PeerId peerId) {
    if (peerId != coordinatorPeerId || !_members.containsKey(peerId)) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    _members.remove(peerId);
    return GroupLeaveCommit(
      members: members,
      coordinatorTerm: coordinatorTerm,
    );
  }
}

/// Section 31.9.3 coordinator-resignation actions. The transport owner sends
/// the returned encrypted controls to each READY member and starts election on
/// receipt; missing ACKs never alter [nextCoordinatorTerm].
class CoordinatorResignationPlan {
  CoordinatorResignationPlan({
    required this.groupId,
    required this.coordinatorTerm,
    required this.coordinatorPeerId,
    required Iterable<PeerId> readyMembers,
  }) : readyMembers = List.unmodifiable(readyMembers
            .where((peerId) => peerId != coordinatorPeerId)
            .toSet());

  final GroupId groupId;
  final int coordinatorTerm;
  final PeerId coordinatorPeerId;
  final List<PeerId> readyMembers;

  int get nextCoordinatorTerm => coordinatorTerm + 1;
  CoordinatorResign get resign => CoordinatorResign(
      groupId: groupId, term: coordinatorTerm, peerId: coordinatorPeerId);
  GroupLeavePayload get leave => GroupLeavePayload(
        groupId: groupId,
        coordinatorTerm: coordinatorTerm,
        leavingPeerId: coordinatorPeerId,
        reason: GroupLeaveReason.applicationLeave,
      );

  /// A receiving READY member starts migration immediately after authenticating
  /// both the peer identity and the current committed term.
  bool acceptsResignation(
    CoordinatorResign received, {
    required PeerId authenticatedSender,
  }) =>
      received.groupId == groupId &&
      received.term == coordinatorTerm &&
      received.peerId == coordinatorPeerId &&
      authenticatedSender == coordinatorPeerId;
}

/// Exact bounded close deadlines for the three Section 31.9 leave paths.
class GroupLeaveGrace {
  static const int normalLeaveMs = 1000;
  static const int coordinatorResignationMs = 500;

  /// Normal/member shutdown may finish earlier after the required ACK or
  /// replacement snapshot, but must be allowed to close at the deadline.
  static bool normalMayClose({
    required int elapsedMs,
    required bool acknowledgedOrExcluded,
  }) =>
      acknowledgedOrExcluded || elapsedMs >= normalLeaveMs;

  /// Missing resignation ACKs never cancel election or prolong the grace.
  static bool coordinatorMayClose({required int elapsedMs}) =>
      elapsedMs >= coordinatorResignationMs;
}

int _compare(List<int> left, List<int> right) {
  for (var index = 0; index < left.length; index++) {
    final result = left[index].compareTo(right[index]);
    if (result != 0) return result;
  }
  return 0;
}

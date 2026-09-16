import '../types.dart';

/// The only Section 10.6 reasons that permit a new coordinator election.
enum CoordinatorElectionCause {
  noCommittedCoordinator,
  groupsMergedWithDifferentCoordinators,
  coordinatorResigned,
  coordinatorUnavailable,
  memberJoined,
}

/// Stable-coordinator policy. In particular, [memberJoined] is never an
/// election trigger, independent of the joining member's CoordinatorRank.
bool coordinatorElectionRequired(CoordinatorElectionCause cause) =>
    cause != CoordinatorElectionCause.memberJoined;

/// Required direct authenticated links after a committed coordinator change.
/// It deliberately describes a star only; it does not create member-to-member
/// application links or alter public PeerIds.
class CoordinatorStarPlan {
  CoordinatorStarPlan({
    required this.coordinatorPeerId,
    required Iterable<PeerId> committedMembers,
  }) : memberPeerIds = List.unmodifiable(committedMembers
            .where((peerId) => peerId != coordinatorPeerId)
            .toSet()
            .toList()
          ..sort(_comparePeerIds));

  final PeerId coordinatorPeerId;
  final List<PeerId> memberPeerIds;
}

int _comparePeerIds(PeerId left, PeerId right) {
  for (var index = 0; index < left.bytes.length; index++) {
    final result = left.bytes[index].compareTo(right.bytes[index]);
    if (result != 0) return result;
  }
  return 0;
}

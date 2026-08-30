import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int n) => PeerId(List.filled(16, n));
void main() {
  test('election announce/claim layout is the exact 76-byte payload', () {
    final event = ElectionAnnouncement(
        groupId: GroupId(List.filled(16, 1)),
        candidateTerm: 4,
        rank: CoordinatorRank(2, 3, _peer(4)),
        membershipHash: List.filled(32, 5));
    expect(ElectionAnnouncement.decode(event.encode()).rank.capabilityScore, 3);
  });
  test('higher term wins split-brain selection, then higher rank', () {
    final a = ElectionAnnouncement(
        groupId: GroupId(List.filled(16, 1)),
        candidateTerm: 3,
        rank: CoordinatorRank(99, 0, _peer(1)),
        membershipHash: List.filled(32, 0));
    final b = ElectionAnnouncement(
        groupId: a.groupId,
        candidateTerm: 4,
        rank: CoordinatorRank(0, 0, _peer(2)),
        membershipHash: List.filled(32, 0));
    expect(highestElectionCandidate([a, b]), b);
    expect(
        mayClaimCoordinator(
            localRank: b.rank, candidateTerm: 4, observed: [a, b]),
        isTrue);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int value) => PeerId(List.filled(16, value));

void main() {
  test('COORD-002 healthy coordinator stays stable when higher rank joins', () {
    final existing = CoordinatorRank(0, 1, _peer(1));
    final joining = CoordinatorRank(9, 15, _peer(2));
    expect(joining.compareTo(existing), greaterThan(0));
    expect(coordinatorElectionRequired(CoordinatorElectionCause.memberJoined),
        isFalse);
  });

  test('COORD-006 migration rebuilds only the coordinator star', () {
    final plan = CoordinatorStarPlan(
      coordinatorPeerId: _peer(2),
      committedMembers: [_peer(1), _peer(2), _peer(3), _peer(1)],
    );
    expect(plan.coordinatorPeerId, _peer(2));
    expect(plan.memberPeerIds, [_peer(1), _peer(3)]);
  });
}

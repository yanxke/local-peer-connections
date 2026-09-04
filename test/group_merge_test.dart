import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int n) => PeerId(List.filled(16, n));
GroupMergeInfo _info(int group, List<GroupMember> members,
        {bool autoMerge = true,
        DiscoveryMode discoveryMode = DiscoveryMode.tokenScoped,
        List<int>? tokenHash,
        GroupTrustMode trustMode = GroupTrustMode.openTofu,
        bool knownPeersAutoMerge = false}) =>
    GroupMergeInfo(
        namespaceHash: List.filled(32, 1),
        tokenHash: tokenHash ?? List.filled(32, 2),
        discoveryMode: discoveryMode,
        autoMerge: autoMerge,
        trustMode: trustMode,
        knownPeersAutoMerge: knownPeersAutoMerge,
        groupId: GroupId(List.filled(16, group)),
        members: members);
void main() {
  test('COORD-007 singleton merge retains lexicographically smaller GroupId',
      () {
    final a = _info(2, [GroupMember(_peer(1), 8)]);
    final b = _info(1, [GroupMember(_peer(2), 8)]);
    expect(evaluateGroupMerge(a, b).winner, b);
  });
  test('UT-086 larger committed membership wins before GroupId tie-break', () {
    final smallerId = _info(1, [GroupMember(_peer(1), 8)]);
    final largerMembership =
        _info(2, [GroupMember(_peer(2), 8), GroupMember(_peer(3), 8)]);
    expect(evaluateGroupMerge(smallerId, largerMembership).winner,
        largerMembership);
  });

  test('COORD-041 larger five-member group wins over smaller GroupId', () {
    final largerId = _info(
        9, [for (var peer = 1; peer <= 5; peer++) GroupMember(_peer(peer), 8)]);
    final smallerId = _info(1, [GroupMember(_peer(6), 8)]);
    expect(evaluateGroupMerge(largerId, smallerId).winner, largerId);
  });

  test('COORD-042 equal membership merge uses lexicographically smaller ID',
      () {
    final largerId = _info(9, [GroupMember(_peer(1), 8)]);
    final smallerId = _info(1, [GroupMember(_peer(2), 8)]);
    expect(evaluateGroupMerge(largerId, smallerId).winner, smallerId);
  });
  test('capacity is minimum of complete candidate union and never subsets', () {
    final result = evaluateGroupMerge(_info(1, [GroupMember(_peer(1), 2)]),
        _info(2, [GroupMember(_peer(2), 2), GroupMember(_peer(3), 2)]));
    expect(result.decision, GroupMergeDecision.groupFull);
    expect(result.effectiveMaxPeers, 2);
    expect(result.unionCount, 3);
  });

  test('COORD-015 oversized 6+5 member merge is refused at capacity eight', () {
    final first = _info(
        1, [for (var peer = 1; peer <= 6; peer++) GroupMember(_peer(peer), 8)]);
    final second = _info(2,
        [for (var peer = 7; peer <= 11; peer++) GroupMember(_peer(peer), 8)]);

    final result = evaluateGroupMerge(first, second);
    expect(result.decision, GroupMergeDecision.groupFull);
    expect(result.effectiveMaxPeers, 8);
    expect(result.unionCount, 11);
  });

  test('COORD-023 capacity conflict preserves both committed memberships', () {
    final first = _info(
        1, [for (var peer = 1; peer <= 5; peer++) GroupMember(_peer(peer), 8)]);
    final second = _info(
        2, [for (var peer = 6; peer <= 9; peer++) GroupMember(_peer(peer), 8)]);

    final result = evaluateGroupMerge(first, second);
    expect(result.decision, GroupMergeDecision.groupFull);
    expect(first.members, hasLength(5));
    expect(second.members, hasLength(4));
  });

  test('COORD-027 only would-be merge winner emits GROUP_MERGE_REJECT', () {
    final winner = _info(
        1, [for (var peer = 1; peer <= 5; peer++) GroupMember(_peer(peer), 8)]);
    final loser = _info(
        2, [for (var peer = 6; peer <= 9; peer++) GroupMember(_peer(peer), 8)]);
    final evaluation = evaluateGroupMerge(winner, loser);

    expect(
      groupMergeRejectForWinner(
        local: winner,
        remote: loser,
        evaluation: evaluation,
      )?.reason,
      GroupMergeRejectReason.groupFull,
    );
    expect(
      groupMergeRejectForWinner(
        local: loser,
        remote: winner,
        evaluation: evaluation,
      ),
      isNull,
    );
  });

  test('COORD-016 effective merge capacity is minimum of all members', () {
    final first = _info(1, [GroupMember(_peer(1), 12)]);
    final second =
        _info(2, [GroupMember(_peer(2), 8), GroupMember(_peer(3), 10)]);

    final result = evaluateGroupMerge(first, second);
    expect(result.decision, GroupMergeDecision.merge);
    expect(result.effectiveMaxPeers, 8);
    expect(result.unionCount, 3);
  });

  test('COORD-021 different token-scoped join tokens do not merge', () {
    final first = _info(1, [GroupMember(_peer(1), 8)]);
    final second =
        _info(2, [GroupMember(_peer(2), 8)], tokenHash: List.filled(32, 3));
    expect(evaluateGroupMerge(first, second).decision,
        GroupMergeDecision.joinTokenMismatch);
  });

  test('COORD-022 compatible open-proximity groups merge', () {
    final first = _info(1, [GroupMember(_peer(1), 8)],
        discoveryMode: DiscoveryMode.openProximity);
    final second = _info(2, [GroupMember(_peer(2), 8)],
        discoveryMode: DiscoveryMode.openProximity);
    expect(
        evaluateGroupMerge(first, second).decision, GroupMergeDecision.merge);
  });

  test('COORD-025/026 incompatible trust merge settings are refused', () {
    final open = _info(1, [GroupMember(_peer(1), 8)]);
    final knownPeers = _info(2, [GroupMember(_peer(2), 8)],
        trustMode: GroupTrustMode.knownPeers);
    expect(evaluateGroupMerge(open, knownPeers).decision,
        GroupMergeDecision.trustModeMismatch);

    final firstKnown = _info(3, [GroupMember(_peer(3), 8)],
        trustMode: GroupTrustMode.knownPeers);
    final secondKnown = _info(4, [GroupMember(_peer(4), 8)],
        trustMode: GroupTrustMode.knownPeers);
    expect(evaluateGroupMerge(firstKnown, secondKnown).decision,
        GroupMergeDecision.knownPeersAutoMergeDisabled);
  });

  test('COORD-034 conflicting same-PeerId capacity reconciles to minimum', () {
    final first = _info(1, [GroupMember(_peer(1), 12)]);
    final second = _info(2, [GroupMember(_peer(1), 8)]);

    final result = evaluateGroupMerge(first, second);
    expect(result.decision, GroupMergeDecision.merge);
    expect(result.unionCount, 1);
    expect(result.effectiveMaxPeers, 8);
  });

  test('COORD-014 same-GroupId split brain reconciles at max term plus one',
      () {
    final reconciliation = reconcileSameGroupSplitBrain(
      termA: 7,
      termB: 9,
      snapshotA: [GroupMember(_peer(1), 12), GroupMember(_peer(2), 8)],
      snapshotB: [GroupMember(_peer(2), 10), GroupMember(_peer(3), 9)],
    );
    expect(reconciliation.coordinatorTerm, 10);
    expect(reconciliation.members.map((member) => member.peerId),
        [_peer(1), _peer(2), _peer(3)]);
    expect(reconciliation.members[1].maxPeers, 8);
    expect(reconciliation.effectiveMaxPeers, 8);
  });

  test('COORD-019 three compatible groups converge on one GroupId', () {
    final groups = [
      _info(3, [GroupMember(_peer(1), 8)]),
      _info(2, [GroupMember(_peer(2), 8)]),
      _info(1, [GroupMember(_peer(3), 8)]),
    ];
    expect(selectConvergedMergeWinner(groups).groupId,
        GroupId(List.filled(16, 1)));
  });

  test('COORD-069 singleton GROUP_MERGE converges both committed views', () {
    final winner = _info(1, [GroupMember(_peer(1), 8)]);
    final loser = _info(2, [GroupMember(_peer(2), 8)]);
    final evaluation = evaluateGroupMerge(winner, loser);
    expect(evaluation.decision, GroupMergeDecision.merge);

    final payload = GroupMergePayload(
        winningGroupId: winner.groupId,
        losingGroupId: loser.groupId,
        newCoordinatorTerm: 1,
        effectiveMaxPeers: evaluation.effectiveMaxPeers,
        members: [GroupMember(_peer(1), 8), GroupMember(_peer(2), 8)]);
    final winningReceiver = GroupMergeReceiver(
        committedGroupId: winner.groupId,
        committedTerm: 0,
        committedMembers: winner.members);
    final losingReceiver = GroupMergeReceiver(
        committedGroupId: loser.groupId,
        committedTerm: 0,
        committedMembers: loser.members);

    expect(
        winningReceiver.receive(payload), GroupMergeReceiveDisposition.applied);
    expect(
        losingReceiver.receive(payload), GroupMergeReceiveDisposition.applied);
    expect(winningReceiver.groupId, winner.groupId);
    expect(losingReceiver.groupId, winner.groupId);
    expect(winningReceiver.term, 1);
    expect(losingReceiver.term, 1);
    expect(winningReceiver.members, payload.members);
    expect(losingReceiver.members, payload.members);
  });

  test('COORD-070 GROUP_MERGE requires advertised winning coordinator', () {
    final winner = _info(1, [GroupMember(_peer(1), 8)]);
    final payload = GroupMergePayload(
        winningGroupId: winner.groupId,
        losingGroupId: GroupId(List.filled(16, 2)),
        newCoordinatorTerm: 1,
        effectiveMaxPeers: 8,
        members: [GroupMember(_peer(1), 8), GroupMember(_peer(2), 8)]);
    final announced = GroupInfoPayload(
        info: winner, coordinatorTerm: 0, coordinatorPeerId: _peer(1));

    expect(
        isIncomingGroupMergeAuthorized(
            payload: payload,
            localGroupId: payload.losingGroupId,
            retainedRemoteInfo: announced,
            authenticatedSender: _peer(1)),
        isTrue);
    expect(
        isIncomingGroupMergeAuthorized(
            payload: payload,
            localGroupId: payload.losingGroupId,
            retainedRemoteInfo: announced,
            authenticatedSender: _peer(3)),
        isFalse);
    expect(
        isIncomingGroupMergeAuthorized(
            payload: payload,
            localGroupId: winner.groupId,
            retainedRemoteInfo: announced,
            authenticatedSender: _peer(1)),
        isFalse);
  });
}

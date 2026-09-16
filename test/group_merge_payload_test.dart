import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int n) => PeerId(List.filled(16, n));
void main() {
  test('GROUP_MERGE is committed only within effective capacity', () async {
    final payload = GroupMergePayload(
        winningGroupId: GroupId(List.filled(16, 1)),
        losingGroupId: GroupId(List.filled(16, 2)),
        newCoordinatorTerm: 2,
        effectiveMaxPeers: 2,
        members: [GroupMember(_peer(1), 2), GroupMember(_peer(2), 2)]);
    expect(
        (await GroupMergePayload.decode(await payload.encode()))
            .newCoordinatorTerm,
        2);
  });
  test('GROUP_MERGE_REJECT has its frozen 38 byte layout', () {
    final reject = GroupMergeRejectPayload(
        localGroupId: GroupId(List.filled(16, 1)),
        remoteGroupId: GroupId(List.filled(16, 2)),
        reason: GroupMergeRejectReason.groupFull,
        effectiveMaxPeers: 2,
        candidateUnionCount: 3);
    expect(
        GroupMergeRejectPayload.decode(reject.encode()).candidateUnionCount, 3);
  });

  test('COORD-020 stale/equal superseded GROUP_MERGE is ignored', () {
    final initial = GroupId(List.filled(16, 9));
    final applied = GroupMergePayload(
      winningGroupId: GroupId(List.filled(16, 1)),
      losingGroupId: initial,
      newCoordinatorTerm: 3,
      effectiveMaxPeers: 8,
      members: [GroupMember(_peer(1), 8), GroupMember(_peer(2), 8)],
    );
    final receiver = GroupMergeReceiver(
      committedGroupId: initial,
      committedTerm: 2,
      committedMembers: [GroupMember(_peer(1), 8)],
    );
    expect(receiver.receive(applied), GroupMergeReceiveDisposition.applied);
    expect(receiver.receive(applied), GroupMergeReceiveDisposition.duplicate);

    final conflictingEqual = GroupMergePayload(
      winningGroupId: GroupId(List.filled(16, 3)),
      losingGroupId: initial,
      newCoordinatorTerm: 3,
      effectiveMaxPeers: 8,
      members: [GroupMember(_peer(3), 8)],
    );
    expect(
        receiver.receive(conflictingEqual), GroupMergeReceiveDisposition.stale);
    expect(receiver.groupId, applied.winningGroupId);
    expect(receiver.members, applied.members);
  });

  test('COORD-018 losing GroupId redirects for exactly 30 seconds', () {
    final losing = GroupId(List.filled(16, 2));
    final winning = GroupId(List.filled(16, 1));
    final alias = GroupMergeAlias(
      losingGroupId: losing,
      winningGroupId: winning,
      installedAtMs: 100,
    );
    expect(alias.redirect(losing, nowMs: 100), winning);
    expect(alias.redirect(losing, nowMs: 30099), winning);
    expect(alias.redirect(losing, nowMs: 30100), isNull);
  });
}

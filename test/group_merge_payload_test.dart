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
}

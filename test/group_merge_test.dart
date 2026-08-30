import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int n) => PeerId(List.filled(16, n));
GroupMergeInfo _info(int group, List<GroupMember> members,
        {bool autoMerge = true}) =>
    GroupMergeInfo(
        namespaceHash: List.filled(32, 1),
        tokenHash: List.filled(32, 2),
        discoveryMode: DiscoveryMode.tokenScoped,
        autoMerge: autoMerge,
        trustMode: GroupTrustMode.openTofu,
        knownPeersAutoMerge: false,
        groupId: GroupId(List.filled(16, group)),
        members: members);
void main() {
  test('Group merge uses member count, then smaller GroupId, as winner', () {
    final a = _info(2, [GroupMember(_peer(1), 8)]);
    final b = _info(1, [GroupMember(_peer(2), 8)]);
    expect(evaluateGroupMerge(a, b).winner, b);
  });
  test('capacity is minimum of complete candidate union and never subsets', () {
    final result = evaluateGroupMerge(_info(1, [GroupMember(_peer(1), 2)]),
        _info(2, [GroupMember(_peer(2), 2), GroupMember(_peer(3), 2)]));
    expect(result.decision, GroupMergeDecision.groupFull);
    expect(result.effectiveMaxPeers, 2);
    expect(result.unionCount, 3);
  });
}

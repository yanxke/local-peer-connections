import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int n) => PeerId(List.filled(16, n));
void main() {
  test('GROUP_INFO round trip retains its committed membership', () async {
    final value = GroupInfoPayload(
        info: GroupMergeInfo(
            namespaceHash: List.filled(32, 1),
            tokenHash: List.filled(32, 2),
            discoveryMode: DiscoveryMode.tokenScoped,
            autoMerge: true,
            trustMode: GroupTrustMode.openTofu,
            knownPeersAutoMerge: false,
            groupId: GroupId(List.filled(16, 3)),
            members: [GroupMember(_peer(1), 8), GroupMember(_peer(2), 8)]),
        coordinatorTerm: 1,
        coordinatorPeerId: _peer(1));
    final decoded = await GroupInfoPayload.decode(await value.encode());
    expect(decoded.info.members.length, 2);
    expect(decoded.coordinatorPeerId, _peer(1));
  });
  test('GROUP_INFO rejects noncanonical record order', () async {
    final value = GroupInfoPayload(
        info: GroupMergeInfo(
            namespaceHash: List.filled(32, 1),
            tokenHash: List.filled(32, 2),
            discoveryMode: DiscoveryMode.tokenScoped,
            autoMerge: true,
            trustMode: GroupTrustMode.openTofu,
            knownPeersAutoMerge: false,
            groupId: GroupId(List.filled(16, 3)),
            members: [GroupMember(_peer(2), 8), GroupMember(_peer(1), 8)]),
        coordinatorTerm: 0,
        coordinatorPeerId: null);
    final encoded = await value.encode();
    expectLater(GroupInfoPayload.decode(encoded), throwsA(isA<LpcException>()));
  });

  test('COORD-017/024 GROUP_INFO preserves complete member capacity records',
      () async {
    final remote = GroupInfoPayload(
      info: GroupMergeInfo(
        namespaceHash: List.filled(32, 1),
        tokenHash: List.filled(32, 2),
        discoveryMode: DiscoveryMode.tokenScoped,
        autoMerge: true,
        trustMode: GroupTrustMode.openTofu,
        knownPeersAutoMerge: false,
        groupId: GroupId(List.filled(16, 3)),
        members: [GroupMember(_peer(3), 9), GroupMember(_peer(4), 8)],
      ),
      coordinatorTerm: 2,
      coordinatorPeerId: _peer(3),
    );
    final decoded = await GroupInfoPayload.decode(await remote.encode());
    expect(decoded.info.members.map((member) => member.maxPeers), [9, 8]);

    final local = GroupMergeInfo(
      namespaceHash: List.filled(32, 1),
      tokenHash: List.filled(32, 2),
      discoveryMode: DiscoveryMode.tokenScoped,
      autoMerge: true,
      trustMode: GroupTrustMode.openTofu,
      knownPeersAutoMerge: false,
      groupId: GroupId(List.filled(16, 2)),
      members: [GroupMember(_peer(1), 12), GroupMember(_peer(2), 10)],
    );
    final merge = evaluateGroupMerge(local, decoded.info);
    expect(merge.decision, GroupMergeDecision.merge);
    expect(merge.unionCount, 4);
    expect(merge.effectiveMaxPeers, 8);
  });
}

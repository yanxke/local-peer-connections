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
}

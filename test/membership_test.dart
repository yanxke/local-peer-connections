import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int value) => PeerId(List.filled(16, value));
void main() {
  test('CoordinatorRank compares the exact high tuple first', () {
    expect(
        CoordinatorRank(1, 0, _peer(0))
            .compareTo(CoordinatorRank(0, 99, _peer(255))),
        greaterThan(0));
    expect(
        coordinatorCapabilityScore(
            lanListen: true,
            l2capListen: true,
            gattPeripheral: true,
            gattCentral: true),
        15);
  });
  test('membership snapshot validates canonical hash and record ordering',
      () async {
    final snapshot = MembershipSnapshot(
        groupId: GroupId(List.filled(16, 9)),
        coordinatorTerm: 3,
        members: [GroupMember(_peer(2), 8), GroupMember(_peer(1), 7)]);
    final encoded = await snapshot.encode();
    final decoded = await MembershipSnapshot.decode(encoded);
    expect(decoded.members.length, 2);
    encoded[30] ^= 1;
    expect(
        () => MembershipSnapshot.decode(encoded), throwsA(isA<LpcException>()));
  });
}

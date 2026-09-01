import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('GROUP_LEAVE has the exact 44-byte Section 31.9 layout', () {
    final payload = GroupLeavePayload(
      groupId: GroupId(List<int>.generate(16, (index) => index)),
      coordinatorTerm: 0x0102030405060708,
      leavingPeerId: PeerId(List<int>.generate(16, (index) => 0x10 + index)),
      reason: GroupLeaveReason.kicked,
    );
    final bytes = payload.encode();

    expect(bytes, [
      ...List<int>.generate(16, (index) => index),
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      ...List<int>.generate(16, (index) => 0x10 + index),
      3,
      0,
      0,
      0,
    ]);
    expect(GroupLeavePayload.decode(bytes).reason, GroupLeaveReason.kicked);
  });

  test('GROUP_LEAVE rejects nonzero reserved bytes and invalid reasons', () {
    final bytes = List<int>.filled(44, 0)..[40] = 1;
    bytes[41] = 1;
    expect(() => GroupLeavePayload.decode(bytes), throwsA(isA<LpcException>()));
    bytes[41] = 0;
    bytes[40] = 4;
    expect(() => GroupLeavePayload.decode(bytes), throwsA(isA<LpcException>()));
  });

  test('COORD-028 normal leave removes member without changing term', () {
    final group = GroupId(List.filled(16, 1));
    final coordinator = PeerId(List.filled(16, 1));
    final leaving = PeerId(List.filled(16, 2));
    final controller = GroupLeaveMembershipController(
      groupId: group,
      coordinatorTerm: 7,
      coordinatorPeerId: coordinator,
      committedMembers: [GroupMember(coordinator, 8), GroupMember(leaving, 8)],
    );

    final commit = controller.accept(
      GroupLeavePayload(
        groupId: group,
        coordinatorTerm: 7,
        leavingPeerId: leaving,
        reason: GroupLeaveReason.applicationLeave,
      ),
      authenticatedSender: leaving,
    );
    expect(commit.coordinatorTerm, 7);
    expect(commit.members.map((member) => member.peerId), [coordinator]);
  });

  test('COORD-032 only coordinator can kick a committed member', () {
    final group = GroupId(List.filled(16, 1));
    final coordinator = PeerId(List.filled(16, 1));
    final target = PeerId(List.filled(16, 2));
    final controller = GroupLeaveMembershipController(
      groupId: group,
      coordinatorTerm: 7,
      coordinatorPeerId: coordinator,
      committedMembers: [GroupMember(coordinator, 8), GroupMember(target, 8)],
    );
    final kicked = GroupLeavePayload(
      groupId: group,
      coordinatorTerm: 7,
      leavingPeerId: target,
      reason: GroupLeaveReason.kicked,
    );
    expect(
      () => controller.accept(kicked, authenticatedSender: target),
      throwsA(isA<LpcException>()),
    );
    final commit = controller.accept(kicked, authenticatedSender: coordinator);
    expect(commit.coordinatorTerm, 7);
    expect(commit.members.map((member) => member.peerId), [coordinator]);
  });

  test('COORD-029 terminal non-coordinator disconnect removes same-term member',
      () {
    final group = GroupId(List.filled(16, 1));
    final coordinator = PeerId(List.filled(16, 1));
    final absent = PeerId(List.filled(16, 2));
    final controller = GroupLeaveMembershipController(
      groupId: group,
      coordinatorTerm: 7,
      coordinatorPeerId: coordinator,
      committedMembers: [GroupMember(coordinator, 8), GroupMember(absent, 8)],
    );
    final commit = controller.removeAbruptNonCoordinator(absent);
    expect(commit.coordinatorTerm, 7);
    expect(commit.members.map((member) => member.peerId), [coordinator]);
  });

  test('COORD-038/039/040 leave grace never waits indefinitely for ACK', () {
    expect(
      GroupLeaveGrace.normalMayClose(
          elapsedMs: 999, acknowledgedOrExcluded: false),
      isFalse,
    );
    expect(
      GroupLeaveGrace.normalMayClose(
          elapsedMs: 1000, acknowledgedOrExcluded: false),
      isTrue,
    );
    expect(
      GroupLeaveGrace.normalMayClose(
          elapsedMs: 0, acknowledgedOrExcluded: true),
      isTrue,
    );
    expect(GroupLeaveGrace.coordinatorMayClose(elapsedMs: 499), isFalse);
    expect(GroupLeaveGrace.coordinatorMayClose(elapsedMs: 500), isTrue);
  });

  test('COORD-030/031 coordinator resignation starts election and excludes old',
      () {
    final group = GroupId(List.filled(16, 1));
    final old = PeerId(List.filled(16, 1));
    final next = PeerId(List.filled(16, 2));
    final plan = CoordinatorResignationPlan(
      groupId: group,
      coordinatorTerm: 7,
      coordinatorPeerId: old,
      readyMembers: [old, next],
    );
    expect(plan.readyMembers, [next]);
    expect(plan.nextCoordinatorTerm, 8);
    expect(plan.leave.leavingPeerId, old);
    expect(
        plan.acceptsResignation(plan.resign, authenticatedSender: old), isTrue);

    final membership = GroupLeaveMembershipController(
      groupId: group,
      coordinatorTerm: 7,
      coordinatorPeerId: old,
      committedMembers: [GroupMember(old, 8), GroupMember(next, 8)],
    ).removeResignedCoordinator(old);
    expect(membership.members.map((member) => member.peerId), [next]);
  });
}

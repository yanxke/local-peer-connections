import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int value) => PeerId(List.filled(16, value));

List<int> _messageId(int prefix, int counter) {
  final bytes = ByteData(8)
    ..setUint32(0, prefix)
    ..setUint32(4, counter);
  return bytes.buffer.asUint8List();
}

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

  test('UT-098/099 later same-domain snapshot wins and older is stale', () {
    final ordering = MembershipSnapshotOrderTable();
    expect(
      ordering.observe(
        coordinatorPeerId: _peer(1),
        coordinatorTerm: 7,
        sessionId: List.filled(16, 9),
        senderMessageId: _messageId(4, 2),
      ),
      MembershipSnapshotOrderDisposition.accepted,
    );
    expect(
      ordering.observe(
        coordinatorPeerId: _peer(1),
        coordinatorTerm: 7,
        sessionId: List.filled(16, 9),
        senderMessageId: _messageId(4, 1),
      ),
      MembershipSnapshotOrderDisposition.stale,
    );
  });

  test('UT-100 coordinator and term changes are distinct ordering domains', () {
    final ordering = MembershipSnapshotOrderTable();
    for (final coordinatorAndTerm in [(1, 7), (2, 7), (1, 8)]) {
      expect(
        ordering.observe(
          coordinatorPeerId: _peer(coordinatorAndTerm.$1),
          coordinatorTerm: coordinatorAndTerm.$2,
          sessionId: List.filled(16, 9),
          senderMessageId: _messageId(4, 1),
        ),
        MembershipSnapshotOrderDisposition.accepted,
      );
    }
  });

  test('UT-101/102/103/COORD-052/053 new SessionId starts a fresh baseline',
      () {
    final ordering = MembershipSnapshotOrderTable();
    expect(
      ordering.observe(
        coordinatorPeerId: _peer(1),
        coordinatorTerm: 7,
        sessionId: List.filled(16, 9),
        senderMessageId: _messageId(4, 100),
      ),
      MembershipSnapshotOrderDisposition.accepted,
    );
    // Same prefix but a new logical SessionId must accept counter one.
    expect(
      ordering.observe(
        coordinatorPeerId: _peer(1),
        coordinatorTerm: 7,
        sessionId: List.filled(16, 10),
        senderMessageId: _messageId(4, 1),
      ),
      MembershipSnapshotOrderDisposition.accepted,
    );
    expect(ordering.domainCount, 2);
  });

  test('COORD-047 newer same-term snapshot survives old post-RESUME replay',
      () async {
    final receiver = MembershipSnapshotReceiver();
    final sessionId = List.filled(16, 3);
    final a = MembershipSnapshot(
      groupId: GroupId(List.filled(16, 9)),
      coordinatorTerm: 7,
      members: [GroupMember(_peer(1), 8)],
    );
    final b = MembershipSnapshot(
      groupId: a.groupId,
      coordinatorTerm: 7,
      members: [GroupMember(_peer(1), 8), GroupMember(_peer(2), 8)],
    );
    final committed = <MembershipSnapshot>[];
    await receiver.add(
      messageId: _messageId(4, 1),
      sessionId: sessionId,
      coordinatorPeerId: _peer(1),
      payload: await a.encode(),
      commit: committed.add,
    );
    await receiver.add(
      messageId: _messageId(4, 2),
      sessionId: sessionId,
      coordinatorPeerId: _peer(1),
      payload: await b.encode(),
      commit: committed.add,
    );
    final oldReplay = await receiver.add(
      messageId: _messageId(4, 1),
      sessionId: sessionId,
      coordinatorPeerId: _peer(1),
      payload: await a.encode(),
      commit: committed.add,
    );
    expect(oldReplay.committed, isNull);
    expect(committed, hasLength(2));
    expect(committed.last.members.map((member) => member.peerId),
        [_peer(1), _peer(2)]);
  });

  test('COORD-049/050 post-RESUME duplicate B ACKs without reapplying',
      () async {
    final receiver = MembershipSnapshotReceiver();
    final sessionId = List.filled(16, 3);
    final a = MembershipSnapshot(
      groupId: GroupId(List.filled(16, 9)),
      coordinatorTerm: 7,
      members: [GroupMember(_peer(1), 8)],
    );
    final b = MembershipSnapshot(
      groupId: a.groupId,
      coordinatorTerm: 7,
      members: [GroupMember(_peer(1), 8), GroupMember(_peer(2), 8)],
    );
    var commits = 0;
    await receiver.add(
      messageId: _messageId(4, 1),
      sessionId: sessionId,
      coordinatorPeerId: _peer(1),
      payload: await a.encode(),
      commit: (_) => commits++,
    );
    final bPayload = await b.encode();
    await receiver.add(
      messageId: _messageId(4, 2),
      sessionId: sessionId,
      coordinatorPeerId: _peer(1),
      payload: bPayload,
      commit: (_) => commits++,
    );
    final postResumeB = await receiver.add(
      messageId: _messageId(4, 2),
      sessionId: sessionId,
      coordinatorPeerId: _peer(1),
      payload: bPayload,
      commit: (_) => commits++,
    );
    expect(postResumeB.committed, isNull);
    expect(postResumeB.acknowledgmentMessageId, _messageId(4, 2));
    expect(commits, 2);
  });

  test('COORD-048/051 resumed newer snapshot prevents stale rollback',
      () async {
    final receiver = MembershipSnapshotReceiver();
    final sessionId = List.filled(16, 3);
    final a = MembershipSnapshot(
      groupId: GroupId(List.filled(16, 9)),
      coordinatorTerm: 7,
      members: [GroupMember(_peer(1), 8)],
    );
    final b = MembershipSnapshot(
      groupId: a.groupId,
      coordinatorTerm: 7,
      members: [GroupMember(_peer(1), 8), GroupMember(_peer(2), 8)],
    );
    final committed = <MembershipSnapshot>[];
    await receiver.add(
      messageId: _messageId(4, 1),
      sessionId: sessionId,
      coordinatorPeerId: _peer(1),
      payload: await a.encode(),
      commit: committed.add,
    );
    // An interrupted B has no committed receiver state. Its complete
    // whole-operation retransmission after RESUME becomes the next snapshot.
    await receiver.add(
      messageId: _messageId(4, 2),
      sessionId: sessionId,
      coordinatorPeerId: _peer(1),
      payload: await b.encode(),
      commit: committed.add,
    );
    final delayedA = await receiver.add(
      messageId: _messageId(4, 1),
      sessionId: sessionId,
      coordinatorPeerId: _peer(1),
      payload: await a.encode(),
      commit: committed.add,
    );
    expect(delayedA.committed, isNull);
    expect(committed, hasLength(2));
    expect(committed.last.members, hasLength(2));
  });

  test(
      'UT-049 duplicate ACK-required MEMBERSHIP_SNAPSHOT commits once and ACKs again',
      () async {
    final receiver = MembershipSnapshotReceiver();
    final snapshot = MembershipSnapshot(
      groupId: GroupId(List.filled(16, 9)),
      coordinatorTerm: 7,
      members: [GroupMember(_peer(1), 8)],
    );
    final payload = await snapshot.encode();
    final messageId = _messageId(4, 1);
    var commits = 0;

    final first = await receiver.add(
      messageId: messageId,
      sessionId: List.filled(16, 3),
      coordinatorPeerId: _peer(2),
      payload: payload,
      commit: (_) => commits++,
    );
    final duplicate = await receiver.add(
      messageId: messageId,
      sessionId: List.filled(16, 3),
      coordinatorPeerId: _peer(2),
      payload: payload,
      commit: (_) => commits++,
    );

    expect(first.committed, isNotNull);
    expect(first.acknowledgmentMessageId, messageId);
    expect(duplicate.committed, isNull);
    expect(duplicate.acknowledgmentMessageId, messageId);
    expect(commits, 1);
  });
}

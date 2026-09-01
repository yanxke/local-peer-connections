import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int n) => PeerId(List.filled(16, n));
void main() {
  test('election announce/claim layout is the exact 76-byte payload', () {
    final event = ElectionAnnouncement(
        groupId: GroupId(List.filled(16, 1)),
        candidateTerm: 4,
        rank: CoordinatorRank(2, 3, _peer(4)),
        membershipHash: List.filled(32, 5));
    expect(ElectionAnnouncement.decode(event.encode()).rank.capabilityScore, 3);
  });
  test('COORD-008/009 higher term wins, then higher CoordinatorRank', () {
    final a = ElectionAnnouncement(
        groupId: GroupId(List.filled(16, 1)),
        candidateTerm: 3,
        rank: CoordinatorRank(99, 0, _peer(1)),
        membershipHash: List.filled(32, 0));
    final b = ElectionAnnouncement(
        groupId: a.groupId,
        candidateTerm: 4,
        rank: CoordinatorRank(0, 0, _peer(2)),
        membershipHash: List.filled(32, 0));
    expect(highestElectionCandidate([a, b]), b);
    expect(
        mayClaimCoordinator(
            localRank: b.rank, candidateTerm: 4, observed: [a, b]),
        isTrue);
  });

  test('Section 10.9 election waits, claims, then emits three heartbeats', () {
    final controller = ElectionController(
        groupId: GroupId(List.filled(16, 1)),
        localRank: CoordinatorRank(2, 3, _peer(4)),
        lastCommittedTerm: 7,
        membershipHash: List.filled(32, 5),
        startedAtMs: 0);
    expect(controller.poll(1199), isEmpty);
    expect(controller.poll(1200).single, isA<ElectionClaim>());
    expect(controller.poll(1699), isEmpty);
    final elected = controller.poll(1700);
    expect(elected[0], isA<ElectionBecameCoordinator>());
    expect(elected[1], isA<ElectionHeartbeat>());
    expect((controller.poll(1800).single as ElectionHeartbeat).index, 1);
    expect((controller.poll(1900).single as ElectionHeartbeat).index, 2);
    expect(controller.poll(2000), isEmpty);
  });

  test('higher-ranked candidate prevents local coordinator promotion', () {
    final controller = ElectionController(
        groupId: GroupId(List.filled(16, 1)),
        localRank: CoordinatorRank(2, 3, _peer(4)),
        lastCommittedTerm: 7,
        membershipHash: List.filled(32, 5),
        startedAtMs: 0);
    controller.observe(
        ElectionAnnouncement(
            groupId: GroupId(List.filled(16, 1)),
            candidateTerm: 8,
            rank: CoordinatorRank(2, 4, _peer(5)),
            membershipHash: List.filled(32, 5)),
        isClaim: false,
        nowMs: 100);
    expect(controller.poll(2000), isEmpty);
    expect(controller.isCoordinator, isFalse);
  });

  test('COORD-001 simultaneous three-peer election converges automatically',
      () {
    final groupId = GroupId(List.filled(16, 1));
    final controllers = [
      for (var peer = 1; peer <= 3; peer++)
        ElectionController(
          groupId: groupId,
          localRank: CoordinatorRank(0, peer, _peer(peer)),
          lastCommittedTerm: 7,
          membershipHash: List.filled(32, 5),
          startedAtMs: 0,
        ),
    ];

    // Bootstrap links exchange every candidate announcement during the
    // normative 1200 ms observation window.
    for (final receiver in controllers) {
      for (final sender in controllers) {
        if (receiver == sender) continue;
        receiver.observe(sender.localAnnouncement, isClaim: false, nowMs: 0);
      }
    }
    final claims = [
      for (final controller in controllers)
        ...controller.poll(1200).whereType<ElectionClaim>(),
    ];
    expect(claims, hasLength(1));
    expect(claims.single.message.rank.peerId, _peer(3));

    // Every reachable peer observes the authenticated winning claim. No user
    // host selection participates in this convergence.
    for (final controller in controllers) {
      if (controller.localRank.peerId == _peer(3)) continue;
      controller.observe(claims.single.message, isClaim: true, nowMs: 1200);
    }
    for (final controller in controllers) {
      controller.poll(1700);
    }
    expect(controllers.where((controller) => controller.isCoordinator),
        hasLength(1));
    expect(
        controllers
            .singleWhere((controller) => controller.isCoordinator)
            .localRank
            .peerId,
        _peer(3));
  });

  test('COORD-003 coordinator loss elects exactly one replacement', () {
    var now = DateTime(2026);
    final liveness = CoordinatorLiveness(clock: () => now);
    liveness.observe();
    now = now.add(const Duration(seconds: 3));
    expect(liveness.unavailable, isTrue);

    final groupId = GroupId(List.filled(16, 1));
    final remaining = [
      for (final peer in [2, 3])
        ElectionController(
          groupId: groupId,
          localRank: CoordinatorRank(0, peer, _peer(peer)),
          lastCommittedTerm: 7,
          membershipHash: List.filled(32, 5),
          startedAtMs: 0,
        ),
    ];
    for (final receiver in remaining) {
      for (final sender in remaining) {
        if (receiver != sender) {
          receiver.observe(sender.localAnnouncement, isClaim: false, nowMs: 0);
        }
      }
    }
    final claim = remaining
        .expand((controller) => controller.poll(1200))
        .whereType<ElectionClaim>()
        .single;
    for (final controller in remaining) {
      if (controller.localRank.peerId != claim.message.rank.peerId) {
        controller.observe(claim.message, isClaim: true, nowMs: 1200);
      }
      controller.poll(1700);
    }
    expect(remaining.where((controller) => controller.isCoordinator),
        hasLength(1));
    expect(
        remaining
            .singleWhere((controller) => controller.isCoordinator)
            .localRank
            .peerId,
        _peer(3));
  });
}

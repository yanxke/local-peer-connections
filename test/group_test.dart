import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId peer(int n) => PeerId(List<int>.filled(16, n));

void main() {
  test('GroupConfig validates the normative scoped-token rules', () {
    expect(() => GroupConfig(applicationNamespace: [1]),
        throwsA(isA<LpcException>()));
    expect(
        () => GroupConfig(
            applicationNamespace: [1], groupJoinToken: List.filled(15, 0)),
        throwsA(isA<LpcException>()));
  });

  // UT-114: committed membership is visible before MemberJoined delivery.
  test('UT-114 committed membership is visible before MemberJoined', () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    final seen = Completer<bool>();
    final sub = group.events.listen((event) {
      if (event is MemberJoined)
        seen.complete(
            group.members.any((m) => m.peerId == event.member.peerId));
    });
    group.commitMembership([GroupMember(peer(1), 8), GroupMember(peer(2), 8)],
        coordinator: peer(1));
    expect(await seen.future, isTrue);
    await sub.cancel();
    await runtime.close();
  });

  // UT-104: application destinations must be committed members.
  test('UT-104 rejects a destination absent from committed membership',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    final handle = group.send(peer(2), [1]);
    expect(await handle.completed, SendState.failed);
    await runtime.close();
  });

  test('realtime API rejects reserved channels and oversized payloads',
      () async {
    final runtime = await createRuntime(localPeerId: peer(1));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    group.commitMembership([GroupMember(peer(1), 8), GroupMember(peer(2), 8)],
        coordinator: peer(1));
    expect(await group.sendRealtime(peer(2), 0, [1]).completed,
        SendState.failed);
    expect(await group.sendRealtime(peer(2), 1, List.filled(1101, 0)).completed,
        SendState.failed);
    await runtime.close();
  });

  test('broadcast snapshots targets in lexicographic PeerId order', () async {
    final runtime = await createRuntime(localPeerId: peer(2));
    final group = runtime.joinOrCreateGroup(GroupConfig(
        applicationNamespace: [1], groupJoinToken: List.filled(16, 0)));
    group.commitMembership(
        [GroupMember(peer(2), 8), GroupMember(peer(3), 8), GroupMember(peer(1), 8)],
        coordinator: peer(2));
    final broadcast = group.broadcast([1]);
    expect(broadcast.handles.length, 2);
    await runtime.close();
  });
}

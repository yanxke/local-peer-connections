import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId publicationPeer(int value) => PeerId(List<int>.filled(16, value));

GroupConfig checkpointConfig() => GroupConfig(
      applicationNamespace: [1],
      groupJoinToken: List<int>.filled(16, 0),
      coordinatorCheckpointing: true,
    );

void commitPeers(GroupSession group, Iterable<PeerId> peers) {
  group.commitMembership(
    [
      GroupMember(group.localPeerId, 8),
      for (final peerId in peers) GroupMember(peerId, 8),
    ],
    coordinator: group.localPeerId,
  );
}

void main() {
  test('UT-224/225 publication ids and required peers are local metadata', () {
    final group = GroupSession.internal(checkpointConfig(), publicationPeer(1),
        GroupId(List<int>.filled(16, 2)));
    final requiredPeer = publicationPeer(2);
    commitPeers(group, [requiredPeer]);

    final handle = group.publishCoordinatorCheckpoint([1, 2, 3]);

    expect(handle.publicationId, 1);
    expect(handle.coordinatorTerm, 0);
    expect(handle.requiredPeerIds, {requiredPeer});
    expect(handle.perPeerResults[requiredPeer], CheckpointPeerResult.pending);
    expect(group.latestCoordinatorCheckpoint(), [1, 2, 3]);
  });

  test('UT-226 explicit peer validation is atomic', () {
    final group = GroupSession.internal(checkpointConfig(), publicationPeer(1),
        GroupId(List<int>.filled(16, 2)));
    final requiredPeer = publicationPeer(2);
    commitPeers(group, [requiredPeer]);

    expect(
      () => group.publishCoordinatorCheckpoint(
        [1],
        options: CheckpointPublishOptions(
          acknowledgementRequirement:
              CheckpointAcknowledgementRequirement.explicitPeers,
          explicitPeerIds: [requiredPeer, requiredPeer],
        ),
      ),
      throwsA(isA<LpcException>()
          .having((error) => error.code, 'code', LpcErrorCode.invalidArgument)),
    );
    final handle = group.publishCoordinatorCheckpoint([2],
        options: CheckpointPublishOptions(
            acknowledgementRequirement:
                CheckpointAcknowledgementRequirement.none));
    expect(handle.publicationId, 1);
    expect(group.latestCoordinatorCheckpoint(), [2]);
  });

  test('UT-229 NONE completes immediately and does not need an ACK', () async {
    final group = GroupSession.internal(checkpointConfig(), publicationPeer(1),
        GroupId(List<int>.filled(16, 2)));

    final handle = group.publishCoordinatorCheckpoint(
      [4],
      options: CheckpointPublishOptions(
          acknowledgementRequirement:
              CheckpointAcknowledgementRequirement.none),
    );

    expect(handle.status, CheckpointPublicationStatus.durable);
    expect(handle.isTerminal, isTrue);
    final result = await handle.completion;
    expect(result.status, CheckpointPublicationStatus.durable);
    expect(result.perPeerResults, isEmpty);
  });

  test('UT-227/COORD-072 becomes durable only after the required ACK',
      () async {
    final group = GroupSession.internal(checkpointConfig(), publicationPeer(1),
        GroupId(List<int>.filled(16, 2)));
    final requiredPeer = publicationPeer(2);
    commitPeers(group, [requiredPeer]);
    final events = <GroupEvent>[];
    final subscription = group.events.listen(events.add);
    final handle = group.publishCoordinatorCheckpoint([5]);

    group.checkpointOperationStarted(handle, requiredPeer);
    expect(handle.status, CheckpointPublicationStatus.pending);
    group.checkpointOperationFinished(
        handle, requiredPeer, CheckpointPeerResult.acknowledged,
        checkpointSequence: 1);

    final result = await handle.completion;
    expect(result.status, CheckpointPublicationStatus.durable);
    expect(
        result.perPeerResults[requiredPeer], CheckpointPeerResult.acknowledged);
    expect(events.whereType<CoordinatorCheckpointReplicationAcknowledged>(),
        hasLength(1));
    expect(events.whereType<CoordinatorCheckpointPublicationCompleted>(),
        hasLength(1));
    await subscription.cancel();
  });

  test('UT-228 ACKs are correlated to the exact publication and peer',
      () async {
    final group = GroupSession.internal(checkpointConfig(), publicationPeer(1),
        GroupId(List<int>.filled(16, 2)));
    final firstPeer = publicationPeer(2);
    final secondPeer = publicationPeer(3);
    commitPeers(group, [firstPeer, secondPeer]);
    final first = group.publishCoordinatorCheckpoint([13]);
    group.checkpointOperationStarted(first, firstPeer);
    group.checkpointOperationStarted(first, secondPeer);
    final newer = group.publishCoordinatorCheckpoint([14]);
    group.checkpointOperationStarted(newer, firstPeer);

    group.checkpointOperationFinished(
        newer, firstPeer, CheckpointPeerResult.acknowledged,
        checkpointSequence: 1);
    group.checkpointOperationFinished(
        first, publicationPeer(4), CheckpointPeerResult.acknowledged,
        checkpointSequence: 1);
    expect(first.status, CheckpointPublicationStatus.pending);
    group.checkpointOperationFinished(
        first, firstPeer, CheckpointPeerResult.acknowledged,
        checkpointSequence: 1);
    expect(first.status, CheckpointPublicationStatus.pending);
    group.checkpointOperationFinished(
        first, secondPeer, CheckpointPeerResult.acknowledged,
        checkpointSequence: 1);
    expect(
        (await first.completion).status, CheckpointPublicationStatus.durable);
  });

  test('UT-230/231 membership removal uses the publication snapshot', () async {
    final group = GroupSession.internal(checkpointConfig(), publicationPeer(1),
        GroupId(List<int>.filled(16, 2)));
    final removedPeer = publicationPeer(2);
    commitPeers(group, [removedPeer]);
    final handle = group.publishCoordinatorCheckpoint([6]);

    group.commitMembership([GroupMember(group.localPeerId, 8)],
        coordinator: group.localPeerId);

    final result = await handle.completion;
    expect(result.status, CheckpointPublicationStatus.failed);
    expect(result.perPeerResults[removedPeer], CheckpointPeerResult.peerLeft);

    final next = group.publishCoordinatorCheckpoint([7]);
    expect(next.requiredPeerIds, isEmpty);
    expect(next.status, CheckpointPublicationStatus.durable);
  });

  test('UT-232 supersedes an unstarted publication but not an in-flight one',
      () async {
    final group = GroupSession.internal(checkpointConfig(), publicationPeer(1),
        GroupId(List<int>.filled(16, 2)));
    final requiredPeer = publicationPeer(2);
    commitPeers(group, [requiredPeer]);

    final first = group.publishCoordinatorCheckpoint([8]);
    final second = group.publishCoordinatorCheckpoint([9]);
    final firstResult = await first.completion;
    expect(firstResult.perPeerResults[requiredPeer],
        CheckpointPeerResult.superseded);

    group.checkpointOperationStarted(second, requiredPeer);
    final third = group.publishCoordinatorCheckpoint([10]);
    expect(second.status, CheckpointPublicationStatus.pending);
    group.checkpointOperationFinished(
        second, requiredPeer, CheckpointPeerResult.acknowledged,
        checkpointSequence: 2);
    expect(
        (await second.completion).status, CheckpointPublicationStatus.durable);
    expect(third.status, CheckpointPublicationStatus.pending);
  });

  test('UT-234 checkpoint ACK timeout fails the publication', () async {
    final group = GroupSession.internal(checkpointConfig(), publicationPeer(1),
        GroupId(List<int>.filled(16, 2)));
    final requiredPeer = publicationPeer(2);
    commitPeers(group, [requiredPeer]);
    final handle = group.publishCoordinatorCheckpoint([15]);
    group.checkpointOperationStarted(handle, requiredPeer);
    group.checkpointOperationFinished(
        handle, requiredPeer, CheckpointPeerResult.ackTimeout,
        checkpointSequence: 1);
    final result = await handle.completion;
    expect(result.status, CheckpointPublicationStatus.failed);
    expect(
        result.perPeerResults[requiredPeer], CheckpointPeerResult.ackTimeout);
  });

  test('UT-234 authority loss and UT-236 close fail pending handles', () async {
    final group = GroupSession.internal(checkpointConfig(), publicationPeer(1),
        GroupId(List<int>.filled(16, 2)));
    final requiredPeer = publicationPeer(2);
    commitPeers(group, [requiredPeer]);
    final authorityLost = group.publishCoordinatorCheckpoint([11]);
    group.commitMembership(
      [GroupMember(group.localPeerId, 8), GroupMember(requiredPeer, 8)],
      coordinator: requiredPeer,
      coordinatorTerm: 1,
    );
    expect((await authorityLost.completion).perPeerResults[requiredPeer],
        CheckpointPeerResult.authorityLost);

    group.commitMembership(
      [GroupMember(group.localPeerId, 8), GroupMember(requiredPeer, 8)],
      coordinator: group.localPeerId,
      coordinatorTerm: 2,
    );
    final closed = group.publishCoordinatorCheckpoint([12]);
    group.leave();
    expect((await closed.completion).perPeerResults[requiredPeer],
        CheckpointPeerResult.groupClosed);
  });

  test('UT-237 a later member does not enlarge a publication', () async {
    final group = GroupSession.internal(checkpointConfig(), publicationPeer(1),
        GroupId(List<int>.filled(16, 2)));
    final originalPeer = publicationPeer(2);
    final joiningPeer = publicationPeer(3);
    commitPeers(group, [originalPeer]);
    final handle = group.publishCoordinatorCheckpoint([16]);
    commitPeers(group, [originalPeer, joiningPeer]);
    expect(handle.requiredPeerIds, {originalPeer});
    group.checkpointOperationStarted(handle, originalPeer);
    group.checkpointOperationFinished(
        handle, originalPeer, CheckpointPeerResult.acknowledged,
        checkpointSequence: 1);
    expect(
        (await handle.completion).status, CheckpointPublicationStatus.durable);
  });

  test(
      'UT-238 terminal results are immutable and duplicate transitions are no-ops',
      () async {
    final group = GroupSession.internal(checkpointConfig(), publicationPeer(1),
        GroupId(List<int>.filled(16, 2)));
    final requiredPeer = publicationPeer(2);
    commitPeers(group, [requiredPeer]);
    final events = <GroupEvent>[];
    final subscription = group.events.listen(events.add);
    final handle = group.publishCoordinatorCheckpoint([17]);
    group.checkpointOperationStarted(handle, requiredPeer);
    group.checkpointOperationFinished(
        handle, requiredPeer, CheckpointPeerResult.acknowledged,
        checkpointSequence: 1);
    final result = await handle.completion;
    expect(() => result.requiredPeerIds.add(publicationPeer(3)),
        throwsUnsupportedError);
    expect(
        () =>
            result.perPeerResults[requiredPeer] = CheckpointPeerResult.peerLeft,
        throwsUnsupportedError);
    group.checkpointOperationFinished(
        handle, requiredPeer, CheckpointPeerResult.peerLeft,
        checkpointSequence: 1);
    expect(events.whereType<CoordinatorCheckpointPublicationCompleted>(),
        hasLength(1));
    await subscription.cancel();
  });

  test('UT-240 publication id exhaustion is explicit', () {
    final group = GroupSession.internal(
      checkpointConfig(),
      publicationPeer(1),
      GroupId(List<int>.filled(16, 2)),
      nextCheckpointPublicationId: 0x7fffffffffffffff - 1,
    );
    final options = CheckpointPublishOptions(
        acknowledgementRequirement: CheckpointAcknowledgementRequirement.none);
    expect(
        group.publishCoordinatorCheckpoint([1], options: options).publicationId,
        0x7fffffffffffffff - 1);
    expect(
        group.publishCoordinatorCheckpoint([2], options: options).publicationId,
        0x7fffffffffffffff);
    expect(
      () => group.publishCoordinatorCheckpoint([3], options: options),
      throwsA(isA<LpcException>().having(
          (error) => error.code, 'code', LpcErrorCode.resourceExhausted)),
    );
  });

  test('UT-242 required application validation is retained on the handle', () {
    final group = GroupSession.internal(checkpointConfig(), publicationPeer(1),
        GroupId(List<int>.filled(16, 2)));
    final peer = publicationPeer(2);
    commitPeers(group, [peer]);
    final version = group.membershipView().version;
    final handle = group.publishCoordinatorCheckpoint([1],
        options: CheckpointPublishOptions(
            applicationValidationRequirement:
                CheckpointApplicationValidationRequirement.required));
    expect(handle.applicationValidationRequirement,
        CheckpointApplicationValidationRequirement.required);
    expect(handle.acceptedMembershipVersion, version);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  final target = PeerId(List.filled(16, 1));

  test('UT-051/COORD-035 snapshot timeout unsynchronizes and reconnects', () {
    final recovery = GroupControlTimeoutRecovery();
    final action = recovery.onFinalAckTimeout(
      type: FrameType.membershipSnapshot,
      peerId: target,
    );
    expect(action, isA<MembershipSnapshotTimeoutRecovery>());
    expect((action as MembershipSnapshotTimeoutRecovery).closeError,
        LpcErrorCode.groupStateSyncFailed);
    expect(action.requiresReconnectAndResync, isTrue);
    expect(recovery.syncState(target), GroupSyncState.unsynchronized);
  });

  test('UT-052/COORD-036 merge timeout preserves commit and reboots target',
      () {
    final recovery = GroupControlTimeoutRecovery();
    final action = recovery.onFinalAckTimeout(
      type: FrameType.groupMerge,
      peerId: target,
    );
    expect(action, isA<GroupMergeTimeoutRecovery>());
    expect((action as GroupMergeTimeoutRecovery).closeError,
        LpcErrorCode.groupStateSyncFailed);
    expect(action.requiresRebootstrap, isTrue);
    expect(recovery.syncState(target), GroupSyncState.unsynchronized);
  });

  test('UT-053/COORD-037 checkpoint timeout reports without disconnecting', () {
    final recovery = GroupControlTimeoutRecovery();
    final action = recovery.onFinalAckTimeout(
      type: FrameType.coordinatorCheckpoint,
      peerId: target,
      checkpointSequence: 3,
    );
    expect(action, isA<CheckpointReplicationTimeoutRecovery>());
    expect(
        (action as CheckpointReplicationTimeoutRecovery).checkpointSequence, 3);
    expect(action.reportsReplicationFailure, isTrue);
    expect(recovery.syncState(target), GroupSyncState.synchronized);
  });
}

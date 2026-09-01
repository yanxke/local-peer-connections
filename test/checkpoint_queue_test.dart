import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-090/COORD-044 slow peer receives A then C, never B', () {
    final queue = CheckpointReplicationQueue();
    final a = queue.publish([1])!;
    expect(a.sequence, 1);
    queue.publish([2]);
    queue.publish([3]);
    final c = queue.completeInFlight()!;
    expect(c.sequence, 2);
    expect(c.bytes, [3]);
  });
  test('UT-091/COORD-043 holds one in-flight and one pending checkpoint', () {
    final queue = CheckpointReplicationQueue();
    queue.publish([1]);
    queue.publish([2]);
    queue.publish([3]);
    expect(queue.inFlight!.bytes, [1]);
    expect(queue.hasPending, isTrue);
  });

  test('UT-092 preserves an ACK-required checkpoint already in flight', () {
    final queue = CheckpointReplicationQueue();
    final a = queue.publish([1])!;
    queue.publish([2]);
    expect(queue.inFlight, same(a));
    expect(queue.inFlight!.bytes, [1]);
  });

  test('UT-093/094/095 promote only the latest pending checkpoint without gap',
      () {
    final queue = CheckpointReplicationQueue();
    expect(queue.publish([1])!.sequence, 1);
    queue.publish([2]);
    queue.publish([3]); // Replaces [2] before it owns a sequence.
    final promoted = queue.completeInFlight()!;
    expect(promoted.bytes, [3]);
    expect(promoted.sequence, 2);
  });

  test('UT-096/COORD-045 reconnected peer receives only retained latest', () {
    final replicator = CoordinatorCheckpointReplicator();
    replicator.publish([1], const []);
    replicator.publish([2], const []);
    final operation = replicator.peerReady(PeerId(List.filled(16, 7)))!;
    expect(operation.sequence, 1);
    expect(operation.bytes, [2]);
  });

  test('UT-097/COORD-046 peers promote checkpoint values independently', () {
    final a = PeerId(List.filled(16, 1));
    final b = PeerId(List.filled(16, 2));
    final replicator = CoordinatorCheckpointReplicator();
    final first = replicator.publish([1], [a, b]);
    expect(first[a]!.sequence, 1);
    expect(first[b]!.sequence, 1);

    // A advances while B remains in flight; the same publication therefore
    // becomes in-flight for A but remains pending for B.
    expect(replicator.completeInFlight(a), isNull);
    final second = replicator.publish([2], [a, b]);
    expect(second[a]!.sequence, 2);
    expect(second.containsKey(b), isFalse);
    final bPromotion = replicator.completeInFlight(b)!;
    expect(bPromotion.sequence, 2);
    expect(bPromotion.bytes, [2]);
  });
}

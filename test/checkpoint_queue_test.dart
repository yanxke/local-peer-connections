import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-090 only inflight A and latest pending C are promoted', () {
    final queue = CheckpointReplicationQueue();
    final a = queue.publish([1])!;
    expect(a.sequence, 1);
    queue.publish([2]);
    queue.publish([3]);
    final c = queue.completeInFlight()!;
    expect(c.sequence, 2);
    expect(c.bytes, [3]);
  });
  test('UT-091 holds at most one in-flight and one pending value', () {
    final queue = CheckpointReplicationQueue();
    queue.publish([1]);
    queue.publish([2]);
    queue.publish([3]);
    expect(queue.inFlight!.bytes, [1]);
    expect(queue.hasPending, isTrue);
  });
}

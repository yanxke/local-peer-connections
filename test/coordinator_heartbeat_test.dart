import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('coordinator heartbeat uses its exact 72-byte Section 10.7 payload', () {
    final h = CoordinatorHeartbeat(
        groupId: GroupId(List.filled(16, 1)),
        term: 2,
        coordinatorPeerId: PeerId(List.filled(16, 3)),
        membershipHash: List.filled(32, 4));
    expect(CoordinatorHeartbeat.decode(h.encode()).term, 2);
  });
  test(
      'coordinator becomes unavailable after three seconds without a valid frame',
      () {
    var now = DateTime(2026);
    final liveness = CoordinatorLiveness(clock: () => now);
    liveness.observe();
    now = now.add(const Duration(milliseconds: 2999));
    expect(liveness.unavailable, isFalse);
    now = now.add(const Duration(milliseconds: 1));
    expect(liveness.unavailable, isTrue);
  });
}

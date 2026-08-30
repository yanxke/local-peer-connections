import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  // UT-041: counter value 1 is used first.
  test('UT-041 allocates counter one first', () {
    final ids = MessageIdAllocator([1, 2, 3, 4]);
    expect(ids.allocate(), [1, 2, 3, 4, 0, 0, 0, 1]);
  });
  // UT-020/021: duplicates are accepted once and collisions fail.
  test('dedup accepts duplicate content but rejects collisions', () {
    final dedup = CompletedMessageDedup(capacity: 2);
    expect(dedup.accept(List.filled(8, 1), [9]), isTrue);
    expect(dedup.accept(List.filled(8, 1), [9]), isFalse);
    expect(() => dedup.accept(List.filled(8, 1), [8]),
        throwsA(isA<LpcException>()));
  });
}

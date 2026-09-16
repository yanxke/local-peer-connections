import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test(
      'Section 6.1 GroupMessageId starts with counter one in network byte order',
      () {
    final allocator = GroupMessageIdAllocator([1, 2, 3, 4, 5, 6, 7, 8]);
    expect(allocator.allocate().bytes,
        [1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0, 0, 0, 0, 1]);
  });
  test('GroupMessageIds remain distinct from eight byte hop MessageIds', () {
    expect(
        GroupMessageIdAllocator(List.filled(8, 0)).allocate().bytes.length, 16);
    expect(MessageIdAllocator(List.filled(4, 0)).allocate().length, 8);
  });
}

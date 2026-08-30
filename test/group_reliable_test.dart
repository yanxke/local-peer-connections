import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('GROUP_RELIABLE preserves end-to-end IDs and uses 16300-byte chunks',
      () {
    final chunks = chunkGroupReliable(
        groupId: GroupId(List.filled(16, 1)),
        source: PeerId(List.filled(16, 2)),
        destination: PeerId(List.filled(16, 3)),
        messageId: GroupMessageId(List.filled(16, 4)),
        mode: DeliveryMode.reliableAcked,
        priority: SendPriority.interactive,
        bytes: List.filled(16301, 9));
    expect(chunks.length, 2);
    expect(chunks.first.encode().length, 84 + 16300);
    expect(GroupReliableChunk.decode(chunks.last.encode()).groupMessageId,
        chunks.last.groupMessageId);
  });
  test('GROUP_RELIABLE encodes zero bytes as one zero-length chunk', () {
    final chunks = chunkGroupReliable(
        groupId: GroupId(List.filled(16, 1)),
        source: PeerId(List.filled(16, 2)),
        destination: PeerId(List.filled(16, 3)),
        messageId: GroupMessageId(List.filled(16, 4)),
        mode: DeliveryMode.reliableOrdered,
        priority: SendPriority.normal,
        bytes: []);
    expect(chunks.single.bytes, isEmpty);
    expect(chunks.single.chunkCount, 1);
  });
}

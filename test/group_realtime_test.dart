import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test(
      'GROUP_REALTIME_DATAGRAM preserves original source and fixed header fields',
      () {
    final d = GroupRealtimeDatagram(
        groupId: GroupId(List.filled(16, 1)),
        sourcePeerId: PeerId(List.filled(16, 2)),
        destinationPeerId: PeerId(List.filled(16, 3)),
        channelId: 1,
        sequence: 1,
        senderTick: 9,
        bytes: [7]);
    expect(
        GroupRealtimeDatagram.decode(d.encode()).sourcePeerId, d.sourcePeerId);
  });
  test('per destination/channel sequences are independent', () {
    final allocator = GroupRealtimeSequenceAllocator();
    final a = PeerId(List.filled(16, 1));
    final b = PeerId(List.filled(16, 2));
    expect(allocator.allocate(a, 1), 1);
    expect(allocator.allocate(a, 1), 2);
    expect(allocator.allocate(b, 1), 1);
  });
}

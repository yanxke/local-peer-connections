import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  // UT-016: one MiB is split using the frozen 16,364-byte chunk limit.
  test('UT-016 chunks a 1 MiB application message exactly', () {
    final chunks = chunkData(List<int>.filled(maxApplicationMessageBytes, 3),
        mode: DeliveryMode.reliableAcked, priority: SendPriority.interactive);
    expect(chunks.length, 65);
    expect(chunks.first.bytes.length, maxDataChunkBytes);
    expect(chunks.last.chunkOffset + chunks.last.bytes.length,
        maxApplicationMessageBytes);
    expect(DataChunk.decode(chunks.last.encode()).chunkIndex, 64);
  });

  test('realtime layout uses the Section 22 big-endian fields', () {
    final encoded =
        RealtimeDatagram(channelId: 1, sequence: 2, senderTick: 3, bytes: [4])
            .encode();
    expect(encoded, [0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 1, 4]);
    expect(RealtimeDatagram.decode(encoded).senderTick, 3);
  });

  test('realtime rejects payloads larger than 1100 bytes', () {
    expect(
        () => RealtimeDatagram(
            channelId: 1,
            sequence: 1,
            senderTick: 0,
            bytes: List.filled(1101, 0)),
        throwsA(isA<LpcException>()));
  });
}

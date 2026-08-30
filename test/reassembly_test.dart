import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  // UT-075/076: incomplete DATA never crosses a transport generation.
  test('UT-075 clears incomplete reliable DATA on transport loss', () {
    final bytes = List<int>.filled(maxDataChunkBytes + 2, 7);
    final chunks = chunkData(bytes,
        mode: DeliveryMode.reliableOrdered, priority: SendPriority.normal);
    final receiver = DataReassembler();
    expect(receiver.add(List.filled(8, 1), chunks.first), isNull);
    receiver.onTransportGenerationLost();
    expect(receiver.add(List.filled(8, 1), chunks.last), isNull);
    expect(receiver.add(List.filled(8, 1), chunks.first)!.bytes, bytes);
  });

  test('reassembly rejects conflicting duplicate chunks', () {
    final receiver = DataReassembler();
    final original = chunkData(List.filled(maxDataChunkBytes + 1, 1),
            mode: DeliveryMode.reliableAcked, priority: SendPriority.normal)
        .first;
    receiver.add(List.filled(8, 2), original);
    final conflict = DataChunk(
        deliveryMode: original.deliveryMode,
        priority: original.priority,
        chunkIndex: 0,
        chunkCount: original.chunkCount,
        totalLength: original.totalLength,
        chunkOffset: 0,
        bytes: List.filled(maxDataChunkBytes, 2));
    expect(() => receiver.add(List.filled(8, 2), conflict),
        throwsA(isA<LpcException>()));
  });

  test('realtime filter accepts newer uint32 values including wraparound', () {
    final filter = RealtimeSequenceFilter();
    RealtimeDatagram packet(int seq) =>
        RealtimeDatagram(channelId: 1, sequence: seq, senderTick: 0, bytes: []);
    expect(filter.accept(packet(0xffffffff)), isTrue);
    expect(filter.accept(packet(0)), isTrue);
    expect(filter.accept(packet(0xffffffff)), isFalse);
  });
}

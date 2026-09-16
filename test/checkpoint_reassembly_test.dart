import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-045 checkpoint completes only after all chunks', () {
    final chunks = chunkCheckpoint(List.filled(4001, 1), term: 2, sequence: 3);
    final receiver = CheckpointReassembler();
    expect(receiver.add(List.filled(8, 1), chunks.first), isNull);
    expect(receiver.add(List.filled(8, 1), chunks.last)!.bytes.length, 4001);
  });
  test('UT-060 discards incomplete checkpoint on transport loss', () {
    final chunks = chunkCheckpoint(List.filled(4001, 1), term: 2, sequence: 3);
    final receiver = CheckpointReassembler();
    receiver.add(List.filled(8, 1), chunks.first);
    receiver.onTransportGenerationLost();
    expect(receiver.add(List.filled(8, 1), chunks.last), isNull);
  });
}

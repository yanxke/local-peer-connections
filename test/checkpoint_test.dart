import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-043 checkpoint chunks remain at most 4032-byte control plaintext',
      () {
    final chunks = chunkCheckpoint(List.filled(4001, 1), term: 1, sequence: 1);
    expect(chunks.first.encode().length, 4032);
    expect(
        CoordinatorCheckpointChunk.decode(chunks.last.encode()).chunkIndex, 1);
  });
  test('zero checkpoint is exactly one zero-byte chunk', () {
    expect(chunkCheckpoint([], term: 1, sequence: 1).single.bytes, isEmpty);
  });
}

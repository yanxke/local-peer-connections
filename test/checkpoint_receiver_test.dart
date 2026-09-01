import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-045/046 checkpoint commits once and completed duplicate ACKs again',
      () {
    final receiver = CheckpointReceiver();
    final id = List<int>.filled(8, 5);
    final chunks =
        chunkCheckpoint(List<int>.filled(4001, 1), term: 2, sequence: 3);
    var commits = 0;
    expect(
        receiver
            .add(id, chunks.first, commit: (_) => commits++)
            .acknowledgmentMessageId,
        isNull);
    final complete = receiver.add(id, chunks.last, commit: (_) => commits++);
    expect(commits, 1);
    expect(complete.committed!.bytes, hasLength(4001));
    expect(complete.acknowledgmentMessageId, id);
    expect(
        receiver
            .add(id, chunks.first, commit: (_) => commits++)
            .acknowledgmentMessageId,
        isNull);
    final duplicate = receiver.add(id, chunks.last, commit: (_) => commits++);
    expect(duplicate.isDuplicate, isTrue);
    expect(duplicate.acknowledgmentMessageId, id);
    expect(commits, 1);
  });
}

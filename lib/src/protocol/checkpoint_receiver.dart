import 'checkpoint.dart';
import 'checkpoint_reassembly.dart';
import 'reliability.dart';

class CheckpointReceiveResult {
  const CheckpointReceiveResult._(
      {this.committed, this.acknowledgmentMessageId});
  const CheckpointReceiveResult.incomplete() : this._();
  CheckpointReceiveResult.committed(
      ReassembledCheckpoint checkpoint, List<int> messageId)
      : this._(
            committed: checkpoint,
            acknowledgmentMessageId: List<int>.unmodifiable(messageId));
  CheckpointReceiveResult.duplicate(List<int> messageId)
      : this._(acknowledgmentMessageId: List<int>.unmodifiable(messageId));

  final ReassembledCheckpoint? committed;
  final List<int>? acknowledgmentMessageId;
  bool get isDuplicate => committed == null && acknowledgmentMessageId != null;
}

/// Section 23 checkpoint completion. [commit] runs exactly once for a new
/// complete checkpoint; only successful commit produces an ACK-eligible
/// result. The owner serializes calls for one receive direction.
class CheckpointReceiver {
  CheckpointReceiver(
      {CheckpointReassembler? reassembler, CompletedMessageDedup? dedup})
      : _reassembler = reassembler ?? CheckpointReassembler(),
        _dedup = dedup ?? CompletedMessageDedup();

  final CheckpointReassembler _reassembler;
  final CompletedMessageDedup _dedup;

  CheckpointReceiveResult add(
    List<int> messageId,
    CoordinatorCheckpointChunk chunk, {
    required void Function(ReassembledCheckpoint checkpoint) commit,
  }) {
    final complete = _reassembler.add(messageId, chunk);
    if (complete == null) return const CheckpointReceiveResult.incomplete();
    final canonical = <int>[
      for (final part in chunkCheckpoint(complete.bytes,
          term: complete.term, sequence: complete.sequence))
        ...part.encode()
    ];
    if (_dedup.isDuplicate(messageId, canonical)) {
      return CheckpointReceiveResult.duplicate(messageId);
    }
    commit(complete);
    _dedup.accept(messageId, canonical);
    return CheckpointReceiveResult.committed(complete, messageId);
  }

  void onTransportGenerationLost() => _reassembler.onTransportGenerationLost();
}

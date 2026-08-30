import 'dart:typed_data';
import '../types.dart';
import 'checkpoint.dart';

class ReassembledCheckpoint {
  ReassembledCheckpoint(
      {required List<int> messageId,
      required this.term,
      required this.sequence,
      required List<int> bytes})
      : messageId = Uint8List.fromList(messageId),
        bytes = Uint8List.fromList(bytes);
  final Uint8List messageId, bytes;
  final int term, sequence;
}

class CheckpointReassembler {
  CheckpointReassembler({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  final Map<String, _PartialCheckpoint> _pending = {};
  ReassembledCheckpoint? add(
      List<int> messageId, CoordinatorCheckpointChunk chunk) {
    if (messageId.length != 8)
      throw ArgumentError.value(messageId, 'messageId');
    expireInactive();
    final key = messageId.join(',');
    final partial =
        _pending.putIfAbsent(key, () => _PartialCheckpoint(chunk, _clock()));
    partial.add(chunk, _clock());
    if (!partial.complete) return null;
    _pending.remove(key);
    return ReassembledCheckpoint(
        messageId: messageId,
        term: partial.term,
        sequence: partial.sequence,
        bytes: partial.join());
  }

  void onTransportGenerationLost() => _pending.clear();
  void expireInactive() {
    final cutoff = _clock().subtract(const Duration(seconds: 10));
    _pending.removeWhere((_, value) => value.updated.isBefore(cutoff));
  }
}

class _PartialCheckpoint {
  _PartialCheckpoint(CoordinatorCheckpointChunk first, this.updated)
      : term = first.term,
        sequence = first.sequence,
        totalLength = first.totalLength,
        chunkCount = first.chunkCount,
        chunks = List<Uint8List?>.filled(first.chunkCount, null);
  final int term, sequence, totalLength, chunkCount;
  final List<Uint8List?> chunks;
  DateTime updated;
  void add(CoordinatorCheckpointChunk chunk, DateTime now) {
    if (chunk.term != term ||
        chunk.sequence != sequence ||
        chunk.totalLength != totalLength ||
        chunk.chunkCount != chunkCount)
      throw const LpcException(LpcErrorCode.messageIdCollision);
    final old = chunks[chunk.chunkIndex];
    if (old != null && !_same(old, chunk.bytes))
      throw const LpcException(LpcErrorCode.messageIdCollision);
    chunks[chunk.chunkIndex] ??= chunk.bytes;
    updated = now;
  }

  bool get complete => chunks.every((c) => c != null);
  Uint8List join() {
    final output = Uint8List(totalLength);
    var offset = 0;
    for (final c in chunks) {
      output.setRange(offset, offset + c!.length, c);
      offset += c.length;
    }
    return output;
  }

  bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var x = 0;
    for (var i = 0; i < a.length; i++) {
      x |= a[i] ^ b[i];
    }
    return x == 0;
  }
}

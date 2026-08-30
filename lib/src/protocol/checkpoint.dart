import 'dart:typed_data';
import '../types.dart';

const int maxCoordinatorCheckpointBytes = 262144;
const int maxCoordinatorCheckpointChunkBytes = 4000;

class CoordinatorCheckpointChunk {
  CoordinatorCheckpointChunk(
      {required this.term,
      required this.sequence,
      required this.totalLength,
      required this.chunkIndex,
      required this.chunkCount,
      required this.chunkOffset,
      required List<int> bytes})
      : bytes = Uint8List.fromList(bytes) {
    final expected = totalLength == 0 ? 1 : (totalLength + 3999) ~/ 4000;
    if (totalLength < 0 ||
        totalLength > maxCoordinatorCheckpointBytes ||
        chunkCount != expected ||
        chunkIndex < 0 ||
        chunkIndex >= chunkCount ||
        chunkOffset != chunkIndex * 4000 ||
        this.bytes.length > 4000 ||
        (totalLength == 0 && this.bytes.isNotEmpty) ||
        (totalLength > 0 &&
            (this.bytes.isEmpty ||
                chunkOffset + this.bytes.length > totalLength)) ||
        (chunkIndex + 1 < chunkCount && this.bytes.length != 4000) ||
        (chunkIndex + 1 == chunkCount &&
            totalLength > 0 &&
            chunkOffset + this.bytes.length != totalLength))
      throw const LpcException(LpcErrorCode.protocolMismatch);
  }
  final int term, sequence, totalLength, chunkIndex, chunkCount, chunkOffset;
  final Uint8List bytes;
  Uint8List encode() {
    final h = ByteData(32)
      ..setUint64(0, term)
      ..setUint64(8, sequence)
      ..setUint32(16, totalLength)
      ..setUint16(20, chunkIndex)
      ..setUint16(22, chunkCount)
      ..setUint32(24, chunkOffset)
      ..setUint16(28, bytes.length);
    return Uint8List.fromList([...h.buffer.asUint8List(), ...bytes]);
  }

  static CoordinatorCheckpointChunk decode(List<int> input) {
    if (input.length < 32)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final h = ByteData.sublistView(Uint8List.fromList(input));
    if (h.getUint16(30) != 0 || input.length != 32 + h.getUint16(28))
      throw const LpcException(LpcErrorCode.protocolMismatch);
    return CoordinatorCheckpointChunk(
        term: h.getUint64(0),
        sequence: h.getUint64(8),
        totalLength: h.getUint32(16),
        chunkIndex: h.getUint16(20),
        chunkCount: h.getUint16(22),
        chunkOffset: h.getUint32(24),
        bytes: input.sublist(32));
  }
}

List<CoordinatorCheckpointChunk> chunkCheckpoint(List<int> bytes,
    {required int term, required int sequence}) {
  if (bytes.length > maxCoordinatorCheckpointBytes)
    throw const LpcException(LpcErrorCode.messageTooLarge);
  final count = bytes.isEmpty ? 1 : (bytes.length + 3999) ~/ 4000;
  return List.generate(count, (i) {
    final offset = i * 4000;
    return CoordinatorCheckpointChunk(
        term: term,
        sequence: sequence,
        totalLength: bytes.length,
        chunkIndex: i,
        chunkCount: count,
        chunkOffset: offset,
        bytes: bytes.sublist(
            offset,
            offset < bytes.length
                ? (offset + 4000).clamp(0, bytes.length)
                : offset));
  });
}

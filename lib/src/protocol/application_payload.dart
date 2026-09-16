import 'dart:typed_data';
import '../types.dart';

const int maxApplicationMessageBytes = 1048576;
const int maxDataChunkBytes = 16364;
const int maxRealtimePayloadBytes = 1100;

int _mode(DeliveryMode m) => switch (m) {
      DeliveryMode.reliableOrdered => 1,
      DeliveryMode.reliableAcked => 2,
      _ => throw ArgumentError('DATA cannot be realtime')
    };
DeliveryMode _decodeMode(int v) => switch (v) {
      1 => DeliveryMode.reliableOrdered,
      2 => DeliveryMode.reliableAcked,
      _ => throw const LpcException(LpcErrorCode.protocolMismatch)
    };
int _priority(SendPriority p) => p.index + 1;
SendPriority _decodePriority(int p) => p >= 1 && p <= 3
    ? SendPriority.values[p - 1]
    : throw const LpcException(LpcErrorCode.protocolMismatch);

class DataChunk {
  DataChunk(
      {required this.deliveryMode,
      required this.priority,
      required this.chunkIndex,
      required this.chunkCount,
      required this.totalLength,
      required this.chunkOffset,
      required List<int> bytes})
      : bytes = Uint8List.fromList(bytes) {
    final count = (totalLength + maxDataChunkBytes - 1) ~/ maxDataChunkBytes;
    if (totalLength < 1 ||
        totalLength > maxApplicationMessageBytes ||
        chunkCount != count ||
        chunkIndex < 0 ||
        chunkIndex >= count ||
        chunkOffset != chunkIndex * maxDataChunkBytes ||
        this.bytes.isEmpty ||
        this.bytes.length > maxDataChunkBytes ||
        chunkOffset + this.bytes.length > totalLength ||
        (chunkIndex + 1 < count && this.bytes.length != maxDataChunkBytes) ||
        (chunkIndex + 1 == count &&
            chunkOffset + this.bytes.length != totalLength))
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid DATA chunk');
  }
  final DeliveryMode deliveryMode;
  final SendPriority priority;
  final int chunkIndex, chunkCount, totalLength, chunkOffset;
  final Uint8List bytes;
  Uint8List encode() {
    final h = ByteData(20);
    h.setUint8(0, _mode(deliveryMode));
    h.setUint8(1, _priority(priority));
    h.setUint16(2, chunkIndex);
    h.setUint16(4, chunkCount);
    h.setUint32(8, totalLength);
    h.setUint32(12, chunkOffset);
    h.setUint16(16, bytes.length);
    return Uint8List.fromList([...h.buffer.asUint8List(), ...bytes]);
  }

  static DataChunk decode(List<int> input) {
    if (input.length < 20)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final raw = Uint8List.fromList(input);
    final h = ByteData.sublistView(raw);
    if (h.getUint16(6) != 0 ||
        h.getUint16(18) != 0 ||
        input.length != 20 + h.getUint16(16))
      throw const LpcException(LpcErrorCode.protocolMismatch);
    return DataChunk(
        deliveryMode: _decodeMode(h.getUint8(0)),
        priority: _decodePriority(h.getUint8(1)),
        chunkIndex: h.getUint16(2),
        chunkCount: h.getUint16(4),
        totalLength: h.getUint32(8),
        chunkOffset: h.getUint32(12),
        bytes: raw.sublist(20));
  }
}

List<DataChunk> chunkData(List<int> bytes,
    {required DeliveryMode mode, required SendPriority priority}) {
  if (mode == DeliveryMode.realtimeLatest ||
      bytes.isEmpty ||
      bytes.length > maxApplicationMessageBytes)
    throw const LpcException(LpcErrorCode.messageTooLarge);
  final count = (bytes.length + maxDataChunkBytes - 1) ~/ maxDataChunkBytes;
  return List.generate(count, (i) {
    final offset = i * maxDataChunkBytes;
    return DataChunk(
        deliveryMode: mode,
        priority: priority,
        chunkIndex: i,
        chunkCount: count,
        totalLength: bytes.length,
        chunkOffset: offset,
        bytes: bytes.sublist(
            offset, (offset + maxDataChunkBytes).clamp(0, bytes.length)));
  });
}

class RealtimeDatagram {
  RealtimeDatagram(
      {required this.channelId,
      required this.sequence,
      required this.senderTick,
      required List<int> bytes})
      : bytes = Uint8List.fromList(bytes) {
    if (channelId < 1 ||
        channelId > 65535 ||
        this.bytes.length > maxRealtimePayloadBytes)
      throw const LpcException(LpcErrorCode.messageTooLarge);
  }
  final int channelId, sequence, senderTick;
  final Uint8List bytes;
  Uint8List encode() {
    final h = ByteData(16)
      ..setUint16(0, channelId)
      ..setUint32(2, sequence)
      ..setUint64(6, senderTick)
      ..setUint16(14, bytes.length);
    return Uint8List.fromList([...h.buffer.asUint8List(), ...bytes]);
  }

  static RealtimeDatagram decode(List<int> input) {
    if (input.length < 16)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final raw = Uint8List.fromList(input);
    final h = ByteData.sublistView(raw);
    if (input.length != 16 + h.getUint16(14))
      throw const LpcException(LpcErrorCode.protocolMismatch);
    return RealtimeDatagram(
        channelId: h.getUint16(0),
        sequence: h.getUint32(2),
        senderTick: h.getUint64(6),
        bytes: raw.sublist(16));
  }
}

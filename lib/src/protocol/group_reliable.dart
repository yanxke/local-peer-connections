import 'dart:typed_data';
import '../types.dart';

const int maxGroupReliableChunkBytes = 16300;

class GroupReliableChunk {
  GroupReliableChunk(
      {required this.groupId,
      required this.sourcePeerId,
      required this.destinationPeerId,
      required this.groupMessageId,
      required this.deliveryMode,
      required this.priority,
      required this.chunkIndex,
      required this.chunkCount,
      required this.totalLength,
      required this.chunkOffset,
      required List<int> bytes})
      : bytes = Uint8List.fromList(bytes) {
    final expected = totalLength == 0
        ? 1
        : (totalLength + maxGroupReliableChunkBytes - 1) ~/
            maxGroupReliableChunkBytes;
    if (deliveryMode == DeliveryMode.realtimeLatest ||
        totalLength < 0 ||
        totalLength > 1048576 ||
        chunkCount != expected ||
        chunkIndex < 0 ||
        chunkIndex >= chunkCount ||
        chunkOffset != chunkIndex * maxGroupReliableChunkBytes ||
        this.bytes.length > maxGroupReliableChunkBytes ||
        (totalLength == 0 && this.bytes.isNotEmpty) ||
        (totalLength > 0 &&
            (this.bytes.isEmpty ||
                chunkOffset + this.bytes.length > totalLength)) ||
        (chunkIndex + 1 < chunkCount &&
            this.bytes.length != maxGroupReliableChunkBytes) ||
        (chunkIndex + 1 == chunkCount &&
            totalLength > 0 &&
            chunkOffset + this.bytes.length != totalLength))
      throw const LpcException(LpcErrorCode.protocolMismatch);
  }
  final GroupId groupId;
  final PeerId sourcePeerId, destinationPeerId;
  final GroupMessageId groupMessageId;
  final DeliveryMode deliveryMode;
  final SendPriority priority;
  final int chunkIndex, chunkCount, totalLength, chunkOffset;
  final Uint8List bytes;
  Uint8List encode() {
    final h = ByteData(84);
    h.buffer.asUint8List().setRange(0, 16, groupId.bytes);
    h.buffer.asUint8List().setRange(16, 32, sourcePeerId.bytes);
    h.buffer.asUint8List().setRange(32, 48, destinationPeerId.bytes);
    h.buffer.asUint8List().setRange(48, 64, groupMessageId.bytes);
    h.setUint8(64, deliveryMode == DeliveryMode.reliableOrdered ? 1 : 2);
    h.setUint8(65, priority.index + 1);
    h.setUint16(68, chunkIndex);
    h.setUint16(70, chunkCount);
    h.setUint32(72, totalLength);
    h.setUint32(76, chunkOffset);
    h.setUint16(80, bytes.length);
    return Uint8List.fromList([...h.buffer.asUint8List(), ...bytes]);
  }

  static GroupReliableChunk decode(List<int> input) {
    if (input.length < 84)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final raw = Uint8List.fromList(input);
    final h = ByteData.sublistView(raw);
    if (h.getUint16(66) != 0 ||
        h.getUint16(82) != 0 ||
        input.length != 84 + h.getUint16(80) ||
        h.getUint8(64) < 1 ||
        h.getUint8(64) > 2 ||
        h.getUint8(65) < 1 ||
        h.getUint8(65) > 3)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    return GroupReliableChunk(
        groupId: GroupId(raw.sublist(0, 16)),
        sourcePeerId: PeerId(raw.sublist(16, 32)),
        destinationPeerId: PeerId(raw.sublist(32, 48)),
        groupMessageId: GroupMessageId(raw.sublist(48, 64)),
        deliveryMode: h.getUint8(64) == 1
            ? DeliveryMode.reliableOrdered
            : DeliveryMode.reliableAcked,
        priority: SendPriority.values[h.getUint8(65) - 1],
        chunkIndex: h.getUint16(68),
        chunkCount: h.getUint16(70),
        totalLength: h.getUint32(72),
        chunkOffset: h.getUint32(76),
        bytes: raw.sublist(84));
  }
}

List<GroupReliableChunk> chunkGroupReliable(
    {required GroupId groupId,
    required PeerId source,
    required PeerId destination,
    required GroupMessageId messageId,
    required DeliveryMode mode,
    required SendPriority priority,
    required List<int> bytes}) {
  if (bytes.length > 1048576)
    throw const LpcException(LpcErrorCode.messageTooLarge);
  final count = bytes.isEmpty
      ? 1
      : (bytes.length + maxGroupReliableChunkBytes - 1) ~/
          maxGroupReliableChunkBytes;
  return List.generate(count, (i) {
    final offset = i * maxGroupReliableChunkBytes;
    return GroupReliableChunk(
        groupId: groupId,
        sourcePeerId: source,
        destinationPeerId: destination,
        groupMessageId: messageId,
        deliveryMode: mode,
        priority: priority,
        chunkIndex: i,
        chunkCount: count,
        totalLength: bytes.length,
        chunkOffset: offset,
        bytes: bytes.sublist(
            offset,
            offset < bytes.length
                ? (offset + maxGroupReliableChunkBytes).clamp(0, bytes.length)
                : offset));
  });
}

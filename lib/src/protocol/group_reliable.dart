import 'dart:typed_data';
import '../types.dart';

const int maxGroupReliableChunkBytes = 16300;

class GroupReliableChunk {
  GroupReliableChunk({
    required this.groupId,
    required this.sourcePeerId,
    required this.destinationPeerId,
    required this.groupMessageId,
    required this.deliveryMode,
    required this.priority,
    required this.chunkIndex,
    required this.chunkCount,
    required this.totalLength,
    required this.chunkOffset,
    required List<int> bytes,
  }) : bytes = Uint8List.fromList(bytes) {
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
      bytes: raw.sublist(84),
    );
  }
}

List<GroupReliableChunk> chunkGroupReliable({
  required GroupId groupId,
  required PeerId source,
  required PeerId destination,
  required GroupMessageId messageId,
  required DeliveryMode mode,
  required SendPriority priority,
  required List<int> bytes,
}) {
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
            : offset,
      ),
    );
  });
}

/// A complete `GROUP_RELIABLE` operation received on one authenticated
/// pairwise hop. The pairwise MessageId is intentionally retained separately
/// from the end-to-end [groupMessageId] (Section 43.1.1).
class ReassembledGroupReliable {
  ReassembledGroupReliable({
    required List<int> pairwiseMessageId,
    required this.groupId,
    required this.sourcePeerId,
    required this.destinationPeerId,
    required this.groupMessageId,
    required this.deliveryMode,
    required this.priority,
    required List<int> bytes,
  })  : pairwiseMessageId = Uint8List.fromList(pairwiseMessageId),
        bytes = Uint8List.fromList(bytes);

  final Uint8List pairwiseMessageId;
  final GroupId groupId;
  final PeerId sourcePeerId, destinationPeerId;
  final GroupMessageId groupMessageId;
  final DeliveryMode deliveryMode;
  final SendPriority priority;
  final Uint8List bytes;
}

/// Section 43.1.8 receiver-side reassembly for a single physical hop.
///
/// The owner supplies bounded limits from its hop admission policy. Calling
/// [onTransportGenerationLost] is mandatory before accepting chunks from a
/// replacement transport generation; partial chunks are never combined across
/// generations. [discardIncompleteStaleAuthority] similarly clears partial
/// state once its hop has been classified as stale former-coordinator traffic
/// (Section 43.1.11).
class GroupReliableReassembler {
  GroupReliableReassembler({
    required this.maxIncompleteMessages,
    required this.maxIncompleteBytes,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (maxIncompleteMessages < 1 || maxIncompleteBytes < 0) {
      throw ArgumentError('invalid GROUP_RELIABLE reassembly limits');
    }
  }

  final int maxIncompleteMessages, maxIncompleteBytes;
  final DateTime Function() _clock;
  final Map<String, _PartialGroupReliable> _messages = {};
  int _bufferedBytes = 0;

  int get incompleteMessages => _messages.length;
  int get bufferedBytes => _bufferedBytes;

  ReassembledGroupReliable? add(
    List<int> pairwiseMessageId,
    GroupReliableChunk chunk,
  ) {
    if (pairwiseMessageId.length != 8) {
      throw ArgumentError.value(pairwiseMessageId, 'pairwiseMessageId');
    }
    expireInactive();
    final key = pairwiseMessageId.join(',');
    var partial = _messages[key];
    if (partial == null) {
      if (_messages.length >= maxIncompleteMessages ||
          _bufferedBytes + chunk.totalLength > maxIncompleteBytes) {
        throw const LpcException(LpcErrorCode.resourceExhausted);
      }
      partial = _PartialGroupReliable(pairwiseMessageId, chunk, _clock());
      _messages[key] = partial;
      _bufferedBytes += chunk.totalLength;
    } else {
      partial.validateMetadata(chunk);
    }
    partial.add(chunk, _clock());
    if (!partial.complete) return null;
    _messages.remove(key);
    _bufferedBytes -= partial.totalLength;
    return partial.reassembled();
  }

  /// Section 43.1.8: all incomplete hop state is generation-local.
  void onTransportGenerationLost() {
    _messages.clear();
    _bufferedBytes = 0;
  }

  /// Section 43.1.11: a partial hop from the former coordinator cannot be
  /// completed by chunks submitted through the replacement coordinator.
  ///
  /// The caller invokes this only after authenticating and classifying the
  /// received operation as stale-authority application traffic.
  void discardIncompleteStaleAuthority() {
    _messages.clear();
    _bufferedBytes = 0;
  }

  /// Section 43.1.8 uses the Section 21 10-second inactivity interval.
  void expireInactive() {
    final cutoff = _clock().subtract(const Duration(seconds: 10));
    final expired = _messages.entries
        .where((entry) => entry.value.updated.isBefore(cutoff))
        .toList();
    for (final entry in expired) {
      _bufferedBytes -= entry.value.totalLength;
      _messages.remove(entry.key);
    }
  }
}

class _PartialGroupReliable {
  _PartialGroupReliable(
    this.pairwiseMessageId,
    GroupReliableChunk first,
    this.updated,
  )   : groupId = first.groupId,
        sourcePeerId = first.sourcePeerId,
        destinationPeerId = first.destinationPeerId,
        groupMessageId = first.groupMessageId,
        deliveryMode = first.deliveryMode,
        priority = first.priority,
        chunkCount = first.chunkCount,
        totalLength = first.totalLength,
        chunks = List<Uint8List?>.filled(first.chunkCount, null);

  final List<int> pairwiseMessageId;
  final GroupId groupId;
  final PeerId sourcePeerId, destinationPeerId;
  final GroupMessageId groupMessageId;
  final DeliveryMode deliveryMode;
  final SendPriority priority;
  final int chunkCount, totalLength;
  final List<Uint8List?> chunks;
  DateTime updated;

  void validateMetadata(GroupReliableChunk chunk) {
    if (chunk.groupId != groupId ||
        chunk.sourcePeerId != sourcePeerId ||
        chunk.destinationPeerId != destinationPeerId ||
        chunk.groupMessageId != groupMessageId ||
        chunk.deliveryMode != deliveryMode ||
        chunk.priority != priority ||
        chunk.chunkCount != chunkCount ||
        chunk.totalLength != totalLength) {
      throw const LpcException(LpcErrorCode.messageIdCollision);
    }
  }

  void add(GroupReliableChunk chunk, DateTime at) {
    final existing = chunks[chunk.chunkIndex];
    if (existing != null && !_same(existing, chunk.bytes)) {
      throw const LpcException(LpcErrorCode.messageIdCollision);
    }
    chunks[chunk.chunkIndex] ??= chunk.bytes;
    updated = at;
  }

  bool get complete => chunks.every((chunk) => chunk != null);

  ReassembledGroupReliable reassembled() {
    final bytes = Uint8List(totalLength);
    var offset = 0;
    for (final chunk in chunks) {
      bytes.setRange(offset, offset + chunk!.length, chunk);
      offset += chunk.length;
    }
    return ReassembledGroupReliable(
      pairwiseMessageId: pairwiseMessageId,
      groupId: groupId,
      sourcePeerId: sourcePeerId,
      destinationPeerId: destinationPeerId,
      groupMessageId: groupMessageId,
      deliveryMode: deliveryMode,
      priority: priority,
      bytes: bytes,
    );
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var result = 0;
  for (var index = 0; index < a.length; index++) {
    result |= a[index] ^ b[index];
  }
  return result == 0;
}

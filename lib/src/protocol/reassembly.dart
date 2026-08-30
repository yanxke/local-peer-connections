import 'dart:typed_data';
import '../types.dart';
import 'application_payload.dart';

class ReassembledData {
  ReassembledData(
      {required List<int> messageId,
      required this.deliveryMode,
      required this.priority,
      required List<int> bytes})
      : messageId = Uint8List.fromList(messageId),
        bytes = Uint8List.fromList(bytes);
  final Uint8List messageId, bytes;
  final DeliveryMode deliveryMode;
  final SendPriority priority;
}

/// Section 21 receiver-side reassembly. Its caller supplies only authenticated,
/// sequence-valid DATA chunks and discards this state on transport loss.
class DataReassembler {
  DataReassembler(
      {this.maxIncompleteMessages = 1024,
      this.maxIncompleteBytes = maxApplicationMessageBytes,
      DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final int maxIncompleteMessages, maxIncompleteBytes;
  final DateTime Function() _clock;
  final Map<String, _PartialData> _messages = {};
  int _bufferedBytes = 0;
  ReassembledData? add(List<int> messageId, DataChunk chunk) {
    if (messageId.length != 8)
      throw ArgumentError.value(messageId, 'messageId');
    expireInactive();
    final key = messageId.join(',');
    var partial = _messages[key];
    if (partial == null) {
      if (_messages.length >= maxIncompleteMessages ||
          _bufferedBytes + chunk.totalLength > maxIncompleteBytes)
        throw const LpcException(LpcErrorCode.resourceExhausted);
      partial = _PartialData(messageId, chunk, _clock());
      _messages[key] = partial;
      _bufferedBytes += chunk.totalLength;
    } else {
      partial.validateMetadata(chunk);
    }
    partial.add(chunk, _clock());
    if (!partial.complete) return null;
    _messages.remove(key);
    _bufferedBytes -= partial.totalLength;
    return ReassembledData(
        messageId: messageId,
        deliveryMode: partial.deliveryMode,
        priority: partial.priority,
        bytes: partial.join());
  }

  /// Section 21.1: no partial data crosses a physical transport generation.
  void onTransportGenerationLost() {
    _messages.clear();
    _bufferedBytes = 0;
  }

  void expireInactive() {
    final cutoff = _clock().subtract(const Duration(seconds: 10));
    final expired = _messages.entries
        .where((e) => e.value.updated.isBefore(cutoff))
        .toList();
    for (final entry in expired) {
      _bufferedBytes -= entry.value.totalLength;
      _messages.remove(entry.key);
    }
  }
}

class _PartialData {
  _PartialData(this.messageId, DataChunk first, this.updated)
      : deliveryMode = first.deliveryMode,
        priority = first.priority,
        chunkCount = first.chunkCount,
        totalLength = first.totalLength,
        chunks = List<Uint8List?>.filled(first.chunkCount, null);
  final List<int> messageId;
  final DeliveryMode deliveryMode;
  final SendPriority priority;
  final int chunkCount, totalLength;
  final List<Uint8List?> chunks;
  DateTime updated;
  void validateMetadata(DataChunk chunk) {
    if (chunk.deliveryMode != deliveryMode ||
        chunk.priority != priority ||
        chunk.chunkCount != chunkCount ||
        chunk.totalLength != totalLength)
      throw const LpcException(LpcErrorCode.messageIdCollision);
  }

  void add(DataChunk chunk, DateTime at) {
    final existing = chunks[chunk.chunkIndex];
    if (existing != null && !_same(existing, chunk.bytes))
      throw const LpcException(LpcErrorCode.messageIdCollision);
    chunks[chunk.chunkIndex] ??= chunk.bytes;
    updated = at;
  }

  bool get complete => chunks.every((chunk) => chunk != null);
  Uint8List join() {
    final out = Uint8List(totalLength);
    var offset = 0;
    for (final chunk in chunks) {
      out.setRange(offset, offset + chunk!.length, chunk);
      offset += chunk.length;
    }
    return out;
  }

  bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}

/// RFC-1982-style uint32 acceptance for each realtime channel (Section 22).
class RealtimeSequenceFilter {
  final Map<int, int> _last = {};
  bool accept(RealtimeDatagram datagram) {
    final prior = _last[datagram.channelId];
    if (prior != null && !_newer(datagram.sequence, prior)) return false;
    _last[datagram.channelId] = datagram.sequence;
    return true;
  }

  bool _newer(int candidate, int previous) {
    final difference = (candidate - previous) & 0xffffffff;
    return difference != 0 && difference < 0x80000000;
  }

  void clear() => _last.clear();
}

import 'dart:typed_data';
import '../types.dart';

class GroupRealtimeDatagram {
  GroupRealtimeDatagram(
      {required this.groupId,
      required this.sourcePeerId,
      required this.destinationPeerId,
      required this.channelId,
      required this.sequence,
      required this.senderTick,
      required List<int> bytes})
      : bytes = Uint8List.fromList(bytes) {
    if (channelId < 1 ||
        channelId > 65535 ||
        sequence == 0 ||
        this.bytes.length > 1100)
      throw const LpcException(LpcErrorCode.messageTooLarge);
  }
  final GroupId groupId;
  final PeerId sourcePeerId, destinationPeerId;
  final int channelId, sequence, senderTick;
  final Uint8List bytes;
  Uint8List encode() {
    final h = ByteData(68);
    h.buffer.asUint8List().setRange(0, 16, groupId.bytes);
    h.buffer.asUint8List().setRange(16, 32, sourcePeerId.bytes);
    h.buffer.asUint8List().setRange(32, 48, destinationPeerId.bytes);
    h.setUint16(48, channelId);
    h.setUint32(52, sequence);
    h.setUint64(56, senderTick);
    h.setUint16(64, bytes.length);
    return Uint8List.fromList([...h.buffer.asUint8List(), ...bytes]);
  }

  static GroupRealtimeDatagram decode(List<int> input) {
    if (input.length < 68)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final raw = Uint8List.fromList(input);
    final h = ByteData.sublistView(raw);
    if (h.getUint16(50) != 0 ||
        h.getUint16(66) != 0 ||
        input.length != 68 + h.getUint16(64))
      throw const LpcException(LpcErrorCode.protocolMismatch);
    return GroupRealtimeDatagram(
        groupId: GroupId(raw.sublist(0, 16)),
        sourcePeerId: PeerId(raw.sublist(16, 32)),
        destinationPeerId: PeerId(raw.sublist(32, 48)),
        channelId: h.getUint16(48),
        sequence: h.getUint32(52),
        senderTick: h.getUint64(56),
        bytes: raw.sublist(68));
  }
}

/// Originating GroupSession sequence allocator, keyed by destination/channel.
class GroupRealtimeSequenceAllocator {
  final Map<String, int> _next = {};
  int allocate(PeerId destination, int channelId) {
    final key = '${destination}:$channelId';
    final result = _next[key] ?? 1;
    if (result == 0xffffffff) {
      _next[key] = 0;
      return result;
    }
    if (result == 0) throw const LpcException(LpcErrorCode.resourceExhausted);
    _next[key] = result + 1;
    return result;
  }
}

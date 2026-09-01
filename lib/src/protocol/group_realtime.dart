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
        this.bytes.length > 1100) {
      throw const LpcException(LpcErrorCode.messageTooLarge);
    }
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
    if (input.length < 68) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final raw = Uint8List.fromList(input);
    final h = ByteData.sublistView(raw);
    if (h.getUint16(50) != 0 ||
        h.getUint16(66) != 0 ||
        input.length != 68 + h.getUint16(64)) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
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
    final key = '$destination:$channelId';
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

enum CoordinatorRealtimeEnqueueResult {
  enqueued,
  replacedPending,
  droppedDestinationUnavailable,
  droppedCapacity,
}

/// Section 37.1 coordinator-side pending realtime state. It is deliberately
/// separate from the physical-hop scheduler: this table enforces the group
/// routing identity and bounded latest-pending rule before the destination-hop
/// scheduler accepts a frame.
class CoordinatorRealtimePending {
  CoordinatorRealtimePending({required this.maxPendingDatagrams})
      : assert(maxPendingDatagrams > 0);

  final int maxPendingDatagrams;
  final Map<String, GroupRealtimeDatagram> _pending = {};

  int get length => _pending.length;

  CoordinatorRealtimeEnqueueResult enqueue(
    GroupRealtimeDatagram datagram, {
    required Set<PeerId> committedMembers,
    required bool destinationReady,
  }) {
    if (!committedMembers.contains(datagram.destinationPeerId) ||
        !destinationReady) {
      return CoordinatorRealtimeEnqueueResult.droppedDestinationUnavailable;
    }
    final key = _key(
        datagram.sourcePeerId, datagram.destinationPeerId, datagram.channelId);
    if (_pending.containsKey(key)) {
      _pending[key] = datagram;
      return CoordinatorRealtimeEnqueueResult.replacedPending;
    }
    if (_pending.length >= maxPendingDatagrams) {
      return CoordinatorRealtimeEnqueueResult.droppedCapacity;
    }
    _pending[key] = datagram;
    return CoordinatorRealtimeEnqueueResult.enqueued;
  }

  /// Removes exactly one not-yet-submitted datagram for this routing key.
  GroupRealtimeDatagram? take(
          PeerId source, PeerId destination, int channelId) =>
      _pending.remove(_key(source, destination, channelId));

  /// Section 43.1.10: former coordinator realtime state is discarded.
  void coordinatorAuthorityLost() => _pending.clear();

  /// Section 43.1.12: a removed member receives no queued application traffic.
  void destinationRemoved(PeerId destination) {
    _pending.removeWhere(
        (_, datagram) => datagram.destinationPeerId == destination);
  }

  String _key(PeerId source, PeerId destination, int channelId) =>
      '$source:$destination:$channelId';
}

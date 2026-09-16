import 'dart:typed_data';
import '../types.dart';

class GroupDeliveryAck {
  const GroupDeliveryAck(
      {required this.groupId,
      required this.sourcePeerId,
      required this.destinationPeerId,
      required this.groupMessageId});
  final GroupId groupId;
  final PeerId sourcePeerId, destinationPeerId;
  final GroupMessageId groupMessageId;
  Uint8List encode() => Uint8List.fromList([
        ...groupId.bytes,
        ...sourcePeerId.bytes,
        ...destinationPeerId.bytes,
        ...groupMessageId.bytes
      ]);
  static GroupDeliveryAck decode(List<int> bytes) {
    if (bytes.length != 64)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    return GroupDeliveryAck(
        groupId: GroupId(bytes.sublist(0, 16)),
        sourcePeerId: PeerId(bytes.sublist(16, 32)),
        destinationPeerId: PeerId(bytes.sublist(32, 48)),
        groupMessageId: GroupMessageId(bytes.sublist(48, 64)));
  }
}

enum GroupRelayStatus {
  sentToDestinationTransport,
  destinationNotInGroup,
  destinationUnavailable,
  destinationAckTimeout,
  relayQueueFull,
  groupNotReady
}

extension GroupRelayStatusError on GroupRelayStatus {
  LpcErrorCode? get errorCode => switch (this) {
        GroupRelayStatus.sentToDestinationTransport => null,
        GroupRelayStatus.destinationNotInGroup =>
          LpcErrorCode.destinationNotInGroup,
        GroupRelayStatus.destinationUnavailable =>
          LpcErrorCode.destinationUnavailable,
        GroupRelayStatus.destinationAckTimeout => LpcErrorCode.ackTimeout,
        GroupRelayStatus.relayQueueFull => LpcErrorCode.sendQueueFull,
        GroupRelayStatus.groupNotReady => LpcErrorCode.invalidState
      };
}

class GroupRelayStatusPayload {
  GroupRelayStatusPayload(
      {required this.groupId,
      required this.sourcePeerId,
      required this.destinationPeerId,
      required this.groupMessageId,
      required this.status})
      : errorCode = status.errorCode {}
  final GroupId groupId;
  final PeerId sourcePeerId, destinationPeerId;
  final GroupMessageId groupMessageId;
  final GroupRelayStatus status;
  final LpcErrorCode? errorCode;
  Uint8List encode() {
    final h = ByteData(68);
    h.buffer.asUint8List().setRange(0, 16, groupId.bytes);
    h.buffer.asUint8List().setRange(16, 32, sourcePeerId.bytes);
    h.buffer.asUint8List().setRange(32, 48, destinationPeerId.bytes);
    h.buffer.asUint8List().setRange(48, 64, groupMessageId.bytes);
    h.setUint8(64, status.index + 1);
    h.setUint16(66, errorCode?.value ?? 0);
    return h.buffer.asUint8List();
  }

  static GroupRelayStatusPayload decode(List<int> bytes) {
    if (bytes.length != 68)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final h = ByteData.sublistView(Uint8List.fromList(bytes));
    final wire = h.getUint8(64);
    if (wire < 1 || wire > 6 || h.getUint8(65) != 0)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final status = GroupRelayStatus.values[wire - 1];
    if (h.getUint16(66) != (status.errorCode?.value ?? 0))
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid GROUP_RELAY_STATUS mapping');
    return GroupRelayStatusPayload(
        groupId: GroupId(bytes.sublist(0, 16)),
        sourcePeerId: PeerId(bytes.sublist(16, 32)),
        destinationPeerId: PeerId(bytes.sublist(32, 48)),
        groupMessageId: GroupMessageId(bytes.sublist(48, 64)),
        status: status);
  }
}

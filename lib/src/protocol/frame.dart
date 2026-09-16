import 'dart:typed_data';
import '../types.dart';

const int lpcHeaderLength = 62;
const int maxEncryptedPayloadLength = 16384;
const int protocolMajor = 1;
const int protocolMinor = 0;

enum FrameType {
  hello(0x01),
  auth(0x02),
  ready(0x03),
  ping(0x04),
  pong(0x05),
  data(0x06),
  ack(0x07),
  resumeRequest(0x08),
  resumeAccept(0x09),
  resumeReject(0x0A),
  resumeReady(0x0B),
  caps(0x0C),
  upgradeOffer(0x0D),
  upgradeAccept(0x0E),
  upgradeReject(0x0F),
  upgradeBind(0x10),
  upgradeBindAck(0x11),
  switchCommit(0x12),
  switchAck(0x13),
  close(0x14),
  error(0x15),
  coordinatorHeartbeat(0x16),
  membershipSnapshot(0x17),
  electionAnnounce(0x18),
  coordinatorClaim(0x19),
  coordinatorResign(0x1A),
  realtimeDatagram(0x1B),
  groupInfo(0x1C),
  groupMerge(0x1D),
  coordinatorCheckpoint(0x1E),
  udpOffer(0x1F),
  udpAccept(0x20),
  udpClose(0x21),
  groupMergeReject(0x22),
  groupLeave(0x23),
  groupReliable(0x24),
  groupRealtimeDatagram(0x25),
  groupDeliveryAck(0x26),
  groupRelayStatus(0x27);

  const FrameType(this.value);
  final int value;
  static FrameType fromValue(int value) =>
      FrameType.values.firstWhere((e) => e.value == value,
          orElse: () =>
              throw const LpcException(LpcErrorCode.unsupportedFrameType));
}

class LpcFrame {
  LpcFrame(
      {required this.type,
      required this.flags,
      this.protocolMinor = 0,
      required this.transportGeneration,
      required this.sequenceNumber,
      required List<int> messageId,
      required List<int> sessionId,
      required List<int> nonce,
      required List<int> payload,
      List<int>? tag})
      : messageId = Uint8List.fromList(messageId),
        sessionId = Uint8List.fromList(sessionId),
        nonce = Uint8List.fromList(nonce),
        payload = Uint8List.fromList(payload),
        tag = tag == null ? null : Uint8List.fromList(tag) {
    if (this.messageId.length != 8 ||
        this.sessionId.length != 16 ||
        this.nonce.length != 12)
      throw ArgumentError('invalid LPC identifier length');
    if (this.payload.length > maxEncryptedPayloadLength)
      throw const LpcException(LpcErrorCode.messageTooLarge);
    if (flags & ~1 != 0 || this.protocolMinor < 0 || this.protocolMinor > 255)
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'reserved flag set');
  }
  final FrameType type;
  final int flags, protocolMinor, transportGeneration, sequenceNumber;
  final Uint8List messageId, sessionId, nonce, payload;
  final Uint8List? tag;
  bool get encrypted => tag != null;
  Uint8List encode() {
    if (!encrypted &&
        type != FrameType.hello &&
        type != FrameType.auth &&
        type != FrameType.error)
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'plaintext frame type');
    final b = BytesBuilder(copy: false);
    final h = ByteData(lpcHeaderLength);
    h.setUint8(0, 0x4c);
    h.setUint8(1, 0x50);
    h.setUint8(2, 0x43);
    h.setUint8(3, 0x31);
    h.setUint8(4, protocolMajor);
    h.setUint8(5, this.protocolMinor);
    h.setUint8(6, type.value);
    h.setUint8(7, flags);
    h.setUint16(8, lpcHeaderLength);
    h.setUint32(10, payload.length);
    h.setUint32(14, transportGeneration);
    h.setUint64(18, sequenceNumber);
    h.buffer.asUint8List().setRange(26, 34, messageId);
    h.buffer.asUint8List().setRange(34, 50, sessionId);
    h.buffer.asUint8List().setRange(50, 62, nonce);
    b.add(h.buffer.asUint8List());
    b.add(payload);
    if (tag != null) b.add(tag!);
    return b.toBytes();
  }

  static LpcFrame decode(List<int> input) {
    if (input.length < lpcHeaderLength)
      throw const LpcException(LpcErrorCode.protocolMismatch, 'short frame');
    final bytes = Uint8List.fromList(input);
    final h = ByteData.sublistView(bytes);
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'LPC1' ||
        h.getUint8(4) != protocolMajor ||
        h.getUint16(8) != lpcHeaderLength)
      throw const LpcException(LpcErrorCode.protocolMismatch, 'invalid header');
    final length = h.getUint32(10);
    if (length > maxEncryptedPayloadLength)
      throw const LpcException(LpcErrorCode.messageTooLarge);
    final type = FrameType.fromValue(h.getUint8(6));
    final encrypted = input.length == lpcHeaderLength + length + 16;
    if (!encrypted && input.length != lpcHeaderLength + length)
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid frame length');
    return LpcFrame(
        type: type,
        flags: h.getUint8(7),
        protocolMinor: h.getUint8(5),
        transportGeneration: h.getUint32(14),
        sequenceNumber: h.getUint64(18),
        messageId: bytes.sublist(26, 34),
        sessionId: bytes.sublist(34, 50),
        nonce: bytes.sublist(50, 62),
        payload: bytes.sublist(62, 62 + length),
        tag: encrypted ? bytes.sublist(62 + length) : null);
  }
}

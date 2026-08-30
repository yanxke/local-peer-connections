import 'dart:convert';
import 'dart:typed_data';
import '../types.dart';
import 'frame.dart';

enum SecurityLevel {
  authenticatedKnownPeer,
  authenticatedSas,
  authenticatedPsk,
  encryptedTofu
}

class ErrorPayload {
  ErrorPayload(this.code, [this.diagnostic = '']) {
    if (utf8.encode(diagnostic).length > 0xffff)
      throw ArgumentError.value(diagnostic, 'diagnostic');
  }
  final LpcErrorCode code;
  final String diagnostic;
  Uint8List encode() {
    final text = utf8.encode(diagnostic);
    final h = ByteData(4)
      ..setUint16(0, code.value)
      ..setUint16(2, text.length);
    return Uint8List.fromList([...h.buffer.asUint8List(), ...text]);
  }

  static ErrorPayload decode(List<int> bytes) {
    if (bytes.length < 4)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    if (bytes.length != 4 + data.getUint16(2))
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final code = LpcErrorCode.values
        .where((value) => value.value == data.getUint16(0))
        .firstOrNull;
    if (code == null) throw const LpcException(LpcErrorCode.protocolMismatch);
    return ErrorPayload(
        code, utf8.decode(bytes.sublist(4), allowMalformed: false));
  }
}

/// Section 16.2.1's sole permitted plaintext ERROR. Every header field except
/// the sender's advertised max minor is fixed by the wire contract.
LpcFrame preKeyProtocolMismatchError(
        {required int senderMaxMinor, String diagnostic = ''}) =>
    LpcFrame(
        type: FrameType.error,
        flags: 0,
        protocolMinor: senderMaxMinor,
        transportGeneration: 0,
        sequenceNumber: 0,
        messageId: List.filled(8, 0),
        sessionId: List.filled(16, 0),
        nonce: List.filled(12, 0),
        payload:
            ErrorPayload(LpcErrorCode.protocolMismatch, diagnostic).encode());

/// Validates the stateless wire requirements for the pre-key plaintext ERROR.
/// The handshake state preconditions are enforced by its orchestrator.
ErrorPayload parsePreKeyProtocolMismatchError(LpcFrame frame) {
  if (frame.type != FrameType.error ||
      frame.encrypted ||
      frame.flags != 0 ||
      frame.transportGeneration != 0 ||
      frame.sequenceNumber != 0 ||
      frame.messageId.any((byte) => byte != 0) ||
      frame.sessionId.any((byte) => byte != 0) ||
      frame.nonce.any((byte) => byte != 0)) {
    throw const LpcException(
        LpcErrorCode.protocolMismatch, 'invalid plaintext ERROR header');
  }
  final payload = ErrorPayload.decode(frame.payload);
  if (payload.code != LpcErrorCode.protocolMismatch) {
    throw const LpcException(LpcErrorCode.protocolMismatch,
        'plaintext ERROR is not PROTOCOL_MISMATCH');
  }
  return payload;
}

class ReadyPayload {
  ReadyPayload(
      {required List<int> sessionId,
      required this.peerCapabilities,
      required this.keepaliveIntervalMs,
      required this.keepaliveDeadTimeoutMs,
      required this.securityLevel})
      : sessionId = Uint8List.fromList(sessionId) {
    if (this.sessionId.length != 16 ||
        keepaliveIntervalMs < 1000 ||
        keepaliveIntervalMs > 10000 ||
        keepaliveDeadTimeoutMs <
            ((3 * keepaliveIntervalMs) > 6000 ? 3 * keepaliveIntervalMs : 6000))
      throw const LpcException(LpcErrorCode.protocolMismatch, 'invalid READY');
  }
  final Uint8List sessionId;
  final int peerCapabilities, keepaliveIntervalMs, keepaliveDeadTimeoutMs;
  final SecurityLevel securityLevel;
  Uint8List encode() {
    final result = ByteData(32);
    result.buffer.asUint8List().setRange(0, 16, sessionId);
    result.setUint32(16, peerCapabilities);
    result.setUint32(20, keepaliveIntervalMs);
    result.setUint32(24, keepaliveDeadTimeoutMs);
    result.setUint8(28, securityLevel.index + 1);
    return result.buffer.asUint8List();
  }

  static ReadyPayload decode(List<int> bytes) {
    if (bytes.length != 32)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    if (data.getUint8(29) != 0 ||
        data.getUint8(30) != 0 ||
        data.getUint8(31) != 0 ||
        data.getUint8(28) < 1 ||
        data.getUint8(28) > 4)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    return ReadyPayload(
        sessionId: bytes.sublist(0, 16),
        peerCapabilities: data.getUint32(16),
        keepaliveIntervalMs: data.getUint32(20),
        keepaliveDeadTimeoutMs: data.getUint32(24),
        securityLevel: SecurityLevel.values[data.getUint8(28) - 1]);
  }
}

enum SequenceAcceptance { accepted, replay }

class ReceiveSequenceWindow {
  int _highest = 0;
  SequenceAcceptance accept(int sequence) {
    if (sequence < 1) throw const LpcException(LpcErrorCode.protocolMismatch);
    if (sequence <= _highest) return SequenceAcceptance.replay;
    if (sequence > _highest + 1024)
      throw const LpcException(LpcErrorCode.sequenceWindowExceeded);
    _highest = sequence;
    return SequenceAcceptance.accepted;
  }

  void reset() => _highest = 0;
}

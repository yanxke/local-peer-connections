import 'dart:typed_data';
import '../types.dart';
import 'frame.dart';
import 'hello.dart';

/// Constructs the Section 16 plaintext HELLO envelope. The header minor is
/// the sender's advertised maximum minor, while every session field is zero.
LpcFrame plaintextHelloFrame(HelloPayload hello) => LpcFrame(
    type: FrameType.hello,
    flags: 0,
    protocolMinor: hello.maxMinor,
    transportGeneration: 0,
    sequenceNumber: 0,
    messageId: List.filled(8, 0),
    sessionId: List.filled(16, 0),
    nonce: List.filled(12, 0),
    payload: hello.encode());

/// Constructs the Section 16 plaintext AUTH envelope. AUTH has no payload
/// version field, so its header uses the same local maximum minor as HELLO.
LpcFrame plaintextAuthFrame(
        {required int senderMaxMinor, required List<int> authPayload}) =>
    LpcFrame(
        type: FrameType.auth,
        flags: 0,
        protocolMinor: senderMaxMinor,
        transportGeneration: 0,
        sequenceNumber: 0,
        messageId: List.filled(8, 0),
        sessionId: List.filled(16, 0),
        nonce: List.filled(12, 0),
        payload: _authPayload(authPayload));

Future<HelloPayload> parsePlaintextHelloFrame(LpcFrame frame) async {
  _validatePlaintextHandshakeHeader(frame, FrameType.hello);
  return HelloPayload.decode(frame.payload);
}

Uint8List parsePlaintextAuthFrame(LpcFrame frame) {
  _validatePlaintextHandshakeHeader(frame, FrameType.auth);
  return _authPayload(frame.payload);
}

Uint8List _authPayload(List<int> payload) {
  if (payload.length != 64) {
    throw const LpcException(
        LpcErrorCode.authenticationFailed, 'AUTH payload must be 64 bytes');
  }
  return Uint8List.fromList(payload);
}

void _validatePlaintextHandshakeHeader(LpcFrame frame, FrameType expectedType) {
  if (frame.type != expectedType ||
      frame.encrypted ||
      frame.flags != 0 ||
      frame.transportGeneration != 0 ||
      frame.sequenceNumber != 0 ||
      frame.messageId.any((byte) => byte != 0) ||
      frame.sessionId.any((byte) => byte != 0) ||
      frame.nonce.any((byte) => byte != 0)) {
    throw const LpcException(
        LpcErrorCode.protocolMismatch, 'invalid plaintext handshake header');
  }
}

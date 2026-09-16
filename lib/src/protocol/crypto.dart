import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../types.dart';
import 'frame.dart';

Uint8List frameNonce(int generation, int sequence) {
  final b = ByteData(12)
    ..setUint32(0, generation)
    ..setUint64(4, sequence);
  return b.buffer.asUint8List();
}

Future<SecretKey> trafficKey(
    List<int> sessionRootKey, int generation, int direction) {
  if (sessionRootKey.length != 32 || direction < 0 || direction > 1)
    throw ArgumentError('invalid traffic key inputs');
  final generationBytes = ByteData(4)..setUint32(0, generation);
  return Hkdf(hmac: Hmac.sha256(), outputLength: 32)
      .deriveKey(secretKey: SecretKey(sessionRootKey), nonce: const [], info: [
    ...ascii.encode('LPC1-traffic'),
    ...generationBytes.buffer.asUint8List(),
    direction
  ]);
}

/// Section 17 frame protection. Associated data is the first 50 header bytes.
class FrameProtector {
  const FrameProtector();
  static final _cipher = Chacha20.poly1305Aead();
  Future<LpcFrame> encrypt(LpcFrame plain, List<int> key) async {
    if (plain.encrypted) throw ArgumentError('frame is already encrypted');
    final nonce = frameNonce(plain.transportGeneration, plain.sequenceNumber);
    final aad = _headerPrefix(plain, nonce, plain.payload.length);
    final box = await _cipher.encrypt(plain.payload,
        secretKey: SecretKey(key), nonce: nonce, aad: aad);
    return LpcFrame(
        type: plain.type,
        flags: plain.flags,
        transportGeneration: plain.transportGeneration,
        sequenceNumber: plain.sequenceNumber,
        messageId: plain.messageId,
        sessionId: plain.sessionId,
        nonce: nonce,
        payload: box.cipherText,
        tag: box.mac.bytes);
  }

  Future<LpcFrame> decrypt(LpcFrame frame, List<int> key) async {
    if (!frame.encrypted ||
        !_equal(frame.nonce,
            frameNonce(frame.transportGeneration, frame.sequenceNumber)))
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid encrypted frame nonce');
    try {
      final clear = await _cipher.decrypt(
          SecretBox(frame.payload, nonce: frame.nonce, mac: Mac(frame.tag!)),
          secretKey: SecretKey(key),
          aad: _headerPrefix(frame, frame.nonce, frame.payload.length));
      return LpcFrame(
          type: frame.type,
          flags: frame.flags,
          transportGeneration: frame.transportGeneration,
          sequenceNumber: frame.sequenceNumber,
          messageId: frame.messageId,
          sessionId: frame.sessionId,
          nonce: frame.nonce,
          payload: clear);
    } on SecretBoxAuthenticationError {
      throw const LpcException(LpcErrorCode.authenticationFailed,
          'ChaCha20-Poly1305 authentication failed');
    }
  }

  List<int> _headerPrefix(LpcFrame f, List<int> nonce, int length) {
    final h = ByteData(50);
    h.buffer.asUint8List().setRange(0, 4, ascii.encode('LPC1'));
    h.setUint8(4, protocolMajor);
    h.setUint8(5, protocolMinor);
    h.setUint8(6, f.type.value);
    h.setUint8(7, f.flags);
    h.setUint16(8, lpcHeaderLength);
    h.setUint32(10, length);
    h.setUint32(14, f.transportGeneration);
    h.setUint64(18, f.sequenceNumber);
    h.buffer.asUint8List().setRange(26, 34, f.messageId);
    h.buffer.asUint8List().setRange(34, 50, f.sessionId);
    return h.buffer.asUint8List();
  }

  bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }
}

import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../types.dart';
import 'hello.dart';

class HandshakeSecrets {
  HandshakeSecrets(
      {required List<int> sessionRootKey,
      required List<int> resumeSecret,
      required List<int> sessionId})
      : sessionRootKey = Uint8List.fromList(sessionRootKey),
        resumeSecret = Uint8List.fromList(resumeSecret),
        sessionId = Uint8List.fromList(sessionId);
  final Uint8List sessionRootKey, resumeSecret, sessionId;
}

Future<Uint8List> handshakeTranscript(
    {required List<int> serviceUuid,
    required List<int> localHello,
    required List<int> remoteHello}) async {
  if (serviceUuid.length != 16)
    throw ArgumentError.value(serviceUuid, 'serviceUuid');
  final comparison = _compare(localHello, remoteHello);
  final pair = comparison <= 0
      ? [...localHello, ...remoteHello]
      : [...remoteHello, ...localHello];
  final digest = await Sha256()
      .hash([...ascii.encode('LPC1-transcript'), ...serviceUuid, ...pair]);
  return Uint8List.fromList(digest.bytes);
}

Future<Uint8List> deriveBaseRootKey(
    {required List<int> sharedSecret,
    required List<int> transcript,
    required HandshakeTrustMode trustMode,
    List<int>? psk32}) async {
  if (sharedSecret.length != 32 || transcript.length != 32)
    throw ArgumentError('invalid handshake input');
  List<int> salt = transcript;
  if (trustMode == HandshakeTrustMode.psk32) {
    if (psk32?.length != 32)
      throw const LpcException(
          LpcErrorCode.authenticationFailed, 'PSK_32 requires 32 bytes');
    salt = (await Hmac.sha256().calculateMac(
            [...ascii.encode('LPC1-psk'), ...transcript],
            secretKey: SecretKey(psk32!)))
        .bytes;
  }
  final output = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(sharedSecret),
      nonce: salt,
      info: ascii.encode('LPC1-base-root'));
  return Uint8List.fromList(await output.extractBytes());
}

Future<HandshakeSecrets> deriveHandshakeSecrets(
    {required List<int> baseRootKey, required List<int> transcript}) async {
  final root = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(baseRootKey),
      nonce: transcript,
      info: ascii.encode('LPC1-session-root'));
  final rootBytes = await root.extractBytes();
  final resume = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(rootBytes),
      nonce: const [],
      info: ascii.encode('LPC1-resume-secret'));
  final id = await Sha256()
      .hash([...ascii.encode('LPC1-session-id'), ...transcript, ...rootBytes]);
  return HandshakeSecrets(
      sessionRootKey: rootBytes,
      resumeSecret: await resume.extractBytes(),
      sessionId: id.bytes.sublist(0, 16));
}

Future<String> sasFor(
    {required List<int> baseRootKey, required List<int> transcript}) async {
  final mac = await Hmac.sha256().calculateMac(
      [...ascii.encode('LPC1-sas'), ...transcript],
      secretKey: SecretKey(baseRootKey));
  final value =
      ByteData.sublistView(Uint8List.fromList(mac.bytes)).getUint32(0) %
          1000000;
  return value.toString().padLeft(6, '0');
}

int _compare(List<int> a, List<int> b) {
  final min = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < min; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return a.length.compareTo(b.length);
}

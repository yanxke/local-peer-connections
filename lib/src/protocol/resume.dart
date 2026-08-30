import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../types.dart';

Future<Uint8List> resumeRequestProof(
        {required List<int> resumeSecret,
        required List<int> sessionId,
        required List<int> nonceA,
        required List<int> transcript}) async =>
    Uint8List.fromList((await Hmac.sha256().calculateMac([
      ...ascii.encode('LPC1-resume-request'),
      ...sessionId,
      ...nonceA,
      ...transcript
    ], secretKey: SecretKey(resumeSecret)))
        .bytes);

class ResumeRequest {
  ResumeRequest(
      {required List<int> sessionId,
      required List<int> nonceA,
      required this.previousGeneration,
      required List<int> proof})
      : sessionId = Uint8List.fromList(sessionId),
        nonceA = Uint8List.fromList(nonceA),
        proof = Uint8List.fromList(proof) {
    if (this.sessionId.length != 16 ||
        this.nonceA.length != 16 ||
        this.proof.length != 32) throw ArgumentError('invalid RESUME_REQUEST');
  }
  final Uint8List sessionId, nonceA, proof;
  final int previousGeneration;
  Uint8List encode() {
    final b = ByteData(68);
    b.buffer.asUint8List().setRange(0, 16, sessionId);
    b.buffer.asUint8List().setRange(16, 32, nonceA);
    b.setUint32(32, previousGeneration);
    b.buffer.asUint8List().setRange(36, 68, proof);
    return b.buffer.asUint8List();
  }

  static ResumeRequest decode(List<int> b) {
    if (b.length != 68) throw const LpcException(LpcErrorCode.protocolMismatch);
    final d = ByteData.sublistView(Uint8List.fromList(b));
    return ResumeRequest(
        sessionId: b.sublist(0, 16),
        nonceA: b.sublist(16, 32),
        previousGeneration: d.getUint32(32),
        proof: b.sublist(36));
  }
}

class ResumeReady {
  ResumeReady(List<int> sessionId, this.generation)
      : sessionId = Uint8List.fromList(sessionId) {
    if (this.sessionId.length != 16)
      throw ArgumentError.value(sessionId, 'sessionId');
  }
  final Uint8List sessionId;
  final int generation;
  Uint8List encode() {
    final b = ByteData(20);
    b.buffer.asUint8List().setRange(0, 16, sessionId);
    b.setUint32(16, generation);
    return b.buffer.asUint8List();
  }

  static ResumeReady decode(List<int> b) {
    if (b.length != 20) throw const LpcException(LpcErrorCode.protocolMismatch);
    return ResumeReady(b.sublist(0, 16),
        ByteData.sublistView(Uint8List.fromList(b)).getUint32(16));
  }
}

Future<Uint8List> resumeAcceptProof(
    {required List<int> resumeSecret,
    required List<int> sessionId,
    required List<int> nonceA,
    required List<int> nonceB,
    required List<int> transcript,
    required int generation}) async {
  final g = ByteData(4)..setUint32(0, generation);
  return Uint8List.fromList((await Hmac.sha256().calculateMac([
    ...ascii.encode('LPC1-resume-accept'),
    ...sessionId,
    ...nonceA,
    ...nonceB,
    ...transcript,
    ...g.buffer.asUint8List()
  ], secretKey: SecretKey(resumeSecret)))
      .bytes);
}

class ResumeAccept {
  ResumeAccept(
      {required List<int> sessionId,
      required List<int> nonceA,
      required List<int> nonceB,
      required this.generation,
      required List<int> proof})
      : sessionId = Uint8List.fromList(sessionId),
        nonceA = Uint8List.fromList(nonceA),
        nonceB = Uint8List.fromList(nonceB),
        proof = Uint8List.fromList(proof) {
    if (this.sessionId.length != 16 ||
        this.nonceA.length != 16 ||
        this.nonceB.length != 16 ||
        this.proof.length != 32) throw ArgumentError('invalid RESUME_ACCEPT');
  }
  final Uint8List sessionId, nonceA, nonceB, proof;
  final int generation;
  Uint8List encode() {
    final b = ByteData(84);
    b.buffer.asUint8List().setRange(0, 16, sessionId);
    b.buffer.asUint8List().setRange(16, 32, nonceA);
    b.buffer.asUint8List().setRange(32, 48, nonceB);
    b.setUint32(48, generation);
    b.buffer.asUint8List().setRange(52, 84, proof);
    return b.buffer.asUint8List();
  }

  static ResumeAccept decode(List<int> b) {
    if (b.length != 84) throw const LpcException(LpcErrorCode.protocolMismatch);
    final d = ByteData.sublistView(Uint8List.fromList(b));
    return ResumeAccept(
        sessionId: b.sublist(0, 16),
        nonceA: b.sublist(16, 32),
        nonceB: b.sublist(32, 48),
        generation: d.getUint32(48),
        proof: b.sublist(52));
  }
}

class ResumedSecrets {
  ResumedSecrets(List<int> root, List<int> resume)
      : sessionRootKey = Uint8List.fromList(root),
        resumeSecret = Uint8List.fromList(resume);
  final Uint8List sessionRootKey, resumeSecret;
}

Future<ResumedSecrets> deriveResumedSecrets(
    {required List<int> candidateSessionRootKey,
    required List<int> previousResumeSecret,
    required List<int> sessionId,
    required List<int> nonceA,
    required List<int> nonceB,
    required int generation}) async {
  if (candidateSessionRootKey.length != 32 ||
      previousResumeSecret.length != 32 ||
      sessionId.length != 16 ||
      nonceA.length != 16 ||
      nonceB.length != 16) throw ArgumentError('invalid resumed root input');
  final g = ByteData(4)..setUint32(0, generation);
  final rootKey = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(candidateSessionRootKey),
      nonce: previousResumeSecret,
      info: [
        ...ascii.encode('LPC1-resumed-root'),
        ...sessionId,
        ...nonceA,
        ...nonceB,
        ...g.buffer.asUint8List()
      ]);
  final root = await rootKey.extractBytes();
  final next = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(root),
      nonce: const [],
      info: ascii.encode('LPC1-resume-secret'));
  return ResumedSecrets(root, await next.extractBytes());
}

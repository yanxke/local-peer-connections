import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../backend.dart';
import '../types.dart';
import 'crypto.dart';
import 'frame.dart';

/// Section 26.1 candidate traffic key. Candidate RESUME control frames always
/// use this key with generation 0, independently of normal traffic keys.
Future<Uint8List> candidateTrafficKey(
    List<int> candidateSessionRootKey, int direction) async {
  if (candidateSessionRootKey.length != 32 || direction < 0 || direction > 1) {
    throw ArgumentError('invalid candidate traffic key input');
  }
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(candidateSessionRootKey),
      nonce: const [],
      info: [...ascii.encode('LPC1-candidate'), direction]);
  return Uint8List.fromList(await key.extractBytes());
}

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

/// Verifies Section 26.2's requester proof before the responder accepts a
/// candidate RESUME. Invalid proofs are rejected under the candidate session.
Future<void> verifyResumeRequestProof(
    {required List<int> resumeSecret,
    required List<int> sessionId,
    required List<int> nonceA,
    required List<int> transcript,
    required List<int> proof}) async {
  final expected = await resumeRequestProof(
      resumeSecret: resumeSecret,
      sessionId: sessionId,
      nonceA: nonceA,
      transcript: transcript);
  if (!_same(expected, proof)) {
    throw const LpcException(
        LpcErrorCode.resumeRejected, 'invalid RESUME_REQUEST proof');
  }
}

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

/// Verifies Section 26.3's responder proof before switching to the resumed
/// logical session.
Future<void> verifyResumeAcceptProof(
    {required List<int> resumeSecret,
    required List<int> sessionId,
    required List<int> nonceA,
    required List<int> nonceB,
    required List<int> transcript,
    required int generation,
    required List<int> proof}) async {
  final expected = await resumeAcceptProof(
      resumeSecret: resumeSecret,
      sessionId: sessionId,
      nonceA: nonceA,
      nonceB: nonceB,
      transcript: transcript,
      generation: generation);
  if (!_same(expected, proof)) {
    throw const LpcException(
        LpcErrorCode.resumeRejected, 'invalid RESUME_ACCEPT proof');
  }
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

/// The completed output of a backend-bound Section 26 candidate exchange.
/// The logical-operation owner installs these values only after this object
/// has authenticated both generation-specific RESUME_READY frames.
class ResumedSession {
  ResumedSession({
    required List<int> sessionRootKey,
    required List<int> resumeSecret,
    required List<int> sessionId,
    required this.generation,
  })  : sessionRootKey = Uint8List.fromList(sessionRootKey),
        resumeSecret = Uint8List.fromList(resumeSecret),
        sessionId = Uint8List.fromList(sessionId);

  final Uint8List sessionRootKey, resumeSecret, sessionId;
  final int generation;
}

/// Portable Section 26 candidate encrypted RESUME driver.
///
/// Callers establish and authenticate the fresh candidate HELLO/AUTH first,
/// then provide that candidate handshake's root/session/transcript plus the
/// prior logical-session record. This driver deliberately stops before core
/// transport rebinding, so no application DATA can leak onto the candidate.
class CandidateResumeConnection {
  CandidateResumeConnection({
    required this.backend,
    required List<int> candidateSessionRootKey,
    required List<int> candidateSessionId,
    required List<int> candidateTranscript,
    required this.localPeerId,
    required this.remotePeerId,
    required List<int> previousSessionId,
    required List<int> previousResumeSecret,
    required this.previousGeneration,
    required this.requester,
    List<int> Function()? randomNonce,
    List<int>? initialEncodedFrame,
  })  : _candidateSessionRootKey = Uint8List.fromList(candidateSessionRootKey),
        _candidateSessionId = Uint8List.fromList(candidateSessionId),
        _candidateTranscript = Uint8List.fromList(candidateTranscript),
        _previousSessionId = Uint8List.fromList(previousSessionId),
        _previousResumeSecret = Uint8List.fromList(previousResumeSecret),
        _randomNonce = randomNonce ?? _secureNonce,
        _initialEncodedFrame = initialEncodedFrame == null
            ? null
            : Uint8List.fromList(initialEncodedFrame) {
    if (_candidateSessionRootKey.length != 32 ||
        _candidateSessionId.length != 16 ||
        _candidateTranscript.length != 32 ||
        _previousSessionId.length != 16 ||
        _previousResumeSecret.length != 32 ||
        previousGeneration < 1 ||
        previousGeneration == 0xffffffff) {
      throw ArgumentError('invalid candidate RESUME inputs');
    }
  }

  final BackendConnection backend;
  final Uint8List _candidateSessionRootKey,
      _candidateSessionId,
      _candidateTranscript,
      _previousSessionId,
      _previousResumeSecret;
  final PeerId localPeerId, remotePeerId;
  final int previousGeneration;
  final bool requester;
  final List<int> Function() _randomNonce;
  final Uint8List? _initialEncodedFrame;
  final Completer<ResumedSession> _completed = Completer<ResumedSession>();
  StreamSubscription<BackendConnectionEvent>? _subscription;
  Future<void> _inbound = Future<void>.value();
  int _nextCandidateOutbound = 1;
  int _nextCandidateInbound = 1;
  int? _generation;
  Uint8List? _nonceA, _nonceB;
  ResumedSecrets? _resumedSecrets;
  bool _started = false;
  bool _sentReady = false;
  bool _receivedReady = false;

  Future<ResumedSession> get completed => _completed.future;

  /// Starts the candidate control exchange. The requester sends exactly one
  /// RESUME_REQUEST; a responder waits for that authenticated request.
  Future<void> start() async {
    if (_started) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'candidate RESUME already started');
    }
    _started = true;
    _subscription = backend.events.listen(_onBackendEvent,
        onError: (Object error, StackTrace stack) => _fail(error, stack));
    final initial = _initialEncodedFrame;
    if (initial != null) {
      // The selectable handshake owns exactly the first RESUME_REQUEST, then
      // hands it over after this listener is installed.  Process it through
      // the same serialized receive path as backend-delivered bytes.
      _inbound = _inbound.then((_) => _receive(initial));
    }
    if (!requester) return;
    final nonce = Uint8List.fromList(_randomNonce());
    if (nonce.length != 16)
      throw ArgumentError('randomNonce must return 16 bytes');
    _nonceA = nonce;
    final proof = await resumeRequestProof(
        resumeSecret: _previousResumeSecret,
        sessionId: _previousSessionId,
        nonceA: nonce,
        transcript: _candidateTranscript);
    await _sendCandidate(
        FrameType.resumeRequest,
        ResumeRequest(
                sessionId: _previousSessionId,
                nonceA: nonce,
                previousGeneration: previousGeneration,
                proof: proof)
            .encode());
  }

  void _onBackendEvent(BackendConnectionEvent event) {
    if (event is BackendBytesReceived) {
      _inbound = _inbound.then((_) => _receive(event.bytes));
    }
    if (event is BackendClosed) {
      _fail(const LpcException(LpcErrorCode.transportClosed));
    }
    if (event is BackendError) _fail(event.error);
  }

  Future<void> _receive(List<int> bytes) async {
    try {
      final frame = LpcFrame.decode(bytes);
      if (_resumedSecrets == null) {
        await _receiveCandidate(frame);
      } else {
        await _receiveReady(frame);
      }
    } catch (error, stackTrace) {
      await _closeWithError(error, stackTrace);
    }
  }

  Future<void> _receiveCandidate(LpcFrame frame) async {
    if (!frame.encrypted ||
        frame.protocolMinor != protocolMinor ||
        frame.flags != 0 ||
        frame.transportGeneration != 0 ||
        !_same(frame.sessionId, _candidateSessionId) ||
        frame.messageId.any((byte) => byte != 0) ||
        frame.sequenceNumber != _nextCandidateInbound ||
        (frame.type != FrameType.resumeRequest &&
            frame.type != FrameType.resumeAccept &&
            frame.type != FrameType.resumeReject)) {
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid candidate RESUME frame');
    }
    final key = await candidateTrafficKey(
        _candidateSessionRootKey, _direction(remotePeerId, localPeerId));
    final clear = await const FrameProtector().decrypt(frame, key);
    _nextCandidateInbound++;
    switch (clear.type) {
      case FrameType.resumeRequest:
        try {
          await _receiveRequest(clear);
        } on LpcException catch (error) {
          if (!requester) await _sendReject(error.code);
          rethrow;
        }
      case FrameType.resumeAccept:
        await _receiveAccept(clear);
      case FrameType.resumeReject:
        if (clear.payload.length != 2) {
          throw const LpcException(LpcErrorCode.protocolMismatch);
        }
        throw const LpcException(LpcErrorCode.resumeRejected);
      default:
        throw const LpcException(LpcErrorCode.protocolMismatch);
    }
  }

  Future<void> _receiveRequest(LpcFrame frame) async {
    if (requester || _nonceA != null) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final request = ResumeRequest.decode(frame.payload);
    if (!_same(request.sessionId, _previousSessionId) ||
        request.previousGeneration != previousGeneration) {
      throw const LpcException(LpcErrorCode.resumeRejected);
    }
    await verifyResumeRequestProof(
        resumeSecret: _previousResumeSecret,
        sessionId: _previousSessionId,
        nonceA: request.nonceA,
        transcript: _candidateTranscript,
        proof: request.proof);
    _nonceA = request.nonceA;
    _nonceB = Uint8List.fromList(_randomNonce());
    if (_nonceB!.length != 16)
      throw ArgumentError('randomNonce must return 16 bytes');
    _generation = previousGeneration + 1;
    final proof = await resumeAcceptProof(
        resumeSecret: _previousResumeSecret,
        sessionId: _previousSessionId,
        nonceA: _nonceA!,
        nonceB: _nonceB!,
        transcript: _candidateTranscript,
        generation: _generation!);
    await _deriveResumedSecrets();
    await _sendCandidate(
        FrameType.resumeAccept,
        ResumeAccept(
                sessionId: _previousSessionId,
                nonceA: _nonceA!,
                nonceB: _nonceB!,
                generation: _generation!,
                proof: proof)
            .encode());
    await _sendResumedReady();
  }

  Future<void> _receiveAccept(LpcFrame frame) async {
    if (!requester || _nonceA == null || _nonceB != null) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final accept = ResumeAccept.decode(frame.payload);
    if (!_same(accept.sessionId, _previousSessionId) ||
        !_same(accept.nonceA, _nonceA!) ||
        accept.generation != previousGeneration + 1) {
      throw const LpcException(LpcErrorCode.resumeRejected);
    }
    await verifyResumeAcceptProof(
        resumeSecret: _previousResumeSecret,
        sessionId: _previousSessionId,
        nonceA: _nonceA!,
        nonceB: accept.nonceB,
        transcript: _candidateTranscript,
        generation: accept.generation,
        proof: accept.proof);
    _nonceB = accept.nonceB;
    _generation = accept.generation;
    await _deriveResumedSecrets();
    await _sendResumedReady();
  }

  Future<void> _deriveResumedSecrets() async {
    _resumedSecrets = await deriveResumedSecrets(
        candidateSessionRootKey: _candidateSessionRootKey,
        previousResumeSecret: _previousResumeSecret,
        sessionId: _previousSessionId,
        nonceA: _nonceA!,
        nonceB: _nonceB!,
        generation: _generation!);
  }

  Future<void> _sendCandidate(FrameType type, List<int> payload) async {
    final sequence = _nextCandidateOutbound++;
    final key = await candidateTrafficKey(
        _candidateSessionRootKey, _direction(localPeerId, remotePeerId));
    await _writeEncrypted(
        type: type,
        generation: 0,
        sequence: sequence,
        sessionId: _candidateSessionId,
        payload: payload,
        key: key);
  }

  /// Section 26.3 rejection is still authenticated under candidate keys.
  Future<void> _sendReject(LpcErrorCode error) async {
    final payload = ByteData(2)..setUint16(0, error.value);
    await _sendCandidate(FrameType.resumeReject, payload.buffer.asUint8List());
  }

  Future<void> _sendResumedReady() async {
    final secrets = _resumedSecrets!;
    final generation = _generation!;
    final key = await trafficKey(secrets.sessionRootKey, generation,
        _direction(localPeerId, remotePeerId));
    await _writeEncrypted(
        type: FrameType.resumeReady,
        generation: generation,
        sequence: 1,
        sessionId: _previousSessionId,
        payload: ResumeReady(_previousSessionId, generation).encode(),
        key: await key.extractBytes());
    _sentReady = true;
    _completeIfReady();
  }

  Future<void> _receiveReady(LpcFrame frame) async {
    final secrets = _resumedSecrets!;
    final generation = _generation!;
    if (!frame.encrypted ||
        frame.type != FrameType.resumeReady ||
        frame.protocolMinor != protocolMinor ||
        frame.flags != 0 ||
        frame.transportGeneration != generation ||
        frame.sequenceNumber != 1 ||
        !_same(frame.sessionId, _previousSessionId) ||
        frame.messageId.any((byte) => byte != 0)) {
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid RESUME_READY frame');
    }
    final key = await trafficKey(secrets.sessionRootKey, generation,
        _direction(remotePeerId, localPeerId));
    final clear =
        await const FrameProtector().decrypt(frame, await key.extractBytes());
    final ready = ResumeReady.decode(clear.payload);
    if (!_same(ready.sessionId, _previousSessionId) ||
        ready.generation != generation ||
        _receivedReady) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    _receivedReady = true;
    _completeIfReady();
  }

  Future<void> _writeEncrypted(
      {required FrameType type,
      required int generation,
      required int sequence,
      required List<int> sessionId,
      required List<int> payload,
      required List<int> key}) async {
    final protected = await const FrameProtector().encrypt(
        LpcFrame(
            type: type,
            flags: 0,
            transportGeneration: generation,
            sequenceNumber: sequence,
            messageId: List.filled(8, 0),
            sessionId: sessionId,
            nonce: List.filled(12, 0),
            payload: payload),
        key);
    final result = await backend.write(protected.encode()).completion;
    if (result != TransportWriteState.submittedToPlatform) {
      throw const LpcException(LpcErrorCode.transportClosed);
    }
  }

  void _completeIfReady() {
    if (!_sentReady || !_receivedReady || _completed.isCompleted) return;
    final secrets = _resumedSecrets!;
    _completed.complete(ResumedSession(
        sessionRootKey: secrets.sessionRootKey,
        resumeSecret: secrets.resumeSecret,
        sessionId: _previousSessionId,
        generation: _generation!));
    unawaited(_subscription?.cancel());
  }

  void _fail(Object error, [StackTrace? stackTrace]) {
    unawaited(_closeWithError(error, stackTrace));
  }

  Future<void> _closeWithError(Object error, [StackTrace? stackTrace]) async {
    if (!_completed.isCompleted) _completed.completeError(error, stackTrace);
    await _subscription?.cancel();
    await backend.close();
  }
}

int _direction(PeerId sender, PeerId receiver) =>
    _compare(sender.bytes, receiver.bytes) < 0 ? 0 : 1;

int _compare(List<int> a, List<int> b) {
  for (var index = 0; index < a.length; index++) {
    final comparison = a[index].compareTo(b[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

List<int> _secureNonce() =>
    List<int>.generate(16, (_) => Random.secure().nextInt(256));

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

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var result = 0;
  for (var i = 0; i < a.length; i++) {
    result |= a[i] ^ b[i];
  }
  return result == 0;
}

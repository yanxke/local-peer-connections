import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

class _ResumeBackend implements BackendConnection {
  _ResumeBackend(this.connectionId);
  @override
  final String connectionId;
  _ResumeBackend? remote;
  final writes = <Uint8List>[];
  final _events = StreamController<BackendConnectionEvent>.broadcast();
  @override
  TransportType get transportType => TransportType.gatt;
  @override
  TransportConnectionState get state => TransportConnectionState.open;
  @override
  int get maxWriteSize => 512;
  @override
  Stream<BackendConnectionEvent> get events => _events.stream;
  @override
  Future<void> close() async {}
  @override
  TransportWrite write(Uint8List frame) {
    writes.add(frame);
    final write = TransportWrite()..submittedToPlatform();
    Future<void>.microtask(
        () => remote!._events.add(BackendBytesReceived(frame)));
    return write;
  }
}

void main() {
  test('UT-023 candidate RESUME frame uses generation zero and candidate key',
      () async {
    final key = await candidateTrafficKey(List<int>.filled(32, 1), 0);
    final plain = LpcFrame(
        type: FrameType.resumeRequest,
        flags: 0,
        transportGeneration: 0,
        sequenceNumber: 1,
        messageId: List<int>.filled(8, 0),
        sessionId: List<int>.filled(16, 2),
        nonce: List<int>.filled(12, 0),
        payload: List<int>.filled(68, 3));
    final encrypted = await const FrameProtector().encrypt(plain, key);
    expect(encrypted.transportGeneration, 0);
    expect(encrypted.sequenceNumber, 1);
    expect(
        await const FrameProtector().decrypt(encrypted, key), isA<LpcFrame>());
  });

  test(
      'UT-024 RESUME request proof verifies and fixed payload is deterministic',
      () async {
    final proof = await resumeRequestProof(
        resumeSecret: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        nonceA: List.filled(16, 3),
        transcript: List.filled(32, 4));
    final request = ResumeRequest(
        sessionId: List.filled(16, 2),
        nonceA: List.filled(16, 3),
        previousGeneration: 1,
        proof: proof);
    expect(ResumeRequest.decode(request.encode()).proof, proof);
    await verifyResumeRequestProof(
        resumeSecret: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        nonceA: List.filled(16, 3),
        transcript: List.filled(32, 4),
        proof: proof);
  });

  test('UT-025 invalid RESUME request proof is rejected', () async {
    await expectLater(
        verifyResumeRequestProof(
            resumeSecret: List.filled(32, 1),
            sessionId: List.filled(16, 2),
            nonceA: List.filled(16, 3),
            transcript: List.filled(32, 4),
            proof: List.filled(32, 9)),
        throwsA(isA<LpcException>().having(
            (error) => error.code, 'code', LpcErrorCode.resumeRejected)));
  });

  test('UT-026 RESUME preserves SessionId and MessageId allocation state', () {
    final sessionId = List<int>.filled(16, 2);
    final messages = MessageIdAllocator([7, 8, 9, 10]);
    expect(messages.allocate(), [7, 8, 9, 10, 0, 0, 0, 1]);

    final resumed = ResumeReady.decode(ResumeReady(sessionId, 2).encode());
    expect(resumed.sessionId, sessionId);
    expect(messages.allocate(), [7, 8, 9, 10, 0, 0, 0, 2]);
  });

  test('RESUME_READY preserves SessionId and new generation', () {
    final ready = ResumeReady(List.filled(16, 1), 2);
    expect(ResumeReady.decode(ready.encode()).generation, 2);
  });
  test('RESUME_ACCEPT proof binds both nonces and its generation', () async {
    final proof = await resumeAcceptProof(
        resumeSecret: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        nonceA: List.filled(16, 3),
        nonceB: List.filled(16, 4),
        transcript: List.filled(32, 5),
        generation: 2);
    final accept = ResumeAccept(
        sessionId: List.filled(16, 2),
        nonceA: List.filled(16, 3),
        nonceB: List.filled(16, 4),
        generation: 2,
        proof: proof);
    expect(ResumeAccept.decode(accept.encode()).proof, proof);
    await verifyResumeAcceptProof(
        resumeSecret: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        nonceA: List.filled(16, 3),
        nonceB: List.filled(16, 4),
        transcript: List.filled(32, 5),
        generation: 2,
        proof: proof);
  });
  test('resumed root rotates with the new transport generation', () async {
    final one = await deriveResumedSecrets(
        candidateSessionRootKey: List.filled(32, 1),
        previousResumeSecret: List.filled(32, 2),
        sessionId: List.filled(16, 3),
        nonceA: List.filled(16, 4),
        nonceB: List.filled(16, 5),
        generation: 1);
    final two = await deriveResumedSecrets(
        candidateSessionRootKey: List.filled(32, 1),
        previousResumeSecret: List.filled(32, 2),
        sessionId: List.filled(16, 3),
        nonceA: List.filled(16, 4),
        nonceB: List.filled(16, 5),
        generation: 2);
    expect(one.sessionRootKey, isNot(two.sessionRootKey));
    expect(one.resumeSecret, isNot(two.resumeSecret));
  });

  test('UT-173 candidate exchange gates success on both RESUME_READY frames',
      () async {
    final aBackend = _ResumeBackend('a');
    final bBackend = _ResumeBackend('b');
    aBackend.remote = bBackend;
    bBackend.remote = aBackend;
    final a = CandidateResumeConnection(
        backend: aBackend,
        candidateSessionRootKey: List.filled(32, 1),
        candidateSessionId: List.filled(16, 2),
        candidateTranscript: List.filled(32, 3),
        localPeerId: PeerId(List.filled(16, 4)),
        remotePeerId: PeerId(List.filled(16, 5)),
        previousSessionId: List.filled(16, 6),
        previousResumeSecret: List.filled(32, 7),
        previousGeneration: 1,
        requester: true,
        randomNonce: () => List.filled(16, 8));
    final b = CandidateResumeConnection(
        backend: bBackend,
        candidateSessionRootKey: List.filled(32, 1),
        candidateSessionId: List.filled(16, 2),
        candidateTranscript: List.filled(32, 3),
        localPeerId: PeerId(List.filled(16, 5)),
        remotePeerId: PeerId(List.filled(16, 4)),
        previousSessionId: List.filled(16, 6),
        previousResumeSecret: List.filled(32, 7),
        previousGeneration: 1,
        requester: false,
        randomNonce: () => List.filled(16, 9));

    await b.start();
    await a.start();
    final sessions = await Future.wait([a.completed, b.completed])
        .timeout(const Duration(seconds: 2));

    expect(sessions.map((session) => session.sessionId),
        everyElement(List.filled(16, 6)));
    expect(sessions.map((session) => session.generation), everyElement(2));
    expect(aBackend.writes.map(LpcFrame.decode).map((frame) => frame.type),
        [FrameType.resumeRequest, FrameType.resumeReady]);
    expect(bBackend.writes.map(LpcFrame.decode).map((frame) => frame.type),
        [FrameType.resumeAccept, FrameType.resumeReady]);
    expect(LpcFrame.decode(aBackend.writes[0]).transportGeneration, 0);
    expect(LpcFrame.decode(aBackend.writes[1]).transportGeneration, 2);
  });

  test('UT-174 an unresumable request receives candidate RESUME_REJECT',
      () async {
    final aBackend = _ResumeBackend('a');
    final bBackend = _ResumeBackend('b');
    aBackend.remote = bBackend;
    bBackend.remote = aBackend;
    final a = CandidateResumeConnection(
        backend: aBackend,
        candidateSessionRootKey: List.filled(32, 1),
        candidateSessionId: List.filled(16, 2),
        candidateTranscript: List.filled(32, 3),
        localPeerId: PeerId(List.filled(16, 4)),
        remotePeerId: PeerId(List.filled(16, 5)),
        previousSessionId: List.filled(16, 6),
        previousResumeSecret: List.filled(32, 7),
        previousGeneration: 1,
        requester: true,
        randomNonce: () => List.filled(16, 8));
    final b = CandidateResumeConnection(
        backend: bBackend,
        candidateSessionRootKey: List.filled(32, 1),
        candidateSessionId: List.filled(16, 2),
        candidateTranscript: List.filled(32, 3),
        localPeerId: PeerId(List.filled(16, 5)),
        remotePeerId: PeerId(List.filled(16, 4)),
        previousSessionId: List.filled(16, 6),
        previousResumeSecret: List.filled(32, 9),
        previousGeneration: 1,
        requester: false,
        randomNonce: () => List.filled(16, 10));

    await b.start();
    await a.start();
    final rejected = isA<LpcException>()
        .having((error) => error.code, 'code', LpcErrorCode.resumeRejected);
    await Future.wait([
      expectLater(a.completed, throwsA(rejected)),
      expectLater(b.completed, throwsA(rejected)),
    ]);
    expect(
        LpcFrame.decode(bBackend.writes.single).type, FrameType.resumeReject);
  });
}

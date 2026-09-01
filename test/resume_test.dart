import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

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
}

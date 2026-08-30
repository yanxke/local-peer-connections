import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('RESUME_REQUEST proof and fixed payload are deterministic', () async {
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

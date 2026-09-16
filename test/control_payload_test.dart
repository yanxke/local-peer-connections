import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('pre-key protocol mismatch error uses the normal error payload layout',
      () {
    final payload =
        ErrorPayload(LpcErrorCode.protocolMismatch, 'minor mismatch');
    expect(ErrorPayload.decode(payload.encode()).code,
        LpcErrorCode.protocolMismatch);
  });
  test('UT-081/082 pre-key mismatch ERROR has exact plaintext header', () {
    final frame = preKeyProtocolMismatchError(
        senderMaxMinor: 0, diagnostic: 'no common minor');
    final parsed = LpcFrame.decode(frame.encode());
    expect(parsed.protocolMinor, 0);
    expect(parsed.encrypted, isFalse);
    expect(parsed.transportGeneration, 0);
    expect(parsed.sequenceNumber, 0);
    expect(
        parsePreKeyProtocolMismatchError(parsed).diagnostic, 'no common minor');
  });
  test('UT-083 plaintext ERROR rejects non-mismatch codes', () {
    final invalid = LpcFrame(
        type: FrameType.error,
        flags: 0,
        transportGeneration: 0,
        sequenceNumber: 0,
        messageId: List.filled(8, 0),
        sessionId: List.filled(16, 0),
        nonce: List.filled(12, 0),
        payload: ErrorPayload(LpcErrorCode.authenticationFailed).encode());
    expect(() => parsePreKeyProtocolMismatchError(invalid),
        throwsA(isA<LpcException>()));
  });
  test('READY is 32 bytes and dead timeout is at least three intervals', () {
    final ready = ReadyPayload(
        sessionId: List.filled(16, 1),
        peerCapabilities: 1,
        keepaliveIntervalMs: 2000,
        keepaliveDeadTimeoutMs: 6000,
        securityLevel: SecurityLevel.encryptedTofu);
    expect(ready.encode().length, 32);
    expect(ReadyPayload.decode(ready.encode()).securityLevel,
        SecurityLevel.encryptedTofu);
    expect(
        () => ReadyPayload(
            sessionId: List.filled(16, 1),
            peerCapabilities: 0,
            keepaliveIntervalMs: 1000,
            keepaliveDeadTimeoutMs: 3000,
            securityLevel: SecurityLevel.encryptedTofu),
        throwsA(isA<LpcException>()));
  });
  test('Section 18 rejects replay and sequence-window overflow', () {
    final window = ReceiveSequenceWindow();
    expect(window.accept(1), SequenceAcceptance.accepted);
    expect(window.accept(1), SequenceAcceptance.replay);
    expect(() => window.accept(1026), throwsA(isA<LpcException>()));
  });
}

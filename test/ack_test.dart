import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('ACK payload is exactly its acknowledged MessageId', () {
    final ack = AckPayload([1, 2, 3, 4, 5, 6, 7, 8]);
    expect(AckPayload.decode(ack.encode()).messageId, ack.messageId);
  });
  test('UT-054 ACK retry starts only after final frame submission', () {
    final op =
        RetainedAckOperation(messageId: List.filled(8, 1), logicalContent: [2]);
    expect(op.onAckTimeout(), AckTimeoutResult.ignored);
    op.finalFrameSubmitted();
    expect(op.onAckTimeout(), AckTimeoutResult.retransmitWholeOperation);
  });
  test('Section 23 gives exactly two retransmissions before ACK_TIMEOUT', () {
    final op =
        RetainedAckOperation(messageId: List.filled(8, 1), logicalContent: [2]);
    op.finalFrameSubmitted();
    expect(op.onAckTimeout(), AckTimeoutResult.retransmitWholeOperation);
    op.finalFrameSubmitted();
    expect(op.onAckTimeout(), AckTimeoutResult.retransmitWholeOperation);
    op.finalFrameSubmitted();
    expect(op.onAckTimeout(), AckTimeoutResult.terminalAckTimeout);
    expect(op.state, AckOperationState.failed);
  });

  test('ACK retention starts its deadline only after final submission', () {
    final retained = AckRetentionSet(capacity: 1);
    retained.retain(messageId: List.filled(8, 1), logicalContent: [2]);
    expect(retained.onTimer(List.filled(8, 1), nowMs: 10000),
        AckTimeoutResult.ignored);
    retained.finalFrameSubmitted(List.filled(8, 1), nowMs: 10);
    expect(retained.onTimer(List.filled(8, 1), nowMs: 3009),
        AckTimeoutResult.ignored);
    expect(retained.onTimer(List.filled(8, 1), nowMs: 3010),
        AckTimeoutResult.retransmitWholeOperation);
  });

  test('UT-056 long transmission starts no ACK timeout before final submission',
      () {
    final retained = AckRetentionSet();
    final id = List.filled(8, 1);
    retained.retain(messageId: id, logicalContent: [2]);
    // The operation has spent more than one timeout interval transmitting,
    // but its final frame has not reached SENT_TO_TRANSPORT yet.
    expect(retained.onTimer(id, nowMs: 5000), AckTimeoutResult.ignored);
    retained.finalFrameSubmitted(id, nowMs: 5000);
    expect(retained.onTimer(id, nowMs: 7999), AckTimeoutResult.ignored);
    expect(retained.onTimer(id, nowMs: 8000),
        AckTimeoutResult.retransmitWholeOperation);
  });

  test('UT-058 transport loss before final submission leaves no ACK timer', () {
    final retained = AckRetentionSet();
    final id = List.filled(8, 1);
    retained.retain(messageId: id, logicalContent: [2]);
    retained.transportLost();
    expect(retained.onTimer(id, nowMs: 10000), AckTimeoutResult.ignored);
    expect(retained.retransmitAfterResume(), hasLength(1));
  });

  test('UT-059 resumed retry starts a fresh timer only after submission', () {
    final retained = AckRetentionSet();
    final id = List.filled(8, 1);
    retained.retain(messageId: id, logicalContent: [2]);
    retained.finalFrameSubmitted(id, nowMs: 0);
    retained.transportLost();
    expect(retained.retransmitAfterResume(), hasLength(1));
    expect(retained.onTimer(id, nowMs: 10000), AckTimeoutResult.ignored);
    retained.finalFrameSubmitted(id, nowMs: 10000);
    expect(retained.onTimer(id, nowMs: 12999), AckTimeoutResult.ignored);
    expect(retained.onTimer(id, nowMs: 13000),
        AckTimeoutResult.retransmitWholeOperation);
  });

  test('RESUME retains and retries whole operations with their MessageId', () {
    final retained = AckRetentionSet();
    final op =
        retained.retain(messageId: List.filled(8, 3), logicalContent: [4]);
    retained.finalFrameSubmitted(op.messageId, nowMs: 0);
    retained.transportLost();
    final retry = retained.retransmitAfterResume();
    expect(retry, [op]);
    expect(retry.single.messageId, List.filled(8, 3));
    expect(op.retransmissions, 1);
  });
}

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

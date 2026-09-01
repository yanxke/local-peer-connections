import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test(
      'UT-020 completed reliable retransmission is not redelivered and ACKs again',
      () {
    final receiver = ReliableDataReceiver();
    final messageId = List<int>.filled(8, 1);
    final chunk = chunkData([7],
            mode: DeliveryMode.reliableAcked, priority: SendPriority.normal)
        .single;

    final first = receiver.add(messageId, chunk);
    expect(first.delivered!.bytes, [7]);
    expect(first.acknowledgmentMessageId, messageId);
    final duplicate = receiver.add(messageId, chunk);
    expect(duplicate.delivered, isNull);
    expect(duplicate.isDuplicate, isTrue);
    expect(duplicate.acknowledgmentMessageId, messageId);
  });

  test('completed MessageId with different content reports a collision', () {
    final receiver = ReliableDataReceiver();
    final id = List<int>.filled(8, 1);
    receiver.add(
        id,
        chunkData([7],
                mode: DeliveryMode.reliableAcked, priority: SendPriority.normal)
            .single);
    expect(
        () => receiver.add(
            id,
            chunkData([8],
                    mode: DeliveryMode.reliableAcked,
                    priority: SendPriority.normal)
                .single),
        throwsA(isA<LpcException>().having(
            (error) => error.code, 'code', LpcErrorCode.messageIdCollision)));
  });
}

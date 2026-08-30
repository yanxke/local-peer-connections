import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int n) => PeerId(List.filled(16, n));
void main() {
  test('destination group dedup delivers identical routed content once', () {
    final cache = CompletedGroupMessageDedup();
    final id = GroupMessageId(List.filled(16, 3));
    expect(
        cache.accept(
            source: _peer(1),
            messageId: id,
            destination: _peer(2),
            mode: DeliveryMode.reliableAcked,
            priority: SendPriority.normal,
            bytes: [9]),
        isTrue);
    expect(
        cache.accept(
            source: _peer(1),
            messageId: id,
            destination: _peer(2),
            mode: DeliveryMode.reliableAcked,
            priority: SendPriority.normal,
            bytes: [9]),
        isFalse);
  });
  test('same source and GroupMessageId with conflicting content is collision',
      () {
    final cache = CompletedGroupMessageDedup();
    final id = GroupMessageId(List.filled(16, 3));
    cache.accept(
        source: _peer(1),
        messageId: id,
        destination: _peer(2),
        mode: DeliveryMode.reliableAcked,
        priority: SendPriority.normal,
        bytes: [9]);
    expect(
        () => cache.accept(
            source: _peer(1),
            messageId: id,
            destination: _peer(2),
            mode: DeliveryMode.reliableAcked,
            priority: SendPriority.normal,
            bytes: [8]),
        throwsA(isA<LpcException>()));
  });
}

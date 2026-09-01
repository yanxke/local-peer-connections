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

  test('UT-147 destination dedup capacity is shared across source PeerIds', () {
    final cache = CompletedGroupMessageDedup(capacity: 2);
    bool accept(int source, int message) => cache.accept(
          source: _peer(source),
          messageId: GroupMessageId(List.filled(16, message)),
          destination: _peer(9),
          mode: DeliveryMode.reliableAcked,
          priority: SendPriority.normal,
          bytes: [message],
        );

    expect(accept(1, 1), isTrue);
    expect(accept(2, 2), isTrue);
    // A third entry from another source evicts the oldest entry in the one
    // destination-scoped cache; source 1 does not own a separate allocation.
    expect(accept(3, 3), isTrue);
    expect(accept(1, 1), isTrue);
  });

  test('UT-134 an evicted completed GroupMessageId may be delivered again', () {
    final cache = CompletedGroupMessageDedup(capacity: 2);
    bool accept(int message) => cache.accept(
          source: _peer(1),
          messageId: GroupMessageId(List.filled(16, message)),
          destination: _peer(9),
          mode: DeliveryMode.reliableAcked,
          priority: SendPriority.normal,
          bytes: [message],
        );

    expect(accept(1), isTrue);
    expect(accept(2), isTrue);
    expect(accept(3), isTrue); // Evicts message 1 from the bounded window.
    expect(accept(1), isTrue);
  });

  test('COORD-062 default dedup window evicts after 16,384 newer messages', () {
    final cache = CompletedGroupMessageDedup();
    GroupMessageId id(int value) => GroupMessageId(List.generate(
        16, (index) => index < 4 ? (value >> (index * 8)) & 0xff : 0));
    bool accept(int value) => cache.accept(
          source: _peer(1),
          messageId: id(value),
          destination: _peer(2),
          mode: DeliveryMode.reliableAcked,
          priority: SendPriority.normal,
          bytes: [value & 0xff],
        );

    expect(accept(0), isTrue);
    for (var value = 1; value <= 16384; value++) {
      expect(accept(value), isTrue);
    }
    expect(accept(0), isTrue);
  });
}

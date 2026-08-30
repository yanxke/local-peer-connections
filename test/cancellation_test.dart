import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test(
      'cancel tombstone correlates late route signaling without payload retention',
      () {
    final table = CancellationTombstoneTable();
    final id = GroupMessageId(List.filled(16, 1));
    final destination = PeerId(List.filled(16, 2));
    table.add(
        CancelledGroupSendTombstone(
            groupMessageId: id,
            destinationPeerId: destination,
            deliveryMode: DeliveryMode.reliableAcked),
        signalingSessionIds: [List.filled(16, 3)]);
    expect(table.lookup(messageId: id, destination: destination), isNotNull);
  });
  test('tombstone is immediately released after all capable sessions terminate',
      () {
    final table = CancellationTombstoneTable();
    final id = GroupMessageId(List.filled(16, 1));
    final destination = PeerId(List.filled(16, 2));
    table.add(
        CancelledGroupSendTombstone(
            groupMessageId: id,
            destinationPeerId: destination,
            deliveryMode: DeliveryMode.reliableOrdered),
        signalingSessionIds: [List.filled(16, 3)]);
    table.sessionTerminated(List.filled(16, 3));
    expect(table.length, 0);
  });
}

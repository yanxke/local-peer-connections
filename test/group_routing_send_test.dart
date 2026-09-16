import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int value) => PeerId(List.filled(16, value));
GroupId _group() => GroupId(List.filled(16, 1));
GroupMessageId _message(int value) => GroupMessageId(List.filled(16, value));

RoutedGroupOperation _operation({
  int message = 4,
  DeliveryMode mode = DeliveryMode.reliableAcked,
}) =>
    RoutedGroupOperation(
      groupId: _group(),
      sourcePeerId: _peer(2),
      destinationPeerId: _peer(3),
      groupMessageId: _message(message),
      deliveryMode: mode,
      priority: SendPriority.interactive,
      bytes: [1, 2],
    );

void main() {
  test('RELIABLE_ACKED completes only on GROUP_DELIVERY_ACK', () {
    final sends = RoutedSendTable(localPeerId: _peer(2));
    final operation = _operation();
    expect(sends.register(operation), SendState.transmitting);

    expect(
      sends.onDeliveryAck(GroupDeliveryAck(
        groupId: _group(),
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        groupMessageId: _message(4),
      )),
      SendState.remoteAcknowledged,
    );
    expect(sends.length, 0);
  });

  test('COORD-057 ordered send completes only after final-hop relay status',
      () {
    final sends = RoutedSendTable(localPeerId: _peer(2));
    final operation = _operation(mode: DeliveryMode.reliableOrdered);
    sends.register(operation);

    expect(
      sends.onRelayStatus(GroupRelayStatusPayload(
        groupId: _group(),
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        groupMessageId: _message(4),
        status: GroupRelayStatus.sentToDestinationTransport,
      )),
      SendState.sentToTransport,
    );
  });

  test('terminal relay status fails an active routed operation', () {
    final sends = RoutedSendTable(localPeerId: _peer(2));
    sends.register(_operation());

    expect(
      sends.onRelayStatus(GroupRelayStatusPayload(
        groupId: _group(),
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        groupMessageId: _message(4),
        status: GroupRelayStatus.destinationUnavailable,
      )),
      SendState.failed,
    );
    expect(sends.operationsToReroute(), isEmpty);
  });

  test('COORD-055 nonterminal send retains GroupMessageId for reroute', () {
    final sends = RoutedSendTable(localPeerId: _peer(2));
    final operation = _operation();
    sends.register(operation);

    expect(sends.operationsToReroute(), [operation]);
    expect(sends.cancel(operation.groupMessageId), operation);
    expect(sends.operationsToReroute(), isEmpty);
  });

  test('success signaling with the wrong delivery mode is rejected', () {
    final sends = RoutedSendTable(localPeerId: _peer(2));
    sends.register(_operation());
    expect(
      () => sends.onRelayStatus(GroupRelayStatusPayload(
        groupId: _group(),
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        groupMessageId: _message(4),
        status: GroupRelayStatus.sentToDestinationTransport,
      )),
      throwsA(isA<LpcException>()),
    );
  });
}

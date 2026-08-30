import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('GROUP_DELIVERY_ACK preserves stable group operation identity', () {
    final ack = GroupDeliveryAck(
        groupId: GroupId(List.filled(16, 1)),
        sourcePeerId: PeerId(List.filled(16, 2)),
        destinationPeerId: PeerId(List.filled(16, 3)),
        groupMessageId: GroupMessageId(List.filled(16, 4)));
    expect(GroupDeliveryAck.decode(ack.encode()).groupMessageId,
        ack.groupMessageId);
  });
  test('GROUP_RELAY_STATUS uses only its exact status/error mapping', () {
    final status = GroupRelayStatusPayload(
        groupId: GroupId(List.filled(16, 1)),
        sourcePeerId: PeerId(List.filled(16, 2)),
        destinationPeerId: PeerId(List.filled(16, 3)),
        groupMessageId: GroupMessageId(List.filled(16, 4)),
        status: GroupRelayStatus.destinationUnavailable);
    expect(GroupRelayStatusPayload.decode(status.encode()).errorCode,
        LpcErrorCode.destinationUnavailable);
  });
}

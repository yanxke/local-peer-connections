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
  test('UT-123 GROUP_RELAY_STATUS uses only exact status/error mappings', () {
    final expected = <GroupRelayStatus, LpcErrorCode?>{
      GroupRelayStatus.sentToDestinationTransport: null,
      GroupRelayStatus.destinationNotInGroup:
          LpcErrorCode.destinationNotInGroup,
      GroupRelayStatus.destinationUnavailable:
          LpcErrorCode.destinationUnavailable,
      GroupRelayStatus.destinationAckTimeout: LpcErrorCode.ackTimeout,
      GroupRelayStatus.relayQueueFull: LpcErrorCode.sendQueueFull,
      GroupRelayStatus.groupNotReady: LpcErrorCode.invalidState,
    };
    for (final entry in expected.entries) {
      final status = GroupRelayStatusPayload(
        groupId: GroupId(List.filled(16, 1)),
        sourcePeerId: PeerId(List.filled(16, 2)),
        destinationPeerId: PeerId(List.filled(16, 3)),
        groupMessageId: GroupMessageId(List.filled(16, 4)),
        status: entry.key,
      );
      expect(GroupRelayStatusPayload.decode(status.encode()).errorCode,
          entry.value);
    }
  });
}

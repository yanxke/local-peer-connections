import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int value) => PeerId(List.filled(16, value));

ReassembledGroupReliable _operation({
  int source = 2,
  int destination = 3,
  int message = 4,
  List<int> bytes = const [7, 8],
}) =>
    ReassembledGroupReliable(
      pairwiseMessageId: List.filled(8, 9),
      groupId: GroupId(List.filled(16, 1)),
      sourcePeerId: _peer(source),
      destinationPeerId: _peer(destination),
      groupMessageId: GroupMessageId(List.filled(16, message)),
      deliveryMode: DeliveryMode.reliableAcked,
      priority: SendPriority.interactive,
      bytes: bytes,
    );

void main() {
  final members = <PeerId>{_peer(1), _peer(2), _peer(3)};

  test('coordinator atomically admits and releases a destination relay', () {
    final relays = CoordinatorRelayTable(
      coordinatorPeerId: _peer(1),
      maxReservedBytesPerDestination: 10,
      maxReservedMessagesPerDestination: 1,
    );
    final operation = _operation();

    final admitted = relays.admit(
      operation,
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 10,
    );
    expect(admitted.kind, RelayAdmissionKind.forward);
    expect(admitted.sourceHopAcknowledged, isTrue);
    expect(relays.admittedRelayCount, 1);
    expect(relays.reservedBytesFor(_peer(3)), 10);

    expect(relays.complete(_peer(2), operation.groupMessageId), operation);
    expect(relays.admittedRelayCount, 0);
    expect(relays.reservedBytesFor(_peer(3)), 0);
  });

  test('relay admission reports exact non-retaining route failures', () {
    final relays = CoordinatorRelayTable(
      coordinatorPeerId: _peer(1),
      maxReservedBytesPerDestination: 1,
      maxReservedMessagesPerDestination: 1,
    );

    expect(
      relays
          .admit(
            _operation(),
            committedMembers: members,
            destinationReady: false,
            reservationBytes: 1,
          )
          .status,
      GroupRelayStatus.destinationUnavailable,
    );
    expect(
      relays
          .admit(
            _operation(destination: 4),
            committedMembers: members,
            destinationReady: true,
            reservationBytes: 1,
          )
          .status,
      GroupRelayStatus.destinationNotInGroup,
    );
    expect(
      relays
          .admit(
            _operation(),
            committedMembers: members,
            destinationReady: true,
            reservationBytes: 2,
          )
          .status,
      GroupRelayStatus.relayQueueFull,
    );
    expect(relays.admittedRelayCount, 0);
  });

  test('authority loss and destination removal release all affected relays',
      () {
    final relays = CoordinatorRelayTable(
      coordinatorPeerId: _peer(1),
      maxReservedBytesPerDestination: 10,
      maxReservedMessagesPerDestination: 2,
    );
    final first = _operation(message: 4);
    final second = _operation(message: 5);
    for (final operation in [first, second]) {
      relays.admit(
        operation,
        committedMembers: members,
        destinationReady: true,
        reservationBytes: 2,
      );
    }

    expect(relays.destinationRemoved(_peer(3)), [first, second]);
    expect(relays.reservedMessagesFor(_peer(3)), 0);

    relays.admit(
      first,
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 2,
    );
    expect(relays.coordinatorAuthorityLost(), [first]);
    expect(relays.admittedRelayCount, 0);
  });

  test('a duplicate admission is idempotent but collision is rejected', () {
    final relays = CoordinatorRelayTable(
      coordinatorPeerId: _peer(1),
      maxReservedBytesPerDestination: 10,
      maxReservedMessagesPerDestination: 1,
    );
    final operation = _operation();
    relays.admit(
      operation,
      committedMembers: members,
      destinationReady: true,
      reservationBytes: 2,
    );
    expect(
      relays
          .admit(
            operation,
            committedMembers: members,
            destinationReady: true,
            reservationBytes: 2,
          )
          .kind,
      RelayAdmissionKind.forward,
    );
    expect(relays.reservedMessagesFor(_peer(3)), 1);
    expect(
      () => relays.admit(
        _operation(bytes: [99]),
        committedMembers: members,
        destinationReady: true,
        reservationBytes: 2,
      ),
      throwsA(isA<LpcException>()),
    );
  });
}

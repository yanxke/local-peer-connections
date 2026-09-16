import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int value) => PeerId(List.filled(16, value));
GroupId _group() => GroupId(List.filled(16, 1));

GroupDestinationRouter _router() => GroupDestinationRouter(
      validator: GroupRoutingValidator(
        canonicalGroupId: _group(),
        localPeerId: _peer(3),
        currentCoordinatorPeerId: _peer(1),
        committedMembers: {_peer(1), _peer(2), _peer(3), _peer(4)},
      ),
    );

StaleCoordinatorClassifier _formerCoordinator() => StaleCoordinatorClassifier(
      immediatelyPreviousCoordinator: _peer(1),
      historicalSessionId: List.filled(16, 9),
    );

ReassembledGroupReliable _reliable({
  int source = 2,
  int message = 5,
  DeliveryMode mode = DeliveryMode.reliableAcked,
}) =>
    ReassembledGroupReliable(
      pairwiseMessageId: List.filled(8, 9),
      groupId: _group(),
      sourcePeerId: _peer(source),
      destinationPeerId: _peer(3),
      groupMessageId: GroupMessageId(List.filled(16, message)),
      deliveryMode: mode,
      priority: SendPriority.normal,
      bytes: [7],
    );

GroupRealtimeDatagram _realtime({int source = 2, int sequence = 1}) =>
    GroupRealtimeDatagram(
      groupId: _group(),
      sourcePeerId: _peer(source),
      destinationPeerId: _peer(3),
      channelId: 1,
      sequence: sequence,
      senderTick: 1,
      bytes: [sequence],
    );

void main() {
  test('UT-107/COORD-056 destination duplicate is ACKed but not redelivered',
      () {
    final router = _router();
    final operation = _reliable();
    final first =
        router.receiveReliable(operation, authenticatedSendingPeerId: _peer(1));
    final duplicate =
        router.receiveReliable(operation, authenticatedSendingPeerId: _peer(1));

    expect(first.disposition, ReliableDestinationDisposition.deliver);
    expect(duplicate.disposition, ReliableDestinationDisposition.duplicate);
    expect(first.requiresGenericAck, isTrue);
    expect(duplicate.requiresGenericAck, isTrue);
  });

  test('destination rejects a final hop not sent by current coordinator', () {
    expect(
      () => _router().receiveReliable(
        _reliable(),
        authenticatedSendingPeerId: _peer(2),
      ),
      throwsA(isA<LpcException>()),
    );
  });

  test('realtime latest suppression is scoped by source and channel', () {
    final router = _router();
    expect(
        router.receiveRealtime(_realtime(sequence: 2),
            authenticatedSendingPeerId: _peer(1)),
        isTrue);
    expect(
        router.receiveRealtime(_realtime(sequence: 1),
            authenticatedSendingPeerId: _peer(1)),
        isFalse);
    expect(
        router.receiveRealtime(_realtime(source: 4, sequence: 1),
            authenticatedSendingPeerId: _peer(1)),
        isTrue);
  });

  test('UT-152/COORD-067 stale former hop is ACKed but not delivered', () {
    final result = _router().receiveStaleReliable(
      _reliable(),
      classifier: _formerCoordinator(),
      authenticatedSendingPeerId: _peer(1),
      sessionId: List.filled(16, 9),
      wasInFlightBeforeAuthorityLoss: true,
      cryptographicallyAndFramingValid: true,
    );
    expect(result, StaleCoordinatorDisposition.genericAckAndDiscard);
  });

  test('complete stale ordered reliable hop is discarded without ACK', () {
    final result = _router().receiveStaleReliable(
      _reliable(mode: DeliveryMode.reliableOrdered),
      classifier: _formerCoordinator(),
      authenticatedSendingPeerId: _peer(1),
      sessionId: List.filled(16, 9),
      wasInFlightBeforeAuthorityLoss: true,
      cryptographicallyAndFramingValid: true,
    );
    expect(result, StaleCoordinatorDisposition.discard);
  });

  test(
    'UT-155 former coordinator cannot originate new routing after authority loss',
    () {
      expect(
        () => _router().receiveStaleReliable(
          _reliable(),
          classifier: _formerCoordinator(),
          authenticatedSendingPeerId: _peer(1),
          sessionId: List.filled(16, 9),
          wasInFlightBeforeAuthorityLoss: false,
          cryptographicallyAndFramingValid: true,
        ),
        throwsA(
          isA<LpcException>().having(
            (error) => error.code,
            'code',
            LpcErrorCode.protocolMismatch,
          ),
        ),
      );
    },
  );

  test('UT-154 stale realtime is discarded before destination delivery', () {
    final router = _router();
    final stale = router.receiveStaleRealtime(
      _realtime(sequence: 5),
      classifier: _formerCoordinator(),
      authenticatedSendingPeerId: _peer(1),
      sessionId: List.filled(16, 9),
      wasSubmittedBeforeAuthorityLoss: true,
      cryptographicallyAndFramingValid: true,
    );
    expect(stale, StaleCoordinatorDisposition.discard);
    expect(
      router.receiveRealtime(
        _realtime(sequence: 1),
        authenticatedSendingPeerId: _peer(1),
      ),
      isTrue,
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int value) => PeerId(List.filled(16, value));

void main() {
  final classifier = StaleCoordinatorClassifier(
    immediatelyPreviousCoordinator: _peer(1),
    historicalSessionId: List.filled(16, 9),
  );

  test('historical ACK-required route signaling is ACKed and discarded', () {
    expect(
      classifier.classifySignaling(
        authenticatedSender: _peer(1),
        sessionId: List.filled(16, 9),
        createdBeforeAuthorityLoss: true,
        historicalRouteIsValid: true,
        cryptographicallyAndSequenceValid: true,
        genericAckRequiredValid: true,
      ),
      StaleCoordinatorDisposition.genericAckAndDiscard,
    );
  });

  test('new, invalid, or wrong-session former-coordinator signaling rejects',
      () {
    expect(
      classifier.classifySignaling(
        authenticatedSender: _peer(1),
        sessionId: List.filled(16, 9),
        createdBeforeAuthorityLoss: false,
        historicalRouteIsValid: true,
        cryptographicallyAndSequenceValid: true,
        genericAckRequiredValid: true,
      ),
      StaleCoordinatorDisposition.reject,
    );
    expect(
      classifier.classifySignaling(
        authenticatedSender: _peer(1),
        sessionId: List.filled(16, 8),
        createdBeforeAuthorityLoss: true,
        historicalRouteIsValid: true,
        cryptographicallyAndSequenceValid: true,
        genericAckRequiredValid: true,
      ),
      StaleCoordinatorDisposition.reject,
    );
  });

  test('complete stale ACK-required reliable operation is ACKed and discarded',
      () {
    expect(
      classifier.classifyReliable(
        authenticatedSender: _peer(1),
        sessionId: List.filled(16, 9),
        wasInFlightBeforeAuthorityLoss: true,
        cryptographicallyAndFramingValid: true,
        ackRequired: true,
        completeOperation: true,
      ),
      StaleCoordinatorDisposition.genericAckAndDiscard,
    );
    expect(
      classifier.classifyReliable(
        authenticatedSender: _peer(1),
        sessionId: List.filled(16, 9),
        wasInFlightBeforeAuthorityLoss: true,
        cryptographicallyAndFramingValid: true,
        ackRequired: true,
        completeOperation: false,
      ),
      StaleCoordinatorDisposition.discard,
    );
  });

  test('valid stale realtime is discarded without acknowledgment', () {
    expect(
      classifier.classifyRealtime(
        authenticatedSender: _peer(1),
        sessionId: List.filled(16, 9),
        wasSubmittedBeforeAuthorityLoss: true,
        cryptographicallyAndFramingValid: true,
      ),
      StaleCoordinatorDisposition.discard,
    );
  });
}

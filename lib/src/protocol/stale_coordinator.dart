import '../types.dart';

/// Required treatment of coordinator-authoritative traffic received after a
/// coordinator transition has committed.
enum StaleCoordinatorDisposition { reject, discard, genericAckAndDiscard }

/// Section 43.1.11 classifier for the intentionally narrow historical
/// authority exception. All boolean inputs are facts established by the live
/// authenticated frame/route owner; this class never treats a former
/// coordinator as having current authority.
class StaleCoordinatorClassifier {
  StaleCoordinatorClassifier({
    required this.immediatelyPreviousCoordinator,
    required List<int> historicalSessionId,
  }) : _historicalSessionId = List<int>.unmodifiable(historicalSessionId) {
    if (_historicalSessionId.length != 16) {
      throw ArgumentError.value(historicalSessionId, 'historicalSessionId');
    }
  }

  final PeerId immediatelyPreviousCoordinator;
  final List<int> _historicalSessionId;

  /// `GROUP_DELIVERY_ACK` and `GROUP_RELAY_STATUS` are ACKed normally but
  /// semantically discarded only when every historical-authority condition
  /// has already been established.
  StaleCoordinatorDisposition classifySignaling({
    required PeerId authenticatedSender,
    required List<int> sessionId,
    required bool createdBeforeAuthorityLoss,
    required bool historicalRouteIsValid,
    required bool cryptographicallyAndSequenceValid,
    required bool genericAckRequiredValid,
  }) {
    if (!_historicalCandidate(
          authenticatedSender: authenticatedSender,
          sessionId: sessionId,
          historicalRouteIsValid: historicalRouteIsValid,
          cryptographicallyAndSequenceValid: cryptographicallyAndSequenceValid,
        ) ||
        !createdBeforeAuthorityLoss ||
        !genericAckRequiredValid) {
      return StaleCoordinatorDisposition.reject;
    }
    return StaleCoordinatorDisposition.genericAckAndDiscard;
  }

  /// `GROUP_RELIABLE` from the former coordinator never reaches the
  /// application after migration. A complete, already-in-flight ACK-required
  /// operation can receive its generic ACK; all other valid stale traffic is
  /// silently discarded.
  StaleCoordinatorDisposition classifyReliable({
    required PeerId authenticatedSender,
    required List<int> sessionId,
    required bool wasInFlightBeforeAuthorityLoss,
    required bool cryptographicallyAndFramingValid,
    required bool ackRequired,
    required bool completeOperation,
  }) {
    if (!_historicalCandidate(
      authenticatedSender: authenticatedSender,
      sessionId: sessionId,
      historicalRouteIsValid: wasInFlightBeforeAuthorityLoss,
      cryptographicallyAndSequenceValid: cryptographicallyAndFramingValid,
    )) {
      return StaleCoordinatorDisposition.reject;
    }
    return ackRequired && completeOperation
        ? StaleCoordinatorDisposition.genericAckAndDiscard
        : StaleCoordinatorDisposition.discard;
  }

  /// A valid realtime datagram from the former coordinator is silently
  /// discarded, never delivered, and never treated as protocol corruption.
  StaleCoordinatorDisposition classifyRealtime({
    required PeerId authenticatedSender,
    required List<int> sessionId,
    required bool wasSubmittedBeforeAuthorityLoss,
    required bool cryptographicallyAndFramingValid,
  }) =>
      _historicalCandidate(
        authenticatedSender: authenticatedSender,
        sessionId: sessionId,
        historicalRouteIsValid: wasSubmittedBeforeAuthorityLoss,
        cryptographicallyAndSequenceValid: cryptographicallyAndFramingValid,
      )
          ? StaleCoordinatorDisposition.discard
          : StaleCoordinatorDisposition.reject;

  bool _historicalCandidate({
    required PeerId authenticatedSender,
    required List<int> sessionId,
    required bool historicalRouteIsValid,
    required bool cryptographicallyAndSequenceValid,
  }) =>
      authenticatedSender == immediatelyPreviousCoordinator &&
      _same(sessionId, _historicalSessionId) &&
      historicalRouteIsValid &&
      cryptographicallyAndSequenceValid;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var result = 0;
  for (var index = 0; index < a.length; index++) {
    result |= a[index] ^ b[index];
  }
  return result == 0;
}

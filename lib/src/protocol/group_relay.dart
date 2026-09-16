import '../types.dart';
import 'group_reliable.dart';
import 'group_signaling.dart';

/// The outcome of coordinator relay admission after a complete authenticated
/// source hop. Every outcome means that the source hop can receive its generic
/// ACK; only [forward] reserves final-hop queue capacity.
enum RelayAdmissionKind { deliverLocally, forward, status }

class RelayAdmission {
  const RelayAdmission._(this.kind,
      {this.operation, this.status, this.forwardImmediately = false});

  const RelayAdmission.deliverLocally(ReassembledGroupReliable operation)
      : this._(RelayAdmissionKind.deliverLocally, operation: operation);

  const RelayAdmission.forward(ReassembledGroupReliable operation,
      {required bool forwardImmediately})
      : this._(RelayAdmissionKind.forward,
            operation: operation, forwardImmediately: forwardImmediately);

  const RelayAdmission.status(GroupRelayStatus status)
      : this._(RelayAdmissionKind.status, status: status);

  final RelayAdmissionKind kind;
  final ReassembledGroupReliable? operation;
  final GroupRelayStatus? status;
  final bool forwardImmediately;

  /// Section 43.1.3 requires a generic source-hop ACK after every complete,
  /// valid admission decision, including route-admission failure.
  bool get sourceHopAcknowledged => true;
}

/// Bounded coordinator ownership for admitted `GROUP_RELIABLE` relays.
///
/// This deliberately owns no transport or retry mechanism. Its caller first
/// authenticates and reassembles a source hop, then uses the returned outcome
/// to emit generic ACK / route signaling and submit a destination hop. Queue
/// capacity is supplied in the same accounting units as the destination
/// peer's reliable scheduler.
class CoordinatorRelayTable {
  CoordinatorRelayTable({
    required this.coordinatorPeerId,
    required this.maxReservedBytesPerDestination,
    required this.maxReservedMessagesPerDestination,
  }) {
    if (maxReservedBytesPerDestination < 0 ||
        maxReservedMessagesPerDestination < 1) {
      throw ArgumentError('invalid relay reservation limits');
    }
  }

  final PeerId coordinatorPeerId;
  final int maxReservedBytesPerDestination;
  final int maxReservedMessagesPerDestination;
  final Map<String, _AdmittedRelay> _operations = {};
  final Map<PeerId, _DestinationReservation> _reservations = {};
  final Map<String, List<String>> _sourceDestinationOrder = {};

  int get admittedRelayCount => _operations.length;

  int reservedBytesFor(PeerId destination) =>
      _reservations[destination]?.bytes ?? 0;

  int reservedMessagesFor(PeerId destination) =>
      _reservations[destination]?.messages ?? 0;

  /// Atomically admits a complete source-hop operation or returns its exact
  /// route failure. A non-ready destination is never retained for later
  /// recovery (Section 43.1.3).
  RelayAdmission admit(
    ReassembledGroupReliable operation, {
    required Set<PeerId> committedMembers,
    required bool destinationReady,
    required int reservationBytes,
  }) {
    if (reservationBytes < 0) {
      throw ArgumentError.value(reservationBytes, 'reservationBytes');
    }
    if (!committedMembers.contains(operation.sourcePeerId) ||
        operation.destinationPeerId == operation.sourcePeerId) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    if (!committedMembers.contains(operation.destinationPeerId)) {
      return const RelayAdmission.status(
          GroupRelayStatus.destinationNotInGroup);
    }
    if (operation.destinationPeerId == coordinatorPeerId) {
      return RelayAdmission.deliverLocally(operation);
    }
    if (!destinationReady) {
      return const RelayAdmission.status(
          GroupRelayStatus.destinationUnavailable);
    }

    final key = _operationKey(operation);
    final existing = _operations[key];
    if (existing != null) {
      existing.validateEquivalent(operation, reservationBytes);
      return RelayAdmission.forward(existing.operation,
          forwardImmediately: false);
    }

    final reservation = _reservations.putIfAbsent(
        operation.destinationPeerId, _DestinationReservation.new);
    if (reservation.bytes + reservationBytes > maxReservedBytesPerDestination ||
        reservation.messages + 1 > maxReservedMessagesPerDestination) {
      if (reservation.empty) _reservations.remove(operation.destinationPeerId);
      return const RelayAdmission.status(GroupRelayStatus.relayQueueFull);
    }
    reservation.bytes += reservationBytes;
    reservation.messages++;
    _operations[key] = _AdmittedRelay(operation, reservationBytes);
    final order = _sourceDestinationOrder.putIfAbsent(
        _sourceDestinationKey(
            operation.sourcePeerId, operation.destinationPeerId),
        () => <String>[]);
    order.add(key);
    return RelayAdmission.forward(operation,
        forwardImmediately: order.length == 1);
  }

  /// Releases a relay after its final-hop terminal result. It is harmless for
  /// an already-released operation, which lets completion and authority-loss
  /// paths race without double-releasing a reservation.
  ReassembledGroupReliable? complete(
      PeerId source, GroupMessageId groupMessageId) {
    final relay = _operations.remove(_operationKeyFrom(source, groupMessageId));
    if (relay == null) return null;
    _removeFromOrder(relay.operation);
    _release(relay);
    return relay.operation;
  }

  /// Returns the one relay that may begin final-hop submission after the
  /// preceding operation for this exact source/destination pair terminates.
  ReassembledGroupReliable? takeNextForward(PeerId source, PeerId destination) {
    final order =
        _sourceDestinationOrder[_sourceDestinationKey(source, destination)];
    if (order == null || order.isEmpty) return null;
    return _operations[order.first]?.operation;
  }

  /// Section 43.1.12: terminate every nonterminal relay for a removed target.
  List<ReassembledGroupReliable> destinationRemoved(PeerId destination) =>
      _removeWhere((relay) => relay.operation.destinationPeerId == destination);

  /// Returns every per-source/destination head that may be submitted after a
  /// destination PeerConnection successfully resumes. The operations remain
  /// admitted, and therefore continue to consume their original bounded
  /// reservation; the caller retransmits each complete operation from chunk 0.
  List<ReassembledGroupReliable> forwardableForDestination(PeerId destination) {
    final forwardable = <ReassembledGroupReliable>[];
    for (final relay in _operations.values) {
      final operation = relay.operation;
      if (operation.destinationPeerId != destination) continue;
      if (identical(
          takeNextForward(operation.sourcePeerId, destination), operation)) {
        forwardable.add(operation);
      }
    }
    return List.unmodifiable(forwardable);
  }

  /// The destination remains a committed member but its reconnect/RESUME has
  /// failed terminally. All retained relays to it must release reservations.
  List<ReassembledGroupReliable> destinationUnavailable(PeerId destination) =>
      _removeWhere((relay) => relay.operation.destinationPeerId == destination);

  /// Section 43.1.10: a former coordinator stops all unfinished routing,
  /// releases all reservations, and retains no reroute ownership.
  List<ReassembledGroupReliable> coordinatorAuthorityLost() =>
      _removeWhere((_) => true);

  List<ReassembledGroupReliable> _removeWhere(
      bool Function(_AdmittedRelay relay) predicate) {
    final removed = <ReassembledGroupReliable>[];
    for (final entry in _operations.entries.toList()) {
      if (!predicate(entry.value)) continue;
      _operations.remove(entry.key);
      _removeFromOrder(entry.value.operation);
      _release(entry.value);
      removed.add(entry.value.operation);
    }
    return List.unmodifiable(removed);
  }

  void _release(_AdmittedRelay relay) {
    final destination = relay.operation.destinationPeerId;
    final reservation = _reservations[destination]!;
    reservation.bytes -= relay.reservationBytes;
    reservation.messages--;
    if (reservation.empty) _reservations.remove(destination);
  }

  void _removeFromOrder(ReassembledGroupReliable operation) {
    final key = _sourceDestinationKey(
        operation.sourcePeerId, operation.destinationPeerId);
    final order = _sourceDestinationOrder[key];
    if (order == null) return;
    order.remove(_operationKey(operation));
    if (order.isEmpty) _sourceDestinationOrder.remove(key);
  }
}

class _AdmittedRelay {
  _AdmittedRelay(this.operation, this.reservationBytes);
  final ReassembledGroupReliable operation;
  final int reservationBytes;

  void validateEquivalent(
      ReassembledGroupReliable candidate, int candidateReservationBytes) {
    if (candidateReservationBytes != reservationBytes ||
        candidate.destinationPeerId != operation.destinationPeerId ||
        candidate.deliveryMode != operation.deliveryMode ||
        candidate.priority != operation.priority ||
        !_same(candidate.bytes, operation.bytes)) {
      throw const LpcException(LpcErrorCode.messageIdCollision);
    }
  }
}

class _DestinationReservation {
  int bytes = 0;
  int messages = 0;
  bool get empty => bytes == 0 && messages == 0;
}

String _operationKey(ReassembledGroupReliable operation) =>
    _operationKeyFrom(operation.sourcePeerId, operation.groupMessageId);

String _operationKeyFrom(PeerId source, GroupMessageId groupMessageId) =>
    '$source:${groupMessageId.bytes.join(',')}';

String _sourceDestinationKey(PeerId source, PeerId destination) =>
    '$source:$destination';

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var result = 0;
  for (var index = 0; index < a.length; index++) {
    result |= a[index] ^ b[index];
  }
  return result == 0;
}

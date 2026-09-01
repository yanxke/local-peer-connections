import '../types.dart';

class CancelledGroupSendTombstone {
  const CancelledGroupSendTombstone(
      {required this.groupMessageId,
      required this.destinationPeerId,
      required this.deliveryMode});
  final GroupMessageId groupMessageId;
  final PeerId destinationPeerId;
  final DeliveryMode deliveryMode;
  bool matches(
          {required GroupMessageId messageId, required PeerId destination}) =>
      messageId == groupMessageId && destination == destinationPeerId;
}

/// Bounded Section 36.8.1 tombstone ownership. No application payload or retry
/// state is retained. A caller releases a session when it can no longer convey
/// a valid late route-signaling operation.
class CancellationTombstoneTable {
  CancellationTombstoneTable({this.capacity = 1024}) : assert(capacity > 0);
  final int capacity;
  final Map<GroupMessageId, _TombstoneState> _entries = {};

  /// Whether one more cancellation tombstone can be retained. Source routing
  /// reserves this capacity when accepting a new operation, so cancellation
  /// itself never needs to evict a still-valid tombstone.
  bool get canReserve => _entries.length < capacity;

  void add(CancelledGroupSendTombstone tombstone,
      {required Iterable<List<int>> signalingSessionIds}) {
    final sessions = signalingSessionIds.map(_sessionKey).toSet();
    if (sessions.isEmpty) return;
    if (_entries.length >= capacity &&
        !_entries.containsKey(tombstone.groupMessageId)) {
      throw const LpcException(
          LpcErrorCode.resourceExhausted, 'cancellation tombstone capacity');
    }
    _entries[tombstone.groupMessageId] = _TombstoneState(tombstone, sessions);
  }

  CancelledGroupSendTombstone? lookup(
      {required GroupMessageId messageId, required PeerId destination}) {
    final value = _entries[messageId]?.tombstone;
    return value != null &&
            value.matches(messageId: messageId, destination: destination)
        ? value
        : null;
  }

  void sessionTerminated(List<int> sessionId) {
    final key = _sessionKey(sessionId);
    for (final entry in _entries.entries.toList()) {
      entry.value.sessions.remove(key);
      if (entry.value.sessions.isEmpty) _entries.remove(entry.key);
    }
  }

  void clear() => _entries.clear();
  int get length => _entries.length;
}

class _TombstoneState {
  _TombstoneState(this.tombstone, this.sessions);
  final CancelledGroupSendTombstone tombstone;
  final Set<String> sessions;
}

String _sessionKey(List<int> bytes) {
  if (bytes.length != 16) throw ArgumentError.value(bytes, 'sessionId');
  return bytes.join(',');
}

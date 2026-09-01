import 'membership.dart';
import 'reliability.dart';
import '../types.dart';

/// Result of receiving one complete, authenticated MEMBERSHIP_SNAPSHOT.
///
/// A non-null [acknowledgmentMessageId] means the owner must send the generic
/// ACK.  This includes duplicate and stale snapshots, but only a newly
/// accepted snapshot has a non-null [committed] value.
class MembershipSnapshotReceiveResult {
  const MembershipSnapshotReceiveResult._(
      {this.committed, required this.acknowledgmentMessageId});

  final MembershipSnapshot? committed;
  final List<int> acknowledgmentMessageId;
  bool get isDuplicateOrStale => committed == null;
}

/// Section 10.8/10.8.1 receive boundary for ACK-required snapshots.
///
/// The owner supplies already authenticated peer/session identity and
/// serializes calls for a receive direction. [commit] is invoked once for a
/// newly accepted snapshot. Complete duplicates and stale snapshots remain
/// ACK-eligible but never reapply committed membership.
class MembershipSnapshotReceiver {
  MembershipSnapshotReceiver(
      {MembershipSnapshotOrderTable? ordering, CompletedMessageDedup? dedup})
      : _ordering = ordering ?? MembershipSnapshotOrderTable(),
        _dedup = dedup ?? CompletedMessageDedup();

  final MembershipSnapshotOrderTable _ordering;
  final CompletedMessageDedup _dedup;

  Future<MembershipSnapshotReceiveResult> add({
    required List<int> messageId,
    required List<int> sessionId,
    required PeerId coordinatorPeerId,
    required List<int> payload,
    required void Function(MembershipSnapshot snapshot) commit,
  }) async {
    if (messageId.length != 8 || sessionId.length != 16) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final dedupId = <int>[...sessionId, ...messageId];
    if (_dedup.isDuplicate(dedupId, payload)) {
      return MembershipSnapshotReceiveResult._(
          acknowledgmentMessageId: List<int>.unmodifiable(messageId));
    }

    final snapshot = await MembershipSnapshot.decode(payload);
    final disposition = _ordering.observe(
      coordinatorPeerId: coordinatorPeerId,
      coordinatorTerm: snapshot.coordinatorTerm,
      sessionId: sessionId,
      senderMessageId: messageId,
    );
    if (disposition == MembershipSnapshotOrderDisposition.stale) {
      _dedup.accept(dedupId, payload);
      return MembershipSnapshotReceiveResult._(
          acknowledgmentMessageId: List<int>.unmodifiable(messageId));
    }

    commit(snapshot);
    _dedup.accept(dedupId, payload);
    return MembershipSnapshotReceiveResult._(
      committed: snapshot,
      acknowledgmentMessageId: List<int>.unmodifiable(messageId),
    );
  }
}

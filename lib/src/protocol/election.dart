import 'dart:typed_data';
import '../types.dart';
import 'membership.dart';

class ElectionAnnouncement {
  ElectionAnnouncement(
      {required this.groupId,
      required this.candidateTerm,
      required this.rank,
      required List<int> membershipHash})
      : membershipHash = Uint8List.fromList(membershipHash) {
    if (this.membershipHash.length != 32)
      throw ArgumentError.value(membershipHash, 'membershipHash');
  }
  final GroupId groupId;
  final int candidateTerm;
  final CoordinatorRank rank;
  final Uint8List membershipHash;
  Uint8List encode() {
    final b = ByteData(76);
    b.buffer.asUint8List().setRange(0, 16, groupId.bytes);
    b.setUint64(16, candidateTerm);
    b.setUint16(24, rank.applicationPriority);
    b.setUint16(26, rank.capabilityScore);
    b.buffer.asUint8List().setRange(28, 44, rank.peerId.bytes);
    b.buffer.asUint8List().setRange(44, 76, membershipHash);
    return b.buffer.asUint8List();
  }

  static ElectionAnnouncement decode(List<int> input) {
    if (input.length != 76)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final b = ByteData.sublistView(Uint8List.fromList(input));
    return ElectionAnnouncement(
        groupId: GroupId(input.sublist(0, 16)),
        candidateTerm: b.getUint64(16),
        rank: CoordinatorRank(
            b.getUint16(24), b.getUint16(26), PeerId(input.sublist(28, 44))),
        membershipHash: input.sublist(44));
  }
}

class CoordinatorResign {
  CoordinatorResign(
      {required this.groupId, required this.term, required this.peerId});
  final GroupId groupId;
  final int term;
  final PeerId peerId;
  Uint8List encode() {
    final b = ByteData(40);
    b.buffer.asUint8List().setRange(0, 16, groupId.bytes);
    b.setUint64(16, term);
    b.buffer.asUint8List().setRange(24, 40, peerId.bytes);
    return b.buffer.asUint8List();
  }

  static CoordinatorResign decode(List<int> input) {
    if (input.length != 40)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final b = ByteData.sublistView(Uint8List.fromList(input));
    return CoordinatorResign(
        groupId: GroupId(input.sublist(0, 16)),
        term: b.getUint64(16),
        peerId: PeerId(input.sublist(24)));
  }
}

ElectionAnnouncement highestElectionCandidate(
        Iterable<ElectionAnnouncement> candidates) =>
    candidates.reduce((best, candidate) {
      if (candidate.candidateTerm != best.candidateTerm)
        return candidate.candidateTerm > best.candidateTerm ? candidate : best;
      return candidate.rank.compareTo(best.rank) > 0 ? candidate : best;
    });
bool mayClaimCoordinator(
        {required CoordinatorRank localRank,
        required int candidateTerm,
        required Iterable<ElectionAnnouncement> observed}) =>
    observed.where((item) => item.candidateTerm >= candidateTerm).every(
        (item) =>
            item.candidateTerm == candidateTerm &&
            localRank.compareTo(item.rank) >= 0);

/// Timer-free Section 10.9 election driver. The owner transports its returned
/// announcements, claims, and heartbeats only over authenticated links.
class ElectionController {
  ElectionController(
      {required this.groupId,
      required this.localRank,
      required int lastCommittedTerm,
      required List<int> membershipHash,
      required int startedAtMs})
      : candidateTerm = lastCommittedTerm + 1,
        _startedAtMs = startedAtMs,
        _membershipHash = Uint8List.fromList(membershipHash) {
    if (_membershipHash.length != 32) {
      throw ArgumentError.value(membershipHash, 'membershipHash');
    }
    _localAnnouncement = ElectionAnnouncement(
        groupId: groupId,
        candidateTerm: candidateTerm,
        rank: localRank,
        membershipHash: _membershipHash);
    _observed[_key(candidateTerm, localRank.peerId)] = _localAnnouncement;
  }

  static const int announcementWindowMs = 1200;
  static const int higherRankQuietMs = 500;
  static const int heartbeatSpacingMs = 100;

  final GroupId groupId;
  final CoordinatorRank localRank;
  final int candidateTerm, _startedAtMs;
  final Uint8List _membershipHash;
  late final ElectionAnnouncement _localAnnouncement;
  final Map<String, ElectionAnnouncement> _observed = {};
  int? _claimSentAtMs;
  int? _higherObservedAtMs;
  int _nextHeartbeatIndex = 0;
  bool _coordinator = false;

  ElectionAnnouncement get localAnnouncement => _localAnnouncement;
  bool get isCoordinator => _coordinator;

  /// Records an authenticated announcement or claim. It returns true exactly
  /// when a lower-ranked claim requires the local peer to re-announce.
  bool observe(ElectionAnnouncement message,
      {required bool isClaim, required int nowMs}) {
    if (message.groupId != groupId) {
      throw const LpcException(LpcErrorCode.protocolMismatch, 'wrong GroupId');
    }
    _observed[_key(message.candidateTerm, message.rank.peerId)] = message;
    final higher = message.candidateTerm > candidateTerm ||
        (message.candidateTerm == candidateTerm &&
            message.rank.compareTo(localRank) > 0);
    if (higher) _higherObservedAtMs = nowMs;
    return isClaim &&
        message.candidateTerm == candidateTerm &&
        localRank.compareTo(message.rank) > 0;
  }

  /// Advances the exact election deadlines and returns every action currently
  /// due. At most one heartbeat is produced per call, preserving 100 ms gaps.
  List<ElectionAction> poll(int nowMs) {
    final actions = <ElectionAction>[];
    if (_coordinator) {
      if (_nextHeartbeatIndex < 3 &&
          nowMs >=
              _claimSentAtMs! +
                  higherRankQuietMs +
                  _nextHeartbeatIndex * heartbeatSpacingMs) {
        actions.add(ElectionHeartbeat(_nextHeartbeatIndex));
        _nextHeartbeatIndex++;
      }
      return actions;
    }
    if (_claimSentAtMs == null &&
        nowMs >= _startedAtMs + announcementWindowMs &&
        mayClaimCoordinator(
            localRank: localRank,
            candidateTerm: candidateTerm,
            observed: _observed.values)) {
      _claimSentAtMs = nowMs;
      actions.add(ElectionClaim(_localAnnouncement));
    }
    if (_claimSentAtMs != null &&
        _higherObservedAtMs == null &&
        nowMs >= _claimSentAtMs! + higherRankQuietMs) {
      _coordinator = true;
      actions.add(const ElectionBecameCoordinator());
      actions.add(ElectionHeartbeat(_nextHeartbeatIndex));
      _nextHeartbeatIndex++;
    }
    return actions;
  }

  static String _key(int term, PeerId peerId) =>
      '$term:${peerId.bytes.join(',')}';
}

sealed class ElectionAction {
  const ElectionAction();
}

class ElectionClaim extends ElectionAction {
  const ElectionClaim(this.message);
  final ElectionAnnouncement message;
}

class ElectionHeartbeat extends ElectionAction {
  const ElectionHeartbeat(this.index);
  final int index;
}

class ElectionBecameCoordinator extends ElectionAction {
  const ElectionBecameCoordinator();
}

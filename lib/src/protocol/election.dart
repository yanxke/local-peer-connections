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

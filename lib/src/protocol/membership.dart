import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../types.dart';

class CoordinatorRank implements Comparable<CoordinatorRank> {
  const CoordinatorRank(
      this.applicationPriority, this.capabilityScore, this.peerId);
  final int applicationPriority, capabilityScore;
  final PeerId peerId;
  @override
  int compareTo(CoordinatorRank other) {
    final priority = applicationPriority.compareTo(other.applicationPriority);
    if (priority != 0) return priority;
    final score = capabilityScore.compareTo(other.capabilityScore);
    if (score != 0) return score;
    for (var i = 0; i < 16; i++) {
      final diff = peerId.bytes[i].compareTo(other.peerId.bytes[i]);
      if (diff != 0) return diff;
    }
    return 0;
  }
}

int coordinatorCapabilityScore(
        {required bool lanListen,
        required bool l2capListen,
        required bool gattPeripheral,
        required bool gattCentral}) =>
    (lanListen ? 8 : 0) +
    (l2capListen ? 4 : 0) +
    (gattPeripheral ? 2 : 0) +
    (gattCentral ? 1 : 0);

Future<Uint8List> canonicalMembershipHash(List<GroupMember> members) async {
  final canonical = _canonical(members);
  return Uint8List.fromList((await Sha256().hash(canonical)).bytes);
}

Uint8List _canonical(List<GroupMember> members) {
  final sorted = [...members]
    ..sort((a, b) => _compare(a.peerId.bytes, b.peerId.bytes));
  if (sorted.length > 0xffff ||
      sorted.any((member) => member.maxPeers < 1 || member.maxPeers > 31))
    throw const LpcException(LpcErrorCode.protocolMismatch);
  for (var i = 1; i < sorted.length; i++) {
    if (_compare(sorted[i - 1].peerId.bytes, sorted[i].peerId.bytes) == 0)
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'duplicate member');
  }
  final output = ByteData(2 + sorted.length * 18);
  output.setUint16(0, sorted.length);
  for (var i = 0; i < sorted.length; i++) {
    output.buffer
        .asUint8List()
        .setRange(2 + i * 18, 18 + i * 18, sorted[i].peerId.bytes);
    output.setUint16(18 + i * 18, sorted[i].maxPeers);
  }
  return output.buffer.asUint8List();
}

class MembershipSnapshot {
  MembershipSnapshot(
      {required this.groupId,
      required this.coordinatorTerm,
      required List<GroupMember> members,
      List<int>? hash})
      : members = List.unmodifiable(members),
        hash = hash == null ? null : Uint8List.fromList(hash) {
    if (this.hash != null && this.hash!.length != 32)
      throw ArgumentError.value(hash, 'hash');
  }
  final GroupId groupId;
  final int coordinatorTerm;
  final List<GroupMember> members;
  final Uint8List? hash;
  Future<Uint8List> encode() async {
    final canonical = _canonical(members);
    final digest = await canonicalMembershipHash(members);
    final output = BytesBuilder(copy: false);
    final h = ByteData(26)
      ..setUint64(16, coordinatorTerm)
      ..setUint16(24, members.length);
    h.buffer.asUint8List().setRange(0, 16, groupId.bytes);
    output.add(h.buffer.asUint8List());
    output.add(canonical.sublist(2));
    output.add(digest);
    return output.toBytes();
  }

  static Future<MembershipSnapshot> decode(List<int> input) async {
    if (input.length < 58)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final raw = Uint8List.fromList(input);
    final h = ByteData.sublistView(raw);
    final count = h.getUint16(24);
    if (input.length != 26 + count * 18 + 32)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final members = <GroupMember>[];
    for (var i = 0; i < count; i++) {
      final offset = 26 + i * 18;
      members.add(GroupMember(
          PeerId(raw.sublist(offset, offset + 16)), h.getUint16(offset + 16)));
    }
    final expected = await canonicalMembershipHash(members);
    final supplied = raw.sublist(input.length - 32);
    if (!_same(expected, supplied))
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'membership hash mismatch');
    return MembershipSnapshot(
        groupId: GroupId(raw.sublist(0, 16)),
        coordinatorTerm: h.getUint64(16),
        members: members,
        hash: supplied);
  }
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    final result = a[i].compareTo(b[i]);
    if (result != 0) return result;
  }
  return 0;
}

bool _same(List<int> a, List<int> b) {
  var result = a.length ^ b.length;
  for (var i = 0; i < a.length && i < b.length; i++) {
    result |= a[i] ^ b[i];
  }
  return result == 0;
}

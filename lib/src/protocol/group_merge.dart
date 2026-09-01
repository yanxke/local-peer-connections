import '../types.dart';
import 'membership.dart';
import 'dart:typed_data';

enum GroupMergeDecision {
  merge,
  namespaceMismatch,
  autoMergeDisabled,
  discoveryModeMismatch,
  joinTokenMismatch,
  trustModeMismatch,
  knownPeersAutoMergeDisabled,
  groupFull,
  sameGroup
}

enum GroupMergeRejectReason {
  groupFull,
  namespaceMismatch,
  joinTokenMismatch,
  autoMergeDisabled,
  discoveryModeMismatch,
  staleTerm
}

class GroupMergeRejectPayload {
  const GroupMergeRejectPayload(
      {required this.localGroupId,
      required this.remoteGroupId,
      required this.reason,
      required this.effectiveMaxPeers,
      required this.candidateUnionCount});
  final GroupId localGroupId, remoteGroupId;
  final GroupMergeRejectReason reason;
  final int effectiveMaxPeers, candidateUnionCount;
  Uint8List encode() {
    final out = ByteData(38);
    out.buffer.asUint8List().setRange(0, 16, localGroupId.bytes);
    out.buffer.asUint8List().setRange(16, 32, remoteGroupId.bytes);
    out.setUint16(32, reason.index + 1);
    out.setUint16(34, effectiveMaxPeers);
    out.setUint16(36, candidateUnionCount);
    return out.buffer.asUint8List();
  }

  static GroupMergeRejectPayload decode(List<int> bytes) {
    if (bytes.length != 38)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final b = ByteData.sublistView(Uint8List.fromList(bytes));
    final reason = b.getUint16(32);
    if (reason < 1 || reason > 6)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    return GroupMergeRejectPayload(
        localGroupId: GroupId(bytes.sublist(0, 16)),
        remoteGroupId: GroupId(bytes.sublist(16, 32)),
        reason: GroupMergeRejectReason.values[reason - 1],
        effectiveMaxPeers: b.getUint16(34),
        candidateUnionCount: b.getUint16(36));
  }
}

class GroupMergePayload {
  GroupMergePayload(
      {required this.winningGroupId,
      required this.losingGroupId,
      required this.newCoordinatorTerm,
      required this.effectiveMaxPeers,
      required List<GroupMember> members})
      : members = List.unmodifiable(members) {
    if (effectiveMaxPeers < 1 ||
        effectiveMaxPeers > 31 ||
        this.members.length > effectiveMaxPeers)
      throw const LpcException(LpcErrorCode.groupFull);
  }
  final GroupId winningGroupId, losingGroupId;
  final int newCoordinatorTerm, effectiveMaxPeers;
  final List<GroupMember> members;
  Future<Uint8List> encode() async {
    final hash = await canonicalMembershipHash(members);
    final out = BytesBuilder(copy: false);
    final h = ByteData(44);
    h.buffer.asUint8List().setRange(0, 16, winningGroupId.bytes);
    h.buffer.asUint8List().setRange(16, 32, losingGroupId.bytes);
    h.setUint64(32, newCoordinatorTerm);
    h.setUint16(40, effectiveMaxPeers);
    h.setUint16(42, members.length);
    out.add(h.buffer.asUint8List());
    for (final member in members) {
      final r = ByteData(18);
      r.buffer.asUint8List().setRange(0, 16, member.peerId.bytes);
      r.setUint16(16, member.maxPeers);
      out.add(r.buffer.asUint8List());
    }
    out.add(hash);
    return out.toBytes();
  }

  static Future<GroupMergePayload> decode(List<int> bytes) async {
    if (bytes.length < 76)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final raw = Uint8List.fromList(bytes);
    final h = ByteData.sublistView(raw);
    final count = h.getUint16(42);
    if (bytes.length != 44 + count * 18 + 32)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final members = <GroupMember>[];
    PeerId? previous;
    for (var i = 0; i < count; i++) {
      final at = 44 + i * 18;
      final peer = PeerId(raw.sublist(at, at + 16));
      if (previous != null && _compare(previous.bytes, peer.bytes) >= 0)
        throw const LpcException(LpcErrorCode.protocolMismatch);
      members.add(GroupMember(peer, h.getUint16(at + 16)));
      previous = peer;
    }
    if (!_same(
        await canonicalMembershipHash(members), raw.sublist(bytes.length - 32)))
      throw const LpcException(LpcErrorCode.protocolMismatch);
    return GroupMergePayload(
        winningGroupId: GroupId(raw.sublist(0, 16)),
        losingGroupId: GroupId(raw.sublist(16, 32)),
        newCoordinatorTerm: h.getUint64(32),
        effectiveMaxPeers: h.getUint16(40),
        members: members);
  }
}

class GroupMergeInfo {
  GroupMergeInfo(
      {required List<int> namespaceHash,
      required this.discoveryMode,
      required this.autoMerge,
      required this.trustMode,
      required this.knownPeersAutoMerge,
      required List<int> tokenHash,
      required this.groupId,
      required List<GroupMember> members})
      : namespaceHash = List.unmodifiable(namespaceHash),
        tokenHash = List.unmodifiable(tokenHash),
        members = List.unmodifiable(members) {
    if (this.namespaceHash.length != 32 || this.tokenHash.length != 32)
      throw ArgumentError('group hashes must be 32 bytes');
  }
  final List<int> namespaceHash, tokenHash;
  final DiscoveryMode discoveryMode;
  final bool autoMerge, knownPeersAutoMerge;
  final GroupTrustMode trustMode;
  final GroupId groupId;
  final List<GroupMember> members;
}

/// Section 31.2 GROUP_INFO payload. This codec preserves record order on decode
/// so malformed non-canonical membership cannot be silently normalized.
class GroupInfoPayload {
  GroupInfoPayload(
      {required this.info,
      required this.coordinatorTerm,
      required this.coordinatorPeerId}) {
    if (coordinatorPeerId != null && coordinatorPeerId!.bytes.length != 16)
      throw ArgumentError.value(coordinatorPeerId, 'coordinatorPeerId');
  }
  final GroupMergeInfo info;
  final int coordinatorTerm;
  final PeerId? coordinatorPeerId;
  Future<Uint8List> encode() async {
    final hash = await canonicalMembershipHash(info.members);
    final head = ByteData(110);
    head.buffer.asUint8List().setRange(0, 32, info.namespaceHash);
    head.setUint8(32, info.discoveryMode.index + 1);
    head.setUint8(33, info.autoMerge ? 1 : 0);
    head.setUint8(34, info.trustMode.index + 1);
    head.setUint8(35, info.knownPeersAutoMerge ? 1 : 0);
    head.buffer.asUint8List().setRange(36, 68, info.tokenHash);
    head.buffer.asUint8List().setRange(68, 84, info.groupId.bytes);
    head.setUint64(84, coordinatorTerm);
    head.buffer
        .asUint8List()
        .setRange(92, 108, coordinatorPeerId?.bytes ?? List.filled(16, 0));
    head.setUint16(108, info.members.length);
    final body = BytesBuilder(copy: false)..add(head.buffer.asUint8List());
    for (final m in info.members) {
      final record = ByteData(18);
      record.buffer.asUint8List().setRange(0, 16, m.peerId.bytes);
      record.setUint16(16, m.maxPeers);
      body.add(record.buffer.asUint8List());
    }
    body.add(hash);
    return body.toBytes();
  }

  static Future<GroupInfoPayload> decode(List<int> input) async {
    if (input.length < 142)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final raw = Uint8List.fromList(input);
    final h = ByteData.sublistView(raw);
    final count = h.getUint16(108);
    if (input.length != 110 + count * 18 + 32 ||
        h.getUint8(33) > 1 ||
        h.getUint8(35) > 1 ||
        h.getUint8(32) < 1 ||
        h.getUint8(32) > 2 ||
        h.getUint8(34) < 1 ||
        h.getUint8(34) > 4)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final mode = DiscoveryMode.values[h.getUint8(32) - 1];
    final trust = GroupTrustMode.values[h.getUint8(34) - 1];
    if (trust != GroupTrustMode.knownPeers && h.getUint8(35) != 0)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final members = <GroupMember>[];
    PeerId? previous;
    for (var i = 0; i < count; i++) {
      final offset = 110 + i * 18;
      final peer = PeerId(raw.sublist(offset, offset + 16));
      if (previous != null && _compare(previous.bytes, peer.bytes) >= 0)
        throw const LpcException(LpcErrorCode.protocolMismatch,
            'noncanonical GROUP_INFO membership');
      members.add(GroupMember(peer, h.getUint16(offset + 16)));
      previous = peer;
    }
    final computed = await canonicalMembershipHash(members);
    if (!_same(computed, raw.sublist(input.length - 32)))
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'GROUP_INFO membership hash');
    final coordinatorBytes = raw.sublist(92, 108);
    final coordinator = coordinatorBytes.every((byte) => byte == 0)
        ? null
        : PeerId(coordinatorBytes);
    return GroupInfoPayload(
        info: GroupMergeInfo(
            namespaceHash: raw.sublist(0, 32),
            tokenHash: raw.sublist(36, 68),
            discoveryMode: mode,
            autoMerge: h.getUint8(33) == 1,
            trustMode: trust,
            knownPeersAutoMerge: h.getUint8(35) == 1,
            groupId: GroupId(raw.sublist(68, 84)),
            members: members),
        coordinatorTerm: h.getUint64(84),
        coordinatorPeerId: coordinator);
  }
}

class GroupMergeEvaluation {
  const GroupMergeEvaluation(this.decision,
      {this.winner, this.effectiveMaxPeers = 0, this.unionCount = 0});
  final GroupMergeDecision decision;
  final GroupMergeInfo? winner;
  final int effectiveMaxPeers, unionCount;
}

GroupMergeEvaluation evaluateGroupMerge(GroupMergeInfo a, GroupMergeInfo b) {
  if (_compare(a.namespaceHash, b.namespaceHash) != 0)
    return const GroupMergeEvaluation(GroupMergeDecision.namespaceMismatch);
  if (!a.autoMerge || !b.autoMerge)
    return const GroupMergeEvaluation(GroupMergeDecision.autoMergeDisabled);
  if (a.discoveryMode != b.discoveryMode)
    return const GroupMergeEvaluation(GroupMergeDecision.discoveryModeMismatch);
  if (a.discoveryMode == DiscoveryMode.tokenScoped &&
      _compare(a.tokenHash, b.tokenHash) != 0)
    return const GroupMergeEvaluation(GroupMergeDecision.joinTokenMismatch);
  if (a.trustMode != b.trustMode)
    return const GroupMergeEvaluation(GroupMergeDecision.trustModeMismatch);
  if (a.trustMode == GroupTrustMode.knownPeers &&
      (!a.knownPeersAutoMerge || !b.knownPeersAutoMerge))
    return const GroupMergeEvaluation(
        GroupMergeDecision.knownPeersAutoMergeDisabled);
  if (a.groupId == b.groupId)
    return const GroupMergeEvaluation(GroupMergeDecision.sameGroup);
  final records = <PeerId, GroupMember>{};
  for (final record in [...a.members, ...b.members]) {
    final prior = records[record.peerId];
    records[record.peerId] = prior == null
        ? record
        : GroupMember(
            record.peerId,
            prior.maxPeers < record.maxPeers
                ? prior.maxPeers
                : record.maxPeers);
  }
  final capacity = records.values
      .map((record) => record.maxPeers)
      .reduce((x, y) => x < y ? x : y);
  final winner = a.members.length != b.members.length
      ? (a.members.length > b.members.length ? a : b)
      : (_compare(a.groupId.bytes, b.groupId.bytes) < 0 ? a : b);
  return GroupMergeEvaluation(
      records.length > capacity
          ? GroupMergeDecision.groupFull
          : GroupMergeDecision.merge,
      winner: winner,
      effectiveMaxPeers: capacity,
      unionCount: records.length);
}

/// Selects the deterministic winner while a set of mutually compatible groups
/// converge. Every pair must be merge-compatible; the same GroupMergeRank used
/// for pairwise merge is folded across the set.
GroupMergeInfo selectConvergedMergeWinner(Iterable<GroupMergeInfo> groups) {
  final values = groups.toList(growable: false);
  if (values.isEmpty) throw ArgumentError.value(groups, 'groups');
  var winner = values.first;
  for (final candidate in values.skip(1)) {
    final evaluation = evaluateGroupMerge(winner, candidate);
    if (evaluation.decision != GroupMergeDecision.merge ||
        evaluation.winner == null) {
      throw const LpcException(LpcErrorCode.groupMergeRejected);
    }
    winner = evaluation.winner!;
  }
  return winner;
}

/// Section 31.3/31.4: only the would-be winning coordinator emits a rejection
/// when the complete candidate union exceeds effective capacity. Compatibility
/// failures simply prevent automatic merge and do not generate this frame.
GroupMergeRejectPayload? groupMergeRejectForWinner({
  required GroupMergeInfo local,
  required GroupMergeInfo remote,
  required GroupMergeEvaluation evaluation,
}) {
  if (evaluation.decision != GroupMergeDecision.groupFull ||
      evaluation.winner != local) {
    return null;
  }
  return GroupMergeRejectPayload(
    localGroupId: local.groupId,
    remoteGroupId: remote.groupId,
    reason: GroupMergeRejectReason.groupFull,
    effectiveMaxPeers: evaluation.effectiveMaxPeers,
    candidateUnionCount: evaluation.unionCount,
  );
}

/// Result of applying a complete authenticated GROUP_MERGE at one member.
enum GroupMergeReceiveDisposition { applied, duplicate, stale }

/// Section 31.6 stale-term boundary. The caller supplies only decoded,
/// authenticated payloads; this state owner prevents an older/equal conflicting
/// merge from replacing committed GroupId, term, or membership.
class GroupMergeReceiver {
  GroupMergeReceiver({
    required GroupId committedGroupId,
    required int committedTerm,
    required Iterable<GroupMember> committedMembers,
  })  : _groupId = committedGroupId,
        _term = committedTerm,
        _members = List.unmodifiable(committedMembers.toList());

  GroupId _groupId;
  int _term;
  List<GroupMember> _members;
  GroupMergePayload? _lastApplied;

  GroupId get groupId => _groupId;
  int get term => _term;
  List<GroupMember> get members => _members;

  GroupMergeReceiveDisposition receive(GroupMergePayload payload) {
    if (payload.newCoordinatorTerm < _term) {
      return GroupMergeReceiveDisposition.stale;
    }
    if (payload.newCoordinatorTerm == _term) {
      return _matchesLastApplied(payload)
          ? GroupMergeReceiveDisposition.duplicate
          : GroupMergeReceiveDisposition.stale;
    }
    _groupId = payload.winningGroupId;
    _term = payload.newCoordinatorTerm;
    _members = payload.members;
    _lastApplied = payload;
    return GroupMergeReceiveDisposition.applied;
  }

  bool _matchesLastApplied(GroupMergePayload candidate) {
    final applied = _lastApplied;
    if (applied == null ||
        applied.winningGroupId != candidate.winningGroupId ||
        applied.losingGroupId != candidate.losingGroupId ||
        applied.newCoordinatorTerm != candidate.newCoordinatorTerm ||
        applied.effectiveMaxPeers != candidate.effectiveMaxPeers ||
        applied.members.length != candidate.members.length) {
      return false;
    }
    for (var index = 0; index < applied.members.length; index++) {
      final left = applied.members[index];
      final right = candidate.members[index];
      if (left.peerId != right.peerId || left.maxPeers != right.maxPeers) {
        return false;
      }
    }
    return true;
  }
}

/// Section 31.6 losing-GroupId alias. The authenticated reconnect owner calls
/// [redirect] only after it has validated the joining peer's identity/trust.
class GroupMergeAlias {
  GroupMergeAlias({
    required this.losingGroupId,
    required this.winningGroupId,
    required this.installedAtMs,
  });

  static const int lifetimeMs = 30000;
  final GroupId losingGroupId;
  final GroupId winningGroupId;
  final int installedAtMs;

  GroupId? redirect(GroupId presentedGroupId, {required int nowMs}) {
    if (nowMs < installedAtMs || nowMs - installedAtMs >= lifetimeMs) {
      return null;
    }
    return presentedGroupId == losingGroupId ? winningGroupId : null;
  }
}

/// Reconciled same-GroupId state from Section 31.7. Conflicting authenticated
/// capacity records collapse to their minimum; capacity overflow is surfaced
/// rather than silently evicting a committed member.
class SplitBrainReconciliation {
  const SplitBrainReconciliation({
    required this.coordinatorTerm,
    required this.members,
    required this.effectiveMaxPeers,
  });

  final int coordinatorTerm;
  final List<GroupMember> members;
  final int effectiveMaxPeers;
}

SplitBrainReconciliation reconcileSameGroupSplitBrain({
  required int termA,
  required int termB,
  required Iterable<GroupMember> snapshotA,
  required Iterable<GroupMember> snapshotB,
  Iterable<GroupMember> reachableMembers = const [],
}) {
  if (termA < 0 || termB < 0) {
    throw const LpcException(LpcErrorCode.protocolMismatch);
  }
  final records = <PeerId, GroupMember>{};
  for (final record in [...snapshotA, ...snapshotB, ...reachableMembers]) {
    final prior = records[record.peerId];
    records[record.peerId] = prior == null
        ? record
        : GroupMember(
            record.peerId,
            prior.maxPeers < record.maxPeers
                ? prior.maxPeers
                : record.maxPeers);
  }
  if (records.isEmpty) {
    throw const LpcException(LpcErrorCode.protocolMismatch);
  }
  final members = records.values.toList()
    ..sort((left, right) => _compare(left.peerId.bytes, right.peerId.bytes));
  final effectiveMaxPeers = members
      .map((member) => member.maxPeers)
      .reduce((left, right) => left < right ? left : right);
  if (members.length > effectiveMaxPeers) {
    throw const LpcException(LpcErrorCode.groupFull);
  }
  return SplitBrainReconciliation(
    coordinatorTerm: (termA > termB ? termA : termB) + 1,
    members: List.unmodifiable(members),
    effectiveMaxPeers: effectiveMaxPeers,
  );
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    final d = a[i].compareTo(b[i]);
    if (d != 0) return d;
  }
  return 0;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var result = 0;
  for (var i = 0; i < a.length; i++) {
    result |= a[i] ^ b[i];
  }
  return result == 0;
}

import 'dart:typed_data';
import '../types.dart';

const Duration coordinatorHeartbeatInterval = Duration(seconds: 1);
const Duration coordinatorHeartbeatTimeout = Duration(seconds: 3);

class CoordinatorHeartbeat {
  CoordinatorHeartbeat(
      {required this.groupId,
      required this.term,
      required this.coordinatorPeerId,
      required List<int> membershipHash})
      : membershipHash = Uint8List.fromList(membershipHash) {
    if (this.membershipHash.length != 32)
      throw ArgumentError.value(membershipHash, 'membershipHash');
  }
  final GroupId groupId;
  final int term;
  final PeerId coordinatorPeerId;
  final Uint8List membershipHash;
  Uint8List encode() {
    final data = ByteData(72);
    data.buffer.asUint8List().setRange(0, 16, groupId.bytes);
    data.setUint64(16, term);
    data.buffer.asUint8List().setRange(24, 40, coordinatorPeerId.bytes);
    data.buffer.asUint8List().setRange(40, 72, membershipHash);
    return data.buffer.asUint8List();
  }

  static CoordinatorHeartbeat decode(List<int> bytes) {
    if (bytes.length != 72)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    return CoordinatorHeartbeat(
        groupId: GroupId(bytes.sublist(0, 16)),
        term: data.getUint64(16),
        coordinatorPeerId: PeerId(bytes.sublist(24, 40)),
        membershipHash: bytes.sublist(40));
  }
}

/// Time-only liveness helper. The group state machine calls [observe] for every
/// valid heartbeat or other authenticated coordinator frame.
class CoordinatorLiveness {
  CoordinatorLiveness({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  DateTime? _lastObserved;
  void observe() => _lastObserved = _clock();
  bool get unavailable =>
      _lastObserved == null ||
      _clock().difference(_lastObserved!) >= coordinatorHeartbeatTimeout;
}

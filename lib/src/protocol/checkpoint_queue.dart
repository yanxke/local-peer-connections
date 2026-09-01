import 'dart:typed_data';
import '../types.dart';

class CheckpointReplicationOperation {
  CheckpointReplicationOperation(this.sequence, List<int> bytes)
      : bytes = Uint8List.fromList(bytes);
  final int sequence;
  final Uint8List bytes;
}

/// Section 31.11 queue for a single target peer and one coordinator term.
/// Pending values are deliberately not assigned sequence/MessageId ownership.
class CheckpointReplicationQueue {
  CheckpointReplicationOperation? _inFlight;
  Uint8List? _pending;
  int _nextSequence = 1;
  bool _exhausted = false;
  CheckpointReplicationOperation? get inFlight => _inFlight;
  bool get hasPending => _pending != null;
  CheckpointReplicationOperation? publish(List<int> bytes) {
    if (bytes.length > 262144)
      throw const LpcException(LpcErrorCode.messageTooLarge);
    if (_inFlight != null) {
      _pending = Uint8List.fromList(bytes);
      return null;
    }
    return _promote(bytes);
  }

  CheckpointReplicationOperation? completeInFlight() {
    _inFlight = null;
    final next = _pending;
    _pending = null;
    return next == null ? null : _promote(next);
  }

  CheckpointReplicationOperation _promote(List<int> bytes) {
    if (_exhausted) throw const LpcException(LpcErrorCode.resourceExhausted);
    final result = CheckpointReplicationOperation(_nextSequence, bytes);
    if (_nextSequence == 0xffffffffffffffff)
      _exhausted = true;
    else
      _nextSequence++;
    _inFlight = result;
    return result;
  }
}

/// Bounded coordinator checkpoint replication ownership for one coordinator
/// term. It retains one latest application value for future READY peers and
/// delegates wire-operation promotion independently to each target queue.
class CoordinatorCheckpointReplicator {
  final Map<PeerId, CheckpointReplicationQueue> _queues = {};
  Uint8List? _latest;

  Uint8List? get latestCheckpoint =>
      _latest == null ? null : Uint8List.fromList(_latest!);

  CheckpointReplicationQueue queueFor(PeerId peer) =>
      _queues.putIfAbsent(peer, CheckpointReplicationQueue.new);

  /// Replaces the retained application value, then offers it to the supplied
  /// READY target snapshot. Each target receives its own promotion sequence.
  Map<PeerId, CheckpointReplicationOperation> publish(
      List<int> bytes, Iterable<PeerId> readyTargets) {
    if (bytes.length > 262144) {
      throw const LpcException(LpcErrorCode.messageTooLarge);
    }
    _latest = Uint8List.fromList(bytes);
    final promoted = <PeerId, CheckpointReplicationOperation>{};
    for (final peer in readyTargets.toSet()) {
      final operation = queueFor(peer).publish(_latest!);
      if (operation != null) promoted[peer] = operation;
    }
    return Map.unmodifiable(promoted);
  }

  /// Schedules only the currently retained value for a peer that became READY
  /// or resynchronized; historical publications are never reconstructed.
  CheckpointReplicationOperation? peerReady(PeerId peer) {
    final latest = _latest;
    return latest == null ? null : queueFor(peer).publish(latest);
  }

  CheckpointReplicationOperation? completeInFlight(PeerId peer) =>
      _queues[peer]?.completeInFlight();

  /// Called after target removal or terminal session loss. Both bounded slots
  /// are released and no historical checkpoint is retained per target.
  void removeTarget(PeerId peer) => _queues.remove(peer);
}

import 'dart:typed_data';
import 'dart:math';
import '../types.dart';

/// Section 24's negotiated timings. Dead timeout is derived, never supplied
/// independently by a peer.
class KeepaliveTiming {
  KeepaliveTiming._(this.intervalMs, this.deadTimeoutMs);
  final int intervalMs;
  final int deadTimeoutMs;

  static KeepaliveTiming negotiate(int localIntervalMs, int remoteIntervalMs) {
    _validate(localIntervalMs);
    _validate(remoteIntervalMs);
    final interval =
        localIntervalMs > remoteIntervalMs ? localIntervalMs : remoteIntervalMs;
    return KeepaliveTiming._(
        interval, (3 * interval) > 6000 ? 3 * interval : 6000);
  }

  static void _validate(int value) {
    if (value < 1000 || value > 10000) {
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid keepalive interval');
    }
  }
}

/// Exact 16-byte PING/PONG body. A PONG copies the received payload without
/// interpretation, including the sender's monotonic diagnostic timestamp.
class PingPayload {
  PingPayload(List<int> pingId, this.monotonicSenderTimeUs)
      : pingId = Uint8List.fromList(pingId) {
    if (this.pingId.length != 8) {
      throw ArgumentError.value(pingId, 'pingId');
    }
  }
  final Uint8List pingId;
  final int monotonicSenderTimeUs;

  Uint8List encode() {
    final bytes = ByteData(16);
    bytes.buffer.asUint8List().setRange(0, 8, pingId);
    bytes.setUint64(8, monotonicSenderTimeUs);
    return bytes.buffer.asUint8List();
  }

  static PingPayload decode(List<int> input) {
    if (input.length != 16) {
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'PING/PONG payload must be 16 bytes');
    }
    final bytes = Uint8List.fromList(input);
    return PingPayload(
        bytes.sublist(0, 8), ByteData.sublistView(bytes).getUint64(8));
  }
}

/// Timer-free Section 24 liveness bookkeeping. The owning serialized
/// PeerConnection calls these methods using its monotonic clock and emits the
/// actual PING or enters reconnecting when the predicates become true.
class KeepaliveTracker {
  KeepaliveTracker(this.timing, {required int nowMs})
      : _lastEncryptedSentMs = nowMs,
        _lastAuthenticatedReceivedMs = nowMs;
  final KeepaliveTiming timing;
  int _lastEncryptedSentMs;
  int _lastAuthenticatedReceivedMs;

  void encryptedFrameSent(int nowMs) => _lastEncryptedSentMs = nowMs;
  void authenticatedFrameReceived(int nowMs) =>
      _lastAuthenticatedReceivedMs = nowMs;
  bool pingDue(int nowMs) => nowMs - _lastEncryptedSentMs >= timing.intervalMs;
  bool dead(int nowMs) =>
      nowMs - _lastAuthenticatedReceivedMs >= timing.deadTimeoutMs;
}

/// A timer-free driver for Section 24. Its owner calls [poll] from its
/// serialized monotonic timer, submits a returned PING through the backend,
/// and calls [pingSubmitted] only after that complete encrypted frame reaches
/// `SENT_TO_TRANSPORT`. A pending PING is never duplicated while platform
/// submission is outstanding.
class KeepaliveController {
  KeepaliveController(KeepaliveTiming timing,
      {required int nowMs, List<int> Function()? nextPingId})
      : _tracker = KeepaliveTracker(timing, nowMs: nowMs),
        _nextPingId = nextPingId ?? _securePingId;

  final KeepaliveTracker _tracker;
  final List<int> Function() _nextPingId;
  PingPayload? _pendingPing;

  KeepaliveDecision poll({required int nowMs, required int monotonicUs}) {
    if (_tracker.dead(nowMs)) return const KeepaliveDecision.reconnect();
    if (_pendingPing != null || !_tracker.pingDue(nowMs)) {
      return const KeepaliveDecision.none();
    }
    final id = _nextPingId();
    if (id.length != 8) throw ArgumentError.value(id, 'nextPingId');
    final ping = PingPayload(id, monotonicUs);
    _pendingPing = ping;
    return KeepaliveDecision.ping(ping);
  }

  /// Must only be called after the backend reports complete frame submission.
  void pingSubmitted(int nowMs) {
    if (_pendingPing == null) {
      throw const LpcException(LpcErrorCode.invalidState, 'no pending PING');
    }
    _pendingPing = null;
    _tracker.encryptedFrameSent(nowMs);
  }

  /// A failed PING is not retried on the same failed transport generation.
  /// The owner will enter reconnecting through its terminal transport path.
  void pingSubmissionFailed() => _pendingPing = null;

  void authenticatedFrameReceived(int nowMs) =>
      _tracker.authenticatedFrameReceived(nowMs);

  static List<int> _securePingId() =>
      List<int>.generate(8, (_) => Random.secure().nextInt(256));
}

sealed class KeepaliveDecision {
  const KeepaliveDecision._();
  const factory KeepaliveDecision.none() = KeepaliveNoAction;
  const factory KeepaliveDecision.ping(PingPayload ping) = KeepalivePing;
  const factory KeepaliveDecision.reconnect() = KeepaliveReconnect;
}

class KeepaliveNoAction extends KeepaliveDecision {
  const KeepaliveNoAction() : super._();
}

class KeepalivePing extends KeepaliveDecision {
  const KeepalivePing(this.ping) : super._();
  final PingPayload ping;
}

class KeepaliveReconnect extends KeepaliveDecision {
  const KeepaliveReconnect() : super._();
}

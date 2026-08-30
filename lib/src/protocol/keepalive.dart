import 'dart:typed_data';
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

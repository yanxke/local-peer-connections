import 'dart:typed_data';
import 'dart:collection';
import '../types.dart';

class AckPayload {
  AckPayload(List<int> messageId) : messageId = Uint8List.fromList(messageId) {
    if (this.messageId.length != 8)
      throw ArgumentError.value(messageId, 'messageId');
  }
  final Uint8List messageId;
  Uint8List encode() => Uint8List.fromList(messageId);
  static AckPayload decode(List<int> bytes) {
    if (bytes.length != 8)
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'ACK payload must be 8 bytes');
    return AckPayload(bytes);
  }
}

enum AckOperationState { pendingSubmission, awaitingAck, acknowledged, failed }

enum AckTimeoutResult { ignored, retransmitWholeOperation, terminalAckTimeout }

/// Section 23 sender retention. The PeerConnection invokes this only when its
/// complete final frame/chunk reaches backend `SUBMITTED_TO_PLATFORM`.
class RetainedAckOperation {
  RetainedAckOperation(
      {required List<int> messageId, required List<int> logicalContent})
      : messageId = Uint8List.fromList(messageId),
        logicalContent = Uint8List.fromList(logicalContent) {
    if (this.messageId.length != 8)
      throw ArgumentError.value(messageId, 'messageId');
  }
  final Uint8List messageId, logicalContent;
  AckOperationState _state = AckOperationState.pendingSubmission;
  int _retransmissions = 0;
  AckOperationState get state => _state;
  int get retransmissions => _retransmissions;
  void finalFrameSubmitted() {
    if (_state == AckOperationState.pendingSubmission)
      _state = AckOperationState.awaitingAck;
  }

  void acknowledge() {
    if (_state == AckOperationState.awaitingAck ||
        _state == AckOperationState.pendingSubmission)
      _state = AckOperationState.acknowledged;
  }

  void transportLost() {
    if (_state == AckOperationState.awaitingAck)
      _state = AckOperationState.pendingSubmission;
  }

  AckTimeoutResult onAckTimeout() {
    if (_state != AckOperationState.awaitingAck)
      return AckTimeoutResult.ignored;
    if (_retransmissions == 2) {
      _state = AckOperationState.failed;
      return AckTimeoutResult.terminalAckTimeout;
    }
    _retransmissions++;
    _state = AckOperationState.pendingSubmission;
    return AckTimeoutResult.retransmitWholeOperation;
  }

  /// RESUME retransmission has the same bounded retry budget as a timeout.
  /// It deliberately does not depend on an old ACK deadline: the new attempt
  /// gets a deadline only after its final frame is platform-submitted.
  AckTimeoutResult retransmitAfterResume() {
    if (_state == AckOperationState.acknowledged ||
        _state == AckOperationState.failed) {
      return AckTimeoutResult.ignored;
    }
    if (_retransmissions == 2) {
      _state = AckOperationState.failed;
      return AckTimeoutResult.terminalAckTimeout;
    }
    _retransmissions++;
    _state = AckOperationState.pendingSubmission;
    return AckTimeoutResult.retransmitWholeOperation;
  }
}

/// Bounded sender-side retention for all ACK-required logical units. The
/// caller owns the logical encoder and invokes [finalFrameSubmitted] only
/// after its complete current attempt is sent to the platform.
class AckRetentionSet {
  AckRetentionSet({this.capacity = 1024, this.timeoutMs = 3000})
      : assert(capacity > 0),
        assert(timeoutMs == 3000);
  final int capacity;
  final int timeoutMs;
  final LinkedHashMap<String, _RetainedEntry> _entries = LinkedHashMap();

  int get length => _entries.length;

  RetainedAckOperation retain(
      {required List<int> messageId, required List<int> logicalContent}) {
    final key = _key(messageId);
    if (_entries.containsKey(key)) {
      throw const LpcException(LpcErrorCode.messageIdCollision);
    }
    if (_entries.length >= capacity) {
      throw const LpcException(
          LpcErrorCode.resourceExhausted, 'ACK-required retention is full');
    }
    final operation = RetainedAckOperation(
        messageId: messageId, logicalContent: logicalContent);
    _entries[key] = _RetainedEntry(operation);
    return operation;
  }

  void finalFrameSubmitted(List<int> messageId, {required int nowMs}) {
    final entry = _required(messageId);
    entry.operation.finalFrameSubmitted();
    if (entry.operation.state == AckOperationState.awaitingAck) {
      entry.deadlineMs = nowMs + timeoutMs;
    }
  }

  /// Returns true only for a retained operation. Unknown/late ACKs are not a
  /// state mutation and are ignored by the generic sender mechanism.
  bool acknowledge(List<int> messageId) {
    final entry = _entries.remove(_key(messageId));
    if (entry == null) return false;
    entry.operation.acknowledge();
    return true;
  }

  AckTimeoutResult onTimer(List<int> messageId, {required int nowMs}) {
    final entry = _required(messageId);
    if (entry.deadlineMs == null || nowMs < entry.deadlineMs!) {
      return AckTimeoutResult.ignored;
    }
    entry.deadlineMs = null;
    final result = entry.operation.onAckTimeout();
    if (result == AckTimeoutResult.terminalAckTimeout) {
      _entries.remove(_key(messageId));
    }
    return result;
  }

  /// Pauses active ACK deadlines on transport loss. Retention remains intact
  /// for RESUME; no ACK timer is active while reconnecting.
  void transportLost() {
    for (final entry in _entries.values) {
      entry.operation.transportLost();
      entry.deadlineMs = null;
    }
  }

  /// Produces all logical operations eligible for whole-operation recovery.
  /// Terminal failures are removed; callers retransmit returned operations
  /// from chunk zero using the original MessageId.
  List<RetainedAckOperation> retransmitAfterResume() {
    final ready = <RetainedAckOperation>[];
    for (final entry in List<_RetainedEntry>.from(_entries.values)) {
      final result = entry.operation.retransmitAfterResume();
      entry.deadlineMs = null;
      if (result == AckTimeoutResult.retransmitWholeOperation) {
        ready.add(entry.operation);
      } else if (result == AckTimeoutResult.terminalAckTimeout) {
        _entries.remove(_key(entry.operation.messageId));
      }
    }
    return List.unmodifiable(ready);
  }

  _RetainedEntry _required(List<int> messageId) {
    final entry = _entries[_key(messageId)];
    if (entry == null) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'ACK-required operation is not retained');
    }
    return entry;
  }

  String _key(List<int> messageId) {
    if (messageId.length != 8)
      throw ArgumentError.value(messageId, 'messageId');
    return messageId.join(',');
  }
}

class _RetainedEntry {
  _RetainedEntry(this.operation);
  final RetainedAckOperation operation;
  int? deadlineMs;
}

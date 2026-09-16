import 'dart:collection';
import '../group.dart';
import '../types.dart';

enum ScheduledKind { control, realtime, reliable }

class ScheduledItem {
  ScheduledItem(
      {required this.kind,
      required this.bytes,
      this.priority = SendPriority.normal,
      this.channelId,
      this.realtimeKey,
      this.expiresAtMs});
  final ScheduledKind kind;
  final List<int> bytes;
  final SendPriority priority;
  final int? channelId;
  final String? realtimeKey;

  /// Absolute monotonic deadline. Null is used only by callers whose
  /// operation has no expiry policy; protocol send paths supply a deadline.
  final int? expiresAtMs;
  bool expiredAt(int nowMs) => expiresAtMs != null && nowMs >= expiresAtMs!;

  /// Section 22.1's default realtime expiry. The owner supplies its monotonic
  /// acceptance timestamp; this avoids deriving deadlines from wall-clock time.
  factory ScheduledItem.realtime({
    required List<int> bytes,
    required String realtimeKey,
    required int acceptedAtMs,
    int expiryMs = 100,
    int? channelId,
  }) {
    if (expiryMs < 1) throw ArgumentError.value(expiryMs, 'expiryMs');
    return ScheduledItem(
        kind: ScheduledKind.realtime,
        bytes: bytes,
        channelId: channelId,
        realtimeKey: realtimeKey,
        expiresAtMs: acceptedAtMs + expiryMs);
  }
}

/// One reliable operation retained in the bounded scheduler before any LPC
/// DATA frame has begun transport submission.
class QueuedReliableSend {
  const QueuedReliableSend(this.item, this.handle);
  final ScheduledItem item;
  final SendHandle handle;
}

/// Section 37 bounded per-hop scheduler. Caller supplies one peer's traffic.
class PeerScheduler {
  PeerScheduler({this.maxQueuedBytes = 262144, this.maxQueuedMessages = 1024});
  final int maxQueuedBytes, maxQueuedMessages;
  final Queue<ScheduledItem> _control = Queue(),
      _realtime = Queue(),
      _reliable = Queue();
  final Map<ScheduledItem, SendHandleController> _reliableHandles = {};
  int _bytes = 0, _realtimeRun = 0;
  int get queuedBytes => _bytes;
  int get queuedMessages =>
      _control.length + _realtime.length + _reliable.length;
  void add(ScheduledItem item) {
    if (item.kind == ScheduledKind.realtime) {
      final old =
          _realtime.where((e) => e.realtimeKey == item.realtimeKey).toList();
      for (final value in old) {
        _realtime.remove(value);
        _bytes -= value.bytes.length;
      }
    }
    if (_bytes + item.bytes.length > maxQueuedBytes ||
        _control.length + _realtime.length + _reliable.length >=
            maxQueuedMessages)
      throw const LpcException(LpcErrorCode.sendQueueFull);
    (switch (item.kind) {
      ScheduledKind.control => _control,
      ScheduledKind.realtime => _realtime,
      ScheduledKind.reliable => _reliable
    })
        .add(item);
    _bytes += item.bytes.length;
  }

  /// Queues a reliable operation with cancellation semantics. Calling
  /// `cancel()` while it is still queued removes it before any DATA frame can
  /// be selected for submission (Section 36.8).
  QueuedReliableSend enqueueReliable({
    required List<int> bytes,
    required SendPriority priority,
    int? expiresAtMs,
  }) {
    late final ScheduledItem item;
    final controller =
        SendHandleController.queued(onCancel: () => cancel(item));
    item = ScheduledItem(
      kind: ScheduledKind.reliable,
      bytes: bytes,
      priority: priority,
      expiresAtMs: expiresAtMs,
    );
    add(item);
    _reliableHandles[item] = controller;
    return QueuedReliableSend(item, controller.handle);
  }

  /// Removes one still-queued item. It returns false once the item has begun
  /// scheduler dispatch or was already removed.
  bool cancel(ScheduledItem item) {
    for (final queue in [_control, _realtime, _reliable]) {
      if (queue.remove(item)) {
        _bytes -= item.bytes.length;
        _reliableHandles.remove(item);
        return true;
      }
    }
    return false;
  }

  ScheduledItem? takeNext() {
    ScheduledItem? item;
    if (_control.isNotEmpty)
      item = _control.removeFirst();
    else if (_realtime.isNotEmpty &&
        !(_realtimeRun >= 8 &&
            _reliable.any((i) => i.priority != SendPriority.bulk)))
      item = _realtime.removeFirst();
    else if (_reliable.isNotEmpty) {
      final index =
          _reliable.toList().indexWhere((i) => i.priority != SendPriority.bulk);
      item = index < 0 ? _reliable.removeFirst() : _removeAt(_reliable, index);
    }
    if (item != null) {
      _bytes -= item.bytes.length;
      _realtimeRun = item.kind == ScheduledKind.realtime ? _realtimeRun + 1 : 0;
      _reliableHandles.remove(item)?.transmitting();
    }
    return item;
  }

  /// Removes every operation that has not begun physical transmission before
  /// its absolute deadline. The owner maps each returned item to the public
  /// `EXPIRED` handle state (Sections 22.1 and 36).
  List<ScheduledItem> removeExpired(int nowMs) {
    final expired = <ScheduledItem>[];
    for (final queue in [_control, _realtime, _reliable]) {
      for (final item
          in queue.where((item) => item.expiredAt(nowMs)).toList()) {
        queue.remove(item);
        _bytes -= item.bytes.length;
        _reliableHandles.remove(item)?.complete(SendState.expired);
        expired.add(item);
      }
    }
    return List.unmodifiable(expired);
  }

  /// Discards pending realtime state on a transport-generation loss. Reliable
  /// items remain queued for their distinct RESUME recovery semantics.
  List<ScheduledItem> discardRealtimeOnReconnect() {
    final discarded = _realtime.toList(growable: false);
    _realtime.clear();
    for (final item in discarded) {
      _bytes -= item.bytes.length;
      _reliableHandles.remove(item)?.complete(SendState.failed);
    }
    return discarded;
  }

  ScheduledItem _removeAt(Queue<ScheduledItem> queue, int index) {
    for (var i = 0; i < index; i++) {
      queue.add(queue.removeFirst());
    }
    return queue.removeFirst();
  }
}

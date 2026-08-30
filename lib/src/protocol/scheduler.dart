import 'dart:collection';
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
}

/// Section 37 bounded per-hop scheduler. Caller supplies one peer's traffic.
class PeerScheduler {
  PeerScheduler({this.maxQueuedBytes = 262144, this.maxQueuedMessages = 1024});
  final int maxQueuedBytes, maxQueuedMessages;
  final Queue<ScheduledItem> _control = Queue(),
      _realtime = Queue(),
      _reliable = Queue();
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
        expired.add(item);
      }
    }
    return List.unmodifiable(expired);
  }

  ScheduledItem _removeAt(Queue<ScheduledItem> queue, int index) {
    for (var i = 0; i < index; i++) {
      queue.add(queue.removeFirst());
    }
    return queue.removeFirst();
  }
}

import 'dart:collection';
import 'dart:typed_data';
import '../types.dart';

/// Section 43.1.4 destination cache. It is one cache per destination
/// GroupSession (not per source) and retains only the latest 16,384 operations.
class CompletedGroupMessageDedup {
  CompletedGroupMessageDedup({this.capacity = 16384}) : assert(capacity > 0);
  final int capacity;
  final LinkedHashMap<String, Uint8List> _entries = LinkedHashMap();
  bool accept(
      {required PeerId source,
      required GroupMessageId messageId,
      required PeerId destination,
      required DeliveryMode mode,
      required SendPriority priority,
      required List<int> bytes}) {
    final key = '${source}:${messageId.bytes.join(',')}';
    final content = Uint8List.fromList(
        [...destination.bytes, mode.index, priority.index, ...bytes]);
    final existing = _entries[key];
    if (existing != null) {
      if (!_same(existing, content))
        throw const LpcException(LpcErrorCode.messageIdCollision);
      return false;
    }
    _entries[key] = content;
    if (_entries.length > capacity) _entries.remove(_entries.keys.first);
    return true;
  }

  bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var value = 0;
    for (var i = 0; i < a.length; i++) {
      value |= a[i] ^ b[i];
    }
    return value == 0;
  }
}

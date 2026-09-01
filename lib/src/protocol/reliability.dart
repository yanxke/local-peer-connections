import 'dart:collection';
import 'dart:typed_data';
import '../types.dart';

class MessageIdAllocator {
  MessageIdAllocator(List<int> prefix, {int initialCounter = 1})
      : _prefix = Uint8List.fromList(prefix),
        _next = initialCounter {
    if (_prefix.length != 4) {
      throw ArgumentError.value(prefix, 'prefix');
    }
    if (initialCounter < 1 || initialCounter > 0xffffffff) {
      throw ArgumentError.value(initialCounter, 'initialCounter');
    }
  }
  final Uint8List _prefix;
  int _next;
  bool _exhausted = false;
  Uint8List allocate() {
    if (_exhausted)
      throw const LpcException(
          LpcErrorCode.resourceExhausted, 'new SessionId required');
    final data = ByteData(8);
    data.buffer.asUint8List().setRange(0, 4, _prefix);
    data.setUint32(4, _next);
    if (_next == 0xffffffff)
      _exhausted = true;
    else
      _next++;
    return data.buffer.asUint8List();
  }
}

class CompletedMessageDedup {
  CompletedMessageDedup({this.capacity = 16384}) : assert(capacity > 0);
  final int capacity;
  final LinkedHashMap<String, Uint8List> _entries = LinkedHashMap();
  bool accept(List<int> id, List<int> content) {
    if (isDuplicate(id, content)) return false;
    final key = id.join(',');
    _entries[key] = Uint8List.fromList(content);
    if (_entries.length > capacity) _entries.remove(_entries.keys.first);
    return true;
  }

  /// Checks a completed operation without mutating retention. This permits a
  /// caller to commit protocol state before recording completion/ACKing it.
  bool isDuplicate(List<int> id, List<int> content) {
    final key = id.join(',');
    final old = _entries[key];
    if (old != null) {
      if (!_same(old, content))
        throw const LpcException(LpcErrorCode.messageIdCollision);
      return true;
    }
    return false;
  }

  bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}

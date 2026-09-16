import 'dart:typed_data';
import '../types.dart';

/// Section 6.1 allocator. The caller persists this instance for the complete
/// GroupSession lifetime, including coordinator migrations and pairwise RESUME.
class GroupMessageIdAllocator {
  GroupMessageIdAllocator(List<int> prefix)
      : _prefix = Uint8List.fromList(prefix) {
    if (_prefix.length != 8) throw ArgumentError.value(prefix, 'prefix');
  }
  final Uint8List _prefix;
  int _next = 1;
  bool _exhausted = false;
  GroupMessageId allocate() {
    if (_exhausted)
      throw const LpcException(
          LpcErrorCode.resourceExhausted, 'GroupMessageId counter exhausted');
    final bytes = ByteData(16);
    bytes.buffer.asUint8List().setRange(0, 8, _prefix);
    bytes.setUint64(8, _next);
    if (_next == 0xffffffffffffffff)
      _exhausted = true;
    else
      _next++;
    return GroupMessageId(bytes.buffer.asUint8List());
  }
}

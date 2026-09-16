import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'backend.dart';
import 'types.dart';

/// Platform stream boundary used by TCP and L2CAP backends. A successful
/// result reports exactly how many bytes the socket/stream accepted; partial
/// acceptance remains one pending LPC frame until its remaining bytes are
/// accepted too.
abstract interface class StreamWritePlatform {
  Future<StreamWriteSubmission> write(Uint8List bytes);
  Future<void> close();
}

sealed class StreamWriteSubmission {
  const StreamWriteSubmission();
}

class StreamBytesAccepted extends StreamWriteSubmission {
  const StreamBytesAccepted(this.byteCount);
  final int byteCount;
}

class StreamTemporarilyUnavailable extends StreamWriteSubmission {
  const StreamTemporarilyUnavailable();
}

class StreamTerminalFailure extends StreamWriteSubmission {
  const StreamTerminalFailure();
}

/// Portable ordered-stream backend for L2CAP and TCP. It never fragments LPC
/// itself: the platform reports acceptance of the exact serialized bytes.
class StreamBackendConnection implements PrioritizedBackendConnection {
  StreamBackendConnection({
    required this.connectionId,
    required this.transportType,
    required StreamWritePlatform platform,
    this.maxQueuedBytes = 262144,
  }) : _platform = platform {
    if (transportType != TransportType.l2cap &&
        transportType != TransportType.lanTcp) {
      throw ArgumentError.value(transportType, 'transportType');
    }
    if (maxQueuedBytes < 1) throw ArgumentError.value(maxQueuedBytes);
  }

  @override
  final String connectionId;
  @override
  final TransportType transportType;
  final StreamWritePlatform _platform;
  final int maxQueuedBytes;
  final Queue<_PendingStreamWrite> _writes = Queue<_PendingStreamWrite>();
  final StreamController<BackendConnectionEvent> _events =
      StreamController<BackendConnectionEvent>.broadcast();
  TransportConnectionState _state = TransportConnectionState.open;
  int _queuedBytes = 0;
  bool _draining = false;

  @override
  TransportConnectionState get state => _state;
  @override
  int get maxWriteSize => 16384 + 62 + 16;
  @override
  Stream<BackendConnectionEvent> get events => _events.stream;

  @override
  TransportWrite write(Uint8List completeSerializedLpcFrame) {
    return writeWithPriority(completeSerializedLpcFrame,
        priority: SendPriority.interactive);
  }

  @override
  TransportWrite writeWithPriority(Uint8List completeSerializedLpcFrame,
      {required SendPriority priority}) {
    if (_state != TransportConnectionState.open) {
      throw const LpcException(LpcErrorCode.transportClosed);
    }
    if (_queuedBytes + completeSerializedLpcFrame.length > maxQueuedBytes) {
      throw const LpcException(LpcErrorCode.sendQueueFull);
    }
    final pending = _PendingStreamWrite(completeSerializedLpcFrame, priority);
    _writes.add(pending);
    _queuedBytes += completeSerializedLpcFrame.length;
    unawaited(_drain());
    return pending.write;
  }

  /// Called by the native binding after ordinary stream backpressure clears.
  void writable() {
    if (_state == TransportConnectionState.open) unawaited(_drain());
  }

  void terminalFailure(
      [LpcException error = const LpcException(LpcErrorCode.transportClosed)]) {
    if (_state != TransportConnectionState.open) return;
    _state = TransportConnectionState.failed;
    while (_writes.isNotEmpty) {
      _writes.removeFirst().write.fail();
    }
    _queuedBytes = 0;
    _events.add(BackendError(error));
    _events.add(const BackendClosed());
  }

  @override
  Future<void> close() async {
    if (_state == TransportConnectionState.closed) return;
    if (_state == TransportConnectionState.open) terminalFailure();
    await _platform.close();
    _state = TransportConnectionState.closed;
  }

  Future<void> _drain() async {
    if (_draining || _state != TransportConnectionState.open) return;
    _draining = true;
    try {
      while (_writes.isNotEmpty && _state == TransportConnectionState.open) {
        final pending = _takeNext();
        final bytes = pending.bytes.sublist(pending.offset);
        final result = await _platform.write(bytes);
        switch (result) {
          case StreamTemporarilyUnavailable():
            return;
          case StreamTerminalFailure():
            terminalFailure();
            return;
          case StreamBytesAccepted(:final byteCount):
            if (byteCount < 1 || byteCount > bytes.length) {
              terminalFailure(const LpcException(LpcErrorCode.platformError));
              return;
            }
            pending.offset += byteCount;
            if (pending.offset == pending.bytes.length) {
              _writes.removeFirst();
              _queuedBytes -= pending.bytes.length;
              pending.write.submittedToPlatform();
            }
        }
      }
    } catch (_) {
      terminalFailure();
    } finally {
      _draining = false;
    }
  }

  _PendingStreamWrite _takeNext() {
    if (_writes.length < 2) return _writes.first;
    // A byte stream cannot interleave two partially accepted serialized LPC
    // frames. Priority selection is therefore only between frames that have
    // not started physical submission.
    if (_writes.first.offset != 0) return _writes.first;
    var selected = _writes.first;
    for (final candidate in _writes.skip(1)) {
      if (candidate.priority.index < selected.priority.index) {
        selected = candidate;
      }
    }
    if (identical(selected, _writes.first)) return selected;
    _writes.remove(selected);
    _writes.addFirst(selected);
    return selected;
  }
}

class _PendingStreamWrite {
  _PendingStreamWrite(List<int> bytes, this.priority)
      : bytes = Uint8List.fromList(bytes);
  final Uint8List bytes;
  final SendPriority priority;
  final TransportWrite write = TransportWrite();
  int offset = 0;
}

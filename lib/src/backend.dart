import 'dart:async';
import 'dart:typed_data';
import 'types.dart';

enum TransportType { gatt, l2cap, lanTcp, meshRelay }

enum TransportWriteState { pending, submittedToPlatform, failed }

enum TransportConnectionState { connecting, open, closed, failed }

/// Section 44 completion object. Backends retain PENDING through internal
/// fragmentation/backpressure and complete only at the platform API boundary.
class TransportWrite {
  TransportWrite();
  final Completer<TransportWriteState> _completion = Completer();
  TransportWriteState _state = TransportWriteState.pending;
  TransportWriteState get state => _state;
  Future<TransportWriteState> get completion => _completion.future;
  void submittedToPlatform() {
    if (_state != TransportWriteState.pending) return;
    _state = TransportWriteState.submittedToPlatform;
    _completion.complete(_state);
  }

  void fail() {
    if (_state != TransportWriteState.pending) return;
    _state = TransportWriteState.failed;
    _completion.complete(_state);
  }
}

abstract interface class BackendConnection {
  String get connectionId;
  TransportType get transportType;
  TransportConnectionState get state;
  int get maxWriteSize;

  TransportWrite write(Uint8List completeSerializedLpcFrame);
  Future<void> close();
  Stream<BackendConnectionEvent> get events;
}

/// Optional backend capability for a serialized realtime LPC frame. It lets a
/// transport select its specified realtime platform path without changing the
/// encrypted LPC frame or its completion semantics.
abstract interface class RealtimeBackendConnection
    implements BackendConnection {
  TransportWrite writeRealtime(Uint8List completeSerializedLpcFrame);
}

/// Optional backend capability for Section 37 priority scheduling. Keeping
/// this separate preserves source compatibility for custom backends that only
/// implement the original FIFO [BackendConnection] contract.
abstract interface class PrioritizedBackendConnection
    implements BackendConnection {
  /// Queues one complete LPC frame. The backend must preserve FIFO order
  /// within a priority, but may select a higher-priority queued frame before
  /// a lower-priority one.
  TransportWrite writeWithPriority(Uint8List completeSerializedLpcFrame,
      {required SendPriority priority});
}

sealed class BackendConnectionEvent {
  const BackendConnectionEvent();
}

class BackendOpened extends BackendConnectionEvent {
  const BackendOpened();
}

class BackendBytesReceived extends BackendConnectionEvent {
  BackendBytesReceived(List<int> bytes) : bytes = Uint8List.fromList(bytes);
  final Uint8List bytes;
}

class BackendWritable extends BackendConnectionEvent {
  const BackendWritable();
}

class BackendClosed extends BackendConnectionEvent {
  const BackendClosed();
}

class BackendError extends BackendConnectionEvent {
  const BackendError(this.error);
  final LpcException error;
}

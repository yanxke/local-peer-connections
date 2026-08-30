import 'dart:async';
import 'dart:typed_data';
import 'types.dart';

enum TransportType { gatt, l2cap, lanTcp }

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

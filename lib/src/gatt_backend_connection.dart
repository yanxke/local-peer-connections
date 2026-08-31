import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'backend.dart';
import 'protocol/gatt_fragment.dart';
import 'types.dart';

/// The native GATT binding implements only this platform-specific fragment
/// submission boundary. It must report [temporarilyUnavailable] for ordinary
/// backpressure and [terminalFailure] only when this physical link cannot
/// submit further fragments.
abstract interface class GattFragmentPlatform {
  int get platformSafeWriteSize;
  Future<GattFragmentSubmission> submitGattFragment(Uint8List fragment);
  Future<void> close();
}

enum GattFragmentSubmission {
  submitted,
  temporarilyUnavailable,
  terminalFailure,
}

/// Portable Section 12/44 GATT backend. Native code forwards received GATT
/// fragments to [receiveGattFragment], invokes [writable] on flow-control
/// recovery, and invokes [terminalFailure] when the physical link dies.
class GattBackendConnection implements BackendConnection {
  GattBackendConnection({
    required this.connectionId,
    required GattFragmentPlatform platform,
    this.maxQueuedBytes = 262144,
    int Function()? monotonicNowMs,
  })  : _platform = platform,
        _fragmenter = GattFragmenter(platform.platformSafeWriteSize),
        _nowMs = monotonicNowMs ?? _wallClockMs {
    if (maxQueuedBytes < 1) throw ArgumentError.value(maxQueuedBytes);
  }

  @override
  final String connectionId;
  final GattFragmentPlatform _platform;
  final GattFragmenter _fragmenter;
  final int maxQueuedBytes;
  final int Function() _nowMs;
  final Queue<_PendingGattWrite> _writes = Queue<_PendingGattWrite>();
  final StreamController<BackendConnectionEvent> _events =
      StreamController<BackendConnectionEvent>.broadcast();
  final GattReassembler _reassembler = GattReassembler();
  TransportConnectionState _state = TransportConnectionState.open;
  int _queuedBytes = 0;
  bool _draining = false;

  @override
  TransportType get transportType => TransportType.gatt;
  @override
  TransportConnectionState get state => _state;
  @override
  int get maxWriteSize => _fragmenter.maxPayloadSize + 7;
  @override
  Stream<BackendConnectionEvent> get events => _events.stream;

  @override
  TransportWrite write(Uint8List completeSerializedLpcFrame) {
    if (_state != TransportConnectionState.open) {
      throw const LpcException(LpcErrorCode.transportClosed);
    }
    final fragments = _fragmenter.split(completeSerializedLpcFrame);
    final encoded = fragments.map((fragment) => fragment.encode()).toList();
    final byteCount =
        encoded.fold<int>(0, (sum, fragment) => sum + fragment.length);
    if (_queuedBytes + byteCount > maxQueuedBytes) {
      throw const LpcException(LpcErrorCode.sendQueueFull);
    }
    final pending = _PendingGattWrite(encoded, byteCount);
    _writes.add(pending);
    _queuedBytes += byteCount;
    unawaited(_drain());
    return pending.write;
  }

  /// Resume the same pending fragment after a transient not-writable signal.
  void writable() {
    if (_state == TransportConnectionState.open) unawaited(_drain());
  }

  /// Delivers a complete serialized LPC frame upward only after a valid END
  /// fragment. A malformed fragment invalidates the current partial frame and
  /// is reported to the owning connection as a protocol error.
  void receiveGattFragment(List<int> encoded) {
    if (_state != TransportConnectionState.open) return;
    try {
      final frame =
          _reassembler.add(GattFragment.decode(encoded), nowMs: _nowMs());
      if (frame != null) _events.add(BackendBytesReceived(frame));
    } on LpcException catch (error) {
      _events.add(BackendError(error));
    }
  }

  /// Called by the native inactivity timer. The partial frame is discarded;
  /// the next valid START fragment can begin a new LPC frame.
  bool discardExpiredReassembly() => _reassembler.discardExpired(_nowMs());

  /// Called only for a terminal physical GATT failure. Every accepted pending
  /// write fails together; no same-link frame is retried.
  void terminalFailure(
      [LpcException error = const LpcException(LpcErrorCode.transportClosed)]) {
    if (_state != TransportConnectionState.open) return;
    _state = TransportConnectionState.failed;
    while (_writes.isNotEmpty) {
      final pending = _writes.removeFirst();
      pending.write.fail();
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
        final pending = _writes.first;
        final result = await _platform
            .submitGattFragment(pending.fragments[pending.nextFragment]);
        if (result == GattFragmentSubmission.temporarilyUnavailable) {
          return;
        }
        if (result == GattFragmentSubmission.terminalFailure) {
          terminalFailure();
          return;
        }
        pending.nextFragment++;
        if (pending.nextFragment == pending.fragments.length) {
          _writes.removeFirst();
          _queuedBytes -= pending.byteCount;
          // Only this final platform API submission constitutes frame-level
          // SENT_TO_TRANSPORT (Section 44.1).
          pending.write.submittedToPlatform();
        }
      }
    } catch (_) {
      terminalFailure();
    } finally {
      _draining = false;
    }
  }
}

class _PendingGattWrite {
  _PendingGattWrite(this.fragments, this.byteCount);
  final List<Uint8List> fragments;
  final int byteCount;
  final TransportWrite write = TransportWrite();
  int nextFragment = 0;
}

int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

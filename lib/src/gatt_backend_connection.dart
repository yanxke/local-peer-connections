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
  Future<GattFragmentSubmission> submitGattFragment(
    Uint8List fragment, {
    GattFragmentTransmission transmission = GattFragmentTransmission.normal,
  });
  Future<void> close();
}

/// The native binding maps these values to the corresponding GATT API call.
/// `normal` retains the existing reliable/control submission path.
enum GattFragmentTransmission { normal, writeWithoutResponse, notify }

/// The local BLE role fixes the required Section 22.2 realtime direction.
enum GattLinkRole { central, peripheral }

enum GattFragmentSubmission {
  submitted,
  temporarilyUnavailable,
  terminalFailure,
}

/// Portable Section 12/44 GATT backend. Native code forwards received GATT
/// fragments to [receiveGattFragment], invokes [writable] on flow-control
/// recovery, and invokes [terminalFailure] when the physical link dies.
class GattBackendConnection implements RealtimeBackendConnection {
  GattBackendConnection({
    required this.connectionId,
    required GattFragmentPlatform platform,
    this.localRole,
    this.logger,
    this.maxQueuedBytes = 262144,
    this.fragmentTimeoutMs = 5000,
    int Function()? monotonicNowMs,
  })  : _platform = platform,
        _fragmenter = GattFragmenter(platform.platformSafeWriteSize),
        _nowMs = monotonicNowMs ?? _wallClockMs {
    if (maxQueuedBytes < 1) throw ArgumentError.value(maxQueuedBytes);
    if (fragmentTimeoutMs < 1) throw ArgumentError.value(fragmentTimeoutMs);
  }

  @override
  final String connectionId;
  final GattFragmentPlatform _platform;
  final GattLinkRole? localRole;

  /// Optional diagnostic sink. Logs frame/queue state, never fragment bytes.
  final void Function(String message)? logger;
  final GattFragmenter _fragmenter;
  final int maxQueuedBytes;
  final int fragmentTimeoutMs;
  final int Function() _nowMs;
  final Queue<_PendingGattWrite> _writes = Queue<_PendingGattWrite>();
  final StreamController<BackendConnectionEvent> _events =
      StreamController<BackendConnectionEvent>.broadcast();
  late final GattReassembler _reassembler =
      GattReassembler(timeoutMs: fragmentTimeoutMs);
  TransportConnectionState _state = TransportConnectionState.open;
  int _queuedBytes = 0;
  bool _draining = false;

  void _log(String message) {
    try {
      logger?.call(message);
    } on Object {
      // Logging must never affect transport behavior.
    }
  }

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
    return _write(completeSerializedLpcFrame,
        transmission: GattFragmentTransmission.normal);
  }

  /// Maps realtime GATT traffic exactly by BLE direction: central writes RX
  /// without response, while peripheral notifies TX. A binding must supply
  /// its local role before realtime can be used.
  @override
  TransportWrite writeRealtime(Uint8List completeSerializedLpcFrame) {
    final role = localRole;
    if (role == null) {
      throw const LpcException(LpcErrorCode.invalidState,
          'GATT local role is required for realtime');
    }
    return _write(
      completeSerializedLpcFrame,
      transmission: role == GattLinkRole.central
          ? GattFragmentTransmission.writeWithoutResponse
          : GattFragmentTransmission.notify,
    );
  }

  TransportWrite _write(
    Uint8List completeSerializedLpcFrame, {
    required GattFragmentTransmission transmission,
  }) {
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
    final pending = _PendingGattWrite(encoded, byteCount, transmission);
    _writes.add(pending);
    _queuedBytes += byteCount;
    _log(
        'queued frame bytes=${completeSerializedLpcFrame.length} fragments=${encoded.length} transmission=${transmission.name} queueBytes=$_queuedBytes queueFrames=${_writes.length}');
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
      final fragment = GattFragment.decode(encoded);
      _log(
          'received fragment sequence=${fragment.sequence} start=${fragment.start} end=${fragment.end} bytes=${fragment.bytes.length}');
      final frame = _reassembler.add(fragment, nowMs: _nowMs());
      if (frame != null) {
        _log('received complete frame bytes=${frame.length}');
        _events.add(BackendBytesReceived(frame));
      }
    } on LpcException catch (error) {
      _log(
          'receive fragment failed code=${error.code.name} detail=${error.message}');
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
    _log(
        'terminal failure code=${error.code.name} pendingFrames=${_writes.length} queuedBytes=$_queuedBytes');
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
        final result = await _platform.submitGattFragment(
            pending.fragments[pending.nextFragment],
            transmission: pending.transmission);
        if (result == GattFragmentSubmission.temporarilyUnavailable) {
          _log(
              'fragment temporarily unavailable index=${pending.nextFragment + 1}/${pending.fragments.length} queueFrames=${_writes.length}');
          return;
        }
        if (result == GattFragmentSubmission.terminalFailure) {
          _log(
              'fragment terminal failure index=${pending.nextFragment + 1}/${pending.fragments.length}');
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
          _log(
              'frame submitted transmission=${pending.transmission.name} remainingFrames=${_writes.length} queueBytes=$_queuedBytes');
        }
      }
    } catch (error) {
      _log('drain failed error=$error');
      terminalFailure();
    } finally {
      _draining = false;
    }
  }
}

class _PendingGattWrite {
  _PendingGattWrite(this.fragments, this.byteCount, this.transmission);
  final List<Uint8List> fragments;
  final int byteCount;
  final GattFragmentTransmission transmission;
  final TransportWrite write = TransportWrite();
  int nextFragment = 0;
}

int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

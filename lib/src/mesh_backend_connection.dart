import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'backend.dart';
import 'protocol/frame.dart';
import 'protocol/mesh_relay.dart';
import 'types.dart';

/// End-to-end LPC frame carrier over one authenticated friend relay.
///
/// The relay never owns the inner cryptographic session. A write is reported
/// submitted only after the destination has injected the full inner frame;
/// the separate inner ACK still governs RELIABLE_ACKED application delivery.
class MeshBackendConnection implements BackendConnection {
  MeshBackendConnection({
    required this.localPeerId,
    required this.remotePeerId,
    required this.relayPeerId,
    required this.sendEnvelope,
  }) : _nextFrameId = Random.secure().nextInt(0x7fffffff) << 32,
       _events = StreamController<BackendConnectionEvent>.broadcast(
         sync: true,
       ) {
    _events.onListen = _flushBuffered;
  }

  final PeerId localPeerId, remotePeerId, relayPeerId;
  final Future<TransportWriteState> Function(MeshFrame frame) sendEnvelope;
  final StreamController<BackendConnectionEvent> _events;
  final List<Uint8List> _buffered = [];
  final Map<int, _PendingMeshWrite> _pending = {};
  int _nextFrameId;
  int _pendingBytes = 0;
  TransportConnectionState _state = TransportConnectionState.open;

  @override
  String get connectionId => 'mesh:${remotePeerId.toString()}';
  @override
  TransportType get transportType => TransportType.meshRelay;
  @override
  TransportConnectionState get state => _state;
  @override
  int get maxWriteSize => 16462;
  @override
  Stream<BackendConnectionEvent> get events => _events.stream;

  @override
  TransportWrite write(Uint8List completeSerializedLpcFrame) {
    final write = TransportWrite();
    late final FrameType innerType;
    try {
      innerType = LpcFrame.decode(completeSerializedLpcFrame).type;
    } on Object {
      write.fail();
      return write;
    }
    if (_state != TransportConnectionState.open ||
        completeSerializedLpcFrame.length > maxWriteSize ||
        _pending.length >= 16 ||
        _pendingBytes + completeSerializedLpcFrame.length > 65536) {
      write.fail();
      return write;
    }
    final frameId = ++_nextFrameId;
    final chunks = <MeshFrame>[];
    final chunkCount = max(
      1,
      (completeSerializedLpcFrame.length + meshRelayChunkBytes - 1) ~/
          meshRelayChunkBytes,
    );
    for (var index = 0; index < chunkCount; index++) {
      final start = index * meshRelayChunkBytes;
      chunks.add(
        MeshFrame(
          kind: MeshFrameKind.chunk,
          source: localPeerId,
          destination: remotePeerId,
          frameId: frameId,
          chunkIndex: index,
          chunkCount: chunkCount,
          bytes: completeSerializedLpcFrame.sublist(
            start,
            min(start + meshRelayChunkBytes, completeSerializedLpcFrame.length),
          ),
        ),
      );
    }
    final pending = _PendingMeshWrite(
      write,
      chunks,
      completeSerializedLpcFrame.length,
      innerType == FrameType.realtimeDatagram ||
          innerType == FrameType.groupRealtimeDatagram,
    );
    _pending[frameId] = pending;
    _pendingBytes += pending.length;
    unawaited(_transmit(frameId, pending));
    return write;
  }

  Future<void> _transmit(int frameId, _PendingMeshWrite pending) async {
    if (_state != TransportConnectionState.open || _pending[frameId] != pending)
      return;
    pending.timer?.cancel();
    try {
      for (final chunk in pending.chunks) {
        if (_state != TransportConnectionState.open ||
            _pending[frameId] != pending)
          return;
        if (await sendEnvelope(chunk) !=
            TransportWriteState.submittedToPlatform) {
          _fail(frameId, pending);
          return;
        }
      }
      if (_pending[frameId] != pending) return;
      if (pending.realtime) {
        // Minor-0 realtime semantics still apply inside the virtual session:
        // one-shot, no receipt wait, and no retransmission of stale state.
        _pending.remove(frameId);
        _pendingBytes -= pending.length;
        pending.write.submittedToPlatform();
        return;
      }
      // A 4 KiB frame can take several seconds across two BLE hops. Starting
      // a one-second receipt timer here caused an identical retry to overlap
      // still-in-flight chunks, then exhausted retries and dropped a healthy
      // virtual connection. Budget the serialized size at 200 B/s plus 5s.
      final receiptWait = Duration(
        milliseconds: 5000 + ((pending.length + 199) ~/ 200) * 1000,
      );
      pending.timer = Timer(receiptWait, () {
        if (_pending[frameId] != pending) return;
        if (pending.retries++ >= 2) {
          _fail(frameId, pending);
        } else {
          // On a lost receipt, retransmit the entire serialized inner frame.
          // Destination dedup prevents the inner frame from being injected twice.
          unawaited(_transmit(frameId, pending));
        }
      });
    } on Object {
      _fail(frameId, pending);
    }
  }

  void receiveReceipt(int frameId) {
    final pending = _pending.remove(frameId);
    if (pending == null) return;
    pending.timer?.cancel();
    _pendingBytes -= pending.length;
    pending.write.submittedToPlatform();
  }

  void receiveFrame(List<int> frame) {
    if (_state != TransportConnectionState.open) return;
    if (_events.hasListener) {
      _events.add(BackendBytesReceived(frame));
    } else if (_buffered.length < 2) {
      // An incoming HELLO can race the async creation of the responder's
      // X25519 key. Keep only the first bounded handshake frames.
      _buffered.add(Uint8List.fromList(frame));
    }
  }

  void _flushBuffered() {
    for (final frame in _buffered) {
      _events.add(BackendBytesReceived(frame));
    }
    _buffered.clear();
  }

  void _fail(int frameId, _PendingMeshWrite pending) {
    if (_pending.remove(frameId) != pending) return;
    pending.timer?.cancel();
    _pendingBytes -= pending.length;
    pending.write.fail();
  }

  @override
  Future<void> close() async {
    if (_state == TransportConnectionState.closed) return;
    _state = TransportConnectionState.closed;
    for (final entry in _pending.entries.toList()) {
      _fail(entry.key, entry.value);
    }
    _buffered.clear();
    _events.add(const BackendClosed());
    await _events.close();
  }
}

class _PendingMeshWrite {
  _PendingMeshWrite(this.write, this.chunks, this.length, this.realtime);
  final TransportWrite write;
  final List<MeshFrame> chunks;
  final int length;
  final bool realtime;
  Timer? timer;
  int retries = 0;
}

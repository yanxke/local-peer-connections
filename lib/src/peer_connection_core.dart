import 'dart:async';
import 'dart:typed_data';
import 'backend.dart';
import 'protocol/crypto.dart';
import 'protocol/frame.dart';
import 'protocol/peer_state.dart';
import 'protocol/control_payload.dart';
import 'protocol/ack.dart';
import 'types.dart';

/// Authenticated-generation transport core. Handshake orchestration owns its
/// creation; this object has no platform BLE dependency.
class PeerConnectionCore {
  PeerConnectionCore(
      {required this.backend,
      required List<int> sessionRootKey,
      required List<int> sessionId,
      required this.localPeerId,
      required this.remotePeerId,
      AckRetentionSet? ackRetention,
      this.generation = 1,
      int initialNextSequence = 1,
      int initialHighestReceivedSequence = 0})
      : _sessionRootKey = Uint8List.fromList(sessionRootKey),
        _sessionId = Uint8List.fromList(sessionId),
        ackRetention = ackRetention ?? AckRetentionSet(),
        _nextSequence = initialNextSequence {
    if (_sessionRootKey.length != 32 || _sessionId.length != 16)
      throw ArgumentError('invalid session key or id');
    if (generation < 1 ||
        initialNextSequence < 1 ||
        initialHighestReceivedSequence < 0) {
      throw ArgumentError('invalid generation or sequence');
    }
    _receiveSequences.seedHighest(initialHighestReceivedSequence);
    _state.requireTransition(PeerConnectionState.connecting);
    _state.requireTransition(PeerConnectionState.transportConnected);
    _state.requireTransition(PeerConnectionState.authenticating);
    _state.requireTransition(PeerConnectionState.ready);
    _backendSubscription = backend.events
        .listen(_onBackendEvent, onError: (_, __) => _handleTransportLoss());
  }
  final BackendConnection backend;
  final Uint8List _sessionRootKey, _sessionId;
  final PeerId localPeerId, remotePeerId;
  final PeerStateMachine _state = PeerStateMachine();
  final ReceiveSequenceWindow _receiveSequences = ReceiveSequenceWindow();
  final AckRetentionSet ackRetention;
  final Set<TransportWrite> _pendingWrites = <TransportWrite>{};
  late final StreamSubscription<BackendConnectionEvent> _backendSubscription;
  int generation;
  int _nextSequence;
  PeerConnectionState get state => _state.state;
  Future<TransportWriteState> submitEncrypted(FrameType type, List<int> payload,
      {int flags = 0, List<int>? messageId}) async {
    if (state != PeerConnectionState.ready)
      throw const LpcException(LpcErrorCode.invalidState);
    final sequence = _nextSequence++;
    final direction =
        _compare(localPeerId.bytes, remotePeerId.bytes) < 0 ? 0 : 1;
    final key = await trafficKey(_sessionRootKey, generation, direction);
    final frame = LpcFrame(
        type: type,
        flags: flags,
        transportGeneration: generation,
        sequenceNumber: sequence,
        messageId: messageId ?? List.filled(8, 0),
        sessionId: _sessionId,
        nonce: List.filled(12, 0),
        payload: payload);
    final protected =
        await const FrameProtector().encrypt(frame, await key.extractBytes());
    final write = backend.write(protected.encode());
    _pendingWrites.add(write);
    // A backend completion is the only authority for SENT_TO_TRANSPORT.  In
    // particular, a terminal failure is a generation-wide transport loss,
    // never a per-frame same-generation retry (Sections 44.1.2-44.1.3).
    unawaited(write.completion.then((result) {
      _pendingWrites.remove(write);
      if (result == TransportWriteState.failed) {
        _handleTransportLoss();
      }
    }, onError: (_, __) {
      _pendingWrites.remove(write);
      _handleTransportLoss();
    }));
    return write.completion;
  }

  Future<LpcFrame?> receiveEncrypted(List<int> encodedFrame) async {
    if (state != PeerConnectionState.ready)
      throw const LpcException(LpcErrorCode.invalidState);
    final frame = LpcFrame.decode(encodedFrame);
    if (!frame.encrypted ||
        frame.transportGeneration != generation ||
        !_same(frame.sessionId, _sessionId))
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final direction =
        _compare(remotePeerId.bytes, localPeerId.bytes) < 0 ? 0 : 1;
    final key = await trafficKey(_sessionRootKey, generation, direction);
    final clear =
        await const FrameProtector().decrypt(frame, await key.extractBytes());
    if (_receiveSequences.accept(clear.sequenceNumber) ==
        SequenceAcceptance.replay) return null;
    if (clear.type == FrameType.ack) {
      final ack = parseAck(clear);
      if (ack != null) ackRetention.acknowledge(ack.messageId);
    }
    return clear;
  }

  Future<TransportWriteState> submitAck(List<int> acknowledgedMessageId) =>
      submitEncrypted(
          FrameType.ack, AckPayload(acknowledgedMessageId).encode());
  AckPayload? parseAck(LpcFrame frame) {
    if (frame.type != FrameType.ack) return null;
    if (frame.flags != 0 || frame.messageId.any((byte) => byte != 0))
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid ACK header');
    return AckPayload.decode(frame.payload);
  }

  void beginReconnect() {
    _handleTransportLoss();
  }

  void completeResume(
      {required int newGeneration, required List<int> resumedSessionRootKey}) {
    if (resumedSessionRootKey.length != 32)
      throw ArgumentError.value(resumedSessionRootKey, 'resumedSessionRootKey');
    if (state != PeerConnectionState.reconnecting)
      throw const LpcException(LpcErrorCode.invalidState);
    _sessionRootKey.setRange(0, 32, resumedSessionRootKey);
    generation = newGeneration;
    _nextSequence = 1;
    _receiveSequences.reset();
    _state.requireTransition(PeerConnectionState.ready);
  }

  /// Called after RESUME_READY by the logical-operation owner. Each returned
  /// entry must be re-encoded as a complete operation from chunk zero; this
  /// core intentionally cannot infer a frame-specific encoder.
  List<RetainedAckOperation> retransmitAckOperationsAfterResume() {
    if (state != PeerConnectionState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    return ackRetention.retransmitAfterResume();
  }

  /// Moves an active generation into the protocol reconnect path.  Backend
  /// close/error callbacks are intentionally harmless once reconnecting: an
  /// impossible or stale callback cannot manufacture another transition.
  void _handleTransportLoss() {
    if (state == PeerConnectionState.ready) {
      _state.requireTransition(PeerConnectionState.reconnecting);
      ackRetention.transportLost();
      // Section 44.1.2 makes terminal transport failure generation-wide. The
      // backend may signal one failed frame first; every other frame accepted
      // for that same physical generation must become FAILED as well.
      for (final write in List<TransportWrite>.from(_pendingWrites)) {
        write.fail();
      }
    }
  }

  void _onBackendEvent(BackendConnectionEvent event) {
    if (event is BackendClosed || event is BackendError) {
      _handleTransportLoss();
    }
  }

  /// Idempotently terminates this logical connection.  Recovery callers use
  /// [completeResume]; close is deliberately not a substitute for RESUME.
  Future<void> close() async {
    if (state == PeerConnectionState.disconnected ||
        state == PeerConnectionState.disconnecting) {
      return;
    }
    if (state == PeerConnectionState.ready ||
        state == PeerConnectionState.reconnecting) {
      _state.requireTransition(PeerConnectionState.disconnecting);
    } else if (state == PeerConnectionState.failed) {
      _state.requireTransition(PeerConnectionState.disconnected);
      await _backendSubscription.cancel();
      return;
    } else {
      return;
    }
    await backend.close();
    _state.requireTransition(PeerConnectionState.disconnected);
    await _backendSubscription.cancel();
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var result = 0;
  for (var i = 0; i < a.length; i++) {
    result |= a[i] ^ b[i];
  }
  return result == 0;
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    final value = a[i].compareTo(b[i]);
    if (value != 0) return value;
  }
  return 0;
}

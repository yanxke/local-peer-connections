import 'dart:async';
import 'dart:typed_data';
import 'backend.dart';
import 'group.dart';
import 'protocol/crypto.dart';
import 'protocol/frame.dart';
import 'protocol/peer_state.dart';
import 'protocol/control_payload.dart';
import 'protocol/ack.dart';
import 'protocol/application_payload.dart';
import 'protocol/checkpoint.dart';
import 'protocol/reliable_data_receiver.dart';
import 'protocol/reliability.dart';
import 'protocol/keepalive.dart';
import 'protocol/reassembly.dart';
import 'types.dart';

/// Authenticated-generation transport core. Handshake orchestration owns its
/// creation; this object has no platform BLE dependency.
class PeerConnectionCore {
  PeerConnectionCore(
      {required BackendConnection backend,
      required List<int> sessionRootKey,
      required List<int> sessionId,
      List<int>? resumeSecret,
      required this.localPeerId,
      required this.remotePeerId,
      this.securityLevel,
      AckRetentionSet? ackRetention,
      this.messageIdAllocator,
      KeepaliveTiming? keepaliveTiming,
      int Function()? monotonicNowMs,
      this.generation = 1,
      int initialNextSequence = 1,
      int initialHighestReceivedSequence = 0})
      : _backend = backend,
        _sessionRootKey = Uint8List.fromList(sessionRootKey),
        _sessionId = Uint8List.fromList(sessionId),
        _resumeSecret =
            resumeSecret == null ? null : Uint8List.fromList(resumeSecret),
        ackRetention = ackRetention ?? AckRetentionSet(),
        _monotonicStopwatch = Stopwatch()..start(),
        _nextSequence = initialNextSequence {
    if (_sessionRootKey.length != 32 ||
        _sessionId.length != 16 ||
        (_resumeSecret != null && _resumeSecret!.length != 32))
      throw ArgumentError('invalid session key or id');
    if (generation < 1 ||
        initialNextSequence < 1 ||
        initialHighestReceivedSequence < 0) {
      throw ArgumentError('invalid generation or sequence');
    }
    _monotonicNowMs =
        monotonicNowMs ?? (() => _monotonicStopwatch.elapsedMilliseconds);
    _receiveSequences.seedHighest(initialHighestReceivedSequence);
    _keepalive = keepaliveTiming == null
        ? null
        : KeepaliveController(keepaliveTiming, nowMs: _monotonicNowMs());
    _state.requireTransition(PeerConnectionState.connecting);
    _state.requireTransition(PeerConnectionState.transportConnected);
    _state.requireTransition(PeerConnectionState.authenticating);
    _state.requireTransition(PeerConnectionState.ready);
    _bindBackend(backend);
  }
  BackendConnection _backend;
  BackendConnection get backend => _backend;
  final Uint8List _sessionRootKey, _sessionId;
  Uint8List? _resumeSecret;
  final PeerId localPeerId, remotePeerId;
  final SecurityLevel? securityLevel;
  final PeerStateMachine _state = PeerStateMachine();
  final ReceiveSequenceWindow _receiveSequences = ReceiveSequenceWindow();
  final AckRetentionSet ackRetention;
  final Stopwatch _monotonicStopwatch;
  late final int Function() _monotonicNowMs;
  late final KeepaliveController? _keepalive;

  /// Session-direction allocator shared by DATA and ACK-required control
  /// operations when the handshake owner provides the retained prefix.
  final MessageIdAllocator? messageIdAllocator;
  final ReliableDataReceiver _dataReceiver = ReliableDataReceiver();
  final RealtimeSequenceFilter _realtimeReceiver = RealtimeSequenceFilter();
  final Map<int, int> _nextRealtimeSequence = <int, int>{};
  final Map<String, _AckRequiredFrame> _ackRequiredFrames = {};
  final Map<String, List<CoordinatorCheckpointChunk>> _checkpointOperations =
      {};
  final Map<String, _ReliableDataOperation> _reliableDataOperations = {};
  final Set<TransportWrite> _pendingWrites = <TransportWrite>{};
  final StreamController<LpcFrame> _receivedFrames =
      StreamController<LpcFrame>.broadcast(sync: true);
  late StreamSubscription<BackendConnectionEvent> _backendSubscription;
  int generation;
  int _nextSequence;
  bool _pollingKeepalive = false;
  bool _pollingAckTimeouts = false;
  PeerConnectionState get state => _state.state;
  int get monotonicNowMs => _monotonicNowMs();
  Uint8List get sessionId => Uint8List.fromList(_sessionId);

  /// The retained Section 26 secret for this logical SessionId. It is present
  /// only for handshake-owned cores, never synthesized for test/manual cores.
  Uint8List get resumeSecret {
    final secret = _resumeSecret;
    if (secret == null) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'RESUME secret is unavailable');
    }
    return Uint8List.fromList(secret);
  }

  /// Authenticated, replay-filtered frames in receive order. Higher layers
  /// own the frame-specific application/group dispatch.
  Stream<LpcFrame> get receivedFrames => _receivedFrames.stream;
  Future<TransportWriteState> submitEncrypted(FrameType type, List<int> payload,
      {int flags = 0, List<int>? messageId}) async {
    if (state != PeerConnectionState.ready)
      throw const LpcException(LpcErrorCode.invalidState);
    if (type == FrameType.ping || type == FrameType.pong) {
      PingPayload.decode(payload);
    }
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
    final encoded = protected.encode();
    final write = type == FrameType.realtimeDatagram &&
            backend is RealtimeBackendConnection
        ? (backend as RealtimeBackendConnection).writeRealtime(encoded)
        : backend.write(encoded);
    _pendingWrites.add(write);
    // A backend completion is the only authority for SENT_TO_TRANSPORT.  In
    // particular, a terminal failure is a generation-wide transport loss,
    // never a per-frame same-generation retry (Sections 44.1.2-44.1.3).
    unawaited(write.completion.then((result) {
      _pendingWrites.remove(write);
      if (result == TransportWriteState.submittedToPlatform) {
        _keepalive?.encryptedFrameSubmitted(_monotonicNowMs());
      }
      if (result == TransportWriteState.failed) {
        _handleTransportLoss();
      }
    }, onError: (_, __) {
      _pendingWrites.remove(write);
      _handleTransportLoss();
    }));
    return write.completion;
  }

  /// Sends a complete, single-frame ACK-required logical operation. The core
  /// retains its immutable frame input so an ACK timeout can retransmit the
  /// same MessageId and content with a new reliable wire sequence. Chunked
  /// operations remain owned by their operation-specific encoders.
  Future<TransportWriteState> submitAckRequiredFrame(
      {required FrameType type,
      required List<int> payload,
      List<int>? messageId,
      required int nowMs}) async {
    if (state != PeerConnectionState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    final id = messageId ?? _allocateMessageId();
    final key = _messageKey(id);
    if (_ackRequiredFrames.containsKey(key) ||
        _checkpointOperations.containsKey(key)) {
      throw const LpcException(LpcErrorCode.messageIdCollision);
    }
    final retained =
        ackRetention.retain(messageId: id, logicalContent: payload);
    final frame = _AckRequiredFrame(type, payload, retained.messageId);
    _ackRequiredFrames[key] = frame;
    return _submitRetainedAckFrame(frame, nowMs: nowMs);
  }

  List<int> _allocateMessageId() {
    final allocator = messageIdAllocator;
    if (allocator == null) {
      throw const LpcException(
        LpcErrorCode.invalidState,
        'MessageId allocator was not supplied by handshake ownership',
      );
    }
    return allocator.allocate();
  }

  /// Sends one chunked COORDINATOR_CHECKPOINT logical operation. Every chunk
  /// uses the caller's one MessageId while [submitEncrypted] allocates a fresh
  /// reliable sequence for each frame. Its ACK deadline begins only after the
  /// final chunk reaches the backend submission boundary.
  Future<List<TransportWriteState>> submitAckRequiredCheckpoint({
    required List<CoordinatorCheckpointChunk> chunks,
    List<int>? messageId,
    required int nowMs,
  }) async {
    if (state != PeerConnectionState.ready || chunks.isEmpty) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    final id = messageId ?? _allocateMessageId();
    final key = _messageKey(id);
    if (_ackRequiredFrames.containsKey(key) ||
        _checkpointOperations.containsKey(key)) {
      throw const LpcException(LpcErrorCode.messageIdCollision);
    }
    final first = chunks.first;
    for (var index = 0; index < chunks.length; index++) {
      final chunk = chunks[index];
      if (chunk.term != first.term ||
          chunk.sequence != first.sequence ||
          chunk.totalLength != first.totalLength ||
          chunk.chunkCount != chunks.length ||
          chunk.chunkIndex != index) {
        throw const LpcException(
            LpcErrorCode.protocolMismatch, 'invalid checkpoint operation');
      }
    }
    final content = <int>[for (final chunk in chunks) ...chunk.encode()];
    ackRetention.retain(messageId: id, logicalContent: content);
    _checkpointOperations[key] = List.unmodifiable(chunks);
    return _submitCheckpointAttempt(id, chunks, nowMs: nowMs);
  }

  /// Submits one complete reliable DATA operation in chunk order.  The
  /// immutable chunk plan is retained across transport loss so recovery can
  /// restart at chunk zero (Sections 21.2 and 26.6).
  Future<List<TransportWriteState>> submitReliableData({
    required List<int> bytes,
    required DeliveryMode deliveryMode,
    required SendPriority priority,
    required List<int> messageId,
    required int nowMs,
  }) =>
      _submitReliableData(
        bytes: bytes,
        deliveryMode: deliveryMode,
        priority: priority,
        messageId: messageId,
        nowMs: nowMs,
      );

  /// Starts a point-to-point DATA submission with its observable public
  /// handle. The handle moves to `SENT_TO_TRANSPORT` only once every chunk has
  /// reached the backend boundary (Section 36.4.2).
  SendHandle submitReliableDataWithHandle({
    required List<int> bytes,
    required DeliveryMode deliveryMode,
    required SendPriority priority,
    required List<int> messageId,
    required int nowMs,
  }) {
    final controller = SendHandleController.transmitting(
      onCancel: () => _cancelReliableData(messageId),
    );
    unawaited(() async {
      try {
        await _submitReliableData(
          bytes: bytes,
          deliveryMode: deliveryMode,
          priority: priority,
          messageId: messageId,
          nowMs: nowMs,
          handleController: controller,
        );
      } on Object {
        controller.complete(SendState.failed);
      }
    }());
    return controller.handle;
  }

  void _cancelReliableData(List<int> messageId) {
    final operation = _reliableDataOperations.remove(_messageKey(messageId));
    if (operation == null) return;
    operation.cancelled = true;
    if (operation.deliveryMode == DeliveryMode.reliableAcked) {
      ackRetention.cancel(messageId);
    }
  }

  Future<List<TransportWriteState>> _submitReliableData({
    required List<int> bytes,
    required DeliveryMode deliveryMode,
    required SendPriority priority,
    required List<int> messageId,
    required int nowMs,
    SendHandleController? handleController,
  }) async {
    if (state != PeerConnectionState.ready ||
        deliveryMode == DeliveryMode.realtimeLatest) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    final key = _messageKey(messageId);
    if (_ackRequiredFrames.containsKey(key) ||
        _checkpointOperations.containsKey(key) ||
        _reliableDataOperations.containsKey(key)) {
      throw const LpcException(LpcErrorCode.messageIdCollision);
    }
    final operation = _ReliableDataOperation(
      messageId: messageId,
      chunks: chunkData(bytes, mode: deliveryMode, priority: priority),
      handleController: handleController,
    );
    if (deliveryMode == DeliveryMode.reliableAcked) {
      ackRetention.retain(messageId: messageId, logicalContent: bytes);
    }
    _reliableDataOperations[key] = operation;
    return _submitReliableDataAttempt(operation, nowMs: nowMs);
  }

  Future<List<TransportWriteState>> _submitReliableDataAttempt(
    _ReliableDataOperation operation, {
    required int nowMs,
  }) async {
    final results = <TransportWriteState>[];
    for (final chunk in operation.chunks) {
      if (operation.cancelled) return results;
      final result = await submitEncrypted(
        FrameType.data,
        chunk.encode(),
        flags: operation.deliveryMode == DeliveryMode.reliableAcked ? 1 : 0,
        messageId: operation.messageId,
      );
      results.add(result);
      if (operation.cancelled) return results;
      if (result != TransportWriteState.submittedToPlatform) return results;
    }
    if (operation.cancelled) return results;
    if (operation.deliveryMode == DeliveryMode.reliableAcked) {
      ackRetention.finalFrameSubmitted(operation.messageId, nowMs: nowMs);
      operation.handleController?.sentToTransport();
    } else {
      // A fully submitted RELIABLE_ORDERED operation is terminal at the
      // transport boundary and must not be automatically replayed on RESUME.
      _reliableDataOperations.remove(_messageKey(operation.messageId));
      operation.handleController?.complete(SendState.sentToTransport);
    }
    return results;
  }

  /// Replays retained DATA plans after RESUME. Ordered plans exist only when
  /// their prior attempt did not fully reach the transport boundary; ACKed
  /// plans use the shared bounded ACK-retention retry accounting.
  Future<List<List<TransportWriteState>>> retransmitReliableDataAfterResume(
      {required int nowMs}) async {
    if (state != PeerConnectionState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    final attempts = <List<TransportWriteState>>[];
    for (final operation
        in List<_ReliableDataOperation>.from(_reliableDataOperations.values)) {
      if (operation.deliveryMode == DeliveryMode.reliableAcked) {
        final result =
            ackRetention.retransmitOneAfterResume(operation.messageId);
        if (result == AckTimeoutResult.terminalAckTimeout) {
          _reliableDataOperations.remove(_messageKey(operation.messageId));
          operation.handleController?.complete(SendState.failed);
          continue;
        }
        if (result != AckTimeoutResult.retransmitWholeOperation) continue;
      }
      attempts.add(await _submitReliableDataAttempt(operation, nowMs: nowMs));
    }
    return List.unmodifiable(attempts);
  }

  Future<AckTimeoutResult> retryAckRequiredCheckpoint(List<int> messageId,
      {required int nowMs}) async {
    final result = ackRetention.onTimer(messageId, nowMs: nowMs);
    final key = _messageKey(messageId);
    if (result == AckTimeoutResult.retransmitWholeOperation) {
      final chunks = _checkpointOperations[key];
      if (chunks == null) {
        throw const LpcException(
            LpcErrorCode.invalidState, 'missing checkpoint encoder');
      }
      await _submitCheckpointAttempt(messageId, chunks, nowMs: nowMs);
    } else if (result == AckTimeoutResult.terminalAckTimeout) {
      _checkpointOperations.remove(key);
    }
    return result;
  }

  /// Section 26 recovery of one retained checkpoint. All chunks restart at
  /// chunk 0 under the new generation; their MessageId stays unchanged.
  Future<AckTimeoutResult> retransmitCheckpointAfterResume(List<int> messageId,
      {required int nowMs}) async {
    if (state != PeerConnectionState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    final key = _messageKey(messageId);
    final result = ackRetention.retransmitOneAfterResume(messageId);
    if (result == AckTimeoutResult.retransmitWholeOperation) {
      final chunks = _checkpointOperations[key];
      if (chunks == null) {
        throw const LpcException(
            LpcErrorCode.invalidState, 'missing checkpoint encoder');
      }
      await _submitCheckpointAttempt(messageId, chunks, nowMs: nowMs);
    } else if (result == AckTimeoutResult.terminalAckTimeout) {
      _checkpointOperations.remove(key);
    }
    return result;
  }

  Future<List<TransportWriteState>> _submitCheckpointAttempt(
      List<int> messageId, List<CoordinatorCheckpointChunk> chunks,
      {required int nowMs}) async {
    final results = <TransportWriteState>[];
    for (final chunk in chunks) {
      final result = await submitEncrypted(
          FrameType.coordinatorCheckpoint, chunk.encode(),
          flags: 1, messageId: messageId);
      results.add(result);
      if (result != TransportWriteState.submittedToPlatform) return results;
    }
    ackRetention.finalFrameSubmitted(messageId, nowMs: nowMs);
    return results;
  }

  /// Applies the 3-second ACK deadline for a single-frame retained operation.
  /// A retry is re-encrypted through [submitEncrypted], which necessarily
  /// allocates a fresh generation-local wire sequence number.
  Future<AckTimeoutResult> retryAckRequiredFrame(List<int> messageId,
      {required int nowMs}) async {
    final result = ackRetention.onTimer(messageId, nowMs: nowMs);
    if (result == AckTimeoutResult.retransmitWholeOperation) {
      final frame = _ackRequiredFrames[_messageKey(messageId)];
      if (frame == null) {
        throw const LpcException(
            LpcErrorCode.invalidState, 'missing ACK-required frame encoder');
      }
      await _submitRetainedAckFrame(frame, nowMs: nowMs);
    } else if (result == AckTimeoutResult.terminalAckTimeout) {
      _ackRequiredFrames.remove(_messageKey(messageId));
    }
    return result;
  }

  Future<TransportWriteState> _submitRetainedAckFrame(_AckRequiredFrame frame,
      {required int nowMs}) async {
    final result = await submitEncrypted(frame.type, frame.payload,
        flags: 1, messageId: frame.messageId);
    if (result == TransportWriteState.submittedToPlatform) {
      ackRetention.finalFrameSubmitted(frame.messageId, nowMs: nowMs);
    }
    return result;
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
    if (clear.type == FrameType.ping || clear.type == FrameType.pong) {
      // Parsing enforces the exact 16-byte payload before a PONG echoes it
      // byte-for-byte (Section 24).
      PingPayload.decode(clear.payload);
    }
    _keepalive?.authenticatedFrameReceived(_monotonicNowMs());
    if (clear.type == FrameType.ping) {
      final result = await submitEncrypted(FrameType.pong, clear.payload);
      if (result != TransportWriteState.submittedToPlatform) {
        throw const LpcException(LpcErrorCode.transportClosed);
      }
    }
    if (clear.type == FrameType.ack) {
      final ack = parseAck(clear);
      if (ack != null && ackRetention.acknowledge(ack.messageId)) {
        _ackRequiredFrames.remove(_messageKey(ack.messageId));
        _checkpointOperations.remove(_messageKey(ack.messageId));
        final data = _reliableDataOperations.remove(_messageKey(ack.messageId));
        data?.handleController?.complete(SendState.remoteAcknowledged);
      }
    }
    return clear;
  }

  /// Drives the negotiated Section 24 keepalive from the owning runtime's
  /// serialized timer. It never emits duplicate PINGs while one is pending.
  Future<void> pollKeepalive() async {
    final keepalive = _keepalive;
    if (keepalive == null ||
        state != PeerConnectionState.ready ||
        _pollingKeepalive) {
      return;
    }
    _pollingKeepalive = true;
    try {
      final nowMs = _monotonicNowMs();
      final decision = keepalive.poll(
          nowMs: nowMs,
          monotonicUs: nowMs * Duration.microsecondsPerMillisecond);
      switch (decision) {
        case KeepaliveNoAction():
          return;
        case KeepaliveReconnect():
          _handleTransportLoss();
          return;
        case KeepalivePing(:final ping):
          final result = await submitEncrypted(FrameType.ping, ping.encode());
          if (result == TransportWriteState.submittedToPlatform) {
            keepalive.pingSubmitted(_monotonicNowMs());
          } else {
            keepalive.pingSubmissionFailed();
          }
      }
    } finally {
      _pollingKeepalive = false;
    }
  }

  /// Drives Section 23 ACK timers for operations owned by this connection.
  /// Group-routing owners retain their own logical encoders and continue to
  /// consume their retained entries explicitly.
  Future<void> pollAckTimeouts() async {
    if (state != PeerConnectionState.ready || _pollingAckTimeouts) return;
    _pollingAckTimeouts = true;
    try {
      final nowMs = _monotonicNowMs();
      for (final messageId in ackRetention.dueMessageIds(nowMs: nowMs)) {
        final key = _messageKey(messageId);
        if (_ackRequiredFrames.containsKey(key)) {
          await retryAckRequiredFrame(messageId, nowMs: nowMs);
        } else if (_checkpointOperations.containsKey(key)) {
          await retryAckRequiredCheckpoint(messageId, nowMs: nowMs);
        } else {
          final operation = _reliableDataOperations[key];
          if (operation == null ||
              operation.deliveryMode != DeliveryMode.reliableAcked) {
            continue;
          }
          final result = ackRetention.onTimer(messageId, nowMs: nowMs);
          if (result == AckTimeoutResult.retransmitWholeOperation) {
            await _submitReliableDataAttempt(operation, nowMs: nowMs);
          } else if (result == AckTimeoutResult.terminalAckTimeout) {
            _reliableDataOperations.remove(key);
            operation.handleController?.complete(SendState.failed);
          }
        }
        if (state != PeerConnectionState.ready) return;
      }
    } finally {
      _pollingAckTimeouts = false;
    }
  }

  Future<TransportWriteState> submitAck(List<int> acknowledgedMessageId) =>
      submitEncrypted(
          FrameType.ack, AckPayload(acknowledgedMessageId).encode());

  /// Sends one `REALTIME_LATEST` envelope on the active reliable transport.
  /// It is deliberately neither ACK_REQUIRED nor retained for retry/RESUME.
  Future<TransportWriteState> submitRealtime(RealtimeDatagram datagram) =>
      submitEncrypted(FrameType.realtimeDatagram, datagram.encode());

  RealtimeDatagram allocateRealtimeDatagram({
    required int channelId,
    required int senderTick,
    required List<int> bytes,
  }) {
    final sequence = _nextRealtimeSequence[channelId] ?? 1;
    _nextRealtimeSequence[channelId] = (sequence + 1) & 0xffffffff;
    return RealtimeDatagram(
        channelId: channelId,
        sequence: sequence,
        senderTick: senderTick,
        bytes: bytes);
  }

  /// Parses an authenticated realtime frame and applies Section 22's
  /// per-channel serial-number suppression. The filter deliberately survives
  /// RESUME while the SessionId remains unchanged.
  RealtimeDatagram? receiveRealtime(LpcFrame frame) {
    if (frame.type != FrameType.realtimeDatagram) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final datagram = RealtimeDatagram.decode(frame.payload);
    return _realtimeReceiver.accept(datagram) ? datagram : null;
  }

  /// Completes authenticated DATA reassembly and applies Section 23.3's
  /// completed-ID deduplication. Callers deliver a non-null result to the
  /// application only after this method returns. A MessageId collision closes
  /// this PeerConnection before the error is surfaced.
  Future<ReliableDataReceiveResult> receiveDataChunk(
      List<int> messageId, DataChunk chunk) async {
    if (state != PeerConnectionState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    try {
      final result = _dataReceiver.add(messageId, chunk);
      final ackId = result.acknowledgmentMessageId;
      if (ackId != null) await submitAck(ackId);
      return result;
    } on LpcException catch (error) {
      if (error.code == LpcErrorCode.messageIdCollision) await close();
      rethrow;
    }
  }

  /// Commits one authenticated DATA frame before the runtime can emit an
  /// application callback. Invalid DATA framing is terminal for this
  /// connection generation, just like any other malformed encrypted frame.
  Future<ReliableDataReceiveResult> receiveDataFrame(LpcFrame frame) async {
    if (frame.type != FrameType.data) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    try {
      return await receiveDataChunk(
          frame.messageId, DataChunk.decode(frame.payload));
    } on Object {
      await close();
      rethrow;
    }
  }

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
      {required int newGeneration,
      required List<int> resumedSessionRootKey,
      List<int>? newResumeSecret,
      BackendConnection? resumedBackend}) {
    if (resumedSessionRootKey.length != 32)
      throw ArgumentError.value(resumedSessionRootKey, 'resumedSessionRootKey');
    if (state != PeerConnectionState.reconnecting)
      throw const LpcException(LpcErrorCode.invalidState);
    if (resumedBackend != null) {
      if (resumedBackend.state != TransportConnectionState.open) {
        throw const LpcException(
            LpcErrorCode.transportClosed, 'resumed backend is not open');
      }
      // The source identity guard in [_bindBackend] makes a late close/error
      // callback from the failed physical generation harmless after handoff.
      unawaited(_backendSubscription.cancel());
      _backend = resumedBackend;
      _bindBackend(resumedBackend);
    }
    _sessionRootKey.setRange(0, 32, resumedSessionRootKey);
    if (newResumeSecret != null) {
      if (newResumeSecret.length != 32) {
        throw ArgumentError.value(newResumeSecret, 'newResumeSecret');
      }
      _resumeSecret = Uint8List.fromList(newResumeSecret);
    }
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

  /// Re-emits retained single-frame ACK-required operations after RESUME. The
  /// operation-specific owner uses [retransmitAckOperationsAfterResume] for
  /// chunked encodings; this companion handles frames accepted through
  /// [submitAckRequiredFrame].
  Future<List<RetainedAckOperation>> retransmitAckRequiredFramesAfterResume(
      {required int nowMs}) async {
    if (state != PeerConnectionState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    final operations = <RetainedAckOperation>[];
    for (final frame
        in List<_AckRequiredFrame>.from(_ackRequiredFrames.values)) {
      final result = ackRetention.retransmitOneAfterResume(frame.messageId);
      if (result == AckTimeoutResult.terminalAckTimeout) {
        _ackRequiredFrames.remove(_messageKey(frame.messageId));
      } else if (result == AckTimeoutResult.retransmitWholeOperation) {
        await _submitRetainedAckFrame(frame, nowMs: nowMs);
        operations.add(RetainedAckOperation(
          messageId: frame.messageId,
          logicalContent: frame.payload,
        ));
      }
    }
    return List.unmodifiable(operations);
  }

  /// Moves an active generation into the protocol reconnect path.  Backend
  /// close/error callbacks are intentionally harmless once reconnecting: an
  /// impossible or stale callback cannot manufacture another transition.
  void _handleTransportLoss() {
    if (state == PeerConnectionState.ready) {
      _state.requireTransition(PeerConnectionState.reconnecting);
      ackRetention.transportLost();
      _dataReceiver.onTransportGenerationLost();
      // Section 44.1.2 makes terminal transport failure generation-wide. The
      // backend may signal one failed frame first; every other frame accepted
      // for that same physical generation must become FAILED as well.
      for (final write in List<TransportWrite>.from(_pendingWrites)) {
        write.fail();
      }
    }
  }

  void _onBackendEvent(BackendConnectionEvent event) {
    if (event is BackendBytesReceived) {
      unawaited(_receiveBackendFrame(event.bytes));
      return;
    }
    if (event is BackendClosed || event is BackendError) {
      _handleTransportLoss();
    }
  }

  void _bindBackend(BackendConnection source) {
    _backendSubscription = source.events.listen((event) {
      if (identical(source, _backend)) _onBackendEvent(event);
    }, onError: (_, __) {
      if (identical(source, _backend)) _handleTransportLoss();
    });
  }

  Future<void> _receiveBackendFrame(List<int> encoded) async {
    try {
      final frame = await receiveEncrypted(encoded);
      if (frame != null) _receivedFrames.add(frame);
    } on Object {
      // A malformed encrypted frame is a terminal protocol failure for this
      // transport generation.  Do not leave an authenticated connection
      // accepting later bytes after its framing/security invariant failed.
      await close();
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
    await _receivedFrames.close();
  }
}

class _AckRequiredFrame {
  _AckRequiredFrame(this.type, List<int> payload, List<int> messageId)
      : payload = Uint8List.fromList(payload),
        messageId = Uint8List.fromList(messageId);
  final FrameType type;
  final Uint8List payload, messageId;
}

class _ReliableDataOperation {
  _ReliableDataOperation({
    required List<int> messageId,
    required List<DataChunk> chunks,
    this.handleController,
  })  : messageId = Uint8List.fromList(messageId),
        chunks = List.unmodifiable(chunks),
        deliveryMode = chunks.first.deliveryMode {
    if (this.messageId.length != 8 || chunks.isEmpty) {
      throw ArgumentError('invalid reliable DATA operation');
    }
  }

  final Uint8List messageId;
  final List<DataChunk> chunks;
  final DeliveryMode deliveryMode;
  final SendHandleController? handleController;
  bool cancelled = false;
}

String _messageKey(List<int> messageId) {
  if (messageId.length != 8) {
    throw ArgumentError.value(messageId, 'messageId');
  }
  return messageId.join(',');
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

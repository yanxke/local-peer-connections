import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

class _Backend implements BackendConnection {
  final writes = <Uint8List>[];
  final pendingWrites = <TransportWrite>[];
  final StreamController<BackendConnectionEvent> controller =
      StreamController<BackendConnectionEvent>.broadcast();
  bool failWrites = false;
  int? failFromWriteNumber;
  bool leaveWritesPending = false;
  int? pendingFromWriteNumber;
  @override
  String get connectionId => 'test';
  @override
  TransportType get transportType => TransportType.gatt;
  @override
  TransportConnectionState get state => TransportConnectionState.open;
  @override
  int get maxWriteSize => 512;
  @override
  Stream<BackendConnectionEvent> get events => controller.stream;
  @override
  Future<void> close() async {}
  @override
  TransportWrite write(Uint8List frame) {
    writes.add(frame);
    final write = TransportWrite();
    if (failWrites ||
        (failFromWriteNumber != null &&
            writes.length >= failFromWriteNumber!)) {
      write.fail();
    } else if (!leaveWritesPending &&
        (pendingFromWriteNumber == null ||
            writes.length < pendingFromWriteNumber!)) {
      write.submittedToPlatform();
    } else {
      pendingWrites.add(write);
    }
    return write;
  }
}

void main() {
  test('UT-175 RESUME rebinds the logical core to the fresh backend only',
      () async {
    final failedBackend = _Backend();
    final resumedBackend = _Backend();
    final peer = PeerConnectionCore(
        backend: failedBackend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        resumeSecret: List.filled(32, 7),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));

    failedBackend.controller.add(const BackendClosed());
    await Future<void>.delayed(Duration.zero);
    expect(peer.state, PeerConnectionState.reconnecting);
    peer.completeResume(
        newGeneration: 2,
        resumedSessionRootKey: List.filled(32, 5),
        newResumeSecret: List.filled(32, 8),
        resumedBackend: resumedBackend);
    expect(peer.backend, same(resumedBackend));
    expect(peer.state, PeerConnectionState.ready);
    expect(peer.resumeSecret, List.filled(32, 8));

    // Late notifications from the old physical generation cannot tear down
    // the newly resumed logical generation.
    failedBackend.controller.add(const BackendClosed());
    await Future<void>.delayed(Duration.zero);
    expect(peer.state, PeerConnectionState.ready);
    await peer.submitEncrypted(FrameType.data, [1]);
    expect(failedBackend.writes, isEmpty);
    final frame = LpcFrame.decode(resumedBackend.writes.single);
    expect(frame.transportGeneration, 2);
    expect(frame.sequenceNumber, 1);
  });

  test('UT-044 checkpoint chunks share one MessageId and use fresh sequences',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final id = List<int>.filled(8, 9);
    final results = await peer.submitAckRequiredCheckpoint(
        chunks: chunkCheckpoint(List.filled(4001, 1), term: 1, sequence: 1),
        messageId: id,
        nowMs: 0);
    expect(results, everyElement(TransportWriteState.submittedToPlatform));
    final frames = backend.writes.map(LpcFrame.decode).toList();
    expect(frames, hasLength(2));
    expect(frames.map((frame) => frame.messageId), everyElement(id));
    expect(frames.map((frame) => frame.sequenceNumber), [1, 2]);
  });

  test(
      'UT-062 ACK-required controls allocate from the session MessageId stream',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
      backend: backend,
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
      messageIdAllocator: MessageIdAllocator(List.filled(4, 9)),
    );

    await peer.submitAckRequiredFrame(
      type: FrameType.membershipSnapshot,
      payload: [1],
      nowMs: 0,
    );
    await peer.submitAckRequiredFrame(
      type: FrameType.groupMerge,
      payload: [2],
      nowMs: 0,
    );
    await peer.submitAckRequiredCheckpoint(
      chunks: chunkCheckpoint(List.filled(4001, 1), term: 1, sequence: 1),
      nowMs: 0,
    );
    final frames = backend.writes.map(LpcFrame.decode).toList();
    expect(frames.map((frame) => frame.flags), everyElement(1));
    expect(frames.map((frame) => frame.messageId), [
      [9, 9, 9, 9, 0, 0, 0, 1],
      [9, 9, 9, 9, 0, 0, 0, 2],
      [9, 9, 9, 9, 0, 0, 0, 3],
      [9, 9, 9, 9, 0, 0, 0, 3],
    ]);
  });

  test('UT-047 checkpoint retry resends every chunk with same MessageId',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final id = List<int>.filled(8, 9);
    await peer.submitAckRequiredCheckpoint(
        chunks: chunkCheckpoint(List.filled(4001, 1), term: 1, sequence: 1),
        messageId: id,
        nowMs: 0);
    expect(await peer.retryAckRequiredCheckpoint(id, nowMs: 3000),
        AckTimeoutResult.retransmitWholeOperation);
    final frames = backend.writes.map(LpcFrame.decode).toList();
    expect(frames.map((frame) => frame.messageId), everyElement(id));
    expect(frames.map((frame) => frame.sequenceNumber), [1, 2, 3, 4]);
  });

  test('UT-055 checkpoint ACK timer starts only after final chunk submission',
      () async {
    final backend = _Backend()..pendingFromWriteNumber = 2;
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final id = List<int>.filled(8, 9);
    final submission = peer.submitAckRequiredCheckpoint(
        chunks: chunkCheckpoint(List.filled(4001, 1), term: 1, sequence: 1),
        messageId: id,
        nowMs: 0);
    await Future<void>.delayed(Duration.zero);
    expect(backend.writes, hasLength(2));
    expect(await peer.retryAckRequiredCheckpoint(id, nowMs: 3000),
        AckTimeoutResult.ignored);
    backend.pendingWrites.single.submittedToPlatform();
    await submission;
    backend.pendingFromWriteNumber = null;
    expect(await peer.retryAckRequiredCheckpoint(id, nowMs: 3000),
        AckTimeoutResult.retransmitWholeOperation);
  });

  test('UT-061 resumed checkpoint retransmits chunk zero with same MessageId',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final id = List<int>.filled(8, 9);
    await peer.submitAckRequiredCheckpoint(
        chunks: chunkCheckpoint(List.filled(4001, 1), term: 1, sequence: 1),
        messageId: id,
        nowMs: 0);
    peer.beginReconnect();
    peer.completeResume(
        newGeneration: 2, resumedSessionRootKey: List.filled(32, 5));
    expect(await peer.retransmitCheckpointAfterResume(id, nowMs: 1),
        AckTimeoutResult.retransmitWholeOperation);
    final frames = backend.writes.map(LpcFrame.decode).toList();
    expect(frames.skip(2).map((frame) => frame.messageId), everyElement(id));
    expect(frames.skip(2).map((frame) => frame.transportGeneration),
        everyElement(2));
    expect(frames.skip(2).map((frame) => frame.sequenceNumber), [1, 2]);
  });

  test(
      'UT-077 partially submitted ordered DATA restarts from chunk zero after RESUME',
      () async {
    final backend = _Backend()..failFromWriteNumber = 2;
    final peer = PeerConnectionCore(
      backend: backend,
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    final id = List.filled(8, 9);
    final firstAttempt = await peer.submitReliableData(
      bytes: List.filled(maxDataChunkBytes + 1, 7),
      deliveryMode: DeliveryMode.reliableOrdered,
      priority: SendPriority.normal,
      messageId: id,
      nowMs: 0,
    );
    expect(firstAttempt, [
      TransportWriteState.submittedToPlatform,
      TransportWriteState.failed,
    ]);
    expect(peer.state, PeerConnectionState.reconnecting);

    backend.failFromWriteNumber = null;
    peer.completeResume(
      newGeneration: 2,
      resumedSessionRootKey: List.filled(32, 5),
    );
    final resumed = await peer.retransmitReliableDataAfterResume(nowMs: 1);
    expect(
        resumed.single, everyElement(TransportWriteState.submittedToPlatform));
    final frames = backend.writes.skip(2).map(LpcFrame.decode).toList();
    expect(frames.map((frame) => frame.messageId), everyElement(id));
    expect(frames.map((frame) => frame.transportGeneration), everyElement(2));
    final receiver = PeerConnectionCore(
      backend: _Backend(),
      sessionRootKey: List.filled(32, 5),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 4)),
      remotePeerId: PeerId(List.filled(16, 3)),
      generation: 2,
    );
    final indices = <int>[];
    for (final encoded in backend.writes.skip(2)) {
      final clear = await receiver.receiveEncrypted(encoded);
      indices.add(DataChunk.decode(clear!.payload).chunkIndex);
    }
    expect(indices, [0, 1]);
  });

  test('UT-078 fully submitted ordered DATA is not replayed after RESUME',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
      backend: backend,
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    await peer.submitReliableData(
      bytes: List.filled(maxDataChunkBytes + 1, 7),
      deliveryMode: DeliveryMode.reliableOrdered,
      priority: SendPriority.normal,
      messageId: List.filled(8, 9),
      nowMs: 0,
    );
    peer.beginReconnect();
    peer.completeResume(
      newGeneration: 2,
      resumedSessionRootKey: List.filled(32, 5),
    );
    expect(await peer.retransmitReliableDataAfterResume(nowMs: 1), isEmpty);
    expect(backend.writes, hasLength(2));
  });

  test('UT-079 ACK-required DATA replays every chunk after RESUME', () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
      backend: backend,
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    final id = List.filled(8, 9);
    await peer.submitReliableData(
      bytes: List.filled(maxDataChunkBytes + 1, 8),
      deliveryMode: DeliveryMode.reliableAcked,
      priority: SendPriority.interactive,
      messageId: id,
      nowMs: 0,
    );
    peer.beginReconnect();
    peer.completeResume(
      newGeneration: 2,
      resumedSessionRootKey: List.filled(32, 5),
    );
    await peer.retransmitReliableDataAfterResume(nowMs: 1);
    final replay = backend.writes.skip(2).map(LpcFrame.decode).toList();
    expect(replay.map((frame) => frame.messageId), everyElement(id));
    expect(replay.map((frame) => frame.transportGeneration), everyElement(2));
    final receiver = PeerConnectionCore(
      backend: _Backend(),
      sessionRootKey: List.filled(32, 5),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 4)),
      remotePeerId: PeerId(List.filled(16, 3)),
      generation: 2,
    );
    final indices = <int>[];
    for (final encoded in backend.writes.skip(2)) {
      final clear = await receiver.receiveEncrypted(encoded);
      indices.add(DataChunk.decode(clear!.payload).chunkIndex);
    }
    expect(indices, [0, 1]);
  });

  test('UT-080 multi-frame SendHandle waits for every DATA chunk submission',
      () async {
    final backend = _Backend()..pendingFromWriteNumber = 2;
    final peer = PeerConnectionCore(
      backend: backend,
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    final handle = peer.submitReliableDataWithHandle(
      bytes: List.filled(maxDataChunkBytes + 1, 7),
      deliveryMode: DeliveryMode.reliableOrdered,
      priority: SendPriority.normal,
      messageId: List.filled(8, 9),
      nowMs: 0,
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.writes, hasLength(2));
    expect(handle.state, SendState.transmitting);
    expect(handle.isTerminal, isFalse);

    backend.pendingWrites.single.submittedToPlatform();
    expect(await handle.completed, SendState.sentToTransport);
  });

  test(
      'UT-136 cancelled partially transmitted ACK-required DATA has no future retry',
      () async {
    final backend = _Backend()..pendingFromWriteNumber = 2;
    final peer = PeerConnectionCore(
      backend: backend,
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    final handle = peer.submitReliableDataWithHandle(
      bytes: List.filled(maxDataChunkBytes + 1, 7),
      deliveryMode: DeliveryMode.reliableAcked,
      priority: SendPriority.interactive,
      messageId: List.filled(8, 9),
      nowMs: 0,
    );
    await Future<void>.delayed(Duration.zero);
    expect(backend.writes, hasLength(2));
    handle.cancel();
    expect(await handle.completed, SendState.cancelled);

    backend.pendingWrites.single.submittedToPlatform();
    peer.beginReconnect();
    peer.completeResume(
      newGeneration: 2,
      resumedSessionRootKey: List.filled(32, 5),
    );
    expect(await peer.retransmitReliableDataAfterResume(nowMs: 1), isEmpty);
    expect(backend.writes, hasLength(2));
  });

  test('RT-001 realtime DATA emits no LPC ACK', () async {
    final aBackend = _Backend();
    final bBackend = _Backend();
    final a = PeerConnectionCore(
      backend: aBackend,
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    final b = PeerConnectionCore(
      backend: bBackend,
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 4)),
      remotePeerId: PeerId(List.filled(16, 3)),
    );
    await a.submitRealtime(
      RealtimeDatagram(channelId: 1, sequence: 1, senderTick: 1, bytes: [7]),
    );
    final received = await b.receiveEncrypted(aBackend.writes.single);
    expect(received!.type, FrameType.realtimeDatagram);
    expect(bBackend.writes, isEmpty);
  });

  test('UT-166 authenticated realtime delivery is latest-only per channel', () {
    final peer = PeerConnectionCore(
      backend: _Backend(),
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    LpcFrame frame(int sequence) => LpcFrame(
        type: FrameType.realtimeDatagram,
        flags: 0,
        transportGeneration: 1,
        sequenceNumber: sequence,
        messageId: List.filled(8, 0),
        sessionId: List.filled(16, 2),
        nonce: List.filled(12, 0),
        payload: RealtimeDatagram(
            channelId: 3,
            sequence: sequence,
            senderTick: 7,
            bytes: [9]).encode());

    expect(peer.receiveRealtime(frame(5))!.bytes, [9]);
    expect(peer.receiveRealtime(frame(4)), isNull);
    expect(peer.receiveRealtime(frame(6))!.sequence, 6);
  });

  test('UT-167 realtime sequence allocation is independent per channel', () {
    final peer = PeerConnectionCore(
      backend: _Backend(),
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    expect(
        peer.allocateRealtimeDatagram(
            channelId: 1, senderTick: 0, bytes: []).sequence,
        1);
    expect(
        peer.allocateRealtimeDatagram(
            channelId: 2, senderTick: 0, bytes: []).sequence,
        1);
    expect(
        peer.allocateRealtimeDatagram(
            channelId: 1, senderTick: 0, bytes: []).sequence,
        2);
  });

  test('UT-168 malformed authenticated DATA closes before delivery', () async {
    final peer = PeerConnectionCore(
      backend: _Backend(),
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    final frame = LpcFrame(
        type: FrameType.data,
        flags: 0,
        transportGeneration: 1,
        sequenceNumber: 1,
        messageId: List.filled(8, 1),
        sessionId: List.filled(16, 2),
        nonce: List.filled(12, 0),
        payload: [0]);

    await expectLater(
        peer.receiveDataFrame(frame), throwsA(isA<LpcException>()));
    expect(peer.state, PeerConnectionState.disconnected);
  });

  test('RT-002 realtime DATA is not retransmitted after transport loss',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
      backend: backend,
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    await peer.submitRealtime(
      RealtimeDatagram(channelId: 1, sequence: 1, senderTick: 1, bytes: [7]),
    );
    peer.beginReconnect();
    peer.completeResume(
      newGeneration: 2,
      resumedSessionRootKey: List.filled(32, 5),
    );
    expect(
        await peer.retransmitAckRequiredFramesAfterResume(nowMs: 1), isEmpty);
    expect(await peer.retransmitReliableDataAfterResume(nowMs: 1), isEmpty);
    expect(backend.writes, hasLength(1));
  });

  test('UT-070 resumed control operation retransmits without reapplying state',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final messageId = List<int>.filled(8, 9);
    final payload = await MembershipSnapshot(
      groupId: GroupId(List.filled(16, 5)),
      coordinatorTerm: 1,
      members: [GroupMember(PeerId(List.filled(16, 6)), 8)],
    ).encode();
    final receiver = MembershipSnapshotReceiver();
    var commits = 0;
    Future<void> receive(List<int> bytes) async {
      await receiver.add(
        messageId: messageId,
        sessionId: List.filled(16, 2),
        coordinatorPeerId: PeerId(List.filled(16, 7)),
        payload: bytes,
        commit: (_) => commits++,
      );
    }

    await peer.submitAckRequiredFrame(
      type: FrameType.membershipSnapshot,
      payload: payload,
      messageId: messageId,
      nowMs: 0,
    );
    await receive(payload);
    peer.beginReconnect();
    peer.completeResume(
      newGeneration: 2,
      resumedSessionRootKey: List.filled(32, 4),
    );
    final operations =
        await peer.retransmitAckRequiredFramesAfterResume(nowMs: 1);
    await receive(operations.single.logicalContent);

    final frames = backend.writes.map(LpcFrame.decode).toList();
    expect(frames, hasLength(2));
    expect(frames.map((frame) => frame.messageId), everyElement(messageId));
    expect(frames.map((frame) => frame.transportGeneration), [1, 2]);
    expect(operations.single.logicalContent, payload);
    expect(commits, 1);
  });

  test('UT-021 conflicting completed DATA MessageId closes the PeerConnection',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final id = List<int>.filled(8, 1);
    await peer.receiveDataChunk(
        id,
        chunkData([7],
                mode: DeliveryMode.reliableAcked, priority: SendPriority.normal)
            .single);
    await expectLater(
        peer.receiveDataChunk(
            id,
            chunkData([8],
                    mode: DeliveryMode.reliableAcked,
                    priority: SendPriority.normal)
                .single),
        throwsA(isA<LpcException>().having(
            (error) => error.code, 'code', LpcErrorCode.messageIdCollision)));
    expect(peer.state, PeerConnectionState.disconnected);
  });

  test(
      'PeerConnection submits encrypted complete LPC frames through backend completion',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    expect(await peer.submitEncrypted(FrameType.data, [7]),
        TransportWriteState.submittedToPlatform);
    expect(LpcFrame.decode(backend.writes.single).encrypted, isTrue);
  });
  test('UT-057 scheduler submission is not SENT_TO_TRANSPORT', () async {
    final backend = _Backend()..leaveWritesPending = true;
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final submission = peer.submitEncrypted(FrameType.data, [7]);
    await Future<void>.delayed(Duration.zero);
    expect(backend.writes, hasLength(1));
    expect(backend.pendingWrites.single.state, TransportWriteState.pending);

    backend.pendingWrites.single.submittedToPlatform();
    expect(await submission, TransportWriteState.submittedToPlatform);
  });
  test('PeerConnection decrypts a remote frame once and suppresses replay',
      () async {
    final aBackend = _Backend();
    final a = PeerConnectionCore(
        backend: aBackend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final bBackend = _Backend();
    final b = PeerConnectionCore(
        backend: bBackend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 4)),
        remotePeerId: PeerId(List.filled(16, 3)));
    await a.submitEncrypted(FrameType.data, [9]);
    expect((await b.receiveEncrypted(aBackend.writes.single))!.payload, [9]);
    expect(await b.receiveEncrypted(aBackend.writes.single), isNull);
  });

  test(
      'UT-162 live core schedules PING, echoes PONG, and detects liveness loss',
      () async {
    var nowMs = 0;
    final aBackend = _Backend();
    final a = PeerConnectionCore(
        backend: aBackend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)),
        keepaliveTiming: KeepaliveTiming.negotiate(2000, 2000),
        monotonicNowMs: () => nowMs);
    final bBackend = _Backend();
    final b = PeerConnectionCore(
        backend: bBackend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 4)),
        remotePeerId: PeerId(List.filled(16, 3)));

    nowMs = 2000;
    await a.pollKeepalive();
    expect(LpcFrame.decode(aBackend.writes.single).type, FrameType.ping);
    final ping = await b.receiveEncrypted(aBackend.writes.single);
    expect(ping!.payload, hasLength(16));
    expect(LpcFrame.decode(bBackend.writes.single).type, FrameType.pong);
    expect((await a.receiveEncrypted(bBackend.writes.single))!.payload,
        ping.payload);

    nowMs = 0;
    final lostBackend = _Backend();
    final lost = PeerConnectionCore(
        backend: lostBackend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 5)),
        remotePeerId: PeerId(List.filled(16, 6)),
        keepaliveTiming: KeepaliveTiming.negotiate(2000, 2000),
        monotonicNowMs: () => nowMs);
    nowMs = 6000;
    await lost.pollKeepalive();
    expect(lost.state, PeerConnectionState.reconnecting);
  });

  test('UT-163 live core retransmits ACK-required operations on deadline',
      () async {
    var nowMs = 0;
    final backend = _Backend();
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)),
        monotonicNowMs: () => nowMs);
    final messageId = List.filled(8, 9);
    await peer.submitAckRequiredFrame(
        type: FrameType.membershipSnapshot,
        payload: [7],
        messageId: messageId,
        nowMs: nowMs);

    nowMs = 2999;
    await peer.pollAckTimeouts();
    expect(backend.writes, hasLength(1));
    nowMs = 3000;
    await peer.pollAckTimeouts();
    expect(backend.writes, hasLength(2));
    nowMs = 6000;
    await peer.pollAckTimeouts();
    expect(backend.writes, hasLength(3));
    nowMs = 9000;
    await peer.pollAckTimeouts();
    expect(backend.writes, hasLength(3));
    expect(peer.ackRetention.length, 0);
  });

  test('PeerConnection sends generic ACK with mandated zero header fields',
      () async {
    final aBackend = _Backend();
    final a = PeerConnectionCore(
        backend: aBackend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final bBackend = _Backend();
    final b = PeerConnectionCore(
        backend: bBackend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 4)),
        remotePeerId: PeerId(List.filled(16, 3)));
    await a.submitAck(List.filled(8, 9));
    expect(
        b
            .parseAck((await b.receiveEncrypted(aBackend.writes.single))!)!
            .messageId,
        List.filled(8, 9));
  });

  test('terminal backend write failure starts generation-wide reconnect',
      () async {
    final backend = _Backend()..failWrites = true;
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    expect(await peer.submitEncrypted(FrameType.data, [7]),
        TransportWriteState.failed);
    await Future<void>.delayed(Duration.zero);
    expect(peer.state, PeerConnectionState.reconnecting);
  });

  test('UT-039 backend close rejects further peer traffic with INVALID_STATE',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    backend.controller.add(const BackendClosed());
    await Future<void>.delayed(Duration.zero);
    expect(peer.state, PeerConnectionState.reconnecting);
    await expectLater(
        peer.submitEncrypted(FrameType.data, [7]),
        throwsA(isA<LpcException>()
            .having((error) => error.code, 'code', LpcErrorCode.invalidState)));
  });

  test('UT-038 DiscoverySession.stop does not close a PeerConnection',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
      backend: backend,
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    var stopped = 0;
    final discovery = DiscoverySession(stopPlatformScan: () async {
      stopped++;
    });
    final events = <DiscoveryEvent>[];
    final subscription = discovery.events.listen(events.add);

    await discovery.stop();
    await discovery.stop();
    expect(stopped, 1);
    expect(events, hasLength(1));
    expect(events.single, isA<DiscoveryStopped>());
    expect(peer.state, PeerConnectionState.ready);
    expect(await peer.submitEncrypted(FrameType.data, [1]),
        TransportWriteState.submittedToPlatform);
    await subscription.cancel();
  });

  test('UT-074 terminal transport loss fails every pending generation write',
      () async {
    final backend = _Backend()..leaveWritesPending = true;
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final first = peer.submitEncrypted(FrameType.data, [1]);
    final second = peer.submitEncrypted(FrameType.data, [2]);
    await Future<void>.delayed(Duration.zero);
    backend.controller.add(const BackendClosed());
    expect(await first, TransportWriteState.failed);
    expect(await second, TransportWriteState.failed);
  });

  test('UT-073 failed ACK-required write arms no timer or same-generation send',
      () async {
    final backend = _Backend()..leaveWritesPending = true;
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final id = List.filled(8, 1);
    final submission = peer.submitAckRequiredFrame(
        type: FrameType.data, payload: [7], messageId: id, nowMs: 0);
    await Future<void>.delayed(Duration.zero);
    backend.controller.add(const BackendClosed());
    expect(await submission, TransportWriteState.failed);
    expect(peer.state, PeerConnectionState.reconnecting);
    expect(
        peer.ackRetention.onTimer(id, nowMs: 10000), AckTimeoutResult.ignored);
    await expectLater(peer.submitEncrypted(FrameType.data, [1]),
        throwsA(isA<LpcException>()));
  });

  test('UT-027 RESUME increments generation and resets wire sequence to one',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    await peer.submitEncrypted(FrameType.data, [1]);
    peer.beginReconnect();
    peer.completeResume(
        newGeneration: 2, resumedSessionRootKey: List.filled(32, 5));
    await peer.submitEncrypted(FrameType.data, [2]);

    final resumedFrame = LpcFrame.decode(backend.writes.last);
    expect(resumedFrame.transportGeneration, 2);
    expect(resumedFrame.sequenceNumber, 1);
  });

  test('UT-019 ACK timeout retransmits same MessageId with a new sequence',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final messageId = List.filled(8, 9);
    await peer.submitAckRequiredFrame(
        type: FrameType.data, payload: [7], messageId: messageId, nowMs: 0);
    expect(await peer.retryAckRequiredFrame(messageId, nowMs: 3000),
        AckTimeoutResult.retransmitWholeOperation);

    final original = LpcFrame.decode(backend.writes.first);
    final retry = LpcFrame.decode(backend.writes.last);
    expect(original.flags, 1);
    expect(retry.flags, 1);
    expect(retry.messageId, original.messageId);
    expect(retry.sequenceNumber, greaterThan(original.sequenceNumber));

    final receiver = PeerConnectionCore(
        backend: _Backend(),
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 4)),
        remotePeerId: PeerId(List.filled(16, 3)));
    expect(
        (await receiver.receiveEncrypted(backend.writes.first))!.payload, [7]);
    expect(
        (await receiver.receiveEncrypted(backend.writes.last))!.payload, [7]);
  });

  test('UT-028 unacknowledged ACK-required frame retransmits after RESUME',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final messageId = List.filled(8, 8);
    await peer.submitAckRequiredFrame(
        type: FrameType.data, payload: [7], messageId: messageId, nowMs: 0);
    peer.beginReconnect();
    peer.completeResume(
        newGeneration: 2, resumedSessionRootKey: List.filled(32, 5));

    final retried =
        await peer.retransmitAckRequiredFramesAfterResume(nowMs: 10);
    final frame = LpcFrame.decode(backend.writes.last);
    expect(retried.single.messageId, messageId);
    expect(frame.messageId, messageId);
    expect(frame.transportGeneration, 2);
    expect(frame.sequenceNumber, 1);
  });

  test('UT-029 non-ACK frame is not automatically retransmitted after RESUME',
      () async {
    final backend = _Backend();
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    await peer.submitEncrypted(FrameType.data, [7]);
    peer.beginReconnect();
    peer.completeResume(
        newGeneration: 2, resumedSessionRootKey: List.filled(32, 5));

    expect(
        await peer.retransmitAckRequiredFramesAfterResume(nowMs: 10), isEmpty);
    expect(backend.writes, hasLength(1));
  });

  test('authenticated ACK removes only its retained logical operation',
      () async {
    final aBackend = _Backend();
    final bBackend = _Backend();
    final a = PeerConnectionCore(
        backend: aBackend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final b = PeerConnectionCore(
        backend: bBackend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 4)),
        remotePeerId: PeerId(List.filled(16, 3)));
    a.ackRetention.retain(messageId: List.filled(8, 5), logicalContent: [1]);
    await b.submitAck(List.filled(8, 5));
    await a.receiveEncrypted(bBackend.writes.single);
    expect(a.ackRetention.length, 0);
  });
}

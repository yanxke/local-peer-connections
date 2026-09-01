import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

class _GattPlatform implements GattFragmentPlatform {
  _GattPlatform(Iterable<GattFragmentSubmission> responses,
      {this.safeWriteSize = 10})
      : _responses = Queue<GattFragmentSubmission>.of(responses);

  final Queue<GattFragmentSubmission> _responses;
  final List<Uint8List> submitted = <Uint8List>[];
  final List<GattFragmentTransmission> transmissions =
      <GattFragmentTransmission>[];
  final int safeWriteSize;
  @override
  int get platformSafeWriteSize => safeWriteSize;
  @override
  Future<void> close() async {}
  @override
  Future<GattFragmentSubmission> submitGattFragment(Uint8List fragment,
      {GattFragmentTransmission transmission =
          GattFragmentTransmission.normal}) async {
    submitted.add(fragment);
    transmissions.add(transmission);
    return _responses.removeFirst();
  }
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  test('UT-063 GATT fragmentation-queue insertion is not transport submission',
      () async {
    final platform =
        _GattPlatform([GattFragmentSubmission.temporarilyUnavailable]);
    final backend =
        GattBackendConnection(connectionId: 'gatt', platform: platform);

    final write = backend.write(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]));
    // `write` has accepted and queued the fragmented LPC frame, but no final
    // platform fragment submission has occurred.
    expect(write.state, TransportWriteState.pending);
    await _turn();
    expect(write.state, TransportWriteState.pending);
  });

  test('UT-064/068 GATT write remains pending until final fragment submission',
      () async {
    final platform = _GattPlatform([
      GattFragmentSubmission.temporarilyUnavailable,
      GattFragmentSubmission.submitted,
      GattFragmentSubmission.submitted,
      GattFragmentSubmission.submitted,
    ]);
    final backend =
        GattBackendConnection(connectionId: 'gatt', platform: platform);
    final write = backend.write(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]));
    await _turn();
    expect(write.state, TransportWriteState.pending);
    expect(platform.submitted, hasLength(1));

    backend.writable();
    expect(await write.completion, TransportWriteState.submittedToPlatform);
    expect(platform.submitted, hasLength(4));
  });

  test('UT-071 transient GATT backpressure remains pending and stays READY',
      () async {
    final platform = _GattPlatform([
      GattFragmentSubmission.temporarilyUnavailable,
      ...List.filled(32, GattFragmentSubmission.submitted),
    ]);
    final backend =
        GattBackendConnection(connectionId: 'gatt', platform: platform);
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final write = peer.submitEncrypted(FrameType.ping, [1]);
    await _turn();
    expect(peer.state, PeerConnectionState.ready);

    backend.writable();
    expect(await write, TransportWriteState.submittedToPlatform);
    expect(peer.state, PeerConnectionState.ready);
  });

  test('UT-072/074 terminal fragment failure fails every pending write',
      () async {
    final platform = _GattPlatform([GattFragmentSubmission.terminalFailure]);
    final backend =
        GattBackendConnection(connectionId: 'gatt', platform: platform);
    final first = backend.write(Uint8List.fromList([1]));
    final second = backend.write(Uint8List.fromList([2]));
    expect(await first.completion, TransportWriteState.failed);
    expect(await second.completion, TransportWriteState.failed);
    expect(backend.state, TransportConnectionState.failed);
    expect(() => backend.write(Uint8List.fromList([3])),
        throwsA(isA<LpcException>()));
  });

  test('UT-072 terminal GATT failure moves its PeerConnection to reconnecting',
      () async {
    final platform = _GattPlatform([GattFragmentSubmission.terminalFailure]);
    final backend =
        GattBackendConnection(connectionId: 'gatt', platform: platform);
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    expect(await peer.submitEncrypted(FrameType.ping, [1]),
        TransportWriteState.failed);
    await _turn();
    expect(peer.state, PeerConnectionState.reconnecting);
  });

  test('UT-069 failed GATT submission never starts an ACK timer', () async {
    final platform = _GattPlatform([GattFragmentSubmission.terminalFailure]);
    final backend =
        GattBackendConnection(connectionId: 'gatt', platform: platform);
    final peer = PeerConnectionCore(
      backend: backend,
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    final messageId = List.filled(8, 9);

    expect(
      await peer.submitAckRequiredFrame(
        type: FrameType.membershipSnapshot,
        payload: [1],
        messageId: messageId,
        nowMs: 0,
      ),
      TransportWriteState.failed,
    );
    expect(
      await peer.retryAckRequiredFrame(messageId, nowMs: 3000),
      AckTimeoutResult.ignored,
    );
  });

  test(
      'UT-065 ACK timer waits for final physical GATT fragment of final DATA frame',
      () async {
    // GATT fragments are capped at 512 payload bytes. Submit every fragment
    // of the first DATA frame, then hold the only/final fragment of the final
    // DATA frame at the platform boundary.
    final platform = _GattPlatform(
      [
        ...List.filled(33, GattFragmentSubmission.submitted),
        GattFragmentSubmission.temporarilyUnavailable,
        GattFragmentSubmission.submitted,
      ],
      safeWriteSize: 20000,
    );
    final backend =
        GattBackendConnection(connectionId: 'gatt', platform: platform);
    final peer = PeerConnectionCore(
      backend: backend,
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    final id = List.filled(8, 9);
    final submission = peer.submitReliableData(
      bytes: List.filled(maxDataChunkBytes + 1, 7),
      deliveryMode: DeliveryMode.reliableAcked,
      priority: SendPriority.interactive,
      messageId: id,
      nowMs: 0,
    );

    await _turn();
    expect(platform.submitted, hasLength(34));
    expect(
      peer.ackRetention.onTimer(id, nowMs: 3000),
      AckTimeoutResult.ignored,
    );

    backend.writable();
    expect(
      await submission,
      everyElement(TransportWriteState.submittedToPlatform),
    );
    expect(
      peer.ackRetention.onTimer(id, nowMs: 3000),
      AckTimeoutResult.retransmitWholeOperation,
    );
  });

  test('bounded GATT queue rejects new work without failing accepted work',
      () async {
    final platform =
        _GattPlatform([GattFragmentSubmission.temporarilyUnavailable]);
    final backend = GattBackendConnection(
        connectionId: 'gatt', platform: platform, maxQueuedBytes: 7);
    expect(() => backend.write(Uint8List.fromList([1])),
        throwsA(isA<LpcException>()));
    expect(backend.state, TransportConnectionState.open);
  });

  test('RT-011 GATT central realtime uses Write Without Response', () async {
    final platform = _GattPlatform([GattFragmentSubmission.submitted]);
    final backend = GattBackendConnection(
      connectionId: 'gatt',
      platform: platform,
      localRole: GattLinkRole.central,
    );

    expect(
      await backend.writeRealtime(Uint8List.fromList([1])).completion,
      TransportWriteState.submittedToPlatform,
    );
    expect(platform.transmissions,
        [GattFragmentTransmission.writeWithoutResponse]);
  });

  test('RT-012 GATT peripheral realtime uses Notify', () async {
    final platform = _GattPlatform([GattFragmentSubmission.submitted]);
    final backend = GattBackendConnection(
      connectionId: 'gatt',
      platform: platform,
      localRole: GattLinkRole.peripheral,
    );

    expect(
      await backend.writeRealtime(Uint8List.fromList([1])).completion,
      TransportWriteState.submittedToPlatform,
    );
    expect(platform.transmissions, [GattFragmentTransmission.notify]);
  });
}

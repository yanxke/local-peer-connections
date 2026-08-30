import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

class _Backend implements BackendConnection {
  final writes = <Uint8List>[];
  final StreamController<BackendConnectionEvent> controller =
      StreamController<BackendConnectionEvent>.broadcast();
  bool failWrites = false;
  bool leaveWritesPending = false;
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
    if (failWrites) {
      write.fail();
    } else if (!leaveWritesPending) {
      write.submittedToPlatform();
    }
    return write;
  }
}

void main() {
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
    expect(await peer.submitEncrypted(FrameType.ping, [7]),
        TransportWriteState.submittedToPlatform);
    expect(LpcFrame.decode(backend.writes.single).encrypted, isTrue);
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
    await a.submitEncrypted(FrameType.ping, [9]);
    expect((await b.receiveEncrypted(aBackend.writes.single))!.payload, [9]);
    expect(await b.receiveEncrypted(aBackend.writes.single), isNull);
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
    expect(await peer.submitEncrypted(FrameType.ping, [7]),
        TransportWriteState.failed);
    await Future<void>.delayed(Duration.zero);
    expect(peer.state, PeerConnectionState.reconnecting);
  });

  test('backend close starts reconnect and further traffic is rejected',
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
    await expectLater(peer.submitEncrypted(FrameType.ping, [7]),
        throwsA(isA<LpcException>()));
  });

  test('terminal transport loss fails every pending generation write',
      () async {
    final backend = _Backend()..leaveWritesPending = true;
    final peer = PeerConnectionCore(
        backend: backend,
        sessionRootKey: List.filled(32, 1),
        sessionId: List.filled(16, 2),
        localPeerId: PeerId(List.filled(16, 3)),
        remotePeerId: PeerId(List.filled(16, 4)));
    final first = peer.submitEncrypted(FrameType.ping, [1]);
    final second = peer.submitEncrypted(FrameType.pong, [2]);
    await Future<void>.delayed(Duration.zero);
    backend.controller.add(const BackendClosed());
    expect(await first, TransportWriteState.failed);
    expect(await second, TransportWriteState.failed);
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

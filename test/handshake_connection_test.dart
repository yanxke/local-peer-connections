import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

const _uuid = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];

class _Backend implements BackendConnection {
  _Backend(this.connectionId);

  @override
  final String connectionId;
  _Backend? remote;
  bool closed = false;
  final List<Uint8List> writes = <Uint8List>[];
  final StreamController<BackendConnectionEvent> _events =
      StreamController<BackendConnectionEvent>.broadcast();

  @override
  TransportType get transportType => TransportType.gatt;
  @override
  TransportConnectionState get state =>
      closed ? TransportConnectionState.closed : TransportConnectionState.open;
  @override
  int get maxWriteSize => 512;
  @override
  Stream<BackendConnectionEvent> get events => _events.stream;
  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  TransportWrite write(Uint8List frame) {
    writes.add(frame);
    final write = TransportWrite()..submittedToPlatform();
    Future<void>.microtask(
        () => remote!._events.add(BackendBytesReceived(frame)));
    return write;
  }
}

Future<HandshakeExchange> _exchange(int identitySeed, int ephemeralSeed,
    {HandshakeTrustMode trustMode = HandshakeTrustMode.tofu}) async {
  final identity =
      await Ed25519().newKeyPairFromSeed(List.filled(32, identitySeed));
  final ephemeral =
      await X25519().newKeyPairFromSeed(List.filled(32, ephemeralSeed));
  final identityPublic = await identity.extractPublicKey();
  final ephemeralPublic = await ephemeral.extractPublicKey();
  return HandshakeExchange(
      serviceUuid: _uuid,
      localHello: HelloPayload(
          peerId: await PeerIdentity.peerIdForPublicKey(identityPublic.bytes),
          identityPublicKey: identityPublic.bytes,
          ephemeralPublicKey: ephemeralPublic.bytes,
          connectionNonce: List.filled(16, identitySeed),
          peerCapabilities: 3,
          keepaliveIntervalMs: identitySeed == 1 ? 1000 : 2000,
          trustMode: trustMode),
      localIdentityKeyPair: identity,
      localEphemeralKeyPair: ephemeral,
      tofuStore:
          trustMode == HandshakeTrustMode.tofu ? TofuIdentityStore() : null);
}

void main() {
  test(
      'UT-157 backend handshake exchanges authenticated READY before core readiness',
      () async {
    final backendA = _Backend('a');
    final backendB = _Backend('b');
    backendA.remote = backendB;
    backendB.remote = backendA;
    final exchangeA = await _exchange(1, 3);
    final exchangeB = await _exchange(2, 4);
    final a = HandshakeConnection(
        backend: backendA,
        exchange: exchangeA,
        localPeerId: exchangeA.localHello.peerId,
        remotePeerId: exchangeB.localHello.peerId);
    final b = HandshakeConnection(
        backend: backendB,
        exchange: exchangeB,
        localPeerId: exchangeB.localHello.peerId,
        remotePeerId: exchangeA.localHello.peerId);

    await Future.wait([a.start(), b.start()]);
    final cores = await Future.wait([a.ready, b.ready])
        .timeout(const Duration(seconds: 2));

    expect(cores.map((core) => core.state),
        everyElement(PeerConnectionState.ready));
    expect(cores.map((core) => core.securityLevel),
        everyElement(SecurityLevel.encryptedTofu));
    expect(exchangeA.result!.keepaliveTiming.intervalMs, 2000);
    expect(exchangeB.result!.keepaliveTiming.intervalMs, 2000);
    expect(exchangeA.result!.keepaliveTiming.deadTimeoutMs, 6000);
    expect(exchangeB.result!.keepaliveTiming.deadTimeoutMs, 6000);
    for (final backend in [backendA, backendB]) {
      final readyFrames = backend.writes
          .map(LpcFrame.decode)
          .where((frame) => frame.type == FrameType.ready)
          .toList();
      expect(readyFrames, hasLength(1));
      expect(readyFrames.single.encrypted, isTrue);
      expect(readyFrames.single.transportGeneration, 1);
      expect(readyFrames.single.sequenceNumber, 1);
    }
    await cores[0].submitEncrypted(FrameType.data, [9]);
    expect(LpcFrame.decode(backendA.writes.last).sequenceNumber, 2);

    final replayedReadySequence = await _encryptedFrame(
        exchangeB.result!,
        exchangeB.localHello.peerId,
        exchangeA.localHello.peerId,
        FrameType.data,
        1,
        [1]);
    expect(await cores[0].receiveEncrypted(replayedReadySequence), isNull);
    final nextInbound = await _encryptedFrame(
        exchangeB.result!,
        exchangeB.localHello.peerId,
        exchangeA.localHello.peerId,
        FrameType.data,
        2,
        [2]);
    expect((await cores[0].receiveEncrypted(nextInbound))!.payload, [2]);
  });

  test('UT-169 SAS handshake exposes both verification values before READY',
      () async {
    final backendA = _Backend('sas-a');
    final backendB = _Backend('sas-b');
    backendA.remote = backendB;
    backendB.remote = backendA;
    final exchangeA =
        await _exchange(11, 13, trustMode: HandshakeTrustMode.sas);
    final exchangeB =
        await _exchange(12, 14, trustMode: HandshakeTrustMode.sas);
    String? sasA;
    String? sasB;
    late final HandshakeConnection a;
    late final HandshakeConnection b;
    a = HandshakeConnection(
        backend: backendA,
        exchange: exchangeA,
        localPeerId: exchangeA.localHello.peerId,
        onSasRequired: (_, sas) {
          sasA = sas;
          unawaited(a.confirmSas(true));
        });
    b = HandshakeConnection(
        backend: backendB,
        exchange: exchangeB,
        localPeerId: exchangeB.localHello.peerId,
        onSasRequired: (_, sas) {
          sasB = sas;
          unawaited(b.confirmSas(true));
        });

    await Future.wait([a.start(), b.start()]);
    final cores = await Future.wait([a.ready, b.ready])
        .timeout(const Duration(seconds: 2));

    expect(sasA, isNotNull);
    expect(sasA, sasB);
    expect(cores.map((core) => core.securityLevel),
        everyElement(SecurityLevel.authenticatedSas));
  });

  test('UT-177 candidate handshake authenticates without normal READY',
      () async {
    final backendA = _Backend('candidate-a');
    final backendB = _Backend('candidate-b');
    backendA.remote = backendB;
    backendB.remote = backendA;
    final exchangeA = await _exchange(21, 23);
    final exchangeB = await _exchange(22, 24);
    final a = HandshakeConnection(
        backend: backendA,
        exchange: exchangeA,
        localPeerId: exchangeA.localHello.peerId,
        candidateOnly: true);
    final b = HandshakeConnection(
        backend: backendB,
        exchange: exchangeB,
        localPeerId: exchangeB.localHello.peerId,
        candidateOnly: true);

    await Future.wait([a.start(), b.start()]);
    final results = await Future.wait([a.authenticated, b.authenticated])
        .timeout(const Duration(seconds: 2));

    expect(results.map((result) => result.secrets.sessionRootKey),
        everyElement(isNotEmpty));
    expect(
        [...backendA.writes, ...backendB.writes]
            .map(LpcFrame.decode)
            .where((frame) => frame.type == FrameType.ready),
        isEmpty);
  });

  test(
      'UT-179 selectable inbound handshake waits for READY before normal completion',
      () async {
    final backendA = _Backend('selectable-a');
    final backendB = _Backend('selectable-b');
    backendA.remote = backendB;
    backendB.remote = backendA;
    final exchangeA = await _exchange(31, 33);
    final exchangeB = await _exchange(32, 34);
    final initiator = HandshakeConnection(
        backend: backendA,
        exchange: exchangeA,
        localPeerId: exchangeA.localHello.peerId);
    final responder = HandshakeConnection(
        backend: backendB,
        exchange: exchangeB,
        localPeerId: exchangeB.localHello.peerId,
        acceptCandidateResume: true);

    await Future.wait([initiator.start(), responder.start()]);
    final cores = await Future.wait([initiator.ready, responder.ready])
        .timeout(const Duration(seconds: 2));
    expect(cores, everyElement(isA<PeerConnectionCore>()));
    expect(
        backendB.writes
            .map(LpcFrame.decode)
            .where((frame) => frame.type == FrameType.ready),
        hasLength(1));
  });
}

Future<Uint8List> _encryptedFrame(HandshakeResult result, PeerId sender,
    PeerId receiver, FrameType type, int sequence, List<int> payload) async {
  final direction = _compare(sender.bytes, receiver.bytes) < 0 ? 0 : 1;
  final key = await trafficKey(result.secrets.sessionRootKey, 1, direction);
  return (await const FrameProtector().encrypt(
          LpcFrame(
              type: type,
              flags: 0,
              transportGeneration: 1,
              sequenceNumber: sequence,
              messageId: List.filled(8, 0),
              sessionId: result.secrets.sessionId,
              nonce: List.filled(12, 0),
              payload: payload),
          await key.extractBytes()))
      .encode();
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    final value = a[i].compareTo(b[i]);
    if (value != 0) return value;
  }
  return 0;
}

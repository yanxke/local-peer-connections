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

Future<HandshakeExchange> _exchange(int identitySeed, int ephemeralSeed) async {
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
          trustMode: HandshakeTrustMode.tofu),
      localIdentityKeyPair: identity,
      localEphemeralKeyPair: ephemeral,
      tofuStore: TofuIdentityStore());
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
    expect(exchangeA.result!.keepaliveTiming.intervalMs, 2000);
    await cores[0].submitEncrypted(FrameType.ping, [9]);
    expect(LpcFrame.decode(backendA.writes.last).sequenceNumber, 2);

    final replayedReadySequence = await _encryptedFrame(
        exchangeB.result!,
        exchangeB.localHello.peerId,
        exchangeA.localHello.peerId,
        FrameType.ping,
        1,
        [1]);
    expect(await cores[0].receiveEncrypted(replayedReadySequence), isNull);
    final nextInbound = await _encryptedFrame(
        exchangeB.result!,
        exchangeB.localHello.peerId,
        exchangeA.localHello.peerId,
        FrameType.ping,
        2,
        [2]);
    expect((await cores[0].receiveEncrypted(nextInbound))!.payload, [2]);
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

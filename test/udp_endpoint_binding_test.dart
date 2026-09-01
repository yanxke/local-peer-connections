import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

UdpEndpoint _endpoint(int port, int lastOctet) => UdpEndpoint(
    addressFamily: UdpAddressFamily.ipv4,
    port: port,
    address: [192, 168, 1, lastOctet, ...List<int>.filled(12, 0)]);

class _ReadyBackend implements BackendConnection {
  @override
  String get connectionId => 'udp-isolation';
  @override
  TransportType get transportType => TransportType.gatt;
  @override
  TransportConnectionState get state => TransportConnectionState.open;
  @override
  int get maxWriteSize => 512;
  @override
  Stream<BackendConnectionEvent> get events => const Stream.empty();
  @override
  Future<void> close() async {}
  @override
  TransportWrite write(Uint8List completeSerializedLpcFrame) =>
      TransportWrite()..submittedToPlatform();
}

void main() {
  test('expected authenticated UDP source remains accepted', () {
    final binding =
        UdpEndpointBinding(channelId: 4, remoteEndpoint: _endpoint(5, 6));
    expect(binding.validateAuthenticatedSource(_endpoint(5, 6)),
        isA<UdpEndpointAccept>());
    expect(binding.valid, isTrue);
  });

  test('unexpected authenticated UDP source invalidates only the sidecar', () {
    final binding =
        UdpEndpointBinding(channelId: 4, remoteEndpoint: _endpoint(5, 6));
    final decision = binding.validateAuthenticatedSource(_endpoint(7, 6));
    expect(decision, isA<UdpEndpointChanged>());
    expect((decision as UdpEndpointChanged).close.reason,
        UdpCloseReason.networkChanged);
    expect(binding.valid, isFalse);
    expect(binding.validateAuthenticatedSource(_endpoint(5, 6)),
        isA<UdpEndpointDiscard>());
  });

  test('RT-020/021 endpoint movement falls back without mutating reliability',
      () {
    final sidecar = UdpSidecarLifecycle.active(
      sessionId: List.filled(16, 1),
      reliableGeneration: 7,
      binding:
          UdpEndpointBinding(channelId: 4, remoteEndpoint: _endpoint(5, 6)),
    );

    final action = sidecar.authenticatedSource(_endpoint(7, 6));
    expect(action?.close?.reason, UdpCloseReason.networkChanged);
    expect(action?.fallbackToReliable, isTrue);
    expect(action?.requiresFreshSidecar, isTrue);
    expect(sidecar.state, UdpRealtimeState.failed);
    expect(sidecar.reliableGeneration, 7);
  });

  test('RT-023 reliable RESUME destroys the old UDP sidecar', () async {
    final sidecar = UdpSidecarLifecycle.active(
      sessionId: List.filled(16, 1),
      reliableGeneration: 7,
      binding:
          UdpEndpointBinding(channelId: 4, remoteEndpoint: _endpoint(5, 6)),
    );

    final action = sidecar.reliableResumed(8);
    expect(action?.close, isNull);
    expect(action?.fallbackToReliable, isTrue);
    expect(action?.requiresFreshSidecar, isTrue);
    expect(sidecar.state, UdpRealtimeState.failed);
    expect(sidecar.reliableGeneration, 8);

    final oldKeys = await deriveUdpSidecarKeys(
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 1),
      reliableGeneration: 7,
      channelId: 4,
      offerNonce: List.filled(16, 2),
      acceptNonce: List.filled(16, 3),
    );
    final resumedKeys = await deriveUdpSidecarKeys(
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 1),
      reliableGeneration: 8,
      channelId: 4,
      offerNonce: List.filled(16, 2),
      acceptNonce: List.filled(16, 3),
    );
    expect(resumedKeys.root, isNot(oldKeys.root));
  });

  test(
      'RT-027 endpoint change invalidates UDP only; PeerConnection stays READY',
      () async {
    final peer = PeerConnectionCore(
      backend: _ReadyBackend(),
      sessionRootKey: List.filled(32, 1),
      sessionId: List.filled(16, 2),
      localPeerId: PeerId(List.filled(16, 3)),
      remotePeerId: PeerId(List.filled(16, 4)),
    );
    final sidecar = UdpSidecarLifecycle.active(
      sessionId: List.filled(16, 2),
      reliableGeneration: peer.generation,
      binding:
          UdpEndpointBinding(channelId: 4, remoteEndpoint: _endpoint(5, 6)),
    );

    expect(sidecar.authenticatedSource(_endpoint(7, 6)), isNotNull);
    expect(sidecar.state, UdpRealtimeState.failed);
    expect(peer.state, PeerConnectionState.ready);
    expect(peer.generation, 1);
    await peer.close();
  });
}

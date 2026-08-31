import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

class _GattPlatform implements GattFragmentPlatform {
  _GattPlatform(Iterable<GattFragmentSubmission> responses)
      : _responses = Queue<GattFragmentSubmission>.of(responses);

  final Queue<GattFragmentSubmission> _responses;
  final List<Uint8List> submitted = <Uint8List>[];
  @override
  int get platformSafeWriteSize => 10;
  @override
  Future<void> close() async {}
  @override
  Future<GattFragmentSubmission> submitGattFragment(Uint8List fragment) async {
    submitted.add(fragment);
    return _responses.removeFirst();
  }
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  test('UT-068 GATT write remains pending until final fragment submission',
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
}

import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

class _StreamPlatform implements StreamWritePlatform {
  _StreamPlatform(Iterable<StreamWriteSubmission> responses)
      : _responses = Queue.of(responses);

  final Queue<StreamWriteSubmission> _responses;
  final List<Uint8List> writes = [];
  @override
  Future<void> close() async {}

  @override
  Future<StreamWriteSubmission> write(Uint8List bytes) async {
    writes.add(Uint8List.fromList(bytes));
    return _responses.removeFirst();
  }
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  test('UT-066 TCP waits for all serialized bytes before transport submission',
      () async {
    final platform = _StreamPlatform([
      const StreamBytesAccepted(2),
      const StreamTemporarilyUnavailable(),
      const StreamBytesAccepted(3),
    ]);
    final backend = StreamBackendConnection(
      connectionId: 'tcp',
      transportType: TransportType.lanTcp,
      platform: platform,
    );
    final write = backend.write(Uint8List.fromList([1, 2, 3, 4, 5]));
    await _turn();
    expect(write.state, TransportWriteState.pending);
    expect(platform.writes.map((bytes) => bytes.length), [5, 3]);
    backend.writable();
    expect(await write.completion, TransportWriteState.submittedToPlatform);
  });

  test(
      'UT-067 L2CAP waits for all serialized bytes before transport submission',
      () async {
    final platform = _StreamPlatform([
      const StreamBytesAccepted(1),
      const StreamBytesAccepted(2),
    ]);
    final backend = StreamBackendConnection(
      connectionId: 'l2cap',
      transportType: TransportType.l2cap,
      platform: platform,
    );
    final write = backend.write(Uint8List.fromList([1, 2, 3]));
    expect(await write.completion, TransportWriteState.submittedToPlatform);
    expect(platform.writes.map((bytes) => bytes.length), [3, 2]);
  });
}

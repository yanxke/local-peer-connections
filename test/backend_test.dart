import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('TransportWrite remains pending until platform submission', () async {
    final write = TransportWrite();
    expect(write.state, TransportWriteState.pending);
    write.submittedToPlatform();
    expect(await write.completion, TransportWriteState.submittedToPlatform);
  });
  test('terminal failure does not become submitted later', () async {
    final write = TransportWrite();
    write.fail();
    write.submittedToPlatform();
    expect(await write.completion, TransportWriteState.failed);
  });
}

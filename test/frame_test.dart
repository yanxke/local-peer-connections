import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

List<int> _bytes(int length, [int value = 0]) =>
    List<int>.filled(length, value);

void main() {
  // UT-015: parser rejects payloads above Section 13's allocation limit.
  test('UT-015 rejects oversized encrypted payload before allocation', () {
    final bytes = _bytes(62);
    bytes.setRange(0, 4, 'LPC1'.codeUnits);
    bytes[4] = 1;
    bytes[5] = 1;
    bytes[6] = FrameType.data.value;
    bytes[8] = 0;
    bytes[9] = 62;
    bytes[12] = 0x40;
    bytes[13] = 1;
    expect(() => LpcFrame.decode(bytes), throwsA(isA<LpcException>()));
  });

  // UT-048: ACK_REQUIRED is the only accepted frame-flag bit.
  test('UT-048 preserves ACK_REQUIRED binary flag', () {
    final frame = LpcFrame(
        type: FrameType.data,
        flags: 1,
        transportGeneration: 0,
        sequenceNumber: 1,
        messageId: _bytes(8),
        sessionId: _bytes(16),
        nonce: _bytes(12),
        payload: [1, 2],
        tag: _bytes(16));
    final encoded = frame.encode();
    expect(encoded[7], 1);
    expect(LpcFrame.decode(encoded).flags, 1);
  });

  test('frame uses the Section 13 header layout and network byte order', () {
    final frame = LpcFrame(
        type: FrameType.ping,
        flags: 0,
        transportGeneration: 0x01020304,
        sequenceNumber: 7,
        messageId: _bytes(8),
        sessionId: _bytes(16),
        nonce: _bytes(12),
        payload: [7],
        tag: _bytes(16));
    final encoded = frame.encode();
    expect(encoded.sublist(0, 10), [0x4c, 0x50, 0x43, 0x31, 1, 1, 4, 0, 0, 62]);
    expect(encoded.sublist(14, 18), [1, 2, 3, 4]);
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/src/backend.dart';
import 'package:local_peer_connections/src/mesh_backend_connection.dart';
import 'package:local_peer_connections/src/protocol/frame.dart';
import 'package:local_peer_connections/src/protocol/mesh_relay.dart';
import 'package:local_peer_connections/src/types.dart';

void main() {
  final vector =
      (jsonDecode(File('test/vectors/mesh_minor0.json').readAsStringSync())
          as Map<String, dynamic>);
  final a = PeerId(_unhex(vector['peer_a'] as String));
  final c = PeerId(_unhex(vector['peer_c'] as String));

  test('UT-266 mesh advert vector and canonical validation', () {
    final expected = _unhex(vector['advert_payload'] as String);
    final advert = MeshAdvert(vector['advert_generation'] as int, [a, c]);
    expect(advert.encode(), expected);
    expect(MeshAdvert.decode(expected).neighbors, [a, c]);
    expect(
      () => MeshAdvert.decode(expected.sublist(0, expected.length - 1)),
      throwsA(isA<LpcException>()),
    );
    expect(() => MeshAdvert(1, [c, a]), throwsA(isA<LpcException>()));
    expect(() => MeshAdvert(1, [a, a]), throwsA(isA<LpcException>()));
  });

  test('UT-267 mesh frame and receipt vectors reject malformed lengths', () {
    final chunk = MeshFrame(
      kind: MeshFrameKind.chunk,
      source: a,
      destination: c,
      frameId: 0x0102030405060708,
      chunkIndex: 0,
      chunkCount: 1,
      bytes: [0x4c, 0x50, 0x43],
    );
    final receipt = MeshFrame(
      kind: MeshFrameKind.receipt,
      source: c,
      destination: a,
      frameId: chunk.frameId,
      chunkIndex: 0,
      chunkCount: 0,
      bytes: const [],
    );
    final expectedChunk = _unhex(vector['chunk_payload'] as String);
    final expectedReceipt = _unhex(vector['receipt_payload'] as String);
    expect(chunk.encode(), expectedChunk);
    expect(receipt.encode(), expectedReceipt);
    expect(MeshFrame.decode(expectedChunk).bytes, [0x4c, 0x50, 0x43]);
    expect(MeshFrame.decode(expectedReceipt).kind, MeshFrameKind.receipt);
    expect(
      () => MeshFrame.decode([...expectedChunk, 0]),
      throwsA(isA<LpcException>()),
    );
    expect(
      () => MeshFrame.decode(expectedChunk.sublist(0, 47)),
      throwsA(isA<LpcException>()),
    );
    expect(
      () => MeshFrame(
        kind: MeshFrameKind.chunk,
        source: a,
        destination: c,
        frameId: 1,
        chunkIndex: 5,
        chunkCount: 5,
        bytes: const [],
      ),
      throwsA(isA<LpcException>()),
    );
    final maxChunk = MeshFrame(
      kind: MeshFrameKind.chunk,
      source: a,
      destination: c,
      frameId: 2,
      chunkIndex: 0,
      chunkCount: 1,
      bytes: List<int>.filled(meshRelayChunkBytes, 0),
    );
    final outer = LpcFrame(
      type: FrameType.meshFrame,
      flags: 0,
      protocolMinor: 0,
      transportGeneration: 1,
      sequenceNumber: 1,
      messageId: List<int>.filled(8, 0),
      sessionId: List<int>.filled(16, 0),
      nonce: List<int>.filled(12, 0),
      payload: maxChunk.encode(),
      tag: List<int>.filled(16, 0),
    );
    expect(outer.encode().length, 4026);
    expect(outer.encode().length, lessThanOrEqualTo(4096));
    expect(
      () => MeshFrame(
        kind: MeshFrameKind.chunk,
        source: a,
        destination: c,
        frameId: 3,
        chunkIndex: 0,
        chunkCount: 1,
        bytes: List<int>.filled(meshRelayChunkBytes + 1, 0),
      ),
      throwsA(isA<LpcException>()),
    );
  });

  test(
    'UT-269 realtime relay writes are one-shot and do not await receipt',
    () async {
      final sent = <MeshFrame>[];
      final backend = MeshBackendConnection(
        localPeerId: a,
        remotePeerId: c,
        relayPeerId: PeerId(List<int>.filled(16, 0x10)),
        sendEnvelope: (packet) async {
          sent.add(packet);
          return TransportWriteState.submittedToPlatform;
        },
      );
      final wire = _innerFrame(FrameType.realtimeDatagram);
      final write = backend.write(wire);
      expect(
        await write.completion.timeout(const Duration(seconds: 1)),
        TransportWriteState.submittedToPlatform,
      );
      expect(sent, hasLength(1));
      await backend.close();
    },
  );

  test('UT-270 reliable relay write waits for destination receipt', () async {
    final sent = <MeshFrame>[];
    final backend = MeshBackendConnection(
      localPeerId: a,
      remotePeerId: c,
      relayPeerId: PeerId(List<int>.filled(16, 0x10)),
      sendEnvelope: (packet) async {
        sent.add(packet);
        return TransportWriteState.submittedToPlatform;
      },
    );
    final write = backend.write(_innerFrame(FrameType.data));
    await Future<void>.delayed(Duration.zero);
    expect(write.state, TransportWriteState.pending);
    expect(sent, hasLength(1));
    backend.receiveReceipt(sent.single.frameId);
    expect(await write.completion, TransportWriteState.submittedToPlatform);
    await backend.close();
  });

  test(
    'UT-273 multi-chunk receipt allowance exceeds a one-second BLE pause',
    () async {
      final sent = <MeshFrame>[];
      final backend = MeshBackendConnection(
        localPeerId: a,
        remotePeerId: c,
        relayPeerId: PeerId(List<int>.filled(16, 0x10)),
        sendEnvelope: (packet) async {
          sent.add(packet);
          return TransportWriteState.submittedToPlatform;
        },
      );
      final write = backend.write(
        _innerFrame(FrameType.data, payloadBytes: 4096),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(sent, hasLength(2));
      expect(write.state, TransportWriteState.pending);
      backend.receiveReceipt(sent.first.frameId);
      expect(await write.completion, TransportWriteState.submittedToPlatform);
      await backend.close();
    },
  );
}

Uint8List _innerFrame(FrameType type, {int payloadBytes = 3}) => LpcFrame(
  type: type,
  flags: 0,
  protocolMinor: 0,
  transportGeneration: 1,
  sequenceNumber: 2,
  messageId: List<int>.filled(8, 0),
  sessionId: List<int>.filled(16, 1),
  nonce: List<int>.filled(12, 0),
  payload: List<int>.filled(payloadBytes, 3),
  tag: List<int>.filled(16, 0),
).encode();

List<int> _unhex(String value) => [
  for (var index = 0; index < value.length; index += 2)
    int.parse(value.substring(index, index + 2), radix: 16),
];

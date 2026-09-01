import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-009 negotiates only the frozen minor 1 range', () {
    expect(negotiateMinor(localMin: 1, localMax: 1, remoteMin: 1, remoteMax: 1),
        1);
    expect(negotiateMinor(localMin: 1, localMax: 1, remoteMin: 0, remoteMax: 0),
        isNull);
  });
  test('UT-087 HELLO round trip verifies PeerId and fixed layout', () async {
    final key = List<int>.generate(32, (i) => i);
    final hello = HelloPayload(
        peerId: await PeerIdentity.peerIdForPublicKey(key),
        identityPublicKey: key,
        ephemeralPublicKey: List.filled(32, 2),
        connectionNonce: List.filled(16, 3),
        peerCapabilities: 1);
    expect(hello.encode().length, 112);
    expect((await HelloPayload.decode(hello.encode())).topology,
        HelloTopology.autoGroup);
  });
  test('UT-002 HELLO exact binary encode/decode is stable', () async {
    final key = List<int>.generate(32, (i) => i);
    final hello = HelloPayload(
      peerId: await PeerIdentity.peerIdForPublicKey(key),
      identityPublicKey: key,
      ephemeralPublicKey: List.filled(32, 2),
      connectionNonce: List.filled(16, 3),
      peerCapabilities: 1,
      keepaliveIntervalMs: 3000,
    );
    final encoded = hello.encode();
    expect(
      _hex(encoded),
      '630dcd2966c4336691125448bbb25b4f000102030405060708090a0b0c0d0e0f'
      '101112131415161718191a1b1c1d1e1f02020202020202020202020202020202'
      '0202020202020202020202020202020203030303030303030303030303030303'
      '000000010101030304000bb800100000',
    );
    expect((await HelloPayload.decode(encoded)).encode(), encoded);
  });
  test('UT-156 HELLO encodes the local keepalive interval at offset 106',
      () async {
    final key = List<int>.generate(32, (i) => i);
    final hello = HelloPayload(
        peerId: await PeerIdentity.peerIdForPublicKey(key),
        identityPublicKey: key,
        ephemeralPublicKey: List.filled(32, 2),
        connectionNonce: List.filled(16, 3),
        peerCapabilities: 1,
        keepaliveIntervalMs: 3000);
    final bytes = hello.encode();
    expect(ByteData.sublistView(bytes).getUint16(106), 3000);
    expect((await HelloPayload.decode(bytes)).keepaliveIntervalMs, 3000);
  });
  test('HELLO keepalive binary vector is byte-for-byte stable', () async {
    final key = List<int>.generate(32, (i) => i);
    final hello = HelloPayload(
        peerId: await PeerIdentity.peerIdForPublicKey(key),
        identityPublicKey: key,
        ephemeralPublicKey: List.filled(32, 2),
        connectionNonce: List.filled(16, 3),
        peerCapabilities: 1,
        keepaliveIntervalMs: 3000);
    expect(
        _hex(hello.encode()),
        '630dcd2966c4336691125448bbb25b4f000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f02020202020202020202020202020202'
        '0202020202020202020202020202020203030303030303030303030303030303'
        '000000010101030304000bb800100000');
  });
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

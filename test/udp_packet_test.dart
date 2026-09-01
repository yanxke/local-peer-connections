import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('LPU1 packet encrypts with header AAD and round-trips', () async {
    final plain = UdpPacket(
        protocolMinor: 1,
        type: UdpPacketType.probe,
        reliableGeneration: 1,
        channelId: 2,
        sequence: BigInt.one,
        sessionId: List.filled(16, 3),
        payload: List.filled(16, 4));
    final protected =
        await const UdpPacketProtector().encrypt(plain, List.filled(32, 1));
    expect(protected.encode(), hasLength(76));
    final clear = await const UdpPacketProtector()
        .decrypt(UdpPacket.decode(protected.encode()), List.filled(32, 1));
    expect(clear.payload, plain.payload);
  });

  test('maximum realtime body fits within the UDP datagram bound', () async {
    final realtime = RealtimeDatagram(
        channelId: 1, sequence: 1, senderTick: 1, bytes: List.filled(1100, 7));
    final protected = await const UdpPacketProtector().encrypt(
        UdpPacket(
            protocolMinor: 1,
            type: UdpPacketType.realtime,
            reliableGeneration: 1,
            channelId: 1,
            sequence: BigInt.one,
            sessionId: List.filled(16, 1),
            payload: realtime.encode()),
        List.filled(32, 2));
    expect(protected.encode(), hasLength(1176));
  });

  test('RT-013 UDP sidecar sender encodes realtime only', () async {
    final sender = UdpRealtimeSender(
      sessionId: List.filled(16, 1),
      reliableGeneration: 1,
      trafficKey: List.filled(32, 2),
    );
    final protected = await sender.encode(
      RealtimeDatagram(channelId: 7, sequence: 3, senderTick: 5, bytes: [9]),
    );
    expect(protected.type, UdpPacketType.realtime);
    final clear = await const UdpPacketProtector().decrypt(
      UdpPacket.decode(protected.encode()),
      List.filled(32, 2),
    );
    expect(RealtimeDatagram.decode(clear.payload).bytes, [9]);
  });

  test('modified UDP packet fails AEAD authentication', () async {
    final protected = await const UdpPacketProtector().encrypt(
        UdpPacket(
            protocolMinor: 1,
            type: UdpPacketType.probe,
            reliableGeneration: 1,
            channelId: 1,
            sequence: BigInt.one,
            sessionId: List.filled(16, 1),
            payload: List.filled(16, 2)),
        List.filled(32, 3));
    final modified = protected.encode()..[udpPacketHeaderLength] ^= 1;
    await expectLater(
        const UdpPacketProtector()
            .decrypt(UdpPacket.decode(modified), List.filled(32, 3)),
        throwsA(isA<LpcException>()));
  });

  test('UDP replay window accepts reordering but rejects replay and old data',
      () {
    final window = UdpReplayWindow();
    expect(window.accept(BigInt.from(10)), isTrue);
    expect(window.accept(BigInt.from(12)), isTrue);
    expect(window.accept(BigInt.from(11)), isTrue);
    expect(window.accept(BigInt.from(11)), isFalse);
    expect(window.accept(BigInt.from(300)), isTrue);
    expect(window.accept(BigInt.from(44)), isFalse);
  });

  test('RT-015 later UDP sequence does not make delayed reliable frame stale',
      () {
    final udp = UdpReplayWindow();
    final reliable = ReceiveSequenceWindow();
    expect(udp.accept(BigInt.from(900)), isTrue);
    expect(reliable.accept(1), SequenceAcceptance.accepted);
  });

  test('RT-016 UDP packet loss creates no reliable sequence gap', () {
    final udp = UdpReplayWindow();
    final reliable = ReceiveSequenceWindow();
    expect(udp.accept(BigInt.one), isTrue);
    expect(udp.accept(BigInt.from(3)), isTrue); // UDP packet 2 was lost.
    expect(reliable.accept(1), SequenceAcceptance.accepted);
    expect(reliable.accept(2), SequenceAcceptance.accepted);
  });

  test('RT-017 in-window UDP reordering leaves reliable replay state intact',
      () {
    final udp = UdpReplayWindow();
    final reliable = ReceiveSequenceWindow();
    expect(udp.accept(BigInt.from(10)), isTrue);
    expect(udp.accept(BigInt.from(12)), isTrue);
    expect(udp.accept(BigInt.from(11)), isTrue);
    expect(reliable.accept(1), SequenceAcceptance.accepted);
    expect(reliable.accept(1), SequenceAcceptance.replay);
  });

  test('UDP packet header preserves the UINT64_MAX sequence value', () {
    final packet = UdpPacket(
        protocolMinor: 1,
        type: UdpPacketType.probe,
        reliableGeneration: 1,
        channelId: 1,
        sequence: BigInt.parse('18446744073709551615'),
        sessionId: List.filled(16, 0),
        payload: List.filled(16, 0),
        tag: List.filled(16, 0));
    expect(UdpPacket.decode(packet.encode()).sequence, packet.sequence);
  });

  test('UDP packet sequence begins at one and reserves UINT64_MAX', () {
    final allocator = UdpPacketSequenceAllocator();
    expect(allocator.allocate(), BigInt.one);
  });

  test('RT-026 UDP packet sequence requires a fresh sidecar before UINT64_MAX',
      () {
    final maximum = BigInt.parse('18446744073709551615');
    final allocator =
        UdpPacketSequenceAllocator(initialNext: maximum - BigInt.one);
    expect(allocator.allocate(), maximum - BigInt.one);
    expect(
      allocator.allocate,
      throwsA(
        isA<LpcException>().having(
          (error) => error.code,
          'code',
          LpcErrorCode.resourceExhausted,
        ),
      ),
    );
  });

  test('RT-022 UDP and realtime datagram sequences advance independently', () {
    final udp = UdpPacketSequenceAllocator();
    final realtime = GroupRealtimeSequenceAllocator();
    final destination = PeerId(List<int>.filled(16, 4));
    expect(udp.allocate(), BigInt.one);
    expect(realtime.allocate(destination, 8), 1);
    expect(udp.allocate(), BigInt.from(2));
    expect(realtime.allocate(destination, 8), 2);
  });
}

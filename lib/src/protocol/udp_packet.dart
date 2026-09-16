import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../types.dart';
import 'application_payload.dart';
import 'frame.dart';

const int udpPacketHeaderLength = 44;
const int udpPacketTagLength = 16;
const int maxUdpPacketLength = 1232;
final BigInt _maxUint64 = BigInt.parse('18446744073709551615');
final BigInt _uint32Mask = BigInt.from(0xffffffff);

enum UdpPacketType {
  realtime(0x01),
  probe(0x02),
  probeAck(0x03);

  const UdpPacketType(this.value);
  final int value;
  static UdpPacketType fromValue(int value) =>
      UdpPacketType.values.firstWhere((type) => type.value == value,
          orElse: () => throw const LpcException(
              LpcErrorCode.protocolMismatch, 'invalid UDP packet type'));
}

class UdpPacket {
  UdpPacket(
      {required this.protocolMinor,
      required this.type,
      required this.reliableGeneration,
      required this.channelId,
      required this.sequence,
      required List<int> sessionId,
      required List<int> payload,
      List<int>? tag})
      : sessionId = Uint8List.fromList(sessionId),
        payload = Uint8List.fromList(payload),
        tag = tag == null ? null : Uint8List.fromList(tag) {
    if (protocolMinor < 0 ||
        protocolMinor > 255 ||
        reliableGeneration < 1 ||
        reliableGeneration > 0xffffffff ||
        channelId < 1 ||
        channelId > 0xffffffff ||
        sequence < BigInt.one ||
        sequence > _maxUint64 ||
        sessionId.length != 16 ||
        payload.length >
            maxUdpPacketLength - udpPacketHeaderLength - udpPacketTagLength ||
        (this.tag != null && this.tag!.length != udpPacketTagLength)) {
      throw ArgumentError('invalid UDP packet');
    }
  }

  final int protocolMinor, reliableGeneration, channelId;
  final BigInt sequence;
  final UdpPacketType type;
  final Uint8List sessionId, payload;
  final Uint8List? tag;
  bool get encrypted => tag != null;

  Uint8List header() {
    final data = ByteData(udpPacketHeaderLength);
    final raw = data.buffer.asUint8List();
    raw.setRange(0, 4, [0x4c, 0x50, 0x55, 0x31]); // LPU1
    data.setUint8(4, protocolMajor);
    data.setUint8(5, protocolMinor);
    data.setUint8(6, type.value);
    data.setUint32(8, reliableGeneration);
    data.setUint32(12, channelId);
    _setUint64(data, 16, sequence);
    raw.setRange(24, 40, sessionId);
    data.setUint16(40, payload.length);
    return raw;
  }

  Uint8List encode() {
    if (!encrypted) throw ArgumentError('UDP packet is not encrypted');
    return Uint8List.fromList([...header(), ...payload, ...tag!]);
  }

  static UdpPacket decode(List<int> bytes) {
    if (bytes.length < udpPacketHeaderLength + udpPacketTagLength ||
        bytes.length > maxUdpPacketLength) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final raw = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(raw);
    if (raw[0] != 0x4c ||
        raw[1] != 0x50 ||
        raw[2] != 0x55 ||
        raw[3] != 0x31 ||
        data.getUint8(4) != protocolMajor ||
        data.getUint8(7) != 0 ||
        data.getUint16(42) != 0 ||
        raw.length !=
            udpPacketHeaderLength + data.getUint16(40) + udpPacketTagLength) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    return UdpPacket(
        protocolMinor: data.getUint8(5),
        type: UdpPacketType.fromValue(data.getUint8(6)),
        reliableGeneration: data.getUint32(8),
        channelId: data.getUint32(12),
        sequence: _getUint64(data, 16),
        sessionId: raw.sublist(24, 40),
        payload: raw.sublist(44, raw.length - udpPacketTagLength),
        tag: raw.sublist(raw.length - udpPacketTagLength));
  }
}

Uint8List udpPacketNonce(int generation, BigInt sequence) {
  final data = ByteData(12)..setUint32(0, generation);
  _setUint64(data, 4, sequence);
  return data.buffer.asUint8List();
}

BigInt _getUint64(ByteData data, int offset) =>
    (BigInt.from(data.getUint32(offset)) << 32) |
    BigInt.from(data.getUint32(offset + 4));

void _setUint64(ByteData data, int offset, BigInt value) {
  data.setUint32(offset, (value >> 32).toInt());
  data.setUint32(offset + 4, (value & _uint32Mask).toInt());
}

class UdpPacketProtector {
  const UdpPacketProtector();
  static final _cipher = Chacha20.poly1305Aead();

  Future<UdpPacket> encrypt(UdpPacket plain, List<int> key) async {
    if (plain.encrypted || key.length != 32)
      throw ArgumentError('invalid UDP encrypt');
    final box = await _cipher.encrypt(plain.payload,
        secretKey: SecretKey(key),
        nonce: udpPacketNonce(plain.reliableGeneration, plain.sequence),
        aad: plain.header());
    return UdpPacket(
        protocolMinor: plain.protocolMinor,
        type: plain.type,
        reliableGeneration: plain.reliableGeneration,
        channelId: plain.channelId,
        sequence: plain.sequence,
        sessionId: plain.sessionId,
        payload: box.cipherText,
        tag: box.mac.bytes);
  }

  Future<UdpPacket> decrypt(UdpPacket packet, List<int> key) async {
    if (!packet.encrypted || key.length != 32)
      throw ArgumentError('invalid UDP decrypt');
    try {
      final clear = await _cipher.decrypt(
          SecretBox(packet.payload,
              nonce: udpPacketNonce(packet.reliableGeneration, packet.sequence),
              mac: Mac(packet.tag!)),
          secretKey: SecretKey(key),
          aad: packet.header());
      return UdpPacket(
          protocolMinor: packet.protocolMinor,
          type: packet.type,
          reliableGeneration: packet.reliableGeneration,
          channelId: packet.channelId,
          sequence: packet.sequence,
          sessionId: packet.sessionId,
          payload: clear);
    } on SecretBoxAuthenticationError {
      throw const LpcException(LpcErrorCode.udpAuthenticationFailed);
    }
  }
}

class UdpPacketSequenceAllocator {
  UdpPacketSequenceAllocator({BigInt? initialNext})
      : _next = initialNext ?? BigInt.one {
    if (_next < BigInt.one || _next > _maxUint64) {
      throw ArgumentError.value(initialNext, 'initialNext');
    }
  }

  BigInt _next;
  BigInt allocate() {
    if (_next >= _maxUint64) {
      throw const LpcException(
          LpcErrorCode.resourceExhausted, 'fresh UDP sidecar required');
    }
    final sequence = _next;
    _next += BigInt.one;
    return sequence;
  }
}

/// UDP sidecars carry only `REALTIME_LATEST` payloads. Reliable DATA has no
/// encoder here and therefore remains on the active LPC transport.
class UdpRealtimeSender {
  UdpRealtimeSender({
    required List<int> sessionId,
    required this.reliableGeneration,
    required List<int> trafficKey,
    UdpPacketSequenceAllocator? sequenceAllocator,
  })  : _sessionId = Uint8List.fromList(sessionId),
        _trafficKey = Uint8List.fromList(trafficKey),
        _sequenceAllocator = sequenceAllocator ?? UdpPacketSequenceAllocator() {
    if (_sessionId.length != 16 ||
        _trafficKey.length != 32 ||
        reliableGeneration < 1 ||
        reliableGeneration > 0xffffffff) {
      throw ArgumentError('invalid UDP realtime sender');
    }
  }

  final Uint8List _sessionId, _trafficKey;
  final int reliableGeneration;
  final UdpPacketSequenceAllocator _sequenceAllocator;

  Future<UdpPacket> encode(RealtimeDatagram datagram) =>
      const UdpPacketProtector().encrypt(
        UdpPacket(
          protocolMinor: protocolMinor,
          type: UdpPacketType.realtime,
          reliableGeneration: reliableGeneration,
          channelId: datagram.channelId,
          sequence: _sequenceAllocator.allocate(),
          sessionId: _sessionId,
          payload: datagram.encode(),
        ),
        _trafficKey,
      );
}

/// Section 22.4.7's per-direction 256-packet replay window. Call this only
/// after UDP AEAD authentication succeeds.
class UdpReplayWindow {
  BigInt? _greatest;
  final Set<BigInt> _received = {};

  bool accept(BigInt sequence) {
    if (sequence < BigInt.one) return false;
    final greatest = _greatest;
    if (greatest == null) {
      _greatest = sequence;
      _received.add(sequence);
      return true;
    }
    if (sequence > greatest) {
      _greatest = sequence;
      _received.removeWhere((value) => value < sequence - BigInt.from(255));
      _received.add(sequence);
      return true;
    }
    if (sequence < greatest - BigInt.from(255) ||
        _received.contains(sequence)) {
      return false;
    }
    _received.add(sequence);
    return true;
  }
}

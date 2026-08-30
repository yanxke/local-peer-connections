import 'dart:typed_data';
import '../identity.dart';
import '../types.dart';

enum HelloTopology { pointToPoint, explicitStar, autoGroup }

enum HelloRole { host, client, peer }

enum HandshakeTrustMode { knownPeer, sas, psk32, tofu }

class HelloPayload {
  HelloPayload(
      {required this.peerId,
      required List<int> identityPublicKey,
      required List<int> ephemeralPublicKey,
      required List<int> connectionNonce,
      required this.peerCapabilities,
      this.minMinor = 1,
      this.maxMinor = 1,
      this.topology = HelloTopology.autoGroup,
      this.role = HelloRole.peer,
      this.trustMode = HandshakeTrustMode.tofu,
      List<int> applicationMetadata = const [],
      this.keepaliveIntervalMs = 2000,
      this.maxApplicationMessageBytes = 1048576})
      : identityPublicKey = Uint8List.fromList(identityPublicKey),
        ephemeralPublicKey = Uint8List.fromList(ephemeralPublicKey),
        connectionNonce = Uint8List.fromList(connectionNonce),
        applicationMetadata = Uint8List.fromList(applicationMetadata) {
    if (this.identityPublicKey.length != 32 ||
        this.ephemeralPublicKey.length != 32 ||
        this.connectionNonce.length != 16 ||
        this.applicationMetadata.length > 31 ||
        minMinor > maxMinor ||
        keepaliveIntervalMs < 1000 ||
        keepaliveIntervalMs > 10000 ||
        peerCapabilities & ~0x1ff != 0)
      throw const LpcException(LpcErrorCode.protocolMismatch, 'invalid HELLO');
  }
  final PeerId peerId;
  final Uint8List identityPublicKey,
      ephemeralPublicKey,
      connectionNonce,
      applicationMetadata;
  final int peerCapabilities,
      minMinor,
      maxMinor,
      keepaliveIntervalMs,
      maxApplicationMessageBytes;
  final HelloTopology topology;
  final HelloRole role;
  final HandshakeTrustMode trustMode;
  Uint8List encode() {
    final h = ByteData(112);
    h.buffer.asUint8List().setRange(0, 16, peerId.bytes);
    h.buffer.asUint8List().setRange(16, 48, identityPublicKey);
    h.buffer.asUint8List().setRange(48, 80, ephemeralPublicKey);
    h.buffer.asUint8List().setRange(80, 96, connectionNonce);
    h.setUint32(96, peerCapabilities);
    h.setUint8(100, minMinor);
    h.setUint8(101, maxMinor);
    h.setUint8(102, topology.index + 1);
    h.setUint8(103, role.index + 1);
    h.setUint8(104, trustMode.index + 1);
    h.setUint8(105, applicationMetadata.length);
    h.setUint16(106, keepaliveIntervalMs);
    h.setUint32(108, maxApplicationMessageBytes);
    return Uint8List.fromList(
        [...h.buffer.asUint8List(), ...applicationMetadata]);
  }

  static Future<HelloPayload> decode(List<int> input) async {
    if (input.length < 112)
      throw const LpcException(LpcErrorCode.protocolMismatch, 'short HELLO');
    final raw = Uint8List.fromList(input);
    final h = ByteData.sublistView(raw);
    if (input.length != 112 + h.getUint8(105))
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid HELLO length');
    final value = HelloPayload(
        peerId: PeerId(raw.sublist(0, 16)),
        identityPublicKey: raw.sublist(16, 48),
        ephemeralPublicKey: raw.sublist(48, 80),
        connectionNonce: raw.sublist(80, 96),
        peerCapabilities: h.getUint32(96),
        minMinor: h.getUint8(100),
        maxMinor: h.getUint8(101),
        topology: _value(HelloTopology.values, h.getUint8(102)),
        role: _value(HelloRole.values, h.getUint8(103)),
        trustMode: _value(HandshakeTrustMode.values, h.getUint8(104)),
        applicationMetadata: raw.sublist(112),
        keepaliveIntervalMs: h.getUint16(106),
        maxApplicationMessageBytes: h.getUint32(108));
    if (await PeerIdentity.peerIdForPublicKey(value.identityPublicKey) !=
        value.peerId)
      throw const LpcException(
          LpcErrorCode.authenticationFailed, 'HELLO PeerId mismatch');
    return value;
  }

  static T _value<T>(List<T> values, int wire) {
    if (wire < 1 || wire > values.length)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    return values[wire - 1];
  }
}

int? negotiateMinor(
    {required int localMin,
    required int localMax,
    required int remoteMin,
    required int remoteMax,
    int localMajor = 1,
    int remoteMajor = 1}) {
  if (localMajor != 1 || remoteMajor != 1) return null;
  final negotiated = localMax < remoteMax ? localMax : remoteMax;
  return negotiated >= (localMin > remoteMin ? localMin : remoteMin)
      ? negotiated
      : null;
}

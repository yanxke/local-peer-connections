import 'dart:typed_data';

import '../types.dart';

// An encrypted LPC frame adds 78 bytes (62-byte header + 16-byte tag).
// MESH_FRAME adds 48 payload-header bytes, so 3900 leaves the encoded outer
// frame at 4026 bytes, safely below LPC's 4096-byte control-frame ceiling.
const int meshRelayChunkBytes = 3900;

/// Friend-relay wire records. These only travel inside an already
/// authenticated, encrypted direct PeerConnection; the target still performs
/// its own end-to-end HELLO/AUTH before the virtual link becomes READY.
class MeshAdvert {
  MeshAdvert(this.generation, Iterable<PeerId> neighbors)
    : neighbors = List<PeerId>.unmodifiable(neighbors) {
    if (generation < 0 ||
        generation > 0xffffffff ||
        this.neighbors.length > 64) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    for (var index = 1; index < this.neighbors.length; index++) {
      if (_compareIds(this.neighbors[index - 1], this.neighbors[index]) >= 0) {
        throw const LpcException(LpcErrorCode.protocolMismatch);
      }
    }
  }

  final int generation;
  final List<PeerId> neighbors;

  Uint8List encode() {
    final bytes = Uint8List(6 + 16 * neighbors.length);
    final view = ByteData.sublistView(bytes);
    view.setUint8(0, 1);
    view.setUint8(1, neighbors.length);
    view.setUint32(2, generation);
    for (var index = 0; index < neighbors.length; index++) {
      bytes.setRange(6 + 16 * index, 22 + 16 * index, neighbors[index].bytes);
    }
    return bytes;
  }

  static MeshAdvert decode(List<int> raw) {
    if (raw.length < 6 ||
        raw[0] != 1 ||
        raw[1] > 64 ||
        raw.length != 6 + raw[1] * 16) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final bytes = Uint8List.fromList(raw);
    final view = ByteData.sublistView(bytes);
    return MeshAdvert(
      view.getUint32(2),
      List<PeerId>.generate(
        raw[1],
        (index) => PeerId(bytes.sublist(6 + index * 16, 22 + index * 16)),
      ),
    );
  }
}

enum MeshFrameKind { chunk, receipt }

class MeshFrame {
  MeshFrame({
    required this.kind,
    required this.source,
    required this.destination,
    required this.frameId,
    required this.chunkIndex,
    required this.chunkCount,
    required List<int> bytes,
  }) : bytes = Uint8List.fromList(bytes) {
    if (source == destination ||
        frameId < 0 ||
        frameId > 0x7fffffffffffffff ||
        this.bytes.length > meshRelayChunkBytes ||
        (kind == MeshFrameKind.receipt &&
            (chunkIndex != 0 || chunkCount != 0 || this.bytes.isNotEmpty)) ||
        (kind == MeshFrameKind.chunk &&
            (chunkCount < 1 ||
                chunkCount > 5 ||
                chunkIndex < 0 ||
                chunkIndex >= chunkCount))) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
  }

  final MeshFrameKind kind;
  final PeerId source, destination;
  final int frameId, chunkIndex, chunkCount;
  final Uint8List bytes;

  Uint8List encode() {
    final output = Uint8List(48 + bytes.length);
    final view = ByteData.sublistView(output);
    view.setUint8(0, 1);
    view.setUint8(1, kind == MeshFrameKind.chunk ? 1 : 2);
    output.setRange(2, 18, source.bytes);
    output.setRange(18, 34, destination.bytes);
    view.setUint64(34, frameId);
    view.setUint16(42, chunkIndex);
    view.setUint16(44, chunkCount);
    view.setUint16(46, bytes.length);
    output.setRange(48, output.length, bytes);
    return output;
  }

  static MeshFrame decode(List<int> raw) {
    if (raw.length < 48 || raw[0] != 1 || raw[1] < 1 || raw[1] > 2) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final data = Uint8List.fromList(raw);
    final view = ByteData.sublistView(data);
    final length = view.getUint16(46);
    if (length > meshRelayChunkBytes || data.length != 48 + length) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    return MeshFrame(
      kind: raw[1] == 1 ? MeshFrameKind.chunk : MeshFrameKind.receipt,
      source: PeerId(data.sublist(2, 18)),
      destination: PeerId(data.sublist(18, 34)),
      frameId: view.getUint64(34),
      chunkIndex: view.getUint16(42),
      chunkCount: view.getUint16(44),
      bytes: data.sublist(48),
    );
  }
}

int _compareIds(PeerId left, PeerId right) {
  for (var index = 0; index < 16; index++) {
    final comparison = left.bytes[index].compareTo(right.bytes[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

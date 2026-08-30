import 'dart:typed_data';
import '../types.dart';

/// GATT envelope from Section 12: uint32 sequence, uint16 length, bytes.
class GattFragment {
  GattFragment(this.sequence, List<int> bytes)
      : bytes = Uint8List.fromList(bytes) {
    if (this.bytes.length > 0xffff)
      throw ArgumentError.value(bytes.length, 'bytes.length');
  }
  final int sequence;
  final Uint8List bytes;
  Uint8List encode() {
    final data = ByteData(6)
      ..setUint32(0, sequence)
      ..setUint16(4, bytes.length);
    return Uint8List.fromList([...data.buffer.asUint8List(), ...bytes]);
  }

  static GattFragment decode(List<int> encoded) {
    if (encoded.length < 6)
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'short GATT fragment');
    final data = ByteData.sublistView(Uint8List.fromList(encoded));
    final length = data.getUint16(4);
    if (encoded.length != length + 6)
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid GATT fragment length');
    return GattFragment(data.getUint32(0), encoded.sublist(6));
  }
}

class GattFragmenter {
  const GattFragmenter(this.maxPayloadSize)
      : assert(maxPayloadSize > 0 && maxPayloadSize <= 0xffff);
  final int maxPayloadSize;
  List<GattFragment> split(List<int> frame, {required int firstSequence}) {
    final result = <GattFragment>[];
    for (var offset = 0; offset < frame.length; offset += maxPayloadSize) {
      result.add(GattFragment(
          firstSequence + result.length,
          frame.sublist(
              offset, (offset + maxPayloadSize).clamp(0, frame.length))));
    }
    return result;
  }
}

/// Reassembles ordered fragments without narrowing the uint32 fragment sequence.
class GattReassembler {
  GattReassembler({this.maxBufferedBytes = 1024 * 1024});
  final int maxBufferedBytes;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int? _nextSequence;
  Uint8List? add(GattFragment fragment) {
    if (_nextSequence != null && fragment.sequence != _nextSequence) {
      _buffer.clear();
      _nextSequence = null;
      throw const LpcException(LpcErrorCode.protocolMismatch,
          'non-contiguous GATT fragment sequence');
    }
    if (_buffer.length + fragment.bytes.length > maxBufferedBytes) {
      _buffer.clear();
      _nextSequence = null;
      throw const LpcException(LpcErrorCode.resourceExhausted);
    }
    _buffer.add(fragment.bytes);
    _nextSequence = (fragment.sequence + 1) & 0xffffffff;
    // GATT carries exactly one LPC frame in this baseline implementation.
    final current = _buffer.toBytes();
    if (current.length < 62) return null;
    final payloadLength = ByteData.sublistView(current).getUint32(10);
    final expectedPlain = 62 + payloadLength;
    final expectedEncrypted = expectedPlain + 16;
    if (current.length != expectedPlain && current.length != expectedEncrypted)
      return null;
    _buffer.clear();
    _nextSequence = null;
    return current;
  }
}

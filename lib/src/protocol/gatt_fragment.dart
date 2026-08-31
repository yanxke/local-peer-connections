import 'dart:typed_data';

import '../types.dart';

/// Section 12 GATT envelope: uint32 sequence, flags, uint16 length, bytes.
class GattFragment {
  GattFragment(this.sequence, List<int> bytes,
      {this.start = false, this.end = false})
      : bytes = Uint8List.fromList(bytes) {
    if (sequence < 0 || sequence > 0xffffffff || this.bytes.length > 0xffff) {
      throw ArgumentError('invalid GATT fragment');
    }
  }

  final int sequence;
  final bool start, end;
  final Uint8List bytes;
  int get flags => (start ? 1 : 0) | (end ? 2 : 0);

  Uint8List encode() {
    final data = ByteData(7)
      ..setUint32(0, sequence)
      ..setUint8(4, flags)
      ..setUint16(5, bytes.length);
    return Uint8List.fromList([...data.buffer.asUint8List(), ...bytes]);
  }

  static GattFragment decode(List<int> encoded) {
    if (encoded.length < 7) {
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'short GATT fragment');
    }
    final data = ByteData.sublistView(Uint8List.fromList(encoded));
    final flags = data.getUint8(4);
    final length = data.getUint16(5);
    if (flags & ~3 != 0 || encoded.length != length + 7) {
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid GATT fragment');
    }
    return GattFragment(data.getUint32(0), encoded.sublist(7),
        start: flags & 1 != 0, end: flags & 2 != 0);
  }
}

class GattFragmenter {
  /// [platformSafeWriteSize] includes the complete GATT envelope.
  GattFragmenter(int platformSafeWriteSize)
      : maxPayloadSize = _payloadSize(platformSafeWriteSize);

  final int maxPayloadSize;

  static int _payloadSize(int platformSafeWriteSize) {
    if (platformSafeWriteSize <= 7) {
      throw const LpcException(LpcErrorCode.resourceExhausted,
          'GATT safe write size cannot carry a fragment');
    }
    final payload = platformSafeWriteSize - 7;
    return payload > 512 ? 512 : payload;
  }

  /// V1 resets the fragment sequence to zero for every LPC frame.
  List<GattFragment> split(List<int> frame) {
    if (frame.isEmpty) {
      throw ArgumentError.value(frame, 'frame', 'LPC frame is not empty');
    }
    final fragments = <GattFragment>[];
    for (var offset = 0; offset < frame.length; offset += maxPayloadSize) {
      final sequence = fragments.length;
      fragments.add(GattFragment(
          sequence,
          frame.sublist(
              offset, (offset + maxPayloadSize).clamp(0, frame.length)),
          start: sequence == 0,
          end: offset + maxPayloadSize >= frame.length));
    }
    return fragments;
  }
}

/// Reassembles one non-interleaved Section 12 LPC frame. The owner calls
/// [discardExpired] from its backend timer; no incomplete frame survives two
/// seconds without fragment progress.
class GattReassembler {
  GattReassembler(
      {this.maxBufferedBytes = 16384 + 62 + 16, this.timeoutMs = 2000})
      : assert(maxBufferedBytes > 0),
        assert(timeoutMs > 0);

  final int maxBufferedBytes;
  final int timeoutMs;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int? _nextSequence;
  int? _lastProgressMs;

  bool discardExpired(int nowMs) {
    if (_lastProgressMs == null || nowMs - _lastProgressMs! < timeoutMs) {
      return false;
    }
    _reset();
    return true;
  }

  Uint8List? add(GattFragment fragment, {required int nowMs}) {
    discardExpired(nowMs);
    if (fragment.start) {
      if (_nextSequence != null || fragment.sequence != 0) {
        _reset();
        throw const LpcException(
            LpcErrorCode.protocolMismatch, 'invalid GATT fragment start');
      }
    } else if (_nextSequence == null || fragment.sequence != _nextSequence) {
      _reset();
      throw const LpcException(LpcErrorCode.protocolMismatch,
          'non-contiguous GATT fragment sequence');
    }
    if (_buffer.length + fragment.bytes.length > maxBufferedBytes) {
      _reset();
      throw const LpcException(LpcErrorCode.resourceExhausted);
    }
    _buffer.add(fragment.bytes);
    _nextSequence = fragment.sequence + 1;
    _lastProgressMs = nowMs;
    if (!fragment.end) return null;
    final completed = _buffer.toBytes();
    _reset();
    return completed;
  }

  void _reset() {
    _buffer.clear();
    _nextSequence = null;
    _lastProgressMs = null;
  }
}

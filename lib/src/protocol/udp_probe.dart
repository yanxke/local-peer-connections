import 'dart:math';
import 'dart:typed_data';

import '../types.dart';

/// Section 22.4.9 UDP-sidecar activation state.
enum UdpProbeState { probing, active, failed }

/// Timer-free UDP probe state machine. Its owner calls [poll] from its
/// serialized monotonic timer and encrypts/submits returned payloads as the
/// corresponding LPU1 UDP packet type.
class UdpProbeController {
  UdpProbeController({required int nowMs, List<int> Function()? nextToken})
      : _startedAtMs = nowMs,
        _nextProbeAtMs = nowMs,
        _token = Uint8List.fromList((nextToken ?? _secureToken)()) {
    if (_token.length != 16)
      throw ArgumentError('probe token must be 16 bytes');
  }

  static const int intervalMs = 250;
  static const int timeoutMs = 2000;
  static const int maxTransmissions = 8;

  final int _startedAtMs;
  Uint8List _token;
  int _nextProbeAtMs;
  int _transmissions = 0;
  bool _receivedRemoteProbe = false;
  bool _receivedOwnProbeAck = false;
  UdpProbeState _state = UdpProbeState.probing;

  UdpProbeState get state => _state;
  List<int> get token => Uint8List.fromList(_token);
  bool get receivedRemoteProbe => _receivedRemoteProbe;
  bool get receivedOwnProbeAck => _receivedOwnProbeAck;

  UdpProbeDecision poll(int nowMs) {
    if (_state != UdpProbeState.probing) return const UdpProbeNoAction();
    if (nowMs - _startedAtMs >= timeoutMs) {
      _state = UdpProbeState.failed;
      return const UdpProbeFailed();
    }
    if (nowMs < _nextProbeAtMs || _transmissions >= maxTransmissions) {
      return const UdpProbeNoAction();
    }
    _transmissions++;
    _nextProbeAtMs += intervalMs;
    return UdpProbeSend(_token);
  }

  /// Handles a payload only after the outer LPU1 packet has passed AEAD,
  /// replay, and endpoint-binding validation. The returned payload must be
  /// sent immediately as UDP_PROBE_ACK.
  UdpProbeDecision receiveProbe(List<int> payload) {
    if (payload.length != 16) {
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'UDP_PROBE payload must be 16 bytes');
    }
    if (_state == UdpProbeState.failed) return const UdpProbeNoAction();
    if (_state == UdpProbeState.probing) {
      _receivedRemoteProbe = true;
      _activateIfValidated();
    }
    return UdpProbeAck(Uint8List.fromList(payload));
  }

  /// Handles a UDP_PROBE_ACK payload after outer packet validation.
  void receiveProbeAck(List<int> payload) {
    if (payload.length != 16) {
      throw const LpcException(LpcErrorCode.protocolMismatch,
          'UDP_PROBE_ACK payload must be 16 bytes');
    }
    if (_state == UdpProbeState.probing && _same(payload, _token)) {
      _receivedOwnProbeAck = true;
      _activateIfValidated();
    }
  }

  void _activateIfValidated() {
    if (_receivedRemoteProbe && _receivedOwnProbeAck) {
      _state = UdpProbeState.active;
    }
  }

  static bool _same(List<int> a, List<int> b) {
    var difference = a.length ^ b.length;
    for (var i = 0; i < a.length && i < b.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  static List<int> _secureToken() =>
      List<int>.generate(16, (_) => Random.secure().nextInt(256));
}

sealed class UdpProbeDecision {
  const UdpProbeDecision();
}

class UdpProbeNoAction extends UdpProbeDecision {
  const UdpProbeNoAction();
}

class UdpProbeSend extends UdpProbeDecision {
  UdpProbeSend(List<int> payload) : payload = Uint8List.fromList(payload);
  final Uint8List payload;
}

class UdpProbeAck extends UdpProbeDecision {
  UdpProbeAck(List<int> payload) : payload = Uint8List.fromList(payload);
  final Uint8List payload;
}

class UdpProbeFailed extends UdpProbeDecision {
  const UdpProbeFailed();
}

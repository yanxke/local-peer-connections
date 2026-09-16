import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../types.dart';
import 'auth.dart';
import 'control_payload.dart';
import 'frame.dart';
import 'handshake.dart';
import 'handshake_frames.dart';
import 'handshake_orchestrator.dart';
import 'hello.dart';

enum HandshakeExchangeState {
  created,
  helloSent,
  helloExchanged,
  authSent,
  awaitingSasConfirmation,
  authenticated,
  closed,
}

/// Serialized portable Section 16 plaintext handshake controller. Backends
/// transport its complete LPC frames; this class owns no BLE/GATT types and
/// deliberately stops before the encrypted READY exchange.
class HandshakeExchange {
  HandshakeExchange(
      {required List<int> serviceUuid,
      required this.localHello,
      required this.localIdentityKeyPair,
      required this.localEphemeralKeyPair,
      this.knownPeerPolicy,
      this.tofuStore,
      this.psk32})
      : _serviceUuid = Uint8List.fromList(serviceUuid) {
    if (_serviceUuid.length != 16) {
      throw ArgumentError.value(serviceUuid, 'serviceUuid');
    }
  }

  final Uint8List _serviceUuid;
  final HelloPayload localHello;
  final SimpleKeyPair localIdentityKeyPair;
  final SimpleKeyPair localEphemeralKeyPair;
  final KnownPeerPolicy? knownPeerPolicy;
  final TofuIdentityStore? tofuStore;
  final List<int>? psk32;
  HandshakeExchangeState _state = HandshakeExchangeState.created;
  Uint8List? _remoteHelloBytes;
  HelloPayload? _remoteHello;
  HandshakeResult? _result;

  HandshakeExchangeState get state => _state;
  HelloPayload? get remoteHello => _remoteHello;
  HandshakeResult? get result => _result;

  LpcFrame createHello() {
    _require(HandshakeExchangeState.created);
    _state = HandshakeExchangeState.helloSent;
    return plaintextHelloFrame(localHello);
  }

  /// Processes a plaintext HELLO, AUTH, or valid pre-key mismatch ERROR. A
  /// returned frame is the required local pre-key mismatch ERROR and must be
  /// sent before the backend closes the physical connection.
  Future<LpcFrame?> receivePlaintext(LpcFrame frame) async {
    if (frame.type == FrameType.error) {
      if (_state == HandshakeExchangeState.created ||
          _state == HandshakeExchangeState.helloSent) {
        parsePreKeyProtocolMismatchError(frame);
        _state = HandshakeExchangeState.closed;
        return null;
      }
      throw const LpcException(LpcErrorCode.protocolMismatch,
          'plaintext ERROR after HELLO negotiation');
    }
    if (frame.type == FrameType.hello) {
      if (_state != HandshakeExchangeState.created &&
          _state != HandshakeExchangeState.helloSent) {
        throw const LpcException(
            LpcErrorCode.protocolMismatch, 'unexpected plaintext HELLO');
      }
      final remote = await parsePlaintextHelloFrame(frame);
      final negotiated = negotiateMinor(
          localMin: localHello.minMinor,
          localMax: localHello.maxMinor,
          remoteMin: remote.minMinor,
          remoteMax: remote.maxMinor);
      if (negotiated != 0) {
        _state = HandshakeExchangeState.closed;
        return preKeyProtocolMismatchError(senderMaxMinor: localHello.maxMinor);
      }
      if (remote.trustMode != localHello.trustMode) {
        _state = HandshakeExchangeState.closed;
        throw const LpcException(
            LpcErrorCode.authenticationFailed, 'mismatched HELLO trust mode');
      }
      _remoteHello = remote;
      _remoteHelloBytes = Uint8List.fromList(frame.payload);
      _state = HandshakeExchangeState.helloExchanged;
      return null;
    }
    if (frame.type == FrameType.auth) {
      if (_state != HandshakeExchangeState.helloExchanged &&
          _state != HandshakeExchangeState.authSent) {
        throw const LpcException(
            LpcErrorCode.protocolMismatch, 'AUTH before HELLO exchange');
      }
      final auth = parsePlaintextAuthFrame(frame);
      final value = await verifyHandshake(
          serviceUuid: _serviceUuid,
          localHelloBytes: localHello.encode(),
          remoteHelloBytes: _remoteHelloBytes!,
          localIdentityKeyPair: localIdentityKeyPair,
          localEphemeralKeyPair: localEphemeralKeyPair,
          remoteAuthPayload: auth,
          knownPeerPolicy: knownPeerPolicy,
          tofuStore: tofuStore,
          psk32: psk32);
      _result = value;
      _state = value.sas == null
          ? HandshakeExchangeState.authenticated
          : HandshakeExchangeState.awaitingSasConfirmation;
      return null;
    }
    throw const LpcException(
        LpcErrorCode.protocolMismatch, 'unexpected plaintext frame type');
  }

  Future<LpcFrame> createAuth() async {
    if (_state != HandshakeExchangeState.helloExchanged) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'AUTH requires complete HELLO exchange');
    }
    final transcript = await handshakeTranscript(
        serviceUuid: _serviceUuid,
        localHello: localHello.encode(),
        remoteHello: _remoteHelloBytes!);
    _state = HandshakeExchangeState.authSent;
    return plaintextAuthFrame(
        senderMaxMinor: localHello.maxMinor,
        authPayload: await createAuthPayload(
            identityKeyPair: localIdentityKeyPair, transcript: transcript));
  }

  /// Pairwise SAS must be an explicit local decision before READY can begin.
  void confirmSas(bool accepted) {
    _require(HandshakeExchangeState.awaitingSasConfirmation);
    if (!accepted) {
      _state = HandshakeExchangeState.closed;
      throw const LpcException(
          LpcErrorCode.authenticationFailed, 'SAS rejected');
    }
    _state = HandshakeExchangeState.authenticated;
  }

  void _require(HandshakeExchangeState expected) {
    if (_state != expected) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'unexpected handshake state');
    }
  }
}

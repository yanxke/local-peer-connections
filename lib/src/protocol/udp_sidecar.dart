import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../types.dart';

enum UdpAddressFamily {
  ipv4(0x04),
  ipv6(0x06);

  const UdpAddressFamily(this.value);
  final int value;
  static UdpAddressFamily fromValue(int value) =>
      UdpAddressFamily.values.firstWhere((family) => family.value == value,
          orElse: () => throw const LpcException(
              LpcErrorCode.protocolMismatch, 'invalid UDP address family'));
}

/// Section 22.4.1: only the lexicographically smaller PeerId may initiate an
/// automatic UDP_OFFER. Capability/policy checks remain the caller's job.
bool mayAutomaticallyInitiateUdp(PeerId localPeerId, PeerId remotePeerId) {
  for (var i = 0; i < localPeerId.bytes.length; i++) {
    if (localPeerId.bytes[i] != remotePeerId.bytes[i]) {
      return localPeerId.bytes[i] < remotePeerId.bytes[i];
    }
  }
  return false;
}

/// An IP endpoint negotiated inside UDP_OFFER or UDP_ACCEPT. It is transport
/// addressing only and never protocol peer identity.
class UdpEndpoint {
  UdpEndpoint({
    required this.addressFamily,
    required this.port,
    required List<int> address,
  }) : address = Uint8List.fromList(address) {
    _validateEndpoint(1, addressFamily, port, this.address);
  }

  final UdpAddressFamily addressFamily;
  final int port;
  final Uint8List address;

  bool sameAs(UdpEndpoint other) {
    if (addressFamily != other.addressFamily || port != other.port) {
      return false;
    }
    var difference = 0;
    for (var i = 0; i < address.length; i++) {
      difference |= address[i] ^ other.address[i];
    }
    return difference == 0;
  }
}

/// Section 22.4.12 endpoint binding. Call [validateAuthenticatedSource] only
/// after LPU1 AEAD verification; a source mismatch invalidates this sidecar,
/// never the reliable PeerConnection or its transport generation.
class UdpEndpointBinding {
  UdpEndpointBinding({required this.channelId, required this.remoteEndpoint}) {
    if (channelId < 1 || channelId > 0xffffffff) {
      throw ArgumentError.value(channelId, 'channelId');
    }
  }

  final int channelId;
  final UdpEndpoint remoteEndpoint;
  bool _valid = true;
  bool get valid => _valid;

  UdpEndpointDecision validateAuthenticatedSource(UdpEndpoint source) {
    if (!_valid) return const UdpEndpointDiscard();
    if (remoteEndpoint.sameAs(source)) return const UdpEndpointAccept();
    _valid = false;
    return UdpEndpointChanged(
        UdpClose(channelId, UdpCloseReason.networkChanged));
  }
}

sealed class UdpEndpointDecision {
  const UdpEndpointDecision();
}

class UdpEndpointAccept extends UdpEndpointDecision {
  const UdpEndpointAccept();
}

/// Discard without emitting another close after the sidecar is already invalid.
class UdpEndpointDiscard extends UdpEndpointDecision {
  const UdpEndpointDiscard();
}

/// The owner sends [close] over the existing reliable connection when it is
/// available, then applies its policy for establishing a fresh sidecar.
class UdpEndpointChanged extends UdpEndpointDecision {
  const UdpEndpointChanged(this.close);
  final UdpClose close;
}

/// Section 22.4.2 lifecycle states for the optional realtime sidecar. These
/// never replace the independently-owned reliable PeerConnection state.
enum UdpRealtimeState {
  disabled,
  offered,
  negotiating,
  probing,
  active,
  failed,
  closed
}

/// Required owner action after a sidecar-only invalidation. The owner sends
/// [close] over its existing reliable connection when non-null, routes
/// realtime over that reliable connection in the meantime, and starts a fresh
/// offer only when policy continues to allow it.
class UdpSidecarRecoveryAction {
  const UdpSidecarRecoveryAction({
    required this.fallbackToReliable,
    required this.requiresFreshSidecar,
    this.close,
  });

  final bool fallbackToReliable;
  final bool requiresFreshSidecar;
  final UdpClose? close;
}

/// Owns the active endpoint binding and its reliable-generation association.
///
/// Call [authenticatedSource] only after LPU1 authentication. A changed source
/// or reliable RESUME invalidates this sidecar alone; the caller deliberately
/// receives an action rather than a request to mutate its PeerConnection.
class UdpSidecarLifecycle {
  UdpSidecarLifecycle.active({
    required List<int> sessionId,
    required int reliableGeneration,
    required UdpEndpointBinding binding,
  })  : _sessionId = Uint8List.fromList(sessionId),
        _reliableGeneration = reliableGeneration,
        _binding = binding {
    if (_sessionId.length != 16 || reliableGeneration < 1) {
      throw ArgumentError('invalid active UDP sidecar');
    }
  }

  final Uint8List _sessionId;
  int _reliableGeneration;
  UdpEndpointBinding? _binding;
  UdpRealtimeState _state = UdpRealtimeState.active;

  UdpRealtimeState get state => _state;
  int get reliableGeneration => _reliableGeneration;
  List<int> get sessionId => Uint8List.fromList(_sessionId);
  bool get usesReliableFallback => _state != UdpRealtimeState.active;

  UdpSidecarRecoveryAction? authenticatedSource(UdpEndpoint source) {
    final binding = _binding;
    if (_state != UdpRealtimeState.active || binding == null) return null;
    final decision = binding.validateAuthenticatedSource(source);
    if (decision is! UdpEndpointChanged) return null;
    _binding = null;
    _state = UdpRealtimeState.failed;
    return UdpSidecarRecoveryAction(
      fallbackToReliable: true,
      requiresFreshSidecar: true,
      close: decision.close,
    );
  }

  /// Section 22.4.11: successful RESUME destroys old UDP state and requires a
  /// new offer/accept/probe exchange. No UDP_CLOSE is sent for an old
  /// generation because it is already invalid.
  UdpSidecarRecoveryAction? reliableResumed(int newReliableGeneration) {
    if (newReliableGeneration < 1) {
      throw ArgumentError.value(newReliableGeneration, 'newReliableGeneration');
    }
    if (newReliableGeneration == _reliableGeneration) return null;
    _reliableGeneration = newReliableGeneration;
    _binding = null;
    _state = UdpRealtimeState.failed;
    return const UdpSidecarRecoveryAction(
      fallbackToReliable: true,
      requiresFreshSidecar: true,
    );
  }
}

class UdpOffer {
  UdpOffer(
      {required this.channelId,
      required this.addressFamily,
      required this.port,
      required List<int> address,
      required List<int> offerNonce})
      : address = Uint8List.fromList(address),
        offerNonce = Uint8List.fromList(offerNonce) {
    _validateEndpoint(channelId, addressFamily, port, this.address);
    if (this.offerNonce.length != 16)
      throw ArgumentError('invalid offer nonce');
  }

  final int channelId, port;
  final UdpAddressFamily addressFamily;
  final Uint8List address, offerNonce;

  Uint8List encode() {
    final data = ByteData(40);
    final raw = data.buffer.asUint8List();
    data.setUint32(0, channelId);
    data.setUint8(4, addressFamily.value);
    data.setUint16(6, port);
    raw.setRange(8, 24, address);
    raw.setRange(24, 40, offerNonce);
    return raw;
  }

  static UdpOffer decode(List<int> bytes) {
    if (bytes.length != 40)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final raw = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(raw);
    if (data.getUint8(5) != 0)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    return UdpOffer(
        channelId: data.getUint32(0),
        addressFamily: UdpAddressFamily.fromValue(data.getUint8(4)),
        port: data.getUint16(6),
        address: raw.sublist(8, 24),
        offerNonce: raw.sublist(24, 40));
  }
}

class UdpAccept {
  UdpAccept(
      {required this.channelId,
      required this.addressFamily,
      required this.port,
      required List<int> address,
      required List<int> offerNonce,
      required List<int> acceptNonce})
      : address = Uint8List.fromList(address),
        offerNonce = Uint8List.fromList(offerNonce),
        acceptNonce = Uint8List.fromList(acceptNonce) {
    _validateEndpoint(channelId, addressFamily, port, this.address);
    if (this.offerNonce.length != 16 || this.acceptNonce.length != 16) {
      throw ArgumentError('invalid UDP accept nonce');
    }
  }

  final int channelId, port;
  final UdpAddressFamily addressFamily;
  final Uint8List address, offerNonce, acceptNonce;

  Uint8List encode() {
    final data = ByteData(56);
    final raw = data.buffer.asUint8List();
    data.setUint32(0, channelId);
    data.setUint8(4, addressFamily.value);
    data.setUint16(6, port);
    raw.setRange(8, 24, address);
    raw.setRange(24, 40, offerNonce);
    raw.setRange(40, 56, acceptNonce);
    return raw;
  }

  static UdpAccept decode(List<int> bytes) {
    if (bytes.length != 56)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final raw = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(raw);
    if (data.getUint8(5) != 0)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    return UdpAccept(
        channelId: data.getUint32(0),
        addressFamily: UdpAddressFamily.fromValue(data.getUint8(4)),
        port: data.getUint16(6),
        address: raw.sublist(8, 24),
        offerNonce: raw.sublist(24, 40),
        acceptNonce: raw.sublist(40, 56));
  }
}

enum UdpCloseReason {
  localRequest(0x0001),
  probeTimeout(0x0002),
  networkChanged(0x0003),
  rekeyRequired(0x0004),
  protocolError(0x0005);

  const UdpCloseReason(this.value);
  final int value;
  static UdpCloseReason fromValue(int value) =>
      UdpCloseReason.values.firstWhere((reason) => reason.value == value,
          orElse: () => throw const LpcException(
              LpcErrorCode.protocolMismatch, 'invalid UDP_CLOSE reason'));
}

class UdpClose {
  UdpClose(this.channelId, this.reason) {
    if (channelId < 1 || channelId > 0xffffffff) {
      throw ArgumentError.value(channelId, 'channelId');
    }
  }
  final int channelId;
  final UdpCloseReason reason;
  Uint8List encode() {
    final data = ByteData(6)
      ..setUint32(0, channelId)
      ..setUint16(4, reason.value);
    return data.buffer.asUint8List();
  }

  static UdpClose decode(List<int> bytes) {
    if (bytes.length != 6)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    return UdpClose(
        data.getUint32(0), UdpCloseReason.fromValue(data.getUint16(4)));
  }
}

class UdpSidecarKeys {
  UdpSidecarKeys(this.root, this.key0To1, this.key1To0);
  final Uint8List root, key0To1, key1To0;
}

Future<UdpSidecarKeys> deriveUdpSidecarKeys(
    {required List<int> sessionRootKey,
    required List<int> sessionId,
    required int reliableGeneration,
    required int channelId,
    required List<int> offerNonce,
    required List<int> acceptNonce}) async {
  if (sessionRootKey.length != 32 ||
      sessionId.length != 16 ||
      reliableGeneration < 1 ||
      reliableGeneration > 0xffffffff ||
      channelId < 1 ||
      channelId > 0xffffffff ||
      offerNonce.length != 16 ||
      acceptNonce.length != 16) {
    throw ArgumentError('invalid UDP sidecar input');
  }
  final generation = ByteData(4)..setUint32(0, reliableGeneration);
  final channel = ByteData(4)..setUint32(0, channelId);
  final rootKey = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
      .deriveKey(secretKey: SecretKey(sessionRootKey), nonce: [
    ...offerNonce,
    ...acceptNonce
  ], info: [
    ...ascii.encode('LPC1-udp-sidecar'),
    ...sessionId,
    ...generation.buffer.asUint8List(),
    ...channel.buffer.asUint8List(),
  ]);
  final root = Uint8List.fromList(await rootKey.extractBytes());
  Future<Uint8List> directional(String info) async {
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(root), nonce: const [], info: ascii.encode(info));
    return Uint8List.fromList(await key.extractBytes());
  }

  return UdpSidecarKeys(root, await directional('LPC1-udp-key-0-to-1'),
      await directional('LPC1-udp-key-1-to-0'));
}

void _validateEndpoint(
    int channelId, UdpAddressFamily family, int port, List<int> address) {
  if (channelId < 1 ||
      channelId > 0xffffffff ||
      port < 0 ||
      port > 0xffff ||
      address.length != 16 ||
      (family == UdpAddressFamily.ipv4 &&
          address.sublist(4).any((byte) => byte != 0))) {
    throw const LpcException(
        LpcErrorCode.protocolMismatch, 'invalid UDP endpoint');
  }
}

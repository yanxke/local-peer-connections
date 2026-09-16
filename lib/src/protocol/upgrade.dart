import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../types.dart';

/// Section 28's on-wire reliable transport identifiers.
enum UpgradeTransport {
  bleGatt(0x01),
  bleL2cap(0x02),
  wifiLanTcp(0x03);

  const UpgradeTransport(this.value);
  final int value;

  static UpgradeTransport fromValue(int value) => UpgradeTransport.values
      .firstWhere((transport) => transport.value == value,
          orElse: () => throw const LpcException(
              LpcErrorCode.protocolMismatch, 'invalid upgrade transport'));
}

/// Section 29.1's 19-byte TCP listener address carried inside an encrypted
/// UPGRADE_OFFER or UPGRADE_ACCEPT.
class LanTcpEndpoint {
  LanTcpEndpoint(
      {required this.addressFamily,
      required this.port,
      required List<int> address})
      : address = Uint8List.fromList(address) {
    if ((addressFamily != 4 && addressFamily != 6) ||
        port < 0 ||
        port > 0xffff ||
        this.address.length != 16 ||
        (addressFamily == 4 &&
            this.address.sublist(4).any((byte) => byte != 0))) {
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid LAN TCP endpoint');
    }
  }

  final int addressFamily, port;
  final Uint8List address;

  Uint8List encode() {
    final data = ByteData(19);
    data.setUint8(0, addressFamily);
    data.setUint16(1, port);
    data.buffer.asUint8List().setRange(3, 19, address);
    return data.buffer.asUint8List();
  }

  static LanTcpEndpoint decode(List<int> bytes) {
    if (bytes.length != 19) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final raw = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(raw);
    return LanTcpEndpoint(
        addressFamily: data.getUint8(0),
        port: data.getUint16(1),
        address: raw.sublist(3, 19));
  }
}

/// Section 30's encrypted two-byte big-endian L2CAP PSM offer/accept data.
class L2capPsm {
  L2capPsm(this.value) {
    if (value < 0 || value > 0xffff) {
      throw ArgumentError.value(value, 'value');
    }
  }
  final int value;

  Uint8List encode() {
    final data = ByteData(2)..setUint16(0, value);
    return data.buffer.asUint8List();
  }

  static L2capPsm decode(List<int> bytes) {
    if (bytes.length != 2) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    return L2capPsm(
        ByteData.sublistView(Uint8List.fromList(bytes)).getUint16(0));
  }
}

/// Section 28.1's encrypted UPGRADE_OFFER payload.
class UpgradeOffer {
  UpgradeOffer(
      {required List<int> upgradeId,
      required this.targetTransport,
      required this.targetGeneration,
      required List<int> offerData})
      : upgradeId = Uint8List.fromList(upgradeId),
        offerData = Uint8List.fromList(offerData) {
    _validateProposal(
        upgradeId: this.upgradeId,
        targetGeneration: targetGeneration,
        data: this.offerData,
        name: 'UPGRADE_OFFER');
  }

  final Uint8List upgradeId, offerData;
  final UpgradeTransport targetTransport;
  final int targetGeneration;

  Uint8List encode() => _encodeProposal(
      upgradeId: upgradeId,
      transport: targetTransport,
      generation: targetGeneration,
      data: offerData);

  static UpgradeOffer decode(List<int> bytes) {
    final proposal = _decodeProposal(bytes, 'UPGRADE_OFFER');
    return UpgradeOffer(
        upgradeId: proposal.upgradeId,
        targetTransport: proposal.transport,
        targetGeneration: proposal.generation,
        offerData: proposal.data);
  }
}

/// Section 28.2's encrypted UPGRADE_ACCEPT payload. Its frozen field offsets
/// intentionally mirror UPGRADE_OFFER, including the three zero reserved
/// bytes, so independent implementations encode identical bytes.
class UpgradeAccept {
  UpgradeAccept(
      {required List<int> upgradeId,
      required this.targetTransport,
      required this.targetGeneration,
      required List<int> acceptData})
      : upgradeId = Uint8List.fromList(upgradeId),
        acceptData = Uint8List.fromList(acceptData) {
    _validateProposal(
        upgradeId: this.upgradeId,
        targetGeneration: targetGeneration,
        data: this.acceptData,
        name: 'UPGRADE_ACCEPT');
  }

  final Uint8List upgradeId, acceptData;
  final UpgradeTransport targetTransport;
  final int targetGeneration;

  Uint8List encode() => _encodeProposal(
      upgradeId: upgradeId,
      transport: targetTransport,
      generation: targetGeneration,
      data: acceptData);

  static UpgradeAccept decode(List<int> bytes) {
    final proposal = _decodeProposal(bytes, 'UPGRADE_ACCEPT');
    return UpgradeAccept(
        upgradeId: proposal.upgradeId,
        targetTransport: proposal.transport,
        targetGeneration: proposal.generation,
        acceptData: proposal.data);
  }
}

/// Section 28.2's encrypted UPGRADE_REJECT payload (18 bytes).
class UpgradeReject {
  UpgradeReject({required List<int> upgradeId, required this.errorCode})
      : upgradeId = Uint8List.fromList(upgradeId) {
    if (this.upgradeId.length != 16) {
      throw ArgumentError.value(upgradeId, 'upgradeId');
    }
  }

  final Uint8List upgradeId;
  final LpcErrorCode errorCode;

  Uint8List encode() {
    final bytes = ByteData(18);
    bytes.buffer.asUint8List().setRange(0, 16, upgradeId);
    bytes.setUint16(16, errorCode.value);
    return bytes.buffer.asUint8List();
  }

  static UpgradeReject decode(List<int> bytes) {
    if (bytes.length != 18) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final raw = Uint8List.fromList(bytes);
    final value = ByteData.sublistView(raw).getUint16(16);
    final code = LpcErrorCode.values.where((code) => code.value == value);
    if (code.isEmpty) throw const LpcException(LpcErrorCode.protocolMismatch);
    return UpgradeReject(upgradeId: raw.sublist(0, 16), errorCode: code.single);
  }
}

class _UpgradeProposal {
  const _UpgradeProposal(
      this.upgradeId, this.transport, this.generation, this.data);
  final Uint8List upgradeId, data;
  final UpgradeTransport transport;
  final int generation;
}

void _validateProposal(
    {required List<int> upgradeId,
    required int targetGeneration,
    required List<int> data,
    required String name}) {
  if (upgradeId.length != 16 || targetGeneration < 1 || data.length > 0xffff) {
    throw ArgumentError('invalid $name');
  }
}

Uint8List _encodeProposal(
    {required List<int> upgradeId,
    required UpgradeTransport transport,
    required int generation,
    required List<int> data}) {
  final bytes = ByteData(26);
  final raw = bytes.buffer.asUint8List();
  raw.setRange(0, 16, upgradeId);
  bytes.setUint8(16, transport.value);
  bytes.setUint32(20, generation);
  bytes.setUint16(24, data.length);
  return Uint8List.fromList([...raw, ...data]);
}

_UpgradeProposal _decodeProposal(List<int> bytes, String name) {
  if (bytes.length < 26)
    throw const LpcException(LpcErrorCode.protocolMismatch);
  final raw = Uint8List.fromList(bytes);
  final data = ByteData.sublistView(raw);
  if (raw.sublist(17, 20).any((value) => value != 0) ||
      data.getUint32(20) < 1 ||
      bytes.length != 26 + data.getUint16(24)) {
    throw const LpcException(LpcErrorCode.protocolMismatch);
  }
  final proposal = _UpgradeProposal(
      raw.sublist(0, 16),
      UpgradeTransport.fromValue(data.getUint8(16)),
      data.getUint32(20),
      raw.sublist(26));
  _validateProposal(
      upgradeId: proposal.upgradeId,
      targetGeneration: proposal.generation,
      data: proposal.data,
      name: name);
  return proposal;
}

/// Section 28's single-upgrade lifecycle. Physical candidate connection and
/// actual RESUME I/O remain the owner's responsibility; this guard exposes the
/// only permitted state consequences for the two failure phases.
enum UpgradeState {
  idle,
  offered,
  accepted,
  connectingCandidate,
  bindingCandidate,
  switchPending,
  active,
  failed,
}

enum UpgradeFailureAction { retainOldTransport, secureResumeFallback }

class UpgradeLifecycle {
  UpgradeLifecycle(
      {required this.activeTransport, required this.currentGeneration}) {
    if (currentGeneration < 1) {
      throw ArgumentError.value(currentGeneration, 'currentGeneration');
    }
  }

  UpgradeTransport activeTransport;
  int currentGeneration;
  UpgradeState _state = UpgradeState.idle;
  UpgradeTransport? _candidateTransport;
  int? _targetGeneration;
  bool _localBindSent = false;
  bool _remoteBindVerified = false;
  bool _remoteBindAckReceived = false;

  UpgradeState get state => _state;
  UpgradeTransport? get candidateTransport => _candidateTransport;
  int? get targetGeneration => _targetGeneration;
  bool get candidateBound =>
      _localBindSent && _remoteBindVerified && _remoteBindAckReceived;

  void offer(UpgradeTransport target, {required int targetGeneration}) {
    _require(UpgradeState.idle);
    if (target == activeTransport ||
        targetGeneration != currentGeneration + 1) {
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid upgrade target generation');
    }
    _candidateTransport = target;
    _targetGeneration = targetGeneration;
    _state = UpgradeState.offered;
  }

  void accept() {
    _require(UpgradeState.offered);
    _state = UpgradeState.accepted;
  }

  void candidateConnecting() {
    _require(UpgradeState.accepted);
    _state = UpgradeState.connectingCandidate;
  }

  void candidateOpened() {
    _require(UpgradeState.connectingCandidate);
    _state = UpgradeState.bindingCandidate;
  }

  void localBindSent() {
    _require(UpgradeState.bindingCandidate);
    _localBindSent = true;
  }

  void remoteBindVerified() {
    _require(UpgradeState.bindingCandidate);
    _remoteBindVerified = true;
  }

  void remoteBindAckReceived() {
    _require(UpgradeState.bindingCandidate);
    _remoteBindAckReceived = true;
  }

  /// Called after the initiator receives SWITCH_ACK, or after the receiver
  /// validates a bound candidate and sends SWITCH_ACK on the old transport.
  void switchAcknowledged() {
    _require(UpgradeState.bindingCandidate);
    if (!candidateBound) {
      throw const LpcException(
          LpcErrorCode.channelBindingFailed, 'candidate is not bound');
    }
    _state = UpgradeState.switchPending;
  }

  /// Commits the one-way Section 28.5 transition to the candidate generation.
  void switchActivated() {
    _require(UpgradeState.switchPending);
    activeTransport = _candidateTransport!;
    currentGeneration = _targetGeneration!;
    _state = UpgradeState.active;
  }

  /// Section 28.6: no generation change and the old active transport remains
  /// usable until a valid SWITCH_ACK has occurred.
  UpgradeFailureAction failBeforeSwitch() {
    if (_state == UpgradeState.idle ||
        _state == UpgradeState.failed ||
        _state == UpgradeState.switchPending ||
        _state == UpgradeState.active) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'switch has already begun');
    }
    _state = UpgradeState.failed;
    return UpgradeFailureAction.retainOldTransport;
  }

  /// Section 28.7: old generation rollback is forbidden after switching.
  UpgradeFailureAction activeTransportFailed() {
    _require(UpgradeState.active);
    _state = UpgradeState.failed;
    return UpgradeFailureAction.secureResumeFallback;
  }

  void _require(UpgradeState expected) {
    if (_state != expected) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'unexpected upgrade state');
    }
  }
}

/// Section 28.4 candidate-channel binding payload (72 bytes).
class UpgradeBind {
  UpgradeBind(
      {required List<int> upgradeId,
      required List<int> sessionId,
      required this.targetTransport,
      required this.targetGeneration,
      required List<int> bindingProof})
      : upgradeId = Uint8List.fromList(upgradeId),
        sessionId = Uint8List.fromList(sessionId),
        bindingProof = Uint8List.fromList(bindingProof) {
    if (this.upgradeId.length != 16 ||
        this.sessionId.length != 16 ||
        this.bindingProof.length != 32 ||
        targetGeneration < 1) {
      throw ArgumentError('invalid UPGRADE_BIND');
    }
  }

  final Uint8List upgradeId, sessionId, bindingProof;
  final UpgradeTransport targetTransport;
  final int targetGeneration;

  Uint8List encode() {
    final bytes = ByteData(72);
    final raw = bytes.buffer.asUint8List();
    raw.setRange(0, 16, upgradeId);
    raw.setRange(16, 32, sessionId);
    bytes.setUint8(32, targetTransport.value);
    bytes.setUint32(36, targetGeneration);
    raw.setRange(40, 72, bindingProof);
    return raw;
  }

  static UpgradeBind decode(List<int> bytes) {
    if (bytes.length != 72) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final raw = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(raw);
    if (raw.sublist(33, 36).any((value) => value != 0) ||
        data.getUint32(36) < 1) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    return UpgradeBind(
        upgradeId: raw.sublist(0, 16),
        sessionId: raw.sublist(16, 32),
        targetTransport: UpgradeTransport.fromValue(data.getUint8(32)),
        targetGeneration: data.getUint32(36),
        bindingProof: raw.sublist(40, 72));
  }
}

Future<Uint8List> upgradeBindProof(
    {required List<int> resumeSecret,
    required List<int> upgradeId,
    required List<int> sessionId,
    required UpgradeTransport targetTransport,
    required int targetGeneration}) async {
  if (resumeSecret.length != 32 ||
      upgradeId.length != 16 ||
      sessionId.length != 16 ||
      targetGeneration < 1) {
    throw ArgumentError('invalid upgrade binding input');
  }
  final generation = ByteData(4)..setUint32(0, targetGeneration);
  final mac = await Hmac.sha256().calculateMac([
    ...ascii.encode('LPC1-upgrade-bind'),
    ...upgradeId,
    ...sessionId,
    targetTransport.value,
    ...generation.buffer.asUint8List(),
  ], secretKey: SecretKey(resumeSecret));
  return Uint8List.fromList(mac.bytes);
}

Future<void> verifyUpgradeBindProof(
    {required List<int> resumeSecret, required UpgradeBind bind}) async {
  final expected = await upgradeBindProof(
      resumeSecret: resumeSecret,
      upgradeId: bind.upgradeId,
      sessionId: bind.sessionId,
      targetTransport: bind.targetTransport,
      targetGeneration: bind.targetGeneration);
  if (!_same(expected, bind.bindingProof)) {
    throw const LpcException(
        LpcErrorCode.channelBindingFailed, 'invalid UPGRADE_BIND proof');
  }
}

/// Section 28.4 candidate-channel binding acknowledgment (20 bytes).
class UpgradeBindAck {
  UpgradeBindAck({required List<int> upgradeId, required this.targetGeneration})
      : upgradeId = Uint8List.fromList(upgradeId) {
    if (this.upgradeId.length != 16 || targetGeneration < 1) {
      throw ArgumentError('invalid UPGRADE_BIND_ACK');
    }
  }

  final Uint8List upgradeId;
  final int targetGeneration;

  Uint8List encode() {
    final bytes = ByteData(20);
    bytes.buffer.asUint8List().setRange(0, 16, upgradeId);
    bytes.setUint32(16, targetGeneration);
    return bytes.buffer.asUint8List();
  }

  static UpgradeBindAck decode(List<int> bytes) {
    if (bytes.length != 20) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final raw = Uint8List.fromList(bytes);
    final generation = ByteData.sublistView(raw).getUint32(16);
    if (generation < 1) throw const LpcException(LpcErrorCode.protocolMismatch);
    return UpgradeBindAck(
        upgradeId: raw.sublist(0, 16), targetGeneration: generation);
  }
}

/// The identical Section 28.5 SWITCH_COMMIT and SWITCH_ACK payload (21 bytes).
class UpgradeSwitch {
  UpgradeSwitch(
      {required List<int> upgradeId,
      required this.targetGeneration,
      required this.targetTransport})
      : upgradeId = Uint8List.fromList(upgradeId) {
    if (this.upgradeId.length != 16 || targetGeneration < 1) {
      throw ArgumentError('invalid SWITCH payload');
    }
  }

  final Uint8List upgradeId;
  final int targetGeneration;
  final UpgradeTransport targetTransport;

  Uint8List encode() {
    final bytes = ByteData(21);
    bytes.buffer.asUint8List().setRange(0, 16, upgradeId);
    bytes.setUint32(16, targetGeneration);
    bytes.setUint8(20, targetTransport.value);
    return bytes.buffer.asUint8List();
  }

  static UpgradeSwitch decode(List<int> bytes) {
    if (bytes.length != 21) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final raw = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(raw);
    final generation = data.getUint32(16);
    if (generation < 1) throw const LpcException(LpcErrorCode.protocolMismatch);
    return UpgradeSwitch(
        upgradeId: raw.sublist(0, 16),
        targetGeneration: generation,
        targetTransport: UpgradeTransport.fromValue(data.getUint8(20)));
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var result = 0;
  for (var i = 0; i < a.length; i++) {
    result |= a[i] ^ b[i];
  }
  return result == 0;
}

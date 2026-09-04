import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'backend.dart';
import 'gatt_backend_connection.dart';
import 'group.dart';
import 'identity_store.dart';
import 'platform_ble_backend.dart';
import 'protocol/capabilities.dart';
import 'protocol/connection_rank.dart';
import 'protocol/application_payload.dart';
import 'protocol/ack.dart';
import 'protocol/auth.dart';
import 'protocol/control_payload.dart';
import 'protocol/frame.dart';
import 'protocol/handshake_connection.dart';
import 'protocol/handshake_exchange.dart';
import 'protocol/handshake_orchestrator.dart';
import 'protocol/hello.dart';
import 'protocol/peer_state.dart';
import 'protocol/reconnect.dart';
import 'protocol/resume.dart';
import 'protocol/group_reliable.dart';
import 'protocol/group_realtime.dart';
import 'protocol/group_routing_send.dart';
import 'protocol/group_member_router.dart';
import 'protocol/group_destination_router.dart';
import 'protocol/group_coordinator_router.dart';
import 'protocol/group_routing_validation.dart';
import 'protocol/coordinator_relay_controller.dart';
import 'protocol/group_relay.dart';
import 'protocol/group_signaling.dart';
import 'protocol/group_merge.dart';
import 'protocol/membership.dart';
import 'peer_connection_core.dart';
import 'types.dart';

enum RuntimeState { created, initializing, ready, failed, closing, closed }

sealed class RuntimeEvent {
  const RuntimeEvent(this.monotonicTimestampMs);
  final int monotonicTimestampMs;
}

class KnownPeerProbeStarted extends RuntimeEvent {
  const KnownPeerProbeStarted(
      super.monotonicTimestampMs, this.discoveryEndpointId);
  final String discoveryEndpointId;
}

/// Terminal outcome of a bounded automatic nearby-known-peer probe.
class KnownPeerProbeFailed extends RuntimeEvent {
  const KnownPeerProbeFailed(
      super.monotonicTimestampMs, this.discoveryEndpointId, this.error);
  final String discoveryEndpointId;
  final LpcException error;
}

class UnknownPeerIdentified extends RuntimeEvent {
  const UnknownPeerIdentified(super.monotonicTimestampMs, this.connection,
      {this.discoveryEndpointId});

  /// The authenticated connection used for this bounded automatic probe.
  /// It is emitted before the Runtime releases its negative known-peer probe
  /// ownership, so applications can inspect authenticated HELLO metadata.
  /// Receiving this event does not grant application relationship authority.
  final PeerConnection connection;
  PeerId get peerId => connection.peerId;
  final String? discoveryEndpointId;
}

class KnownPeerConnected extends RuntimeEvent {
  const KnownPeerConnected(super.monotonicTimestampMs, this.connection,
      {this.discoveryEndpointId});
  final PeerConnection connection;
  final String? discoveryEndpointId;
}

sealed class DiscoveryEvent {
  const DiscoveryEvent();
}

class DiscoveryStopped extends DiscoveryEvent {
  const DiscoveryStopped();
}

sealed class HostSessionEvent {
  const HostSessionEvent();
}

class HostSessionClosed extends HostSessionEvent {
  const HostSessionClosed();
}

class HostPeerConnected extends HostSessionEvent {
  const HostPeerConnected(this.connection, {this.discoveryEndpointId});
  final PeerConnection connection;

  /// Ephemeral platform endpoint that produced this inbound connection.
  /// It is presentation-only and must not be persisted as peer identity.
  final String? discoveryEndpointId;
}

/// SAS comparison required for an inbound explicit-host connection.
class HostPeerVerificationRequired extends HostSessionEvent {
  const HostPeerVerificationRequired(this.peerId, this.sas);
  final PeerId peerId;
  final String sas;
}

sealed class ConnectionAttemptEvent {
  const ConnectionAttemptEvent();
}

class ConnectionAttemptConnected extends ConnectionAttemptEvent {
  const ConnectionAttemptConnected(this.connection);
  final PeerConnection connection;
}

class ConnectionAttemptFailed extends ConnectionAttemptEvent {
  const ConnectionAttemptFailed(this.error);
  final LpcException error;
}

class ConnectionAttemptCancelled extends ConnectionAttemptEvent {
  const ConnectionAttemptCancelled();
}

/// Section 16.10's explicit human-verification request. The application must
/// compare this six-digit value on both devices before accepting it.
class PeerVerificationRequired extends ConnectionAttemptEvent {
  const PeerVerificationRequired(this.peerId, this.sas);
  final PeerId peerId;
  final String sas;
}

/// One outbound Section 33.4 physical connection attempt. Its endpoint is a
/// platform handle; [PeerConnection.peerId] becomes available only after the
/// authenticated HELLO/AUTH/READY exchange completes.
class ConnectionAttempt {
  ConnectionAttempt._(this.endpointId, this._cancel);
  final String endpointId;
  final Future<void> Function() _cancel;
  final StreamController<ConnectionAttemptEvent> _events =
      StreamController<ConnectionAttemptEvent>.broadcast(sync: true);
  bool _terminal = false;
  Future<void> Function(bool accepted)? _confirmVerification;
  Stream<ConnectionAttemptEvent> get events => _events.stream;
  void _connected(PeerConnection connection) {
    if (_terminal) return;
    _terminal = true;
    _events.add(ConnectionAttemptConnected(connection));
  }

  void _failed(LpcException error) {
    if (_terminal) return;
    _terminal = true;
    _events.add(ConnectionAttemptFailed(error));
  }

  Future<void> cancel() async {
    if (_terminal) return;
    _terminal = true;
    await _cancel();
    _events.add(const ConnectionAttemptCancelled());
  }

  /// Accepts or rejects a pending SAS comparison. It is valid only after a
  /// [PeerVerificationRequired] event and before a terminal attempt outcome.
  Future<void> confirmPeerVerification(bool accepted) async {
    if (_terminal || _confirmVerification == null) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'no peer verification is pending');
    }
    final confirm = _confirmVerification!;
    _confirmVerification = null;
    await confirm(accepted);
  }

  void _verificationRequired(
      PeerId peerId, String sas, Future<void> Function(bool) confirm) {
    if (_terminal || _confirmVerification != null) return;
    _confirmVerification = confirm;
    _events.add(PeerVerificationRequired(peerId, sas));
  }
}

class PeerMessageReceived {
  PeerMessageReceived(List<int> value, this.deliveryMode)
      : bytes = List.unmodifiable(value);
  final List<int> bytes;
  final DeliveryMode deliveryMode;
}

/// One authenticated realtime state update accepted by the Section 22
/// per-channel latest-sequence filter.
class PeerRealtimeDatagramReceived {
  PeerRealtimeDatagramReceived(this.channelId, this.senderTick, List<int> value)
      : bytes = List.unmodifiable(value);
  final int channelId, senderTick;
  final List<int> bytes;
}

/// Lifecycle events for one authenticated PeerConnection. Their timestamp is
/// sampled after the corresponding core-state mutation has committed.
sealed class PeerConnectionEvent {
  const PeerConnectionEvent(this.monotonicTimestampMs);
  final int monotonicTimestampMs;
}

class PeerReconnecting extends PeerConnectionEvent {
  const PeerReconnecting(super.monotonicTimestampMs);
}

class PeerReconnected extends PeerConnectionEvent {
  PeerReconnected(
      super.monotonicTimestampMs, List<int> sessionId, this.transport)
      : sessionId = List.unmodifiable(sessionId);
  final List<int> sessionId;
  final TransportType transport;
}

class PeerDisconnected extends PeerConnectionEvent {
  const PeerDisconnected(super.monotonicTimestampMs);
}

/// Public authenticated point-to-point connection. Group routing remains the
/// separate Section 43 owner; this class exposes the direct Section 36 path.
class PeerConnection {
  PeerConnection._(this._core,
      {required this.securityLevel,
      List<int> remoteApplicationMetadata = const [],
      void Function(PeerConnection)? onDisconnected,
      void Function(PeerConnection)? onReconnecting})
      : remoteApplicationMetadata =
            List.unmodifiable(remoteApplicationMetadata),
        _onDisconnected = onDisconnected,
        _onReconnecting = onReconnecting {
    _frames = _core.receivedFrames.listen(_onFrame);
    _connectionTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      unawaited(_core.pollKeepalive());
      unawaited(_core.pollAckTimeouts());
      unawaited(_pollRealtimeQueue());
      if (_core.state == PeerConnectionState.reconnecting &&
          !_reconnectNotified) {
        _reconnectNotified = true;
        _events.add(PeerReconnecting(_core.monotonicNowMs));
        _onReconnecting?.call(this);
      }
      if (_core.state == PeerConnectionState.ready && _reconnectNotified) {
        _reconnectNotified = false;
        _events.add(PeerReconnected(_core.monotonicNowMs, _core.sessionId,
            _core.backend.transportType));
      }
    });
  }
  final PeerConnectionCore _core;
  final SecurityLevel securityLevel;

  /// Authenticated application metadata received in the peer's HELLO.
  final List<int> remoteApplicationMetadata;
  final void Function(PeerConnection)? _onDisconnected;
  final void Function(PeerConnection)? _onReconnecting;
  late final StreamSubscription<LpcFrame> _frames;
  late final Timer _connectionTimer;
  final StreamController<PeerMessageReceived> _messages =
      StreamController<PeerMessageReceived>.broadcast(sync: true);
  final StreamController<PeerRealtimeDatagramReceived> _realtimeMessages =
      StreamController<PeerRealtimeDatagramReceived>.broadcast(sync: true);
  final StreamController<PeerConnectionEvent> _events =
      StreamController<PeerConnectionEvent>.broadcast(sync: true);
  final StreamController<LpcFrame> _groupFrames =
      StreamController<LpcFrame>.broadcast(sync: true);
  final Map<int, _QueuedRealtime> _queuedRealtime = <int, _QueuedRealtime>{};
  bool _submittingRealtime = false;
  bool _disconnected = false;
  bool _reconnectNotified = false;
  PeerId get peerId => _core.remotePeerId;
  List<int> get sessionId => List.unmodifiable(_core.sessionId);
  PeerConnectionState get state => _core.state;
  TransportType get activeTransport => _core.backend.transportType;
  Stream<PeerMessageReceived> get messages => _messages.stream;
  Stream<PeerRealtimeDatagramReceived> get realtimeMessages =>
      _realtimeMessages.stream;
  Stream<PeerConnectionEvent> get events => _events.stream;
  Stream<LpcFrame> get groupFrames => _groupFrames.stream;
  SendHandle send(List<int> bytes,
      {SendOptions options = const SendOptions()}) {
    if (_disconnected || _core.state != PeerConnectionState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    if (options.deliveryMode == DeliveryMode.realtimeLatest) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'use sendRealtime for REALTIME_LATEST');
    }
    final allocator = _core.messageIdAllocator;
    if (allocator == null) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'missing MessageId allocator');
    }
    return _core.submitReliableDataWithHandle(
        bytes: bytes,
        deliveryMode: options.deliveryMode,
        priority: options.priority,
        messageId: allocator.allocate(),
        nowMs: _core.monotonicNowMs);
  }

  RealtimeSendHandle sendRealtime(int channelId, List<int> bytes,
      {RealtimeOptions options = const RealtimeOptions()}) {
    if (_disconnected || options.expiryMs < 1) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    final datagram = _core.allocateRealtimeDatagram(
        channelId: channelId, senderTick: options.senderTick, bytes: bytes);
    final controller = RealtimeSendHandleController.queued(
        onCancel: () => _queuedRealtime.remove(channelId));
    final previous = _queuedRealtime[channelId];
    _queuedRealtime[channelId] = _QueuedRealtime(
        datagram: datagram,
        expiresAtMs: _core.monotonicNowMs + options.expiryMs,
        controller: controller);
    previous?.controller.complete(SendState.superseded);
    unawaited(_pollRealtimeQueue());
    return controller.handle;
  }

  Future<void> disconnect() async {
    if (_disconnected) return;
    _disconnected = true;
    _connectionTimer.cancel();
    for (final queued in _queuedRealtime.values) {
      queued.controller.complete(SendState.failed);
    }
    _queuedRealtime.clear();
    await _frames.cancel();
    await _core.close();
    _events.add(PeerDisconnected(_core.monotonicNowMs));
    await _messages.close();
    await _realtimeMessages.close();
    await _groupFrames.close();
    await _events.close();
    _onDisconnected?.call(this);
  }

  void _onFrame(LpcFrame frame) {
    if (frame.type == FrameType.groupReliable ||
        frame.type == FrameType.groupRealtimeDatagram ||
        frame.type == FrameType.groupDeliveryAck ||
        frame.type == FrameType.groupRelayStatus ||
        frame.type == FrameType.groupInfo ||
        frame.type == FrameType.groupMerge ||
        frame.type == FrameType.membershipSnapshot) {
      _groupFrames.add(frame);
      return;
    }
    if (frame.type == FrameType.realtimeDatagram) {
      final datagram = _core.receiveRealtime(frame);
      if (datagram != null) {
        _realtimeMessages.add(PeerRealtimeDatagramReceived(
            datagram.channelId, datagram.senderTick, datagram.bytes));
      }
      return;
    }
    if (frame.type != FrameType.data) return;
    unawaited(() async {
      try {
        final result = await _core.receiveDataFrame(frame);
        final delivered = result.delivered;
        if (delivered != null) {
          _messages.add(
              PeerMessageReceived(delivered.bytes, delivered.deliveryMode));
        }
      } on Object {
        // The core has already applied its terminal malformed-frame path.
      }
    }());
  }

  Future<void> _pollRealtimeQueue() async {
    if (_disconnected || _submittingRealtime) return;
    final nowMs = _core.monotonicNowMs;
    for (final entry in _queuedRealtime.entries.toList()) {
      if (nowMs >= entry.value.expiresAtMs) {
        _queuedRealtime.remove(entry.key);
        entry.value.controller.complete(SendState.expired);
      }
    }
    if (_queuedRealtime.isEmpty) return;
    final entry = _queuedRealtime.entries.first;
    final queued = entry.value;
    _queuedRealtime.remove(entry.key);
    _submittingRealtime = true;
    queued.controller.transmitting();
    try {
      final result = await _core.submitRealtime(queued.datagram);
      queued.controller.complete(
          result == TransportWriteState.submittedToPlatform
              ? SendState.sentToTransport
              : SendState.failed);
    } on Object {
      queued.controller.complete(SendState.failed);
    } finally {
      _submittingRealtime = false;
      if (!_disconnected) unawaited(_pollRealtimeQueue());
    }
  }
}

class _QueuedRealtime {
  const _QueuedRealtime(
      {required this.datagram,
      required this.expiresAtMs,
      required this.controller});
  final RealtimeDatagram datagram;
  final int expiresAtMs;
  final RealtimeSendHandleController controller;
}

/// Section 33.2 explicit-role host lifecycle. Peer admission and message I/O
/// are owned by the connection layer; this object owns only advertising here.
class HostSession {
  HostSession.internal({
    required this.config,
    required Future<void> Function() startAdvertising,
    required Future<void> Function() stopAdvertising,
    required Future<void> Function(HostSession, PeerConnection) releasePeer,
    required void Function(HostSession host) onClosed,
  })  : _startAdvertising = startAdvertising,
        _stopAdvertising = stopAdvertising,
        _releasePeer = releasePeer,
        _onClosed = onClosed;

  final HostConfig config;
  final Future<void> Function() _startAdvertising;
  final Future<void> Function() _stopAdvertising;
  final Future<void> Function(HostSession, PeerConnection) _releasePeer;
  final void Function(HostSession host) _onClosed;
  final StreamController<HostSessionEvent> _events =
      StreamController<HostSessionEvent>.broadcast(sync: true);
  final Map<PeerId, PeerConnection> _peers = <PeerId, PeerConnection>{};
  final Map<PeerId, ConnectionAttempt> _pendingVerifications =
      <PeerId, ConnectionAttempt>{};
  bool _advertising = false;
  bool _closed = false;

  bool get isAdvertising => _advertising;
  bool get isClosed => _closed;
  Stream<HostSessionEvent> get events => _events.stream;
  List<PeerConnection> peers() => List.unmodifiable(_peers.values.toList()
    ..sort((a, b) => _comparePeerIdBytes(a.peerId, b.peerId)));

  void _peerConnected(PeerConnection connection,
      {String? discoveryEndpointId}) {
    if (_closed) {
      unawaited(connection.disconnect());
      return;
    }
    _peers[connection.peerId] = connection;
    connection.events.listen((event) {
      if (event is PeerDisconnected &&
          identical(_peers[connection.peerId], connection)) {
        _peers.remove(connection.peerId);
      }
    });
    _events.add(HostPeerConnected(connection,
        discoveryEndpointId: discoveryEndpointId));
  }

  void _peerVerificationRequired(
      ConnectionAttempt attempt, PeerId peerId, String sas) {
    if (_closed) {
      unawaited(attempt.confirmPeerVerification(false));
      return;
    }
    _pendingVerifications[peerId] = attempt;
    attempt.events.listen((event) {
      if (event is ConnectionAttemptConnected ||
          event is ConnectionAttemptFailed ||
          event is ConnectionAttemptCancelled) {
        if (identical(_pendingVerifications[peerId], attempt)) {
          _pendingVerifications.remove(peerId);
        }
      }
    });
    _events.add(HostPeerVerificationRequired(peerId, sas));
  }

  /// Confirms the pending inbound SAS comparison for [peerId].
  Future<void> confirmPeerVerification(PeerId peerId, bool accepted) async {
    final attempt = _pendingVerifications.remove(peerId);
    if (attempt == null) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'no peer verification is pending');
    }
    await attempt.confirmPeerVerification(accepted);
  }

  /// Sends directly to one authenticated peer admitted by this explicit-role
  /// host. GroupSession routing is intentionally not used by this API.
  SendHandle send(PeerId peerId, List<int> bytes,
      {SendOptions options = const SendOptions()}) {
    if (_closed) throw const LpcException(LpcErrorCode.invalidState);
    final peer = _peers[peerId];
    if (peer == null) {
      throw const LpcException(LpcErrorCode.destinationUnavailable);
    }
    return peer.send(bytes, options: options);
  }

  BroadcastHandle broadcast(List<int> bytes,
      {SendOptions options = const SendOptions()}) {
    if (_closed) throw const LpcException(LpcErrorCode.invalidState);
    return BroadcastHandle({
      for (final peer in peers())
        peer.peerId: peer.send(bytes, options: options)
    });
  }

  /// Releases this HostSession's relationship to [peerId].  The Runtime keeps
  /// a shared connection alive when another logical owner still needs it.
  Future<void> disconnect(PeerId peerId, {String? reason}) async {
    if (_closed) throw const LpcException(LpcErrorCode.invalidState);
    final peer = _peers.remove(peerId);
    if (peer == null) return;
    await _releasePeer(this, peer);
  }

  Future<void> startAdvertising() async {
    if (_closed) throw const LpcException(LpcErrorCode.invalidState);
    if (_advertising) return;
    await _startAdvertising();
    _advertising = true;
  }

  Future<void> stopAdvertising() async {
    if (!_advertising) return;
    _advertising = false;
    await _stopAdvertising();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final attempt in _pendingVerifications.values) {
      await attempt.cancel();
    }
    _pendingVerifications.clear();
    try {
      await stopAdvertising();
      for (final peer in _peers.values.toList()) {
        await _releasePeer(this, peer);
      }
      _peers.clear();
    } finally {
      _onClosed(this);
      _events.add(const HostSessionClosed());
    }
  }
}

/// Local opaque endpoint metadata. It is deliberately not a protocol PeerId.
class DiscoveredEndpoint {
  const DiscoveredEndpoint(this.id, {required this.rssi, this.localName});
  final String id;
  final int rssi;
  final String? localName;
}

/// Section 33.3 discovery lifecycle. Scanning is owned separately from any
/// PeerConnection that may have been created from an endpoint.
class DiscoverySession {
  DiscoverySession(
      {Future<void> Function()? stopPlatformScan,
      Future<void> Function()? onStopped})
      : _stopPlatformScan = stopPlatformScan ?? _noOp,
        _onStopped = onStopped ?? _noOp;

  final Future<void> Function() _stopPlatformScan;
  final Future<void> Function() _onStopped;
  final Map<String, DiscoveredEndpoint> _endpoints = {};
  final StreamController<DiscoveryEvent> _events =
      StreamController<DiscoveryEvent>.broadcast(sync: true);
  bool _stopped = false;

  bool get isStopped => _stopped;
  Stream<DiscoveryEvent> get events => _events.stream;
  List<DiscoveredEndpoint> currentEndpoints() =>
      List.unmodifiable(_endpoints.values.toList());

  /// Backend owners record active scan results here. Once stopped, no further
  /// endpoint changes are retained or emitted.
  void recordEndpoint(DiscoveredEndpoint endpoint) {
    if (_stopped) return;
    _endpoints[endpoint.id] = endpoint;
  }

  /// Stops scanning once and emits exactly one terminal discovery event. It
  /// intentionally neither owns nor closes established PeerConnections.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      await _stopPlatformScan();
    } finally {
      await _onStopped();
      _events.add(const DiscoveryStopped());
    }
  }
}

Future<void> _noOp() async {}

int _comparePeerIdBytes(PeerId a, PeerId b) {
  for (var index = 0; index < a.bytes.length; index++) {
    final comparison = a.bytes[index].compareTo(b.bytes[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

LpcException _asLpcError(Object error) => error is LpcException
    ? error
    : LpcException(LpcErrorCode.platformError, error.toString());

KnownPeerPolicy? _knownPeerPolicyFor(
    RuntimeConfig config, HandshakeTrustMode trustMode) {
  if (trustMode != HandshakeTrustMode.knownPeer) return null;
  final peer = config.expectedPeerId;
  return peer != null
      ? ExpectExactPeer(peer)
      : AllowlistedPeers(config.allowedPeerIds);
}

void _validateTrustCredentialsFor(
    RuntimeConfig config, HandshakeTrustMode trustMode) {
  if (trustMode == HandshakeTrustMode.psk32 && config.psk32?.length != 32) {
    throw const LpcException(
        LpcErrorCode.invalidState, 'PSK_32 requires a 32-byte psk32');
  }
  if (trustMode == HandshakeTrustMode.knownPeer &&
      config.expectedPeerId == null &&
      config.allowedPeerIds.isEmpty) {
    throw const LpcException(
        LpcErrorCode.invalidState, 'KNOWN_PEER requires a peer policy');
  }
}

class _GattReconnect {
  _GattReconnect(this.peer, this.endpointId, this.schedule);
  final PeerConnection peer;
  final String endpointId;
  final ReconnectSchedule schedule;
  Timer? timer;
  bool attempting = false;
  bool closed = false;
  void dispose() {
    closed = true;
    timer?.cancel();
  }
}

/// RESUME starts with a new HELLO/AUTH candidate handshake.  It must preserve
/// the original connection's trust mode; selecting KNOWN_PEER merely because
/// a stable PeerId is now available causes a responder still using TOFU to
/// reject HELLO before RESUME can begin.
HandshakeTrustMode _resumeTrustMode(SecurityLevel securityLevel) =>
    switch (securityLevel) {
      SecurityLevel.encryptedTofu => HandshakeTrustMode.tofu,
      SecurityLevel.authenticatedKnownPeer => HandshakeTrustMode.knownPeer,
      SecurityLevel.authenticatedSas => HandshakeTrustMode.sas,
      SecurityLevel.authenticatedPsk => HandshakeTrustMode.psk32,
    };

/// Physical-link facts can change after RESUME.  Only a local GATT central
/// owns a platform endpoint that may be passed back to `connectGatt`.
class _GattLink {
  _GattLink(this.endpointId, this.localCanInitiateReconnect);
  String endpointId;
  bool localCanInitiateReconnect;
}

/// The only GroupConfig information that must be selected before HELLO on a
/// shared service advertisement (Section 32.3.1). Namespace and join scope
/// are deliberately excluded: they are authenticated GROUP_INFO data.
class _AutoGroupHandshakeProfile {
  _AutoGroupHandshakeProfile(GroupConfig config)
      : trustMode = switch (config.groupTrustMode) {
          GroupTrustMode.openTofu => HandshakeTrustMode.tofu,
          GroupTrustMode.groupPsk32 => HandshakeTrustMode.psk32,
          GroupTrustMode.pairwiseSas => HandshakeTrustMode.sas,
          GroupTrustMode.knownPeers => HandshakeTrustMode.knownPeer,
        },
        psk32 = config.groupPsk32 == null
            ? null
            : List<int>.unmodifiable(config.groupPsk32!),
        allowedPeerIds = Set<PeerId>.unmodifiable(config.allowedPeerIds);

  final HandshakeTrustMode trustMode;
  final List<int>? psk32;
  final Set<PeerId> allowedPeerIds;

  KnownPeerPolicy? get knownPeerPolicy =>
      trustMode == HandshakeTrustMode.knownPeer
          ? AllowlistedPeers(allowedPeerIds)
          : null;

  bool matches(_AutoGroupHandshakeProfile other) {
    if (trustMode != other.trustMode) return false;
    if (!_sameBytes(psk32, other.psk32)) return false;
    return allowedPeerIds.length == other.allowedPeerIds.length &&
        allowedPeerIds.containsAll(other.allowedPeerIds);
  }
}

bool _sameBytes(List<int>? a, List<int>? b) {
  if (a == null || b == null) return a == null && b == null;
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

/// Top-level owner for LPC objects. Native BLE implementations are attached via
/// the platform backend; this portable core intentionally owns no BLE types.
class NearbyRuntime {
  NearbyRuntime._(
      this.config, this.localPeerId, this._platformBleBackend, this._identity)
      : _state = RuntimeState.ready {
    _platformSubscription =
        _platformBleBackend?.events.listen(_onPlatformEvent);
  }
  final RuntimeConfig config;
  final PeerId localPeerId;
  final PlatformBleBackend? _platformBleBackend;
  final LocalIdentity? _identity;
  final TofuIdentityStore _tofuStore = TofuIdentityStore();
  StreamSubscription<PlatformBleEvent>? _platformSubscription;
  final Map<String, ConnectionAttempt> _attempts = {};
  final Map<String, PlatformGattConnectionBinding> _gattBindings = {};
  final Map<String, _GattReconnect> _gattReconnects = {};
  final Map<PeerConnection, _GattLink> _gattLinks = {};
  final Map<PeerConnection, List<int>> _connectionRanks = {};
  final Set<PeerConnection> _peers = <PeerConnection>{};
  final Set<PeerId> _directRetainedPeers = <PeerId>{};
  final Set<PeerId> _knownRetainedPeers = <PeerId>{};
  final Set<String> _automaticProbeEndpoints = <String>{};
  final Set<String> _pendingKnownPeerProbes = <String>{};
  // Discovery callbacks are intentionally noisy.  Once a currently observed
  // endpoint has completed its bounded identity classification, a duplicate
  // scan result must not create another temporary connection.  This cache is
  // endpoint-scoped and in-memory only; it is never a PeerId mapping.
  final Map<String, bool> _completedKnownPeerProbeEndpoints = <String, bool>{};
  final Map<PeerId, bool> _knownPeerCache = <PeerId, bool>{};
  final StreamController<RuntimeEvent> _events =
      StreamController<RuntimeEvent>.broadcast(sync: true);
  late String? _discoveryDisplayName = config.discoveryDisplayName;
  late List<int> _applicationMetadata =
      List<int>.unmodifiable(config.applicationMetadata);
  RuntimeState _state;
  final List<GroupSession> _groups = [];
  final Map<GroupSession, _RuntimeGroupRouteTransport> _groupRouting = {};
  final Map<GroupSession, Set<PeerConnection>> _groupPeers = {};
  _AutoGroupHandshakeProfile? _autoGroupProfile;
  final List<HostSession> _hosts = [];
  final Map<String, DiscoverySession> _discoveries = {};
  final Set<String> _startingDiscovery = {};
  final Set<HostSession> _advertisingHosts = <HostSession>{};
  final Set<GroupSession> _advertisingGroups = <GroupSession>{};
  final Set<GroupSession> _scanningGroups = <GroupSession>{};
  bool _advertisingActive = false;
  bool _discoveryActive = false;
  LocalRuntimeCapabilityBitmap? _capabilities;
  RuntimeState get state => _state;
  Stream<RuntimeEvent> get events => _events.stream;
  static Future<NearbyRuntime> create(
      {RuntimeConfig config = const RuntimeConfig(),
      PeerId? localPeerId,
      IdentityStore? identityStore,
      PlatformBleBackend? platformBleBackend}) async {
    config.validate();
    if (localPeerId != null && identityStore != null) {
      throw ArgumentError('provide localPeerId or identityStore, not both');
    }
    LocalIdentity? identity;
    if (identityStore != null || localPeerId == null) {
      identity = await LocalIdentity.load(identityStore ??
          (platformBleBackend == null
              ? InMemoryIdentityStore()
              : PlatformIdentityStore()));
    }
    final peer = localPeerId ?? identity!.peerId;
    if (identity != null && peer != identity.peerId) {
      throw const LpcException(LpcErrorCode.invalidState,
          'localPeerId does not match the persistent identity');
    }
    return NearbyRuntime._(config, peer, platformBleBackend, identity);
  }

  /// Starts a user-requested direct connection. If LPC is already performing
  /// its bounded automatic known-peer probe for the same ephemeral endpoint,
  /// the user request adopts that physical attempt instead of racing it. The
  /// completed connection is then retained as direct, not released as an
  /// unknown-probe result.
  ConnectionAttempt connect(String discoveryEndpointId) {
    final existing = _attempts[discoveryEndpointId];
    if (existing != null) {
      if (_automaticProbeEndpoints.remove(discoveryEndpointId)) {
        _startNextKnownPeerProbe();
      }
      return existing;
    }
    return _connect(discoveryEndpointId, automaticProbe: false);
  }

  ConnectionAttempt _connect(String discoveryEndpointId,
      {required bool automaticProbe}) {
    if (_state != RuntimeState.ready)
      throw const LpcException(LpcErrorCode.invalidState);
    if (!config.enableGatt) {
      throw const LpcException(
          LpcErrorCode.unsupportedCapability, 'GATT is disabled');
    }
    final backend = _platformBleBackend;
    final identity = _identity;
    if (backend == null || identity == null) {
      throw const LpcException(LpcErrorCode.unsupportedCapability,
          'GATT connect requires a platform backend and persistent identity');
    }
    late final ConnectionAttempt attempt;
    attempt = ConnectionAttempt._(discoveryEndpointId, () async {
      _attempts.remove(discoveryEndpointId);
      await backend.closeGattConnection(discoveryEndpointId);
    });
    if (_attempts.containsKey(discoveryEndpointId)) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'connection attempt already active');
    }
    _attempts[discoveryEndpointId] = attempt;
    if (automaticProbe) _automaticProbeEndpoints.add(discoveryEndpointId);
    if (automaticProbe) {
      attempt.events.listen((event) {
        if (event is ConnectionAttemptConnected ||
            event is ConnectionAttemptFailed ||
            event is ConnectionAttemptCancelled) {
          if (_automaticProbeEndpoints.remove(discoveryEndpointId)) {
            _startNextKnownPeerProbe();
          }
        }
      });
    }
    unawaited(
        backend.connectGatt(discoveryEndpointId).catchError((Object error) {
      attempt._failed(_asLpcError(error));
      _attempts.remove(discoveryEndpointId);
      if (_automaticProbeEndpoints.remove(discoveryEndpointId)) {
        _startNextKnownPeerProbe();
      }
    }));
    return attempt;
  }

  void _onPlatformEvent(PlatformBleEvent event) {
    if (event is PlatformEndpointFound) {
      _scheduleKnownPeerProbe(event.endpointId);
      return;
    }
    if (event is! PlatformGattConnected) return;
    final reconnect = _gattReconnects[event.endpointId];
    if (reconnect != null && reconnect.attempting) {
      unawaited(_startGattResume(event, reconnect));
      return;
    }
    // Keep an outbound attempt registered through HELLO/AUTH/READY.  An
    // explicit user Connect may arrive after native GATT reports connected
    // but before authentication completes; it must be able to adopt this
    // exact attempt instead of creating a competing physical connection.
    var attempt = _attempts[event.endpointId];
    HostSession? host;
    if (attempt == null) {
      for (final candidate in _advertisingHosts) {
        if (candidate.config.autoAccept) {
          host = candidate;
          break;
        }
      }
      final groupProfile = _autoGroupProfile;
      if (host == null && groupProfile == null) return;
      if (host != null && !host.config.autoAccept) return;
      final backend = _platformBleBackend!;
      attempt = ConnectionAttempt._(event.endpointId,
          () => backend.closeGattConnection(event.endpointId));
      if (host == null) {
        unawaited(
            _startGattHandshake(event, attempt, groupProfile: groupProfile));
        return;
      }
    }
    unawaited(_startGattHandshake(event, attempt, host: host));
  }

  Future<void> _startGattHandshake(
      PlatformGattConnected event, ConnectionAttempt attempt,
      {HostSession? host, _AutoGroupHandshakeProfile? groupProfile}) async {
    final backend = _platformBleBackend!;
    final identity = _identity!;
    try {
      // A platform may reuse an opaque endpoint after a disconnect.  Replace
      // the old fragment-event binding before installing the new generation.
      await _gattBindings.remove(event.endpointId)?.close();
      final connection = GattBackendConnection(
          connectionId: event.endpointId,
          platform: PlatformGattFragmentPlatform(
              backend: backend,
              endpointId: event.endpointId,
              platformSafeWriteSize: event.platformSafeWriteSize),
          localRole: event.localRole == 'central'
              ? GattLinkRole.central
              : GattLinkRole.peripheral,
          maxQueuedBytes: config.maxQueuedBytesPerPeer);
      _gattBindings[event.endpointId] = PlatformGattConnectionBinding(
          backend: backend,
          endpointId: event.endpointId,
          connection: connection);
      final ephemeral = await X25519().newKeyPair();
      final ephemeralPublic = await ephemeral.extractPublicKey();
      final trustMode =
          groupProfile?.trustMode ?? host?.config.trustMode ?? config.trustMode;
      late final HandshakeConnection handshake;
      handshake = HandshakeConnection(
          backend: connection,
          localPeerId: localPeerId,
          // An accepted inbound physical link can be either an ordinary
          // explicit-host connection or the responder side of Section 26
          // reconnect.  Do not emit a normal READY before its first encrypted
          // frame selects one of those two protocol paths.
          acceptCandidateResume: host != null || groupProfile != null,
          exchange: HandshakeExchange(
              serviceUuid: config.serviceUuid,
              localHello: HelloPayload(
                  peerId: localPeerId,
                  identityPublicKey: identity.publicKey.bytes,
                  ephemeralPublicKey: ephemeralPublic.bytes,
                  connectionNonce: List<int>.generate(
                      16, (_) => Random.secure().nextInt(256)),
                  peerCapabilities: PeerCapabilityBitmap(const [
                    PeerCapability.gattBaseline,
                    PeerCapability.resume
                  ]).value,
                  keepaliveIntervalMs: config.keepaliveIntervalMs,
                  applicationMetadata:
                      host?.config.applicationMetadata ?? _applicationMetadata,
                  trustMode: trustMode),
              localIdentityKeyPair: identity.keyPair,
              localEphemeralKeyPair: ephemeral,
              knownPeerPolicy: groupProfile?.knownPeerPolicy ??
                  _knownPeerPolicyFor(config, trustMode),
              tofuStore:
                  trustMode == HandshakeTrustMode.tofu ? _tofuStore : null,
              psk32: groupProfile?.psk32 ?? config.psk32),
          onSasRequired: (peerId, sas) {
            attempt._verificationRequired(peerId, sas, handshake.confirmSas);
            host?._peerVerificationRequired(attempt, peerId, sas);
          });
      await handshake.start();
      if (host != null || groupProfile != null) {
        final outcome = await Future.any<Object>([
          handshake.ready.then<Object>((core) => core),
          handshake.authenticated.then<Object>((candidate) => candidate),
        ]);
        if (outcome is HandshakeResult) {
          await _completeInboundGattResume(
              event, connection, handshake, outcome);
          return;
        }
        final core = outcome as PeerConnectionCore;
        final peer = await _ownPeer(core,
            securityLevel:
                handshake.exchange.result!.createReady().securityLevel,
            gattEndpointId: event.endpointId,
            connectionRank: await _rankFor(handshake),
            remoteApplicationMetadata:
                handshake.exchange.result!.remoteHello.applicationMetadata);
        host?._peerConnected(peer, discoveryEndpointId: event.endpointId);
        attempt._connected(peer);
        return;
      }
      final core = await handshake.ready;
      final peer = await _ownPeer(core,
          securityLevel: handshake.exchange.result!.createReady().securityLevel,
          gattEndpointId: event.endpointId,
          connectionRank: await _rankFor(handshake),
          remoteApplicationMetadata:
              handshake.exchange.result!.remoteHello.applicationMetadata);
      if (_automaticProbeEndpoints.contains(event.endpointId)) {
        await _classifyKnownPeer(peer, event.endpointId);
      } else {
        _directRetainedPeers.add(peer.peerId);
      }
      _attempts.remove(event.endpointId);
      attempt._connected(peer);
    } on Object catch (error) {
      attempt._failed(_asLpcError(error));
      await _gattBindings.remove(event.endpointId)?.close();
      await backend.closeGattConnection(event.endpointId);
      if (_automaticProbeEndpoints.remove(event.endpointId)) {
        _startNextKnownPeerProbe();
      }
    }
  }

  void _scheduleKnownPeerProbe(String endpointId) {
    if (!config.autoConnectKnownPeers ||
        _completedKnownPeerProbeEndpoints.containsKey(endpointId) ||
        _automaticProbeEndpoints.contains(endpointId) ||
        _attempts.containsKey(endpointId) ||
        _pendingKnownPeerProbes.contains(endpointId)) return;
    if (_automaticProbeEndpoints.length >=
        config.maxConcurrentKnownPeerProbes) {
      if (_pendingKnownPeerProbes.length < config.maxPendingKnownPeerProbes) {
        _pendingKnownPeerProbes.add(endpointId);
      }
      return;
    }
    _startKnownPeerProbe(endpointId);
  }

  void _startKnownPeerProbe(String endpointId) {
    _automaticProbeEndpoints.add(endpointId);
    _events.add(KnownPeerProbeStarted(_monotonicMs, endpointId));
    try {
      final attempt = _connect(endpointId, automaticProbe: true);
      attempt.events.listen((event) {
        if (event is ConnectionAttemptFailed) {
          _events
              .add(KnownPeerProbeFailed(_monotonicMs, endpointId, event.error));
        }
      });
    } on Object catch (error) {
      _events.add(
          KnownPeerProbeFailed(_monotonicMs, endpointId, _asLpcError(error)));
      _automaticProbeEndpoints.remove(endpointId);
      _startNextKnownPeerProbe();
    }
  }

  void _startNextKnownPeerProbe() {
    while (
        _automaticProbeEndpoints.length < config.maxConcurrentKnownPeerProbes &&
            _pendingKnownPeerProbes.isNotEmpty) {
      final endpointId = _pendingKnownPeerProbes.first;
      _pendingKnownPeerProbes.remove(endpointId);
      _startKnownPeerProbe(endpointId);
    }
  }

  Future<void> _classifyKnownPeer(
      PeerConnection peer, String endpointId) async {
    bool known = _knownPeerCache[peer.peerId] ?? false;
    if (!_knownPeerCache.containsKey(peer.peerId)) {
      try {
        known = await config.knownPeerResolver!
            .isKnownPeer(peer.peerId)
            .timeout(Duration(milliseconds: config.knownPeerLookupTimeoutMs));
      } on Object {
        known = false;
      }
      if (config.maxKnownPeerCacheEntries > 0) {
        if (_knownPeerCache.length >= config.maxKnownPeerCacheEntries) {
          _knownPeerCache.remove(_knownPeerCache.keys.first);
        }
        _knownPeerCache[peer.peerId] = known;
      }
    }
    if (known) {
      _knownRetainedPeers.add(peer.peerId);
      _events.add(KnownPeerConnected(_monotonicMs, peer,
          discoveryEndpointId: endpointId));
    } else {
      _events.add(UnknownPeerIdentified(_monotonicMs, peer,
          discoveryEndpointId: endpointId));
      // No Runtime-managed owner remains for a negative probe result.
      await peer.disconnect();
    }
    if (config.maxKnownPeerCacheEntries > 0) {
      if (_completedKnownPeerProbeEndpoints.length >=
          config.maxKnownPeerCacheEntries) {
        _completedKnownPeerProbeEndpoints
            .remove(_completedKnownPeerProbeEndpoints.keys.first);
      }
      _completedKnownPeerProbeEndpoints[endpointId] = true;
    }
    _automaticProbeEndpoints.remove(endpointId);
    _startNextKnownPeerProbe();
  }

  int get _monotonicMs => DateTime.now().microsecondsSinceEpoch ~/ 1000;

  /// Releases Runtime direct and automatic-known-peer retention only. Shared
  /// session owners are deliberately not affected.
  Future<void> releasePeerRetention(PeerId peerId) async {
    if (_state != RuntimeState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    _directRetainedPeers.remove(peerId);
    _knownRetainedPeers.remove(peerId);
    _knownPeerCache.remove(peerId);
    final peer = _peers.where((value) => value.peerId == peerId).firstOrNull;
    if (peer != null && !_hasOtherOwner(peer)) await peer.disconnect();
  }

  bool _hasOtherOwner(PeerConnection peer) =>
      _directRetainedPeers.contains(peer.peerId) ||
      _knownRetainedPeers.contains(peer.peerId) ||
      _hosts.any((host) => host.peers().contains(peer)) ||
      _groups.any((group) => _groupPeers[group]?.contains(peer) ?? false);

  Future<void> _releaseHostPeer(HostSession owner, PeerConnection peer) async {
    if (!_hasOtherOwnerExcept(peer, owner)) await peer.disconnect();
  }

  bool _hasOtherOwnerExcept(PeerConnection peer, HostSession excluded) =>
      _directRetainedPeers.contains(peer.peerId) ||
      _knownRetainedPeers.contains(peer.peerId) ||
      _hosts.any((host) => host != excluded && host.peers().contains(peer)) ||
      _groups.any((group) => _groupPeers[group]?.contains(peer) ?? false);

  Future<void> updateLocalPresentation(LocalPresentation presentation) async {
    if (_state != RuntimeState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    // LocalPresentation validates both values before this method is entered.
    // Refresh the backend first: a failed refresh must not expose only one
    // half of the requested presentation as the Runtime's future default.
    if (_advertisingActive) {
      final backend = _platformBleBackend;
      if (backend != null) {
        await backend.stopAdvertising();
        await backend.startAdvertising(config.serviceUuid,
            localName: presentation.discoveryDisplayName);
      }
    }
    _discoveryDisplayName = presentation.discoveryDisplayName;
    _applicationMetadata =
        List<int>.unmodifiable(presentation.applicationMetadata);
  }

  /// Completes the responder side of a fresh inbound candidate connection.
  /// Matching is by the authenticated candidate PeerId plus a reconnecting
  /// logical peer; the RESUME proof then binds the exact prior SessionId and
  /// secret before any core state is reattached.
  Future<void> _completeInboundGattResume(
      PlatformGattConnected event,
      GattBackendConnection connection,
      HandshakeConnection handshake,
      HandshakeResult candidate) async {
    final candidates = _peers
        .where((peer) =>
            peer.peerId == handshake.remotePeerId &&
            peer.state == PeerConnectionState.reconnecting)
        .toList(growable: false);
    if (candidates.length != 1) {
      throw const LpcException(
          LpcErrorCode.resumeRejected, 'no unique reconnecting logical peer');
    }
    final peer = candidates.single;
    final previousEndpoint = _gattLinks[peer]?.endpointId;
    final resume = CandidateResumeConnection(
        backend: connection,
        candidateSessionRootKey: candidate.secrets.sessionRootKey,
        candidateSessionId: candidate.secrets.sessionId,
        candidateTranscript: candidate.transcript,
        localPeerId: localPeerId,
        remotePeerId: peer.peerId,
        previousSessionId: peer.sessionId,
        previousResumeSecret: peer._core.resumeSecret,
        previousGeneration: peer._core.generation,
        requester: false,
        initialEncodedFrame: await handshake.candidateInitialFrame);
    await resume.start();
    final resumed = await resume.completed;
    peer._core.completeResume(
        newGeneration: resumed.generation,
        resumedSessionRootKey: resumed.sessionRootKey,
        newResumeSecret: resumed.resumeSecret,
        resumedBackend: connection);
    await peer._core
        .retransmitReliableDataAfterResume(nowMs: peer._core.monotonicNowMs);
    await peer._core.retransmitAckRequiredFramesAfterResume(
        nowMs: peer._core.monotonicNowMs);
    await peer._core.retransmitAckRequiredCheckpointsAfterResume(
        nowMs: peer._core.monotonicNowMs);
    _gattLinks[peer] =
        _GattLink(event.endpointId, event.localRole == 'central');
    if (previousEndpoint != null && previousEndpoint != event.endpointId) {
      await _gattBindings.remove(previousEndpoint)?.close();
    }
    _GattReconnect? reconnect;
    for (final value in _gattReconnects.values) {
      if (identical(value.peer, peer)) {
        reconnect = value;
        break;
      }
    }
    if (reconnect != null) {
      _gattReconnects.remove(reconnect.endpointId);
      reconnect.dispose();
    }
  }

  void _beginGattReconnect(PeerConnection peer) {
    if (!config.autoReconnect || _state != RuntimeState.ready) return;
    final link = _gattLinks[peer];
    // An inbound peripheral-side link exposes the remote central identifier,
    // not a discovery endpoint.  The remote central owns the next attempt.
    if (link == null || !link.localCanInitiateReconnect) return;
    final endpointId = link.endpointId;
    final existing = _gattReconnects[endpointId];
    if (existing != null) return;
    final reconnect = _GattReconnect(
        peer,
        endpointId,
        ReconnectSchedule(
            startedAtMs: peer._core.monotonicNowMs,
            timeoutMs: config.reconnectTimeoutMs));
    _gattReconnects[endpointId] = reconnect;
    reconnect.timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _pollGattReconnect(reconnect);
    });
    _pollGattReconnect(reconnect);
  }

  void _pollGattReconnect(_GattReconnect reconnect) {
    if (reconnect.closed ||
        _gattReconnects[reconnect.endpointId] != reconnect) {
      return;
    }
    final nowMs = reconnect.peer._core.monotonicNowMs;
    if (reconnect.schedule.expiredAt(nowMs)) {
      _gattReconnects.remove(reconnect.endpointId);
      reconnect.dispose();
      unawaited(reconnect.peer.disconnect());
      return;
    }
    if (!reconnect.attempting && reconnect.schedule.attemptDue(nowMs)) {
      reconnect.attempting = true;
      unawaited(() async {
        try {
          await _platformBleBackend!.connectGatt(reconnect.endpointId);
        } on Object {
          _reconnectAttemptFailed(reconnect);
        }
      }());
    }
  }

  void _reconnectAttemptFailed(_GattReconnect reconnect) {
    if (reconnect.closed ||
        _gattReconnects[reconnect.endpointId] != reconnect) {
      return;
    }
    reconnect.attempting = false;
    final nowMs = reconnect.peer._core.monotonicNowMs;
    if (reconnect.schedule.attemptDue(nowMs)) {
      reconnect.schedule.attemptFailed(nowMs);
    }
  }

  Future<void> _startGattResume(
      PlatformGattConnected event, _GattReconnect reconnect) async {
    final backend = _platformBleBackend!;
    final identity = _identity!;
    final peer = reconnect.peer;
    try {
      if (peer.state != PeerConnectionState.reconnecting) {
        throw const LpcException(LpcErrorCode.invalidState);
      }
      final previousEndpoint = _gattLinks[peer]?.endpointId;
      await _gattBindings.remove(event.endpointId)?.close();
      final connection = GattBackendConnection(
          connectionId: event.endpointId,
          platform: PlatformGattFragmentPlatform(
              backend: backend,
              endpointId: event.endpointId,
              platformSafeWriteSize: event.platformSafeWriteSize),
          localRole: event.localRole == 'central'
              ? GattLinkRole.central
              : GattLinkRole.peripheral,
          maxQueuedBytes: config.maxQueuedBytesPerPeer);
      _gattBindings[event.endpointId] = PlatformGattConnectionBinding(
          backend: backend,
          endpointId: event.endpointId,
          connection: connection);
      final ephemeral = await X25519().newKeyPair();
      final ephemeralPublic = await ephemeral.extractPublicKey();
      final trustMode = _resumeTrustMode(peer.securityLevel);
      final handshake = HandshakeConnection(
          backend: connection,
          localPeerId: localPeerId,
          candidateOnly: true,
          exchange: HandshakeExchange(
              serviceUuid: config.serviceUuid,
              localHello: HelloPayload(
                  peerId: localPeerId,
                  identityPublicKey: identity.publicKey.bytes,
                  ephemeralPublicKey: ephemeralPublic.bytes,
                  connectionNonce: List<int>.generate(
                      16, (_) => Random.secure().nextInt(256)),
                  peerCapabilities: PeerCapabilityBitmap(const [
                    PeerCapability.gattBaseline,
                    PeerCapability.resume
                  ]).value,
                  keepaliveIntervalMs: config.keepaliveIntervalMs,
                  trustMode: trustMode),
              localIdentityKeyPair: identity.keyPair,
              localEphemeralKeyPair: ephemeral,
              knownPeerPolicy: trustMode == HandshakeTrustMode.knownPeer
                  ? ExpectExactPeer(peer.peerId)
                  : null,
              tofuStore:
                  trustMode == HandshakeTrustMode.tofu ? _tofuStore : null,
              psk32:
                  trustMode == HandshakeTrustMode.psk32 ? config.psk32 : null));
      await handshake.start();
      final candidate = await handshake.authenticated;
      final resume = CandidateResumeConnection(
          backend: connection,
          candidateSessionRootKey: candidate.secrets.sessionRootKey,
          candidateSessionId: candidate.secrets.sessionId,
          candidateTranscript: candidate.transcript,
          localPeerId: localPeerId,
          remotePeerId: peer.peerId,
          previousSessionId: peer.sessionId,
          previousResumeSecret: peer._core.resumeSecret,
          previousGeneration: peer._core.generation,
          requester: true);
      await resume.start();
      final resumed = await resume.completed;
      peer._core.completeResume(
          newGeneration: resumed.generation,
          resumedSessionRootKey: resumed.sessionRootKey,
          newResumeSecret: resumed.resumeSecret,
          resumedBackend: connection);
      await peer._core
          .retransmitReliableDataAfterResume(nowMs: peer._core.monotonicNowMs);
      await peer._core.retransmitAckRequiredFramesAfterResume(
          nowMs: peer._core.monotonicNowMs);
      await peer._core.retransmitAckRequiredCheckpointsAfterResume(
          nowMs: peer._core.monotonicNowMs);
      _gattLinks[peer] =
          _GattLink(event.endpointId, event.localRole == 'central');
      if (previousEndpoint != null && previousEndpoint != event.endpointId) {
        await _gattBindings.remove(previousEndpoint)?.close();
      }
      _gattReconnects.remove(event.endpointId);
      reconnect.dispose();
    } on Object {
      await _gattBindings.remove(event.endpointId)?.close();
      await backend.closeGattConnection(event.endpointId);
      _reconnectAttemptFailed(reconnect);
    }
  }

  /// Section 33.1 local-only capabilities. A portable runtime without a
  /// platform backend correctly reports no runtime transport capabilities.
  Future<LocalRuntimeCapabilityBitmap> capabilities() async {
    final backend = _platformBleBackend;
    if (backend == null) return LocalRuntimeCapabilityBitmap(const []);
    return _capabilities ??= await backend.queryCapabilities();
  }

  /// Starts one scan for this runtime's configured service UUID. Discovery
  /// endpoints remain local opaque platform handles, never protocol PeerIds.
  Future<DiscoverySession> startDiscovery() async {
    if (_state != RuntimeState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    if (!config.enableGatt) {
      throw const LpcException(
          LpcErrorCode.unsupportedCapability, 'GATT is disabled');
    }
    final backend = _platformBleBackend;
    if (backend == null) {
      throw const LpcException(
          LpcErrorCode.unsupportedCapability, 'no platform BLE backend');
    }
    final key = _serviceKey(config.serviceUuid);
    if (_discoveries.containsKey(key) || !_startingDiscovery.add(key)) {
      throw const LpcException(LpcErrorCode.invalidState,
          'discovery is already active for this service UUID');
    }
    try {
      StreamSubscription<PlatformBleEvent>? subscription;
      late final DiscoverySession session;
      session = DiscoverySession(
        stopPlatformScan: () => _removeExplicitDiscoveryDemand(),
        onStopped: () async {
          await subscription?.cancel();
          _discoveries.remove(key);
          await _removeExplicitDiscoveryDemand();
        },
      );
      subscription = backend.events.listen((event) {
        if (event case PlatformEndpointFound()) {
          session.recordEndpoint(DiscoveredEndpoint(event.endpointId,
              rssi: event.rssi, localName: event.localName));
        }
      }, onError: (Object error, StackTrace stack) {
        // A platform scan error should not terminate the runtime's discovery
        // stream (the app may choose to retry or show its own diagnostics).
        debugPrint('[LocalPeerConnections] discovery backend error: $error');
      });
      // Attach the event listener before starting the native scan. Some BLE
      // stacks report a cached advertisement synchronously from startScan;
      // subscribing first prevents losing that first endpoint.
      if (!_discoveryActive) {
        await backend.startDiscovery(config.serviceUuid);
        _discoveryActive = true;
      }
      _discoveries[key] = session;
      return session;
    } catch (_) {
      // If native start fails, do not leave the listener behind.
      // (The session is not published until startDiscovery succeeds.)
      rethrow;
    } finally {
      _startingDiscovery.remove(key);
    }
  }

  GroupSession joinOrCreateGroup(GroupConfig config) {
    if (_state != RuntimeState.ready)
      throw const LpcException(LpcErrorCode.invalidState);
    final profile = _AutoGroupHandshakeProfile(config);
    final activeProfile = _autoGroupProfile;
    if (activeProfile != null && !activeProfile.matches(profile)) {
      throw const LpcException(LpcErrorCode.invalidState,
          'active GroupSessions require one AUTO_GROUP handshake profile');
    }
    for (final host in _advertisingHosts) {
      if (host.config.autoAccept && !_hostMatchesGroupProfile(host, profile)) {
        throw const LpcException(LpcErrorCode.invalidState,
            'HostSession and AUTO_GROUP inbound profiles are incompatible');
      }
    }
    final random = Random.secure();
    late final GroupSession group;
    group = GroupSession.internal(config, localPeerId,
        GroupId(List<int>.generate(16, (_) => random.nextInt(256))),
        onClosed: _groupClosed,
        onMembershipCommitted: _groupMembershipCommitted);
    final routing = _RuntimeGroupRouteTransport(
        group: group,
        peers: () => Set.unmodifiable(_peers),
        maxReservedBytesPerDestination: this.config.maxQueuedBytesPerPeer,
        maxReservedMessagesPerDestination:
            this.config.maxQueuedMessagesPerPeer);
    _groupRouting[group] = routing;
    _groupPeers[group] = <PeerConnection>{};
    _groups.add(group);
    _autoGroupProfile = profile;
    // AUTO_GROUP presence is Runtime-owned shared resource demand.  The
    // portable, backend-free core deliberately remains usable for protocol
    // tests; a platform binding starts the shared resources below.
    unawaited(_addGroupPresence(group));
    // Keep an unconnected group usable by deterministic unit-test transports,
    // but bind the production route owner as soon as Runtime has a live peer.
    // A group with no authenticated peers cannot submit a live route anyway.
    if (_peers.isNotEmpty) {
      group.attachRouteTransport(routing);
      for (final peer in _peers) {
        routing.observePeer(peer);
      }
    }
    return group;
  }

  void _groupMembershipCommitted(GroupSession group, Set<PeerId> memberIds) {
    final previous = _groupPeers[group] ?? <PeerConnection>{};
    final next =
        _peers.where((peer) => memberIds.contains(peer.peerId)).toSet();
    _groupPeers[group] = next;
    for (final peer in previous.difference(next)) {
      if (!_hasOtherOwner(peer)) unawaited(peer.disconnect());
    }
  }

  bool _hostMatchesGroupProfile(
      HostSession host, _AutoGroupHandshakeProfile groupProfile) {
    return _hostMatchesGroupProfileForConfig(host.config, groupProfile);
  }

  bool _hostMatchesGroupProfileForConfig(
      HostConfig host, _AutoGroupHandshakeProfile groupProfile) {
    final trustMode = host.trustMode ?? config.trustMode;
    if (trustMode != groupProfile.trustMode) return false;
    if (trustMode == HandshakeTrustMode.psk32) {
      return _sameBytes(config.psk32, groupProfile.psk32);
    }
    if (trustMode == HandshakeTrustMode.knownPeer) {
      final hostPeers = config.expectedPeerId == null
          ? config.allowedPeerIds.toSet()
          : {config.expectedPeerId!};
      return hostPeers.length == groupProfile.allowedPeerIds.length &&
          hostPeers.containsAll(groupProfile.allowedPeerIds);
    }
    return true;
  }

  Future<void> _addGroupPresence(GroupSession group) async {
    final backend = _platformBleBackend;
    if (backend == null || _state != RuntimeState.ready) return;
    _advertisingGroups.add(group);
    _scanningGroups.add(group);
    var listenerStarted = false;
    try {
      if (!_advertisingActive) {
        await backend.listenGatt(config.serviceUuid);
        listenerStarted = true;
        await backend.startAdvertising(config.serviceUuid,
            localName: _discoveryDisplayName);
        _advertisingActive = true;
      }
      if (!_discoveryActive) {
        await backend.startDiscovery(config.serviceUuid);
        _discoveryActive = true;
      }
    } on Object {
      _advertisingGroups.remove(group);
      _scanningGroups.remove(group);
      if (listenerStarted &&
          _advertisingHosts.isEmpty &&
          _advertisingGroups.isEmpty) {
        await backend.stopGatt();
      }
      // GroupSession remains a valid local protocol object. Platform failures
      // are not silently converted into an alternate transport or topology.
    }
  }

  Future<void> _removeExplicitDiscoveryDemand() async {
    if (_discoveries.isEmpty && _discoveryActive && _scanningGroups.isEmpty) {
      final backend = _platformBleBackend;
      _discoveryActive = false;
      if (backend != null) await backend.stopDiscovery();
    }
  }

  void _groupClosed(GroupSession group) {
    _groups.remove(group);
    _groupRouting.remove(group)?.dispose();
    final peers = _groupPeers.remove(group) ?? const <PeerConnection>{};
    _advertisingGroups.remove(group);
    _scanningGroups.remove(group);
    if (_groups.isEmpty) _autoGroupProfile = null;
    unawaited(() async {
      if (_advertisingGroups.isEmpty &&
          _advertisingHosts.isEmpty &&
          _advertisingActive) {
        final backend = _platformBleBackend;
        _advertisingActive = false;
        if (backend != null) {
          await backend.stopAdvertising();
          await backend.stopGatt();
        }
      }
      if (_scanningGroups.isEmpty && _discoveries.isEmpty && _discoveryActive) {
        final backend = _platformBleBackend;
        _discoveryActive = false;
        if (backend != null) await backend.stopDiscovery();
      }
      for (final peer in peers) {
        if (!_hasOtherOwner(peer)) await peer.disconnect();
      }
    }());
  }

  /// Creates the advanced Section 33.2 explicit-role host. At most one host
  /// owned by this runtime may advertise at a time.
  HostSession createHostSession(HostConfig config) {
    if (_state != RuntimeState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    if (!this.config.enableGatt) {
      throw const LpcException(
          LpcErrorCode.unsupportedCapability, 'GATT is disabled');
    }
    final backend = _platformBleBackend;
    if (backend == null) {
      throw const LpcException(
          LpcErrorCode.unsupportedCapability, 'no platform BLE backend');
    }
    _validateTrustCredentialsFor(
        this.config, config.trustMode ?? this.config.trustMode);
    final groupProfile = _autoGroupProfile;
    if (config.autoAccept &&
        groupProfile != null &&
        !_hostMatchesGroupProfileForConfig(config, groupProfile)) {
      throw const LpcException(LpcErrorCode.invalidState,
          'HostSession and AUTO_GROUP inbound profiles are incompatible');
    }
    final runtimeConfig = this.config;
    late final HostSession host;
    host = HostSession.internal(
      config: config,
      startAdvertising: () async {
        if (_advertisingHosts.add(host) && !_advertisingActive) {
          var listenerStarted = false;
          try {
            await backend.listenGatt(runtimeConfig.serviceUuid);
            listenerStarted = true;
            await backend.startAdvertising(runtimeConfig.serviceUuid,
                localName: _discoveryDisplayName);
            _advertisingActive = true;
          } on Object {
            _advertisingHosts.remove(host);
            if (listenerStarted &&
                _advertisingHosts.isEmpty &&
                _advertisingGroups.isEmpty) {
              await backend.stopGatt();
            }
            rethrow;
          }
        }
      },
      stopAdvertising: () async {
        _advertisingHosts.remove(host);
        if (_advertisingHosts.isEmpty &&
            _advertisingGroups.isEmpty &&
            _advertisingActive) {
          _advertisingActive = false;
          await backend.stopAdvertising();
          await backend.stopGatt();
        }
      },
      releasePeer: _releaseHostPeer,
      onClosed: (closed) {
        _hosts.remove(closed);
        _advertisingHosts.remove(closed);
      },
    );
    _hosts.add(host);
    return host;
  }

  Future<void> close() async {
    if (_state == RuntimeState.closed || _state == RuntimeState.closing) return;
    _state = RuntimeState.closing;
    for (final reconnect in _gattReconnects.values) {
      reconnect.dispose();
    }
    _gattReconnects.clear();
    for (final attempt in List<ConnectionAttempt>.from(_attempts.values)) {
      await attempt.cancel();
    }
    _attempts.clear();
    for (final peer in List<PeerConnection>.from(_peers)) {
      await peer.disconnect();
    }
    _peers.clear();
    for (final group in List<GroupSession>.from(_groups)) {
      group.close();
    }
    _groups.clear();
    _groupPeers.clear();
    _autoGroupProfile = null;
    for (final host in List<HostSession>.from(_hosts)) {
      await host.close();
    }
    _hosts.clear();
    for (final discovery in List<DiscoverySession>.from(_discoveries.values)) {
      await discovery.stop();
    }
    _discoveries.clear();
    _advertisingGroups.clear();
    _scanningGroups.clear();
    for (final binding in _gattBindings.values) {
      await binding.close();
    }
    _gattBindings.clear();
    await _platformSubscription?.cancel();
    _state = RuntimeState.closed;
    await _events.close();
  }

  Future<List<int>> _rankFor(HandshakeConnection handshake) async {
    final remote = handshake.exchange.remoteHello;
    if (remote == null) {
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'missing authenticated HELLO');
    }
    return connectionRank(
        peerA: localPeerId,
        peerB: remote.peerId,
        connectionNonceA: handshake.exchange.localHello.connectionNonce,
        connectionNonceB: remote.connectionNonce);
  }

  Future<PeerConnection> _ownPeer(PeerConnectionCore core,
      {required SecurityLevel securityLevel,
      String? gattEndpointId,
      List<int>? connectionRank,
      List<int> remoteApplicationMetadata = const []}) async {
    final duplicate = _peers
        .where((peer) =>
            peer.peerId == core.remotePeerId &&
            peer.state == PeerConnectionState.ready)
        .toList(growable: false);
    if (duplicate.isNotEmpty && connectionRank != null) {
      final existing = duplicate.first;
      // A matching PeerId alone is not a compatible logical owner. This
      // portable binding does not multiplex distinct security sessions, so it
      // rejects that request rather than relabeling or downgrading either one.
      if (existing.securityLevel != securityLevel) {
        await core.close();
        throw const LpcException(LpcErrorCode.invalidState,
            'existing peer has an incompatible security profile');
      }
      // The existing authenticated logical session is the reusable object.
      // Do not let a second physical candidate evict its HostSession, group,
      // direct, or known-peer owners.  Closing the candidate collapses the
      // redundant link while preserving those logical owners.
      await core.close();
      return existing;
    }
    late final PeerConnection peer;
    peer = PeerConnection._(core,
        securityLevel: securityLevel,
        remoteApplicationMetadata: remoteApplicationMetadata,
        onDisconnected: (_) {
      _peers.remove(peer);
      _connectionRanks.remove(peer);
      final link = _gattLinks.remove(peer);
      _gattReconnects.remove(link?.endpointId ?? gattEndpointId)?.dispose();
      if (link != null) {
        unawaited(_gattBindings.remove(link.endpointId)?.close());
      }
    },
        onReconnecting:
            gattEndpointId == null ? null : (_) => _beginGattReconnect(peer));
    _peers.add(peer);
    for (final entry in _groupRouting.entries) {
      if (!entry.key.hasRouteTransport) {
        entry.key.attachRouteTransport(entry.value);
      }
      entry.value.observePeer(peer);
      // Routing can observe a peer before it becomes a committed group
      // member, but only committed membership creates group ownership.
      if (entry.key.members.any((member) => member.peerId == peer.peerId)) {
        _groupPeers[entry.key]?.add(peer);
      }
    }
    if (connectionRank != null) {
      _connectionRanks[peer] = List<int>.unmodifiable(connectionRank);
    }
    if (gattEndpointId != null && core.backend is GattBackendConnection) {
      _gattLinks[peer] = _GattLink(
          gattEndpointId,
          (core.backend as GattBackendConnection).localRole ==
              GattLinkRole.central);
    }
    return peer;
  }
}

/// Runtime adapter for the Section 43 routing cores.  It owns no BLE API: all
/// bytes enter and leave through authenticated [PeerConnection] instances.
/// The coordinator-star decision is made from committed GroupSession state;
/// a `send(destination, ...)` never opens a destination shortcut link.
class _RuntimeGroupRouteTransport implements GroupRouteTransport {
  _RuntimeGroupRouteTransport({
    required this.group,
    required this.peers,
    required this.maxReservedBytesPerDestination,
    required this.maxReservedMessagesPerDestination,
  }) {
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      unawaited(_pollAckTimeouts());
    });
    _groupEvents = group.events.listen(_onGroupEvent);
  }

  final GroupSession group;
  final Set<PeerConnection> Function() peers;
  final int maxReservedBytesPerDestination;
  final int maxReservedMessagesPerDestination;
  late final Timer _timer;
  late final StreamSubscription<GroupEvent> _groupEvents;
  final Map<PeerConnection, StreamSubscription<LpcFrame>> _frameSubscriptions =
      {};
  final Map<PeerConnection, StreamSubscription<Uint8List>> _ackSubscriptions =
      {};
  final Map<PeerConnection, StreamSubscription<PeerConnectionEvent>>
      _peerEventSubscriptions = {};
  final Map<PeerConnection, GroupReliableReassembler> _reassemblers = {};
  final MembershipSnapshotOrderTable _membershipOrdering =
      MembershipSnapshotOrderTable();
  final Map<PeerConnection, GroupInfoPayload> _remoteGroupInfo = {};
  late GroupMergeReceiver _mergeReceiver = GroupMergeReceiver(
      committedGroupId: group.groupId,
      committedTerm: group.coordinatorTerm,
      committedMembers: group.members);
  final Map<String, _LiveGroupHop> _ackHops = {};
  final Map<GroupMessageId, SendHandleController> _sourceHandles = {};
  GroupMemberRouter? _memberRouter;
  GroupCoordinatorRouter? _coordinatorRouter;
  GroupDestinationRouter? _destinationRouter;
  String? _coordinatorView;
  String? _destinationView;
  bool _disposed = false;

  void observePeer(PeerConnection peer) {
    if (_disposed || _frameSubscriptions.containsKey(peer)) return;
    _reassemblers[peer] = GroupReliableReassembler(
        maxIncompleteMessages: 64, maxIncompleteBytes: 1048576);
    _frameSubscriptions[peer] = peer.groupFrames.listen(
        (frame) => unawaited(_receiveFrame(peer, frame)),
        onError: (_) => _onPeerLost(peer));
    _ackSubscriptions[peer] = peer._core.acknowledgedMessageIds
        .listen((messageId) => unawaited(_receiveGenericAck(peer, messageId)));
    _peerEventSubscriptions[peer] = peer.events.listen((event) {
      if (event is PeerReconnecting) {
        _reassemblers[peer]?.onTransportGenerationLost();
      } else if (event is PeerReconnected) {
        unawaited(_onPeerReconnected(peer));
      } else if (event is PeerDisconnected) {
        unawaited(_onPeerDisconnected(peer));
      }
    });
    unawaited(_sendGroupInfo(peer));
    if (!group.isCoordinator && peer.peerId == group.coordinatorPeerId) {
      unawaited(_rerouteMemberOperations());
    }
  }

  @override
  void submitReliable(
      RoutedGroupOperation operation, SendHandleController controller) {
    _sourceHandles[operation.groupMessageId] = controller;
    unawaited(() async {
      try {
        if (group.isCoordinator) {
          await _admitLocalCoordinatorOperation(operation);
          return;
        }
        final coordinator = group.coordinatorPeerId;
        final peer = coordinator == null ? null : _readyPeer(coordinator);
        if (peer == null) {
          controller.complete(SendState.failed);
          _sourceHandles.remove(operation.groupMessageId);
          return;
        }
        _member().begin(operation);
        await _submitHop(peer, operation,
            finalHop: false, sourceOperation: operation);
      } on Object {
        controller.complete(SendState.failed);
        _sourceHandles.remove(operation.groupMessageId);
      }
    }());
  }

  @override
  void cancelReliable(GroupMessageId groupMessageId) {
    _sourceHandles.remove(groupMessageId);
    _memberRouter?.cancel(groupMessageId);
    for (final entry in _ackHops.entries.toList()) {
      if (entry.value.operation.groupMessageId != groupMessageId) continue;
      entry.value.peer._core.ackRetention.cancel(entry.value.messageId);
      _ackHops.remove(entry.key);
    }
  }

  @override
  void submitRealtime(
      GroupRealtimeDatagram datagram, RealtimeSendHandleController controller) {
    unawaited(() async {
      try {
        final target = group.isCoordinator
            ? _readyPeer(datagram.destinationPeerId)
            : _readyPeer(group.coordinatorPeerId!);
        if (target == null) {
          controller.complete(SendState.failed);
          return;
        }
        final result = await target._core.submitEncrypted(
            FrameType.groupRealtimeDatagram, datagram.encode());
        controller.complete(result == TransportWriteState.submittedToPlatform
            ? SendState.sentToTransport
            : SendState.failed);
      } on Object {
        controller.complete(SendState.failed);
      }
    }());
  }

  GroupMemberRouter _member() {
    final coordinator = group.coordinatorPeerId;
    if (coordinator == null)
      throw const LpcException(LpcErrorCode.invalidState);
    final existing = _memberRouter;
    if (existing != null &&
        existing.validator.currentCoordinatorPeerId == coordinator) {
      return existing;
    }
    return _memberRouter = GroupMemberRouter(
        validator: _validator(coordinator),
        sends: RoutedSendTable(localPeerId: group.localPeerId));
  }

  GroupCoordinatorRouter _coordinator() {
    if (!group.isCoordinator) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    final view = _routingView(group.localPeerId);
    final existing = _coordinatorRouter;
    if (existing != null && _coordinatorView == view) return existing;
    if (existing != null) {
      _coordinatorView = view;
      // Committed membership may change while an already-admitted relay is
      // active. Preserve that bounded relay table while replacing only the
      // validator used for subsequently received traffic.
      return _coordinatorRouter = GroupCoordinatorRouter(
          validator: _validator(group.localPeerId),
          reliableController: existing.reliableController,
          realtimePending: existing.realtimePending);
    }
    _coordinatorView = view;
    final relays = CoordinatorRelayTable(
        coordinatorPeerId: group.localPeerId,
        maxReservedBytesPerDestination: maxReservedBytesPerDestination,
        maxReservedMessagesPerDestination: maxReservedMessagesPerDestination);
    return _coordinatorRouter = GroupCoordinatorRouter(
        validator: _validator(group.localPeerId),
        reliableController: CoordinatorRelayController(
            canonicalGroupId: group.groupId,
            coordinatorPeerId: group.localPeerId,
            relays: relays),
        realtimePending: CoordinatorRealtimePending(maxPendingDatagrams: 128));
  }

  /// A destination router retains both the group-wide completed-message cache
  /// and its `(source, channel)` latest-state filters for the life of one
  /// committed coordinator/membership view. Recreating it per frame would
  /// turn retransmissions into duplicate application deliveries.
  GroupDestinationRouter _destination() {
    final coordinator = group.coordinatorPeerId;
    if (coordinator == null) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    final view = _routingView(coordinator);
    final existing = _destinationRouter;
    if (existing != null && _destinationView == view) return existing;
    _destinationView = view;
    return _destinationRouter =
        GroupDestinationRouter(validator: _validator(coordinator));
  }

  String _routingView(PeerId coordinator) {
    final members = group.members
        .map((member) => '${member.peerId}:${member.maxPeers}')
        .toList()
      ..sort();
    return '${group.groupId}:$coordinator:${members.join('|')}';
  }

  GroupRoutingValidator _validator(PeerId coordinator) => GroupRoutingValidator(
      canonicalGroupId: group.groupId,
      localPeerId: group.localPeerId,
      currentCoordinatorPeerId: coordinator,
      committedMembers: group.members.map((member) => member.peerId).toSet());

  PeerConnection? _readyPeer(PeerId peerId) {
    for (final peer in peers()) {
      if (peer.peerId == peerId && peer.state == PeerConnectionState.ready) {
        observePeer(peer);
        return peer;
      }
    }
    return null;
  }

  Future<void> _admitLocalCoordinatorOperation(
      RoutedGroupOperation operation) async {
    final destination = _readyPeer(operation.destinationPeerId);
    final incoming = ReassembledGroupReliable(
        pairwiseMessageId: List<int>.filled(8, 0),
        groupId: operation.groupId,
        sourcePeerId: operation.sourcePeerId,
        destinationPeerId: operation.destinationPeerId,
        groupMessageId: operation.groupMessageId,
        deliveryMode: operation.deliveryMode,
        priority: operation.priority,
        bytes: operation.bytes);
    final actions = _coordinator().receiveReliableFromMember(incoming,
        authenticatedSendingPeerId: group.localPeerId,
        destinationReady: destination != null,
        reservationBytes: operation.bytes.length,
        destinationPairwiseMessageId:
            destination == null ? null : _nextMessageId(destination));
    await _applyCoordinatorActions(null, actions,
        localSourceMessageId: operation.groupMessageId);
  }

  Future<void> _receiveFrame(PeerConnection peer, LpcFrame frame) async {
    if (_disposed) return;
    try {
      switch (frame.type) {
        case FrameType.groupReliable:
          await _receiveReliable(peer, frame);
        case FrameType.groupDeliveryAck:
          await _receiveDeliveryAck(peer, frame);
        case FrameType.groupRelayStatus:
          await _receiveRelayStatus(peer, frame);
        case FrameType.groupRealtimeDatagram:
          await _receiveRealtime(peer, frame);
        case FrameType.groupInfo:
          await _receiveGroupInfo(peer, frame);
        case FrameType.groupMerge:
          await _receiveGroupMerge(peer, frame);
        case FrameType.membershipSnapshot:
          await _receiveMembershipSnapshot(peer, frame);
        default:
          return;
      }
    } on LpcException catch (error) {
      // A control send may lose the READY race to normal reconnect handling.
      // The new generation re-advertises GROUP_INFO; it is not a malformed
      // authenticated group frame and must not trigger a second disconnect.
      if (error.code == LpcErrorCode.transportClosed ||
          error.code == LpcErrorCode.invalidState) {
        return;
      }
      await peer.disconnect();
    } on Object {
      // Group routing violations are authenticated peer protocol violations;
      // do not leave the same connection accepting later group traffic.
      await peer.disconnect();
    }
  }

  Future<bool> _sendGroupInfo(PeerConnection peer) async {
    if (_disposed || peer.state != PeerConnectionState.ready) return false;
    try {
      final config = group.config;
      final namespaceHash = await _scopedHash(
          'LPC1-application-namespace', config.applicationNamespace);
      final tokenHash = config.discoveryMode == DiscoveryMode.openProximity
          ? List<int>.filled(32, 0)
          : await _scopedHash('LPC1-group-join-token', config.groupJoinToken!);
      // Hashing is asynchronous; the peer may have begun reconnecting while
      // this control record was being prepared. GROUP_INFO is unacknowledged
      // current-state advertisement, so the next READY generation simply
      // sends it again instead of treating that race as a protocol failure.
      if (_disposed || peer.state != PeerConnectionState.ready) return false;
      final payload = GroupInfoPayload(
          info: GroupMergeInfo(
              namespaceHash: namespaceHash,
              discoveryMode: config.discoveryMode,
              autoMerge: config.autoMerge,
              trustMode: config.groupTrustMode,
              knownPeersAutoMerge: config.knownPeersAutoMerge,
              tokenHash: tokenHash,
              groupId: group.groupId,
              members: group.members),
          coordinatorTerm: group.coordinatorTerm,
          coordinatorPeerId: group.coordinatorPeerId);
      final result = await peer._core
          .submitEncrypted(FrameType.groupInfo, await payload.encode());
      return result == TransportWriteState.submittedToPlatform;
    } on LpcException catch (error) {
      if (error.code != LpcErrorCode.transportClosed &&
          error.code != LpcErrorCode.invalidState) {
        rethrow;
      }
      return false;
    }
  }

  Future<List<int>> _scopedHash(String label, List<int> value) async =>
      (await Sha256().hash([...utf8.encode(label), ...value])).bytes;

  Future<void> _receiveGroupInfo(PeerConnection peer, LpcFrame frame) async {
    if (frame.flags != 0) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final info = await GroupInfoPayload.decode(frame.payload);
    _remoteGroupInfo[peer] = info;
    final local = await _localGroupInfo();
    final evaluation = evaluateGroupMerge(local, info.info);
    if (evaluation.decision != GroupMergeDecision.merge ||
        evaluation.winner?.groupId != local.groupId ||
        !group.isCoordinator) {
      return;
    }
    final members = _mergeMembers(local.members, info.info.members);
    // A delayed GROUP_INFO from the losing pre-merge view must not manufacture
    // a fresh term after this coordinator has already committed that union.
    if (_sameMembers(local.members, members)) return;

    // Only the current coordinator of the deterministic winner originates a
    // merge. This makes the coordinator implicit in the authenticated sender
    // identity of GROUP_MERGE and prevents the two one-member sessions from
    // independently choosing incompatible authorities.
    // A joining peer may have created its GroupSession after this link's
    // initial GROUP_INFO was sent. Refresh the winning view first, on this
    // same ordered pairwise link, so it can bind the immediately following
    // coordinator-less GROUP_MERGE to authenticated GROUP_INFO.
    if (!await _sendGroupInfo(peer)) return;
    if (_disposed || peer.state != PeerConnectionState.ready) return;
    final payload = GroupMergePayload(
        winningGroupId: local.groupId,
        losingGroupId: info.info.groupId,
        newCoordinatorTerm:
            max(group.coordinatorTerm, info.coordinatorTerm) + 1,
        effectiveMaxPeers: evaluation.effectiveMaxPeers,
        members: members);
    _applyGroupMerge(payload, coordinator: group.localPeerId);
    final result = await peer._core.submitAckRequiredFrame(
        type: FrameType.groupMerge,
        payload: await payload.encode(),
        nowMs: peer._core.monotonicNowMs);
    if (result != TransportWriteState.submittedToPlatform) {
      throw const LpcException(LpcErrorCode.transportClosed);
    }
  }

  Future<GroupMergeInfo> _localGroupInfo() async {
    final config = group.config;
    return GroupMergeInfo(
        namespaceHash: await _scopedHash(
            'LPC1-application-namespace', config.applicationNamespace),
        discoveryMode: config.discoveryMode,
        autoMerge: config.autoMerge,
        trustMode: config.groupTrustMode,
        knownPeersAutoMerge: config.knownPeersAutoMerge,
        tokenHash: config.discoveryMode == DiscoveryMode.openProximity
            ? List<int>.filled(32, 0)
            : await _scopedHash(
                'LPC1-group-join-token', config.groupJoinToken!),
        groupId: group.groupId,
        members: group.members);
  }

  List<GroupMember> _mergeMembers(
      Iterable<GroupMember> first, Iterable<GroupMember> second) {
    final merged = <PeerId, GroupMember>{};
    for (final member in [...first, ...second]) {
      final prior = merged[member.peerId];
      merged[member.peerId] = prior == null
          ? member
          : GroupMember(member.peerId, min(prior.maxPeers, member.maxPeers));
    }
    return merged.values.toList()
      ..sort((a, b) => _comparePeerIdBytes(a.peerId, b.peerId));
  }

  bool _sameMembers(Iterable<GroupMember> first, Iterable<GroupMember> second) {
    final left = first.toList()
      ..sort((a, b) => _comparePeerIdBytes(a.peerId, b.peerId));
    final right = second.toList()
      ..sort((a, b) => _comparePeerIdBytes(a.peerId, b.peerId));
    return left.length == right.length &&
        Iterable.generate(left.length).every((index) =>
            left[index].peerId == right[index].peerId &&
            left[index].maxPeers == right[index].maxPeers);
  }

  void _applyGroupMerge(GroupMergePayload payload,
      {required PeerId coordinator}) {
    if (_mergeReceiver.receive(payload) !=
        GroupMergeReceiveDisposition.applied) {
      return;
    }
    group.commitMergedMembership(
        groupId: payload.winningGroupId,
        members: payload.members,
        coordinator: coordinator,
        coordinatorTerm: payload.newCoordinatorTerm);
  }

  Future<void> _receiveGroupMerge(PeerConnection peer, LpcFrame frame) async {
    if (frame.flags != 1) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final payload = await GroupMergePayload.decode(frame.payload);
    final remote = _remoteGroupInfo[peer];
    // The source must be the coordinator that advertised the winning group,
    // and the local group must be the payload's declared loser. Both checks
    // bind this otherwise coordinator-less payload to authenticated GROUP_INFO.
    if (remote == null ||
        !isIncomingGroupMergeAuthorized(
            payload: payload,
            localGroupId: group.groupId,
            retainedRemoteInfo: remote,
            authenticatedSender: peer.peerId)) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    _applyGroupMerge(payload, coordinator: peer.peerId);
    await peer._core.submitAck(frame.messageId);
    await _sendGroupInfo(peer);
  }

  Future<void> _receiveMembershipSnapshot(
      PeerConnection peer, LpcFrame frame) async {
    if (frame.flags != 1) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final snapshot = await MembershipSnapshot.decode(frame.payload);
    if (snapshot.groupId != group.groupId ||
        peer.peerId != group.coordinatorPeerId) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final disposition = _membershipOrdering.observe(
        coordinatorPeerId: peer.peerId,
        coordinatorTerm: snapshot.coordinatorTerm,
        sessionId: peer.sessionId,
        senderMessageId: frame.messageId);
    if (disposition == MembershipSnapshotOrderDisposition.accepted) {
      group.commitMembership(snapshot.members,
          coordinator: peer.peerId, coordinatorTerm: snapshot.coordinatorTerm);
      _mergeReceiver = GroupMergeReceiver(
          committedGroupId: group.groupId,
          committedTerm: group.coordinatorTerm,
          committedMembers: group.members);
    }
    await peer._core.submitAck(frame.messageId);
  }

  Future<void> _receiveReliable(PeerConnection peer, LpcFrame frame) async {
    final chunk = GroupReliableChunk.decode(frame.payload);
    final expectedAck = chunk.deliveryMode == DeliveryMode.reliableAcked;
    if ((frame.flags & 1 != 0) != expectedAck) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final complete = _reassemblers[peer]!.add(frame.messageId, chunk);
    if (complete == null) return;
    if (group.isCoordinator) {
      final destination = _readyPeer(complete.destinationPeerId);
      final actions = _coordinator().receiveReliableFromMember(complete,
          authenticatedSendingPeerId: peer.peerId,
          destinationReady: complete.destinationPeerId == group.localPeerId ||
              destination != null,
          reservationBytes: complete.bytes.length,
          destinationPairwiseMessageId:
              complete.destinationPeerId == group.localPeerId ||
                      destination == null
                  ? null
                  : _nextMessageId(destination));
      await _applyCoordinatorActions(peer, actions);
      return;
    }
    final result = _destination()
        .receiveReliable(complete, authenticatedSendingPeerId: peer.peerId);
    if (complete.deliveryMode == DeliveryMode.reliableAcked) {
      await peer._core.submitAck(complete.pairwiseMessageId);
    }
    if (result.disposition == ReliableDestinationDisposition.deliver) {
      group.receiveReliable(
          source: complete.sourcePeerId,
          id: complete.groupMessageId,
          mode: complete.deliveryMode,
          priority: complete.priority,
          bytes: complete.bytes);
    }
  }

  Future<void> _receiveDeliveryAck(PeerConnection peer, LpcFrame frame) async {
    if (frame.flags != 1)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final ack = GroupDeliveryAck.decode(frame.payload);
    final result = _member()
        .receiveDeliveryAckResult(ack, authenticatedSendingPeerId: peer.peerId);
    if (result.requiresGenericAck) await peer._core.submitAck(frame.messageId);
    final state = result.state;
    if (state != null) _completeSource(ack.groupMessageId, state);
  }

  Future<void> _receiveRelayStatus(PeerConnection peer, LpcFrame frame) async {
    if (frame.flags != 1)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final status = GroupRelayStatusPayload.decode(frame.payload);
    final result = _member().receiveRelayStatusResult(status,
        authenticatedSendingPeerId: peer.peerId);
    if (result.requiresGenericAck) await peer._core.submitAck(frame.messageId);
    final state = result.state;
    if (state != null) _completeSource(status.groupMessageId, state);
  }

  Future<void> _receiveRealtime(PeerConnection peer, LpcFrame frame) async {
    if (frame.flags != 0)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final datagram = GroupRealtimeDatagram.decode(frame.payload);
    if (group.isCoordinator) {
      final target = _readyPeer(datagram.destinationPeerId);
      final result = _coordinator().receiveRealtimeFromMember(datagram,
          authenticatedSendingPeerId: peer.peerId,
          destinationReady: datagram.destinationPeerId == group.localPeerId ||
              target != null);
      if (result == CoordinatorRealtimeEnqueueResult.droppedCapacity) {
        group.reportError(LpcErrorCode.resourceExhausted,
            peerId: datagram.destinationPeerId);
        return;
      }
      if (result ==
          CoordinatorRealtimeEnqueueResult.droppedDestinationUnavailable) {
        return;
      }
      final accepted = _coordinator().realtimePending.take(
          datagram.sourcePeerId,
          datagram.destinationPeerId,
          datagram.channelId);
      if (accepted == null) return;
      if (accepted.destinationPeerId == group.localPeerId) {
        group.receiveRealtime(
            source: accepted.sourcePeerId,
            channelId: accepted.channelId,
            senderTick: accepted.senderTick,
            datagramSequence: accepted.sequence,
            bytes: accepted.bytes);
      } else {
        final destination = _readyPeer(accepted.destinationPeerId);
        if (destination != null) {
          await destination._core.submitEncrypted(
              FrameType.groupRealtimeDatagram, accepted.encode());
        }
      }
      return;
    }
    final accepted = _destination()
        .receiveRealtime(datagram, authenticatedSendingPeerId: peer.peerId);
    if (accepted) {
      group.receiveRealtime(
          source: datagram.sourcePeerId,
          channelId: datagram.channelId,
          senderTick: datagram.senderTick,
          datagramSequence: datagram.sequence,
          bytes: datagram.bytes);
    }
  }

  Future<void> _applyCoordinatorActions(
      PeerConnection? sourcePeer, CoordinatorRelayActions actions,
      {GroupMessageId? localSourceMessageId}) async {
    final sourceAck = actions.sourceHopGenericAckMessageId;
    if (sourceAck != null && sourcePeer != null) {
      await sourcePeer._core.submitAck(sourceAck);
    }
    final local = actions.deliverLocally;
    if (local != null) {
      group.receiveReliable(
          source: local.sourcePeerId,
          id: local.groupMessageId,
          mode: local.deliveryMode,
          priority: local.priority,
          bytes: local.bytes);
    }
    final state = actions.localSourceState;
    if (state != null) {
      final messageId = local?.groupMessageId ?? localSourceMessageId;
      if (messageId != null) _completeSource(messageId, state);
    }
    final ack = actions.deliveryAck;
    if (ack != null)
      await _sendSignal(
          ack.sourcePeerId, FrameType.groupDeliveryAck, ack.encode());
    final status = actions.relayStatus;
    if (status != null)
      await _sendSignal(
          status.sourcePeerId, FrameType.groupRelayStatus, status.encode());
    final forward = actions.forward;
    if (forward != null) await _submitForward(forward);
  }

  Future<void> _submitForward(ReassembledGroupReliable operation) async {
    final destination = _readyPeer(operation.destinationPeerId);
    if (destination == null) {
      final actions = _coordinator().reliableController.finalHopFailed(
          operation.sourcePeerId,
          operation.groupMessageId,
          GroupRelayStatus.destinationUnavailable);
      await _applyCoordinatorActions(null, actions,
          localSourceMessageId: operation.groupMessageId);
      return;
    }
    await _submitHop(destination, null, finalHop: true, reassembled: operation);
  }

  Future<void> _submitHop(PeerConnection peer, RoutedGroupOperation? operation,
      {required bool finalHop,
      ReassembledGroupReliable? reassembled,
      RoutedGroupOperation? sourceOperation}) async {
    final source = reassembled?.sourcePeerId ?? operation!.sourcePeerId;
    final destination =
        reassembled?.destinationPeerId ?? operation!.destinationPeerId;
    final messageId = reassembled?.pairwiseMessageId ?? _nextMessageId(peer);
    final mode = reassembled?.deliveryMode ?? operation!.deliveryMode;
    final priority = reassembled?.priority ?? operation!.priority;
    final bytes = reassembled?.bytes ?? operation!.bytes;
    final groupMessageId =
        reassembled?.groupMessageId ?? operation!.groupMessageId;
    final chunks = chunkGroupReliable(
        groupId: group.groupId,
        source: source,
        destination: destination,
        messageId: groupMessageId,
        mode: mode,
        priority: priority,
        bytes: bytes);
    if (mode == DeliveryMode.reliableAcked) {
      peer._core.ackRetention.retain(
          messageId: messageId,
          logicalContent: [for (final chunk in chunks) ...chunk.encode()]);
    }
    for (final chunk in chunks) {
      final result = await peer._core.submitEncrypted(
          FrameType.groupReliable, chunk.encode(),
          flags: mode == DeliveryMode.reliableAcked ? 1 : 0,
          messageId: messageId);
      if (result != TransportWriteState.submittedToPlatform) {
        throw const LpcException(LpcErrorCode.transportClosed);
      }
    }
    if (mode == DeliveryMode.reliableAcked) {
      peer._core.ackRetention
          .finalFrameSubmitted(messageId, nowMs: peer._core.monotonicNowMs);
      _ackHops[_hopKey(peer, messageId)] = _LiveGroupHop(
          peer: peer,
          messageId: messageId,
          chunks: chunks,
          operation: ReassembledGroupReliable(
              pairwiseMessageId: messageId,
              groupId: group.groupId,
              sourcePeerId: source,
              destinationPeerId: destination,
              groupMessageId: groupMessageId,
              deliveryMode: mode,
              priority: priority,
              bytes: bytes),
          finalHop: finalHop);
    } else if (finalHop) {
      final actions = _coordinator()
          .reliableController
          .finalHopSubmitted(source, groupMessageId);
      await _applyCoordinatorActions(null, actions);
    }
  }

  Future<void> _receiveGenericAck(
      PeerConnection peer, List<int> messageId) async {
    final hop = _ackHops.remove(_hopKey(peer, messageId));
    if (hop == null || !hop.finalHop) return;
    final actions = _coordinator().reliableController.finalHopAcknowledged(
        hop.operation.sourcePeerId, hop.operation.groupMessageId);
    await _applyCoordinatorActions(null, actions,
        localSourceMessageId: hop.operation.groupMessageId);
  }

  Future<void> _sendSignal(
      PeerId source, FrameType type, List<int> payload) async {
    final peer = _readyPeer(source);
    if (peer == null) {
      group.reportError(LpcErrorCode.destinationUnavailable, peerId: source);
      return;
    }
    await peer._core.submitAckRequiredFrame(
        type: type, payload: payload, nowMs: peer._core.monotonicNowMs);
  }

  Future<void> _retransmitHopsFor(PeerConnection peer) async {
    for (final hop
        in _ackHops.values.where((hop) => identical(hop.peer, peer)).toList()) {
      final retry =
          peer._core.ackRetention.retransmitOneAfterResume(hop.messageId);
      if (retry == AckTimeoutResult.retransmitWholeOperation) {
        for (final chunk in hop.chunks) {
          await peer._core.submitEncrypted(
              FrameType.groupReliable, chunk.encode(),
              flags: 1, messageId: hop.messageId);
        }
        peer._core.ackRetention.finalFrameSubmitted(hop.messageId,
            nowMs: peer._core.monotonicNowMs);
      } else if (retry == AckTimeoutResult.terminalAckTimeout) {
        _ackHops.remove(_hopKey(peer, hop.messageId));
      }
    }
  }

  Future<void> _onPeerReconnected(PeerConnection peer) async {
    // GROUP_INFO is current-state, not a retained operation. Send it again
    // after every READY generation so a previous handoff race cannot leave
    // a peer with only a pre-merge view.
    await _sendGroupInfo(peer);
    await _retransmitHopsFor(peer);
    if (group.isCoordinator) {
      // ACK-required final hops were replayed above through their retained
      // encoders. Ordered relays have no generic ACK retention, so only they
      // are resubmitted from chunk 0 after a successful destination RESUME.
      for (final actions
          in _coordinator().destinationResumeSucceeded(peer.peerId)) {
        final forward = actions.forward;
        if (forward != null &&
            forward.deliveryMode == DeliveryMode.reliableOrdered) {
          await _submitHop(peer, null, finalHop: true, reassembled: forward);
        }
      }
      return;
    }
    // A source's ordered operation remains nonterminal until the coordinator
    // reports final-hop submission. On a recovered coordinator route, resend
    // the complete operation with a fresh source-hop attempt.
    if (peer.peerId == group.coordinatorPeerId) {
      for (final operation in _member().coordinatorRouteLost()) {
        if (operation.deliveryMode == DeliveryMode.reliableOrdered) {
          await _submitHop(peer, operation, finalHop: false);
        }
      }
    }
  }

  Future<void> _onPeerDisconnected(PeerConnection peer) async {
    _onPeerLost(peer);
    if (!group.isCoordinator) return;
    for (final actions in _coordinator().destinationResumeFailed(peer.peerId)) {
      await _applyCoordinatorActions(null, actions);
    }
  }

  void _onGroupEvent(GroupEvent event) {
    if (_disposed) return;
    if (event is MemberLeft && group.isCoordinator) {
      final router = _coordinatorRouter;
      if (router != null) {
        unawaited(() async {
          for (final actions in router.destinationRemoved(event.peerId)) {
            await _applyCoordinatorActions(null, actions);
          }
        }());
      }
      return;
    }
    if (event is! CoordinatorChanged) return;
    if (event.previous == group.localPeerId &&
        event.current != group.localPeerId) {
      _coordinatorRouter?.coordinatorAuthorityLost();
      _coordinatorRouter = null;
      _coordinatorView = null;
    }
    final member = _memberRouter;
    if (member != null) {
      // The source table and cancellation tombstones survive coordinator
      // migration; only the authenticated-current-coordinator validator is
      // replaced. The new READY route triggers whole-operation rerouting.
      _memberRouter = GroupMemberRouter(
          validator: _validator(event.current),
          sends: member.sends,
          tombstones: member.tombstones);
      unawaited(_rerouteMemberOperations());
    }
  }

  Future<void> _rerouteMemberOperations() async {
    if (_disposed || group.isCoordinator) return;
    final coordinator = group.coordinatorPeerId;
    if (coordinator == null) return;
    final peer = _readyPeer(coordinator);
    if (peer == null) return;
    // These are new source-hop attempts after authority change, so prior
    // source-hop ACK retention must not retry through the former coordinator.
    for (final entry in _ackHops.entries.toList()) {
      if (entry.value.finalHop) continue;
      entry.value.peer._core.ackRetention.cancel(entry.value.messageId);
      _ackHops.remove(entry.key);
    }
    for (final operation in _member().coordinatorRouteLost()) {
      await _submitHop(peer, operation, finalHop: false);
    }
  }

  /// GROUP_RELIABLE owns its chunk encoder, so PeerConnectionCore deliberately
  /// leaves these retained ACK operations for this adapter to retry. Each
  /// retry is a complete logical hop from chunk 0 with the original hop-local
  /// MessageId (Section 43.1.8).
  Future<void> _pollAckTimeouts() async {
    if (_disposed) return;
    for (final hop in _ackHops.values.toList()) {
      final peer = hop.peer;
      if (peer.state != PeerConnectionState.ready) continue;
      final nowMs = peer._core.monotonicNowMs;
      final result =
          peer._core.ackRetention.onTimer(hop.messageId, nowMs: nowMs);
      if (result == AckTimeoutResult.ignored) continue;
      if (result == AckTimeoutResult.retransmitWholeOperation) {
        try {
          for (final chunk in hop.chunks) {
            final submitted = await peer._core.submitEncrypted(
                FrameType.groupReliable, chunk.encode(),
                flags: 1, messageId: hop.messageId);
            if (submitted != TransportWriteState.submittedToPlatform) {
              throw const LpcException(LpcErrorCode.transportClosed);
            }
          }
          peer._core.ackRetention.finalFrameSubmitted(hop.messageId,
              nowMs: peer._core.monotonicNowMs);
        } on Object {
          // Transport-loss handling pauses the retained deadline. The normal
          // reconnect path will replay the whole hop once READY again.
        }
        continue;
      }
      _ackHops.remove(_hopKey(peer, hop.messageId));
      if (hop.finalHop) {
        final actions = _coordinator().reliableController.finalHopFailed(
            hop.operation.sourcePeerId,
            hop.operation.groupMessageId,
            GroupRelayStatus.destinationAckTimeout);
        await _applyCoordinatorActions(null, actions,
            localSourceMessageId: hop.operation.groupMessageId);
      } else {
        final timeout =
            _memberRouter?.sourceHopAckTimedOut(hop.operation.groupMessageId);
        if (timeout != null) {
          _completeSource(hop.operation.groupMessageId, timeout.state);
        }
      }
    }
  }

  void _onPeerLost(PeerConnection peer) {
    _reassemblers[peer]?.onTransportGenerationLost();
  }

  List<int> _nextMessageId(PeerConnection peer) =>
      peer._core.messageIdAllocator!.allocate();
  String _hopKey(PeerConnection peer, List<int> id) =>
      '${peer.peerId}:${id.join(',')}';
  void _completeSource(GroupMessageId id, SendState state) {
    _sourceHandles.remove(id)?.complete(state);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer.cancel();
    unawaited(_groupEvents.cancel());
    for (final subscription in _frameSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _ackSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _peerEventSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _frameSubscriptions.clear();
    _ackSubscriptions.clear();
    _peerEventSubscriptions.clear();
    _memberRouter?.close();
  }
}

class _LiveGroupHop {
  const _LiveGroupHop({
    required this.peer,
    required this.messageId,
    required this.chunks,
    required this.operation,
    required this.finalHop,
  });
  final PeerConnection peer;
  final List<int> messageId;
  final List<GroupReliableChunk> chunks;
  final ReassembledGroupReliable operation;
  final bool finalHop;
}

/// Convenience factory matching the specification's conceptual entry point.
Future<NearbyRuntime> createRuntime(
        {RuntimeConfig config = const RuntimeConfig(),
        PeerId? localPeerId,
        IdentityStore? identityStore,
        PlatformBleBackend? platformBleBackend}) =>
    NearbyRuntime.create(
        config: config,
        localPeerId: localPeerId,
        identityStore: identityStore,
        platformBleBackend: platformBleBackend);

String _serviceKey(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

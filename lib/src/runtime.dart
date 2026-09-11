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
import 'protocol/checkpoint.dart';
import 'protocol/checkpoint_publication.dart';
import 'protocol/checkpoint_queue.dart';
import 'protocol/checkpoint_receiver.dart';
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

class EndpointFound extends DiscoveryEvent {
  const EndpointFound(this.endpoint);
  final DiscoveredEndpoint endpoint;
}

class EndpointUpdated extends DiscoveryEvent {
  const EndpointUpdated(this.previous, this.endpoint);
  final DiscoveredEndpoint previous;
  final DiscoveredEndpoint endpoint;
}

class EndpointLost extends DiscoveryEvent {
  const EndpointLost(this.endpoint);
  final DiscoveredEndpoint endpoint;
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
  final List<PeerMessageReceived> _messagesBeforeListener =
      <PeerMessageReceived>[];
  late final StreamController<PeerMessageReceived> _messages =
      StreamController<PeerMessageReceived>.broadcast(
    sync: true,
    onListen: _flushMessagesBeforeListener,
  );
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
    _messagesBeforeListener.clear();
    await _messages.close();
    await _realtimeMessages.close();
    await _groupFrames.close();
    await _events.close();
    _onDisconnected?.call(this);
  }

  void _platformTransportLost() {
    if (_disconnected) return;
    _core.transportLost();
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
          final message =
              PeerMessageReceived(delivered.bytes, delivered.deliveryMode);
          // HostSession/GroupSession emits its connected event only after
          // runtime ownership and duplicate-link arbitration complete. A
          // peer can therefore deliver the first application frame before
          // the application has had a chance to subscribe to messages. Keep
          // that reliable frame until the first listener attaches instead of
          // silently dropping it from a broadcast stream.
          if (_messages.hasListener) {
            _messages.add(message);
          } else {
            _messagesBeforeListener.add(message);
          }
        }
      } on Object catch (error) {
        // The core has already applied its terminal malformed-frame path.
        print(
            'inbound data frame failed peer=${_core.remotePeerId} error=$error');
      }
    }());
  }

  void _flushMessagesBeforeListener() {
    if (_messagesBeforeListener.isEmpty) return;
    final queued = List<PeerMessageReceived>.of(_messagesBeforeListener);
    _messagesBeforeListener.clear();
    for (final message in queued) {
      _messages.add(message);
    }
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
      Future<void> Function()? onStopped,
      DateTime Function()? now,
      this.endpointLostAfter = const Duration(seconds: 5)})
      : _stopPlatformScan = stopPlatformScan ?? _noOp,
        _onStopped = onStopped ?? _noOp,
        _now = now ?? DateTime.now {
    if (endpointLostAfter <= Duration.zero) {
      throw ArgumentError.value(endpointLostAfter, 'endpointLostAfter');
    }
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _expireStaleEndpoints();
    });
  }

  final Future<void> Function() _stopPlatformScan;
  final Future<void> Function() _onStopped;
  final DateTime Function() _now;
  final Duration endpointLostAfter;
  final Map<String, DiscoveredEndpoint> _endpoints = {};
  final Map<String, DateTime> _lastObservedAt = {};
  final StreamController<DiscoveryEvent> _events =
      StreamController<DiscoveryEvent>.broadcast(sync: true);
  late final Timer _expiryTimer;
  bool _stopped = false;

  bool get isStopped => _stopped;
  Stream<DiscoveryEvent> get events => _events.stream;
  List<DiscoveredEndpoint> currentEndpoints() =>
      List.unmodifiable(_endpoints.values.toList());

  /// Backend owners record active scan results here. Once stopped, no further
  /// endpoint changes are retained or emitted.
  void recordEndpoint(DiscoveredEndpoint endpoint) {
    if (_stopped) return;
    final previous = _endpoints[endpoint.id];
    _endpoints[endpoint.id] = endpoint;
    _lastObservedAt[endpoint.id] = _now();
    if (previous == null) {
      _events.add(EndpointFound(endpoint));
    } else if (previous.rssi != endpoint.rssi ||
        previous.localName != endpoint.localName) {
      _events.add(EndpointUpdated(previous, endpoint));
    }
  }

  void _expireStaleEndpoints() {
    if (_stopped) return;
    final now = _now();
    for (final entry in _lastObservedAt.entries.toList()) {
      if (now.difference(entry.value) < endpointLostAfter) continue;
      final endpoint = _endpoints.remove(entry.key);
      _lastObservedAt.remove(entry.key);
      if (endpoint != null) _events.add(EndpointLost(endpoint));
    }
  }

  /// Stops scanning once and emits exactly one terminal discovery event. It
  /// intentionally neither owns nor closes established PeerConnections.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _expiryTimer.cancel();
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
  // A keepalive/protocol failure can move the logical peer to RECONNECTING
  // before the native central has released its old client handle.  Serialize
  // that release before calling connectGatt again; otherwise Android quite
  // correctly returns ENDPOINT_BUSY for every retry until the reconnect
  // deadline expires.
  Future<void>? staleGenerationCleanup;
  bool staleGenerationCleanupComplete = false;
  bool staleGenerationCleanupWaitAttached = false;
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
  // A logical PeerConnection can finish closing before the native GATT stack
  // has released its client handle. Keep the endpoint in this short-lived
  // teardown state so a scan callback cannot immediately start a new known
  // peer probe on the stale physical link.
  final Set<String> _closingGattEndpoints = <String>{};
  final Map<String, Future<void>> _gattCloseOperations =
      <String, Future<void>>{};
  // Android can deliver more than one readiness callback for a physical GATT
  // link (for example, repeated CCCD writes).  Serialize handshake startup
  // per endpoint so a duplicate platform event cannot replace the first
  // binding with a competing logical session.
  final Set<String> _startingGattEndpoints = <String>{};
  final Map<String, _GattReconnect> _gattReconnects = {};
  final Map<String, PeerConnection> _gattPeersByEndpoint = {};
  final Map<PeerConnection, Timer> _gattReconnectExpiryTimers = {};
  final Map<PeerConnection, Timer> _unknownPeerReleaseTimers = {};
  final Map<PeerConnection, _GattLink> _gattLinks = {};
  final Map<PeerConnection, List<int>> _connectionRanks = {};
  final Set<PeerConnection> _peers = <PeerConnection>{};
  final Set<PeerId> _directRetainedPeers = <PeerId>{};
  final Set<PeerId> _knownRetainedPeers = <PeerId>{};
  final Set<String> _automaticProbeEndpoints = <String>{};
  final Set<String> _pendingKnownPeerProbes = <String>{};
  final Map<String, Timer> _knownPeerProbeTimers = <String, Timer>{};
  // BLE scan callbacks are intentionally frequent. Keep the full endpoint
  // event stream for discovery semantics, but sample its diagnostic line so
  // logging cannot delay the control server or protocol timers on mobile.
  final Map<String, int> _lastEndpointLogMs = <String, int>{};
  // Discovery callbacks are intentionally noisy.  Once a currently observed
  // endpoint has completed its bounded identity classification, a duplicate
  // scan result must not create another temporary connection.  This cache is
  // endpoint-scoped and in-memory only; it is never a PeerId mapping.
  final Map<String, bool> _completedKnownPeerProbeEndpoints = <String, bool>{};
  // A logical peer can be observed through more than one ephemeral platform
  // endpoint while a duplicate probe races an existing READY connection.
  // Keep those cache entries tied to the logical peer so disconnecting it
  // makes every candidate eligible for automatic recovery.
  final Map<PeerConnection, Set<String>> _knownPeerProbeEndpointsByPeer =
      <PeerConnection, Set<String>>{};
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

  void _log(String message) {
    final logger = config.logger;
    if (logger == null) return;
    try {
      logger('runtime t=$_monotonicMs $message');
    } on Object {
      // Diagnostics must never change connection behavior.
    }
  }

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
      _log(
          'connect adopt endpoint=$discoveryEndpointId automatic=${_automaticProbeEndpoints.contains(discoveryEndpointId)}');
      if (_automaticProbeEndpoints.remove(discoveryEndpointId)) {
        _knownPeerProbeTimers.remove(discoveryEndpointId)?.cancel();
        _startNextKnownPeerProbe();
      }
      return existing;
    }
    final existingPeer = _gattPeersByEndpoint[discoveryEndpointId];
    if (existingPeer != null &&
        (existingPeer.state == PeerConnectionState.ready ||
            existingPeer.state == PeerConnectionState.reconnecting)) {
      _log(
          'connect reuse endpoint=$discoveryEndpointId peer=${existingPeer.peerId} state=${existingPeer.state.name}');
      // An authenticated but not-yet-known probe is kept briefly when an
      // inbound host handshake is racing it. A user Connect arriving during
      // that handoff promotes the same logical peer to direct ownership.
      _unknownPeerReleaseTimers.remove(existingPeer)?.cancel();
      _directRetainedPeers.add(existingPeer.peerId);
      late final StreamSubscription<PeerConnectionEvent> subscription;
      late final ConnectionAttempt attempt;
      attempt = ConnectionAttempt._(discoveryEndpointId, () async {
        await subscription.cancel();
      });
      subscription = existingPeer.events.listen((event) {
        if (event is PeerReconnected) {
          unawaited(subscription.cancel());
          attempt._connected(existingPeer);
        } else if (event is PeerDisconnected) {
          unawaited(subscription.cancel());
          attempt._failed(const LpcException(LpcErrorCode.transportClosed));
        }
      });
      if (existingPeer.state == PeerConnectionState.ready) {
        unawaited(Future<void>.microtask(() {
          unawaited(subscription.cancel());
          attempt._connected(existingPeer);
        }));
      }
      return attempt;
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
    _log(
        'gatt connect requested endpoint=$discoveryEndpointId automatic=$automaticProbe activeAttempts=${_attempts.length}');
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
      _log(
          'gatt connect request failed endpoint=$discoveryEndpointId error=${_asLpcError(error).code.name} detail=$error');
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
      final previous = _lastEndpointLogMs[event.endpointId];
      if (previous == null || _monotonicMs - previous >= 5000) {
        _lastEndpointLogMs[event.endpointId] = _monotonicMs;
        _log(
            'endpoint found endpoint=${event.endpointId} rssi=${event.rssi} name=${event.localName == null ? 'none' : 'present'}');
      }
      _scheduleKnownPeerProbe(event.endpointId);
      return;
    }
    if (event is PlatformGattDisconnected) {
      final binding = _gattBindings[event.endpointId];
      if (binding != null &&
          !binding.acceptsGeneration(event.connectionGeneration)) {
        _log(
            'gatt disconnected ignored stale generation endpoint=${event.endpointId} eventGeneration=${event.connectionGeneration} currentGeneration=${binding.connectionGeneration}');
        return;
      }
      _log(
          'gatt disconnected endpoint=${event.endpointId} generation=${event.connectionGeneration} hasBinding=${_gattBindings.containsKey(event.endpointId)} hasAttempt=${_attempts.containsKey(event.endpointId)}');
      // A duplicate READY candidate can be closed by the remote runtime while
      // this side is still unwinding the handshake.  Failing the automatic
      // probe here would erase its classification before _startGattHandshake
      // reaches the authenticated READY result.  Let that handshake finish
      // (or fail) and perform the normal probe cleanup there; direct user
      // attempts still fail immediately on transport loss.
      final automaticHandshakeDisconnect =
          _startingGattEndpoints.contains(event.endpointId) &&
              _automaticProbeEndpoints.contains(event.endpointId);
      // The binding normally observes this event too.  Keep an endpoint-to-
      // logical-peer index at the runtime boundary so a native disconnect
      // cannot leave an authenticated friend displayed as online if a
      // connection-scoped binding was already replaced by a duplicate probe.
      _gattPeersByEndpoint[event.endpointId]?._platformTransportLost();
      _startingGattEndpoints.remove(event.endpointId);
      unawaited(_closeGattBinding(event.endpointId));
      final attempt = _attempts.remove(event.endpointId);
      if (attempt != null && !automaticHandshakeDisconnect) {
        attempt._failed(const LpcException(
            LpcErrorCode.endpointLost, 'GATT endpoint disconnected'));
        _knownPeerProbeTimers.remove(event.endpointId)?.cancel();
        if (_automaticProbeEndpoints.remove(event.endpointId)) {
          _startNextKnownPeerProbe();
        }
      }
      return;
    }
    if (event is! PlatformGattConnected) return;
    _log(
        'gatt connected endpoint=${event.endpointId} role=${event.localRole} writeSize=${event.platformSafeWriteSize} reconnect=${_gattReconnects[event.endpointId] != null}');
    final reconnect = _gattReconnects[event.endpointId];
    if (reconnect != null && reconnect.attempting) {
      if (_startingGattEndpoints.add(event.endpointId)) {
        _launchGattResume(event, reconnect);
      } else {
        _log(
            'gatt connected ignored duplicate resume callback endpoint=${event.endpointId}');
      }
      return;
    }
    if (_startingGattEndpoints.contains(event.endpointId) ||
        _gattBindings.containsKey(event.endpointId)) {
      _log(
          'gatt connected ignored duplicate endpoint=${event.endpointId} starting=${_startingGattEndpoints.contains(event.endpointId)} bound=${_gattBindings.containsKey(event.endpointId)}');
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
      if (host == null && groupProfile == null) {
        _log(
            'gatt connected rejected endpoint=${event.endpointId} reason=no host/group owner');
        return;
      }
      if (host != null && !host.config.autoAccept) return;
      final backend = _platformBleBackend!;
      attempt = ConnectionAttempt._(event.endpointId,
          () => backend.closeGattConnection(event.endpointId));
      if (host == null) {
        if (_startingGattEndpoints.add(event.endpointId)) {
          _launchGattHandshake(event, attempt, groupProfile: groupProfile);
        }
        return;
      }
    }
    if (_startingGattEndpoints.add(event.endpointId)) {
      _launchGattHandshake(event, attempt, host: host);
    }
  }

  /// Closes both halves of a binding.  Cancelling the event subscription only
  /// stops Dart from consuming callbacks; it does not release the native GATT
  /// client.  This distinction matters when a reconnect candidate is still
  /// handshaking while the logical reconnect deadline expires.
  Future<void> _closeGattBinding(String endpointId) {
    final existing = _gattCloseOperations[endpointId];
    if (existing != null) return existing;
    _closingGattEndpoints.add(endpointId);
    final cleanup = _performGattBindingClose(endpointId);
    _gattCloseOperations[endpointId] = cleanup;
    unawaited(cleanup.then<void>((_) {
      if (_gattCloseOperations[endpointId] == cleanup) {
        _gattCloseOperations.remove(endpointId);
        _closingGattEndpoints.remove(endpointId);
      }
    }));
    return cleanup;
  }

  Future<void> _performGattBindingClose(String endpointId) async {
    final binding = _gattBindings.remove(endpointId);
    if (binding == null) return;
    try {
      await binding.close();
      await binding.connection.close();
    } on Object catch (error) {
      _log(
          'GATT binding transport close failed endpoint=$endpointId error=$error');
    }
  }

  /// Runs a platform-triggered handshake as a consumed background task.
  ///
  /// A rejected probe is an expected network outcome, not an uncaught Dart
  /// error.  In particular, [Future.whenComplete] preserves an error when its
  /// returned Future is ignored, which used to surface normal GATT races as
  /// Flutter "Unhandled Exception" messages.  Keep the endpoint startup lock
  /// and the Future error handling in one place for every handshake path.
  void _launchGattHandshake(
      PlatformGattConnected event, ConnectionAttempt attempt,
      {HostSession? host, _AutoGroupHandshakeProfile? groupProfile}) {
    unawaited(_startGattHandshake(event, attempt,
            host: host, groupProfile: groupProfile)
        .then<void>((_) {
      _startingGattEndpoints.remove(event.endpointId);
    }, onError: (Object error, StackTrace stack) {
      _startingGattEndpoints.remove(event.endpointId);
      if (!_attempts.containsKey(event.endpointId)) {
        _log(
            'background handshake ended endpoint=${event.endpointId} code=${_asLpcError(error).code.name}');
      } else {
        attempt._failed(_asLpcError(error));
      }
    }));
  }

  /// Same containment boundary for automatic RESUME.  Resume failures are
  /// converted into the reconnect scheduler's next attempt by the method
  /// itself, but cleanup failures must not become unhandled Futures.
  void _launchGattResume(
      PlatformGattConnected event, _GattReconnect reconnect) {
    unawaited(_startGattResume(event, reconnect).then<void>((_) {
      _startingGattEndpoints.remove(event.endpointId);
    }, onError: (Object error, StackTrace stack) {
      _startingGattEndpoints.remove(event.endpointId);
      _log(
          'background resume ended endpoint=${event.endpointId} peer=${reconnect.peer.peerId} code=${_asLpcError(error).code.name}');
      _reconnectAttemptFailed(reconnect);
    }));
  }

  Future<void> _startGattHandshake(
      PlatformGattConnected event, ConnectionAttempt attempt,
      {HostSession? host, _AutoGroupHandshakeProfile? groupProfile}) async {
    final backend = _platformBleBackend!;
    final identity = _identity!;
    HandshakeConnection? handshake;
    try {
      _log(
          'handshake start endpoint=${event.endpointId} role=${event.localRole} mode=${host != null ? 'host' : groupProfile != null ? 'group' : _automaticProbeEndpoints.contains(event.endpointId) ? 'known-probe' : 'direct'}');
      // A platform may reuse an opaque endpoint after a disconnect.  Replace
      // the old fragment-event binding before installing the new generation.
      await _gattBindings.remove(event.endpointId)?.close();
      final connection = GattBackendConnection(
          connectionId: event.endpointId,
          logger: (message) => _log(
              'gatt endpoint=${event.endpointId} generation=${event.connectionGeneration} $message'),
          platform: PlatformGattFragmentPlatform(
              backend: backend,
              endpointId: event.endpointId,
              platformSafeWriteSize: event.platformSafeWriteSize,
              connectionGeneration: event.connectionGeneration),
          localRole: event.localRole == 'central'
              ? GattLinkRole.central
              : GattLinkRole.peripheral,
          maxQueuedBytes: config.maxQueuedBytesPerPeer,
          fragmentTimeoutMs: config.gattFragmentInactivityTimeoutMs);
      _gattBindings[event.endpointId] = PlatformGattConnectionBinding(
          backend: backend,
          endpointId: event.endpointId,
          connection: connection,
          connectionGeneration: event.connectionGeneration);
      _log('handshake transport bound endpoint=${event.endpointId}');
      final ephemeral = await X25519().newKeyPair();
      final ephemeralPublic = await ephemeral.extractPublicKey();
      final trustMode =
          groupProfile?.trustMode ?? host?.config.trustMode ?? config.trustMode;
      handshake = HandshakeConnection(
          backend: connection,
          localPeerId: localPeerId,
          logger: (message) =>
              _log('handshake endpoint=${event.endpointId} $message'),
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
            attempt._verificationRequired(peerId, sas, handshake!.confirmSas);
            host?._peerVerificationRequired(attempt, peerId, sas);
          });
      // The peer may answer HELLO while start() is still submitting the
      // local HELLO. Attach error observers before starting so a fast
      // protocol/transport failure is consumed by this handshake task rather
      // than reported by Flutter as an unhandled Future error.
      final ready = handshake.ready;
      final authenticated = handshake.authenticated;
      final candidateInitialFrame = handshake.candidateInitialFrame;
      unawaited(ready.then<void>((_) {}, onError: (_, __) {}));
      unawaited(authenticated.then<void>((_) {}, onError: (_, __) {}));
      // Responder-side candidate handoff reports a failed physical link
      // through this Future before normal READY is selected. It must have an
      // observer even when this particular handshake is not a reconnect.
      unawaited(candidateInitialFrame.then<void>((_) {}, onError: (_, __) {}));
      await handshake.start();
      _log('handshake HELLO submitted endpoint=${event.endpointId}');
      if (host != null || groupProfile != null) {
        final outcome = await Future.any<Object>([
          ready.then<Object>((core) => core),
          authenticated.then<Object>((candidate) => candidate),
        ]);
        if (outcome is HandshakeResult) {
          _log(
              'candidate handshake authenticated endpoint=${event.endpointId} peer=${handshake.remotePeerId}; starting inbound resume');
          await _completeInboundGattResume(
              event, connection, handshake, outcome);
          return;
        }
        final core = outcome as PeerConnectionCore;
        _log(
            'inbound handshake READY endpoint=${event.endpointId} peer=${core.remotePeerId}');
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
      final core = await ready;
      _log(
          'handshake READY endpoint=${event.endpointId} peer=${core.remotePeerId}');
      // Capture this immediately before ownership is assigned.  Duplicate
      // READY resolution can close the candidate transport synchronously
      // while _ownPeer returns the already-owned logical peer; that close
      // emits PlatformGattDisconnected and removes the endpoint from the
      // automatic-probe set.  The candidate was still an automatic probe and
      // must be classified against the PeerId cache rather than silently
      // becoming a failed direct connection.
      final automaticProbe =
          _automaticProbeEndpoints.contains(event.endpointId);
      final peer = await _ownPeer(core,
          securityLevel: handshake.exchange.result!.createReady().securityLevel,
          gattEndpointId: event.endpointId,
          connectionRank: await _rankFor(handshake),
          remoteApplicationMetadata:
              handshake.exchange.result!.remoteHello.applicationMetadata);
      if (automaticProbe) {
        await _classifyKnownPeer(peer, event.endpointId);
      } else {
        _directRetainedPeers.add(peer.peerId);
      }
      _attempts.remove(event.endpointId);
      attempt._connected(peer);
    } on Object catch (error) {
      final lpcError = _asLpcError(error);
      _log(
          'handshake failed endpoint=${event.endpointId} code=${lpcError.code.name} detail=$error');
      final automaticProbe =
          _automaticProbeEndpoints.contains(event.endpointId);
      final exchange = handshake?.exchange;
      // A duplicate authenticated candidate may lose the physical-link rank
      // race after HELLO/AUTH but before this side publishes READY.  The
      // existing logical peer is still a valid authenticated owner, so allow
      // the bounded known-peer probe to classify that PeerId instead of
      // losing the cache lookup solely because the redundant candidate closed.
      if (automaticProbe &&
          exchange?.state == HandshakeExchangeState.authenticated &&
          exchange?.remoteHello?.peerId != null) {
        final existing = _peers
            .where((peer) =>
                peer.peerId == exchange!.remoteHello!.peerId &&
                peer.state == PeerConnectionState.ready)
            .firstOrNull;
        if (existing != null) {
          await _classifyKnownPeer(existing, event.endpointId);
        }
      }
      // The platform may not deliver a second disconnected callback after a
      // protocol-level handshake failure. Release the attempt here so the
      // endpoint can be probed again on the next discovery observation.
      _attempts.remove(event.endpointId);
      attempt._failed(lpcError);
      try {
        await _gattBindings.remove(event.endpointId)?.close();
      } on Object catch (cleanupError) {
        _log(
            'handshake binding cleanup failed endpoint=${event.endpointId} error=$cleanupError');
      }
      try {
        await backend.closeGattConnection(event.endpointId);
      } on Object catch (cleanupError) {
        _log(
            'handshake platform close failed endpoint=${event.endpointId} error=$cleanupError');
      }
      if (_automaticProbeEndpoints.remove(event.endpointId)) {
        _startNextKnownPeerProbe();
      }
    }
  }

  void _scheduleKnownPeerProbe(String endpointId) {
    final existingPeer = _gattPeersByEndpoint[endpointId];
    if (!config.autoConnectKnownPeers ||
        _closingGattEndpoints.contains(endpointId) ||
        (existingPeer != null &&
            (existingPeer.state == PeerConnectionState.ready ||
                existingPeer.state == PeerConnectionState.reconnecting)) ||
        _completedKnownPeerProbeEndpoints.containsKey(endpointId) ||
        _automaticProbeEndpoints.contains(endpointId) ||
        _attempts.containsKey(endpointId) ||
        _pendingKnownPeerProbes.contains(endpointId)) {
      return;
    }
    if (_automaticProbeEndpoints.length >=
        config.maxConcurrentKnownPeerProbes) {
      if (_pendingKnownPeerProbes.length < config.maxPendingKnownPeerProbes) {
        _pendingKnownPeerProbes.add(endpointId);
        _log(
            'known probe queued endpoint=$endpointId pending=${_pendingKnownPeerProbes.length} active=${_automaticProbeEndpoints.length}');
      }
      return;
    }
    _startKnownPeerProbe(endpointId);
  }

  void _startKnownPeerProbe(String endpointId) {
    _automaticProbeEndpoints.add(endpointId);
    _log(
        'known probe started endpoint=$endpointId timeoutMs=${config.reconnectTimeoutMs}');
    _events.add(KnownPeerProbeStarted(_monotonicMs, endpointId));
    try {
      final attempt = _connect(endpointId, automaticProbe: true);
      _knownPeerProbeTimers[endpointId] =
          Timer(Duration(milliseconds: config.reconnectTimeoutMs), () {
        _knownPeerProbeTimers.remove(endpointId);
        if (!_automaticProbeEndpoints.remove(endpointId)) return;
        unawaited(attempt.cancel().catchError((_) {}));
        _events.add(KnownPeerProbeFailed(
            _monotonicMs,
            endpointId,
            const LpcException(LpcErrorCode.connectionTimeout,
                'automatic known-peer probe timed out')));
        _log('known probe timed out endpoint=$endpointId');
        _startNextKnownPeerProbe();
      });
      attempt.events.listen((event) {
        if (event is ConnectionAttemptFailed) {
          _knownPeerProbeTimers.remove(endpointId)?.cancel();
          _events
              .add(KnownPeerProbeFailed(_monotonicMs, endpointId, event.error));
          _log(
              'known probe failed endpoint=$endpointId code=${event.error.code.name} detail=${event.error.message}');
        } else if (event is ConnectionAttemptConnected ||
            event is ConnectionAttemptCancelled) {
          _knownPeerProbeTimers.remove(endpointId)?.cancel();
        }
      });
    } on Object catch (error) {
      _knownPeerProbeTimers.remove(endpointId)?.cancel();
      _events.add(
          KnownPeerProbeFailed(_monotonicMs, endpointId, _asLpcError(error)));
      _log('known probe could not start endpoint=$endpointId error=$error');
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

  /// A platform endpoint is only a local observation and may change across
  /// Android BLE privacy-address rotations. Once one authenticated peer is
  /// READY, another automatic identity probe is a competing physical link,
  /// not a second representation of that peer. Stop those probes here; the
  /// dedicated logical reconnect scheduler remains independent and resumes
  /// after the READY peer enters RECONNECTING.
  void _cancelCompetingKnownPeerProbes({String? exceptEndpointId}) {
    final endpointIds = _automaticProbeEndpoints
        .where((endpointId) => endpointId != exceptEndpointId)
        .toList(growable: false);
    for (final endpointId in endpointIds) {
      _automaticProbeEndpoints.remove(endpointId);
      _knownPeerProbeTimers.remove(endpointId)?.cancel();
      final attempt = _attempts.remove(endpointId);
      if (attempt != null) unawaited(attempt.cancel().catchError((_) {}));
      _log('known probe cancelled as competing endpoint=$endpointId');
    }
    _pendingKnownPeerProbes.clear();
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
      _log(
          'known probe classified endpoint=$endpointId peer=${peer.peerId} known=true');
      _knownRetainedPeers.add(peer.peerId);
      _events.add(KnownPeerConnected(_monotonicMs, peer,
          discoveryEndpointId: endpointId));
      if (config.maxKnownPeerCacheEntries > 0) {
        _knownPeerProbeEndpointsByPeer
            .putIfAbsent(peer, () => <String>{})
            .add(endpointId);
      }
    } else {
      _log(
          'known probe classified endpoint=$endpointId peer=${peer.peerId} known=false; releasing');
      _events.add(UnknownPeerIdentified(_monotonicMs, peer,
          discoveryEndpointId: endpointId));
      // A duplicate automatic probe can resolve to the already-owned logical
      // PeerConnection. Disconnecting it here would tear down a HostSession,
      // direct, or group owner just because this particular discovery probe
      // was not recognized by the resolver. Release only an unowned probe;
      // shared ownership must keep the authenticated transport alive.
      final inboundHandshakeInProgress = _startingGattEndpoints.any(
        (candidate) => candidate != endpointId,
      );
      // A local auto-accepting HostSession can be the application-level
      // receiver while this same physical link is also being used by the
      // remote side's explicit Connect. Keep the unknown probe briefly in
      // that case so the authenticated FRIEND_REQUEST/control frame is not
      // lost when the probe resolver returns false. This remains bounded and
      // does not classify or persist the peer as known.
      final hasAutoAcceptHost = _advertisingHosts.any(
        (candidate) => candidate.config.autoAccept,
      );
      if (!_hasOtherOwner(peer) &&
          !inboundHandshakeInProgress &&
          !hasAutoAcceptHost) {
        await peer.disconnect();
      } else if (!_hasOtherOwner(peer)) {
        // HostSession ownership is published only after the inbound
        // handshake has reached READY. Keep this authenticated transport for
        // a short handoff window so a simultaneous explicit Connect or host
        // promotion cannot lose the first application frame to probe cleanup.
        _unknownPeerReleaseTimers[peer]?.cancel();
        _unknownPeerReleaseTimers[peer] =
            Timer(const Duration(seconds: 10), () {
          _unknownPeerReleaseTimers.remove(peer);
          if (!_hasOtherOwner(peer) &&
              peer.state == PeerConnectionState.ready) {
            unawaited(peer.disconnect());
          }
        });
        _log(
            'known probe deferred release peer=${peer.peerId} endpoint=$endpointId reason=${inboundHandshakeInProgress ? 'inbound-handshake' : 'auto-accept-host'}');
      } else {
        _log(
            'known probe retained shared peer=${peer.peerId} endpoint=$endpointId');
      }
    }
    if (config.maxKnownPeerCacheEntries > 0) {
      if (_completedKnownPeerProbeEndpoints.length >=
          config.maxKnownPeerCacheEntries) {
        final evicted = _completedKnownPeerProbeEndpoints.keys.first;
        _completedKnownPeerProbeEndpoints.remove(evicted);
        for (final endpoints in _knownPeerProbeEndpointsByPeer.values) {
          endpoints.remove(evicted);
        }
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
    _log(
        'inbound resume candidate matched endpoint=${event.endpointId} peer=${peer.peerId} candidates=${candidates.length}');
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
    _log(
        'inbound resume proof accepted endpoint=${event.endpointId} peer=${peer.peerId} generation=${resumed.generation}');
    peer._core.completeResume(
        newGeneration: resumed.generation,
        resumedSessionRootKey: resumed.sessionRootKey,
        newResumeSecret: resumed.resumeSecret,
        resumedBackend: connection);
    await peer._core
        .retransmitReliableDataAfterResume(nowMs: peer._core.monotonicNowMs);
    await peer._core.retransmitAckRequiredFramesAfterResume(
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
    // RESUME completed a new physical generation. The expiry timer belongs
    // only to the failed generation; leaving it armed would disconnect this
    // successfully resumed peer when the old reconnect deadline arrives.
    _gattReconnectExpiryTimers.remove(peer)?.cancel();
  }

  void _beginGattReconnect(PeerConnection peer) {
    if (!config.autoReconnect || _state != RuntimeState.ready) {
      _log(
          'reconnect not scheduled peer=${peer.peerId} autoReconnect=${config.autoReconnect} runtime=${_state.name}');
      return;
    }
    final link = _gattLinks[peer];
    // An inbound peripheral-side link exposes the remote central identifier,
    // not a discovery endpoint.  The remote central owns the next attempt.
    if (link == null || !link.localCanInitiateReconnect) {
      _log(
          'reconnect not scheduled peer=${peer.peerId} reason=${link == null ? 'no-gatt-link' : 'remote-initiates'}');
      return;
    }
    final endpointId = link.endpointId;
    final existing = _gattReconnects[endpointId];
    if (existing != null) {
      _log(
          'reconnect already scheduled peer=${peer.peerId} endpoint=$endpointId');
      return;
    }
    final reconnect = _GattReconnect(
        peer,
        endpointId,
        ReconnectSchedule(
            startedAtMs: peer._core.monotonicNowMs,
            timeoutMs: config.reconnectTimeoutMs));
    _gattReconnects[endpointId] = reconnect;
    final staleBinding = _gattBindings.remove(endpointId);
    // Even when the platform-disconnect callback already removed the Dart
    // binding, ask the native backend to close the endpoint idempotently. A
    // few Android Bluetooth stacks report the link as disconnected before
    // releasing the client handle, which otherwise makes the first RESUME
    // connectGatt call race the old native object.
    reconnect.staleGenerationCleanup =
        _closeStaleGattGeneration(endpointId, staleBinding, reconnect);
    _log(
        'reconnect scheduled peer=${peer.peerId} endpoint=$endpointId timeoutMs=${config.reconnectTimeoutMs}');
    reconnect.timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _pollGattReconnect(reconnect);
    });
    _pollGattReconnect(reconnect);
  }

  void _scheduleGattReconnectExpiry(PeerConnection peer) {
    _gattReconnectExpiryTimers[peer]?.cancel();
    _gattReconnectExpiryTimers[peer] =
        Timer(Duration(milliseconds: config.reconnectTimeoutMs), () {
      _gattReconnectExpiryTimers.remove(peer);
      if (peer.state == PeerConnectionState.reconnecting) {
        _log('reconnect expired peer=${peer.peerId}; terminal disconnect');
        unawaited(peer.disconnect());
      }
    });
  }

  void _pollGattReconnect(_GattReconnect reconnect) {
    if (reconnect.closed ||
        _gattReconnects[reconnect.endpointId] != reconnect) {
      return;
    }
    final nowMs = reconnect.peer._core.monotonicNowMs;
    if (reconnect.schedule.expiredAt(nowMs)) {
      _log(
          'reconnect schedule expired peer=${reconnect.peer.peerId} endpoint=${reconnect.endpointId}');
      _gattReconnects.remove(reconnect.endpointId);
      reconnect.dispose();
      unawaited(reconnect.peer.disconnect());
      return;
    }
    final cleanup = reconnect.staleGenerationCleanup;
    if (!reconnect.staleGenerationCleanupComplete) {
      if (cleanup == null) {
        reconnect.staleGenerationCleanupComplete = true;
      } else if (!reconnect.staleGenerationCleanupWaitAttached) {
        // The completion callback is installed once, without using
        // Future.whenComplete, whose returned error Future could become an
        // unhandled exception during native teardown.
        reconnect.staleGenerationCleanupWaitAttached = true;
        unawaited(cleanup.then<void>((_) {
          reconnect.staleGenerationCleanupComplete = true;
          _pollGattReconnect(reconnect);
        }, onError: (Object error, StackTrace stack) {
          _log(
              'stale GATT generation cleanup failed endpoint=${reconnect.endpointId} error=$error');
          reconnect.staleGenerationCleanupComplete = true;
          _pollGattReconnect(reconnect);
        }));
        reconnect.staleGenerationCleanup = null;
      }
      return;
    }
    if (!reconnect.attempting && reconnect.schedule.attemptDue(nowMs)) {
      reconnect.attempting = true;
      final remainingMs =
          reconnect.schedule.startedAtMs + reconnect.schedule.timeoutMs - nowMs;
      _log(
          'reconnect attempt endpoint=${reconnect.endpointId} peer=${reconnect.peer.peerId} remainingMs=${remainingMs < 0 ? 0 : remainingMs} failureCount=${reconnect.schedule.failedAttempts}');
      unawaited(() async {
        try {
          await _platformBleBackend!.connectGatt(reconnect.endpointId);
        } on Object catch (error) {
          _log(
              'reconnect platform request failed endpoint=${reconnect.endpointId} error=$error');
          _reconnectAttemptFailed(reconnect);
        }
      }());
    }
  }

  Future<void> _closeStaleGattGeneration(String endpointId,
      PlatformGattConnectionBinding? binding, _GattReconnect reconnect) async {
    _log(
        'closing stale GATT generation before reconnect endpoint=$endpointId peer=${reconnect.peer.peerId}');
    // Remove the event subscription first so the old binding cannot consume a
    // fragment or writable callback after the logical peer has entered its
    // next generation. GattBackendConnection.close then releases the native
    // client handle that Android otherwise reports as ENDPOINT_BUSY.
    if (binding != null) {
      await binding.close();
      await binding.connection.close();
    } else {
      await _platformBleBackend?.closeGattConnection(endpointId);
    }
    _log(
        'stale GATT generation closed before reconnect endpoint=$endpointId peer=${reconnect.peer.peerId}');
  }

  void _reconnectAttemptFailed(_GattReconnect reconnect) {
    if (reconnect.closed ||
        _gattReconnects[reconnect.endpointId] != reconnect) {
      return;
    }
    reconnect.attempting = false;
    _log(
        'reconnect attempt failed endpoint=${reconnect.endpointId} peer=${reconnect.peer.peerId}');
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
      _log(
          'resume handshake start endpoint=${event.endpointId} peer=${peer.peerId} generation=${peer._core.generation}');
      final previousEndpoint = _gattLinks[peer]?.endpointId;
      await _gattBindings.remove(event.endpointId)?.close();
      final connection = GattBackendConnection(
          connectionId: event.endpointId,
          logger: (message) => _log(
              'gatt endpoint=${event.endpointId} generation=${event.connectionGeneration} $message'),
          platform: PlatformGattFragmentPlatform(
              backend: backend,
              endpointId: event.endpointId,
              platformSafeWriteSize: event.platformSafeWriteSize,
              connectionGeneration: event.connectionGeneration),
          localRole: event.localRole == 'central'
              ? GattLinkRole.central
              : GattLinkRole.peripheral,
          maxQueuedBytes: config.maxQueuedBytesPerPeer,
          fragmentTimeoutMs: config.gattFragmentInactivityTimeoutMs);
      _gattBindings[event.endpointId] = PlatformGattConnectionBinding(
          backend: backend,
          endpointId: event.endpointId,
          connection: connection,
          connectionGeneration: event.connectionGeneration);
      final ephemeral = await X25519().newKeyPair();
      final ephemeralPublic = await ephemeral.extractPublicKey();
      final trustMode = _resumeTrustMode(peer.securityLevel);
      final handshake = HandshakeConnection(
          backend: connection,
          localPeerId: localPeerId,
          logger: (message) =>
              _log('resume endpoint=${event.endpointId} $message'),
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
      final ready = handshake.ready;
      final authenticated = handshake.authenticated;
      // A candidate resume can be terminated by the reconnect deadline
      // before AUTH completes. Observe every handshake outcome so the
      // expected transport-closed error is consumed instead of surfacing as
      // an unhandled Flutter error.
      unawaited(ready.then<void>((_) {}, onError: (_, __) {}));
      unawaited(authenticated.then<void>((_) {}, onError: (_, __) {}));
      await handshake.start();
      final candidate = await authenticated;
      _log(
          'resume candidate authenticated endpoint=${event.endpointId} peer=${peer.peerId}');
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
      _log(
          'resume proof accepted endpoint=${event.endpointId} peer=${peer.peerId} generation=${resumed.generation}');
      peer._core.completeResume(
          newGeneration: resumed.generation,
          resumedSessionRootKey: resumed.sessionRootKey,
          newResumeSecret: resumed.resumeSecret,
          resumedBackend: connection);
      await peer._core
          .retransmitReliableDataAfterResume(nowMs: peer._core.monotonicNowMs);
      await peer._core.retransmitAckRequiredFramesAfterResume(
          nowMs: peer._core.monotonicNowMs);
      _gattLinks[peer] =
          _GattLink(event.endpointId, event.localRole == 'central');
      _gattPeersByEndpoint[event.endpointId] = peer;
      if (previousEndpoint != null && previousEndpoint != event.endpointId) {
        if (_gattPeersByEndpoint[previousEndpoint] == peer) {
          _gattPeersByEndpoint.remove(previousEndpoint);
        }
        await _gattBindings.remove(previousEndpoint)?.close();
      }
      _gattReconnects.remove(event.endpointId);
      reconnect.dispose();
      // The old reconnect deadline must not terminate the newly resumed
      // generation after the proof has successfully rebound the peer.
      _gattReconnectExpiryTimers.remove(peer)?.cancel();
    } on Object catch (error) {
      _log(
          'resume failed endpoint=${event.endpointId} peer=${peer.peerId} error=$error');
      try {
        await _gattBindings.remove(event.endpointId)?.close();
      } on Object catch (cleanupError) {
        _log(
            'resume binding cleanup failed endpoint=${event.endpointId} error=$cleanupError');
      }
      try {
        await backend.closeGattConnection(event.endpointId);
      } on Object catch (cleanupError) {
        _log(
            'resume platform close failed endpoint=${event.endpointId} error=$cleanupError');
      }
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
        peers: () => Set.unmodifiable(_groupPeers[group] ?? const {}),
        maxReservedBytesPerDestination: this.config.maxQueuedBytesPerPeer,
        maxReservedMessagesPerDestination: this.config.maxQueuedMessagesPerPeer,
        logger: _log);
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
    final profile = _autoGroupProfile;
    final next = _peers
        .where((peer) =>
            memberIds.contains(peer.peerId) &&
            (profile == null || _peerMatchesGroupProfile(peer, profile)))
        .toSet();
    _groupPeers[group] = next;
    for (final peer in previous.difference(next)) {
      if (!_hasOtherOwner(peer)) unawaited(peer.disconnect());
    }
  }

  bool _peerMatchesGroupProfile(
      PeerConnection peer, _AutoGroupHandshakeProfile profile) {
    return switch (profile.trustMode) {
      HandshakeTrustMode.tofu =>
        peer.securityLevel == SecurityLevel.encryptedTofu,
      HandshakeTrustMode.psk32 =>
        peer.securityLevel == SecurityLevel.authenticatedPsk,
      HandshakeTrustMode.sas =>
        peer.securityLevel == SecurityLevel.authenticatedSas,
      HandshakeTrustMode.knownPeer =>
        peer.securityLevel == SecurityLevel.authenticatedKnownPeer,
    };
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
    for (final timer in _knownPeerProbeTimers.values) {
      timer.cancel();
    }
    _knownPeerProbeTimers.clear();
    for (final reconnect in _gattReconnects.values) {
      reconnect.dispose();
    }
    _gattReconnects.clear();
    for (final timer in _gattReconnectExpiryTimers.values) {
      timer.cancel();
    }
    _gattReconnectExpiryTimers.clear();
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
    // Closing only the Dart event subscription is insufficient: the native
    // GATT handle can remain connected and deliver callbacks to the next
    // runtime instance. This is especially visible after an integration-test
    // reset when Android reuses the same device address with a new generation.
    // Close each binding's transport as well so the platform releases the
    // physical link before this runtime is considered closed.
    for (final endpointId in _gattBindings.keys.toList(growable: false)) {
      await _closeGattBinding(endpointId);
    }
    _startingGattEndpoints.clear();
    for (final timer in _unknownPeerReleaseTimers.values) {
      timer.cancel();
    }
    _unknownPeerReleaseTimers.clear();
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
      _log(
          'duplicate READY peer=${core.remotePeerId} existingState=${existing.state.name} existingSecurity=${existing.securityLevel.name} candidateSecurity=${securityLevel.name}');
      // A matching PeerId alone is not a compatible logical owner. This
      // portable binding does not multiplex distinct security sessions, so it
      // rejects that request rather than relabeling or downgrading either one.
      if (existing.securityLevel != securityLevel) {
        _log(
            'duplicate rejected peer=${core.remotePeerId} reason=incompatible-security');
        await core.close();
        throw const LpcException(LpcErrorCode.invalidState,
            'existing peer has an incompatible security profile');
      }
      final existingRank = _connectionRanks[existing];
      if (existingRank == null) {
        // A legacy/manual peer without a recorded rank remains the stable
        // owner.  The new candidate is still closed before it can acquire
        // any Runtime ownership.
        await core.close();
        _log(
            'duplicate candidate closed peer=${core.remotePeerId} reason=existing-unranked');
        return existing;
      }
      final retained =
          retainedConnectionRankIndex(existingRank, connectionRank);
      if (retained == 0) {
        // The existing authenticated logical session wins the deterministic
        // Section 10.2 tie-break.  Closing the candidate collapses its
        // redundant physical link without disturbing direct, HostSession,
        // group, or known-peer ownership of the winner.
        await core.close();
        _log(
            'duplicate candidate closed peer=${core.remotePeerId} reason=existing-rank-wins');
        return existing;
      }
      // The newly authenticated link has the smaller rank.  Replace the
      // existing logical owner only after this candidate has completed the
      // full READY exchange, so there is never an unauthenticated promotion.
      // PeerConnection.disconnect() is an explicit terminal duplicate close;
      // it does not enter the normal reconnect scheduler.
      await existing.disconnect();
      _log(
          'duplicate existing closed peer=${core.remotePeerId} reason=candidate-rank-wins');
    }
    late final PeerConnection peer;
    peer = PeerConnection._(core,
        securityLevel: securityLevel,
        remoteApplicationMetadata: remoteApplicationMetadata,
        onDisconnected: (_) {
      _log(
          'peer disconnected peer=${core.remotePeerId} endpoint=${gattEndpointId ?? 'none'}');
      _peers.remove(peer);
      _connectionRanks.remove(peer);
      _unknownPeerReleaseTimers.remove(peer)?.cancel();
      final link = _gattLinks.remove(peer);
      final endpointId = link?.endpointId ?? gattEndpointId;
      _gattPeersByEndpoint.removeWhere((_, value) => value == peer);
      _gattReconnectExpiryTimers.remove(peer)?.cancel();
      // A completed automatic probe is only a duplicate-scan suppression
      // entry while its authenticated connection remains alive.  Once that
      // logical peer disconnects, the same platform endpoint must be eligible
      // for a fresh known-peer probe so auto-reconnect can recover it.
      if (endpointId != null) {
        _completedKnownPeerProbeEndpoints.remove(endpointId);
      }
      final associatedEndpoints =
          _knownPeerProbeEndpointsByPeer.remove(peer) ?? const <String>{};
      for (final associatedEndpoint in associatedEndpoints) {
        _completedKnownPeerProbeEndpoints.remove(associatedEndpoint);
      }
      _gattReconnects.remove(endpointId)?.dispose();
      if (link != null) {
        // The core backend can already be closed when this callback runs. A
        // reconnect candidate, however, owns a separate binding and must be
        // closed explicitly or Android retains its native client handle.
        unawaited(_closeGattBinding(link.endpointId));
      }
    },
        onReconnecting: gattEndpointId == null
            ? null
            : (_) {
                _log(
                    'peer entering reconnecting peer=${core.remotePeerId} endpoint=${_gattLinks[peer]?.endpointId ?? gattEndpointId}');
                _beginGattReconnect(peer);
                _scheduleGattReconnectExpiry(peer);
              });
    _peers.add(peer);
    // A READY authenticated peer is the logical owner of the session. An
    // automatic known-peer probe started from another transient platform
    // endpoint must not create a duplicate GATT session that can replace or
    // tear down this owner (notably during Android/iOS scan/connect races).
    // Reconnects are tracked separately by _gattReconnects and are not
    // cancelled by this cleanup.
    _cancelCompetingKnownPeerProbes(exceptEndpointId: gattEndpointId);
    final gattRole = core.backend is GattBackendConnection
        ? (core.backend as GattBackendConnection).localRole?.name
        : null;
    _log(
        'peer owned peer=${peer.peerId} security=${securityLevel.name} endpoint=${gattEndpointId ?? 'none'} role=${gattRole ?? 'none'}');
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
      _gattPeersByEndpoint[gattEndpointId] = peer;
    }
    return peer;
  }
}

/// Runtime adapter for the Section 43 routing cores.  It owns no BLE API: all
/// bytes enter and leave through authenticated [PeerConnection] instances.
/// The coordinator-star decision is made from committed GroupSession state;
/// a `send(destination, ...)` never opens a destination shortcut link.
class _RuntimeGroupRouteTransport
    implements GroupRouteTransport, CheckpointGroupRouteTransport {
  _RuntimeGroupRouteTransport({
    required this.group,
    required this.peers,
    required this.maxReservedBytesPerDestination,
    required this.maxReservedMessagesPerDestination,
    required this.logger,
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
  final void Function(String) logger;
  late final Timer _timer;
  late final StreamSubscription<GroupEvent> _groupEvents;
  final Map<PeerConnection, StreamSubscription<LpcFrame>> _frameSubscriptions =
      {};
  final Map<PeerConnection, StreamSubscription<Uint8List>> _ackSubscriptions =
      {};
  final Map<PeerConnection, StreamSubscription<PeerConnectionEvent>>
      _peerEventSubscriptions = {};
  final Map<PeerConnection, GroupReliableReassembler> _reassemblers = {};
  final Map<PeerConnection, CheckpointReceiver> _checkpointReceivers = {};
  final MembershipSnapshotOrderTable _membershipOrdering =
      MembershipSnapshotOrderTable();
  final Map<PeerConnection, GroupInfoPayload> _remoteGroupInfo = {};
  late GroupMergeReceiver _mergeReceiver = GroupMergeReceiver(
      committedGroupId: group.groupId,
      committedTerm: group.coordinatorTerm,
      committedMembers: group.members);
  final Map<String, _LiveGroupHop> _ackHops = {};
  final Map<String, _LiveCheckpointHop> _checkpointHops = {};
  final Map<PeerId, CheckpointReplicationQueue> _checkpointQueues = {};
  final Map<int, _CheckpointPublicationData> _checkpointPublications = {};
  final Map<GroupMessageId, SendHandleController> _sourceHandles = {};
  GroupMemberRouter? _memberRouter;
  GroupCoordinatorRouter? _coordinatorRouter;
  GroupDestinationRouter? _destinationRouter;
  String? _coordinatorView;
  String? _destinationView;
  bool _disposed = false;

  void observePeer(PeerConnection peer) {
    if (_disposed || _frameSubscriptions.containsKey(peer)) return;
    logger(
        'group observe peer=${peer.peerId} state=${peer.state} coordinator=${group.coordinatorPeerId} localCoordinator=${group.isCoordinator} members=${group.members.map((member) => member.peerId).join(',')}');
    _reassemblers[peer] = GroupReliableReassembler(
        maxIncompleteMessages: 64, maxIncompleteBytes: 1048576);
    _checkpointReceivers[peer] = CheckpointReceiver();
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
    checkpointPeerReady(peer.peerId);
    if (!group.isCoordinator && peer.peerId == group.coordinatorPeerId) {
      unawaited(_rerouteMemberOperations());
    }
  }

  @override
  void submitReliable(
      RoutedGroupOperation operation, SendHandleController controller) {
    _sourceHandles[operation.groupMessageId] = controller;
    logger(
        'group source submit group=${_debugId(operation.groupId.bytes)} source=${operation.sourcePeerId} destination=${operation.destinationPeerId} message=${_debugId(operation.groupMessageId.bytes)} coordinator=${group.coordinatorPeerId} localCoordinator=${group.isCoordinator}');
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
  void checkpointPublicationAccepted(
      CoordinatorCheckpointHandle handle,
      List<int> bytes,
      int coordinatorTerm,
      CheckpointApplicationValidationRequirement validationRequirement) {
    if (_disposed ||
        !group.isCoordinator ||
        !group.config.coordinatorCheckpointing) {
      return;
    }
    final value = _CheckpointPublicationData(handle, Uint8List.fromList(bytes),
        coordinatorTerm, validationRequirement);
    _checkpointPublications[handle.publicationId] = value;
    for (final peerId in group.members
        .map((member) => member.peerId)
        .where((peerId) => peerId != group.localPeerId)) {
      final peer = _readyPeer(peerId);
      if (peer != null) _offerCheckpoint(peer, value);
    }
    _pruneCheckpointPublications();
  }

  @override
  void checkpointPeerReady(PeerId peerId) {
    if (_disposed ||
        !group.isCoordinator ||
        !group.config.coordinatorCheckpointing ||
        !group.members.any((member) => member.peerId == peerId)) {
      return;
    }
    final latest = group.latestCheckpointForReplication();
    if (latest == null) return;
    final value = _CheckpointPublicationData(
        latest.publication,
        latest.bytes,
        latest.publication.coordinatorTerm,
        latest.publication.applicationValidationRequirement);
    _checkpointPublications[latest.publication.publicationId] = value;
    final peer = _readyPeer(peerId);
    if (peer != null && peer.peerId != group.localPeerId) {
      _offerCheckpoint(peer, value);
    }
  }

  @override
  void checkpointPeerLeft(PeerId peerId) {
    final queue = _checkpointQueues.remove(peerId);
    if (queue?.inFlight != null) {
      final operation = queue!.inFlight!;
      final value = _checkpointPublications[operation.publicationId];
      if (value != null) {
        group.checkpointOperationFinished(
            value.handle, peerId, CheckpointPeerResult.peerLeft,
            checkpointSequence: operation.sequence);
      }
    }
    for (final entry in _checkpointHops.entries.toList()) {
      if (entry.value.peer.peerId != peerId) continue;
      entry.value.peer._core.ackRetention.cancel(entry.value.messageId);
      _checkpointHops.remove(entry.key);
    }
    _pruneCheckpointPublications();
  }

  @override
  void checkpointAuthorityLost() {
    for (final entry in _checkpointHops.entries.toList()) {
      entry.value.peer._core.ackRetention.cancel(entry.value.messageId);
      _checkpointHops.remove(entry.key);
    }
    _checkpointQueues.clear();
    _checkpointPublications.clear();
  }

  @override
  void checkpointGroupClosed() {
    for (final entry in _checkpointHops.entries.toList()) {
      entry.value.peer._core.ackRetention.cancel(entry.value.messageId);
      _checkpointHops.remove(entry.key);
    }
    _checkpointQueues.clear();
    _checkpointPublications.clear();
  }

  void _offerCheckpoint(
      PeerConnection peer, _CheckpointPublicationData publication) {
    if (_disposed || peer.state != PeerConnectionState.ready) return;
    final queue = _checkpointQueues.putIfAbsent(
        peer.peerId, CheckpointReplicationQueue.new);
    final operation = queue.publish(publication.bytes,
        publicationId: publication.handle.publicationId);
    if (operation != null) {
      _sendCheckpoint(peer, operation, publication);
    }
  }

  void _sendCheckpoint(
      PeerConnection peer,
      CheckpointReplicationOperation operation,
      _CheckpointPublicationData value) {
    if (_disposed || peer.state != PeerConnectionState.ready) return;
    final chunks = chunkCheckpoint(value.bytes,
        term: value.coordinatorTerm,
        sequence: operation.sequence,
        requiresApplicationValidation: value.validationRequirement ==
            CheckpointApplicationValidationRequirement.required);
    final messageId = peer._core.messageIdAllocator!.allocate();
    final hop = _LiveCheckpointHop(
        peer: peer,
        messageId: messageId,
        chunks: chunks,
        operation: operation,
        publication: value.handle);
    _checkpointHops[_hopKey(peer, messageId)] = hop;
    group.checkpointOperationStarted(value.handle, peer.peerId);
    unawaited(() async {
      try {
        final results = await peer._core.submitAckRequiredCheckpoint(
            chunks: chunks,
            messageId: messageId,
            nowMs: peer._core.monotonicNowMs);
        if (results.any(
            (result) => result != TransportWriteState.submittedToPlatform)) {
          _logCheckpointFailure(
              peer, hop, CheckpointPeerResult.sessionTerminated);
        }
      } on Object {
        if (peer.state == PeerConnectionState.disconnected) {
          _finishCheckpoint(peer, hop, CheckpointPeerResult.sessionTerminated);
        }
      }
    }());
  }

  void _logCheckpointFailure(PeerConnection peer, _LiveCheckpointHop hop,
      CheckpointPeerResult result) {
    if (peer.state == PeerConnectionState.disconnected) {
      _finishCheckpoint(peer, hop, result);
    }
  }

  void _finishCheckpoint(PeerConnection peer, _LiveCheckpointHop hop,
      CheckpointPeerResult result) {
    final key = _hopKey(peer, hop.messageId);
    if (_checkpointHops.remove(key) == null) return;
    group.checkpointOperationFinished(hop.publication, peer.peerId, result,
        checkpointSequence: hop.operation.sequence);
    final queue = _checkpointQueues[peer.peerId];
    final next = queue?.completeInFlight();
    if (next != null) {
      final value = _checkpointPublications[next.publicationId];
      if (value != null) _sendCheckpoint(peer, next, value);
    } else if (queue != null && !queue.hasPending && queue.inFlight == null) {
      _checkpointQueues.remove(peer.peerId);
    }
    _pruneCheckpointPublications();
  }

  void _pruneCheckpointPublications() {
    final retained = <int>{
      if (_checkpointPublications.isNotEmpty) _checkpointPublications.keys.last,
      ..._checkpointHops.values.map((hop) => hop.publication.publicationId),
      for (final queue in _checkpointQueues.values)
        if (queue.inFlight?.publicationId != null)
          queue.inFlight!.publicationId!,
    };
    _checkpointPublications.removeWhere((id, _) => !retained.contains(id));
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
        case FrameType.coordinatorCheckpoint:
          await _receiveCoordinatorCheckpoint(peer, frame);
        default:
          return;
      }
    } on LpcException catch (error) {
      // A control send may lose the READY race to normal reconnect handling.
      // The new generation re-advertises GROUP_INFO; it is not a malformed
      // authenticated group frame and must not trigger a second disconnect.
      if (error.code == LpcErrorCode.transportClosed ||
          error.code == LpcErrorCode.invalidState) {
        logger(
            'group frame ignored peer=${peer.peerId} type=${frame.type} message=${frame.messageId} error=${error.code}');
        return;
      }
      logger(
          'group frame protocol failure peer=${peer.peerId} type=${frame.type} message=${frame.messageId} error=${error.code}');
      await peer.disconnect();
    } on Object catch (error) {
      // Group routing violations are authenticated peer protocol violations;
      // do not leave the same connection accepting later group traffic.
      logger(
          'group frame exception peer=${peer.peerId} type=${frame.type} message=${frame.messageId} error=$error');
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
    logger(
        'group info peer=${peer.peerId} localGroup=${_debugId(local.groupId.bytes)} localMembers=${local.members.length} remoteGroup=${_debugId(info.info.groupId.bytes)} remoteMembers=${info.info.members.length} decision=${evaluation.decision} winner=${evaluation.winner == null ? 'none' : _debugId(evaluation.winner!.groupId.bytes)} localCoordinator=${group.isCoordinator}');
    if (evaluation.decision == GroupMergeDecision.sameGroup) {
      if (_sameMembers(local.members, info.info.members)) return;
      // Same-GroupId views are split-brain membership views, not a merge.
      // The coordinator with the newer committed term reconciles the union
      // through MEMBERSHIP_SNAPSHOT (Section 10.10/31.7); a member waits for
      // that authenticated coordinator snapshot instead of committing from
      // an unacknowledged GROUP_INFO advertisement.
      if (!group.isCoordinator ||
          info.coordinatorTerm > group.coordinatorTerm) {
        return;
      }
      final members = _mergeMembers(local.members, info.info.members);
      if (members.length > group.config.maxPeers) {
        group.reportError(LpcErrorCode.groupFull,
            peerId: peer.peerId,
            diagnostic:
                'same-GroupId membership reconciliation exceeds capacity');
        return;
      }
      final term = max(group.coordinatorTerm, info.coordinatorTerm) + 1;
      group.commitMembership(members,
          coordinator: group.localPeerId, coordinatorTerm: term);
      await _publishMembershipSnapshot(members, term, sameGroupOnly: true);
      await _publishGroupInfo();
      return;
    }
    if (evaluation.decision == GroupMergeDecision.merge &&
        evaluation.winner?.groupId != local.groupId) {
      // The losing side can receive GROUP_INFO before the winning side has
      // observed this group's creation (the normal application invite race).
      // Echo the current local view so the deterministic winner has the
      // authenticated GROUP_INFO pair required to authorize GROUP_MERGE.
      await _sendGroupInfo(peer);
    }
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
    await _reconcileRetainedSameGroupViews();
    // A merge changes the authoritative GroupId, membership, and coordinator
    // view for every authenticated group bootstrap link. Refresh the other
    // links as well; otherwise a later GROUP_MERGE on one of them can be
    // rejected against stale retained GROUP_INFO (Section 31.6.1).
    await _publishGroupInfo(except: peer);
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
    final disposition = _mergeReceiver.receive(payload);
    logger(
        'group merge apply disposition=$disposition localGroup=${_debugId(group.groupId.bytes)} winningGroup=${_debugId(payload.winningGroupId.bytes)} losingGroup=${_debugId(payload.losingGroupId.bytes)} members=${payload.members.length} coordinator=$coordinator term=${payload.newCoordinatorTerm}');
    if (disposition != GroupMergeReceiveDisposition.applied) {
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
    final senderAuthorized = remote != null &&
        remote.info.groupId == payload.winningGroupId &&
        remote.coordinatorPeerId == peer.peerId;
    if (!senderAuthorized) {
      logger(
          'group merge authorization failed peer=${peer.peerId} localGroup=${_debugId(group.groupId.bytes)} winningGroup=${_debugId(payload.winningGroupId.bytes)} losingGroup=${_debugId(payload.losingGroupId.bytes)} retainedGroup=${remote == null ? 'none' : _debugId(remote.info.groupId.bytes)} retainedCoordinator=${remote?.coordinatorPeerId}');
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    if (group.groupId != payload.losingGroupId &&
        group.groupId != payload.winningGroupId) {
      // A valid merge can cross an already-committed concurrent merge. The
      // authenticated sender and canonical payload are still useful state,
      // but this operation no longer addresses the receiver's current GroupId
      // and cannot be applied. ACK and republish instead of tearing down a
      // healthy link; the fresh GROUP_INFO will drive the deterministic merge
      // winner to convergence.
      logger(
          'group merge stale concurrent view peer=${peer.peerId} localGroup=${_debugId(group.groupId.bytes)} winningGroup=${_debugId(payload.winningGroupId.bytes)} losingGroup=${_debugId(payload.losingGroupId.bytes)} localTerm=${group.coordinatorTerm} term=${payload.newCoordinatorTerm}');
      await peer._core.submitAck(frame.messageId);
      await _publishGroupInfo();
      return;
    }
    // Concurrent merges can leave an ACK-required merge in flight after this
    // runtime has already committed a different or newer authoritative view.
    // It is authenticated stale state, not peer corruption: ACK it so the
    // sender can retire the operation, then advertise the current view for
    // normal reconciliation (Section 31.6.1).
    if (payload.newCoordinatorTerm <= group.coordinatorTerm ||
        group.groupId == payload.winningGroupId) {
      logger(
          'group merge stale peer=${peer.peerId} localGroup=${_debugId(group.groupId.bytes)} localTerm=${group.coordinatorTerm} winningGroup=${_debugId(payload.winningGroupId.bytes)} losingGroup=${_debugId(payload.losingGroupId.bytes)} term=${payload.newCoordinatorTerm}');
      await peer._core.submitAck(frame.messageId);
      await _publishGroupInfo();
      return;
    }
    if (group.groupId != payload.losingGroupId) {
      logger(
          'group merge rejected current group differs peer=${peer.peerId} localGroup=${_debugId(group.groupId.bytes)} winningGroup=${_debugId(payload.winningGroupId.bytes)} losingGroup=${_debugId(payload.losingGroupId.bytes)} localTerm=${group.coordinatorTerm} term=${payload.newCoordinatorTerm}');
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    _applyGroupMerge(payload, coordinator: peer.peerId);
    await peer._core.submitAck(frame.messageId);
    await _publishGroupInfo();
  }

  Future<void> _publishGroupInfo({PeerConnection? except}) async {
    for (final candidate in _frameSubscriptions.keys.toList()) {
      if (identical(candidate, except)) continue;
      await _sendGroupInfo(candidate);
    }
  }

  Future<void> _reconcileRetainedSameGroupViews() async {
    if (_disposed || !group.isCoordinator) return;
    for (final entry in _remoteGroupInfo.entries.toList()) {
      final remote = entry.value;
      if (remote.info.groupId != group.groupId ||
          _sameMembers(group.members, remote.info.members)) {
        continue;
      }
      final members = _mergeMembers(group.members, remote.info.members);
      if (members.length > group.config.maxPeers) {
        group.reportError(LpcErrorCode.groupFull,
            peerId: entry.key.peerId,
            diagnostic:
                'same-GroupId membership reconciliation exceeds capacity');
        continue;
      }
      final term = max(group.coordinatorTerm, remote.coordinatorTerm) + 1;
      group.commitMembership(members,
          coordinator: group.localPeerId, coordinatorTerm: term);
      await _publishMembershipSnapshot(members, term, sameGroupOnly: true);
    }
  }

  Future<void> _publishMembershipSnapshot(
      Iterable<GroupMember> members, int coordinatorTerm,
      {bool sameGroupOnly = false}) async {
    final payload = MembershipSnapshot(
        groupId: group.groupId,
        coordinatorTerm: coordinatorTerm,
        members: members.toList(growable: false));
    final encoded = await payload.encode();
    for (final peer in _frameSubscriptions.keys.toList()) {
      if (peer.state != PeerConnectionState.ready) continue;
      if (sameGroupOnly &&
          _remoteGroupInfo[peer]?.info.groupId != group.groupId) {
        // A singleton/newly joining peer must receive GROUP_MERGE before a
        // membership snapshot for the winning GroupId.
        continue;
      }
      logger(
          'group membership snapshot send peer=${peer.peerId} group=${_debugId(group.groupId.bytes)} term=$coordinatorTerm members=${members.map((member) => member.peerId).join(',')}');
      try {
        final result = await peer._core.submitAckRequiredFrame(
            type: FrameType.membershipSnapshot,
            payload: encoded,
            nowMs: peer._core.monotonicNowMs);
        logger(
            'group membership snapshot submitted peer=${peer.peerId} result=$result');
      } on LpcException catch (error) {
        if (error.code != LpcErrorCode.transportClosed &&
            error.code != LpcErrorCode.invalidState) {
          rethrow;
        }
      }
    }
  }

  Future<void> _receiveMembershipSnapshot(
      PeerConnection peer, LpcFrame frame) async {
    if (frame.flags != 1) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final snapshot = await MembershipSnapshot.decode(frame.payload);
    logger(
        'group membership snapshot receive peer=${peer.peerId} local=${group.localPeerId} localGroup=${_debugId(group.groupId.bytes)} localTerm=${group.coordinatorTerm} localCoordinator=${group.coordinatorPeerId} snapshotGroup=${_debugId(snapshot.groupId.bytes)} snapshotTerm=${snapshot.coordinatorTerm} members=${snapshot.members.map((member) => member.peerId).join(',')}');
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
    await _publishGroupInfo();
  }

  Future<void> _receiveCoordinatorCheckpoint(
      PeerConnection peer, LpcFrame frame) async {
    if (frame.flags != 1 ||
        group.config.coordinatorCheckpointing == false ||
        group.isCoordinator ||
        peer.peerId != group.coordinatorPeerId) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final chunk = CoordinatorCheckpointChunk.decode(frame.payload);
    final receiver = _checkpointReceivers[peer] ??= CheckpointReceiver();
    final result = await receiver.add(frame.messageId, chunk,
        validate: (checkpoint) =>
            group.validateCoordinatorCheckpoint(checkpoint.bytes),
        commit: (checkpoint) {
          if (checkpoint.term < group.coordinatorTerm) {
            throw const LpcException(LpcErrorCode.protocolMismatch);
          }
          group.commitCoordinatorCheckpoint(checkpoint.bytes,
              coordinator: peer.peerId,
              checkpointSequence: checkpoint.sequence);
        });
    if (result.acknowledgmentMessageId != null) {
      await peer._core.submitAck(frame.messageId);
    }
  }

  Future<void> _receiveReliable(PeerConnection peer, LpcFrame frame) async {
    final chunk = GroupReliableChunk.decode(frame.payload);
    final expectedAck = chunk.deliveryMode == DeliveryMode.reliableAcked;
    if ((frame.flags & 1 != 0) != expectedAck) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final complete = _reassemblers[peer]!.add(frame.messageId, chunk);
    if (complete == null) return;
    logger(
        'group receive complete peer=${peer.peerId} source=${complete.sourcePeerId} destination=${complete.destinationPeerId} message=${_debugId(complete.groupMessageId.bytes)} mode=${complete.deliveryMode} bytes=${complete.bytes.length} coordinator=${group.isCoordinator}');
    if (group.isCoordinator) {
      final destination = _readyPeer(complete.destinationPeerId);
      logger(
          'group coordinator admission source=${complete.sourcePeerId} destination=${complete.destinationPeerId} message=${_debugId(complete.groupMessageId.bytes)} destinationReady=${complete.destinationPeerId == group.localPeerId || destination != null} destinationPeer=${destination?.peerId}');
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
      logger(
          'group destination deliver peer=${peer.peerId} source=${complete.sourcePeerId} destination=${complete.destinationPeerId} message=${_debugId(complete.groupMessageId.bytes)}');
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
    logger(
        'group delivery ack peer=${peer.peerId} source=${ack.sourcePeerId} destination=${ack.destinationPeerId} message=${_debugId(ack.groupMessageId.bytes)} state=$state genericAck=${result.requiresGenericAck}');
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
    logger(
        'group coordinator actions sourcePeer=${sourcePeer?.peerId} sourceHopAck=${actions.sourceHopGenericAckMessageId} local=${actions.deliverLocally == null ? null : _debugId(actions.deliverLocally!.groupMessageId.bytes)} localState=${actions.localSourceState} deliveryAck=${actions.deliveryAck == null ? null : _debugId(actions.deliveryAck!.groupMessageId.bytes)} relayStatus=${actions.relayStatus == null ? null : _debugId(actions.relayStatus!.groupMessageId.bytes)} forward=${actions.forward == null ? null : _debugId(actions.forward!.groupMessageId.bytes)}');
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
    logger(
        'group forward source=${operation.sourcePeerId} destination=${operation.destinationPeerId} message=${_debugId(operation.groupMessageId.bytes)} ready=${destination != null} peer=${destination?.peerId}');
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
    logger(
        'group submit hop peer=${peer.peerId} source=$source destination=$destination message=${_debugId(groupMessageId.bytes)} pairwise=${_debugId(messageId)} finalHop=$finalHop mode=$mode chunks=${chunks.length} bytes=${bytes.length} state=${peer.state}');
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
        logger(
            'group submit hop failed peer=${peer.peerId} message=${_debugId(groupMessageId.bytes)} pairwise=${_debugId(messageId)} result=$result state=${peer.state}');
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
    final checkpoint = _checkpointHops.remove(_hopKey(peer, messageId));
    if (checkpoint != null) {
      group.checkpointOperationFinished(checkpoint.publication, peer.peerId,
          CheckpointPeerResult.acknowledged,
          checkpointSequence: checkpoint.operation.sequence);
      final queue = _checkpointQueues[peer.peerId];
      final next = queue?.completeInFlight();
      if (next != null) {
        final value = _checkpointPublications[next.publicationId];
        if (value != null) _sendCheckpoint(peer, next, value);
      } else if (queue != null && !queue.hasPending && queue.inFlight == null) {
        _checkpointQueues.remove(peer.peerId);
      }
      _pruneCheckpointPublications();
      return;
    }
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

  Future<void> _retransmitCheckpointsFor(PeerConnection peer) async {
    for (final hop in _checkpointHops.values
        .where((hop) => identical(hop.peer, peer))
        .toList()) {
      final retry =
          peer._core.ackRetention.retransmitOneAfterResume(hop.messageId);
      if (retry == AckTimeoutResult.retransmitWholeOperation) {
        try {
          for (final chunk in hop.chunks) {
            final submitted = await peer._core.submitEncrypted(
                FrameType.coordinatorCheckpoint, chunk.encode(),
                flags: 1, messageId: hop.messageId);
            if (submitted != TransportWriteState.submittedToPlatform) {
              throw const LpcException(LpcErrorCode.transportClosed);
            }
          }
          peer._core.ackRetention.finalFrameSubmitted(hop.messageId,
              nowMs: peer._core.monotonicNowMs);
        } on Object {
          // Transport loss leaves the retained operation for the next READY
          // generation; the timeout policy remains authoritative.
        }
      } else if (retry == AckTimeoutResult.terminalAckTimeout) {
        _finishCheckpoint(peer, hop, CheckpointPeerResult.ackTimeout);
      }
    }
  }

  Future<void> _onPeerReconnected(PeerConnection peer) async {
    // GROUP_INFO is current-state, not a retained operation. Send it again
    // after every READY generation so a previous handoff race cannot leave
    // a peer with only a pre-merge view.
    await _sendGroupInfo(peer);
    await _retransmitHopsFor(peer);
    await _retransmitCheckpointsFor(peer);
    checkpointPeerReady(peer.peerId);
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
    for (final hop in _checkpointHops.values
        .where((hop) => identical(hop.peer, peer))
        .toList()) {
      _finishCheckpoint(peer, hop, CheckpointPeerResult.sessionTerminated);
    }
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
    for (final hop in _checkpointHops.values.toList()) {
      final peer = hop.peer;
      if (peer.state != PeerConnectionState.ready) continue;
      final result = peer._core.ackRetention
          .onTimer(hop.messageId, nowMs: peer._core.monotonicNowMs);
      if (result == AckTimeoutResult.ignored) continue;
      if (result == AckTimeoutResult.retransmitWholeOperation) {
        try {
          for (final chunk in hop.chunks) {
            final submitted = await peer._core.submitEncrypted(
                FrameType.coordinatorCheckpoint, chunk.encode(),
                flags: 1, messageId: hop.messageId);
            if (submitted != TransportWriteState.submittedToPlatform) {
              throw const LpcException(LpcErrorCode.transportClosed);
            }
          }
          peer._core.ackRetention.finalFrameSubmitted(hop.messageId,
              nowMs: peer._core.monotonicNowMs);
        } on Object {
          // Transport loss pauses ACK retention; RESUME retries from chunk 0.
        }
      } else if (result == AckTimeoutResult.terminalAckTimeout) {
        _finishCheckpoint(peer, hop, CheckpointPeerResult.ackTimeout);
      }
    }
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
    _checkpointReceivers[peer]?.onTransportGenerationLost();
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
    _checkpointHops.clear();
    _checkpointQueues.clear();
    _checkpointPublications.clear();
    _checkpointReceivers.clear();
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

class _CheckpointPublicationData {
  _CheckpointPublicationData(this.handle, this.bytes, this.coordinatorTerm,
      this.validationRequirement);
  final CoordinatorCheckpointHandle handle;
  final Uint8List bytes;
  final int coordinatorTerm;
  final CheckpointApplicationValidationRequirement validationRequirement;
}

class _LiveCheckpointHop {
  _LiveCheckpointHop({
    required this.peer,
    required this.messageId,
    required this.chunks,
    required this.operation,
    required this.publication,
  });
  final PeerConnection peer;
  final List<int> messageId;
  final List<CoordinatorCheckpointChunk> chunks;
  final CheckpointReplicationOperation operation;
  final CoordinatorCheckpointHandle publication;
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

// GroupId and GroupMessageId intentionally do not expose a toString()
// override. Diagnostics still need stable correlation keys, and these IDs are
// not secret material, so render their bytes explicitly in runtime logs.
String _debugId(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

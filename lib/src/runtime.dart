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
import 'mesh_backend_connection.dart';
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
import 'protocol/mesh_relay.dart';
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
    super.monotonicTimestampMs,
    this.discoveryEndpointId,
  );
  final String discoveryEndpointId;
}

/// Terminal outcome of a bounded automatic nearby-known-peer probe.
class KnownPeerProbeFailed extends RuntimeEvent {
  const KnownPeerProbeFailed(
    super.monotonicTimestampMs,
    this.discoveryEndpointId,
    this.error,
  );
  final String discoveryEndpointId;
  final LpcException error;
}

class UnknownPeerIdentified extends RuntimeEvent {
  const UnknownPeerIdentified(
    super.monotonicTimestampMs,
    this.connection, {
    this.discoveryEndpointId,
  });

  /// The authenticated connection used for this bounded automatic probe.
  /// It is emitted before the Runtime releases its negative known-peer probe
  /// ownership, so applications can inspect authenticated HELLO metadata.
  /// Receiving this event does not grant application relationship authority.
  final PeerConnection connection;
  PeerId get peerId => connection.peerId;
  final String? discoveryEndpointId;
}

class KnownPeerConnected extends RuntimeEvent {
  const KnownPeerConnected(
    super.monotonicTimestampMs,
    this.connection, {
    this.discoveryEndpointId,
  });
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
        LpcErrorCode.invalidState,
        'no peer verification is pending',
      );
    }
    final confirm = _confirmVerification!;
    _confirmVerification = null;
    await confirm(accepted);
  }

  void _verificationRequired(
    PeerId peerId,
    String sas,
    Future<void> Function(bool) confirm,
  ) {
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
    super.monotonicTimestampMs,
    List<int> sessionId,
    this.transport,
  ) : sessionId = List.unmodifiable(sessionId);
  final List<int> sessionId;
  final TransportType transport;
}

class PeerDisconnected extends PeerConnectionEvent {
  const PeerDisconnected(super.monotonicTimestampMs);
}

/// Public authenticated point-to-point connection. Group routing remains the
/// separate Section 43 owner; this class exposes the direct Section 36 path.
class PeerConnection {
  PeerConnection._(
    this._core, {
    required this.securityLevel,
    List<int> remoteApplicationMetadata = const [],
    void Function(PeerConnection)? onDisconnected,
    void Function(PeerConnection)? onReconnecting,
    void Function(PeerConnection, LpcFrame)? onMeshFrame,
  }) : remoteApplicationMetadata = List.unmodifiable(remoteApplicationMetadata),
       _onDisconnected = onDisconnected,
       _onReconnecting = onReconnecting,
       _onMeshFrame = onMeshFrame {
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
        _events.add(
          PeerReconnected(
            _core.monotonicNowMs,
            _core.sessionId,
            _core.backend.transportType,
          ),
        );
      }
    });
  }
  final PeerConnectionCore _core;
  final SecurityLevel securityLevel;

  /// Authenticated application metadata received in the peer's HELLO.
  final List<int> remoteApplicationMetadata;
  final void Function(PeerConnection)? _onDisconnected;
  final void Function(PeerConnection)? _onReconnecting;
  final void Function(PeerConnection, LpcFrame)? _onMeshFrame;
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
  bool get isRelayed => activeTransport == TransportType.meshRelay;
  PeerId? get relayPeerId => _core.backend is MeshBackendConnection
      ? (_core.backend as MeshBackendConnection).relayPeerId
      : null;
  int get negotiatedMinor => _core.negotiatedMinor;

  /// Negotiated link MTU for transports that expose one (currently GATT).
  int? get negotiatedMtu => switch (_core.backend) {
    GattBackendConnection connection => connection.negotiatedMtu,
    _ => null,
  };
  Stream<PeerMessageReceived> get messages => _messages.stream;
  Stream<PeerRealtimeDatagramReceived> get realtimeMessages =>
      _realtimeMessages.stream;
  Stream<PeerConnectionEvent> get events => _events.stream;
  Stream<LpcFrame> get groupFrames => _groupFrames.stream;
  SendHandle send(
    List<int> bytes, {
    SendOptions options = const SendOptions(),
  }) {
    if (_disconnected || _core.state != PeerConnectionState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    if (options.deliveryMode == DeliveryMode.realtimeLatest) {
      throw const LpcException(
        LpcErrorCode.invalidState,
        'use sendRealtime for REALTIME_LATEST',
      );
    }
    final allocator = _core.messageIdAllocator;
    if (allocator == null) {
      throw const LpcException(
        LpcErrorCode.invalidState,
        'missing MessageId allocator',
      );
    }
    return _core.submitReliableDataWithHandle(
      bytes: bytes,
      deliveryMode: options.deliveryMode,
      priority: options.priority,
      messageId: allocator.allocate(),
      nowMs: _core.monotonicNowMs,
    );
  }

  RealtimeSendHandle sendRealtime(
    int channelId,
    List<int> bytes, {
    RealtimeOptions options = const RealtimeOptions(),
  }) {
    if (_disconnected || options.expiryMs < 1) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    final datagram = _core.allocateRealtimeDatagram(
      channelId: channelId,
      senderTick: options.senderTick,
      bytes: bytes,
    );
    final controller = RealtimeSendHandleController.queued(
      onCancel: () => _queuedRealtime.remove(channelId),
    );
    final previous = _queuedRealtime[channelId];
    _queuedRealtime[channelId] = _QueuedRealtime(
      datagram: datagram,
      expiresAtMs: _core.monotonicNowMs + options.expiryMs,
      controller: controller,
    );
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

  /// Publishes the reconnect completion at the same point the runtime commits
  /// a RESUME generation.  Normally the 50 ms lifecycle timer observes this
  /// transition, but a crossed central/peripheral handoff can commit READY
  /// while that timer is busy processing the competing candidate.  In that
  /// case the core state is READY but upper layers remain stuck on their last
  /// RECONNECTING snapshot.  The runtime calls this after [completeResume]
  /// commits state; the flag makes the normal timer path and this explicit
  /// path mutually exclusive.
  void _resumeCommitted() {
    if (_disconnected || _core.state != PeerConnectionState.ready) return;
    if (!_reconnectNotified) return;
    _reconnectNotified = false;
    _events.add(
      PeerReconnected(
        _core.monotonicNowMs,
        _core.sessionId,
        _core.backend.transportType,
      ),
    );
  }

  void _onFrame(LpcFrame frame) {
    if (frame.type == FrameType.meshAdvert ||
        frame.type == FrameType.meshFrame) {
      _onMeshFrame?.call(this, frame);
      return;
    }
    if (frame.type == FrameType.groupReliable ||
        frame.type == FrameType.groupRealtimeDatagram ||
        frame.type == FrameType.groupDeliveryAck ||
        frame.type == FrameType.groupRelayStatus ||
        frame.type == FrameType.groupInfo ||
        frame.type == FrameType.groupMerge ||
        frame.type == FrameType.membershipSnapshot ||
        // Coordinator checkpoints are consumed by the group route transport
        // just like membership and reliable group frames. Keeping this in the
        // shared group stream is required for mobile/macOS checkpoint
        // validation; omitting it makes the sender wait until its bounded
        // publication timeout while ordinary STATE_UPDATE traffic still
        // appears healthy.
        frame.type == FrameType.coordinatorCheckpoint) {
      _groupFrames.add(frame);
      return;
    }
    if (frame.type == FrameType.realtimeDatagram) {
      final datagram = _core.receiveRealtime(frame);
      if (datagram != null) {
        _realtimeMessages.add(
          PeerRealtimeDatagramReceived(
            datagram.channelId,
            datagram.senderTick,
            datagram.bytes,
          ),
        );
      }
      return;
    }
    if (frame.type != FrameType.data) return;
    unawaited(() async {
      try {
        final result = await _core.receiveDataFrame(frame);
        final delivered = result.delivered;
        if (delivered != null) {
          final message = PeerMessageReceived(
            delivered.bytes,
            delivered.deliveryMode,
          );
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
          'inbound data frame failed peer=${_core.remotePeerId} error=$error',
        );
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
            : SendState.failed,
      );
    } on Object {
      queued.controller.complete(SendState.failed);
    } finally {
      _submittingRealtime = false;
      if (!_disconnected) unawaited(_pollRealtimeQueue());
    }
  }
}

class _QueuedRealtime {
  const _QueuedRealtime({
    required this.datagram,
    required this.expiresAtMs,
    required this.controller,
  });
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
  }) : _startAdvertising = startAdvertising,
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
  List<PeerConnection> peers() => List.unmodifiable(
    _peers.values.toList()
      ..sort((a, b) => _comparePeerIdBytes(a.peerId, b.peerId)),
  );

  void _peerConnected(
    PeerConnection connection, {
    String? discoveryEndpointId,
  }) {
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
    _events.add(
      HostPeerConnected(connection, discoveryEndpointId: discoveryEndpointId),
    );
  }

  void _peerVerificationRequired(
    ConnectionAttempt attempt,
    PeerId peerId,
    String sas,
  ) {
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
        LpcErrorCode.invalidState,
        'no peer verification is pending',
      );
    }
    await attempt.confirmPeerVerification(accepted);
  }

  /// Sends directly to one authenticated peer admitted by this explicit-role
  /// host. GroupSession routing is intentionally not used by this API.
  SendHandle send(
    PeerId peerId,
    List<int> bytes, {
    SendOptions options = const SendOptions(),
  }) {
    if (_closed) throw const LpcException(LpcErrorCode.invalidState);
    final peer = _peers[peerId];
    if (peer == null) {
      throw const LpcException(LpcErrorCode.destinationUnavailable);
    }
    return peer.send(bytes, options: options);
  }

  BroadcastHandle broadcast(
    List<int> bytes, {
    SendOptions options = const SendOptions(),
  }) {
    if (_closed) throw const LpcException(LpcErrorCode.invalidState);
    return BroadcastHandle({
      for (final peer in peers())
        peer.peerId: peer.send(bytes, options: options),
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
  DiscoverySession({
    Future<void> Function()? stopPlatformScan,
    Future<void> Function()? onStopped,
    DateTime Function()? now,
    this.endpointLostAfter = const Duration(seconds: 5),
  }) : _stopPlatformScan = stopPlatformScan ?? _noOp,
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
  RuntimeConfig config,
  HandshakeTrustMode trustMode,
) {
  if (trustMode != HandshakeTrustMode.knownPeer) return null;
  final peer = config.expectedPeerId;
  return peer != null
      ? ExpectExactPeer(peer)
      : AllowlistedPeers(config.allowedPeerIds);
}

void _validateTrustCredentialsFor(
  RuntimeConfig config,
  HandshakeTrustMode trustMode,
) {
  if (trustMode == HandshakeTrustMode.psk32 && config.psk32?.length != 32) {
    throw const LpcException(
      LpcErrorCode.invalidState,
      'PSK_32 requires a 32-byte psk32',
    );
  }
  if (trustMode == HandshakeTrustMode.knownPeer &&
      config.expectedPeerId == null &&
      config.allowedPeerIds.isEmpty) {
    throw const LpcException(
      LpcErrorCode.invalidState,
      'KNOWN_PEER requires a peer policy',
    );
  }
}

class _GattReconnect {
  _GattReconnect(
    this.peer,
    this.endpointId,
    this.schedule, {
    this.discoveryCandidate = false,
  });
  final PeerConnection peer;
  final String endpointId;
  final ReconnectSchedule schedule;
  // A discovery candidate is a fresh endpoint observed while the last
  // authenticated link was locally peripheral-side. It is not the endpoint
  // being retried by the normal central-side schedule, so a failed candidate
  // must be released and rediscovered later instead of being retried forever
  // against a possibly unrelated nearby device.
  final bool discoveryCandidate;
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
  _GattLink(
    this.endpointId,
    this.localCanInitiateReconnect, {
    this.connectionGeneration,
    this.candidateStartedAtMs,
    this.readyAtMs,
  });
  String endpointId;
  bool localCanInitiateReconnect;
  int? connectionGeneration;
  int? candidateStartedAtMs;
  int? readyAtMs;
}

/// Returns whether a native disconnect can belong to the currently owned
/// physical link. Platform backends that do not expose generations retain the
/// wildcard behavior used by [PlatformGattConnectionBinding].
@visibleForTesting
bool gattConnectionGenerationMatches(
  int? eventGeneration,
  int? ownerGeneration,
) {
  return ownerGeneration == null ||
      eventGeneration == null ||
      eventGeneration == ownerGeneration;
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
    this.config,
    this.localPeerId,
    this._platformBleBackend,
    this._identity,
  ) : _state = RuntimeState.ready {
    _platformSubscription = _platformBleBackend?.events.listen(
      _onPlatformEvent,
    );
    _mesh = _MeshController(this);
  }
  final RuntimeConfig config;
  final PeerId localPeerId;
  final PlatformBleBackend? _platformBleBackend;
  final LocalIdentity? _identity;
  final TofuIdentityStore _tofuStore = TofuIdentityStore();
  StreamSubscription<PlatformBleEvent>? _platformSubscription;
  final Map<String, ConnectionAttempt> _attempts = {};
  static const _connectionRequestTimeoutMs = 10000;
  final Map<String, Timer> _connectionAttemptTimers = <String, Timer>{};
  final Map<String, PlatformGattConnectionBinding> _gattBindings = {};
  // A logical PeerConnection can finish closing before the native GATT stack
  // has released its client handle. Keep the endpoint in this short-lived
  // teardown state so a scan callback cannot immediately start a new known
  // peer probe on the stale physical link.
  final Set<String> _closingGattEndpoints = <String>{};
  final Map<String, Future<void>> _gattCloseOperations =
      <String, Future<void>>{};
  // A native close can cause a delayed disconnect callback on both sides of
  // the physical link. Remember that the current generation has already had
  // its idempotent native close requested so a late echoed callback cannot
  // start a close ping-pong between two runtimes.
  final Set<String> _nativeCloseRequestedEndpoints = <String>{};
  static const _maxNativeCloseGuards = 256;

  void _rememberNativeCloseRequested(
    String endpointId, {
    int? connectionGeneration,
  }) {
    _nativeCloseRequestedEndpoints.add(
      '$endpointId:${connectionGeneration ?? 'unknown'}',
    );
    while (_nativeCloseRequestedEndpoints.length > _maxNativeCloseGuards) {
      _nativeCloseRequestedEndpoints.remove(
        _nativeCloseRequestedEndpoints.first,
      );
    }
  }

  // Android can deliver more than one readiness callback for a physical GATT
  // link (for example, repeated CCCD writes).  Serialize handshake startup
  // per endpoint so a duplicate platform event cannot replace the first
  // binding with a competing logical session.
  final Set<String> _startingGattEndpoints = <String>{};
  // Keep the platform-ready metadata with the Dart binding. Peripheral-side
  // endpoint IDs are opaque (for example, `server-1` on CoreBluetooth), so a
  // later fragment is otherwise impossible to reattach to a fresh handshake
  // if the old handshake task was lost during a runtime/app lifecycle race.
  final Map<String, PlatformGattConnected> _gattConnectedEvents =
      <String, PlatformGattConnected>{};
  // Discovery advertisements identify only a transport candidate. Preserve
  // when each physical candidate began so duplicate arbitration can
  // distinguish an overlapping race from a later speculative probe. This is
  // local lifecycle bookkeeping; it is never used as PeerId identity or sent
  // on the wire.
  final Map<String, int> _gattCandidateStartedAtMs = <String, int>{};
  final Set<String> _recoveringOrphanedGattEndpoints = <String>{};
  final Map<String, _GattReconnect> _gattReconnects = {};
  final Map<String, PeerConnection> _gattPeersByEndpoint = {};
  final Map<PeerConnection, Timer> _gattReconnectExpiryTimers = {};
  final Map<PeerConnection, Timer> _unknownPeerReleaseTimers = {};
  // A user-visible friend acceptance flow can require leaving the current
  // game screen and opening the Friends tab. Keep an authenticated unknown
  // connection long enough for that explicit decision; the timer is still
  // bounded, and releasePeerRetention/HostSession ownership can close it
  // earlier. A ten-second window was routinely too short on iOS/macOS when
  // CoreBluetooth was still updating the nearby list.
  static const _unknownPeerHandoffTimeout = Duration(seconds: 30);
  final Map<PeerConnection, _GattLink> _gattLinks = {};
  // A peripheral-side link has no local connectable endpoint. Keep the
  // logical peer eligible while the shared scan is running so either device
  // can produce the next physical candidate; upper layers never choose a
  // reconnect initiator.
  final Set<PeerConnection> _reconnectWaitingForDiscovery = <PeerConnection>{};
  final Map<PeerConnection, ReconnectSchedule> _reconnectWaitingSchedules =
      <PeerConnection, ReconnectSchedule>{};
  final Map<PeerConnection, List<int>> _connectionRanks = {};
  final Set<PeerConnection> _peers = <PeerConnection>{};
  // Native GATT callbacks expose a platform-only physical correlation key so
  // an authenticated inbound server link can suppress a redundant central
  // probe for that same device. This is not protocol identity: the map is
  // populated only after HELLO/AUTH and never replaces PeerId arbitration.
  final Map<String, PeerConnection> _authenticatedPeerByPhysicalEndpoint =
      <String, PeerConnection>{};
  final Set<PeerId> _directRetainedPeers = <PeerId>{};
  final Set<PeerId> _knownRetainedPeers = <PeerId>{};
  // Fixture-only topology injection: deny a direct physical edge after
  // authenticating PeerId while leaving friendship intact. This lets a
  // co-located three-device test prove A-B-C relay without RF shielding.
  // Never use a BLE address/DiscoveryEndpointId as the identity decision.
  final Set<PeerId> _blockedDirectPeersForTesting = <PeerId>{};
  final Set<String> _automaticProbeEndpoints = <String>{};
  // Several Android BLE stacks cannot start two LE link procedures from one
  // process concurrently. They report a successful connectGatt invocation
  // for both requests, but the controller leaves one request pending with
  // "cannot start new connection" until the first link is torn down. Keep
  // only the physical link-establishment portion serialized; once the native
  // GATT-connected callback arrives, the next unrelated probe may start while
  // both protocol handshakes proceed independently. This is a platform
  // lifecycle safeguard, not a reconnect direction or PeerId ownership
  // decision.
  String? _automaticGattConnectInFlight;
  Timer? _automaticGattConnectTimer;
  final Set<String> _automaticGattConnectTimedOut = <String>{};
  // An endpoint becomes comparable to an existing logical owner only after
  // its HELLO/AUTH exchange has authenticated the remote PeerId. Keep this
  // short-lived classification so duplicate-link arbitration can suppress a
  // probe for the same peer without suppressing probes for unrelated peers.
  // DiscoveryEndpointId values are ephemeral and are never used as identity.
  final Map<String, PeerId> _authenticatedAutomaticProbePeers =
      <String, PeerId>{};
  // A reconnect candidate must not be assigned to an arbitrary logical peer
  // just because its endpoint was observed while several peers are
  // reconnecting.  Keep the most recent authenticated association as a
  // scheduling hint only; HELLO/AUTH remains authoritative and the hint is
  // never used as PeerId identity or trust.  This is important on macOS and
  // Android, where a scan can report several nearby GATT endpoints while one
  // app is restarting and the platform may deliver them in either order.
  final Map<String, PeerId> _lastAuthenticatedPeerByEndpoint =
      <String, PeerId>{};
  static const _maxLastAuthenticatedEndpointHints = 128;
  final Set<String> _pendingKnownPeerProbes = <String>{};
  final Map<String, Timer> _knownPeerProbeTimers = <String, Timer>{};
  // A winning READY owner can race a probe started from another transient
  // platform endpoint for the same peer. Keep that endpoint suppressed while
  // the logical owner is usable. This is separate from _gattPeersByEndpoint:
  // the observed discovery endpoint is not necessarily the endpoint that
  // delivered the winning inbound connection.
  final Map<String, PeerConnection> _knownProbeSuppressedByOwner =
      <String, PeerConnection>{};
  // A READY duplicate can win after the previous owner has already begun its
  // synchronous disconnect callback.  Keep the displaced discovery endpoint
  // out of the automatic-probe scheduler until the new owner is published;
  // otherwise the callback/scan ordering opens a third link to the same peer
  // and can make the two valid links alternate indefinitely on mobile BLE.
  final Set<String> _duplicateClosingEndpoints = <String>{};
  // A failed native probe can be reported while the endpoint is still
  // advertising. Do not start another GATT allocation on every advertisement
  // (Android vendor stacks can otherwise exhaust their native TCB table).
  final Map<String, int> _knownPeerProbeNotBeforeMs = <String, int>{};
  // After a candidate RESUME is rejected because the remote process has no
  // prior logical session, hand the same endpoint to one fresh normal probe.
  // Without this short-lived guard, the rejection removes the reconnect record
  // while the next advertisement can immediately create another RESUME
  // candidate, producing a candidate/reject/close loop on mobile BLE.
  final Set<String> _freshHandshakeHandoffEndpoints = <String>{};
  final Map<String, PeerId> _freshHandshakeHandoffPeers = <String, PeerId>{};
  final Map<String, Timer> _freshHandshakeHandoffTimers = <String, Timer>{};
  static const _freshHandshakeHandoffTimeout = Duration(seconds: 10);
  static const _knownPeerProbeFailureBackoffMs = 5000;
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
  late final _MeshController _mesh;
  final StreamController<RuntimeEvent> _events =
      StreamController<RuntimeEvent>.broadcast(sync: true);
  late String? _discoveryDisplayName = config.discoveryDisplayName;
  late List<int> _applicationMetadata = List<int>.unmodifiable(
    config.applicationMetadata,
  );
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

  static Future<NearbyRuntime> create({
    RuntimeConfig config = const RuntimeConfig(),
    PeerId? localPeerId,
    IdentityStore? identityStore,
    PlatformBleBackend? platformBleBackend,
  }) async {
    config.validate();
    if (localPeerId != null && identityStore != null) {
      throw ArgumentError('provide localPeerId or identityStore, not both');
    }
    LocalIdentity? identity;
    if (identityStore != null || localPeerId == null) {
      identity = await LocalIdentity.load(
        identityStore ??
            (platformBleBackend == null
                ? InMemoryIdentityStore()
                : PlatformIdentityStore()),
      );
    }
    final peer = localPeerId ?? identity!.peerId;
    if (identity != null && peer != identity.peerId) {
      throw const LpcException(
        LpcErrorCode.invalidState,
        'localPeerId does not match the persistent identity',
      );
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
        'connect adopt endpoint=$discoveryEndpointId automatic=${_automaticProbeEndpoints.contains(discoveryEndpointId)}',
      );
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
        'connect reuse endpoint=$discoveryEndpointId peer=${existingPeer.peerId} state=${existingPeer.state.name}',
      );
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
        unawaited(
          Future<void>.microtask(() {
            unawaited(subscription.cancel());
            attempt._connected(existingPeer);
          }),
        );
      }
      return attempt;
    }
    return _connect(discoveryEndpointId, automaticProbe: false);
  }

  ConnectionAttempt _connect(
    String discoveryEndpointId, {
    required bool automaticProbe,
  }) {
    if (_state != RuntimeState.ready)
      throw const LpcException(LpcErrorCode.invalidState);
    if (!config.enableGatt) {
      throw const LpcException(
        LpcErrorCode.unsupportedCapability,
        'GATT is disabled',
      );
    }
    final backend = _platformBleBackend;
    final identity = _identity;
    if (backend == null || identity == null) {
      throw const LpcException(
        LpcErrorCode.unsupportedCapability,
        'GATT connect requires a platform backend and persistent identity',
      );
    }
    late final ConnectionAttempt attempt;
    attempt = ConnectionAttempt._(discoveryEndpointId, () async {
      _connectionAttemptTimers.remove(discoveryEndpointId)?.cancel();
      _attempts.remove(discoveryEndpointId);
      // Cancellation ends this physical candidate even if the native backend
      // omits its disconnect callback. Do not let a later probe inherit this
      // attempt's start time and be mistaken for an overlapping duplicate.
      _gattCandidateStartedAtMs.remove(discoveryEndpointId);
      await backend.closeGattConnection(discoveryEndpointId);
    });
    if (_attempts.containsKey(discoveryEndpointId)) {
      throw const LpcException(
        LpcErrorCode.invalidState,
        'connection attempt already active',
      );
    }
    _attempts[discoveryEndpointId] = attempt;
    _gattCandidateStartedAtMs.putIfAbsent(
      discoveryEndpointId,
      () => _monotonicMs,
    );
    // Automatic known-peer probes share the bounded reconnect budget. On
    // Android, service discovery and the first encrypted notifications can
    // arrive after the low-level 10-second explicit-request timeout during
    // process restart. If the two timers disagree, a valid late READY is
    // discarded and the same endpoint is needlessly probed again. Keep the
    // public explicit-connect timeout unchanged, but let automatic recovery
    // use the configured reconnect window.
    final requestTimeoutMs = automaticProbe
        ? config.reconnectTimeoutMs
        : _connectionRequestTimeoutMs;
    _connectionAttemptTimers[discoveryEndpointId] = Timer(
      Duration(milliseconds: requestTimeoutMs),
      () {
        if (_attempts[discoveryEndpointId] != attempt) return;
        _connectionAttemptTimers.remove(discoveryEndpointId);
        _attempts.remove(discoveryEndpointId);
        // The timeout owns this attempt, so its candidate timestamp is no
        // longer meaningful even when native GATT teardown is asynchronous.
        _gattCandidateStartedAtMs.remove(discoveryEndpointId);
        attempt._failed(
          const LpcException(
            LpcErrorCode.connectionTimeout,
            'connection request timed out',
          ),
        );
        if (_automaticProbeEndpoints.remove(discoveryEndpointId)) {
          _knownPeerProbeTimers.remove(discoveryEndpointId)?.cancel();
          _startNextKnownPeerProbe();
        }
        _releaseAutomaticGattConnectSlot(discoveryEndpointId);
        unawaited(
          backend.closeGattConnection(discoveryEndpointId).catchError((error) {
            _log(
              'connection timeout cleanup failed endpoint=$discoveryEndpointId error=$error',
            );
          }),
        );
      },
    );
    if (automaticProbe) _automaticProbeEndpoints.add(discoveryEndpointId);
    _log(
      'gatt connect requested endpoint=$discoveryEndpointId automatic=$automaticProbe activeAttempts=${_attempts.length}',
    );
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
        // Android can retain a BluetoothGatt object after the remote app has
        // gone away without delivering onConnectionStateChange. The next
        // authenticated probe then fails immediately with ENDPOINT_BUSY even
        // though Runtime owns no binding for this endpoint. Release that
        // native handle before applying the normal bounded probe backoff;
        // otherwise every later advertisement observes the same stale handle
        // and the peer can never reconnect after an app restart.
        if (_isEndpointBusyError(error)) {
          unawaited(_closeBusyGattEndpoint(backend, discoveryEndpointId));
        }
        _log(
          'gatt connect request failed endpoint=$discoveryEndpointId error=${_asLpcError(error).code.name} detail=$error',
        );
        attempt._failed(_asLpcError(error));
        _connectionAttemptTimers.remove(discoveryEndpointId)?.cancel();
        _attempts.remove(discoveryEndpointId);
        if (_automaticProbeEndpoints.remove(discoveryEndpointId)) {
          _startNextKnownPeerProbe();
        }
        _releaseAutomaticGattConnectSlot(discoveryEndpointId);
      }),
    );
    return attempt;
  }

  void _onPlatformEvent(PlatformBleEvent event) {
    if (event is PlatformEndpointFound) {
      final previous = _lastEndpointLogMs[event.endpointId];
      if (previous == null || _monotonicMs - previous >= 5000) {
        _lastEndpointLogMs[event.endpointId] = _monotonicMs;
        _log(
          'endpoint found endpoint=${event.endpointId} rssi=${event.rssi} name=${event.localName == null ? 'none' : 'present'}',
        );
      }
      final physicalOwner =
          _authenticatedPeerByPhysicalEndpoint[event.endpointId];
      if (physicalOwner != null &&
          (physicalOwner.state == PeerConnectionState.ready ||
              physicalOwner.state == PeerConnectionState.reconnecting)) {
        // The native backend has already authenticated this physical device
        // on an inbound server link. Keep the fast reconnect hint for a
        // reconnecting owner, but do not open an independent known-peer probe
        // that would compete with the selected GATT link.
        _lastAuthenticatedPeerByEndpoint[event.endpointId] =
            physicalOwner.peerId;
        _knownProbeSuppressedByOwner[event.endpointId] = physicalOwner;
      }
      _scheduleReconnectProbe(event.endpointId);
      _scheduleKnownPeerProbe(event.endpointId);
      return;
    }
    if (event is PlatformGattDisconnected) {
      _gattConnectedEvents.remove(event.endpointId);
      _gattCandidateStartedAtMs.remove(event.endpointId);
      _recoveringOrphanedGattEndpoints.remove(event.endpointId);
      _authenticatedAutomaticProbePeers.remove(event.endpointId);
      final binding = _gattBindings[event.endpointId];
      if (binding != null &&
          !binding.acceptsGeneration(event.connectionGeneration)) {
        _log(
          'gatt disconnected ignored stale generation endpoint=${event.endpointId} eventGeneration=${event.connectionGeneration} currentGeneration=${binding.connectionGeneration}',
        );
        return;
      }
      final reconnect = _gattReconnects[event.endpointId];
      _log(
        'gatt disconnected endpoint=${event.endpointId} generation=${event.connectionGeneration} status=${event.status ?? 'none'} hasBinding=${_gattBindings.containsKey(event.endpointId)} hasAttempt=${_attempts.containsKey(event.endpointId)}',
      );
      // A duplicate READY candidate can be closed by the remote runtime while
      // this side is still unwinding the handshake.  Failing the automatic
      // probe here would erase its classification before _startGattHandshake
      // reaches the authenticated READY result.  Let that handshake finish
      // (or fail) and perform the normal probe cleanup there; direct user
      // attempts still fail immediately on transport loss.
      final automaticHandshakeDisconnect =
          _startingGattEndpoints.contains(event.endpointId) &&
          _automaticProbeEndpoints.contains(event.endpointId);
      // The binding normally observes this event too. Keep an endpoint-to-
      // logical-peer index at the runtime boundary so a native disconnect
      // cannot leave an authenticated friend displayed as online if a
      // connection-scoped binding was already replaced by a duplicate probe.
      // CoreBluetooth can deliver the old generation's disconnect after a
      // RESUME has installed a new binding for the same opaque endpoint ID.
      // The binding generation guard filters that callback, so this fallback
      // must apply the same guard before notifying the logical owner.
      final mappedPeer = _gattPeersByEndpoint[event.endpointId];
      final mappedLink = mappedPeer == null ? null : _gattLinks[mappedPeer];
      final generationMatches =
          mappedLink != null &&
          mappedLink.endpointId == event.endpointId &&
          gattConnectionGenerationMatches(
            event.connectionGeneration,
            mappedLink.connectionGeneration,
          );
      if (mappedPeer != null && generationMatches) {
        mappedPeer._platformTransportLost();
      } else if (mappedPeer != null) {
        _log(
          'gatt disconnected ignored stale owner endpoint=${event.endpointId} eventGeneration=${event.connectionGeneration} ownerEndpoint=${mappedLink?.endpointId} ownerGeneration=${mappedLink?.connectionGeneration}',
        );
      }
      _startingGattEndpoints.remove(event.endpointId);
      final closeKey =
          '${event.endpointId}:${event.connectionGeneration ?? 'unknown'}';
      final closeAlreadyRequested =
          _nativeCloseRequestedEndpoints.contains(closeKey) ||
          (event.connectionGeneration == null &&
              !_gattBindings.containsKey(event.endpointId) &&
              _nativeCloseRequestedEndpoints.any(
                (key) => key.startsWith('${event.endpointId}:'),
              ));
      if (!closeAlreadyRequested) {
        unawaited(
          _closeGattBinding(
            event.endpointId,
            connectionGeneration: event.connectionGeneration,
          ),
        );
      }
      _connectionAttemptTimers.remove(event.endpointId)?.cancel();
      final attempt = _attempts.remove(event.endpointId);
      if (attempt != null && !automaticHandshakeDisconnect) {
        final statusDetail = event.status == null
            ? ''
            : ' (platform status ${event.status})';
        attempt._failed(
          LpcException(
            LpcErrorCode.endpointLost,
            'GATT endpoint disconnected$statusDetail',
          ),
        );
        _knownPeerProbeTimers.remove(event.endpointId)?.cancel();
        if (_automaticProbeEndpoints.remove(event.endpointId)) {
          _startNextKnownPeerProbe();
        }
      }
      _releaseAutomaticGattConnectSlot(event.endpointId);
      // A reconnect candidate can fail before the RESUME handshake starts, so
      // there may be no ConnectionAttempt to report the transport loss. Feed
      // that native callback into the same bounded reconnect schedule instead
      // of leaving it permanently marked as attempting.
      if (reconnect != null &&
          reconnect.attempting &&
          !automaticHandshakeDisconnect) {
        _reconnectAttemptFailed(reconnect);
      }
      return;
    }
    if (event is PlatformGattFragment) {
      _recoverOrphanedGattBinding(event);
      return;
    }
    if (event is! PlatformGattConnected) return;
    _gattConnectedEvents[event.endpointId] = event;
    _gattCandidateStartedAtMs.putIfAbsent(event.endpointId, () => _monotonicMs);
    // The native GATT-connected callback completes the platform link
    // procedure. Release only this physical-connect slot here; protocol
    // handshakes for different authenticated candidates remain independent.
    _releaseAutomaticGattConnectSlot(event.endpointId);
    _nativeCloseRequestedEndpoints.removeWhere(
      (key) => key.startsWith('${event.endpointId}:'),
    );
    _log(
      'gatt connected endpoint=${event.endpointId} role=${event.localRole} writeSize=${event.platformSafeWriteSize} reconnect=${_gattReconnects[event.endpointId] != null}',
    );
    final reconnect = _gattReconnects[event.endpointId];
    if (reconnect != null && reconnect.attempting) {
      if (_startingGattEndpoints.add(event.endpointId)) {
        _launchGattResume(event, reconnect);
      } else {
        _log(
          'gatt connected ignored duplicate resume callback endpoint=${event.endpointId}',
        );
      }
      return;
    }
    if (_startingGattEndpoints.contains(event.endpointId) ||
        _gattBindings.containsKey(event.endpointId)) {
      _log(
        'gatt connected ignored duplicate endpoint=${event.endpointId} starting=${_startingGattEndpoints.contains(event.endpointId)} bound=${_gattBindings.containsKey(event.endpointId)}',
      );
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
        // A peer that is already connected through its peripheral-side GATT
        // endpoint can still receive an automatic known-peer probe through a
        // newly discovered central endpoint. Complete that authenticated
        // handshake so both runtimes can compare PeerIds and suppress the
        // duplicate candidate. Rejecting it here leaves the probing side
        // with only transportClosed and causes a connect/close loop on every
        // scan advertisement. This path never retains an unknown peer: the
        // resolver classification below owns that decision.
        if (!config.autoConnectKnownPeers || config.knownPeerResolver == null) {
          _log(
            'gatt connected rejected endpoint=${event.endpointId} reason=no host/group/known-peer owner',
          );
          return;
        }
      }
      if (host != null && !host.config.autoAccept) return;
      final backend = _platformBleBackend!;
      attempt = ConnectionAttempt._(
        event.endpointId,
        () => backend.closeGattConnection(event.endpointId),
      );
      if (host == null) {
        if (_startingGattEndpoints.add(event.endpointId)) {
          _launchGattHandshake(
            event,
            attempt,
            groupProfile: groupProfile,
            knownPeerCandidate: groupProfile == null,
          );
        }
        return;
      }
    }
    if (_startingGattEndpoints.add(event.endpointId)) {
      _launchGattHandshake(event, attempt, host: host);
    }
  }

  /// Reattach an inbound GATT link whose native subscription survived a Dart
  /// handshake/runtime lifecycle race. CoreBluetooth can keep a peripheral
  /// subscription alive after the Dart handshake has been cancelled or an
  /// application-level runtime has been recreated. In that state the native
  /// endpoint still delivers the remote HELLO, but no HandshakeConnection is
  /// listening, so both peers keep probing forever and neither becomes online.
  ///
  /// This is deliberately limited to an endpoint that already has a binding,
  /// has no active handshake, and has no authenticated logical owner. It does
  /// not cancel a competing unknown probe: authenticated PeerId comparison
  /// and normal duplicate-link arbitration remain the ownership decisions.
  void _recoverOrphanedGattBinding(PlatformGattFragment event) {
    final endpointId = event.endpointId;
    if (!_gattBindings.containsKey(endpointId) ||
        _startingGattEndpoints.contains(endpointId) ||
        _gattPeersByEndpoint.containsKey(endpointId) ||
        !_recoveringOrphanedGattEndpoints.add(endpointId)) {
      return;
    }
    final connected =
        _gattConnectedEvents[endpointId] ??
        PlatformGattConnected(
          endpointId,
          endpointId.startsWith('server-') ? 'peripheral' : 'central',
          connectionGeneration: event.connectionGeneration,
        );
    HostSession? host;
    for (final candidate in _advertisingHosts) {
      if (candidate.config.autoAccept) {
        host = candidate;
        break;
      }
    }
    final groupProfile = _autoGroupProfile;
    if (host == null && groupProfile == null) {
      _recoveringOrphanedGattEndpoints.remove(endpointId);
      _log(
        'orphaned GATT binding has no inbound owner endpoint=$endpointId; closing',
      );
      unawaited(_closeGattBinding(endpointId, preserveSharedLink: true));
      return;
    }
    final backend = _platformBleBackend;
    if (backend == null) {
      _recoveringOrphanedGattEndpoints.remove(endpointId);
      return;
    }
    final attempt = ConnectionAttempt._(
      endpointId,
      () => backend.closeGattConnection(
        endpointId,
        connectionGeneration: connected.connectionGeneration,
      ),
    );
    _startingGattEndpoints.add(endpointId);
    _log(
      'recovering orphaned GATT binding endpoint=$endpointId generation=${connected.connectionGeneration}',
    );
    _launchGattHandshake(
      connected,
      attempt,
      host: host,
      groupProfile: host == null ? groupProfile : null,
    );
  }

  /// Closes both halves of a binding.  Cancelling the event subscription only
  /// stops Dart from consuming callbacks; it does not release the native GATT
  /// client.  This distinction matters when a reconnect candidate is still
  /// handshaking while the logical reconnect deadline expires.
  Future<void> _closeGattBinding(
    String endpointId, {
    int? connectionGeneration,
    bool preserveSharedLink = false,
  }) {
    final existing = _gattCloseOperations[endpointId];
    if (existing != null) return existing;
    _closingGattEndpoints.add(endpointId);
    final cleanup = _performGattBindingClose(
      endpointId,
      connectionGeneration: connectionGeneration,
      preserveSharedLink: preserveSharedLink,
    );
    _gattCloseOperations[endpointId] = cleanup;
    unawaited(
      cleanup.then<void>((_) {
        if (_gattCloseOperations[endpointId] == cleanup) {
          _gattCloseOperations.remove(endpointId);
          _closingGattEndpoints.remove(endpointId);
        }
      }),
    );
    return cleanup;
  }

  Future<void> _performGattBindingClose(
    String endpointId, {
    int? connectionGeneration,
    bool preserveSharedLink = false,
  }) async {
    final binding = _gattBindings.remove(endpointId);
    final generation = connectionGeneration ?? binding?.connectionGeneration;
    final closeKey = '$endpointId:${generation ?? 'unknown'}';
    if (_nativeCloseRequestedEndpoints.contains(closeKey)) return;
    _rememberNativeCloseRequested(endpointId, connectionGeneration: generation);
    try {
      if (binding != null) {
        // Only a central-side duplicate has an independently parkable native
        // client handle. Peripheral-side links use ordinary teardown.
        if (preserveSharedLink &&
            binding.connection.localRole == GattLinkRole.central) {
          binding.connection.preserveNativeLinkOnClose();
        }
        await binding.close();
        await binding.connection.close();
      } else {
        // The platform callback can race the handshake/binding cleanup and
        // remove the Dart binding first. Native client/server objects are
        // still independently owned by the plugin in that case. An
        // idempotent close is required to release Android BluetoothGatt
        // handles that otherwise make the next connectGatt return
        // ENDPOINT_BUSY. The native implementations also use the generation
        // guard where the platform exposes one, so this cannot close a newer
        // replacement generation accidentally.
        await _platformBleBackend?.closeGattConnection(
          endpointId,
          connectionGeneration: generation,
          preserveSharedLink: preserveSharedLink,
        );
      }
    } on Object catch (error) {
      _log(
        'GATT binding transport close failed endpoint=$endpointId error=$error',
      );
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
    PlatformGattConnected event,
    ConnectionAttempt attempt, {
    HostSession? host,
    _AutoGroupHandshakeProfile? groupProfile,
    bool knownPeerCandidate = false,
  }) {
    unawaited(
      _startGattHandshake(
        event,
        attempt,
        host: host,
        groupProfile: groupProfile,
        knownPeerCandidate: knownPeerCandidate,
      ).then<void>(
        (_) {
          _startingGattEndpoints.remove(event.endpointId);
          _recoveringOrphanedGattEndpoints.remove(event.endpointId);
        },
        onError: (Object error, StackTrace stack) {
          _startingGattEndpoints.remove(event.endpointId);
          _recoveringOrphanedGattEndpoints.remove(event.endpointId);
          if (!_attempts.containsKey(event.endpointId)) {
            _log(
              'background handshake ended endpoint=${event.endpointId} code=${_asLpcError(error).code.name}',
            );
          } else {
            attempt._failed(_asLpcError(error));
          }
        },
      ),
    );
  }

  /// Same containment boundary for automatic RESUME.  Resume failures are
  /// converted into the reconnect scheduler's next attempt by the method
  /// itself, but cleanup failures must not become unhandled Futures.
  void _launchGattResume(
    PlatformGattConnected event,
    _GattReconnect reconnect,
  ) {
    unawaited(
      _startGattResume(event, reconnect).then<void>(
        (_) {
          _startingGattEndpoints.remove(event.endpointId);
        },
        onError: (Object error, StackTrace stack) {
          _startingGattEndpoints.remove(event.endpointId);
          _log(
            'background resume ended endpoint=${event.endpointId} peer=${reconnect.peer.peerId} code=${_asLpcError(error).code.name}',
          );
          _reconnectAttemptFailed(reconnect);
        },
      ),
    );
  }

  Future<void> _startGattHandshake(
    PlatformGattConnected event,
    ConnectionAttempt attempt, {
    HostSession? host,
    _AutoGroupHandshakeProfile? groupProfile,
    bool knownPeerCandidate = false,
  }) async {
    final backend = _platformBleBackend!;
    final identity = _identity!;
    HandshakeConnection? handshake;
    try {
      _log(
        'handshake start endpoint=${event.endpointId} role=${event.localRole} mode=${host != null
            ? 'host'
            : groupProfile != null
            ? 'group'
            : knownPeerCandidate
            ? 'known-peer-responder'
            : _automaticProbeEndpoints.contains(event.endpointId)
            ? 'known-probe'
            : 'direct'}',
      );
      // A platform may reuse an opaque endpoint after a disconnect.  Replace
      // the old fragment-event binding before installing the new generation.
      await _gattBindings.remove(event.endpointId)?.close();
      final connection = GattBackendConnection(
        connectionId: event.endpointId,
        logger: (message) => _log(
          'gatt endpoint=${event.endpointId} generation=${event.connectionGeneration} $message',
        ),
        platform: PlatformGattFragmentPlatform(
          backend: backend,
          endpointId: event.endpointId,
          platformSafeWriteSize: event.platformSafeWriteSize,
          connectionGeneration: event.connectionGeneration,
          onCloseRequested: () => _rememberNativeCloseRequested(
            event.endpointId,
            connectionGeneration: event.connectionGeneration,
          ),
        ),
        localRole: event.localRole == 'central'
            ? GattLinkRole.central
            : GattLinkRole.peripheral,
        maxQueuedBytes: config.maxQueuedBytesPerPeer,
        fragmentTimeoutMs: config.gattFragmentInactivityTimeoutMs,
      );
      _gattBindings[event.endpointId] = PlatformGattConnectionBinding(
        backend: backend,
        endpointId: event.endpointId,
        connection: connection,
        connectionGeneration: event.connectionGeneration,
      );
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
              16,
              (_) => Random.secure().nextInt(256),
            ),
            peerCapabilities: PeerCapabilityBitmap(const [
              PeerCapability.gattBaseline,
              PeerCapability.resume,
            ]).value,
            maxMinor: 0,
            keepaliveIntervalMs: config.keepaliveIntervalMs,
            applicationMetadata:
                host?.config.applicationMetadata ?? _applicationMetadata,
            trustMode: trustMode,
          ),
          localIdentityKeyPair: identity.keyPair,
          localEphemeralKeyPair: ephemeral,
          knownPeerPolicy:
              groupProfile?.knownPeerPolicy ??
              _knownPeerPolicyFor(config, trustMode),
          tofuStore: trustMode == HandshakeTrustMode.tofu ? _tofuStore : null,
          psk32: groupProfile?.psk32 ?? config.psk32,
        ),
        onSasRequired: (peerId, sas) {
          attempt._verificationRequired(peerId, sas, handshake!.confirmSas);
          host?._peerVerificationRequired(attempt, peerId, sas);
        },
      );
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
      // A known-peer probe can time out while the native stack is still
      // delivering its delayed AUTH/READY frames.  ConnectionAttempt.cancel()
      // closes the platform endpoint, but late callbacks can still complete
      // this Dart handshake.  Never publish a late READY into Runtime
      // ownership after the attempt has become terminal; doing so creates a
      // peer that is immediately killed by the timeout cleanup, which is
      // particularly visible on Android after an app restart.
      if (attempt._terminal) {
        _log(
          'handshake discarded after cancelled attempt endpoint=${event.endpointId}',
        );
        await _closeGattBinding(
          event.endpointId,
          connectionGeneration: event.connectionGeneration,
        );
        return;
      }
      if (host != null || groupProfile != null || knownPeerCandidate) {
        final outcome = await Future.any<Object>([
          ready.then<Object>((core) => core),
          authenticated.then<Object>((candidate) => candidate),
        ]);
        if (attempt._terminal) {
          _log(
            'handshake outcome discarded after cancelled attempt endpoint=${event.endpointId}',
          );
          await _closeGattBinding(
            event.endpointId,
            connectionGeneration: event.connectionGeneration,
          );
          return;
        }
        if (outcome is HandshakeResult) {
          _log(
            'candidate handshake authenticated endpoint=${event.endpointId} peer=${handshake.remotePeerId}; starting inbound resume',
          );
          await backend.associateGattPeer(
            event.endpointId,
            handshake.remotePeerId!,
          );
          await _completeInboundGattResume(
            event,
            connection,
            handshake,
            outcome,
          );
          return;
        }
        final core = outcome as PeerConnectionCore;
        _log(
          'inbound handshake READY endpoint=${event.endpointId} peer=${core.remotePeerId}',
        );
        await backend.associateGattPeer(event.endpointId, core.remotePeerId);
        final peer = await _ownPeer(
          core,
          securityLevel: handshake.exchange.result!.createReady().securityLevel,
          gattEndpointId: event.endpointId,
          gattConnectionGeneration: event.connectionGeneration,
          physicalEndpointId: event.physicalEndpointId,
          connectionRank: await _rankFor(handshake),
          remoteApplicationMetadata:
              handshake.exchange.result!.remoteHello.applicationMetadata,
        );
        _releaseFreshHandshakeHandoffForPeer(peer.peerId);
        if (host != null) {
          host._peerConnected(peer, discoveryEndpointId: event.endpointId);
        }
        if (knownPeerCandidate) {
          // This inbound connection was opened by the remote runtime's
          // automatic known-peer scheduler. It must be classified by the
          // local resolver as well; otherwise a nearby unknown endpoint
          // would become a direct retained peer merely because this runtime
          // answered its low-level handshake.
          _suppressKnownProbeForOwner(event.endpointId, peer);
          final classified = await _classifyKnownPeer(peer, event.endpointId);
          if (!classified) {
            _connectionAttemptTimers.remove(event.endpointId)?.cancel();
            _attempts.remove(event.endpointId);
            attempt._failed(
              const LpcException(
                LpcErrorCode.transportClosed,
                'known-peer candidate disconnected before classification',
              ),
            );
            return;
          }
        }
        attempt._connected(peer);
        return;
      }
      final core = await ready;
      if (attempt._terminal) {
        _log(
          'handshake READY discarded after cancelled attempt endpoint=${event.endpointId}',
        );
        await _closeGattBinding(
          event.endpointId,
          connectionGeneration: event.connectionGeneration,
        );
        return;
      }
      _log(
        'handshake READY endpoint=${event.endpointId} peer=${core.remotePeerId}',
      );
      await backend.associateGattPeer(event.endpointId, core.remotePeerId);
      // Capture this immediately before ownership is assigned.  Duplicate
      // READY resolution can close the candidate transport synchronously
      // while _ownPeer returns the already-owned logical peer; that close
      // emits PlatformGattDisconnected and removes the endpoint from the
      // automatic-probe set.  The candidate was still an automatic probe and
      // must be classified against the PeerId cache rather than silently
      // becoming a failed direct connection.
      final automaticProbe = _automaticProbeEndpoints.contains(
        event.endpointId,
      );
      if (automaticProbe) {
        // Before this point every endpoint is only a service-UUID
        // observation. Do not cancel another probe until this candidate has
        // authenticated a PeerId; otherwise a third nearby device can win
        // the race and starve an unrelated peer.
        _authenticatedAutomaticProbePeers[event.endpointId] = core.remotePeerId;
      }
      final peer = await _ownPeer(
        core,
        securityLevel: handshake.exchange.result!.createReady().securityLevel,
        gattEndpointId: event.endpointId,
        gattConnectionGeneration: event.connectionGeneration,
        physicalEndpointId: event.physicalEndpointId,
        connectionRank: await _rankFor(handshake),
        remoteApplicationMetadata:
            handshake.exchange.result!.remoteHello.applicationMetadata,
      );
      _releaseFreshHandshakeHandoffForPeer(peer.peerId);
      if (automaticProbe) {
        _suppressKnownProbeForOwner(event.endpointId, peer);
        final classified = await _classifyKnownPeer(peer, event.endpointId);
        _authenticatedAutomaticProbePeers.remove(event.endpointId);
        if (!classified) {
          _connectionAttemptTimers.remove(event.endpointId)?.cancel();
          _attempts.remove(event.endpointId);
          attempt._failed(
            const LpcException(
              LpcErrorCode.transportClosed,
              'known-peer candidate disconnected before classification',
            ),
          );
          return;
        }
      } else {
        _directRetainedPeers.add(peer.peerId);
      }
      _authenticatedAutomaticProbePeers.remove(event.endpointId);
      _connectionAttemptTimers.remove(event.endpointId)?.cancel();
      _attempts.remove(event.endpointId);
      attempt._connected(peer);
    } on Object catch (error) {
      final lpcError = _asLpcError(error);
      _log(
        'handshake failed endpoint=${event.endpointId} code=${lpcError.code.name} detail=$error',
      );
      final automaticProbe = _automaticProbeEndpoints.contains(
        event.endpointId,
      );
      _authenticatedAutomaticProbePeers.remove(event.endpointId);
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
            .where(
              (peer) =>
                  peer.peerId == exchange!.remoteHello!.peerId &&
                  peer.state == PeerConnectionState.ready,
            )
            .firstOrNull;
        if (existing != null) {
          _suppressKnownProbeForOwner(event.endpointId, existing);
          await _classifyKnownPeer(existing, event.endpointId);
        }
      }
      // The platform may not deliver a second disconnected callback after a
      // protocol-level handshake failure. Release the attempt here so the
      // endpoint can be probed again on the next discovery observation.
      _connectionAttemptTimers.remove(event.endpointId)?.cancel();
      _attempts.remove(event.endpointId);
      // A protocol-level handshake failure is another terminal end to the
      // candidate lifecycle. Some Android stacks report no subsequent
      // PlatformGattDisconnected after a failed write, leaving this map entry
      // behind and causing a later probe to be classified against stale
      // overlap timing.
      _gattCandidateStartedAtMs.remove(event.endpointId);
      attempt._failed(lpcError);
      try {
        await _closeGattBinding(
          event.endpointId,
          connectionGeneration: event.connectionGeneration,
        );
      } on Object catch (cleanupError) {
        _log(
          'handshake binding cleanup failed endpoint=${event.endpointId} error=$cleanupError',
        );
      }
      if (_automaticProbeEndpoints.remove(event.endpointId)) {
        _startNextKnownPeerProbe();
      }
    }
  }

  void _scheduleKnownPeerProbe(String endpointId) {
    _clearStaleKnownPeerProbeState(endpointId);
    if (_blockedDirectPeersForTesting.contains(
      _lastAuthenticatedPeerByEndpoint[endpointId],
    ))
      return;
    if (_freshHandshakeHandoffEndpoints.contains(endpointId)) return;
    var suppressedOwner = _knownProbeSuppressedByOwner[endpointId];
    if (suppressedOwner != null) {
      if (suppressedOwner.state == PeerConnectionState.ready ||
          suppressedOwner.state == PeerConnectionState.reconnecting) {
        return;
      }
      _knownProbeSuppressedByOwner.remove(endpointId);
      suppressedOwner = null;
    }
    final notBefore = _knownPeerProbeNotBeforeMs[endpointId];
    if (notBefore != null && _monotonicMs < notBefore) {
      return;
    }
    final existingPeer = _gattPeersByEndpoint[endpointId];
    if (!config.autoConnectKnownPeers ||
        _closingGattEndpoints.contains(endpointId) ||
        _duplicateClosingEndpoints.contains(endpointId) ||
        _gattReconnects.containsKey(endpointId) ||
        // A transport endpoint may be in an explicit or inbound handshake
        // even before it has an owned PeerConnection. Do not open a second
        // GATT client for that same endpoint while iOS/macOS is still
        // negotiating the first one.
        _startingGattEndpoints.contains(endpointId) ||
        _gattBindings.containsKey(endpointId) ||
        (existingPeer != null &&
            (existingPeer.state == PeerConnectionState.ready ||
                existingPeer.state == PeerConnectionState.reconnecting)) ||
        _completedKnownPeerProbeEndpoints.containsKey(endpointId) ||
        _automaticProbeEndpoints.contains(endpointId) ||
        _attempts.containsKey(endpointId) ||
        _pendingKnownPeerProbes.contains(endpointId)) {
      return;
    }
    if (_automaticGattConnectInFlight != null ||
        _automaticProbeEndpoints.length >=
            config.maxConcurrentKnownPeerProbes) {
      if (_pendingKnownPeerProbes.length < config.maxPendingKnownPeerProbes) {
        _pendingKnownPeerProbes.add(endpointId);
        _log(
          'known probe queued endpoint=$endpointId pending=${_pendingKnownPeerProbes.length} active=${_automaticProbeEndpoints.length}',
        );
      }
      return;
    }
    _startKnownPeerProbe(endpointId);
  }

  void _suppressKnownProbeForOwner(String endpointId, PeerConnection owner) {
    if (owner.state != PeerConnectionState.ready &&
        owner.state != PeerConnectionState.reconnecting) {
      return;
    }
    // A duplicate candidate can be closed by the remote runtime after it has
    // authenticated, before this side receives READY. The authenticated
    // PeerId is still sufficient to prove that the discovery endpoint belongs
    // to the already-owned logical peer. Retain suppression until that owner
    // disconnects; otherwise every advertisement reopens the same losing
    // candidate and creates a connect/close loop on iOS and Android.
    final ownerEndpoint = _gattLinks[owner]?.endpointId;
    if (ownerEndpoint == endpointId) return;
    _knownProbeSuppressedByOwner[endpointId] = owner;
    _knownPeerProbeEndpointsByPeer
        .putIfAbsent(owner, () => <String>{})
        .add(endpointId);
    _knownPeerProbeNotBeforeMs.remove(endpointId);
    _log(
      'known probe suppressed endpoint=$endpointId owner=${owner.peerId} ownerEndpoint=${ownerEndpoint ?? 'none'}',
    );
  }

  /// Discovery identifiers are ephemeral, but some platform backends can
  /// omit or reorder the disconnect callback that normally clears the
  /// endpoint-scoped probe cache.  Do not let that callback race turn a
  /// completed probe into a permanent black hole: suppression is valid only
  /// while an authenticated logical owner is still READY or RECONNECTING.
  /// This is especially important on mobile BLE stacks where a stale native
  /// GATT client may remain visible after the app-level PeerConnection has
  /// already become terminal.
  void _clearStaleKnownPeerProbeState(String endpointId) {
    final mappedPeer = _gattPeersByEndpoint[endpointId];
    if (mappedPeer?.state == PeerConnectionState.disconnected) {
      _gattPeersByEndpoint.remove(endpointId);
    }

    final suppressedOwner = _knownProbeSuppressedByOwner[endpointId];
    if (suppressedOwner != null &&
        suppressedOwner.state != PeerConnectionState.ready &&
        suppressedOwner.state != PeerConnectionState.reconnecting) {
      _knownProbeSuppressedByOwner.remove(endpointId);
    }

    var activeAssociatedOwner = false;
    final staleAssociations = <PeerConnection>[];
    for (final entry in _knownPeerProbeEndpointsByPeer.entries) {
      if (!entry.value.contains(endpointId)) continue;
      if (entry.key.state == PeerConnectionState.ready ||
          entry.key.state == PeerConnectionState.reconnecting) {
        activeAssociatedOwner = true;
      } else {
        staleAssociations.add(entry.key);
      }
    }
    for (final peer in staleAssociations) {
      final endpoints = _knownPeerProbeEndpointsByPeer[peer];
      endpoints?.remove(endpointId);
      if (endpoints != null && endpoints.isEmpty) {
        _knownPeerProbeEndpointsByPeer.remove(peer);
      }
    }

    // A duplicate winner can be reached through an inbound opaque endpoint,
    // while this displaced discovery endpoint remains only a scan result. It
    // is therefore intentionally absent from _gattPeersByEndpoint; the
    // suppression owner is still authoritative until that logical peer ends.
    final hasActiveOwner =
        _gattPeersByEndpoint.containsKey(endpointId) ||
        activeAssociatedOwner ||
        suppressedOwner != null;
    if (!hasActiveOwner &&
        ((_completedKnownPeerProbeEndpoints.remove(endpointId) ?? false) ||
            _knownProbeSuppressedByOwner.remove(endpointId) != null)) {
      _authenticatedAutomaticProbePeers.remove(endpointId);
      _log('cleared stale known probe state endpoint=$endpointId');
    }
  }

  /// Starts a fresh central candidate for a logical peer whose previous link
  /// was locally peripheral-side. The endpoint is only an observation from
  /// the shared BLE scan; its identity is established by the candidate HELLO
  /// and Section 26 proof, never by a platform identifier. Keep one such
  /// candidate at a time per reconnecting peer so nearby devices cannot create
  /// an unbounded set of physical links.
  void _scheduleReconnectProbe(String endpointId) {
    if (_freshHandshakeHandoffEndpoints.contains(endpointId)) {
      _log(
        'reconnect discovery candidate deferred endpoint=$endpointId reason=fresh-handshake-handoff',
      );
      return;
    }
    final mappedPeer = _gattPeersByEndpoint[endpointId];
    final mappedReady = mappedPeer?.state == PeerConnectionState.ready;
    final mappedReconnecting =
        mappedPeer?.state == PeerConnectionState.reconnecting;
    if (!config.autoReconnect ||
        _state != RuntimeState.ready ||
        _closingGattEndpoints.contains(endpointId) ||
        _gattReconnects.containsKey(endpointId) ||
        // A discovery callback can arrive while an automatic known-peer
        // probe is already opening this same physical endpoint. Do not issue
        // a second connectGatt: the two handshake modes can consume each
        // other's HELLO/AUTH frames and leave both logical links retrying.
        // The existing probe authenticates the PeerId; _ownPeer then replaces
        // a reconnecting logical owner with that fresh authenticated transport.
        _automaticProbeEndpoints.contains(endpointId) ||
        _attempts.containsKey(endpointId) ||
        _startingGattEndpoints.contains(endpointId) ||
        _gattBindings.containsKey(endpointId) ||
        (mappedReady && !mappedReconnecting) ||
        (mappedPeer != null &&
            !mappedReconnecting &&
            !_reconnectWaitingForDiscovery.contains(mappedPeer))) {
      return;
    }
    final notBefore = _knownPeerProbeNotBeforeMs[endpointId];
    if (notBefore != null && _monotonicMs < notBefore) return;
    // A central-side reconnect normally retries its last endpoint.  That
    // endpoint can be a stale platform handle after an iOS/Android address
    // rotation, however, while discovery is already reporting the replacement
    // endpoint.  Do not leave the logical peer dependent on the old handle:
    // any reconnecting peer without an active discovery candidate may adopt
    // this newly observed endpoint.  RESUME/duplicate arbitration still
    // chooses the first authenticated candidate, so this does not assign a
    // permanent reconnect direction or create an unbounded set of links.
    final reconnectingPeers =
        <PeerConnection>{
          ..._reconnectWaitingForDiscovery,
          ..._peers.where(
            (candidate) => candidate.state == PeerConnectionState.reconnecting,
          ),
        }.where(
          (candidate) => !_gattReconnects.values.any(
            (reconnect) =>
                identical(reconnect.peer, candidate) &&
                reconnect.discoveryCandidate,
          ),
        );
    final endpointHint = _lastAuthenticatedPeerByEndpoint[endpointId];
    // A discovery observation without a recent authenticated endpoint hint is
    // not evidence that it belongs to the only reconnecting peer.  In a
    // multi-device BLE neighborhood it may be a different friend, and a
    // speculative RESUME would send the wrong session to that endpoint. On
    // Android, closing that wrong candidate can also tear down an inbound
    // server link that shares the same controller ACL. Let the bounded
    // known-peer probe authenticate the PeerId first; only a previously
    // authenticated endpoint association may take the fast RESUME path.
    if (endpointHint == null) return;
    final peer = reconnectingPeers
        .where((candidate) => candidate.peerId == endpointHint)
        .firstOrNull;
    if (peer == null) return;
    final schedule =
        _reconnectWaitingSchedules[peer] ??
        _gattReconnects.values
            .where((reconnect) => identical(reconnect.peer, peer))
            .map((reconnect) => reconnect.schedule)
            .firstOrNull;
    if (schedule == null ||
        schedule.expiredAt(peer._core.monotonicNowMs) ||
        !schedule.attemptDue(peer._core.monotonicNowMs)) {
      return;
    }
    _reconnectWaitingForDiscovery.add(peer);
    _reconnectWaitingSchedules[peer] = schedule;
    final backend = _platformBleBackend;
    if (backend == null) return;

    final reconnect =
        _GattReconnect(peer, endpointId, schedule, discoveryCandidate: true)
          ..attempting = true
          ..staleGenerationCleanupComplete = true;
    _gattReconnects[endpointId] = reconnect;
    _log(
      'reconnect discovery candidate endpoint=$endpointId peer=${peer.peerId} timeoutMs=${config.reconnectTimeoutMs}',
    );
    unawaited(() async {
      try {
        await backend.connectGatt(endpointId);
      } on Object catch (error) {
        if (_isEndpointBusyError(error)) {
          await _closeBusyGattEndpoint(backend, endpointId);
        }
        _log(
          'reconnect discovery candidate failed endpoint=$endpointId peer=${peer.peerId} error=$error',
        );
        _reconnectAttemptFailed(reconnect);
      }
    }());
  }

  void _startKnownPeerProbe(String endpointId) {
    _automaticGattConnectInFlight = endpointId;
    _automaticProbeEndpoints.add(endpointId);
    // Android stacks may leave connectGatt pending without ever delivering
    // PlatformGattConnected for a stale/unreachable endpoint. Keep the longer
    // reconnect window for service discovery and HELLO/AUTH after the physical
    // callback, but do not let a missing callback serialize unrelated friends
    // for that entire window.
    _automaticGattConnectTimer?.cancel();
    _automaticGattConnectTimer = Timer(
      Duration(
        milliseconds: min(
          config.reconnectTimeoutMs,
          _connectionRequestTimeoutMs,
        ),
      ),
      () => _expireAutomaticGattConnect(endpointId),
    );
    _log(
      'known probe started endpoint=$endpointId timeoutMs=${config.reconnectTimeoutMs}',
    );
    _events.add(KnownPeerProbeStarted(_monotonicMs, endpointId));
    try {
      final attempt = _connect(endpointId, automaticProbe: true);
      _knownPeerProbeTimers[endpointId] = Timer(
        Duration(milliseconds: config.reconnectTimeoutMs),
        () {
          _knownPeerProbeTimers.remove(endpointId);
          _releaseFreshHandshakeHandoff(endpointId);
          if (!_automaticProbeEndpoints.remove(endpointId)) return;
          _deferKnownPeerProbe(endpointId);
          unawaited(attempt.cancel().catchError((_) {}));
          _events.add(
            KnownPeerProbeFailed(
              _monotonicMs,
              endpointId,
              const LpcException(
                LpcErrorCode.connectionTimeout,
                'automatic known-peer probe timed out',
              ),
            ),
          );
          _log('known probe timed out endpoint=$endpointId');
          _startNextKnownPeerProbe();
        },
      );
      attempt.events.listen((event) {
        if (event is ConnectionAttemptFailed) {
          _knownPeerProbeTimers.remove(endpointId)?.cancel();
          _releaseFreshHandshakeHandoff(endpointId);
          if (_shouldBackoffKnownPeerProbe(event.error)) {
            _deferKnownPeerProbe(endpointId);
          }
          _events.add(
            KnownPeerProbeFailed(_monotonicMs, endpointId, event.error),
          );
          _log(
            'known probe failed endpoint=$endpointId code=${event.error.code.name} detail=${event.error.message}',
          );
          _releaseAutomaticGattConnectSlot(endpointId);
        } else if (event is ConnectionAttemptConnected ||
            event is ConnectionAttemptCancelled) {
          _knownPeerProbeTimers.remove(endpointId)?.cancel();
          _releaseFreshHandshakeHandoff(endpointId);
          _releaseAutomaticGattConnectSlot(endpointId);
        }
      });
    } on Object catch (error) {
      _knownPeerProbeTimers.remove(endpointId)?.cancel();
      _releaseFreshHandshakeHandoff(endpointId);
      _events.add(
        KnownPeerProbeFailed(_monotonicMs, endpointId, _asLpcError(error)),
      );
      _log('known probe could not start endpoint=$endpointId error=$error');
      _automaticProbeEndpoints.remove(endpointId);
      _releaseAutomaticGattConnectSlot(endpointId);
      if (_shouldBackoffKnownPeerProbe(_asLpcError(error))) {
        _deferKnownPeerProbe(endpointId);
      }
      _startNextKnownPeerProbe();
    }
  }

  /// Releases only the serialized native GATT link-procedure slot. Protocol
  /// handshakes for different candidates remain independent; the
  /// PlatformGattConnected callback is the physical completion boundary.
  void _releaseAutomaticGattConnectSlot(String endpointId) {
    if (_automaticGattConnectTimedOut.contains(endpointId)) return;
    if (_automaticGattConnectInFlight != endpointId) return;
    _automaticGattConnectTimer?.cancel();
    _automaticGattConnectTimer = null;
    _automaticGattConnectInFlight = null;
    if (_state == RuntimeState.ready) _startNextKnownPeerProbe();
  }

  void _expireAutomaticGattConnect(String endpointId) {
    if (_automaticGattConnectInFlight != endpointId ||
        _gattConnectedEvents.containsKey(endpointId)) {
      return;
    }
    _automaticGattConnectTimedOut.add(endpointId);
    _deferKnownPeerProbe(endpointId);
    _log(
      'known probe physical GATT connect timed out endpoint=$endpointId; closing before next candidate',
    );
    final attempt = _attempts[endpointId];
    _connectionAttemptTimers.remove(endpointId)?.cancel();
    _knownPeerProbeTimers.remove(endpointId)?.cancel();
    _attempts.remove(endpointId);
    _gattCandidateStartedAtMs.remove(endpointId);
    _automaticProbeEndpoints.remove(endpointId);
    attempt?._failed(
      const LpcException(
        LpcErrorCode.connectionTimeout,
        'physical GATT connection did not complete',
      ),
    );
    unawaited(() async {
      try {
        await _platformBleBackend
            ?.closeGattConnection(endpointId)
            .timeout(const Duration(seconds: 1));
      } on Object catch (error) {
        // Some mobile BLE stacks can hang while disposing a connect request
        // that never reached GATT_CONNECTED. Bound cleanup so one stale
        // native handle cannot starve later unrelated friend candidates.
        _log(
          'known probe physical timeout cleanup pending endpoint=$endpointId error=$error',
        );
      } finally {
        _automaticGattConnectTimedOut.remove(endpointId);
        _releaseAutomaticGattConnectSlot(endpointId);
      }
    }());
  }

  bool _shouldBackoffKnownPeerProbe(LpcException error) {
    if (error.code == LpcErrorCode.endpointLost ||
        error.code == LpcErrorCode.transportClosed ||
        error.code == LpcErrorCode.connectionTimeout) {
      return true;
    }
    // Android and some vendor BLE stacks can report a locally closing GATT
    // object as an immediate platform error ("endpoint already has a client
    // link"). Discovery continues during that short native teardown window;
    // without the same bounded backoff used for transport failures, each
    // advertisement starts another probe and starves the real reconnect.
    return _isEndpointBusyError(error) || _isServerLinkDuplicateError(error);
  }

  bool _isEndpointBusyError(Object error) {
    final lpcError = _asLpcError(error);
    return lpcError.code == LpcErrorCode.platformError &&
        lpcError.message.toLowerCase().contains(
          'endpoint already has a client link',
        );
  }

  bool _isServerLinkDuplicateError(Object error) {
    final lpcError = _asLpcError(error);
    return lpcError.code == LpcErrorCode.platformError &&
        (lpcError.message.toLowerCase().contains(
              'endpoint already has a server link',
            ) ||
            lpcError.message.toLowerCase().contains(
              'endpoint already has an authenticated server link',
            ));
  }

  Future<void> _closeBusyGattEndpoint(
    PlatformBleBackend backend,
    String endpointId,
  ) async {
    try {
      // Do not route this through _closeGattBinding: the Dart binding is
      // already absent in this failure mode, while the native plugin may
      // still own an unreported BluetoothGatt handle. An unscoped native
      // close deliberately targets that current stale handle.
      await backend.closeGattConnection(endpointId);
      _log('closed stale busy GATT endpoint=$endpointId before retry');
    } on Object catch (closeError) {
      _log(
        'stale busy GATT close failed endpoint=$endpointId error=$closeError',
      );
    }
  }

  void _deferKnownPeerProbe(String endpointId) {
    // Reciprocal runtimes can observe one another at nearly the same time.
    // A fixed retry interval lets both sides repeatedly become BLE centrals
    // together, which is especially hostile to CoreBluetooth when the first
    // GATT client has just been torn down.  De-phase only the retry schedule;
    // endpoint IDs and this hash are never used as identity or ownership.
    var hash = 2166136261;
    for (final byte in localPeerId.bytes) {
      hash = ((hash ^ byte) * 16777619) & 0x7fffffff;
    }
    for (final byte in utf8.encode(endpointId)) {
      hash = ((hash ^ byte) * 16777619) & 0x7fffffff;
    }
    const jitterRangeMs = 1501;
    _knownPeerProbeNotBeforeMs[endpointId] =
        _monotonicMs + _knownPeerProbeFailureBackoffMs + (hash % jitterRangeMs);
  }

  void _startNextKnownPeerProbe() {
    while (_automaticGattConnectInFlight == null &&
        _automaticProbeEndpoints.length < config.maxConcurrentKnownPeerProbes &&
        _pendingKnownPeerProbes.isNotEmpty) {
      final endpointId = _pendingKnownPeerProbes.first;
      _pendingKnownPeerProbes.remove(endpointId);
      _startKnownPeerProbe(endpointId);
    }
  }

  /// A platform endpoint is only a local observation and may change across
  /// Android BLE privacy-address rotations. Once one authenticated peer is
  /// READY, another automatic identity probe is a competing physical link
  /// only when its authenticated PeerId matches that owner. Probes that have
  /// not authenticated yet remain independent candidates for other nearby
  /// peers. The dedicated logical reconnect scheduler remains independent.
  void _cancelCompetingKnownPeerProbes({
    String? exceptEndpointId,
    PeerConnection? owner,
  }) {
    if (owner == null) return;
    final endpointIds = _automaticProbeEndpoints
        .where(
          (endpointId) =>
              endpointId != exceptEndpointId &&
              _authenticatedAutomaticProbePeers[endpointId] == owner.peerId,
        )
        .toList(growable: false);
    for (final endpointId in endpointIds) {
      _automaticProbeEndpoints.remove(endpointId);
      _knownPeerProbeTimers.remove(endpointId)?.cancel();
      _connectionAttemptTimers.remove(endpointId)?.cancel();
      final attempt = _attempts.remove(endpointId);
      if (attempt != null) unawaited(attempt.cancel().catchError((_) {}));
      // Cancelling the Dart ConnectionAttempt alone is not sufficient once
      // the platform has already delivered GATT_CONNECTED.  In that race
      // the candidate handshake owns a live binding, while Android can keep
      // the native client handle reserved until that binding is explicitly
      // closed.  Leaving it alive causes the next automatic probe to loop on
      // ENDPOINT_BUSY and can tear down the otherwise healthy inbound link.
      // Close the candidate binding as part of the same duplicate-link
      // arbitration; the generation guard makes late callbacks harmless.
      unawaited(_closeGattBinding(endpointId));
      _knownProbeSuppressedByOwner[endpointId] = owner;
      _log('known probe cancelled as competing endpoint=$endpointId');
    }
    // Pending endpoints have not authenticated a PeerId and therefore cannot
    // yet be known duplicates. They stay within the configured bounded queue
    // and perform their own PeerId comparison when probed.
  }

  Future<bool> _classifyKnownPeer(
    PeerConnection peer,
    String endpointId,
  ) async {
    _knownPeerProbeNotBeforeMs.remove(endpointId);
    _releaseFreshHandshakeHandoff(endpointId);
    bool known = _knownPeerCache[peer.peerId] ?? false;
    if (!_knownPeerCache.containsKey(peer.peerId)) {
      try {
        known = await config.knownPeerResolver!
            .isKnownPeer(peer.peerId)
            .timeout(Duration(milliseconds: config.knownPeerLookupTimeoutMs));
      } on Object {
        known = false;
      }
      // Relationship state can change while a Runtime remains alive.  Do not
      // cache a negative answer: otherwise an unfriend followed by a new
      // friend would continue to classify every replacement endpoint as
      // unknown until Runtime restart.  That leaves the bounded unknown-peer
      // handoff timer (30 seconds in this runtime) to close an otherwise
      // healthy link on every reconnect.  The spec permits caching but
      // requires negative results to be short-lived; avoiding them entirely
      // gives the application resolver authoritative live semantics without
      // adding another invalidation API.
      if (known && config.maxKnownPeerCacheEntries > 0) {
        if (_knownPeerCache.length >= config.maxKnownPeerCacheEntries) {
          _knownPeerCache.remove(_knownPeerCache.keys.first);
        }
        _knownPeerCache[peer.peerId] = known;
      }
    }
    // Resolver work is application-owned and may outlive the physical
    // candidate. A classification result is not a connection result: do not
    // publish KnownPeerConnected, retain, or complete the probe with a
    // terminal PeerConnection after the candidate link is gone. A reconnecting
    // logical peer remains owned by the runtime and is intentionally not
    // treated as terminal here.
    if (peer.state == PeerConnectionState.disconnected) {
      _log(
        'known probe discarded endpoint=$endpointId peer=${peer.peerId} state=${peer.state.name}',
      );
      _knownPeerProbeTimers.remove(endpointId)?.cancel();
      _automaticProbeEndpoints.remove(endpointId);
      _startNextKnownPeerProbe();
      return false;
    }
    if (known) {
      _log(
        'known probe classified endpoint=$endpointId peer=${peer.peerId} known=true',
      );
      _knownRetainedPeers.add(peer.peerId);
      _events.add(
        KnownPeerConnected(_monotonicMs, peer, discoveryEndpointId: endpointId),
      );
      if (config.maxKnownPeerCacheEntries > 0) {
        _knownPeerProbeEndpointsByPeer
            .putIfAbsent(peer, () => <String>{})
            .add(endpointId);
      }
    } else {
      _log(
        'known probe classified endpoint=$endpointId peer=${peer.peerId} known=false; releasing',
      );
      _events.add(
        UnknownPeerIdentified(
          _monotonicMs,
          peer,
          discoveryEndpointId: endpointId,
        ),
      );
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
        _unknownPeerReleaseTimers[peer] = Timer(_unknownPeerHandoffTimeout, () {
          _unknownPeerReleaseTimers.remove(peer);
          if (!_hasOtherOwner(peer) &&
              peer.state == PeerConnectionState.ready) {
            unawaited(peer.disconnect());
          }
        });
        _log(
          'known probe deferred release peer=${peer.peerId} endpoint=$endpointId reason=${inboundHandshakeInProgress ? 'inbound-handshake' : 'auto-accept-host'}',
        );
      } else {
        _log(
          'known probe retained shared peer=${peer.peerId} endpoint=$endpointId',
        );
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
    return true;
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
    _mesh.forget(peerId);
    final peer = _peers.where((value) => value.peerId == peerId).firstOrNull;
    if (peer != null && !_hasOtherOwner(peer)) await peer.disconnect();
  }

  /// Local physical-edge fault injection for fixture/conformance testing.
  /// It does not change trust, friendship, GroupSession membership, or any
  /// wire frame. Production applications should not depend on this hook.
  bool isDirectPeerBlockedForTesting(PeerId peerId) =>
      _blockedDirectPeersForTesting.contains(peerId);

  /// Blocks or restores only the direct edge to [peerId]. A confirmed friend
  /// may remain reachable through a different authenticated friend.
  Future<void> setDirectPeerBlockedForTesting(
    PeerId peerId, {
    required bool blocked,
  }) async {
    if (_state != RuntimeState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    if (blocked) {
      if (_blockedDirectPeersForTesting.length >= 64 &&
          !_blockedDirectPeersForTesting.contains(peerId)) {
        throw const LpcException(LpcErrorCode.resourceExhausted);
      }
      _blockedDirectPeersForTesting.add(peerId);
      for (final peer
          in _peers
              .where(
                (candidate) =>
                    candidate.peerId == peerId && !candidate.isRelayed,
              )
              .toList()) {
        await peer.disconnect();
      }
    } else {
      _blockedDirectPeersForTesting.remove(peerId);
      _lastAuthenticatedPeerByEndpoint.removeWhere(
        (_, value) => value == peerId,
      );
    }
    _mesh.poke();
  }

  /// Simulates a terminal write/transport loss on a virtual friend link while
  /// preserving its direct relay. This fixture-only fault hook exercises the
  /// route controller's fresh-handshake recovery path without disabling the
  /// physical A-B or B-C links.
  Future<void> simulateRelayedTransportFailureForTesting(PeerId peerId) async {
    if (_state != RuntimeState.ready) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    final peer = _peers
        .where((candidate) => candidate.peerId == peerId && candidate.isRelayed)
        .firstOrNull;
    if (peer == null) {
      throw const LpcException(
        LpcErrorCode.invalidState,
        'no relayed peer exists for the requested test failure',
      );
    }
    _log('mesh test injecting virtual transport loss target=$peerId');
    peer._platformTransportLost();
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
        await backend.startAdvertising(
          config.serviceUuid,
          localName: presentation.discoveryDisplayName,
        );
      }
    }
    _discoveryDisplayName = presentation.discoveryDisplayName;
    _applicationMetadata = List<int>.unmodifiable(
      presentation.applicationMetadata,
    );
  }

  /// Completes the responder side of a fresh inbound candidate connection.
  /// Matching is by the authenticated candidate PeerId plus a reconnecting
  /// logical peer; the RESUME proof then binds the exact prior SessionId and
  /// secret before any core state is reattached.
  Future<void> _completeInboundGattResume(
    PlatformGattConnected event,
    GattBackendConnection connection,
    HandshakeConnection handshake,
    HandshakeResult candidate,
  ) async {
    final candidates = _peers
        .where(
          (peer) =>
              peer.peerId == handshake.remotePeerId &&
              peer.state == PeerConnectionState.reconnecting,
        )
        .toList(growable: false);
    if (candidates.length != 1) {
      // The candidate HELLO/AUTH is still a valid authenticated identity, but
      // a process restart can erase the prior logical session before the
      // remote side's RESUME request arrives. Reject the existing RESUME
      // operation under the fresh candidate keys so the requester can fall
      // back to a new READY session immediately. Waiting for the reconnect
      // watchdog here made an app restart look like a 30-second transport
      // outage even though both devices were nearby and authenticated.
      await CandidateResumeConnection.sendReject(
        backend: connection,
        candidateSessionRootKey: candidate.secrets.sessionRootKey,
        candidateSessionId: candidate.secrets.sessionId,
        localPeerId: localPeerId,
        remotePeerId: handshake.remotePeerId,
        error: LpcErrorCode.resumeRejected,
        negotiatedMinor: candidate.negotiatedMinor,
      );
      // `submittedToPlatform` means the final GATT write was accepted by the
      // native stack, not that the remote Dart isolate has processed the
      // encrypted rejection yet. Closing the inbound binding in the same
      // callback can discard that already-received frame on mobile backends;
      // the requester then sees only transportClosed and retries RESUME until
      // its watchdog expires instead of promptly falling back to fresh HELLO.
      // Give the bounded candidate exchange a short drain window before the
      // normal failure cleanup closes this physical generation.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      throw const LpcException(
        LpcErrorCode.resumeRejected,
        'no unique reconnecting logical peer',
      );
    }
    final peer = candidates.single;
    final inboundReconnect = _gattReconnects.values
        .where((value) => identical(value.peer, peer))
        .firstOrNull;
    final deadlineMs =
        (inboundReconnect?.schedule.startedAtMs ?? peer._core.monotonicNowMs) +
        (inboundReconnect?.schedule.timeoutMs ?? config.reconnectTimeoutMs);
    Future<T> bounded<T>(Future<T> future, String phase) {
      final remaining = deadlineMs - peer._core.monotonicNowMs;
      if (remaining <= 0) {
        throw const LpcException(
          LpcErrorCode.connectionTimeout,
          'resume deadline exceeded',
        );
      }
      return future.timeout(
        Duration(milliseconds: remaining),
        onTimeout: () => throw LpcException(
          LpcErrorCode.connectionTimeout,
          'inbound resume $phase timed out',
        ),
      );
    }

    _log(
      'inbound resume candidate matched endpoint=${event.endpointId} peer=${peer.peerId} candidates=${candidates.length}',
    );
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
      negotiatedMinor: peer._core.negotiatedMinor,
      initialEncodedFrame: await handshake.candidateInitialFrame,
    );
    await bounded(resume.start(), 'proof start');
    final resumed = await bounded(resume.completed, 'proof');
    // Two symmetric runtimes can authenticate crossed RESUME candidates at
    // nearly the same time.  The first candidate to commit calls
    // _finishGattResume, which disposes the other reconnect record.  Do not
    // let that slower candidate apply a second generation or overwrite the
    // winning binding after its reconnect ownership has been cancelled.
    if (peer.state != PeerConnectionState.reconnecting ||
        (inboundReconnect != null && inboundReconnect.closed)) {
      _log(
        'inbound resume candidate lost race endpoint=${event.endpointId} peer=${peer.peerId}',
      );
      await _closeGattBinding(
        event.endpointId,
        connectionGeneration: event.connectionGeneration,
      );
      return;
    }
    _log(
      'inbound resume proof accepted endpoint=${event.endpointId} peer=${peer.peerId} generation=${resumed.generation}',
    );
    peer._core.completeResume(
      newGeneration: resumed.generation,
      resumedSessionRootKey: resumed.sessionRootKey,
      newResumeSecret: resumed.resumeSecret,
      resumedBackend: connection,
    );
    peer._resumeCommitted();
    // Commit endpoint ownership before replaying reliable traffic.  The old
    // physical generation can deliver a delayed disconnect callback while
    // replay is awaiting native writes.  If the old endpoint remains mapped
    // during that window, _onPlatformEvent can incorrectly move this freshly
    // resumed logical peer back to RECONNECTING.  The generation guard on the
    // old binding still filters stale transport data; this map update makes
    // the callback harmless as well.
    _gattLinks[peer] = _GattLink(
      event.endpointId,
      event.localRole == 'central',
      connectionGeneration: event.connectionGeneration,
      candidateStartedAtMs:
          _gattCandidateStartedAtMs[event.endpointId] ?? _monotonicMs,
      readyAtMs: _monotonicMs,
    );
    _gattPeersByEndpoint[event.endpointId] = peer;
    if (event.physicalEndpointId != null) {
      _authenticatedPeerByPhysicalEndpoint[event.physicalEndpointId!] = peer;
    }
    _gattCandidateStartedAtMs.remove(event.endpointId);
    if (previousEndpoint != null && previousEndpoint != event.endpointId) {
      if (_gattPeersByEndpoint[previousEndpoint] == peer) {
        _gattPeersByEndpoint.remove(previousEndpoint);
      }
    }
    _log(
      'inbound resume state ready endpoint=${event.endpointId} peer=${peer.peerId}',
    );
    _finishGattResume(peer, event.endpointId);
    _gattReconnectExpiryTimers.remove(peer)?.cancel();
    try {
      await Future.wait<void>([
        peer._core
            .retransmitReliableDataAfterResume(nowMs: peer._core.monotonicNowMs)
            .then<void>((_) {}),
        peer._core
            .retransmitAckRequiredFramesAfterResume(
              nowMs: peer._core.monotonicNowMs,
            )
            .then<void>((_) {}),
      ]).timeout(const Duration(seconds: 5));
    } on Object catch (error) {
      _log(
        'inbound resume replay deferred endpoint=${event.endpointId} peer=${peer.peerId} error=$error',
      );
    }
    if (peer.state != PeerConnectionState.ready) {
      _log(
        'inbound resume transport lost during replay endpoint=${event.endpointId} peer=${peer.peerId}',
      );
      if (inboundReconnect != null) {
        _reconnectAttemptFailed(inboundReconnect);
      }
      return;
    }
    // The new endpoint was mapped when RESUME committed, before replay.  Do
    // not defer that ownership update until after native writes complete.
    _reconnectWaitingForDiscovery.remove(peer);
    _reconnectWaitingSchedules.remove(peer);
    if (previousEndpoint != null && previousEndpoint != event.endpointId) {
      await _gattBindings.remove(previousEndpoint)?.close();
    }
    // RESUME completed a new physical generation. The expiry timer belongs
    // only to the failed generation; leaving it armed would disconnect this
    // successfully resumed peer when the old reconnect deadline arrives.
    _gattReconnectExpiryTimers.remove(peer)?.cancel();
  }

  void _beginGattReconnect(PeerConnection peer) {
    if (!config.autoReconnect || _state != RuntimeState.ready) {
      _log(
        'reconnect not scheduled peer=${peer.peerId} autoReconnect=${config.autoReconnect} runtime=${_state.name}',
      );
      return;
    }
    final link = _gattLinks[peer];
    // An inbound peripheral-side link exposes no local connectable endpoint.
    // Keep recovery active and let the shared scanner supply a fresh
    // candidate. This is deliberately symmetric: the runtime does not make
    // Android, iOS, or an LPGE layer the permanent reconnect initiator.
    if (link == null || !link.localCanInitiateReconnect) {
      _reconnectWaitingForDiscovery.add(peer);
      _reconnectWaitingSchedules.putIfAbsent(
        peer,
        () => ReconnectSchedule(
          startedAtMs: peer._core.monotonicNowMs,
          timeoutMs: config.reconnectTimeoutMs,
        ),
      );
      _log(
        'reconnect awaiting discovery peer=${peer.peerId} reason=${link == null ? 'no-gatt-link' : 'local-peripheral'}',
      );
      return;
    }
    final endpointId = link.endpointId;
    final staleGeneration = link.connectionGeneration;
    final existing = _gattReconnects[endpointId];
    if (existing != null) {
      _log(
        'reconnect already scheduled peer=${peer.peerId} endpoint=$endpointId',
      );
      return;
    }
    final reconnect = _GattReconnect(
      peer,
      endpointId,
      ReconnectSchedule(
        startedAtMs: peer._core.monotonicNowMs,
        timeoutMs: config.reconnectTimeoutMs,
      ),
    );
    _gattReconnects[endpointId] = reconnect;
    final staleBinding = _gattBindings.remove(endpointId);
    // Even when the platform-disconnect callback already removed the Dart
    // binding, ask the native backend to close the endpoint idempotently. A
    // few Android Bluetooth stacks report the link as disconnected before
    // releasing the client handle, which otherwise makes the first RESUME
    // connectGatt call race the old native object.
    reconnect.staleGenerationCleanup = _closeStaleGattGeneration(
      endpointId,
      staleBinding,
      reconnect,
      staleGeneration: staleGeneration,
    );
    _log(
      'reconnect scheduled peer=${peer.peerId} endpoint=$endpointId timeoutMs=${config.reconnectTimeoutMs}',
    );
    reconnect.timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _pollGattReconnect(reconnect);
    });
    _pollGattReconnect(reconnect);
  }

  void _scheduleGattReconnectExpiry(PeerConnection peer) {
    _gattReconnectExpiryTimers[peer]?.cancel();
    _gattReconnectExpiryTimers[peer] = Timer(
      Duration(milliseconds: config.reconnectTimeoutMs),
      () {
        _gattReconnectExpiryTimers.remove(peer);
        if (peer.state == PeerConnectionState.reconnecting) {
          _log('reconnect expired peer=${peer.peerId}; terminal disconnect');
          unawaited(peer.disconnect());
        }
      },
    );
  }

  void _pollGattReconnect(_GattReconnect reconnect) {
    if (reconnect.closed ||
        _gattReconnects[reconnect.endpointId] != reconnect) {
      return;
    }
    final nowMs = reconnect.peer._core.monotonicNowMs;
    if (reconnect.schedule.expiredAt(nowMs)) {
      _log(
        'reconnect schedule expired peer=${reconnect.peer.peerId} endpoint=${reconnect.endpointId}',
      );
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
        unawaited(
          cleanup.then<void>(
            (_) {
              reconnect.staleGenerationCleanupComplete = true;
              _pollGattReconnect(reconnect);
            },
            onError: (Object error, StackTrace stack) {
              _log(
                'stale GATT generation cleanup failed endpoint=${reconnect.endpointId} error=$error',
              );
              reconnect.staleGenerationCleanupComplete = true;
              _pollGattReconnect(reconnect);
            },
          ),
        );
        reconnect.staleGenerationCleanup = null;
      }
      return;
    }
    if (!reconnect.attempting && reconnect.schedule.attemptDue(nowMs)) {
      reconnect.attempting = true;
      final remainingMs =
          reconnect.schedule.startedAtMs + reconnect.schedule.timeoutMs - nowMs;
      _log(
        'reconnect attempt endpoint=${reconnect.endpointId} peer=${reconnect.peer.peerId} remainingMs=${remainingMs < 0 ? 0 : remainingMs} failureCount=${reconnect.schedule.failedAttempts}',
      );
      unawaited(() async {
        try {
          await _platformBleBackend!.connectGatt(reconnect.endpointId);
        } on Object catch (error) {
          if (_isEndpointBusyError(error)) {
            await _closeBusyGattEndpoint(
              _platformBleBackend!,
              reconnect.endpointId,
            );
          }
          _log(
            'reconnect platform request failed endpoint=${reconnect.endpointId} error=$error',
          );
          _reconnectAttemptFailed(reconnect);
        }
      }());
    }
  }

  Future<void> _closeStaleGattGeneration(
    String endpointId,
    PlatformGattConnectionBinding? binding,
    _GattReconnect reconnect, {
    int? staleGeneration,
  }) async {
    _log(
      'closing stale GATT generation before reconnect endpoint=$endpointId peer=${reconnect.peer.peerId}',
    );
    // Remove the event subscription first so the old binding cannot consume a
    // fragment or writable callback after the logical peer has entered its
    // next generation. GattBackendConnection.close then releases the native
    // client handle that Android otherwise reports as ENDPOINT_BUSY.
    if (binding != null) {
      await binding.close();
      await binding.connection.close();
    } else {
      // The Dart binding may already have been removed by the platform
      // disconnect callback while the native client handle is still being
      // released. Keep the old generation on this fallback close. An
      // unscoped close can otherwise tear down a replacement GATT generation
      // that connected while the old callback was still draining, producing
      // the immediate READY->RECONNECTING loop seen on iOS/macOS and the
      // ENDPOINT_BUSY/callback churn seen on Android.
      _rememberNativeCloseRequested(
        endpointId,
        connectionGeneration: staleGeneration,
      );
      await _platformBleBackend?.closeGattConnection(
        endpointId,
        connectionGeneration: staleGeneration,
      );
    }
    _log(
      'stale GATT generation closed before reconnect endpoint=$endpointId peer=${reconnect.peer.peerId}',
    );
  }

  void _reconnectAttemptFailed(_GattReconnect reconnect) {
    if (reconnect.closed ||
        _gattReconnects[reconnect.endpointId] != reconnect) {
      return;
    }
    reconnect.attempting = false;
    if (reconnect.discoveryCandidate) {
      // A scanned endpoint is not known to belong to this PeerId until the
      // candidate handshake authenticates it. Do not keep retrying the same
      // nearby endpoint at the reconnect timer rate after a failed identity
      // or transport attempt; wait for a later advertisement instead.
      _gattReconnects.remove(reconnect.endpointId);
      // This endpoint was only a speculative observation.  It must not keep
      // the logical peer marked as waiting on that one observation: with
      // several nearby devices, the first advertisement can belong to a
      // different PeerId and its native connect may time out while the real
      // peer is already advertising.  Leaving this set populated starves the
      // correct endpoint until the reconnect deadline (15 seconds by
      // default), which appeared as a systematic long reconnect on Android
      // and iOS even though the transport itself was available.
      _reconnectWaitingForDiscovery.remove(reconnect.peer);
      final nowMs = reconnect.peer._core.monotonicNowMs;
      if (reconnect.schedule.attemptDue(nowMs)) {
        reconnect.schedule.attemptFailed(nowMs);
      }
      reconnect.dispose();
      _deferKnownPeerProbe(reconnect.endpointId);
      _log(
        'reconnect discovery candidate released endpoint=${reconnect.endpointId} peer=${reconnect.peer.peerId}',
      );
      return;
    }
    _log(
      'reconnect attempt failed endpoint=${reconnect.endpointId} peer=${reconnect.peer.peerId}',
    );
    final nowMs = reconnect.peer._core.monotonicNowMs;
    if (reconnect.schedule.attemptDue(nowMs)) {
      reconnect.schedule.attemptFailed(nowMs);
    }
  }

  void _finishGattResume(PeerConnection peer, String retainedEndpointId) {
    _reconnectWaitingForDiscovery.remove(peer);
    _reconnectWaitingSchedules.remove(peer);
    final candidates = _gattReconnects.entries
        .where((entry) => identical(entry.value.peer, peer))
        .toList(growable: false);
    for (final entry in candidates) {
      _gattReconnects.remove(entry.key);
      entry.value.dispose();
      if (entry.key != retainedEndpointId) {
        // Another candidate may have reached native connected or even begun
        // candidate RESUME before this one won. Close that physical link so
        // its task cannot later race the already READY logical session.
        // Keep the losing endpoint suppressed as well: discovery can report
        // it again after the native close, and treating it as a fresh
        // known-peer probe would recreate the crossed-RESUME loop.
        _suppressKnownProbeForOwner(entry.key, peer);
        unawaited(_closeGattBinding(entry.key, preserveSharedLink: true));
      }
    }
  }

  Future<void> _startGattResume(
    PlatformGattConnected event,
    _GattReconnect reconnect,
  ) async {
    final backend = _platformBleBackend!;
    final identity = _identity!;
    final peer = reconnect.peer;
    Future<T> bounded<T>(Future<T> future, String phase) {
      final remaining =
          reconnect.schedule.startedAtMs +
          reconnect.schedule.timeoutMs -
          peer._core.monotonicNowMs;
      if (remaining <= 0) {
        throw const LpcException(
          LpcErrorCode.connectionTimeout,
          'resume deadline exceeded',
        );
      }
      return future.timeout(
        Duration(milliseconds: remaining),
        onTimeout: () => throw LpcException(
          LpcErrorCode.connectionTimeout,
          'resume $phase timed out',
        ),
      );
    }

    try {
      if (peer.state != PeerConnectionState.reconnecting) {
        throw const LpcException(LpcErrorCode.invalidState);
      }
      _log(
        'resume handshake start endpoint=${event.endpointId} peer=${peer.peerId} generation=${peer._core.generation}',
      );
      final previousEndpoint = _gattLinks[peer]?.endpointId;
      await _gattBindings.remove(event.endpointId)?.close();
      final connection = GattBackendConnection(
        connectionId: event.endpointId,
        logger: (message) => _log(
          'gatt endpoint=${event.endpointId} generation=${event.connectionGeneration} $message',
        ),
        platform: PlatformGattFragmentPlatform(
          backend: backend,
          endpointId: event.endpointId,
          platformSafeWriteSize: event.platformSafeWriteSize,
          connectionGeneration: event.connectionGeneration,
          onCloseRequested: () => _rememberNativeCloseRequested(
            event.endpointId,
            connectionGeneration: event.connectionGeneration,
          ),
        ),
        localRole: event.localRole == 'central'
            ? GattLinkRole.central
            : GattLinkRole.peripheral,
        maxQueuedBytes: config.maxQueuedBytesPerPeer,
        fragmentTimeoutMs: config.gattFragmentInactivityTimeoutMs,
      );
      _gattBindings[event.endpointId] = PlatformGattConnectionBinding(
        backend: backend,
        endpointId: event.endpointId,
        connection: connection,
        connectionGeneration: event.connectionGeneration,
      );
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
              16,
              (_) => Random.secure().nextInt(256),
            ),
            peerCapabilities: PeerCapabilityBitmap(const [
              PeerCapability.gattBaseline,
              PeerCapability.resume,
            ]).value,
            keepaliveIntervalMs: config.keepaliveIntervalMs,
            trustMode: trustMode,
          ),
          localIdentityKeyPair: identity.keyPair,
          localEphemeralKeyPair: ephemeral,
          knownPeerPolicy: trustMode == HandshakeTrustMode.knownPeer
              ? ExpectExactPeer(peer.peerId)
              : null,
          tofuStore: trustMode == HandshakeTrustMode.tofu ? _tofuStore : null,
          psk32: trustMode == HandshakeTrustMode.psk32 ? config.psk32 : null,
        ),
      );
      final ready = handshake.ready;
      final authenticated = handshake.authenticated;
      // A candidate resume can be terminated by the reconnect deadline
      // before AUTH completes. Observe every handshake outcome so the
      // expected transport-closed error is consumed instead of surfacing as
      // an unhandled Flutter error.
      unawaited(ready.then<void>((_) {}, onError: (_, __) {}));
      unawaited(authenticated.then<void>((_) {}, onError: (_, __) {}));
      await bounded(handshake.start(), 'handshake');
      final candidate = await bounded(authenticated, 'authentication');
      _log(
        'resume candidate authenticated endpoint=${event.endpointId} peer=${peer.peerId}',
      );
      await backend.associateGattPeer(event.endpointId, peer.peerId);
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
        requester: true,
        negotiatedMinor: peer._core.negotiatedMinor,
      );
      await bounded(resume.start(), 'proof start');
      final resumed = await bounded(resume.completed, 'proof');
      // A crossed inbound candidate may have won while this candidate was
      // proving RESUME.  _finishGattResume disposes this reconnect record in
      // that case; committing here would rebind a stale generation and can
      // close the already healthy replacement on the next native callback.
      if (reconnect.closed ||
          _gattReconnects[event.endpointId] != reconnect ||
          peer.state != PeerConnectionState.reconnecting) {
        _log(
          'resume candidate lost race endpoint=${event.endpointId} peer=${peer.peerId}',
        );
        await _closeGattBinding(
          event.endpointId,
          connectionGeneration: event.connectionGeneration,
        );
        return;
      }
      _log(
        'resume proof accepted endpoint=${event.endpointId} peer=${peer.peerId} generation=${resumed.generation}',
      );
      peer._core.completeResume(
        newGeneration: resumed.generation,
        resumedSessionRootKey: resumed.sessionRootKey,
        newResumeSecret: resumed.resumeSecret,
        resumedBackend: connection,
      );
      peer._resumeCommitted();
      // Publish the new physical generation before replay.  Android and
      // CoreBluetooth can report the old GATT disconnect after the new RESUME
      // proof has succeeded.  Keeping the old endpoint in the runtime map
      // until replay completes lets that late callback incorrectly mark the
      // resumed logical peer as reconnecting again.
      _gattLinks[peer] = _GattLink(
        event.endpointId,
        event.localRole == 'central',
        connectionGeneration: event.connectionGeneration,
        candidateStartedAtMs:
            _gattCandidateStartedAtMs[event.endpointId] ?? _monotonicMs,
        readyAtMs: _monotonicMs,
      );
      _gattPeersByEndpoint[event.endpointId] = peer;
      if (event.physicalEndpointId != null) {
        _authenticatedPeerByPhysicalEndpoint[event.physicalEndpointId!] = peer;
      }
      _gattCandidateStartedAtMs.remove(event.endpointId);
      if (previousEndpoint != null && previousEndpoint != event.endpointId) {
        if (_gattPeersByEndpoint[previousEndpoint] == peer) {
          _gattPeersByEndpoint.remove(previousEndpoint);
        }
      }
      _log(
        'resume state ready endpoint=${event.endpointId} peer=${peer.peerId}',
      );
      _finishGattResume(peer, event.endpointId);
      // RESUME commits the logical state before replay. Replay is best-effort
      // transport work and must not hold the reconnect watchdog hostage when
      // a native write future stalls during a flaky handoff.
      _gattReconnectExpiryTimers.remove(peer)?.cancel();
      try {
        await Future.wait<void>([
          peer._core
              .retransmitReliableDataAfterResume(
                nowMs: peer._core.monotonicNowMs,
              )
              .then<void>((_) {}),
          peer._core
              .retransmitAckRequiredFramesAfterResume(
                nowMs: peer._core.monotonicNowMs,
              )
              .then<void>((_) {}),
        ]).timeout(const Duration(seconds: 5));
      } on Object catch (error) {
        _log(
          'resume replay deferred endpoint=${event.endpointId} peer=${peer.peerId} error=$error',
        );
      }
      if (peer.state != PeerConnectionState.ready) {
        _log(
          'resume transport lost during replay endpoint=${event.endpointId} peer=${peer.peerId}',
        );
        _reconnectAttemptFailed(reconnect);
        return;
      }
      // Endpoint ownership was committed with the RESUME proof above so
      // delayed callbacks from the old generation cannot affect this peer.
      _reconnectWaitingForDiscovery.remove(peer);
      _reconnectWaitingSchedules.remove(peer);
      if (previousEndpoint != null && previousEndpoint != event.endpointId) {
        await _gattBindings.remove(previousEndpoint)?.close();
      }
      reconnect.dispose();
    } on Object catch (error) {
      final lpcError = _asLpcError(error);
      _log(
        'resume failed endpoint=${event.endpointId} peer=${peer.peerId} error=$error',
      );
      try {
        await _closeGattBinding(
          event.endpointId,
          connectionGeneration: event.connectionGeneration,
        );
      } on Object catch (cleanupError) {
        _log(
          'resume binding cleanup failed endpoint=${event.endpointId} error=$cleanupError',
        );
      }
      // A crossed RESUME can commit on the opposite physical candidate while
      // this task is unwinding its loser.  The winning path has already
      // rebound the logical core to READY and disposed this reconnect record;
      // do not feed the loser back into reconnect scheduling or let its late
      // native close be interpreted as loss of the winning generation.
      if (reconnect.closed ||
          _gattReconnects[event.endpointId] != reconnect ||
          peer.state != PeerConnectionState.reconnecting) {
        _log(
          'resume candidate lost race during failure cleanup endpoint=${event.endpointId} peer=${peer.peerId}',
        );
        return;
      }
      if (lpcError.code == LpcErrorCode.resumeRejected &&
          !reconnect.closed &&
          _gattReconnects[event.endpointId] == reconnect &&
          peer.state == PeerConnectionState.reconnecting) {
        // A restarted peer can authenticate this candidate but cannot prove
        // the old session. Start a normal known-peer candidate promptly after
        // the rejected physical binding has closed. _ownPeer() will replace
        // the reconnecting logical owner only after the fresh HELLO/AUTH/READY
        // exchange succeeds; if it does not, the existing reconnect expiry
        // remains the bounded terminal fallback.
        _gattReconnects.remove(event.endpointId);
        reconnect.dispose();
        _markFreshHandshakeHandoff(event.endpointId, peer.peerId);
        _knownPeerProbeNotBeforeMs.remove(event.endpointId);
        Future<void>.delayed(const Duration(milliseconds: 250), () {
          if (_state != RuntimeState.ready ||
              peer.state != PeerConnectionState.reconnecting ||
              _attempts.containsKey(event.endpointId) ||
              _gattBindings.containsKey(event.endpointId) ||
              _gattReconnects.containsKey(event.endpointId) ||
              _automaticProbeEndpoints.contains(event.endpointId) ||
              _closingGattEndpoints.contains(event.endpointId)) {
            _releaseFreshHandshakeHandoff(event.endpointId);
            return;
          }
          _startKnownPeerProbe(event.endpointId);
        });
        return;
      }
      _reconnectAttemptFailed(reconnect);
    }
  }

  void _markFreshHandshakeHandoff(String endpointId, PeerId peerId) {
    _freshHandshakeHandoffEndpoints.add(endpointId);
    _freshHandshakeHandoffPeers[endpointId] = peerId;
    _freshHandshakeHandoffTimers.remove(endpointId)?.cancel();
    _freshHandshakeHandoffTimers[endpointId] = Timer(
      _freshHandshakeHandoffTimeout,
      () => _releaseFreshHandshakeHandoff(endpointId),
    );
  }

  void _releaseFreshHandshakeHandoff(String endpointId) {
    _freshHandshakeHandoffEndpoints.remove(endpointId);
    _freshHandshakeHandoffPeers.remove(endpointId);
    _freshHandshakeHandoffTimers.remove(endpointId)?.cancel();
  }

  void _releaseFreshHandshakeHandoffForPeer(PeerId peerId) {
    final endpoints = _freshHandshakeHandoffPeers.entries
        .where((entry) => entry.value == peerId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final endpointId in endpoints) {
      _releaseFreshHandshakeHandoff(endpointId);
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
        LpcErrorCode.unsupportedCapability,
        'GATT is disabled',
      );
    }
    final backend = _platformBleBackend;
    if (backend == null) {
      throw const LpcException(
        LpcErrorCode.unsupportedCapability,
        'no platform BLE backend',
      );
    }
    final key = _serviceKey(config.serviceUuid);
    if (_discoveries.containsKey(key) || !_startingDiscovery.add(key)) {
      throw const LpcException(
        LpcErrorCode.invalidState,
        'discovery is already active for this service UUID',
      );
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
      subscription = backend.events.listen(
        (event) {
          if (event case PlatformEndpointFound()) {
            session.recordEndpoint(
              DiscoveredEndpoint(
                event.endpointId,
                rssi: event.rssi,
                localName: event.localName,
              ),
            );
          }
        },
        onError: (Object error, StackTrace stack) {
          // A platform scan error should not terminate the runtime's discovery
          // stream (the app may choose to retry or show its own diagnostics).
          debugPrint('[LocalPeerConnections] discovery backend error: $error');
        },
      );
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

  GroupSession joinOrCreateGroup(
    GroupConfig config, {
    GroupId? groupId,
    PeerId? initialCoordinator,
  }) {
    if (_state != RuntimeState.ready)
      throw const LpcException(LpcErrorCode.invalidState);
    final profile = _AutoGroupHandshakeProfile(config);
    final activeProfile = _autoGroupProfile;
    if (activeProfile != null && !activeProfile.matches(profile)) {
      throw const LpcException(
        LpcErrorCode.invalidState,
        'active GroupSessions require one AUTO_GROUP handshake profile',
      );
    }
    for (final host in _advertisingHosts) {
      if (host.config.autoAccept && !_hostMatchesGroupProfile(host, profile)) {
        throw const LpcException(
          LpcErrorCode.invalidState,
          'HostSession and AUTO_GROUP inbound profiles are incompatible',
        );
      }
    }
    final random = Random.secure();
    late final GroupSession group;
    group = GroupSession.internal(
      config,
      localPeerId,
      groupId ?? GroupId(List<int>.generate(16, (_) => random.nextInt(256))),
      initialCoordinator: initialCoordinator,
      onClosed: _groupClosed,
      onMembershipCommitted: _groupMembershipCommitted,
    );
    final routing = _RuntimeGroupRouteTransport(
      group: group,
      peers: () => Set.unmodifiable(_groupPeers[group] ?? const {}),
      // A process restart can recreate the GroupSession after the
      // authenticated PeerConnection has already been restored.  In that
      // ordering the session membership is authoritative, but the
      // Runtime-owned route-peer cache may still be empty.  Let the route
      // transport reconcile that cache immediately before it resolves a
      // hop, rather than making upper layers retry or choose a reconnect
      // direction.
      syncPeers: () => _syncGroupPeers(group),
      maxReservedBytesPerDestination: this.config.maxQueuedBytesPerPeer,
      maxReservedMessagesPerDestination: this.config.maxQueuedMessagesPerPeer,
      logger: _log,
    );
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
    _syncGroupPeers(group, memberIds: memberIds);
  }

  void _syncGroupPeers(GroupSession group, {Set<PeerId>? memberIds}) {
    final previous = _groupPeers[group] ?? <PeerConnection>{};
    final profile = _autoGroupProfile;
    final committedMemberIds =
        memberIds ?? group.members.map((member) => member.peerId).toSet();
    final next = _peers
        .where(
          (peer) =>
              committedMemberIds.contains(peer.peerId) &&
              (profile == null || _peerMatchesGroupProfile(peer, profile)),
        )
        .toSet();
    _groupPeers[group] = next;
    if (previous.length != next.length ||
        previous.any((peer) => !next.contains(peer))) {
      _log(
        'group route peers synchronized group=${_debugId(group.groupId.bytes)} members=${committedMemberIds.join(',')} peers=${next.map((peer) => '${peer.peerId}:${peer.state}').join(',')}',
      );
    }
    for (final peer in previous.difference(next)) {
      if (!_hasOtherOwner(peer)) unawaited(peer.disconnect());
    }
  }

  bool _peerMatchesGroupProfile(
    PeerConnection peer,
    _AutoGroupHandshakeProfile profile,
  ) {
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
    HostSession host,
    _AutoGroupHandshakeProfile groupProfile,
  ) {
    return _hostMatchesGroupProfileForConfig(host.config, groupProfile);
  }

  bool _hostMatchesGroupProfileForConfig(
    HostConfig host,
    _AutoGroupHandshakeProfile groupProfile,
  ) {
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
        await backend.startAdvertising(
          config.serviceUuid,
          localName: _discoveryDisplayName,
        );
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
        LpcErrorCode.unsupportedCapability,
        'GATT is disabled',
      );
    }
    final backend = _platformBleBackend;
    if (backend == null) {
      throw const LpcException(
        LpcErrorCode.unsupportedCapability,
        'no platform BLE backend',
      );
    }
    _validateTrustCredentialsFor(
      this.config,
      config.trustMode ?? this.config.trustMode,
    );
    final groupProfile = _autoGroupProfile;
    if (config.autoAccept &&
        groupProfile != null &&
        !_hostMatchesGroupProfileForConfig(config, groupProfile)) {
      throw const LpcException(
        LpcErrorCode.invalidState,
        'HostSession and AUTO_GROUP inbound profiles are incompatible',
      );
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
            await backend.startAdvertising(
              runtimeConfig.serviceUuid,
              localName: _discoveryDisplayName,
            );
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
    await _mesh.close();
    _automaticGattConnectTimer?.cancel();
    _automaticGattConnectTimer = null;
    _automaticGattConnectInFlight = null;
    _automaticGattConnectTimedOut.clear();
    for (final timer in _knownPeerProbeTimers.values) {
      timer.cancel();
    }
    _knownPeerProbeTimers.clear();
    _knownPeerProbeNotBeforeMs.clear();
    for (final timer in _freshHandshakeHandoffTimers.values) {
      timer.cancel();
    }
    _freshHandshakeHandoffTimers.clear();
    _freshHandshakeHandoffEndpoints.clear();
    _freshHandshakeHandoffPeers.clear();
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
    for (final timer in _connectionAttemptTimers.values) {
      timer.cancel();
    }
    _connectionAttemptTimers.clear();
    _attempts.clear();
    for (final peer in List<PeerConnection>.from(_peers)) {
      await peer.disconnect();
    }
    _peers.clear();
    _authenticatedPeerByPhysicalEndpoint.clear();
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
    _gattConnectedEvents.clear();
    _gattCandidateStartedAtMs.clear();
    _recoveringOrphanedGattEndpoints.clear();
    _authenticatedAutomaticProbePeers.clear();
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
        LpcErrorCode.protocolMismatch,
        'missing authenticated HELLO',
      );
    }
    return connectionRank(
      peerA: localPeerId,
      peerB: remote.peerId,
      connectionNonceA: handshake.exchange.localHello.connectionNonce,
      connectionNonceB: remote.connectionNonce,
    );
  }

  Future<PeerConnection> _ownPeer(
    PeerConnectionCore core, {
    required SecurityLevel securityLevel,
    String? gattEndpointId,
    int? gattConnectionGeneration,
    String? physicalEndpointId,
    List<int>? connectionRank,
    List<int> remoteApplicationMetadata = const [],
  }) async {
    if (gattEndpointId != null &&
        _blockedDirectPeersForTesting.contains(core.remotePeerId)) {
      // Enforce the fixture topology only after HELLO/AUTH identified the
      // actual PeerId. Rejecting by ephemeral BLE endpoint here would allow
      // a rotating address or another nearby friend to bypass the test.
      await core.close();
      throw const LpcException(
        LpcErrorCode.transportClosed,
        'direct physical edge disabled by local test fixture',
      );
    }
    if (gattEndpointId != null) {
      _lastAuthenticatedPeerByEndpoint.remove(gattEndpointId);
      _lastAuthenticatedPeerByEndpoint[gattEndpointId] = core.remotePeerId;
      while (_lastAuthenticatedPeerByEndpoint.length >
          _maxLastAuthenticatedEndpointHints) {
        _lastAuthenticatedPeerByEndpoint.remove(
          _lastAuthenticatedPeerByEndpoint.keys.first,
        );
      }
    }
    // Some mobile BLE stacks do not report a disconnect when the remote app
    // is killed. In that case the old object can remain READY while its
    // authenticated receive-side keepalive deadline has expired. Compare the
    // physical endpoint before retiring it so a different peer's probe stays
    // independent, and so a duplicate callback for the same endpoint is still
    // handled by the normal per-endpoint coalescing path.
    final staleReady = _peers
        .where((peer) {
          if (peer.peerId != core.remotePeerId ||
              peer.state != PeerConnectionState.ready ||
              peer.securityLevel != securityLevel ||
              !peer._core.livenessExpired) {
            return false;
          }
          if (gattEndpointId == null) return false;
          final oldEndpoint = _gattLinks[peer]?.endpointId;
          return oldEndpoint == null || oldEndpoint != gattEndpointId;
        })
        .toList(growable: false);
    for (final old in staleReady) {
      _log(
        'retiring stale READY peer=${old.peerId} oldEndpoint=${_gattLinks[old]?.endpointId ?? 'none'} candidateEndpoint=${gattEndpointId ?? 'none'} reason=keepalive-dead-timeout',
      );
      // This transitions the old logical owner into the existing reconnecting
      // replacement path below. It deliberately does not close the new,
      // authenticated candidate or affect any other PeerId.
      old._platformTransportLost();
    }
    if (gattEndpointId != null) {
      // A newly authenticated physical path supersedes an end-to-end relay
      // for the same PeerId. Close only the virtual backend, never the relay's
      // own direct BLE link. This avoids presenting duplicate online friends.
      for (final virtual
          in _peers
              .where(
                (peer) => peer.peerId == core.remotePeerId && peer.isRelayed,
              )
              .toList()) {
        await virtual.disconnect();
      }
    }
    // A process restart cannot present the previous RESUME secret, so the
    // restarted peer may arrive as a fresh authenticated READY connection
    // while the old logical owner is still RECONNECTING.  Keep one logical
    // owner per compatible PeerId: cancel the stale reconnect machinery and
    // retire that old object before attaching group/host ownership to this
    // authenticated replacement.  Without this, the old expiry timer can
    // later disconnect the replacement path and a GroupSession never sees a
    // usable transport-generation change for current-state catch-up.
    final reconnecting = _peers
        .where(
          (peer) =>
              peer.peerId == core.remotePeerId &&
              peer.state == PeerConnectionState.reconnecting &&
              peer.securityLevel == securityLevel,
        )
        .toList(growable: false);
    for (final old in reconnecting) {
      _log(
        'replacing reconnecting peer=${old.peerId} with fresh authenticated connection',
      );
      _gattReconnectExpiryTimers.remove(old)?.cancel();
      _reconnectWaitingForDiscovery.remove(old);
      _reconnectWaitingSchedules.remove(old)?.cancel();
      final reconnects = _gattReconnects.entries
          .where((entry) => identical(entry.value.peer, old))
          .toList(growable: false);
      for (final entry in reconnects) {
        _gattReconnects.remove(entry.key);
        entry.value.dispose();
      }
      // A fresh candidate can reuse the same opaque endpoint ID as the
      // reconnecting owner (notably on CoreBluetooth server endpoints). The
      // old PeerConnection's disconnect callback must not close the new
      // candidate binding after ownership is transferred. Remove the old
      // endpoint mapping before disconnecting it; the new authenticated
      // candidate will install its mapping immediately after this method
      // returns. Different endpoints retain the normal stale-link cleanup.
      if (gattEndpointId != null &&
          _gattLinks[old]?.endpointId == gattEndpointId) {
        _gattPeersByEndpoint.remove(gattEndpointId);
        _gattLinks.remove(old);
      }
      await old.disconnect();
    }
    final duplicate = _peers
        .where(
          (peer) =>
              peer.peerId == core.remotePeerId &&
              peer.state == PeerConnectionState.ready,
        )
        .toList(growable: false);
    final candidateStartedAtMs = gattEndpointId == null
        ? _monotonicMs
        : (_gattCandidateStartedAtMs[gattEndpointId] ?? _monotonicMs);
    Future<void> closeDuplicateCandidate() async {
      // The duplicate decision below is made only after both transports have
      // authenticated the same PeerId. On Android, however, the losing
      // central and the winning peripheral can share one controller ACL. A
      // normal close of the losing central can therefore tear down the
      // winning link and start the reconnect loop seen on MiPad/iPhone.
      // Mark the native close as parkable before closing the handshake, then
      // remove the Dart binding while the native plugin retains the handle
      // until the selected server link ends.
      final candidateBackend = core.backend;
      final canPreserveSharedLink =
          gattEndpointId != null &&
          candidateBackend is GattBackendConnection &&
          candidateBackend.localRole == GattLinkRole.central;
      if (canPreserveSharedLink) {
        (candidateBackend as GattBackendConnection).preserveNativeLinkOnClose();
      }
      await core.close();
      if (canPreserveSharedLink) {
        await _closeGattBinding(gattEndpointId!, preserveSharedLink: true);
      }
    }

    String? displacedDuplicateEndpoint;
    if (duplicate.isNotEmpty) {
      final existing = duplicate.first;
      if (core.backend is MeshBackendConnection && !existing.isRelayed) {
        await core.close();
        return existing;
      }
      _log(
        'duplicate READY peer=${core.remotePeerId} existingState=${existing.state.name} existingSecurity=${existing.securityLevel.name} candidateSecurity=${securityLevel.name}',
      );
      // A matching PeerId alone is not a compatible logical owner. This
      // portable binding does not multiplex distinct security sessions, so it
      // rejects that request rather than relabeling or downgrading either one.
      if (existing.securityLevel != securityLevel) {
        _log(
          'duplicate rejected peer=${core.remotePeerId} reason=incompatible-security',
        );
        await closeDuplicateCandidate();
        throw const LpcException(
          LpcErrorCode.invalidState,
          'existing peer has an incompatible security profile',
        );
      }
      final existingLink = _gattLinks[existing];
      final overlapsExisting =
          existingLink != null &&
          existingLink.readyAtMs != null &&
          candidateStartedAtMs <= existingLink.readyAtMs!;
      if (!overlapsExisting || connectionRank == null) {
        // A later advertisement/probe is not a simultaneous duplicate race.
        // Keep the healthy authenticated owner stable even if the candidate's
        // newly generated nonce would produce a smaller rank. This prevents
        // repeated scan observations from replacing a usable link and
        // triggering a disconnect/reconnect loop on mobile BLE.
        await closeDuplicateCandidate();
        if (gattEndpointId != null) {
          _gattCandidateStartedAtMs.remove(gattEndpointId);
        }
        if (physicalEndpointId != null) {
          _authenticatedPeerByPhysicalEndpoint[physicalEndpointId] = existing;
        }
        _log(
          'duplicate candidate closed peer=${core.remotePeerId} reason=late-candidate-existing-owner',
        );
        return existing;
      }
      final existingRank = _connectionRanks[existing];
      if (existingRank == null) {
        // A legacy/manual peer without a recorded rank remains the stable
        // owner.  The new candidate is still closed before it can acquire
        // any Runtime ownership.
        await closeDuplicateCandidate();
        if (gattEndpointId != null) {
          _gattCandidateStartedAtMs.remove(gattEndpointId);
        }
        if (physicalEndpointId != null) {
          _authenticatedPeerByPhysicalEndpoint[physicalEndpointId] = existing;
        }
        _log(
          'duplicate candidate closed peer=${core.remotePeerId} reason=existing-unranked',
        );
        return existing;
      }
      final retained = retainedConnectionRankIndex(
        existingRank,
        connectionRank,
      );
      if (retained == 0) {
        // The existing authenticated logical session wins the deterministic
        // Section 10.2 tie-break.  Closing the candidate collapses its
        // redundant physical link without disturbing direct, HostSession,
        // group, or known-peer ownership of the winner.
        await core.close();
        if (gattEndpointId != null) {
          _gattCandidateStartedAtMs.remove(gattEndpointId);
        }
        if (physicalEndpointId != null) {
          _authenticatedPeerByPhysicalEndpoint[physicalEndpointId] = existing;
        }
        _log(
          'duplicate candidate closed peer=${core.remotePeerId} reason=existing-rank-wins',
        );
        return existing;
      }
      // The newly authenticated link has the smaller rank.  Replace the
      // existing logical owner only after this candidate has completed the
      // full READY exchange, so there is never an unauthenticated promotion.
      // PeerConnection.disconnect() is an explicit terminal duplicate close;
      // it does not enter the normal reconnect scheduler.
      displacedDuplicateEndpoint = _gattLinks[existing]?.endpointId;
      if (displacedDuplicateEndpoint != null) {
        _duplicateClosingEndpoints.add(displacedDuplicateEndpoint);
      }
      await existing.disconnect();
      _log(
        'duplicate existing closed peer=${core.remotePeerId} reason=candidate-rank-wins',
      );
    }
    late final PeerConnection peer;
    peer = PeerConnection._(
      core,
      securityLevel: securityLevel,
      remoteApplicationMetadata: remoteApplicationMetadata,
      onDisconnected: (_) {
        _log(
          'peer disconnected peer=${core.remotePeerId} endpoint=${gattEndpointId ?? 'none'}',
        );
        _peers.remove(peer);
        _mesh.poke();
        _connectionRanks.remove(peer);
        _reconnectWaitingForDiscovery.remove(peer);
        _reconnectWaitingSchedules.remove(peer);
        _knownProbeSuppressedByOwner.removeWhere((_, owner) => owner == peer);
        _authenticatedPeerByPhysicalEndpoint.removeWhere(
          (_, owner) => owner == peer,
        );
        _unknownPeerReleaseTimers.remove(peer)?.cancel();
        final link = _gattLinks.remove(peer);
        final endpointId = link?.endpointId ?? gattEndpointId;
        if (endpointId != null) {
          _authenticatedAutomaticProbePeers.remove(endpointId);
        }
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
              // A transport failure ends the physical candidate lifecycle.
              // Keepalive/write failures can move a PeerConnection into
              // RECONNECTING without producing PlatformGattDisconnected, so
              // the endpoint-start timestamp must be cleared here as well.
              // Otherwise a later probe of the same platform endpoint can
              // inherit the old timestamp and be misclassified as an
              // overlapping duplicate. On Android this can make a fresh
              // central candidate replace a healthy inbound GATT link; the
              // vendor stack then tears down the shared ACL and both sides
              // enter a reconnect loop.
              final failedEndpoint =
                  _gattLinks[peer]?.endpointId ?? gattEndpointId;
              if (failedEndpoint != null) {
                _gattCandidateStartedAtMs.remove(failedEndpoint);
              }
              _log(
                'peer entering reconnecting peer=${core.remotePeerId} endpoint=${_gattLinks[peer]?.endpointId ?? gattEndpointId}',
              );
              _beginGattReconnect(peer);
              _scheduleGattReconnectExpiry(peer);
            },
      onMeshFrame: (owner, frame) => _mesh.receive(owner, frame),
    );
    _peers.add(peer);
    _mesh.observe(peer);
    if (physicalEndpointId != null) {
      _authenticatedPeerByPhysicalEndpoint[physicalEndpointId] = peer;
    }
    if (displacedDuplicateEndpoint != null) {
      // At this point the candidate is about to become the stable owner. The
      // temporary close guard above covered the synchronous old-owner
      // callback; retain the bounded endpoint suppression for future scan
      // observations while this owner remains READY/RECONNECTING.
      _duplicateClosingEndpoints.remove(displacedDuplicateEndpoint);
      _knownProbeSuppressedByOwner[displacedDuplicateEndpoint] = peer;
    }
    // A READY authenticated peer is the logical owner of the session. An
    // automatic known-peer probe started from another transient platform
    // endpoint must not create a duplicate GATT session that can replace or
    // tear down this owner (notably during Android/iOS scan/connect races).
    // Reconnects are tracked separately by _gattReconnects and are not
    // cancelled by this cleanup.
    _cancelCompetingKnownPeerProbes(
      exceptEndpointId: gattEndpointId,
      owner: peer,
    );
    final gattRole = core.backend is GattBackendConnection
        ? (core.backend as GattBackendConnection).localRole?.name
        : null;
    _log(
      'peer owned peer=${peer.peerId} security=${securityLevel.name} endpoint=${gattEndpointId ?? 'none'} role=${gattRole ?? 'none'}',
    );
    for (final entry in _groupRouting.entries) {
      if (!entry.key.hasRouteTransport) {
        entry.key.attachRouteTransport(entry.value);
      }
      entry.value.observePeer(peer);
      // Routing can observe a peer before it becomes a committed group
      // member, but only committed membership creates group ownership.
      _syncGroupPeers(entry.key);
    }
    if (connectionRank != null) {
      _connectionRanks[peer] = List<int>.unmodifiable(connectionRank);
    }
    if (gattEndpointId != null && core.backend is GattBackendConnection) {
      _gattLinks[peer] = _GattLink(
        gattEndpointId,
        (core.backend as GattBackendConnection).localRole ==
            GattLinkRole.central,
        connectionGeneration: gattConnectionGeneration,
        candidateStartedAtMs: candidateStartedAtMs,
        readyAtMs: _monotonicMs,
      );
      _gattPeersByEndpoint[gattEndpointId] = peer;
      _gattCandidateStartedAtMs.remove(gattEndpointId);
    }
    return peer;
  }
}

class _MeshAdvertRecord {
  _MeshAdvertRecord(this.targets, this.receivedAtMs);
  final Set<PeerId> targets;
  final int receivedAtMs;
}

class _MeshIncompleteFrame {
  _MeshIncompleteFrame(this.count, this.updatedAtMs);
  final int count;
  int updatedAtMs;
  final List<int> bytes = [];
  int nextIndex = 0;
}

/// Friend-relay transport overlay. Only authenticated, confirmed-friend direct
/// links participate. It does not replace GroupSession routing: GroupSession
/// still selects its coordinator and sends normal protocol frames over the
/// logical PeerConnection, which may be this end-to-end encrypted virtual A-C
/// session. B owns only a bounded, opaque two-hop frame-forwarding operation.
class _MeshController {
  _MeshController(this.runtime) {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => poke());
  }

  final NearbyRuntime runtime;
  late final Timer _timer;
  final Map<PeerId, _MeshAdvertRecord> _adverts = {};
  final Map<PeerId, MeshBackendConnection> _backends = {};
  final Map<PeerId, PeerConnection> _virtualPeers = {};
  final Map<PeerId, int> _reverseRouteUntil = {};
  final Map<PeerId, int> _confirmedUntil = {};
  final Map<String, _MeshIncompleteFrame> _incomplete = {};
  final Map<PeerId, Map<int, int>> _completed = {};
  final Map<PeerConnection, Future<void>> _inbound = {};
  final Map<PeerConnection, int> _inboundDepth = {};
  int _totalInboundDepth = 0;
  final Map<PeerConnection, StreamSubscription<PeerConnectionEvent>>
  _peerEvents = {};
  int _advertGeneration = 0;
  int _lastAdvertAtMs = 0;
  String _lastAdvertFingerprint = '';
  bool _busy = false;
  bool _closed = false;

  bool get _enabled =>
      !_closed &&
      runtime.config.autoConnectKnownPeers &&
      runtime.config.knownPeerResolver != null &&
      runtime._identity != null &&
      runtime._state == RuntimeState.ready;

  void poke() {
    if (!_enabled || _busy) return;
    unawaited(_tick());
  }

  void observe(PeerConnection peer) {
    _peerEvents[peer]?.cancel();
    _peerEvents[peer] = peer.events.listen((event) {
      if (event is PeerReconnecting || event is PeerReconnected) {
        // A relayed peer's lower transport can fail while its direct relay is
        // still READY. Wake the mesh controller so it can retire the failed
        // virtual generation and authenticate a replacement on the same path.
        _lastAdvertFingerprint = '';
        poke();
      }
      _lastAdvertFingerprint = '';
      if (event is PeerDisconnected) {
        unawaited(_peerEvents.remove(peer)?.cancel());
        _inbound.remove(peer);
        _inboundDepth.remove(peer);
      }
      poke();
    });
    _lastAdvertFingerprint = '';
    poke();
  }

  void forget(PeerId peerId) {
    _confirmedUntil.remove(peerId);
    _adverts.remove(peerId);
    _reverseRouteUntil.remove(peerId);
    final backend = _backends.remove(peerId);
    if (backend != null) unawaited(backend.close());
    final virtual = _virtualPeers.remove(peerId);
    if (virtual != null) unawaited(virtual.disconnect());
    poke();
  }

  Future<bool> _friend(PeerId peerId) async {
    if (!_enabled || peerId == runtime.localPeerId) return false;
    // The runtime's authenticated known-peer classification has already
    // consulted the application resolver. Do not run a second mesh-specific
    // lookup for every advertised neighbor: it changes resolver semantics,
    // can race a mutable relationship store, and adds latency to busy BLE
    // neighborhoods. releasePeerRetention invalidates this ownership.
    if (runtime._knownRetainedPeers.contains(peerId)) return true;
    final now = runtime._monotonicMs;
    if ((_confirmedUntil[peerId] ?? 0) > now) return true;
    try {
      final confirmed = await runtime.config.knownPeerResolver!
          .isKnownPeer(peerId)
          .timeout(
            Duration(milliseconds: runtime.config.knownPeerLookupTimeoutMs),
          );
      if (confirmed) {
        if (_confirmedUntil.length >= 256) {
          _confirmedUntil.remove(_confirmedUntil.keys.first);
        }
        _confirmedUntil[peerId] = now + 5000;
      } else {
        _confirmedUntil.remove(peerId);
      }
      return confirmed;
    } on Object {
      return false;
    }
  }

  PeerConnection? _direct(PeerId peerId) => runtime._peers
      .where(
        (peer) =>
            peer.peerId == peerId &&
            peer.state == PeerConnectionState.ready &&
            peer.activeTransport != TransportType.meshRelay,
      )
      .firstOrNull;

  bool _classifiedOrExplicit(PeerConnection peer) =>
      runtime._knownRetainedPeers.contains(peer.peerId) ||
      runtime._directRetainedPeers.contains(peer.peerId) ||
      runtime._hosts.any((host) => host.peers().contains(peer));

  Future<void> _tick() async {
    if (!_enabled || _busy) return;
    _busy = true;
    try {
      final observedDirectCount = runtime._peers
          .where(
            (peer) =>
                peer.state == PeerConnectionState.ready &&
                peer.activeTransport != TransportType.meshRelay &&
                _classifiedOrExplicit(peer),
          )
          .length;
      if (observedDirectCount < 2 &&
          _adverts.isEmpty &&
          _backends.isEmpty &&
          _lastAdvertFingerprint.isEmpty) {
        // A two-device neighborhood cannot contain a relay. Do not poll the
        // application-owned friendship resolver or send mesh hints in that
        // common case; it also keeps relationship changes driven by the
        // existing known-peer probe contract rather than a second poller.
        return;
      }
      final now = runtime._monotonicMs;
      _adverts.removeWhere(
        (relay, record) =>
            _direct(relay) == null || now - record.receivedAtMs > 12000,
      );
      _incomplete.removeWhere(
        (_, operation) => now - operation.updatedAtMs > 30000,
      );
      for (final recent in _completed.values) {
        recent.removeWhere((_, receivedAt) => now - receivedAt > 30000);
      }
      _completed.removeWhere((_, recent) => recent.isEmpty);
      final direct = runtime._peers
          .where(
            (peer) =>
                peer.state == PeerConnectionState.ready &&
                peer.activeTransport != TransportType.meshRelay &&
                _classifiedOrExplicit(peer),
          )
          .toList();
      final friends = <PeerConnection>[];
      for (final peer in direct) {
        if (await _friend(peer.peerId)) friends.add(peer);
      }
      final fingerprint =
          (friends.map((peer) => peer.peerId.toString()).toList()..sort()).join(
            ',',
          );
      if (friends.isNotEmpty &&
          (fingerprint != _lastAdvertFingerprint ||
              now - _lastAdvertAtMs >= 5000)) {
        _lastAdvertFingerprint = fingerprint;
        _lastAdvertAtMs = now;
        _advertGeneration = (_advertGeneration + 1) & 0xffffffff;
        for (final peer in friends) {
          final targets =
              friends
                  .where((other) => other.peerId != peer.peerId)
                  .map((other) => other.peerId)
                  .toList()
                ..sort(_meshComparePeerIds);
          final advert = MeshAdvert(_advertGeneration, targets.take(64));
          unawaited(
            peer._core
                .submitEncrypted(
                  FrameType.meshAdvert,
                  advert.encode(),
                  priority: SendPriority.interactive,
                )
                .catchError((Object _) => TransportWriteState.failed),
          );
        }
      }
      final candidates = <PeerId, PeerId>{};
      for (final entry in _adverts.entries) {
        for (final target in entry.value.targets) {
          if (target == runtime.localPeerId || _direct(target) != null)
            continue;
          final prior = candidates[target];
          if (prior == null || _meshComparePeerIds(entry.key, prior) < 0) {
            candidates[target] = entry.key;
          }
        }
      }
      for (final entry in _backends.entries.toList()) {
        final reverseHint =
            (_reverseRouteUntil[entry.key] ?? 0) > now &&
            _direct(entry.value.relayPeerId) != null;
        final directTarget = _direct(entry.key) != null;
        final candidateRelay = candidates[entry.key];
        final directRelay = _direct(entry.value.relayPeerId) != null;
        final virtualPeer = _virtualPeers[entry.key];
        final relayChanged =
            candidateRelay != entry.value.relayPeerId && !reverseHint;
        String? retireReason;
        if (directTarget) {
          retireReason = 'direct-target-ready';
        } else if (relayChanged) {
          retireReason = 'advertised-relay-changed';
        } else if (!directRelay) {
          retireReason = 'relay-not-ready';
        } else if (!await _friend(entry.key)) {
          retireReason = 'target-not-friend';
        } else if (virtualPeer != null &&
            virtualPeer.state != PeerConnectionState.ready) {
          // A failed end-to-end write moves the virtual PeerConnection into
          // RECONNECTING but leaves its MeshBackendConnection object cached.
          // Without retiring both together, the next HELLO is blocked by the
          // stale backend entry and the UI can remain offline indefinitely,
          // even though this direct relay and its advertised route are healthy.
          retireReason = 'virtual-peer-not-ready';
        }
        if (retireReason != null) {
          runtime._log(
            'mesh route retiring target=${entry.key} relay=${entry.value.relayPeerId} '
            'reason=$retireReason '
            'candidateRelay=$candidateRelay reverseHint=$reverseHint '
            'directTarget=$directTarget directRelay=$directRelay',
          );
          await entry.value.close();
          _backends.remove(entry.key);
          final virtual = _virtualPeers.remove(entry.key);
          if (virtual != null) await virtual.disconnect();
        }
      }
      for (final entry in candidates.entries) {
        if (_backends.length >= 64) break;
        if (_backends.containsKey(entry.key) ||
            _meshComparePeerIds(runtime.localPeerId, entry.key) >= 0 ||
            !await _friend(entry.key))
          continue;
        _startVirtual(entry.key, entry.value);
      }
    } finally {
      _busy = false;
    }
  }

  void receive(PeerConnection from, LpcFrame frame) {
    if (!_enabled || from.isRelayed || frame.protocolMinor != 0) return;
    final depth = _inboundDepth[from] ?? 0;
    if (depth >= 64 || _totalInboundDepth >= 64) return;
    _inboundDepth[from] = depth + 1;
    _totalInboundDepth++;
    // Decryption can finish for the next frame while an earlier resolver
    // lookup is pending. Preserve each authenticated direct hop's frame order
    // so 4 KiB mesh chunks cannot spuriously fail reassembly on mobile BLE.
    final work = (_inbound[from] ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) => _receive(from, frame))
        .whenComplete(() {
          _totalInboundDepth--;
          final remaining = (_inboundDepth[from] ?? 1) - 1;
          if (remaining == 0) {
            _inboundDepth.remove(from);
          } else {
            _inboundDepth[from] = remaining;
          }
        });
    _inbound[from] = work;
    unawaited(work);
  }

  Future<void> _receive(PeerConnection from, LpcFrame frame) async {
    if (!await _friend(from.peerId)) {
      if (frame.type == FrameType.meshAdvert ||
          frame.type == FrameType.meshFrame) {
        runtime._log(
          'mesh frame ignored unconfirmed direct relay=${from.peerId} type=${frame.type.name}',
        );
      }
      return;
    }
    try {
      if (frame.type == FrameType.meshAdvert) {
        final advert = MeshAdvert.decode(frame.payload);
        if (advert.neighbors.contains(runtime.localPeerId) ||
            advert.neighbors.contains(from.peerId)) {
          runtime._log(
            'mesh advert rejected relay=${from.peerId} generation=${advert.generation} reason=invalid-neighbor-list',
          );
          return;
        }
        if (!_adverts.containsKey(from.peerId) && _adverts.length >= 64) return;
        _adverts[from.peerId] = _MeshAdvertRecord(
          advert.neighbors.toSet(),
          runtime._monotonicMs,
        );
        runtime._log(
          'mesh advert received relay=${from.peerId} generation=${advert.generation} neighbors=${advert.neighbors.join(',')}',
        );
        poke();
        return;
      }
      if (frame.type != FrameType.meshFrame) return;
      final packet = MeshFrame.decode(frame.payload);
      if (packet.source == from.peerId) {
        // Only a direct confirmed friend can ask this runtime to relay; the
        // next hop must itself be a READY direct confirmed friend. No packet
        // can be forwarded from a relayed link or to an arbitrary BLE target.
        final to = _direct(packet.destination);
        if (to == null) {
          if (packet.kind == MeshFrameKind.receipt || packet.chunkIndex == 0) {
            runtime._log(
              'mesh forward blocked source=${packet.source} destination=${packet.destination} via=${from.peerId} frame=${packet.frameId} reason=no-ready-direct-next-hop',
            );
          }
          return;
        }
        if (!await _friend(to.peerId)) {
          runtime._log(
            'mesh forward blocked source=${packet.source} destination=${packet.destination} via=${from.peerId} frame=${packet.frameId} reason=next-hop-not-friend',
          );
          return;
        }
        if (packet.kind == MeshFrameKind.receipt || packet.chunkIndex == 0) {
          runtime._log(
            'mesh forward source=${packet.source} destination=${packet.destination} via=${from.peerId}->${to.peerId} frame=${packet.frameId} kind=${packet.kind.name} chunk=${packet.chunkIndex}/${packet.chunkCount} bytes=${packet.bytes.length}',
          );
        }
        await to._core.submitEncrypted(
          FrameType.meshFrame,
          packet.encode(),
          priority: SendPriority.interactive,
        );
      } else if (packet.destination == runtime.localPeerId) {
        if (!await _friend(packet.source)) {
          runtime._log(
            'mesh frame rejected source=${packet.source} relay=${from.peerId} reason=source-not-friend',
          );
          return;
        }
        if (packet.kind == MeshFrameKind.receipt || packet.chunkIndex == 0) {
          runtime._log(
            'mesh frame arrived source=${packet.source} relay=${from.peerId} frame=${packet.frameId} kind=${packet.kind.name} chunk=${packet.chunkIndex}/${packet.chunkCount} bytes=${packet.bytes.length}',
          );
        }
        if (packet.kind == MeshFrameKind.receipt) {
          final backend = _backends[packet.source];
          if (backend?.relayPeerId == from.peerId) {
            backend!.receiveReceipt(packet.frameId);
          } else {
            runtime._log(
              'mesh receipt ignored source=${packet.source} relay=${from.peerId} frame=${packet.frameId} expectedRelay=${backend?.relayPeerId}',
            );
          }
        } else {
          await _receiveChunk(from.peerId, packet);
        }
      }
    } on Object catch (error) {
      runtime._log('mesh frame rejected relay=${from.peerId} reason=$error');
    }
  }

  Future<void> _receiveChunk(PeerId relay, MeshFrame packet) async {
    final key = '${packet.source}:${packet.frameId}';
    if (_completed[packet.source]?.containsKey(packet.frameId) ?? false) {
      await _sendReceipt(relay, packet);
      return;
    }
    var operation = _incomplete[key];
    if (operation == null) {
      final occupied = _incomplete.values.fold<int>(
        0,
        (sum, value) => sum + value.bytes.length,
      );
      if (packet.chunkIndex != 0 ||
          _incomplete.length >= 16 ||
          occupied + packet.bytes.length > 65536)
        return;
      operation = _MeshIncompleteFrame(packet.chunkCount, runtime._monotonicMs);
      _incomplete[key] = operation;
    }
    if (packet.chunkIndex < operation.nextIndex) {
      // A receipt can be delayed behind a busy second BLE hop, causing the
      // source to resend the same frame from chunk zero. Preserve already
      // accepted bytes; otherwise the duplicate first chunk would erase the
      // partial frame and the later chunks could never complete it.
      final start = packet.chunkIndex * meshRelayChunkBytes;
      final end = start + packet.bytes.length;
      if (end > operation.bytes.length ||
          !_sameBytes(operation.bytes.sublist(start, end), packet.bytes)) {
        _incomplete.remove(key);
      } else {
        operation.updatedAtMs = runtime._monotonicMs;
      }
      return;
    }
    if (operation.count != packet.chunkCount ||
        packet.chunkIndex != operation.nextIndex ||
        _incomplete.values.fold<int>(
                  0,
                  (sum, value) => sum + value.bytes.length,
                ) +
                packet.bytes.length >
            65536 ||
        operation.bytes.length + packet.bytes.length > 16462) {
      _incomplete.remove(key);
      return;
    }
    operation.bytes.addAll(packet.bytes);
    operation.nextIndex++;
    operation.updatedAtMs = runtime._monotonicMs;
    if (operation.nextIndex != operation.count) return;
    _incomplete.remove(key);
    if (!_completed.containsKey(packet.source) && _completed.length >= 64) {
      // Never inject without reserving a dedup slot: otherwise a lost
      // receipt would permit a retry to deliver the same inner DATA twice.
      return;
    }
    // Parsing before backend injection bounds allocations and ensures one
    // serialized LPC frame, not an arbitrary byte stream, crossed the relay.
    final inner = LpcFrame.decode(operation.bytes);
    runtime._log(
      'mesh frame reassembled source=${packet.source} relay=$relay frame=${packet.frameId} inner=${inner.type.name} bytes=${operation.bytes.length}',
    );
    var backend = _backends[packet.source];
    final existingVirtual = _virtualPeers[packet.source];
    if (inner.type == FrameType.hello &&
        !inner.encrypted &&
        existingVirtual != null) {
      // A process restart can send a fresh HELLO while this runtime still
      // considers the old relayed session READY. A failed virtual write can
      // also leave its previous generation RECONNECTING. In either case a
      // fresh authenticated handshake needs a new backend, not the stale
      // core that would reject plaintext HELLO or suppress route recovery.
      final old = _virtualPeers.remove(packet.source);
      if (old != null) await old.disconnect();
      if (backend != null) await backend.close();
      _backends.remove(packet.source);
      backend = null;
    }
    if (backend == null) {
      if (_direct(packet.source) != null) {
        runtime._log(
          'mesh HELLO rejected source=${packet.source} relay=$relay reason=direct-peer-ready',
        );
        return;
      }
      if (_backends.length >= 64) {
        runtime._log(
          'mesh HELLO rejected source=${packet.source} relay=$relay reason=virtual-link-limit',
        );
        return;
      }
      _reverseRouteUntil[packet.source] = runtime._monotonicMs + 12000;
      backend = _startVirtual(packet.source, relay);
    } else {
      _reverseRouteUntil[packet.source] = runtime._monotonicMs + 12000;
    }
    if (backend.relayPeerId != relay) {
      runtime._log(
        'mesh frame rejected source=${packet.source} relay=$relay expectedRelay=${backend.relayPeerId} inner=${inner.type.name}',
      );
      return;
    }
    backend.receiveFrame(operation.bytes);
    final recent = _completed.putIfAbsent(packet.source, () => {});
    if (recent.length >= 64) recent.remove(recent.keys.first);
    recent[packet.frameId] = runtime._monotonicMs;
    await _sendReceipt(relay, packet);
  }

  Future<void> _sendReceipt(PeerId relay, MeshFrame packet) async {
    final peer = _direct(relay);
    if (peer == null) return;
    final receipt = MeshFrame(
      kind: MeshFrameKind.receipt,
      source: runtime.localPeerId,
      destination: packet.source,
      frameId: packet.frameId,
      chunkIndex: 0,
      chunkCount: 0,
      bytes: const [],
    );
    await peer._core.submitEncrypted(
      FrameType.meshFrame,
      receipt.encode(),
      priority: SendPriority.interactive,
    );
  }

  MeshBackendConnection _startVirtual(PeerId target, PeerId relay) {
    runtime._log('mesh handshake start target=$target relay=$relay');
    final backend = MeshBackendConnection(
      localPeerId: runtime.localPeerId,
      remotePeerId: target,
      relayPeerId: relay,
      sendEnvelope: (packet) async {
        final peer = _direct(relay);
        if (peer == null || !await _friend(relay)) {
          return TransportWriteState.failed;
        }
        return peer._core.submitEncrypted(
          FrameType.meshFrame,
          packet.encode(),
          priority: SendPriority.interactive,
        );
      },
    );
    _backends[target] = backend;
    unawaited(_handshakeVirtual(target, backend));
    return backend;
  }

  Future<void> _handshakeVirtual(
    PeerId target,
    MeshBackendConnection backend,
  ) async {
    try {
      final identity = runtime._identity!;
      final ephemeral = await X25519().newKeyPair();
      final public = await ephemeral.extractPublicKey();
      if (!_enabled || _backends[target] != backend) return;
      final handshake = HandshakeConnection(
        backend: backend,
        localPeerId: runtime.localPeerId,
        remotePeerId: target,
        exchange: HandshakeExchange(
          serviceUuid: runtime.config.serviceUuid,
          localHello: HelloPayload(
            peerId: runtime.localPeerId,
            identityPublicKey: identity.publicKey.bytes,
            ephemeralPublicKey: public.bytes,
            connectionNonce: List<int>.generate(
              16,
              (_) => Random.secure().nextInt(256),
            ),
            peerCapabilities: PeerCapabilityBitmap(const [
              PeerCapability.resume,
            ]).value,
            maxMinor: 0,
            trustMode: HandshakeTrustMode.tofu,
            keepaliveIntervalMs: runtime.config.keepaliveIntervalMs,
            applicationMetadata: runtime._applicationMetadata,
          ),
          localIdentityKeyPair: identity.keyPair,
          localEphemeralKeyPair: ephemeral,
          tofuStore: runtime._tofuStore,
        ),
      );
      final ready = handshake.ready;
      unawaited(ready.then<void>((_) {}, onError: (_, __) {}));
      await handshake.start();
      final core = await ready.timeout(
        Duration(milliseconds: runtime.config.reconnectTimeoutMs),
      );
      if (!_enabled || _backends[target] != backend || !await _friend(target)) {
        await core.close();
        return;
      }
      final peer = await runtime._ownPeer(
        core,
        securityLevel: handshake.exchange.result!.createReady().securityLevel,
        remoteApplicationMetadata:
            handshake.exchange.result!.remoteHello.applicationMetadata,
      );
      if (!identical(peer._core, core)) return;
      _virtualPeers[target] = peer;
      runtime._knownRetainedPeers.add(target);
      runtime._events.add(KnownPeerConnected(runtime._monotonicMs, peer));
      runtime._log('mesh READY target=$target relay=${backend.relayPeerId}');
    } on Object catch (error) {
      runtime._log(
        'mesh handshake failed target=$target relay=${backend.relayPeerId} error=$error',
      );
      if (_backends[target] == backend) {
        _backends.remove(target);
        await backend.close();
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer.cancel();
    for (final subscription in _peerEvents.values) {
      await subscription.cancel();
    }
    _peerEvents.clear();
    for (final backend in _backends.values.toList()) {
      await backend.close();
    }
    _backends.clear();
    _reverseRouteUntil.clear();
    _adverts.clear();
    _incomplete.clear();
    _completed.clear();
  }
}

int _meshComparePeerIds(PeerId left, PeerId right) {
  for (var index = 0; index < 16; index++) {
    final comparison = left.bytes[index].compareTo(right.bytes[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
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
    required this.syncPeers,
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
  final void Function() syncPeers;
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
    committedMembers: group.members,
  );
  final Map<String, _LiveGroupHop> _ackHops = {};
  final Map<String, _LiveCheckpointHop> _checkpointHops = {};
  final Map<PeerId, CheckpointReplicationQueue> _checkpointQueues = {};
  final Map<int, _CheckpointPublicationData> _checkpointPublications = {};
  final Map<GroupMessageId, SendHandleController> _sourceHandles = {};
  final Set<PeerId> _sameGroupCatchUpPending = <PeerId>{};
  bool _membershipReconciliationPending = false;
  GroupMemberRouter? _memberRouter;
  GroupCoordinatorRouter? _coordinatorRouter;
  GroupDestinationRouter? _destinationRouter;
  String? _memberView;
  String? _coordinatorView;
  String? _destinationView;
  bool _disposed = false;

  void observePeer(PeerConnection peer) {
    if (_disposed || _frameSubscriptions.containsKey(peer)) return;
    logger(
      'group observe peer=${peer.peerId} state=${peer.state} coordinator=${group.coordinatorPeerId} localCoordinator=${group.isCoordinator} members=${group.members.map((member) => member.peerId).join(',')}',
    );
    _reassemblers[peer] = GroupReliableReassembler(
      maxIncompleteMessages: 64,
      maxIncompleteBytes: 1048576,
    );
    _checkpointReceivers[peer] = CheckpointReceiver();
    _frameSubscriptions[peer] = peer.groupFrames.listen(
      (frame) => unawaited(_receiveFrame(peer, frame)),
      onError: (_) => _onPeerLost(peer),
    );
    _ackSubscriptions[peer] = peer._core.acknowledgedMessageIds.listen(
      (messageId) => unawaited(_receiveGenericAck(peer, messageId)),
    );
    _peerEventSubscriptions[peer] = peer.events.listen((event) {
      if (event is PeerReconnecting) {
        _reassemblers[peer]?.onTransportGenerationLost();
      } else if (event is PeerReconnected) {
        unawaited(_onPeerReconnected(peer));
      } else if (event is PeerDisconnected) {
        unawaited(_onPeerDisconnected(peer));
      }
    });
    // A fresh normal READY connection for an existing member is the process
    // restart/replacement path, not only the in-session RESUME path.  Emit
    // the same current-state catch-up trigger after GROUP_INFO is usable.
    unawaited(_notifyTransportReady(peer));
    checkpointPeerReady(peer.peerId);
    if (!group.isCoordinator && peer.peerId == group.coordinatorPeerId) {
      unawaited(_rerouteMemberOperations());
    }
  }

  @override
  void submitReliable(
    RoutedGroupOperation operation,
    SendHandleController controller,
  ) {
    _sourceHandles[operation.groupMessageId] = controller;
    logger(
      'group source submit group=${_debugId(operation.groupId.bytes)} source=${operation.sourcePeerId} destination=${operation.destinationPeerId} message=${_debugId(operation.groupMessageId.bytes)} coordinator=${group.coordinatorPeerId} localCoordinator=${group.isCoordinator}',
    );
    unawaited(() async {
      try {
        if (_membershipReconciliationPending) {
          // Do not route application operations using a locally retained view
          // after the current coordinator has confirmed that this PeerId is
          // absent. A following membership snapshot or GROUP_MERGE will
          // release this gate after reconciliation.
          controller.complete(SendState.failed);
          _sourceHandles.remove(operation.groupMessageId);
          logger(
            'group source submit rejected pending membership reconciliation local=${group.localPeerId} destination=${operation.destinationPeerId}',
          );
          return;
        }
        if (group.isCoordinator) {
          await _admitLocalCoordinatorOperation(operation);
          return;
        }
        final coordinator = group.coordinatorPeerId;
        final peer = coordinator == null ? null : _readyPeer(coordinator);
        if (peer == null) {
          logger(
            'group source submit deferred failed: coordinator=$coordinator groupState=${group.state} groupMembers=${group.members.map((member) => member.peerId).join(',')} routePeers=${peers().map((candidate) => '${candidate.peerId}:${candidate.state}').join(',')}',
          );
          controller.complete(SendState.failed);
          _sourceHandles.remove(operation.groupMessageId);
          return;
        }
        _member().begin(operation);
        await _submitHop(
          peer,
          operation,
          finalHop: false,
          sourceOperation: operation,
        );
      } on Object catch (error) {
        logger(
          'group source submit failed source=${operation.sourcePeerId} destination=${operation.destinationPeerId} message=${_debugId(operation.groupMessageId.bytes)} error=$error',
        );
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
    CheckpointApplicationValidationRequirement validationRequirement,
  ) {
    if (_disposed ||
        !group.isCoordinator ||
        !group.config.coordinatorCheckpointing) {
      return;
    }
    final value = _CheckpointPublicationData(
      handle,
      Uint8List.fromList(bytes),
      coordinatorTerm,
      validationRequirement,
    );
    logger(
      'checkpoint publish publication=${handle.publicationId} term=$coordinatorTerm bytes=${bytes.length} validation=$validationRequirement members=${group.members.length}',
    );
    _checkpointPublications[handle.publicationId] = value;
    for (final peerId
        in group.members
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
      latest.publication.applicationValidationRequirement,
    );
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
          value.handle,
          peerId,
          CheckpointPeerResult.peerLeft,
          checkpointSequence: operation.sequence,
        );
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
    PeerConnection peer,
    _CheckpointPublicationData publication,
  ) {
    if (_disposed || peer.state != PeerConnectionState.ready) return;
    final queue = _checkpointQueues.putIfAbsent(
      peer.peerId,
      CheckpointReplicationQueue.new,
    );
    final operation = queue.publish(
      publication.bytes,
      publicationId: publication.handle.publicationId,
    );
    if (operation != null) {
      _sendCheckpoint(peer, operation, publication);
    }
  }

  void _sendCheckpoint(
    PeerConnection peer,
    CheckpointReplicationOperation operation,
    _CheckpointPublicationData value,
  ) {
    if (_disposed || peer.state != PeerConnectionState.ready) return;
    final chunks = chunkCheckpoint(
      value.bytes,
      term: value.coordinatorTerm,
      sequence: operation.sequence,
      requiresApplicationValidation:
          value.validationRequirement ==
          CheckpointApplicationValidationRequirement.required,
    );
    final messageId = peer._core.messageIdAllocator!.allocate();
    final hop = _LiveCheckpointHop(
      peer: peer,
      messageId: messageId,
      chunks: chunks,
      operation: operation,
      publication: value.handle,
    );
    logger(
      'checkpoint send peer=${peer.peerId} publication=${value.handle.publicationId} sequence=${operation.sequence} message=${_debugId(messageId)} chunks=${chunks.length} bytes=${value.bytes.length}',
    );
    _checkpointHops[_hopKey(peer, messageId)] = hop;
    group.checkpointOperationStarted(value.handle, peer.peerId);
    unawaited(() async {
      try {
        final results = await peer._core.submitAckRequiredCheckpoint(
          chunks: chunks,
          messageId: messageId,
          nowMs: peer._core.monotonicNowMs,
        );
        logger(
          'checkpoint submitted peer=${peer.peerId} publication=${value.handle.publicationId} message=${_debugId(messageId)} results=$results state=${peer.state}',
        );
        if (results.any(
          (result) => result != TransportWriteState.submittedToPlatform,
        )) {
          _logCheckpointFailure(
            peer,
            hop,
            CheckpointPeerResult.sessionTerminated,
          );
        }
      } on Object {
        if (peer.state == PeerConnectionState.disconnected) {
          _finishCheckpoint(peer, hop, CheckpointPeerResult.sessionTerminated);
        }
      }
    }());
  }

  void _logCheckpointFailure(
    PeerConnection peer,
    _LiveCheckpointHop hop,
    CheckpointPeerResult result,
  ) {
    if (peer.state == PeerConnectionState.disconnected) {
      _finishCheckpoint(peer, hop, result);
    }
  }

  void _finishCheckpoint(
    PeerConnection peer,
    _LiveCheckpointHop hop,
    CheckpointPeerResult result,
  ) {
    final key = _hopKey(peer, hop.messageId);
    if (_checkpointHops.remove(key) == null) return;
    group.checkpointOperationFinished(
      hop.publication,
      peer.peerId,
      result,
      checkpointSequence: hop.operation.sequence,
    );
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
    GroupRealtimeDatagram datagram,
    RealtimeSendHandleController controller,
  ) {
    unawaited(() async {
      try {
        if (_membershipReconciliationPending) {
          controller.complete(SendState.failed);
          return;
        }
        final target = group.isCoordinator
            ? _readyPeer(datagram.destinationPeerId)
            : _readyPeer(group.coordinatorPeerId!);
        if (target == null) {
          controller.complete(SendState.failed);
          return;
        }
        final result = await target._core.submitEncrypted(
          FrameType.groupRealtimeDatagram,
          datagram.encode(),
        );
        controller.complete(
          result == TransportWriteState.submittedToPlatform
              ? SendState.sentToTransport
              : SendState.failed,
        );
      } on Object {
        controller.complete(SendState.failed);
      }
    }());
  }

  GroupMemberRouter _member() {
    final coordinator = group.coordinatorPeerId;
    if (coordinator == null)
      throw const LpcException(LpcErrorCode.invalidState);
    final view = _routingView(coordinator);
    final existing = _memberRouter;
    if (existing != null && _memberView == view) {
      return existing;
    }
    _memberView = view;
    // A restart can restore GroupSession membership without changing its
    // coordinator PeerId. The validator must nevertheless follow the whole
    // committed roster, or a send to a newly restored member is rejected
    // against the stale pre-restart view. Preserve bounded in-flight sends
    // and cancellation tombstones when refreshing that validator.
    return _memberRouter = GroupMemberRouter(
      validator: _validator(coordinator),
      sends: existing?.sends ?? RoutedSendTable(localPeerId: group.localPeerId),
      tombstones: existing?.tombstones,
    );
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
        realtimePending: existing.realtimePending,
      );
    }
    _coordinatorView = view;
    final relays = CoordinatorRelayTable(
      coordinatorPeerId: group.localPeerId,
      maxReservedBytesPerDestination: maxReservedBytesPerDestination,
      maxReservedMessagesPerDestination: maxReservedMessagesPerDestination,
    );
    return _coordinatorRouter = GroupCoordinatorRouter(
      validator: _validator(group.localPeerId),
      reliableController: CoordinatorRelayController(
        canonicalGroupId: group.groupId,
        coordinatorPeerId: group.localPeerId,
        relays: relays,
      ),
      realtimePending: CoordinatorRealtimePending(maxPendingDatagrams: 128),
    );
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
    return _destinationRouter = GroupDestinationRouter(
      validator: _validator(coordinator),
    );
  }

  String _routingView(PeerId coordinator) {
    final members =
        group.members
            .map((member) => '${member.peerId}:${member.maxPeers}')
            .toList()
          ..sort();
    return '${group.groupId}:$coordinator:${members.join('|')}';
  }

  GroupRoutingValidator _validator(PeerId coordinator) => GroupRoutingValidator(
    canonicalGroupId: group.groupId,
    localPeerId: group.localPeerId,
    currentCoordinatorPeerId: coordinator,
    committedMembers: group.members.map((member) => member.peerId).toSet(),
  );

  PeerConnection? _readyPeer(PeerId peerId) {
    syncPeers();
    for (final peer in peers()) {
      if (peer.peerId == peerId && peer.state == PeerConnectionState.ready) {
        observePeer(peer);
        return peer;
      }
    }
    return null;
  }

  Future<void> _admitLocalCoordinatorOperation(
    RoutedGroupOperation operation,
  ) async {
    final destination = _readyPeer(operation.destinationPeerId);
    final incoming = ReassembledGroupReliable(
      pairwiseMessageId: List<int>.filled(8, 0),
      groupId: operation.groupId,
      sourcePeerId: operation.sourcePeerId,
      destinationPeerId: operation.destinationPeerId,
      groupMessageId: operation.groupMessageId,
      deliveryMode: operation.deliveryMode,
      priority: operation.priority,
      bytes: operation.bytes,
    );
    final actions = _coordinator().receiveReliableFromMember(
      incoming,
      authenticatedSendingPeerId: group.localPeerId,
      destinationReady: destination != null,
      reservationBytes: operation.bytes.length,
      destinationPairwiseMessageId: destination == null
          ? null
          : _nextMessageId(destination),
    );
    await _applyCoordinatorActions(
      null,
      actions,
      localSourceMessageId: operation.groupMessageId,
    );
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
          'group frame ignored peer=${peer.peerId} type=${frame.type} message=${frame.messageId} error=${error.code}',
        );
        return;
      }
      logger(
        'group frame protocol failure peer=${peer.peerId} type=${frame.type} message=${frame.messageId} error=${error.code}',
      );
      await peer.disconnect();
    } on Object catch (error) {
      // Group routing violations are authenticated peer protocol violations;
      // do not leave the same connection accepting later group traffic.
      logger(
        'group frame exception peer=${peer.peerId} type=${frame.type} message=${frame.messageId} error=$error',
      );
      await peer.disconnect();
    }
  }

  Future<bool> _sendGroupInfo(PeerConnection peer) async {
    if (_disposed || peer.state != PeerConnectionState.ready) return false;
    try {
      final config = group.config;
      final namespaceHash = await _scopedHash(
        'LPC1-application-namespace',
        config.applicationNamespace,
      );
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
          members: group.members,
        ),
        coordinatorTerm: group.coordinatorTerm,
        coordinatorPeerId: group.coordinatorPeerId,
      );
      final result = await peer._core.submitEncrypted(
        FrameType.groupInfo,
        await payload.encode(),
      );
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
      'group info peer=${peer.peerId} localGroup=${_debugId(local.groupId.bytes)} localMembers=${local.members.length} remoteGroup=${_debugId(info.info.groupId.bytes)} remoteMembers=${info.info.members.length} decision=${evaluation.decision} winner=${evaluation.winner == null ? 'none' : _debugId(evaluation.winner!.groupId.bytes)} localCoordinator=${group.isCoordinator}',
    );
    if (evaluation.decision == GroupMergeDecision.sameGroup) {
      if (_sameMembers(local.members, info.info.members)) {
        final remoteCoordinator = info.coordinatorPeerId;
        if (remoteCoordinator != null &&
            info.coordinatorTerm > group.coordinatorTerm) {
          group.adoptCoordinatorAuthority(
            coordinator: remoteCoordinator,
            coordinatorTerm: info.coordinatorTerm,
          );
          logger(
            'group same-group authority refreshed peer=${peer.peerId} coordinator=$remoteCoordinator term=${info.coordinatorTerm}',
          );
        }
        // A restarted member can send its lower-term GROUP_INFO after the
        // coordinator has already queued a state catch-up for the newly
        // READY transport.  Echo the coordinator's current metadata first;
        // the authenticated peer then adopts the term before the following
        // state frames are delivered.  This is important on BLE, where a
        // process restart can recreate the GroupSession after the transport
        // itself is already usable.
        if (group.isCoordinator &&
            (info.coordinatorTerm < group.coordinatorTerm ||
                info.coordinatorPeerId != group.coordinatorPeerId)) {
          await _sendGroupInfo(peer);
        }
        // A restarted application can create its GroupSession after LPC has
        // already re-established the authenticated PeerConnection. The
        // transport itself is READY, but the prior GroupSession did not hear
        // the initial transport-ready notification. Treat this authenticated
        // same-group reattachment as another current-state catch-up trigger;
        // it does not mutate membership or replay historical messages.
        if (group.members.any((member) => member.peerId == peer.peerId)) {
          if (group.state == GroupState.ready) {
            _notifySameGroupCatchUp(peer);
          } else {
            _sameGroupCatchUpPending.add(peer.peerId);
          }
        }
        return;
      }
      // Same-GroupId views are split-brain membership views, not a merge.
      // The coordinator with the newer committed term reconciles the union
      // through MEMBERSHIP_SNAPSHOT (Section 10.10/31.7); a member waits for
      // that authenticated coordinator snapshot instead of committing from
      // an unacknowledged GROUP_INFO advertisement.
      if (!group.isCoordinator ||
          info.coordinatorTerm > group.coordinatorTerm) {
        return;
      }
      // A process that joined through a non-coordinator can briefly advertise
      // the same GroupId with the coordinator's older, strict-subset view.
      // That is a bootstrap lag, not split brain: the local coordinator still
      // owns the newer committed membership and must not create a new term on
      // every GROUP_INFO heartbeat.  Re-send the current authority metadata;
      // the already-published MEMBERSHIP_SNAPSHOT remains the mechanism that
      // brings this peer up to the committed set.
      if (info.coordinatorPeerId == group.coordinatorPeerId &&
          info.coordinatorTerm < group.coordinatorTerm &&
          _isMemberSubset(info.info.members, local.members)) {
        await _sendGroupInfo(peer);
        // A restarted GroupSession does not retain the prior snapshot's
        // ACK/retry state. Re-send the current committed membership to this
        // authenticated peer specifically; GROUP_INFO alone cannot expand a
        // recreated two-member view back to the full group.
        await _publishMembershipSnapshot(
          local.members,
          group.coordinatorTerm,
          onlyPeer: peer,
        );
        return;
      }
      final members = _mergeMembers(local.members, info.info.members);
      if (members.length > group.config.maxPeers) {
        group.reportError(
          LpcErrorCode.groupFull,
          peerId: peer.peerId,
          diagnostic: 'same-GroupId membership reconciliation exceeds capacity',
        );
        return;
      }
      final term = max(group.coordinatorTerm, info.coordinatorTerm) + 1;
      group.commitMembership(
        members,
        coordinator: group.localPeerId,
        coordinatorTerm: term,
      );
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
      newCoordinatorTerm: max(group.coordinatorTerm, info.coordinatorTerm) + 1,
      effectiveMaxPeers: evaluation.effectiveMaxPeers,
      members: members,
    );
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
      nowMs: peer._core.monotonicNowMs,
    );
    if (result != TransportWriteState.submittedToPlatform) {
      throw const LpcException(LpcErrorCode.transportClosed);
    }
  }

  Future<GroupMergeInfo> _localGroupInfo() async {
    final config = group.config;
    return GroupMergeInfo(
      namespaceHash: await _scopedHash(
        'LPC1-application-namespace',
        config.applicationNamespace,
      ),
      discoveryMode: config.discoveryMode,
      autoMerge: config.autoMerge,
      trustMode: config.groupTrustMode,
      knownPeersAutoMerge: config.knownPeersAutoMerge,
      tokenHash: config.discoveryMode == DiscoveryMode.openProximity
          ? List<int>.filled(32, 0)
          : await _scopedHash('LPC1-group-join-token', config.groupJoinToken!),
      groupId: group.groupId,
      members: group.members,
    );
  }

  List<GroupMember> _mergeMembers(
    Iterable<GroupMember> first,
    Iterable<GroupMember> second,
  ) {
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
        Iterable.generate(left.length).every(
          (index) =>
              left[index].peerId == right[index].peerId &&
              left[index].maxPeers == right[index].maxPeers,
        );
  }

  bool _isMemberSubset(
    Iterable<GroupMember> possibleSubset,
    Iterable<GroupMember> possibleSuperset,
  ) {
    final superset = {
      for (final member in possibleSuperset) member.peerId: member,
    };
    return possibleSubset.every((member) {
      final current = superset[member.peerId];
      return current != null && current.maxPeers == member.maxPeers;
    });
  }

  void _applyGroupMerge(
    GroupMergePayload payload, {
    required PeerId coordinator,
  }) {
    final disposition = _mergeReceiver.receive(payload);
    logger(
      'group merge apply disposition=$disposition localGroup=${_debugId(group.groupId.bytes)} winningGroup=${_debugId(payload.winningGroupId.bytes)} losingGroup=${_debugId(payload.losingGroupId.bytes)} members=${payload.members.length} coordinator=$coordinator term=${payload.newCoordinatorTerm}',
    );
    if (disposition != GroupMergeReceiveDisposition.applied) {
      return;
    }
    group.commitMergedMembership(
      groupId: payload.winningGroupId,
      members: payload.members,
      coordinator: coordinator,
      coordinatorTerm: payload.newCoordinatorTerm,
    );
    _membershipReconciliationPending = false;
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
    final senderAuthorized =
        remote != null &&
        remote.info.groupId == payload.winningGroupId &&
        remote.coordinatorPeerId == peer.peerId;
    if (!senderAuthorized) {
      logger(
        'group merge authorization failed peer=${peer.peerId} localGroup=${_debugId(group.groupId.bytes)} winningGroup=${_debugId(payload.winningGroupId.bytes)} losingGroup=${_debugId(payload.losingGroupId.bytes)} retainedGroup=${remote == null ? 'none' : _debugId(remote.info.groupId.bytes)} retainedCoordinator=${remote?.coordinatorPeerId}',
      );
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
        'group merge stale concurrent view peer=${peer.peerId} localGroup=${_debugId(group.groupId.bytes)} winningGroup=${_debugId(payload.winningGroupId.bytes)} losingGroup=${_debugId(payload.losingGroupId.bytes)} localTerm=${group.coordinatorTerm} term=${payload.newCoordinatorTerm}',
      );
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
        'group merge stale peer=${peer.peerId} localGroup=${_debugId(group.groupId.bytes)} localTerm=${group.coordinatorTerm} winningGroup=${_debugId(payload.winningGroupId.bytes)} losingGroup=${_debugId(payload.losingGroupId.bytes)} term=${payload.newCoordinatorTerm}',
      );
      await peer._core.submitAck(frame.messageId);
      await _publishGroupInfo();
      return;
    }
    if (group.groupId != payload.losingGroupId) {
      logger(
        'group merge rejected current group differs peer=${peer.peerId} localGroup=${_debugId(group.groupId.bytes)} winningGroup=${_debugId(payload.winningGroupId.bytes)} losingGroup=${_debugId(payload.losingGroupId.bytes)} localTerm=${group.coordinatorTerm} term=${payload.newCoordinatorTerm}',
      );
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
      if (remote.coordinatorPeerId == group.coordinatorPeerId &&
          remote.coordinatorTerm < group.coordinatorTerm &&
          _isMemberSubset(remote.info.members, group.members)) {
        // This is the coordinator's own stale bootstrap view.  It is safe to
        // avoid a new reconciliation term, but it is not safe to skip the
        // catch-up: a recreated GroupSession has no prior snapshot retry
        // state, so GROUP_INFO alone cannot expand the retained subset.  This
        // is especially important after a third peer joins through another
        // member while this link is already authenticated.
        await _sendGroupInfo(entry.key);
        await _publishMembershipSnapshot(
          group.members,
          group.coordinatorTerm,
          onlyPeer: entry.key,
        );
        continue;
      }
      final members = _mergeMembers(group.members, remote.info.members);
      if (members.length > group.config.maxPeers) {
        group.reportError(
          LpcErrorCode.groupFull,
          peerId: entry.key.peerId,
          diagnostic: 'same-GroupId membership reconciliation exceeds capacity',
        );
        continue;
      }
      final term = max(group.coordinatorTerm, remote.coordinatorTerm) + 1;
      group.commitMembership(
        members,
        coordinator: group.localPeerId,
        coordinatorTerm: term,
      );
      await _publishMembershipSnapshot(members, term, sameGroupOnly: true);
    }
  }

  Future<void> _publishMembershipSnapshot(
    Iterable<GroupMember> members,
    int coordinatorTerm, {
    bool sameGroupOnly = false,
    PeerConnection? onlyPeer,
  }) async {
    final payload = MembershipSnapshot(
      groupId: group.groupId,
      coordinatorTerm: coordinatorTerm,
      members: members.toList(growable: false),
    );
    final encoded = await payload.encode();
    for (final peer in _frameSubscriptions.keys.toList()) {
      if (onlyPeer != null && !identical(peer, onlyPeer)) continue;
      if (peer.state != PeerConnectionState.ready) continue;
      if (sameGroupOnly &&
          _remoteGroupInfo[peer]?.info.groupId != group.groupId) {
        // A singleton/newly joining peer must receive GROUP_MERGE before a
        // membership snapshot for the winning GroupId.
        continue;
      }
      logger(
        'group membership snapshot send peer=${peer.peerId} group=${_debugId(group.groupId.bytes)} term=$coordinatorTerm members=${members.map((member) => member.peerId).join(',')}',
      );
      try {
        final result = await peer._core.submitAckRequiredFrame(
          type: FrameType.membershipSnapshot,
          payload: encoded,
          nowMs: peer._core.monotonicNowMs,
        );
        logger(
          'group membership snapshot submitted peer=${peer.peerId} result=$result',
        );
      } on LpcException catch (error) {
        if (error.code != LpcErrorCode.transportClosed &&
            error.code != LpcErrorCode.invalidState) {
          rethrow;
        }
      }
    }
  }

  Future<void> _receiveMembershipSnapshot(
    PeerConnection peer,
    LpcFrame frame,
  ) async {
    if (frame.flags != 1) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final snapshot = await MembershipSnapshot.decode(frame.payload);
    logger(
      'group membership snapshot receive peer=${peer.peerId} local=${group.localPeerId} localGroup=${_debugId(group.groupId.bytes)} localTerm=${group.coordinatorTerm} localCoordinator=${group.coordinatorPeerId} snapshotGroup=${_debugId(snapshot.groupId.bytes)} snapshotTerm=${snapshot.coordinatorTerm} members=${snapshot.members.map((member) => member.peerId).join(',')}',
    );
    if (snapshot.groupId != group.groupId ||
        peer.peerId != group.coordinatorPeerId) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final disposition = _membershipOrdering.observe(
      coordinatorPeerId: peer.peerId,
      coordinatorTerm: snapshot.coordinatorTerm,
      sessionId: peer.sessionId,
      senderMessageId: frame.messageId,
    );
    logger(
      'group membership snapshot order peer=${peer.peerId} term=${snapshot.coordinatorTerm} disposition=$disposition message=${_debugId(frame.messageId)}',
    );
    if (disposition == MembershipSnapshotOrderDisposition.accepted) {
      if (membershipSnapshotLocalDisposition(snapshot, group.localPeerId) ==
          MembershipSnapshotLocalDisposition.excluded) {
        // A coordinator can have an older removal snapshot in flight when a
        // restarted process recreates its GroupSession. Treat that as a
        // membership reconciliation race, not a corrupt protocol frame: ACK
        // below, keep the authenticated relayed/direct link alive, and
        // advertise the current local view so the coordinator can reconcile
        // this currently reachable same-GroupId peer (Sections 10.8.2/10.10).
        // Group application traffic remains gated until a newer committed
        // snapshot admits this local PeerId.
        _membershipReconciliationPending = true;
        logger(
          'group membership snapshot excludes local peer; requesting reconciliation local=${group.localPeerId} peer=${peer.peerId} term=${snapshot.coordinatorTerm}',
        );
      } else {
        group.commitMembership(
          snapshot.members,
          coordinator: peer.peerId,
          coordinatorTerm: snapshot.coordinatorTerm,
        );
        _membershipReconciliationPending = false;
        logger(
          'group membership snapshot applied local=${group.localPeerId} term=${group.coordinatorTerm} members=${group.members.map((member) => member.peerId).join(',')}',
        );
        _mergeReceiver = GroupMergeReceiver(
          committedGroupId: group.groupId,
          committedTerm: group.coordinatorTerm,
          committedMembers: group.members,
        );
      }
    }
    await peer._core.submitAck(frame.messageId);
    await _publishGroupInfo();
  }

  Future<void> _receiveCoordinatorCheckpoint(
    PeerConnection peer,
    LpcFrame frame,
  ) async {
    if (frame.flags != 1 ||
        group.config.coordinatorCheckpointing == false ||
        group.isCoordinator ||
        peer.peerId != group.coordinatorPeerId) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    final chunk = CoordinatorCheckpointChunk.decode(frame.payload);
    final receiver = _checkpointReceivers[peer] ??= CheckpointReceiver();
    final result = await receiver.add(
      frame.messageId,
      chunk,
      validate: (checkpoint) async {
        final valid = await group.validateCoordinatorCheckpoint(
          checkpoint.bytes,
        );
        logger(
          'checkpoint validate peer=${peer.peerId} message=${_debugId(frame.messageId)} sequence=${checkpoint.sequence} bytes=${checkpoint.bytes.length} valid=$valid',
        );
        return valid;
      },
      commit: (checkpoint) {
        if (checkpoint.term < group.coordinatorTerm) {
          throw const LpcException(LpcErrorCode.protocolMismatch);
        }
        group.commitCoordinatorCheckpoint(
          checkpoint.bytes,
          coordinator: peer.peerId,
          checkpointSequence: checkpoint.sequence,
        );
      },
    );
    if (result.acknowledgmentMessageId != null) {
      logger(
        'checkpoint receive ACK peer=${peer.peerId} message=${_debugId(frame.messageId)} result=${result.committed != null ? 'committed' : 'duplicate'}',
      );
      await peer._core.submitAck(frame.messageId);
    } else {
      logger(
        'checkpoint receive incomplete peer=${peer.peerId} message=${_debugId(frame.messageId)} sequence=${chunk.sequence}',
      );
    }
  }

  Future<void> _receiveReliable(PeerConnection peer, LpcFrame frame) async {
    final chunk = GroupReliableChunk.decode(frame.payload);
    final expectedAck = chunk.deliveryMode == DeliveryMode.reliableAcked;
    if ((frame.flags & 1 != 0) != expectedAck) {
      throw const LpcException(LpcErrorCode.protocolMismatch);
    }
    // Do not consume a routed application operation while the recreated
    // GroupSession is still forming.  GroupSession.receiveReliable() is
    // intentionally a no-op until committed membership is READY; accepting
    // the pairwise hop first would nevertheless send its ACK and permanently
    // strand a current-state packet after an app restart.  Leaving the frame
    // unacknowledged preserves the bounded LPC retry path, which will retry
    // the same operation after GROUP_INFO/membership bootstrap completes.
    if (group.state != GroupState.ready ||
        !group.members.any((member) => member.peerId == peer.peerId)) {
      logger(
        'group reliable deferred peer=${peer.peerId} reason=group-not-ready-or-peer-not-committed state=${group.state}',
      );
      return;
    }
    final complete = _reassemblers[peer]!.add(frame.messageId, chunk);
    if (complete == null) return;
    logger(
      'group receive complete peer=${peer.peerId} source=${complete.sourcePeerId} destination=${complete.destinationPeerId} message=${_debugId(complete.groupMessageId.bytes)} mode=${complete.deliveryMode} bytes=${complete.bytes.length} coordinator=${group.isCoordinator}',
    );
    if (group.isCoordinator) {
      final destination = _readyPeer(complete.destinationPeerId);
      logger(
        'group coordinator admission source=${complete.sourcePeerId} destination=${complete.destinationPeerId} message=${_debugId(complete.groupMessageId.bytes)} destinationReady=${complete.destinationPeerId == group.localPeerId || destination != null} destinationPeer=${destination?.peerId}',
      );
      final actions = _coordinator().receiveReliableFromMember(
        complete,
        authenticatedSendingPeerId: peer.peerId,
        destinationReady:
            complete.destinationPeerId == group.localPeerId ||
            destination != null,
        reservationBytes: complete.bytes.length,
        destinationPairwiseMessageId:
            complete.destinationPeerId == group.localPeerId ||
                destination == null
            ? null
            : _nextMessageId(destination),
      );
      await _applyCoordinatorActions(peer, actions);
      return;
    }
    final result = _destination().receiveReliable(
      complete,
      authenticatedSendingPeerId: peer.peerId,
    );
    if (complete.deliveryMode == DeliveryMode.reliableAcked) {
      await peer._core.submitAck(complete.pairwiseMessageId);
    }
    if (result.disposition == ReliableDestinationDisposition.deliver) {
      logger(
        'group destination deliver peer=${peer.peerId} source=${complete.sourcePeerId} destination=${complete.destinationPeerId} message=${_debugId(complete.groupMessageId.bytes)}',
      );
      group.receiveReliable(
        source: complete.sourcePeerId,
        id: complete.groupMessageId,
        mode: complete.deliveryMode,
        priority: complete.priority,
        bytes: complete.bytes,
      );
    }
  }

  Future<void> _receiveDeliveryAck(PeerConnection peer, LpcFrame frame) async {
    if (frame.flags != 1)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final ack = GroupDeliveryAck.decode(frame.payload);
    final result = _member().receiveDeliveryAckResult(
      ack,
      authenticatedSendingPeerId: peer.peerId,
    );
    if (result.requiresGenericAck) await peer._core.submitAck(frame.messageId);
    final state = result.state;
    logger(
      'group delivery ack peer=${peer.peerId} source=${ack.sourcePeerId} destination=${ack.destinationPeerId} message=${_debugId(ack.groupMessageId.bytes)} state=$state genericAck=${result.requiresGenericAck}',
    );
    if (state != null) _completeSource(ack.groupMessageId, state);
  }

  Future<void> _receiveRelayStatus(PeerConnection peer, LpcFrame frame) async {
    if (frame.flags != 1)
      throw const LpcException(LpcErrorCode.protocolMismatch);
    final status = GroupRelayStatusPayload.decode(frame.payload);
    final result = _member().receiveRelayStatusResult(
      status,
      authenticatedSendingPeerId: peer.peerId,
    );
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
      final result = _coordinator().receiveRealtimeFromMember(
        datagram,
        authenticatedSendingPeerId: peer.peerId,
        destinationReady:
            datagram.destinationPeerId == group.localPeerId || target != null,
      );
      if (result == CoordinatorRealtimeEnqueueResult.droppedCapacity) {
        group.reportError(
          LpcErrorCode.resourceExhausted,
          peerId: datagram.destinationPeerId,
        );
        return;
      }
      if (result ==
          CoordinatorRealtimeEnqueueResult.droppedDestinationUnavailable) {
        return;
      }
      final accepted = _coordinator().realtimePending.take(
        datagram.sourcePeerId,
        datagram.destinationPeerId,
        datagram.channelId,
      );
      if (accepted == null) return;
      if (accepted.destinationPeerId == group.localPeerId) {
        group.receiveRealtime(
          source: accepted.sourcePeerId,
          channelId: accepted.channelId,
          senderTick: accepted.senderTick,
          datagramSequence: accepted.sequence,
          bytes: accepted.bytes,
        );
      } else {
        final destination = _readyPeer(accepted.destinationPeerId);
        if (destination != null) {
          await destination._core.submitEncrypted(
            FrameType.groupRealtimeDatagram,
            accepted.encode(),
          );
        }
      }
      return;
    }
    final accepted = _destination().receiveRealtime(
      datagram,
      authenticatedSendingPeerId: peer.peerId,
    );
    if (accepted) {
      group.receiveRealtime(
        source: datagram.sourcePeerId,
        channelId: datagram.channelId,
        senderTick: datagram.senderTick,
        datagramSequence: datagram.sequence,
        bytes: datagram.bytes,
      );
    }
  }

  Future<void> _applyCoordinatorActions(
    PeerConnection? sourcePeer,
    CoordinatorRelayActions actions, {
    GroupMessageId? localSourceMessageId,
  }) async {
    logger(
      'group coordinator actions sourcePeer=${sourcePeer?.peerId} sourceHopAck=${actions.sourceHopGenericAckMessageId} local=${actions.deliverLocally == null ? null : _debugId(actions.deliverLocally!.groupMessageId.bytes)} localState=${actions.localSourceState} deliveryAck=${actions.deliveryAck == null ? null : _debugId(actions.deliveryAck!.groupMessageId.bytes)} relayStatus=${actions.relayStatus == null ? null : _debugId(actions.relayStatus!.groupMessageId.bytes)} forward=${actions.forward == null ? null : _debugId(actions.forward!.groupMessageId.bytes)}',
    );
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
        bytes: local.bytes,
      );
    }
    final state = actions.localSourceState;
    if (state != null) {
      final messageId = local?.groupMessageId ?? localSourceMessageId;
      if (messageId != null) _completeSource(messageId, state);
    }
    final ack = actions.deliveryAck;
    if (ack != null)
      await _sendSignal(
        ack.sourcePeerId,
        FrameType.groupDeliveryAck,
        ack.encode(),
      );
    final status = actions.relayStatus;
    if (status != null)
      await _sendSignal(
        status.sourcePeerId,
        FrameType.groupRelayStatus,
        status.encode(),
      );
    final forward = actions.forward;
    if (forward != null) await _submitForward(forward);
  }

  Future<void> _submitForward(ReassembledGroupReliable operation) async {
    final destination = _readyPeer(operation.destinationPeerId);
    logger(
      'group forward source=${operation.sourcePeerId} destination=${operation.destinationPeerId} message=${_debugId(operation.groupMessageId.bytes)} ready=${destination != null} peer=${destination?.peerId}',
    );
    if (destination == null) {
      final actions = _coordinator().reliableController.finalHopFailed(
        operation.sourcePeerId,
        operation.groupMessageId,
        GroupRelayStatus.destinationUnavailable,
      );
      await _applyCoordinatorActions(
        null,
        actions,
        localSourceMessageId: operation.groupMessageId,
      );
      return;
    }
    await _submitHop(destination, null, finalHop: true, reassembled: operation);
  }

  Future<void> _submitHop(
    PeerConnection peer,
    RoutedGroupOperation? operation, {
    required bool finalHop,
    ReassembledGroupReliable? reassembled,
    RoutedGroupOperation? sourceOperation,
  }) async {
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
      bytes: bytes,
    );
    logger(
      'group submit hop peer=${peer.peerId} source=$source destination=$destination message=${_debugId(groupMessageId.bytes)} pairwise=${_debugId(messageId)} finalHop=$finalHop mode=$mode chunks=${chunks.length} bytes=${bytes.length} state=${peer.state}',
    );
    if (mode == DeliveryMode.reliableAcked) {
      peer._core.ackRetention.retain(
        messageId: messageId,
        logicalContent: [for (final chunk in chunks) ...chunk.encode()],
      );
    }
    for (final chunk in chunks) {
      final result = await peer._core.submitEncrypted(
        FrameType.groupReliable,
        chunk.encode(),
        flags: mode == DeliveryMode.reliableAcked ? 1 : 0,
        messageId: messageId,
        priority: priority,
      );
      if (result != TransportWriteState.submittedToPlatform) {
        logger(
          'group submit hop failed peer=${peer.peerId} message=${_debugId(groupMessageId.bytes)} pairwise=${_debugId(messageId)} result=$result state=${peer.state}',
        );
        throw const LpcException(LpcErrorCode.transportClosed);
      }
    }
    if (mode == DeliveryMode.reliableAcked) {
      peer._core.ackRetention.finalFrameSubmitted(
        messageId,
        nowMs: peer._core.monotonicNowMs,
      );
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
          bytes: bytes,
        ),
        finalHop: finalHop,
      );
    } else if (finalHop) {
      final actions = _coordinator().reliableController.finalHopSubmitted(
        source,
        groupMessageId,
      );
      await _applyCoordinatorActions(null, actions);
    }
  }

  Future<void> _receiveGenericAck(
    PeerConnection peer,
    List<int> messageId,
  ) async {
    final checkpoint = _checkpointHops.remove(_hopKey(peer, messageId));
    if (checkpoint != null) {
      logger(
        'checkpoint ACK peer=${peer.peerId} message=${_debugId(messageId)} publication=${checkpoint.publication.publicationId}',
      );
      group.checkpointOperationFinished(
        checkpoint.publication,
        peer.peerId,
        CheckpointPeerResult.acknowledged,
        checkpointSequence: checkpoint.operation.sequence,
      );
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
      hop.operation.sourcePeerId,
      hop.operation.groupMessageId,
    );
    await _applyCoordinatorActions(
      null,
      actions,
      localSourceMessageId: hop.operation.groupMessageId,
    );
  }

  Future<void> _sendSignal(
    PeerId source,
    FrameType type,
    List<int> payload,
  ) async {
    final peer = _readyPeer(source);
    if (peer == null) {
      group.reportError(LpcErrorCode.destinationUnavailable, peerId: source);
      return;
    }
    await peer._core.submitAckRequiredFrame(
      type: type,
      payload: payload,
      nowMs: peer._core.monotonicNowMs,
    );
  }

  Future<void> _retransmitHopsFor(PeerConnection peer) async {
    for (final hop
        in _ackHops.values.where((hop) => identical(hop.peer, peer)).toList()) {
      final retry = peer._core.ackRetention.retransmitOneAfterResume(
        hop.messageId,
      );
      if (retry == AckTimeoutResult.retransmitWholeOperation) {
        for (final chunk in hop.chunks) {
          await peer._core.submitEncrypted(
            FrameType.groupReliable,
            chunk.encode(),
            flags: 1,
            messageId: hop.messageId,
            priority: hop.chunks.first.priority,
          );
        }
        peer._core.ackRetention.finalFrameSubmitted(
          hop.messageId,
          nowMs: peer._core.monotonicNowMs,
        );
      } else if (retry == AckTimeoutResult.terminalAckTimeout) {
        _ackHops.remove(_hopKey(peer, hop.messageId));
      }
    }
  }

  Future<void> _retransmitCheckpointsFor(PeerConnection peer) async {
    for (final hop
        in _checkpointHops.values
            .where((hop) => identical(hop.peer, peer))
            .toList()) {
      final retry = peer._core.ackRetention.retransmitOneAfterResume(
        hop.messageId,
      );
      if (retry == AckTimeoutResult.retransmitWholeOperation) {
        try {
          for (final chunk in hop.chunks) {
            final submitted = await peer._core.submitEncrypted(
              FrameType.coordinatorCheckpoint,
              chunk.encode(),
              flags: 1,
              messageId: hop.messageId,
              priority: SendPriority.interactive,
            );
            if (submitted != TransportWriteState.submittedToPlatform) {
              throw const LpcException(LpcErrorCode.transportClosed);
            }
          }
          peer._core.ackRetention.finalFrameSubmitted(
            hop.messageId,
            nowMs: peer._core.monotonicNowMs,
          );
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
    await _notifyTransportReady(peer);
    await _retransmitHopsFor(peer);
    await _retransmitCheckpointsFor(peer);
    checkpointPeerReady(peer.peerId);
    if (group.isCoordinator) {
      // ACK-required final hops were replayed above through their retained
      // encoders. Ordered relays have no generic ACK retention, so only they
      // are resubmitted from chunk 0 after a successful destination RESUME.
      for (final actions in _coordinator().destinationResumeSucceeded(
        peer.peerId,
      )) {
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

  Future<void> _notifyTransportReady(PeerConnection peer) async {
    final sent = await _sendGroupInfo(peer);
    if (!sent || _disposed || peer.state != PeerConnectionState.ready) return;
    // GroupSession membership can remain committed across a transport loss or
    // a process-restart replacement. Notify only after the current group
    // metadata is usable so applications can republish their latest state;
    // this never creates a new roster/version or chooses a reconnect side.
    group.notifyTransportChanged(
      peer.peerId,
      currentTransport: peer.activeTransport,
      transportGeneration: peer._core.generation,
    );
  }

  Future<void> _onPeerDisconnected(PeerConnection peer) async {
    _onPeerLost(peer);
    for (final hop
        in _checkpointHops.values
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
    // GROUP_INFO and the GroupReady event can cross while a freshly recreated
    // GroupSession is still forming.  Drain on either side of that ordering
    // so a same-group process restart cannot lose its only current-state
    // catch-up trigger.
    if (_sameGroupCatchUpPending.isNotEmpty &&
        (event is GroupReady || group.state == GroupState.ready)) {
      _drainSameGroupCatchUpPending();
    }
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
        tombstones: member.tombstones,
      );
      _memberView = _routingView(event.current);
      unawaited(_rerouteMemberOperations());
    }
  }

  void _notifySameGroupCatchUp(PeerConnection peer) {
    if (_disposed || peer.state != PeerConnectionState.ready) return;
    if (group.state != GroupState.ready) {
      _sameGroupCatchUpPending.add(peer.peerId);
      // If GroupReady was emitted just before GROUP_INFO arrived, there will
      // be no later GroupReady event to drain this entry.  Recheck after the
      // current event turn as well as from the normal GroupReady path.
      scheduleMicrotask(_drainSameGroupCatchUpPending);
      logger(
        'group same-group reattachment catch-up deferred peer=${peer.peerId}',
      );
      return;
    }
    logger(
      'group same-group reattachment catch-up peer=${peer.peerId} generation=${peer._core.generation}',
    );
    group.notifyTransportChanged(
      peer.peerId,
      currentTransport: peer.activeTransport,
      transportGeneration: peer._core.generation,
    );
  }

  void _drainSameGroupCatchUpPending() {
    if (_disposed || group.state != GroupState.ready) return;
    for (final peer in _frameSubscriptions.keys.toList()) {
      if (_sameGroupCatchUpPending.remove(peer.peerId)) {
        _notifySameGroupCatchUp(peer);
      }
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
      final result = peer._core.ackRetention.onTimer(
        hop.messageId,
        nowMs: peer._core.monotonicNowMs,
      );
      if (result == AckTimeoutResult.ignored) continue;
      if (result == AckTimeoutResult.retransmitWholeOperation) {
        try {
          for (final chunk in hop.chunks) {
            final submitted = await peer._core.submitEncrypted(
              FrameType.coordinatorCheckpoint,
              chunk.encode(),
              flags: 1,
              messageId: hop.messageId,
              priority: SendPriority.interactive,
            );
            if (submitted != TransportWriteState.submittedToPlatform) {
              throw const LpcException(LpcErrorCode.transportClosed);
            }
          }
          peer._core.ackRetention.finalFrameSubmitted(
            hop.messageId,
            nowMs: peer._core.monotonicNowMs,
          );
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
      final result = peer._core.ackRetention.onTimer(
        hop.messageId,
        nowMs: nowMs,
      );
      if (result == AckTimeoutResult.ignored) continue;
      if (result == AckTimeoutResult.retransmitWholeOperation) {
        try {
          for (final chunk in hop.chunks) {
            final submitted = await peer._core.submitEncrypted(
              FrameType.groupReliable,
              chunk.encode(),
              flags: 1,
              messageId: hop.messageId,
              priority: hop.chunks.first.priority,
            );
            if (submitted != TransportWriteState.submittedToPlatform) {
              throw const LpcException(LpcErrorCode.transportClosed);
            }
          }
          peer._core.ackRetention.finalFrameSubmitted(
            hop.messageId,
            nowMs: peer._core.monotonicNowMs,
          );
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
          GroupRelayStatus.destinationAckTimeout,
        );
        await _applyCoordinatorActions(
          null,
          actions,
          localSourceMessageId: hop.operation.groupMessageId,
        );
      } else {
        final timeout = _memberRouter?.sourceHopAckTimedOut(
          hop.operation.groupMessageId,
        );
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
  _CheckpointPublicationData(
    this.handle,
    this.bytes,
    this.coordinatorTerm,
    this.validationRequirement,
  );
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
Future<NearbyRuntime> createRuntime({
  RuntimeConfig config = const RuntimeConfig(),
  PeerId? localPeerId,
  IdentityStore? identityStore,
  PlatformBleBackend? platformBleBackend,
}) => NearbyRuntime.create(
  config: config,
  localPeerId: localPeerId,
  identityStore: identityStore,
  platformBleBackend: platformBleBackend,
);

String _serviceKey(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

// GroupId and GroupMessageId intentionally do not expose a toString()
// override. Diagnostics still need stable correlation keys, and these IDs are
// not secret material, so render their bytes explicitly in runtime logs.
String _debugId(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

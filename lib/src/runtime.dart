import 'dart:async';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'backend.dart';
import 'gatt_backend_connection.dart';
import 'group.dart';
import 'identity_store.dart';
import 'platform_ble_backend.dart';
import 'protocol/capabilities.dart';
import 'protocol/application_payload.dart';
import 'protocol/auth.dart';
import 'protocol/control_payload.dart';
import 'protocol/frame.dart';
import 'protocol/handshake_connection.dart';
import 'protocol/handshake_exchange.dart';
import 'protocol/hello.dart';
import 'protocol/peer_state.dart';
import 'protocol/reconnect.dart';
import 'protocol/resume.dart';
import 'peer_connection_core.dart';
import 'types.dart';

enum RuntimeState { created, initializing, ready, failed, closing, closed }

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
  const HostPeerConnected(this.connection);
  final PeerConnection connection;
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
      void Function(PeerConnection)? onDisconnected,
      void Function(PeerConnection)? onReconnecting})
      : _onDisconnected = onDisconnected,
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
    await _events.close();
    _onDisconnected?.call(this);
  }

  void _onFrame(LpcFrame frame) {
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
    required void Function(HostSession host) onClosed,
  })  : _startAdvertising = startAdvertising,
        _stopAdvertising = stopAdvertising,
        _onClosed = onClosed;

  final HostConfig config;
  final Future<void> Function() _startAdvertising;
  final Future<void> Function() _stopAdvertising;
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

  void _peerConnected(PeerConnection connection) {
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
    _events.add(HostPeerConnected(connection));
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
  final Set<PeerConnection> _peers = <PeerConnection>{};
  RuntimeState _state;
  final List<GroupSession> _groups = [];
  final List<HostSession> _hosts = [];
  final Map<String, DiscoverySession> _discoveries = {};
  final Set<String> _startingDiscovery = {};
  HostSession? _advertisingHost;
  bool _startingHostAdvertising = false;
  LocalRuntimeCapabilityBitmap? _capabilities;
  RuntimeState get state => _state;
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

  ConnectionAttempt connect(String discoveryEndpointId) {
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
    unawaited(
        backend.connectGatt(discoveryEndpointId).catchError((Object error) {
      attempt._failed(_asLpcError(error));
      _attempts.remove(discoveryEndpointId);
    }));
    return attempt;
  }

  void _onPlatformEvent(PlatformBleEvent event) {
    if (event is! PlatformGattConnected) return;
    final reconnect = _gattReconnects[event.endpointId];
    if (reconnect != null && reconnect.attempting) {
      unawaited(_startGattResume(event, reconnect));
      return;
    }
    var attempt = _attempts.remove(event.endpointId);
    HostSession? host;
    if (attempt == null) {
      host = _advertisingHost;
      if (host == null || !host.config.autoAccept) return;
      final backend = _platformBleBackend!;
      attempt = ConnectionAttempt._(event.endpointId,
          () => backend.closeGattConnection(event.endpointId));
      attempt.events.listen((outcome) {
        if (outcome is ConnectionAttemptConnected)
          host?._peerConnected(outcome.connection);
      });
    }
    unawaited(_startGattHandshake(event, attempt, host: host));
  }

  Future<void> _startGattHandshake(
      PlatformGattConnected event, ConnectionAttempt attempt,
      {HostSession? host}) async {
    final backend = _platformBleBackend!;
    final identity = _identity!;
    try {
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
      final trustMode = host?.config.trustMode ?? config.trustMode;
      late final HandshakeConnection handshake;
      handshake = HandshakeConnection(
          backend: connection,
          localPeerId: localPeerId,
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
              knownPeerPolicy: _knownPeerPolicyFor(config, trustMode),
              tofuStore:
                  trustMode == HandshakeTrustMode.tofu ? _tofuStore : null,
              psk32: config.psk32),
          onSasRequired: (peerId, sas) {
            attempt._verificationRequired(peerId, sas, handshake.confirmSas);
            host?._peerVerificationRequired(attempt, peerId, sas);
          });
      await handshake.start();
      final core = await handshake.ready;
      attempt._connected(_ownPeer(core,
          securityLevel: handshake.exchange.result!.createReady().securityLevel,
          gattEndpointId: event.endpointId));
    } on Object catch (error) {
      attempt._failed(_asLpcError(error));
      await _gattBindings.remove(event.endpointId)?.close();
      await backend.closeGattConnection(event.endpointId);
    }
  }

  void _beginGattReconnect(PeerConnection peer, String endpointId) {
    if (!config.autoReconnect || _state != RuntimeState.ready) return;
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
                  trustMode: HandshakeTrustMode.knownPeer),
              localIdentityKeyPair: identity.keyPair,
              localEphemeralKeyPair: ephemeral,
              knownPeerPolicy: ExpectExactPeer(peer.peerId)));
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
      await backend.startDiscovery(config.serviceUuid);
      late final StreamSubscription<PlatformBleEvent> subscription;
      late final DiscoverySession session;
      session = DiscoverySession(
        stopPlatformScan: backend.stopDiscovery,
        onStopped: () async {
          await subscription.cancel();
          _discoveries.remove(key);
        },
      );
      subscription = backend.events.listen((event) {
        if (event case PlatformEndpointFound()) {
          session.recordEndpoint(DiscoveredEndpoint(event.endpointId,
              rssi: event.rssi, localName: event.localName));
        }
      });
      _discoveries[key] = session;
      return session;
    } finally {
      _startingDiscovery.remove(key);
    }
  }

  GroupSession joinOrCreateGroup(GroupConfig config) {
    if (_state != RuntimeState.ready)
      throw const LpcException(LpcErrorCode.invalidState);
    final random = Random.secure();
    final group = GroupSession.internal(config, localPeerId,
        GroupId(List<int>.generate(16, (_) => random.nextInt(256))));
    _groups.add(group);
    return group;
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
    final runtimeConfig = this.config;
    late final HostSession host;
    host = HostSession.internal(
      config: config,
      startAdvertising: () async {
        if ((_advertisingHost != null && _advertisingHost != host) ||
            _startingHostAdvertising) {
          throw const LpcException(LpcErrorCode.invalidState,
              'another host session is already advertising');
        }
        _startingHostAdvertising = true;
        try {
          await backend.listenGatt(runtimeConfig.serviceUuid);
          await backend.startAdvertising(runtimeConfig.serviceUuid);
          _advertisingHost = host;
        } finally {
          _startingHostAdvertising = false;
        }
      },
      stopAdvertising: () async {
        if (_advertisingHost != host) return;
        _advertisingHost = null;
        try {
          await backend.stopAdvertising();
        } finally {
          await backend.stopGatt();
        }
      },
      onClosed: (closed) {
        _hosts.remove(closed);
        if (_advertisingHost == closed) _advertisingHost = null;
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
    for (final host in List<HostSession>.from(_hosts)) {
      await host.close();
    }
    _hosts.clear();
    for (final discovery in List<DiscoverySession>.from(_discoveries.values)) {
      await discovery.stop();
    }
    _discoveries.clear();
    for (final binding in _gattBindings.values) {
      await binding.close();
    }
    _gattBindings.clear();
    await _platformSubscription?.cancel();
    _state = RuntimeState.closed;
  }

  PeerConnection _ownPeer(PeerConnectionCore core,
      {required SecurityLevel securityLevel, String? gattEndpointId}) {
    late final PeerConnection peer;
    peer = PeerConnection._(core, securityLevel: securityLevel,
        onDisconnected: (_) {
      _peers.remove(peer);
      _gattReconnects.remove(gattEndpointId)?.dispose();
    },
        onReconnecting: gattEndpointId == null
            ? null
            : (_) => _beginGattReconnect(peer, gattEndpointId));
    _peers.add(peer);
    return peer;
  }
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

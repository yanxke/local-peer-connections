import 'dart:async';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'gatt_backend_connection.dart';
import 'group.dart';
import 'identity_store.dart';
import 'platform_ble_backend.dart';
import 'protocol/capabilities.dart';
import 'protocol/application_payload.dart';
import 'protocol/auth.dart';
import 'protocol/frame.dart';
import 'protocol/handshake_connection.dart';
import 'protocol/handshake_exchange.dart';
import 'protocol/hello.dart';
import 'protocol/peer_state.dart';
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
}

class PeerMessageReceived {
  PeerMessageReceived(List<int> value, this.deliveryMode)
      : bytes = List.unmodifiable(value);
  final List<int> bytes;
  final DeliveryMode deliveryMode;
}

/// Public authenticated point-to-point connection. Group routing remains the
/// separate Section 43 owner; this class exposes the direct Section 36 path.
class PeerConnection {
  PeerConnection._(this._core) {
    _frames = _core.receivedFrames.listen(_onFrame);
  }
  final PeerConnectionCore _core;
  late final StreamSubscription<LpcFrame> _frames;
  final StreamController<PeerMessageReceived> _messages =
      StreamController<PeerMessageReceived>.broadcast(sync: true);
  PeerId get peerId => _core.remotePeerId;
  List<int> get sessionId => List.unmodifiable(_core.sessionId);
  PeerConnectionState get state => _core.state;
  Stream<PeerMessageReceived> get messages => _messages.stream;
  SendHandle send(List<int> bytes,
      {SendOptions options = const SendOptions()}) {
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
        nowMs: DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> disconnect() async {
    await _frames.cancel();
    await _core.close();
    await _messages.close();
  }

  void _onFrame(LpcFrame frame) {
    if (frame.type != FrameType.data) return;
    unawaited(() async {
      final chunk = DataChunk.decode(frame.payload);
      final result = await _core.receiveDataChunk(frame.messageId, chunk);
      final delivered = result.delivered;
      if (delivered != null)
        _messages
            .add(PeerMessageReceived(delivered.bytes, delivered.deliveryMode));
    }());
  }
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
  bool _advertising = false;
  bool _closed = false;

  bool get isAdvertising => _advertising;
  bool get isClosed => _closed;
  Stream<HostSessionEvent> get events => _events.stream;
  void _peerConnected(PeerConnection connection) =>
      _events.add(HostPeerConnected(connection));

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

LpcException _asLpcError(Object error) => error is LpcException
    ? error
    : LpcException(LpcErrorCode.platformError, error.toString());

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
  StreamSubscription<PlatformBleEvent>? _platformSubscription;
  final Map<String, ConnectionAttempt> _attempts = {};
  final Map<String, PlatformGattConnectionBinding> _gattBindings = {};
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
    var attempt = _attempts.remove(event.endpointId);
    if (attempt == null) {
      final host = _advertisingHost;
      if (host == null || !host.config.autoAccept) return;
      final backend = _platformBleBackend!;
      attempt = ConnectionAttempt._(event.endpointId,
          () => backend.closeGattConnection(event.endpointId));
      attempt.events.listen((outcome) {
        if (outcome is ConnectionAttemptConnected)
          host._peerConnected(outcome.connection);
      });
    }
    unawaited(_startGattHandshake(event, attempt));
  }

  Future<void> _startGattHandshake(
      PlatformGattConnected event, ConnectionAttempt attempt) async {
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
      final handshake = HandshakeConnection(
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
                  trustMode: HandshakeTrustMode.tofu),
              localIdentityKeyPair: identity.keyPair,
              localEphemeralKeyPair: ephemeral,
              tofuStore: TofuIdentityStore()));
      await handshake.start();
      final core = await handshake.ready;
      attempt._connected(PeerConnection._(core));
    } on Object catch (error) {
      attempt._failed(_asLpcError(error));
      await _gattBindings.remove(event.endpointId)?.close();
      await backend.closeGattConnection(event.endpointId);
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
    final backend = _platformBleBackend;
    if (backend == null) {
      throw const LpcException(
          LpcErrorCode.unsupportedCapability, 'no platform BLE backend');
    }
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

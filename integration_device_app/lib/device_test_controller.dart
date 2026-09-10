import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

/// Raw LPC device fixture controller.
///
/// This class intentionally has no messenger concepts. Its HTTP API is meant
/// for a host-side device runner, while the on-device UI provides a useful
/// manual fallback when a test needs to inspect a physical device.
class DeviceTestController extends ChangeNotifier {
  DeviceTestController({String? displayName, int? controlPort})
    : displayName = boundedDisplayName(
        displayName ??
            const String.fromEnvironment(
              'LPC_TEST_NAME',
              defaultValue: 'LPC Test Device',
            ),
      ),
      controlPort =
          controlPort ??
          int.tryParse(
            const String.fromEnvironment('LPC_TEST_PORT', defaultValue: '8765'),
          ) ??
          8765;

  static const maxEventHistory = 1000;
  final String displayName;
  final int controlPort;
  final List<Map<String, Object?>> events = <Map<String, Object?>>[];
  final Map<String, PeerConnection> _peers = <String, PeerConnection>{};
  final Map<PeerConnection, StreamSubscription<dynamic>> _peerSubscriptions =
      <PeerConnection, StreamSubscription<dynamic>>{};
  final Map<String, ConnectionAttempt> _attempts =
      <String, ConnectionAttempt>{};
  final Map<String, HostPeerVerificationRequired> _pendingHostVerifications =
      <String, HostPeerVerificationRequired>{};

  NearbyRuntime? runtime;
  HostSession? host;
  DiscoverySession? discovery;
  GroupSession? group;
  HttpServer? _server;
  Timer? _notifyTimer;
  int _eventSequence = 0;
  // Capabilities are current runtime state, not diagnostic history. Keep a
  // dedicated value because high-rate endpoint updates can evict the
  // initialization event from the bounded event buffer before a reset or
  // runner preflight reads the snapshot.
  int? _capabilities;
  bool _initializing = false;
  bool _disposed = false;

  bool get controlServerRunning => _server != null;

  /// Requests the permissions that the host application must own before LPC
  /// can start BLE discovery/advertising. iOS presents its system prompt from
  /// CoreBluetooth; the method is therefore intentionally a no-op there.
  Future<void> start() async {
    final granted = await _requestPlatformPermissions();
    if (!granted) {
      _record('permissionDenied', {});
      return;
    }
    if (runtime != null) {
      await startPresence();
      return;
    }
    await initialize();
  }

  Future<bool> _requestPlatformPermissions() async {
    try {
      return await const MethodChannel(
            'lpc_integration_device_app/permissions',
          ).invokeMethod<bool>('requestBluetoothPermissions') ??
          true;
    } on MissingPluginException {
      // iOS and non-mobile test targets rely on the platform BLE API to
      // present/validate authorization, so an absent helper is acceptable.
      return true;
    } on PlatformException catch (error) {
      _recordError('permissionRequestFailed', error);
      return false;
    }
  }

  Future<void> initialize() async {
    if (_initializing || runtime != null || _disposed) return;
    _initializing = true;
    try {
      final backend = PlatformBleBackend(
        logger: (message) => _record('lpcBackendLog', {'message': message}),
      );
      final localRuntime = await createRuntime(
        config: RuntimeConfig(
          discoveryDisplayName: displayName,
          applicationMetadata: utf8.encode(displayName),
          trustMode: testTrustMode,
          autoReconnect: true,
          logger: (message) => _record('lpcLog', {'message': message}),
        ),
        platformBleBackend: backend,
      );
      runtime = localRuntime;
      localRuntime.events.listen(_onRuntimeEvent);
      host = localRuntime.createHostSession(HostConfig(autoAccept: true));
      host!.events.listen(_onHostEvent);
      _record('runtimeReady', {
        'peerId': localRuntime.localPeerId.toString(),
        'displayName': displayName,
      });
      await startPresence();
      try {
        final capabilities = await localRuntime.capabilities();
        _capabilities = capabilities.value;
        _record('capabilities', {'bitmap': capabilities.value});
      } on Object catch (error) {
        _capabilities = null;
        _recordError('capabilitiesFailed', error);
      }
    } on Object catch (error) {
      _recordError('runtimeInitializationFailed', error);
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  Future<void> startControlServer() async {
    if (!kDebugMode || _server != null || _disposed) return;
    try {
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        controlPort,
      );
      _record('controlServerReady', {'port': controlPort});
      _server!.listen(
        _handleRequest,
        onError: (Object error) {
          _recordError('controlServerError', error);
        },
      );
      notifyListeners();
    } on Object catch (error) {
      _recordError('controlServerStartFailed', error);
    }
  }

  Future<void> startPresence() async {
    final localHost = host;
    final localRuntime = runtime;
    if (localHost == null || localRuntime == null) throw invalidStateError();
    // CoreBluetooth reports .unknown briefly while its managers are being
    // initialized. The first listenGatt/startAdvertising call can therefore
    // return BLUETOOTH_UNAVAILABLE even though Bluetooth is healthy. Retry
    // only that bounded startup race; a powered-off/permission/backend error
    // remains visible to the host runner instead of being hidden forever.
    for (var attempt = 0; ; attempt++) {
      try {
        if (!localHost.isAdvertising) await localHost.startAdvertising();
        if (discovery == null || discovery!.isStopped) {
          discovery = await localRuntime.startDiscovery();
          discovery!.events.listen(_onDiscoveryEvent);
        }
        break;
      } on LpcException catch (error) {
        final retryable = error.code == LpcErrorCode.bluetoothUnavailable;
        if (!retryable || attempt >= 10) rethrow;
        _record('presenceStartupRetry', {
          'attempt': attempt + 1,
          'error': error.code.name,
        });
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    _record('presenceStarted', {});
    notifyListeners();
  }

  Future<void> stopPresence() async {
    await discovery?.stop();
    discovery = null;
    await host?.stopAdvertising();
    _record('presenceStopped', {});
    if (!_disposed) notifyListeners();
  }

  Future<void> connect(String endpointId) async {
    final localRuntime = runtime;
    if (localRuntime == null) throw invalidStateError();
    final attempt = localRuntime.connect(endpointId);
    _attempts[endpointId] = attempt;
    _record('connectRequested', {'endpointId': endpointId});
    attempt.events.listen((event) {
      if (event is PeerVerificationRequired) {
        _record('verificationRequired', {
          'direction': 'outbound',
          'endpointId': endpointId,
          'peerId': event.peerId.toString(),
          'sas': event.sas,
        });
      } else if (event is ConnectionAttemptConnected) {
        _attempts.remove(endpointId);
        _watchPeer(event.connection, endpointId: endpointId);
        _record('connectSucceeded', {
          'endpointId': endpointId,
          'peerId': event.connection.peerId.toString(),
        });
      } else if (event is ConnectionAttemptFailed) {
        _attempts.remove(endpointId);
        _recordError(
          'connectFailed',
          event.error,
          extra: {'endpointId': endpointId},
        );
      } else if (event is ConnectionAttemptCancelled) {
        _attempts.remove(endpointId);
        _record('connectCancelled', {'endpointId': endpointId});
      }
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> cancelConnect(String endpointId) async {
    await _attempts.remove(endpointId)?.cancel();
  }

  Future<void> confirmVerification(String peerId, bool accepted) async {
    final pendingHost = _pendingHostVerifications.remove(peerId);
    if (pendingHost != null) {
      await host!.confirmPeerVerification(_parsePeerId(peerId), accepted);
      _record('verificationConfirmed', {
        'direction': 'inbound',
        'peerId': peerId,
        'accepted': accepted,
      });
      return;
    }
    for (final attempt in _attempts.values) {
      try {
        await attempt.confirmPeerVerification(accepted);
        _record('verificationConfirmed', {
          'direction': 'outbound',
          'peerId': peerId,
          'accepted': accepted,
        });
        return;
      } on LpcException {
        // This attempt has no pending verification; try the next one.
      }
    }
    throw const LpcException(
      LpcErrorCode.invalidState,
      'no matching verification is pending',
    );
  }

  Future<void> sendReliable(
    String peerId,
    List<int> bytes,
    DeliveryMode deliveryMode,
  ) async {
    if (deliveryMode == DeliveryMode.realtimeLatest) {
      throw const LpcException(
        LpcErrorCode.invalidArgument,
        'use sendRealtime for REALTIME_LATEST',
      );
    }
    final peer = _peer(peerId);
    final handle = peer.send(
      bytes,
      options: SendOptions(deliveryMode: deliveryMode),
    );
    _record('sendAccepted', {
      'kind': 'direct',
      'peerId': peer.peerId.toString(),
      'deliveryMode': deliveryMode.name,
      'bytes': bytes.length,
      'digest': payloadDigest(bytes),
      'state': handle.state.name,
    });
    unawaited(
      _recordSendCompletion(handle, {
        'kind': 'direct',
        'peerId': peer.peerId.toString(),
      }),
    );
  }

  Future<void> sendRealtime(
    String peerId,
    int channelId,
    List<int> bytes,
  ) async {
    final peer = _peer(peerId);
    final handle = peer.sendRealtime(channelId, bytes);
    _record('sendAccepted', {
      'kind': 'directRealtime',
      'peerId': peer.peerId.toString(),
      'channelId': channelId,
      'bytes': bytes.length,
      'digest': payloadDigest(bytes),
      'state': handle.state.name,
    });
    unawaited(
      _recordSendCompletion(handle, {
        'kind': 'directRealtime',
        'peerId': peer.peerId.toString(),
        'channelId': channelId,
      }),
    );
  }

  Future<void> createGroup({
    List<int> namespace = const [1, 2, 3],
    List<int>? token,
    int maxPeers = 8,
    bool checkpointing = false,
  }) async {
    if (group != null) throw const LpcException(LpcErrorCode.invalidState);
    final localRuntime = runtime;
    if (localRuntime == null) throw invalidStateError();
    final localGroup = localRuntime.joinOrCreateGroup(
      GroupConfig(
        applicationNamespace: namespace,
        groupJoinToken: token ?? List<int>.filled(16, 7),
        maxPeers: maxPeers,
        coordinatorCheckpointing: checkpointing,
        groupTrustMode: GroupTrustMode.openTofu,
        autoAccept: true,
        autoMerge: true,
      ),
    );
    group = localGroup;
    localGroup.events.listen(_onGroupEvent);
    _record('groupCreated', _groupSnapshot(localGroup));
    notifyListeners();
  }

  Future<void> sendGroup(String peerId, List<int> bytes) async {
    final localGroup = group;
    if (localGroup == null) throw invalidStateError();
    final handle = localGroup.send(
      _parsePeerId(peerId),
      bytes,
      options: const SendOptions(deliveryMode: DeliveryMode.reliableAcked),
    );
    _record('sendAccepted', {
      'kind': 'group',
      'peerId': peerId,
      'bytes': bytes.length,
      'state': handle.state.name,
    });
    unawaited(
      _recordSendCompletion(handle, {'kind': 'group', 'peerId': peerId}),
    );
  }

  Future<void> sendGroupRealtime(
    String peerId,
    int channelId,
    List<int> bytes,
  ) async {
    final localGroup = group;
    if (localGroup == null) throw invalidStateError();
    final handle = localGroup.sendRealtime(
      _parsePeerId(peerId),
      channelId,
      bytes,
    );
    _record('sendAccepted', {
      'kind': 'groupRealtime',
      'peerId': peerId,
      'channelId': channelId,
      'bytes': bytes.length,
      'state': handle.state.name,
    });
  }

  Future<void> publishCheckpoint(List<int> bytes) async {
    final localGroup = group;
    if (localGroup == null) throw invalidStateError();
    final handle = localGroup.publishCoordinatorCheckpoint(bytes);
    _record('checkpointAccepted', {
      'publicationId': handle.publicationId,
      'bytes': bytes.length,
      'requiredPeerIds': [
        for (final peerId in handle.requiredPeerIds) peerId.toString(),
      ],
    });
    unawaited(_recordCheckpointCompletion(handle));
  }

  Future<void> _recordCheckpointCompletion(
    CoordinatorCheckpointHandle handle,
  ) async {
    final result = await handle.completion;
    _record('checkpointCompleted', {
      'publicationId': result.publicationId,
      'status': result.status.name,
      'requiredPeerIds': [
        for (final peerId in result.requiredPeerIds) peerId.toString(),
      ],
      'perPeerResults': {
        for (final entry in result.perPeerResults.entries)
          entry.key.toString(): entry.value.name,
      },
    });
  }

  Future<void> leaveGroup() async {
    group?.leave();
    group = null;
    _record('groupLeft', {});
    notifyListeners();
  }

  Future<void> disconnectPeer(String peerId) async {
    await _peer(peerId).disconnect();
  }

  Future<void> releasePeerRetention(String peerId) async {
    final localRuntime = runtime;
    if (localRuntime == null) throw invalidStateError();
    await localRuntime.releasePeerRetention(_parsePeerId(peerId));
    _record('peerRetentionReleased', {'peerId': peerId});
  }

  Future<void> updatePresentation(String name, {List<int>? metadata}) async {
    final localRuntime = runtime;
    if (localRuntime == null) throw invalidStateError();
    final bounded = boundedDisplayName(name);
    await localRuntime.updateLocalPresentation(
      LocalPresentation(
        discoveryDisplayName: bounded,
        applicationMetadata: metadata ?? utf8.encode(bounded),
      ),
    );
    _record('presentationUpdated', {'displayName': bounded});
  }

  Map<String, Object?> snapshot() => {
    'runtimeState': runtime?.state.name ?? 'notInitialized',
    'localPeerId': runtime?.localPeerId.toString(),
    'displayName': displayName,
    'controlApi': _server == null ? 'disabled' : '127.0.0.1:$controlPort',
    'capabilities': _capabilities,
    // Presence is live state. Do not make the host runner infer it from the
    // bounded event history, because endpoint updates can evict the original
    // presenceStarted event on a busy physical device.
    'presenceActive':
        host?.isAdvertising == true &&
        discovery != null &&
        !discovery!.isStopped,
    'endpoints': [
      for (final endpoint in discovery?.currentEndpoints() ?? const [])
        _endpointSnapshot(endpoint),
    ],
    'connections': [for (final peer in _peers.values) _peerSnapshot(peer)],
    'attempts': [for (final endpointId in _attempts.keys) endpointId],
    'pendingVerifications': [
      for (final value in _pendingHostVerifications.values)
        {'peerId': value.peerId.toString(), 'sas': value.sas},
    ],
    'group': group == null ? null : _groupSnapshot(group!),
    'eventSequence': _eventSequence,
  };

  Future<void> resetRuntime() async {
    _record('runtimeResetRequested', {});
    await _closeRuntime();
    await initialize();
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    unawaited(_server?.close());
    unawaited(_closeRuntime());
    super.dispose();
  }

  Future<void> _closeRuntime() async {
    for (final subscription in _peerSubscriptions.values) {
      await subscription.cancel();
    }
    _peerSubscriptions.clear();
    _peers.clear();
    for (final attempt in _attempts.values) {
      await attempt.cancel();
    }
    _attempts.clear();
    _pendingHostVerifications.clear();
    group?.close();
    group = null;
    await discovery?.stop();
    discovery = null;
    await host?.close();
    host = null;
    await runtime?.close();
    runtime = null;
    _capabilities = null;
    if (!_disposed) notifyListeners();
  }

  void _watchPeer(PeerConnection peer, {String? endpointId}) {
    final key = peer.peerId.toString();
    if (_peers[key] == peer) return;
    final old = _peers[key];
    if (old != null && old != peer) {
      _record('duplicateLogicalPeerObserved', {'peerId': key});
    }
    _peers[key] = peer;
    final eventsSubscription = peer.events.listen((event) {
      if (event is PeerReconnecting) {
        _record('peerReconnecting', {'peerId': key});
      } else if (event is PeerReconnected) {
        _record('peerReconnected', {
          'peerId': key,
          'sessionId': _hex(event.sessionId),
          'transport': event.transport.name,
        });
      } else if (event is PeerDisconnected) {
        _record('peerDisconnected', {'peerId': key});
        if (_peers[key] == peer) _peers.remove(key);
        notifyListeners();
      }
    });
    peer.messages.listen((message) {
      _record('directMessageReceived', {
        'peerId': key,
        'deliveryMode': message.deliveryMode.name,
        'bytes': message.bytes.length,
        'digest': payloadDigest(message.bytes),
      });
    });
    peer.realtimeMessages.listen((message) {
      _record('directRealtimeReceived', {
        'peerId': key,
        'channelId': message.channelId,
        'bytes': message.bytes.length,
        'digest': payloadDigest(message.bytes),
      });
    });
    _peerSubscriptions[peer] = eventsSubscription;
    _record('peerReady', {
      'peerId': key,
      'endpointId': endpointId,
      ..._peerSnapshot(peer),
    });
    notifyListeners();
  }

  void _onRuntimeEvent(RuntimeEvent event) {
    switch (event) {
      case KnownPeerProbeStarted(:final discoveryEndpointId):
        _record('knownPeerProbeStarted', {'endpointId': discoveryEndpointId});
      case KnownPeerProbeFailed(:final discoveryEndpointId, :final error):
        _recordError(
          'knownPeerProbeFailed',
          error,
          extra: {'endpointId': discoveryEndpointId},
        );
      case UnknownPeerIdentified(:final connection, :final discoveryEndpointId):
        _watchPeer(connection, endpointId: discoveryEndpointId);
        _record('unknownPeerIdentified', {
          'peerId': connection.peerId.toString(),
          'endpointId': discoveryEndpointId,
          'metadataBytes': connection.remoteApplicationMetadata.length,
        });
      case KnownPeerConnected(:final connection, :final discoveryEndpointId):
        _watchPeer(connection, endpointId: discoveryEndpointId);
        _record('knownPeerConnected', {
          'peerId': connection.peerId.toString(),
          'endpointId': discoveryEndpointId,
        });
    }
  }

  void _onHostEvent(HostSessionEvent event) {
    switch (event) {
      case HostPeerConnected(:final connection, :final discoveryEndpointId):
        _watchPeer(connection, endpointId: discoveryEndpointId);
        _record('hostPeerConnected', {
          'peerId': connection.peerId.toString(),
          'endpointId': discoveryEndpointId,
        });
      case HostPeerVerificationRequired(:final peerId, :final sas):
        _pendingHostVerifications[peerId.toString()] = event;
        _record('verificationRequired', {
          'direction': 'inbound',
          'peerId': peerId.toString(),
          'sas': sas,
        });
      case HostSessionClosed():
        _record('hostClosed', {});
    }
    notifyListeners();
  }

  void _onDiscoveryEvent(DiscoveryEvent event) {
    switch (event) {
      case EndpointFound(:final endpoint):
        _record('endpointFound', _endpointSnapshot(endpoint));
      case EndpointUpdated(:final endpoint):
        _record('endpointUpdated', _endpointSnapshot(endpoint));
      case EndpointLost(:final endpoint):
        _record('endpointLost', _endpointSnapshot(endpoint));
      case DiscoveryStopped():
        _record('discoveryStopped', {});
    }
    _scheduleNotify();
  }

  void _onGroupEvent(GroupEvent event) {
    final values = <String, Object?>{
      'eventSequence': event.eventSequence,
      'observedAtMs': event.observedAtMonotonicMs,
    };
    switch (event) {
      case GroupReady(:final groupId, :final coordinatorPeerId, :final members):
        _record('groupReady', {
          ...values,
          'groupId': _hex(groupId.bytes),
          'coordinatorPeerId': coordinatorPeerId.toString(),
          'memberPeerIds': [
            for (final member in members) member.peerId.toString(),
          ],
        });
      case MemberJoined(:final member):
        _record('groupMemberJoined', {
          ...values,
          'peerId': member.peerId.toString(),
        });
      case MemberLeft(:final peerId):
        _record('groupMemberLeft', {...values, 'peerId': peerId.toString()});
      case CoordinatorChanged(
        :final previous,
        :final current,
        :final localIsCoordinator,
      ):
        _record('groupCoordinatorChanged', {
          ...values,
          'previous': previous?.toString(),
          'current': current.toString(),
          'localIsCoordinator': localIsCoordinator,
        });
      case ReliableMessageReceived(
        :final sourcePeerId,
        :final groupMessageId,
        :final deliveryMode,
        :final bytes,
      ):
        _record('groupMessageReceived', {
          ...values,
          'sourcePeerId': sourcePeerId.toString(),
          'groupMessageId': _hex(groupMessageId.bytes),
          'deliveryMode': deliveryMode.name,
          'bytes': bytes.length,
          'digest': payloadDigest(bytes),
        });
      case RealtimeDatagramReceived(
        :final sourcePeerId,
        :final channelId,
        :final datagramSequence,
        :final bytes,
      ):
        _record('groupRealtimeReceived', {
          ...values,
          'sourcePeerId': sourcePeerId.toString(),
          'channelId': channelId,
          'datagramSequence': datagramSequence,
          'bytes': bytes.length,
          'digest': payloadDigest(bytes),
        });
      case GroupError(:final errorCode, :final peerId, :final diagnostic):
        _record('groupError', {
          ...values,
          'error': errorCode.name,
          'peerId': peerId?.toString(),
          'diagnostic': diagnostic,
        });
      case GroupClosed():
        _record('groupClosed', values);
      case CoordinatorCheckpointUpdated(
        :final checkpointSequence,
        :final bytes,
      ):
        _record('checkpointUpdated', {
          ...values,
          'checkpointSequence': checkpointSequence,
          'bytes': bytes.length,
        });
      case CoordinatorCheckpointReplicationAcknowledged(
        :final publicationId,
        :final peerId,
        :final checkpointSequence,
      ):
        _record('checkpointPeerAcknowledged', {
          ...values,
          'publicationId': publicationId,
          'peerId': peerId.toString(),
          'checkpointSequence': checkpointSequence,
        });
      case CoordinatorCheckpointReplicationFailed(
        :final publicationId,
        :final peerId,
        :final errorCode,
      ):
        _record('checkpointPeerFailed', {
          ...values,
          'publicationId': publicationId,
          'peerId': peerId.toString(),
          'error': errorCode.name,
        });
      case CoordinatorCheckpointPublicationCompleted(
        :final publicationId,
        :final status,
      ):
        _record('checkpointPublicationCompleted', {
          ...values,
          'publicationId': publicationId,
          'status': status.name,
        });
    }
    notifyListeners();
  }

  Future<void> _recordSendCompletion(
    SendHandle handle,
    Map<String, Object?> values,
  ) async {
    final state = await handle.completed;
    _record('sendCompleted', {...values, 'state': state.name});
  }

  Future<void> _handleRequest(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('cache-control', 'no-store');
    try {
      if (request.method == 'GET' && request.uri.path == '/health') {
        await _writeResponse(request, {'ok': true, 'snapshot': snapshot()});
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/snapshot') {
        await _writeResponse(request, snapshot());
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/events') {
        final after =
            int.tryParse(request.uri.queryParameters['after'] ?? '0') ?? 0;
        await _writeResponse(request, {
          'events': events
              .where((event) => event['sequence']! as int > after)
              .toList(),
          'next': _eventSequence,
        });
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/command') {
        final body = await utf8.decoder.bind(request).join();
        final decoded = jsonDecode(body);
        if (decoded is! Map) {
          throw const FormatException('command must be an object');
        }
        final action = decoded['action'];
        final arguments = decoded['arguments'];
        if (action is! String || arguments is! Map) {
          throw const FormatException('action and arguments are required');
        }
        final result = await command(
          action,
          Map<String, Object?>.from(arguments),
        );
        await _writeResponse(request, {'ok': true, 'result': result});
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await _writeResponse(request, {'ok': false, 'error': 'not found'});
    } on Object catch (error) {
      request.response.statusCode = error is FormatException
          ? HttpStatus.badRequest
          : HttpStatus.internalServerError;
      await _writeResponse(request, {'ok': false, 'error': _errorMap(error)});
    }
  }

  Future<Map<String, Object?>> command(
    String action,
    Map<String, Object?> arguments,
  ) async {
    switch (action) {
      case 'getSnapshot':
        return snapshot();
      case 'startPresence':
        await startPresence();
        return snapshot();
      case 'stopPresence':
        await stopPresence();
        return snapshot();
      case 'connect':
        await connect(_requiredString(arguments, 'endpointId'));
        return snapshot();
      case 'cancelConnect':
        await cancelConnect(_requiredString(arguments, 'endpointId'));
        return snapshot();
      case 'confirmVerification':
        await confirmVerification(
          _requiredString(arguments, 'peerId'),
          arguments['accepted'] == true,
        );
        return snapshot();
      case 'sendReliable':
        await sendReliable(
          _requiredString(arguments, 'peerId'),
          bytesFromArguments(arguments),
          deliveryModeFrom(arguments['deliveryMode']),
        );
        return snapshot();
      case 'sendRealtime':
        await sendRealtime(
          _requiredString(arguments, 'peerId'),
          (arguments['channelId'] as num?)?.toInt() ?? 1,
          bytesFromArguments(arguments),
        );
        return snapshot();
      case 'createGroup':
        await createGroup(
          namespace: intList(arguments['namespace']) ?? const [1, 2, 3],
          token: intList(arguments['token']),
          maxPeers: (arguments['maxPeers'] as num?)?.toInt() ?? 8,
          checkpointing: arguments['checkpointing'] == true,
        );
        return snapshot();
      case 'sendGroup':
        await sendGroup(
          _requiredString(arguments, 'peerId'),
          bytesFromArguments(arguments),
        );
        return snapshot();
      case 'sendGroupRealtime':
        await sendGroupRealtime(
          _requiredString(arguments, 'peerId'),
          (arguments['channelId'] as num?)?.toInt() ?? 1,
          bytesFromArguments(arguments),
        );
        return snapshot();
      case 'publishCheckpoint':
        await publishCheckpoint(bytesFromArguments(arguments));
        return snapshot();
      case 'leaveGroup':
        await leaveGroup();
        return snapshot();
      case 'disconnectPeer':
        await disconnectPeer(_requiredString(arguments, 'peerId'));
        return snapshot();
      case 'releasePeerRetention':
        await releasePeerRetention(_requiredString(arguments, 'peerId'));
        return snapshot();
      case 'updatePresentation':
        await updatePresentation(
          _requiredString(arguments, 'name'),
          metadata: intList(arguments['metadata']),
        );
        return snapshot();
      case 'resetRuntime':
        await resetRuntime();
        return snapshot();
      default:
        throw FormatException('unknown action: $action');
    }
  }

  Future<void> _writeResponse(HttpRequest request, Object value) async {
    request.response.write(jsonEncode(value));
    await request.response.close();
  }

  PeerConnection _peer(String peerId) {
    final peer = _peers[peerId];
    if (peer == null) {
      throw const LpcException(LpcErrorCode.destinationUnavailable);
    }
    return peer;
  }

  Map<String, Object?> _peerSnapshot(PeerConnection peer) => {
    'peerId': peer.peerId.toString(),
    'state': peer.state.name,
    'security': peer.securityLevel.name,
    'transport': peer.activeTransport.name,
    'sessionId': _hex(peer.sessionId),
    'remoteMetadataBytes': peer.remoteApplicationMetadata.length,
  };

  Map<String, Object?> _endpointSnapshot(DiscoveredEndpoint endpoint) => {
    'id': endpoint.id,
    'rssi': endpoint.rssi,
    'localName': endpoint.localName,
  };

  Map<String, Object?> _groupSnapshot(GroupSession value) => {
    'groupId': _hex(value.groupId.bytes),
    'state': value.state.name,
    'coordinatorPeerId': value.coordinatorPeerId?.toString(),
    'coordinatorTerm': value.coordinatorTerm,
    'localIsCoordinator': value.isCoordinator,
    'members': [for (final member in value.members) member.peerId.toString()],
  };

  void _record(String type, Map<String, Object?> data) {
    if (_disposed) return;
    final event = <String, Object?>{
      'sequence': ++_eventSequence,
      'atMs': DateTime.now().millisecondsSinceEpoch,
      'type': type,
      ...data,
    };
    events.add(event);
    if (events.length > maxEventHistory) events.removeAt(0);
    // Discovery and transport diagnostics can arrive much faster than a UI
    // can repaint (especially during the message-load test). Coalesce those
    // repaint requests while retaining every event in the control API history.
    _scheduleNotify();
  }

  void _scheduleNotify() {
    if (_disposed || _notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 100), () {
      _notifyTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  void _recordError(
    String type,
    Object error, {
    Map<String, Object?> extra = const {},
  }) {
    _record(type, {'error': _errorMap(error), ...extra});
  }

  Map<String, Object?> _errorMap(Object error) => {
    'code': error is LpcException ? error.code.name : 'unknown',
    'message': error.toString(),
  };

  LpcException invalidStateError() => const LpcException(
    LpcErrorCode.invalidState,
    'runtime is not initialized',
  );

  String _requiredString(Map<String, Object?> arguments, String key) {
    final value = arguments[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('$key is required');
    }
    return value;
  }
}

String boundedDisplayName(String value) {
  final runes = value
      .trim()
      .runes
      .where((rune) => rune >= 0x20 && rune != 0x7f)
      .toList(growable: false);
  if (runes.isEmpty) return 'LPC Test Device';
  final accepted = <int>[];
  for (final rune in runes) {
    final candidate = String.fromCharCodes([...accepted, rune]);
    if (utf8.encode(candidate).length > 24) break;
    accepted.add(rune);
  }
  return accepted.isEmpty ? 'LPC Test Device' : String.fromCharCodes(accepted);
}

HandshakeTrustMode get testTrustMode {
  return switch (const String.fromEnvironment(
    'LPC_TEST_TRUST_MODE',
    defaultValue: 'tofu',
  )) {
    'sas' => HandshakeTrustMode.sas,
    'tofu' => HandshakeTrustMode.tofu,
    _ => throw StateError('LPC_TEST_TRUST_MODE must be sas or tofu'),
  };
}

List<int> bytesFromArguments(Map<String, Object?> arguments) {
  final bytes = intList(arguments['bytes']);
  if (bytes != null) return bytes;
  final text = arguments['text'];
  if (text is String) return utf8.encode(text);
  final size = (arguments['size'] as num?)?.toInt();
  if (size != null) {
    if (size < 0 || size > 1048576) {
      throw const LpcException(LpcErrorCode.messageTooLarge);
    }
    return List<int>.generate(size, (index) => index % 251);
  }
  throw const FormatException('provide bytes, text, or size');
}

String payloadDigest(List<int> bytes) {
  var value = 2166136261;
  for (final byte in bytes) {
    value = ((value ^ (byte & 0xff)) * 16777619) & 0xffffffff;
  }
  return value.toRadixString(16).padLeft(8, '0');
}

List<int>? intList(Object? value) {
  if (value is! List) return null;
  return [
    for (final item in value)
      if (item is num)
        item.toInt()
      else
        throw const FormatException('expected integer list'),
  ];
}

DeliveryMode deliveryModeFrom(Object? value) => switch (value) {
  'reliableAcked' => DeliveryMode.reliableAcked,
  'reliableOrdered' || null => DeliveryMode.reliableOrdered,
  _ => throw FormatException('unsupported deliveryMode: $value'),
};

PeerId _parsePeerId(String value) {
  if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(value)) {
    throw const FormatException('PeerId must be 32 hexadecimal characters');
  }
  return PeerId([
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ]);
}

String _hex(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

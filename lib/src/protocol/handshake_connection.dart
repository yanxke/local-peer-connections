import 'dart:async';

import '../backend.dart';
import '../peer_connection_core.dart';
import '../types.dart';
import 'control_payload.dart';
import 'crypto.dart';
import 'frame.dart';
import 'handshake_exchange.dart';

/// Backend-bound Section 16 handshake driver.
///
/// It owns plaintext HELLO/AUTH until [HandshakeExchange] authenticates, then
/// exchanges the mandatory generation-1 READY frames.  Its [ready] future
/// completes only after the local READY reached the backend API boundary and
/// the remote READY authenticated; the returned core consequently starts
/// ordinary encrypted traffic at sequence 2 in both directions.
class HandshakeConnection {
  HandshakeConnection({
    required this.backend,
    required this.exchange,
    required this.localPeerId,
    required this.remotePeerId,
  });

  final BackendConnection backend;
  final HandshakeExchange exchange;
  final PeerId localPeerId;
  final PeerId remotePeerId;
  final Completer<PeerConnectionCore> _ready = Completer<PeerConnectionCore>();
  StreamSubscription<BackendConnectionEvent>? _subscription;
  bool _started = false;
  bool _localReadySubmitted = false;
  bool _remoteReadyAuthenticated = false;

  Future<PeerConnectionCore> get ready => _ready.future;

  /// Begins the local HELLO. Call after the backend reports it is open.
  Future<void> start() async {
    if (_started) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'handshake has already started');
    }
    _started = true;
    _subscription = backend.events.listen((event) {
      if (event is BackendBytesReceived) unawaited(_receive(event.bytes));
      if (event is BackendClosed) {
        _fail(const LpcException(LpcErrorCode.transportClosed));
      }
      if (event is BackendError) _fail(event.error);
    },
        onError: (Object error, StackTrace stackTrace) =>
            _fail(error, stackTrace));
    try {
      await _send(exchange.createHello());
    } catch (error, stackTrace) {
      await _closeWithError(error, stackTrace);
      rethrow;
    }
  }

  /// Confirms an SAS-authenticated exchange and, when accepted, starts READY.
  Future<void> confirmSas(bool accepted) async {
    try {
      exchange.confirmSas(accepted);
      await _sendReadyIfAuthenticated();
    } catch (error, stackTrace) {
      await _closeWithError(error, stackTrace);
      rethrow;
    }
  }

  Future<void> _receive(List<int> bytes) async {
    if (_ready.isCompleted) return;
    try {
      final frame = LpcFrame.decode(bytes);
      if (!frame.encrypted) {
        final response = await exchange.receivePlaintext(frame);
        if (response != null) {
          // Section 16.2.1 requires this response to be sent before close.
          await _send(response);
          await _closeWithError(
              const LpcException(LpcErrorCode.protocolMismatch));
          return;
        }
        if (exchange.state == HandshakeExchangeState.helloExchanged) {
          await _send(await exchange.createAuth());
        }
        await _sendReadyIfAuthenticated();
        return;
      }
      await _receiveReady(frame);
    } catch (error, stackTrace) {
      await _closeWithError(error, stackTrace);
    }
  }

  Future<void> _sendReadyIfAuthenticated() async {
    if (exchange.state != HandshakeExchangeState.authenticated ||
        _localReadySubmitted ||
        _ready.isCompleted) {
      return;
    }
    final result = exchange.result!;
    final direction = _direction(localPeerId, remotePeerId);
    final key = await trafficKey(result.secrets.sessionRootKey, 1, direction);
    final clear = LpcFrame(
        type: FrameType.ready,
        flags: 0,
        transportGeneration: 1,
        sequenceNumber: 1,
        messageId: List<int>.filled(8, 0),
        sessionId: result.secrets.sessionId,
        nonce: List<int>.filled(12, 0),
        payload: result.createReady().encode());
    final protected =
        await const FrameProtector().encrypt(clear, await key.extractBytes());
    final status = await _write(protected);
    if (status != TransportWriteState.submittedToPlatform) {
      throw const LpcException(LpcErrorCode.transportClosed);
    }
    _localReadySubmitted = true;
    await _completeIfReady();
  }

  Future<void> _receiveReady(LpcFrame frame) async {
    final result = exchange.result;
    if (result == null ||
        frame.type != FrameType.ready ||
        frame.flags != 0 ||
        frame.protocolMinor != result.negotiatedMinor ||
        frame.transportGeneration != 1 ||
        frame.sequenceNumber != 1 ||
        frame.messageId.any((byte) => byte != 0) ||
        !_same(frame.sessionId, result.secrets.sessionId)) {
      throw const LpcException(
          LpcErrorCode.protocolMismatch, 'invalid READY frame');
    }
    final key = await trafficKey(result.secrets.sessionRootKey, 1,
        _direction(remotePeerId, localPeerId));
    final clear =
        await const FrameProtector().decrypt(frame, await key.extractBytes());
    result.verifyRemoteReady(ReadyPayload.decode(clear.payload));
    _remoteReadyAuthenticated = true;
    await _completeIfReady();
  }

  Future<void> _completeIfReady() async {
    if (!_localReadySubmitted ||
        !_remoteReadyAuthenticated ||
        _ready.isCompleted) {
      return;
    }
    await _subscription?.cancel();
    _ready.complete(PeerConnectionCore(
        backend: backend,
        sessionRootKey: exchange.result!.secrets.sessionRootKey,
        sessionId: exchange.result!.secrets.sessionId,
        localPeerId: localPeerId,
        remotePeerId: remotePeerId,
        initialNextSequence: 2,
        initialHighestReceivedSequence: 1));
  }

  Future<void> _send(LpcFrame frame) async {
    final status = await _write(frame);
    if (status != TransportWriteState.submittedToPlatform) {
      throw const LpcException(LpcErrorCode.transportClosed);
    }
  }

  Future<TransportWriteState> _write(LpcFrame frame) =>
      backend.write(frame.encode()).completion;

  Future<void> _closeWithError(Object error, [StackTrace? stackTrace]) async {
    if (!_ready.isCompleted) _ready.completeError(error, stackTrace);
    await _subscription?.cancel();
    await backend.close();
  }

  void _fail(Object error, [StackTrace? stackTrace]) {
    unawaited(_closeWithError(error, stackTrace));
  }
}

int _direction(PeerId sender, PeerId receiver) =>
    _compare(sender.bytes, receiver.bytes) < 0 ? 0 : 1;

int _compare(List<int> a, List<int> b) {
  for (var index = 0; index < a.length; index++) {
    final comparison = a[index].compareTo(b[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var index = 0; index < a.length; index++) {
    difference |= a[index] ^ b[index];
  }
  return difference == 0;
}

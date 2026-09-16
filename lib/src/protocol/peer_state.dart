import '../types.dart';

enum PeerConnectionState {
  discovered,
  connecting,
  transportConnected,
  authenticating,
  ready,
  reconnecting,
  disconnecting,
  disconnected,
  failed
}

class PeerStateMachine {
  PeerStateMachine([this._state = PeerConnectionState.discovered]);
  PeerConnectionState _state;
  PeerConnectionState get state => _state;
  bool transition(PeerConnectionState next) {
    const allowed = {
      PeerConnectionState.discovered: {PeerConnectionState.connecting},
      PeerConnectionState.connecting: {
        PeerConnectionState.transportConnected,
        PeerConnectionState.failed
      },
      PeerConnectionState.transportConnected: {
        PeerConnectionState.authenticating,
        PeerConnectionState.failed
      },
      PeerConnectionState.authenticating: {
        PeerConnectionState.ready,
        PeerConnectionState.failed
      },
      PeerConnectionState.ready: {
        PeerConnectionState.reconnecting,
        PeerConnectionState.disconnecting,
        PeerConnectionState.failed
      },
      PeerConnectionState.reconnecting: {
        PeerConnectionState.ready,
        PeerConnectionState.disconnected,
        PeerConnectionState.disconnecting
      },
      PeerConnectionState.disconnecting: {PeerConnectionState.disconnected},
      PeerConnectionState.failed: {PeerConnectionState.disconnected}
    };
    if (!(allowed[_state]?.contains(next) ?? false)) return false;
    _state = next;
    return true;
  }

  void requireTransition(PeerConnectionState next) {
    if (!transition(next))
      throw const LpcException(
          LpcErrorCode.invalidState, 'illegal PeerConnection state transition');
  }
}

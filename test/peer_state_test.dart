import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('Section 40 allows only the frozen READY/reconnect path', () {
    final peer = PeerStateMachine();
    peer.requireTransition(PeerConnectionState.connecting);
    peer.requireTransition(PeerConnectionState.transportConnected);
    peer.requireTransition(PeerConnectionState.authenticating);
    peer.requireTransition(PeerConnectionState.ready);
    peer.requireTransition(PeerConnectionState.reconnecting);
    peer.requireTransition(PeerConnectionState.ready);
    expect(peer.state, PeerConnectionState.ready);
  });
  test('UT-040 impossible callback cannot create state transition', () {
    final peer = PeerStateMachine();
    expect(peer.transition(PeerConnectionState.ready), isFalse);
    expect(peer.state, PeerConnectionState.discovered);
  });
}

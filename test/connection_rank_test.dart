import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test('UT-033 symmetric dual GATT links select the same rank winner',
      () async {
    final a = PeerId(List<int>.filled(16, 1));
    final b = PeerId(List<int>.filled(16, 2));
    final firstAtA = await connectionRank(
        peerA: a,
        peerB: b,
        connectionNonceA: List<int>.filled(16, 3),
        connectionNonceB: List<int>.filled(16, 4));
    final firstAtB = await connectionRank(
        peerA: b,
        peerB: a,
        connectionNonceA: List<int>.filled(16, 4),
        connectionNonceB: List<int>.filled(16, 3));
    final second = await connectionRank(
        peerA: a,
        peerB: b,
        connectionNonceA: List<int>.filled(16, 5),
        connectionNonceB: List<int>.filled(16, 6));

    expect(firstAtA, firstAtB);
    final winnerAtA = retainedConnectionRankIndex(firstAtA, second);
    final winnerAtB = retainedConnectionRankIndex(firstAtB, second);
    expect(winnerAtA, winnerAtB);
  });
}

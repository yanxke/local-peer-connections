import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../types.dart';

/// Section 10.2 rank for one authenticated physical connection. Both peers
/// compute the same value regardless of their local/remote orientation.
Future<Uint8List> connectionRank({
  required PeerId peerA,
  required PeerId peerB,
  required List<int> connectionNonceA,
  required List<int> connectionNonceB,
}) async {
  if (connectionNonceA.length != 16 || connectionNonceB.length != 16) {
    throw ArgumentError('connection nonces must be 16 bytes');
  }
  final peers = _ordered(peerA.bytes, peerB.bytes);
  final nonces = _ordered(connectionNonceA, connectionNonceB);
  final digest = await Sha256()
      .hash([...peers.$1, ...peers.$2, ...nonces.$1, ...nonces.$2]);
  return Uint8List.fromList(digest.bytes);
}

/// Returns the index of the retained connection rank. Equal ranks identify
/// the same nonce pair and therefore cannot represent distinct links.
int retainedConnectionRankIndex(List<int> first, List<int> second) {
  if (first.length != 32 || second.length != 32) {
    throw ArgumentError('connection ranks must be 32 bytes');
  }
  final comparison = _compare(first, second);
  if (comparison == 0) {
    throw const LpcException(LpcErrorCode.duplicateConnection,
        'distinct connections have equal rank');
  }
  return comparison < 0 ? 0 : 1;
}

(List<int>, List<int>) _ordered(List<int> first, List<int> second) =>
    _compare(first, second) <= 0 ? (first, second) : (second, first);

int _compare(List<int> first, List<int> second) {
  for (var i = 0; i < first.length && i < second.length; i++) {
    final difference = first[i] - second[i];
    if (difference != 0) return difference;
  }
  return first.length - second.length;
}

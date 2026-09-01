import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  test(
    'GROUP_RELIABLE preserves end-to-end IDs and uses 16300-byte chunks',
    () {
      final chunks = chunkGroupReliable(
        groupId: GroupId(List.filled(16, 1)),
        source: PeerId(List.filled(16, 2)),
        destination: PeerId(List.filled(16, 3)),
        messageId: GroupMessageId(List.filled(16, 4)),
        mode: DeliveryMode.reliableAcked,
        priority: SendPriority.interactive,
        bytes: List.filled(16301, 9),
      );
      expect(chunks.length, 2);
      expect(chunks.first.encode().length, 84 + 16300);
      expect(
        GroupReliableChunk.decode(chunks.last.encode()).groupMessageId,
        chunks.last.groupMessageId,
      );
    },
  );
  test('GROUP_RELIABLE encodes zero bytes as one zero-length chunk', () {
    final chunks = chunkGroupReliable(
      groupId: GroupId(List.filled(16, 1)),
      source: PeerId(List.filled(16, 2)),
      destination: PeerId(List.filled(16, 3)),
      messageId: GroupMessageId(List.filled(16, 4)),
      mode: DeliveryMode.reliableOrdered,
      priority: SendPriority.normal,
      bytes: [],
    );
    expect(chunks.single.bytes, isEmpty);
    expect(chunks.single.chunkCount, 1);
  });

  test('UT-125 partial GROUP_RELIABLE has no admission-ready operation', () {
    final chunks = chunkGroupReliable(
      groupId: GroupId(List.filled(16, 1)),
      source: PeerId(List.filled(16, 2)),
      destination: PeerId(List.filled(16, 3)),
      messageId: GroupMessageId(List.filled(16, 4)),
      mode: DeliveryMode.reliableAcked,
      priority: SendPriority.interactive,
      bytes: List.filled(16301, 9),
    );
    final reassembler = GroupReliableReassembler(
      maxIncompleteMessages: 1,
      maxIncompleteBytes: 16301,
    );

    // Coordinator admission, and consequently the source-hop generic ACK,
    // operates only on the non-null complete result.
    expect(reassembler.add(List.filled(8, 5), chunks.first), isNull);
    expect(reassembler.incompleteMessages, 1);
    expect(reassembler.add(List.filled(8, 5), chunks.last), isNotNull);
  });

  test('UT-128 GROUP_RELIABLE reassembles one hop and discards it on loss', () {
    final chunks = chunkGroupReliable(
      groupId: GroupId(List.filled(16, 1)),
      source: PeerId(List.filled(16, 2)),
      destination: PeerId(List.filled(16, 3)),
      messageId: GroupMessageId(List.filled(16, 4)),
      mode: DeliveryMode.reliableAcked,
      priority: SendPriority.interactive,
      bytes: List.filled(16301, 9),
    );
    final reassembler = GroupReliableReassembler(
      maxIncompleteMessages: 1,
      maxIncompleteBytes: 16301,
    );

    expect(reassembler.add(List.filled(8, 5), chunks.first), isNull);
    reassembler.onTransportGenerationLost();
    expect(reassembler.add(List.filled(8, 5), chunks.last), isNull);
    final complete = reassembler.add(List.filled(8, 5), chunks.first);
    expect(complete!.bytes, List.filled(16301, 9));
    expect(complete.pairwiseMessageId, List.filled(8, 5));
    expect(complete.groupMessageId, GroupMessageId(List.filled(16, 4)));
  });

  test(
    'UT-153 incomplete stale former-coordinator GROUP_RELIABLE is discarded before reroute',
    () {
      final common = <String, Object>{
        'groupId': GroupId(List.filled(16, 1)),
        'source': PeerId(List.filled(16, 2)),
        'destination': PeerId(List.filled(16, 3)),
        'messageId': GroupMessageId(List.filled(16, 4)),
        'mode': DeliveryMode.reliableAcked,
        'priority': SendPriority.interactive,
      };
      final staleChunks = chunkGroupReliable(
        groupId: common['groupId']! as GroupId,
        source: common['source']! as PeerId,
        destination: common['destination']! as PeerId,
        messageId: common['messageId']! as GroupMessageId,
        mode: common['mode']! as DeliveryMode,
        priority: common['priority']! as SendPriority,
        bytes: List.filled(16301, 7),
      );
      final reroutedChunks = chunkGroupReliable(
        groupId: common['groupId']! as GroupId,
        source: common['source']! as PeerId,
        destination: common['destination']! as PeerId,
        messageId: common['messageId']! as GroupMessageId,
        mode: common['mode']! as DeliveryMode,
        priority: common['priority']! as SendPriority,
        bytes: List.filled(16301, 9),
      );
      final reassembler = GroupReliableReassembler(
        maxIncompleteMessages: 1,
        maxIncompleteBytes: 16301,
      );

      // This was received from the immediately previous coordinator. Once
      // migration commits it is stale, even though the end-to-end ID is reused
      // by the relay through the new coordinator.
      expect(reassembler.add(List.filled(8, 5), staleChunks.first), isNull);
      reassembler.discardIncompleteStaleAuthority();
      expect(reassembler.incompleteMessages, 0);

      expect(reassembler.add(List.filled(8, 5), reroutedChunks.last), isNull);
      final complete = reassembler.add(List.filled(8, 5), reroutedChunks.first);
      expect(complete!.bytes, List.filled(16301, 9));
    },
  );

  test(
    'GROUP_RELIABLE rejects a conflicting chunk on one pairwise MessageId',
    () {
      final source = PeerId(List.filled(16, 2));
      final chunk = GroupReliableChunk(
        groupId: GroupId(List.filled(16, 1)),
        sourcePeerId: source,
        destinationPeerId: PeerId(List.filled(16, 3)),
        groupMessageId: GroupMessageId(List.filled(16, 4)),
        deliveryMode: DeliveryMode.reliableOrdered,
        priority: SendPriority.normal,
        chunkIndex: 0,
        chunkCount: 2,
        totalLength: 16301,
        chunkOffset: 0,
        bytes: List.filled(16300, 1),
      );
      final conflicting = GroupReliableChunk(
        groupId: GroupId(List.filled(16, 1)),
        sourcePeerId: source,
        destinationPeerId: PeerId(List.filled(16, 3)),
        groupMessageId: GroupMessageId(List.filled(16, 9)),
        deliveryMode: DeliveryMode.reliableOrdered,
        priority: SendPriority.normal,
        chunkIndex: 1,
        chunkCount: 2,
        totalLength: 16301,
        chunkOffset: 16300,
        bytes: [2],
      );
      final reassembler = GroupReliableReassembler(
        maxIncompleteMessages: 1,
        maxIncompleteBytes: 16301,
      );
      reassembler.add(List.filled(8, 5), chunk);

      expect(
        () => reassembler.add(List.filled(8, 5), conflicting),
        throwsA(
          isA<LpcException>().having(
            (error) => error.code,
            'code',
            LpcErrorCode.messageIdCollision,
          ),
        ),
      );
    },
  );
}

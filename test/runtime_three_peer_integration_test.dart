import 'dart:async';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'RT-028 confirmed friends relay pairwise and GroupSession traffic over A-B-C',
    () async {
      final link = await _ThreePeerLink.create(mesh: true);
      final hosts = [
        link.a.createHostSession(HostConfig(autoAccept: true)),
        link.b.createHostSession(HostConfig(autoAccept: true)),
        link.c.createHostSession(HostConfig(autoAccept: true)),
      ];
      final aVirtual = Completer<PeerConnection>();
      final cVirtual = Completer<PeerConnection>();
      final aEvents = link.a.events.listen((event) {
        if (event is KnownPeerConnected &&
            event.connection.peerId == link.c.localPeerId &&
            event.connection.isRelayed &&
            !aVirtual.isCompleted) {
          aVirtual.complete(event.connection);
        }
      });
      final cEvents = link.c.events.listen((event) {
        if (event is KnownPeerConnected &&
            event.connection.peerId == link.a.localPeerId &&
            event.connection.isRelayed &&
            !cVirtual.isCompleted) {
          cVirtual.complete(event.connection);
        }
      });
      try {
        for (final host in hosts) {
          await host.startAdvertising();
        }
        await link.connect('a-b');
        await link.connect('b-c');
        final aToC = await aVirtual.future.timeout(const Duration(seconds: 12));
        final cToA = await cVirtual.future.timeout(const Duration(seconds: 12));
        expect(aToC.peerId, link.c.localPeerId);
        expect(cToA.peerId, link.a.localPeerId);
        expect(aToC.activeTransport, TransportType.meshRelay);
        expect(cToA.activeTransport, TransportType.meshRelay);
        final receivedAtC = cToA.messages.first;
        final receivedAtA = aToC.messages.first;
        const options = SendOptions(deliveryMode: DeliveryMode.reliableAcked);
        final forward = aToC.send(
          List<int>.filled(128, 0x41),
          options: options,
        );
        final reverse = cToA.send(
          List<int>.filled(128, 0x43),
          options: options,
        );
        expect(
          (await receivedAtC.timeout(const Duration(seconds: 5))).bytes,
          List<int>.filled(128, 0x41),
        );
        expect(
          (await receivedAtA.timeout(const Duration(seconds: 5))).bytes,
          List<int>.filled(128, 0x43),
        );
        expect(
          await forward.completed.timeout(const Duration(seconds: 5)),
          SendState.remoteAcknowledged,
        );
        expect(
          await reverse.completed.timeout(const Duration(seconds: 5)),
          SendState.remoteAcknowledged,
        );
        final largeReceived = cToA.messages.first;
        final largeSend = aToC.send(
          List<int>.generate(8192, (index) => index & 0xff),
          options: options,
        );
        expect(
          (await largeReceived.timeout(const Duration(seconds: 8))).bytes,
          List<int>.generate(8192, (index) => index & 0xff),
        );
        expect(
          await largeSend.completed.timeout(const Duration(seconds: 8)),
          SendState.remoteAcknowledged,
        );

        // LPGE's GroupSession traffic must work without an A-C GATT link:
        // the coordinator-star protocol sees one end-to-end logical peer,
        // while the transport beneath that peer is the friend relay.
        final groupA = link.a.joinOrCreateGroup(
          _groupConfig(checkpointing: true),
        );
        final groupC = link.c.joinOrCreateGroup(
          _groupConfig(checkpointing: true),
        );
        await _waitFor(
          () => _sameCommittedGroup([groupA, groupC], memberCount: 2),
          timeout: const Duration(seconds: 6),
        );
        final groupReceived = groupC.events
            .where((event) => event is ReliableMessageReceived)
            .cast<ReliableMessageReceived>()
            .first;
        final groupSend = groupA.send(link.c.localPeerId, [
          0x31,
          0x32,
          0x33,
        ], options: options);
        expect(
          (await groupReceived.timeout(const Duration(seconds: 5))).bytes,
          [0x31, 0x32, 0x33],
        );
        expect(
          await groupSend.completed.timeout(const Duration(seconds: 5)),
          SendState.remoteAcknowledged,
        );

        // Checkpoint protocol frames must use the same relay-backed logical
        // coordinator-member PeerConnection as ordinary GroupSession traffic.
        // Use a multi-chunk value so this also exercises checkpoint chunking
        // inside the mesh frame transport. The receiver's application
        // validation ACK, not merely transport submission, makes it durable.
        final groupCoordinator = [
          groupA,
          groupC,
        ].singleWhere((group) => group.isCoordinator);
        final groupReceiver = identical(groupCoordinator, groupA)
            ? groupC
            : groupA;
        groupA.setCoordinatorCheckpointValidator((bytes) => bytes.isNotEmpty);
        groupC.setCoordinatorCheckpointValidator((bytes) => bytes.isNotEmpty);
        final checkpointBytes = List<int>.generate(
          8192,
          (index) => (index * 17) & 0xff,
        );
        final checkpointUpdated = groupReceiver.events
            .where((event) => event is CoordinatorCheckpointUpdated)
            .cast<CoordinatorCheckpointUpdated>()
            .first;
        final checkpoint = groupCoordinator.publishCoordinatorCheckpoint(
          checkpointBytes,
          options: CheckpointPublishOptions(
            applicationValidationRequirement:
                CheckpointApplicationValidationRequirement.required,
          ),
        );
        final committedCheckpoint = await checkpointUpdated.timeout(
          const Duration(seconds: 8),
        );
        expect(committedCheckpoint.bytes, checkpointBytes);
        final checkpointResult = await checkpoint.completion.timeout(
          const Duration(seconds: 8),
        );
        expect(checkpointResult.status, CheckpointPublicationStatus.durable);
        expect(checkpointResult.requiredPeerIds, {groupReceiver.localPeerId});
        expect(
          checkpointResult.perPeerResults[groupReceiver.localPeerId],
          CheckpointPeerResult.acknowledged,
        );
        groupA.close();
        groupC.close();

        // When a physical path becomes available, the authenticated direct
        // link wins and the old virtual owner must not leave a second online
        // PeerConnection or tear down either healthy GATT hop.
        final cDirectFuture = hosts[2].events
            .where(
              (event) =>
                  event is HostPeerConnected &&
                  event.connection.peerId == link.a.localPeerId,
            )
            .cast<HostPeerConnected>()
            .first;
        final direct = await link.connect('a-c');
        final cDirect = (await cDirectFuture.timeout(
          const Duration(seconds: 4),
        )).connection;
        expect(direct.activeTransport, TransportType.gatt);
        await _waitFor(
          () => aToC.state == PeerConnectionState.disconnected,
          timeout: const Duration(seconds: 4),
        );
        final directReceive = cDirect.messages.first;
        final directSend = direct.send([9, 8, 7], options: options);
        expect(
          (await directReceive.timeout(const Duration(seconds: 3))).bytes,
          [9, 8, 7],
        );
        expect(
          await directSend.completed.timeout(const Duration(seconds: 3)),
          SendState.remoteAcknowledged,
        );
      } finally {
        await aEvents.cancel();
        await cEvents.cancel();
        for (final host in hosts) {
          await host.close();
        }
        await link.close();
      }
    },
  );

  test('RT-029 unconfirmed A-C cannot form a relayed connection', () async {
    final link = await _ThreePeerLink.create(mesh: true);
    link.blockFriendPair('a-c');
    final hosts = [
      link.a.createHostSession(HostConfig(autoAccept: true)),
      link.b.createHostSession(HostConfig(autoAccept: true)),
      link.c.createHostSession(HostConfig(autoAccept: true)),
    ];
    final relayed = <KnownPeerConnected>[];
    final aEvents = link.a.events.listen((event) {
      if (event is KnownPeerConnected && event.connection.isRelayed) {
        relayed.add(event);
      }
    });
    final cEvents = link.c.events.listen((event) {
      if (event is KnownPeerConnected && event.connection.isRelayed) {
        relayed.add(event);
      }
    });
    try {
      for (final host in hosts) {
        await host.startAdvertising();
      }
      await link.connect('a-b');
      await link.connect('b-c');
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(relayed, isEmpty);
    } finally {
      await aEvents.cancel();
      await cEvents.cancel();
      for (final host in hosts) {
        await host.close();
      }
      await link.close();
    }
  });

  test(
    'RT-030 relay loss removes virtual readiness and direct A-C recovers',
    () async {
      final link = await _ThreePeerLink.create(mesh: true);
      final hosts = [
        link.a.createHostSession(HostConfig(autoAccept: true)),
        link.b.createHostSession(HostConfig(autoAccept: true)),
        link.c.createHostSession(HostConfig(autoAccept: true)),
      ];
      final aVirtual = link.a.events
          .where(
            (event) =>
                event is KnownPeerConnected &&
                event.connection.peerId == link.c.localPeerId &&
                event.connection.isRelayed,
          )
          .cast<KnownPeerConnected>()
          .first;
      final cVirtual = link.c.events
          .where(
            (event) =>
                event is KnownPeerConnected &&
                event.connection.peerId == link.a.localPeerId &&
                event.connection.isRelayed,
          )
          .cast<KnownPeerConnected>()
          .first;
      try {
        for (final host in hosts) {
          await host.startAdvertising();
        }
        await link.connect('a-b');
        await link.connect('b-c');
        final aToC = (await aVirtual.timeout(
          const Duration(seconds: 12),
        )).connection;
        final cToA = (await cVirtual.timeout(
          const Duration(seconds: 12),
        )).connection;
        link.dropNode(1);
        await _waitFor(
          () =>
              aToC.state == PeerConnectionState.disconnected &&
              cToA.state == PeerConnectionState.disconnected,
          timeout: const Duration(seconds: 5),
        );
        final cDirectFuture = hosts[2].events
            .where(
              (event) =>
                  event is HostPeerConnected &&
                  event.connection.peerId == link.a.localPeerId,
            )
            .cast<HostPeerConnected>()
            .first;
        final direct = await link.connect('a-c');
        final cDirect = (await cDirectFuture.timeout(
          const Duration(seconds: 4),
        )).connection;
        expect(direct.isRelayed, isFalse);
        final received = cDirect.messages.first;
        final sent = direct.send(
          [6, 2, 9],
          options: const SendOptions(deliveryMode: DeliveryMode.reliableAcked),
        );
        expect((await received.timeout(const Duration(seconds: 3))).bytes, [
          6,
          2,
          9,
        ]);
        expect(
          await sent.completed.timeout(const Duration(seconds: 3)),
          SendState.remoteAcknowledged,
        );
      } finally {
        for (final host in hosts) {
          await host.close();
        }
        await link.close();
      }
    },
  );

  test('RT-031 endpoint restart recovers the virtual A-C session', () async {
    final link = await _ThreePeerLink.create(mesh: true);
    final hosts = [
      link.a.createHostSession(HostConfig(autoAccept: true)),
      link.b.createHostSession(HostConfig(autoAccept: true)),
      link.c.createHostSession(HostConfig(autoAccept: true)),
    ];
    HostSession? restartedHost;
    Future<PeerConnection> nextVirtual(NearbyRuntime runtime, PeerId target) =>
        runtime.events
            .where(
              (event) =>
                  event is KnownPeerConnected &&
                  event.connection.peerId == target &&
                  event.connection.isRelayed,
            )
            .cast<KnownPeerConnected>()
            .map((event) => event.connection)
            .first;
    try {
      for (final host in hosts) {
        await host.startAdvertising();
      }
      final firstA = nextVirtual(link.a, link.c.localPeerId);
      final firstC = nextVirtual(link.c, link.a.localPeerId);
      await link.connect('a-b');
      await link.connect('b-c');
      final priorA = await firstA.timeout(const Duration(seconds: 12));
      final priorC = await firstC.timeout(const Duration(seconds: 12));
      final oldSession = priorC.sessionId;
      final nextC = nextVirtual(link.c, link.a.localPeerId);
      await link.restartNode(0);
      restartedHost = link.a.createHostSession(HostConfig(autoAccept: true));
      await restartedHost.startAdvertising();
      final nextA = nextVirtual(link.a, link.c.localPeerId);
      await link.connect('a-b');
      final aToC = await nextA.timeout(const Duration(seconds: 12));
      final cToA = await nextC.timeout(const Duration(seconds: 12));
      expect(cToA.sessionId, isNot(oldSession));
      expect(aToC.isRelayed, isTrue);
      expect(cToA.isRelayed, isTrue);
      final received = cToA.messages.first;
      final sent = aToC.send([
        4,
        5,
        6,
      ], options: const SendOptions(deliveryMode: DeliveryMode.reliableAcked));
      expect((await received.timeout(const Duration(seconds: 5))).bytes, [
        4,
        5,
        6,
      ]);
      expect(
        await sent.completed.timeout(const Duration(seconds: 5)),
        SendState.remoteAcknowledged,
      );
      expect(priorA.state, PeerConnectionState.disconnected);
    } finally {
      await restartedHost?.close();
      for (final host in hosts) {
        await host.close();
      }
      await link.close();
    }
  });

  test(
    'RT-033 restarting relay destination restores virtual A-C traffic',
    () async {
      final link = await _ThreePeerLink.create(mesh: true);
      final hosts = [
        link.a.createHostSession(HostConfig(autoAccept: true)),
        link.b.createHostSession(HostConfig(autoAccept: true)),
        link.c.createHostSession(HostConfig(autoAccept: true)),
      ];
      HostSession? restartedHost;
      Future<PeerConnection> nextVirtual(
        NearbyRuntime runtime,
        PeerId target,
      ) => runtime.events
          .where(
            (event) =>
                event is KnownPeerConnected &&
                event.connection.peerId == target &&
                event.connection.isRelayed,
          )
          .cast<KnownPeerConnected>()
          .map((event) => event.connection)
          .first;
      Future<PeerConnection> nextDirect(NearbyRuntime runtime, PeerId target) =>
          runtime.events
              .where(
                (event) =>
                    event is KnownPeerConnected &&
                    event.connection.peerId == target &&
                    !event.connection.isRelayed,
              )
              .cast<KnownPeerConnected>()
              .map((event) => event.connection)
              .first;
      try {
        for (final host in hosts) {
          await host.startAdvertising();
        }
        final firstA = nextVirtual(link.a, link.c.localPeerId);
        final firstC = nextVirtual(link.c, link.a.localPeerId);
        await link.connect('a-b').timeout(const Duration(seconds: 8));
        await link.connect('b-c').timeout(const Duration(seconds: 8));
        final priorA = await firstA.timeout(const Duration(seconds: 12));
        final priorC = await firstC.timeout(const Duration(seconds: 12));
        final oldSession = priorC.sessionId;

        // C is the destination endpoint in the A-B-C route. Restarting it
        // destroys its virtual session while A and the relay B retain theirs;
        // route recovery must replace both stale virtual sessions with a fresh
        // authenticated handshake and preserve ordinary reliable delivery.
        print('[RT-033] initial relay ready; restarting C');
        final nextA = nextVirtual(link.a, link.c.localPeerId);
        // Let B's normal LPC reconnect owner recreate B-C. Starting a second
        // explicit `connect` here races that automatic attempt and tests the
        // fixture's duplicate-candidate arbitration instead of app restart.
        final nextBDirect = nextDirect(link.b, link.c.localPeerId);
        await link.restartNode(2).timeout(const Duration(seconds: 8));
        restartedHost = link.c.createHostSession(HostConfig(autoAccept: true));
        await restartedHost.startAdvertising().timeout(
          const Duration(seconds: 8),
        );
        final nextC = nextVirtual(link.c, link.a.localPeerId);
        print('[RT-033] C runtime restarted; waiting for LPC reconnect B-C');
        await nextBDirect.timeout(const Duration(seconds: 12));

        final aToC = await nextA.timeout(const Duration(seconds: 12));
        final cToA = await nextC.timeout(const Duration(seconds: 12));
        print('[RT-033] virtual handshake restored');
        expect(cToA.sessionId, isNot(oldSession));
        expect(aToC.isRelayed, isTrue);
        expect(cToA.isRelayed, isTrue);

        final receivedAtC = cToA.messages.first;
        final sentFromA = aToC.send(
          [7, 3, 1],
          options: const SendOptions(deliveryMode: DeliveryMode.reliableAcked),
        );
        expect((await receivedAtC.timeout(const Duration(seconds: 5))).bytes, [
          7,
          3,
          1,
        ]);
        expect(
          await sentFromA.completed.timeout(const Duration(seconds: 5)),
          SendState.remoteAcknowledged,
        );

        final receivedAtA = aToC.messages.first;
        final sentFromC = cToA.send(
          [2, 4, 6],
          options: const SendOptions(deliveryMode: DeliveryMode.reliableAcked),
        );
        expect((await receivedAtA.timeout(const Duration(seconds: 5))).bytes, [
          2,
          4,
          6,
        ]);
        expect(
          await sentFromC.completed.timeout(const Duration(seconds: 5)),
          SendState.remoteAcknowledged,
        );
        print('[RT-033] bidirectional reliable delivery restored');
        expect(priorA.state, PeerConnectionState.disconnected);
        expect(priorC.state, PeerConnectionState.disconnected);
      } finally {
        await restartedHost?.close();
        for (final host in hosts) {
          await host.close();
        }
        await link.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'RT-034 restarted group member rejoins over relay and receives durable checkpoint',
    () async {
      final link = await _ThreePeerLink.create(mesh: true);
      await link.a.setDirectPeerBlockedForTesting(
        link.c.localPeerId,
        blocked: true,
      );
      await link.c.setDirectPeerBlockedForTesting(
        link.a.localPeerId,
        blocked: true,
      );
      final hosts = [
        link.a.createHostSession(HostConfig(autoAccept: true)),
        link.b.createHostSession(HostConfig(autoAccept: true)),
        link.c.createHostSession(HostConfig(autoAccept: true)),
      ];
      HostSession? restartedHost;
      try {
        for (final host in hosts) {
          await host.startAdvertising();
        }
        await link.connect('a-b').timeout(const Duration(seconds: 8));
        await link.connect('b-c').timeout(const Duration(seconds: 8));

        final groupA = link.a.joinOrCreateGroup(
          _groupConfig(checkpointing: true),
          groupId: GroupId(List<int>.filled(16, 1)),
        );
        final groupB = link.b.joinOrCreateGroup(
          _groupConfig(checkpointing: true),
          groupId: GroupId(List<int>.filled(16, 2)),
        );
        await _waitFor(
          () => _sameCommittedGroup([groupA, groupB], memberCount: 2),
          timeout: const Duration(seconds: 6),
        );
        final groupC = link.c.joinOrCreateGroup(
          _groupConfig(checkpointing: true),
        );
        await _waitFor(
          () => _sameCommittedGroup([groupA, groupB, groupC], memberCount: 3),
          timeout: const Duration(seconds: 8),
        );
        expect(groupA.isCoordinator, isTrue);

        // Recreate C's GroupSession after a full LPC runtime restart, matching
        // the durable GroupId/coordinator information an app restores from
        // its game state. A's group remains coordinator and A-C has no direct
        // GATT path, so both rejoin and state recovery must traverse B.
        final groupId = groupA.groupId;
        final coordinatorId = groupA.coordinatorPeerId!;
        final nextDirectAtB = link.b.events
            .where(
              (event) =>
                  event is KnownPeerConnected &&
                  event.connection.peerId == link.c.localPeerId &&
                  !event.connection.isRelayed,
            )
            .cast<KnownPeerConnected>()
            .first;
        await link.restartNode(2).timeout(const Duration(seconds: 8));
        final nextVirtualAtC = link.c.events
            .where(
              (event) =>
                  event is KnownPeerConnected &&
                  event.connection.peerId == link.a.localPeerId &&
                  event.connection.isRelayed,
            )
            .cast<KnownPeerConnected>()
            .first;
        restartedHost = link.c.createHostSession(HostConfig(autoAccept: true));
        await restartedHost.startAdvertising().timeout(
          const Duration(seconds: 8),
        );
        await nextDirectAtB.timeout(const Duration(seconds: 12));
        final virtualAtC = await nextVirtualAtC.timeout(
          const Duration(seconds: 12),
        );
        expect(virtualAtC.connection.activeTransport, TransportType.meshRelay);

        final rejoinedC = link.c.joinOrCreateGroup(
          _groupConfig(checkpointing: true),
          groupId: groupId,
          initialCoordinator: coordinatorId,
        );
        await _waitFor(
          () =>
              _sameCommittedGroup([groupA, groupB, rejoinedC], memberCount: 3),
          timeout: const Duration(seconds: 10),
        );

        final receivedAtB = groupB.events
            .where((event) => event is ReliableMessageReceived)
            .cast<ReliableMessageReceived>()
            .first;
        final send = rejoinedC.send(
          link.b.localPeerId,
          [0x52, 0x45, 0x4c, 0x41, 0x59],
          options: const SendOptions(deliveryMode: DeliveryMode.reliableAcked),
        );
        expect((await receivedAtB.timeout(const Duration(seconds: 6))).bytes, [
          0x52,
          0x45,
          0x4c,
          0x41,
          0x59,
        ]);
        expect(
          await send.completed.timeout(const Duration(seconds: 6)),
          SendState.remoteAcknowledged,
        );

        groupB.setCoordinatorCheckpointValidator((bytes) => bytes.isNotEmpty);
        rejoinedC.setCoordinatorCheckpointValidator(
          (bytes) => bytes.isNotEmpty,
        );
        final checkpointBytes = List<int>.generate(
          6144,
          (index) => (index * 29) & 0xff,
        );
        final checkpointAtC = rejoinedC.events
            .where((event) => event is CoordinatorCheckpointUpdated)
            .cast<CoordinatorCheckpointUpdated>()
            .first;
        final publication = groupA.publishCoordinatorCheckpoint(
          checkpointBytes,
          options: CheckpointPublishOptions(
            applicationValidationRequirement:
                CheckpointApplicationValidationRequirement.required,
          ),
        );
        expect(
          (await checkpointAtC.timeout(const Duration(seconds: 8))).bytes,
          checkpointBytes,
        );
        final result = await publication.completion.timeout(
          const Duration(seconds: 8),
        );
        expect(result.status, CheckpointPublicationStatus.durable);
        expect(result.requiredPeerIds, {
          link.b.localPeerId,
          link.c.localPeerId,
        });
        expect(
          result.perPeerResults[link.c.localPeerId],
          CheckpointPeerResult.acknowledged,
        );
      } finally {
        await restartedHost?.close();
        for (final host in hosts) {
          await host.close();
        }
        await link.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'RT-035 failed virtual generation re-handshakes over a READY relay',
    () async {
      final link = await _ThreePeerLink.create(mesh: true);
      await link.a.setDirectPeerBlockedForTesting(
        link.c.localPeerId,
        blocked: true,
      );
      await link.c.setDirectPeerBlockedForTesting(
        link.a.localPeerId,
        blocked: true,
      );
      final hosts = [
        link.a.createHostSession(HostConfig(autoAccept: true)),
        link.b.createHostSession(HostConfig(autoAccept: true)),
        link.c.createHostSession(HostConfig(autoAccept: true)),
      ];
      final publishedAtA = <PeerConnection>[];
      final publishedAtC = <PeerConnection>[];
      final aEvents = link.a.events.listen((event) {
        if (event is KnownPeerConnected &&
            event.connection.peerId == link.c.localPeerId &&
            event.connection.isRelayed) {
          publishedAtA.add(event.connection);
        }
      });
      final cEvents = link.c.events.listen((event) {
        if (event is KnownPeerConnected &&
            event.connection.peerId == link.a.localPeerId &&
            event.connection.isRelayed) {
          publishedAtC.add(event.connection);
        }
      });
      try {
        for (final host in hosts) {
          await host.startAdvertising();
        }
        final firstA = link.a.events
            .where(
              (event) =>
                  event is KnownPeerConnected &&
                  event.connection.peerId == link.c.localPeerId &&
                  event.connection.isRelayed,
            )
            .cast<KnownPeerConnected>()
            .first;
        final firstC = link.c.events
            .where(
              (event) =>
                  event is KnownPeerConnected &&
                  event.connection.peerId == link.a.localPeerId &&
                  event.connection.isRelayed,
            )
            .cast<KnownPeerConnected>()
            .first;
        await link.connect('a-b').timeout(const Duration(seconds: 8));
        await link.connect('b-c').timeout(const Duration(seconds: 8));
        final priorA = (await firstA.timeout(
          const Duration(seconds: 12),
        )).connection;
        final priorC = (await firstC.timeout(
          const Duration(seconds: 12),
        )).connection;
        final oldSessionId = priorA.sessionId;
        expect(priorC.sessionId, oldSessionId);
        expect(priorA.relayPeerId, link.b.localPeerId);
        expect(priorC.relayPeerId, link.b.localPeerId);

        final recoveredA = link.a.events
            .where(
              (event) =>
                  event is KnownPeerConnected &&
                  event.connection.peerId == link.c.localPeerId &&
                  event.connection.isRelayed,
            )
            .cast<KnownPeerConnected>()
            .first;
        final recoveredC = link.c.events
            .where(
              (event) =>
                  event is KnownPeerConnected &&
                  event.connection.peerId == link.a.localPeerId &&
                  event.connection.isRelayed,
            )
            .cast<KnownPeerConnected>()
            .first;
        await link.a.simulateRelayedTransportFailureForTesting(
          link.c.localPeerId,
        );

        final nextA = (await recoveredA.timeout(
          const Duration(seconds: 12),
        )).connection;
        final nextC = (await recoveredC.timeout(
          const Duration(seconds: 12),
        )).connection;
        expect(priorA.state, PeerConnectionState.disconnected);
        expect(priorC.state, PeerConnectionState.disconnected);
        expect(nextA.state, PeerConnectionState.ready);
        expect(nextC.state, PeerConnectionState.ready);
        expect(nextA.sessionId, isNot(oldSessionId));
        expect(nextC.sessionId, nextA.sessionId);
        expect(nextA.relayPeerId, link.b.localPeerId);
        expect(nextC.relayPeerId, link.b.localPeerId);
        expect(
          publishedAtA.where((peer) => peer.state == PeerConnectionState.ready),
          hasLength(1),
        );
        expect(
          publishedAtC.where((peer) => peer.state == PeerConnectionState.ready),
          hasLength(1),
        );

        final received = nextC.messages.first;
        final send = nextA.send(
          [0x4d, 0x45, 0x53, 0x48],
          options: const SendOptions(deliveryMode: DeliveryMode.reliableAcked),
        );
        expect((await received.timeout(const Duration(seconds: 5))).bytes, [
          0x4d,
          0x45,
          0x53,
          0x48,
        ]);
        expect(
          await send.completed.timeout(const Duration(seconds: 5)),
          SendState.remoteAcknowledged,
        );
      } finally {
        await aEvents.cancel();
        await cEvents.cancel();
        for (final host in hosts) {
          await host.close();
        }
        await link.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test('RT-032 blocking only physical A-C switches to friend relay', () async {
    final link = await _ThreePeerLink.create(mesh: true);
    final hosts = [
      link.a.createHostSession(HostConfig(autoAccept: true)),
      link.b.createHostSession(HostConfig(autoAccept: true)),
      link.c.createHostSession(HostConfig(autoAccept: true)),
    ];
    try {
      for (final host in hosts) {
        await host.startAdvertising();
      }
      final aToB = await link.connect('a-b');
      final bToC = await link.connect('b-c');
      final originalDirect = await link.connect('a-c');
      final aVirtual = link.a.events
          .where(
            (event) =>
                event is KnownPeerConnected &&
                event.connection.peerId == link.c.localPeerId &&
                event.connection.isRelayed,
          )
          .cast<KnownPeerConnected>()
          .first;
      final cVirtual = link.c.events
          .where(
            (event) =>
                event is KnownPeerConnected &&
                event.connection.peerId == link.a.localPeerId &&
                event.connection.isRelayed,
          )
          .cast<KnownPeerConnected>()
          .first;
      await link.a.setDirectPeerBlockedForTesting(
        link.c.localPeerId,
        blocked: true,
      );
      await link.c.setDirectPeerBlockedForTesting(
        link.a.localPeerId,
        blocked: true,
      );
      final relayedA = (await aVirtual.timeout(
        const Duration(seconds: 12),
      )).connection;
      final relayedC = (await cVirtual.timeout(
        const Duration(seconds: 12),
      )).connection;
      expect(relayedA.relayPeerId, link.b.localPeerId);
      expect(relayedC.relayPeerId, link.b.localPeerId);
      expect(aToB.state, PeerConnectionState.ready);
      expect(bToC.state, PeerConnectionState.ready);
      expect(originalDirect.state, PeerConnectionState.disconnected);
      await link.a.setDirectPeerBlockedForTesting(
        link.c.localPeerId,
        blocked: false,
      );
      await link.c.setDirectPeerBlockedForTesting(
        link.a.localPeerId,
        blocked: false,
      );
      final recovered = await link.connect('a-c');
      expect(recovered.isRelayed, isFalse);
      await _waitFor(
        () => relayedA.state == PeerConnectionState.disconnected,
        timeout: const Duration(seconds: 4),
      );
      expect(aToB.state, PeerConnectionState.ready);
      expect(bToC.state, PeerConnectionState.ready);
    } finally {
      for (final host in hosts) {
        await host.close();
      }
      await link.close();
    }
  });

  test(
    'IT-039 three runtimes merge, route reliable traffic, and migrate the group view',
    () async {
      final link = await _ThreePeerLink.create();
      final hosts = [
        link.a.createHostSession(HostConfig(autoAccept: true)),
        link.b.createHostSession(HostConfig(autoAccept: true)),
        link.c.createHostSession(HostConfig(autoAccept: true)),
      ];
      final discoveries = <DiscoverySession>[];
      try {
        for (final host in hosts) {
          await host.startAdvertising();
        }
        for (final runtime in link.runtimes) {
          discoveries.add(await runtime.startDiscovery());
        }

        // Establish all three pairwise authenticated links. Group routing may
        // later use only the elected coordinator star, but a full mesh lets the
        // remaining peers continue after the coordinator's two links fail.
        await link.connect('a-b');
        await link.connect('a-c');
        await link.connect('b-c');

        // Stage group creation so this integration test exercises transport
        // convergence and later migration independently of the already-covered
        // simultaneous-election unit test. The established two-member group
        // must remain the merge winner when the third singleton joins.
        final groupA = link.a.joinOrCreateGroup(
          _groupConfig(checkpointing: true),
        );
        final groupB = link.b.joinOrCreateGroup(
          _groupConfig(checkpointing: true),
        );
        await _waitFor(
          () => _sameCommittedGroup([groupA, groupB], memberCount: 2),
          timeout: const Duration(seconds: 5),
        );
        final groupC = link.c.joinOrCreateGroup(
          _groupConfig(checkpointing: true),
        );
        final groups = [groupA, groupB, groupC];
        try {
          await _waitFor(
            () => _sameCommittedGroup(groups, memberCount: 3),
            timeout: const Duration(seconds: 5),
          );
        } catch (_) {
          // Keep the failure actionable: group merge failures are otherwise
          // invisible because GROUP_INFO/GROUP_MERGE are internal frames.
          print(
            'three-peer group states: ${groups.map(_describeGroup).join('; ')}',
          );
          rethrow;
        }
        final originalGroupId = groups[0].groupId;
        final originalCoordinator = groups[0].coordinatorPeerId;
        expect(groups.expand((group) => group.members).length, 9);

        // Regression coverage for the runtime frame demultiplexer: checkpoint
        // frames must reach every non-coordinator GroupSession so the
        // application validator can ACK the publication. A missing
        // coordinatorCheckpoint case leaves the publication pending forever
        // while ordinary group traffic still appears healthy.
        for (final group in groups.where((group) => !group.isCoordinator)) {
          group.setCoordinatorCheckpointValidator((bytes) => bytes.isNotEmpty);
        }
        final checkpointCoordinator = groups.firstWhere(
          (group) => group.isCoordinator,
        );
        final checkpoint = checkpointCoordinator.publishCoordinatorCheckpoint(
          [1, 2, 3],
          options: CheckpointPublishOptions(
            applicationValidationRequirement:
                CheckpointApplicationValidationRequirement.required,
          ),
        );
        expect(
          (await checkpoint.completion.timeout(
            const Duration(seconds: 3),
          )).status,
          CheckpointPublicationStatus.durable,
        );

        final receivedByTarget = Completer<ReliableMessageReceived>();
        final targetBeforeFailure = groups[1];
        final sourceBeforeFailure = groups[0];
        final cSubscription = targetBeforeFailure.events.listen((event) {
          if (event is ReliableMessageReceived &&
              !receivedByTarget.isCompleted) {
            receivedByTarget.complete(event);
          }
        });
        const reliable = SendOptions(deliveryMode: DeliveryMode.reliableAcked);
        final beforeFailure = sourceBeforeFailure.send(
          targetBeforeFailure.localPeerId,
          [7, 8, 9],
          options: reliable,
        );
        expect(
          await receivedByTarget.future.timeout(const Duration(seconds: 3)),
          isA<ReliableMessageReceived>(),
        );
        expect(await beforeFailure.completed, SendState.remoteAcknowledged);

        // Take the elected coordinator offline while retaining the authenticated
        // survivor-to-survivor link. The election result is injected below so
        // this test remains scoped to the runtime/group transport boundary.
        final coordinatorIndex = link.runtimes.indexWhere(
          (runtime) => runtime.localPeerId == originalCoordinator,
        );
        expect(coordinatorIndex, greaterThanOrEqualTo(0));
        link.dropNode(coordinatorIndex);
        final survivorIndices = [
          0,
          1,
          2,
        ].where((index) => index != coordinatorIndex).toList(growable: false);
        final survivorSource = groups[survivorIndices[0]];
        final survivorTarget = groups[survivorIndices[1]];
        final survivorMembers = groups[0].members
            .where((member) => member.peerId != originalCoordinator)
            .toList(growable: false);
        final replacement = survivorMembers
            .map((member) => member.peerId)
            .reduce(
              (left, right) => _comparePeerIds(left, right) >= 0 ? left : right,
            );
        final migrationTerm =
            groups.map((group) => group.coordinatorTerm).reduce(max) + 1;
        // Election frame exchange is covered by the protocol-level election
        // tests. Here we inject its deterministic result into both live group
        // owners after the real GATT loss, then exercise the surviving route.
        // Keeping this boundary explicit prevents the harness from pretending
        // that a direct local commit is the full wire-election implementation.
        for (final index in survivorIndices) {
          groups[index].commitMembership(
            survivorMembers,
            coordinator: replacement,
            coordinatorTerm: migrationTerm,
          );
        }
        await _waitFor(
          () =>
              survivorSource.state == GroupState.ready &&
              survivorTarget.state == GroupState.ready &&
              survivorSource.groupId == originalGroupId &&
              survivorTarget.groupId == originalGroupId &&
              survivorSource.members.length == 2 &&
              survivorTarget.members.length == 2 &&
              survivorSource.coordinatorPeerId ==
                  survivorTarget.coordinatorPeerId &&
              survivorSource.coordinatorPeerId != originalCoordinator &&
              survivorIndices.any(
                (index) =>
                    groups[index].localPeerId ==
                    survivorSource.coordinatorPeerId,
              ),
          timeout: const Duration(seconds: 8),
        );

        final receivedAfterMigration = Completer<ReliableMessageReceived>();
        final afterSubscription = survivorTarget.events.listen((event) {
          if (event is ReliableMessageReceived &&
              !receivedAfterMigration.isCompleted) {
            receivedAfterMigration.complete(event);
          }
        });
        final afterFailure = survivorSource.send(survivorTarget.localPeerId, [
          10,
          11,
          12,
        ], options: reliable);
        final migratedMessage = await receivedAfterMigration.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () =>
              throw StateError('group delivery stopped after migration'),
        );
        expect(migratedMessage.sourcePeerId, survivorSource.localPeerId);
        expect(await afterFailure.completed, SendState.remoteAcknowledged);

        await afterSubscription.cancel();
        await cSubscription.cancel();
        for (final group in groups) {
          group.close();
        }
      } finally {
        for (final discovery in discoveries) {
          await discovery.stop();
        }
        for (final host in hosts) {
          await host.close();
        }
        await link.close();
      }
    },
  );
}

int _comparePeerIds(PeerId left, PeerId right) {
  for (var index = 0; index < left.bytes.length; index++) {
    final comparison = left.bytes[index].compareTo(right.bytes[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

bool _sameCommittedGroup(
  List<GroupSession> groups, {
  required int memberCount,
}) {
  if (groups.any(
    (group) =>
        group.state != GroupState.ready ||
        group.members.length != memberCount ||
        group.coordinatorPeerId == null,
  )) {
    return false;
  }
  final id = groups.first.groupId;
  final coordinator = groups.first.coordinatorPeerId;
  return groups.every(
    (group) => group.groupId == id && group.coordinatorPeerId == coordinator,
  );
}

GroupConfig _groupConfig({bool checkpointing = false}) => GroupConfig(
  applicationNamespace: const [1, 2, 3],
  groupJoinToken: List<int>.filled(16, 4),
  groupTrustMode: GroupTrustMode.openTofu,
  maxPeers: 3,
  autoAccept: true,
  autoMerge: true,
  coordinatorCheckpointing: checkpointing,
);

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

class _ThreePeerLink {
  _ThreePeerLink._();

  final _methods = [
    const MethodChannel('three-peer-a'),
    const MethodChannel('three-peer-b'),
    const MethodChannel('three-peer-c'),
  ];
  final _events = [
    StreamController<PlatformBleEvent>.broadcast(),
    StreamController<PlatformBleEvent>.broadcast(),
    StreamController<PlatformBleEvent>.broadcast(),
  ];
  final _disabledPairs = <String>{};
  final _disabledNodes = <int>{};
  final _unfriendedPairs = <String>{};
  late NearbyRuntime a;
  late NearbyRuntime b;
  late NearbyRuntime c;
  late final List<NearbyRuntime> runtimes;
  bool _meshEnabled = false;
  int _generation = 0;
  final Map<String, int> _pairGenerations = {};
  final Map<String, Set<int>> _closedPairGenerations = {};

  static Future<_ThreePeerLink> create({bool mesh = false}) async {
    final link = _ThreePeerLink._();
    link._meshEnabled = mesh;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (var index = 0; index < link._methods.length; index++) {
      messenger.setMockMethodCallHandler(
        link._methods[index],
        (call) => link._handle(index, call),
      );
    }
    final created = <NearbyRuntime>[];
    for (var index = 0; index < 3; index++) {
      created.add(await link._newRuntime(index));
    }
    link.runtimes = created;
    link.a = created[0];
    link.b = created[1];
    link.c = created[2];
    return link;
  }

  Future<NearbyRuntime> _newRuntime(int index) async => createRuntime(
    config: RuntimeConfig(
      trustMode: HandshakeTrustMode.tofu,
      autoReconnect: true,
      autoConnectKnownPeers: _meshEnabled,
      knownPeerResolver: _meshEnabled ? _AllTestFriends(this, index) : null,
      reconnectTimeoutMs: 1500,
      logger: _testLog,
    ),
    identityStore: InMemoryIdentityStore(
      keyPair: await Ed25519().newKeyPairFromSeed(
        Uint8List.fromList(List<int>.filled(32, index + 1)),
      ),
    ),
    platformBleBackend: PlatformBleBackend(
      methods: _methods[index],
      eventStream: _events[index].stream,
    ),
  );

  Future<NearbyRuntime> restartNode(int index) async {
    await runtimes[index].close();
    final replacement = await _newRuntime(index);
    runtimes[index] = replacement;
    if (index == 0) a = replacement;
    if (index == 1) b = replacement;
    if (index == 2) c = replacement;
    return replacement;
  }

  void blockFriendPair(String pair) => _unfriendedPairs.add(pair);

  Future<PeerConnection> connect(String endpoint) async {
    final local = endpoint.codeUnitAt(0) - 97;
    final attempt = runtimes[local].connect(endpoint);
    final event = await attempt.events.firstWhere(
      (event) => event is ConnectionAttemptConnected,
    );
    return (event as ConnectionAttemptConnected).connection;
  }

  void dropPair(String endpoint) {
    final local = endpoint.codeUnitAt(0) - 97;
    final remote = endpoint.codeUnitAt(2) - 97;
    _events[local].add(PlatformGattDisconnected(endpoint));
    _events[remote].add(PlatformGattDisconnected(endpoint));
  }

  void dropNode(int index) {
    for (final pair in const ['a-b', 'a-c', 'b-c']) {
      if (pair.codeUnitAt(0) - 97 == index ||
          pair.codeUnitAt(2) - 97 == index) {
        // Emit the native disconnect before refusing future connects. This
        // models the platform disappearing, which must trigger LPC's normal
        // reconnect/migration path rather than only blocking new attempts.
        dropPair(pair);
        _disabledPairs.add(pair);
      }
    }
    _disabledNodes.add(index);
  }

  Future<Object?> _handle(int local, MethodCall call) async {
    final arguments = call.arguments is Map
        ? call.arguments as Map<Object?, Object?>
        : const <Object?, Object?>{};
    final endpoint = arguments['endpointId'] as String?;
    if (endpoint == null) return null;
    final first = endpoint.codeUnitAt(0) - 97;
    final second = endpoint.codeUnitAt(2) - 97;
    final remote = local == first ? second : first;
    if (_disabledNodes.contains(local) ||
        _disabledNodes.contains(remote) ||
        _disabledPairs.contains(endpoint)) {
      return null;
    }
    switch (call.method) {
      case 'connectGatt':
        final generation = ++_generation;
        _pairGenerations[endpoint] = generation;
        _events[local].add(
          PlatformGattConnected(
            endpoint,
            'central',
            connectionGeneration: generation,
          ),
        );
        _events[remote].add(
          PlatformGattConnected(
            endpoint,
            'peripheral',
            connectionGeneration: generation,
          ),
        );
        return null;
      case 'submitGattFragment':
        _events[remote].add(
          PlatformGattFragment(endpoint, arguments['fragment'] as Uint8List),
        );
        return 'submitted';
      case 'closeGattConnection':
        // The fake native link must preserve the physical generation on a
        // disconnect callback. An unscoped late close from the previous app
        // process can otherwise tear down the replacement GATT link and
        // create a reconnect loop that real generation-aware backends reject.
        final requestedGeneration = arguments['connectionGeneration'] as int?;
        final closedGeneration =
            requestedGeneration ?? _pairGenerations[endpoint];
        final alreadyClosed =
            closedGeneration != null &&
            !(_closedPairGenerations
                .putIfAbsent(endpoint, () => <int>{})
                .add(closedGeneration));
        if (alreadyClosed) return null;
        _events[remote].add(
          PlatformGattDisconnected(
            endpoint,
            connectionGeneration: closedGeneration,
          ),
        );
        if (_pairGenerations[endpoint] == closedGeneration) {
          _pairGenerations.remove(endpoint);
        }
        return null;
      default:
        return null;
    }
  }

  Future<void> close() async {
    for (final runtime in runtimes) {
      await runtime.close();
    }
    for (final events in _events) {
      await events.close();
    }
  }
}

class _AllTestFriends implements KnownPeerResolver {
  const _AllTestFriends(this.link, this.localIndex);
  final _ThreePeerLink link;
  final int localIndex;
  @override
  Future<bool> isKnownPeer(PeerId peerId) async {
    final remoteIndex = link.runtimes.indexWhere(
      (runtime) => runtime.localPeerId == peerId,
    );
    if (remoteIndex < 0) return false;
    final first = min(localIndex, remoteIndex);
    final second = max(localIndex, remoteIndex);
    final pair =
        '${String.fromCharCode(97 + first)}-${String.fromCharCode(97 + second)}';
    return !link._unfriendedPairs.contains(pair);
  }
}

String _describeGroup(GroupSession group) =>
    'local=${group.localPeerId} state=${group.state.name} '
    'id=${group.groupId.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()} '
    'term=${group.coordinatorTerm} coordinator=${group.coordinatorPeerId} '
    'members=${group.members.map((member) => member.peerId).join(',')}';

void _testLog(String message) {
  // Keep failed simulated handshakes diagnosable without exposing key or
  // payload contents in test output.
  print('[three-peer-test] $message');
}

import 'dart:async';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      final groupA = link.a.joinOrCreateGroup(_groupConfig());
      final groupB = link.b.joinOrCreateGroup(_groupConfig());
      await _waitFor(
        () => _sameCommittedGroup([groupA, groupB], memberCount: 2),
        timeout: const Duration(seconds: 5),
      );
      final groupC = link.c.joinOrCreateGroup(_groupConfig());
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
            'three-peer group states: ${groups.map(_describeGroup).join('; ')}');
        rethrow;
      }
      final originalGroupId = groups[0].groupId;
      final originalCoordinator = groups[0].coordinatorPeerId;
      expect(groups.expand((group) => group.members).length, 9);

      final receivedByTarget = Completer<ReliableMessageReceived>();
      final targetBeforeFailure = groups[1];
      final sourceBeforeFailure = groups[0];
      final cSubscription = targetBeforeFailure.events.listen((event) {
        if (event is ReliableMessageReceived && !receivedByTarget.isCompleted) {
          receivedByTarget.complete(event);
        }
      });
      const reliable = SendOptions(deliveryMode: DeliveryMode.reliableAcked);
      final beforeFailure = sourceBeforeFailure
          .send(targetBeforeFailure.localPeerId, [7, 8, 9], options: reliable);
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
      final survivorIndices = [0, 1, 2]
          .where((index) => index != coordinatorIndex)
          .toList(growable: false);
      final survivorSource = groups[survivorIndices[0]];
      final survivorTarget = groups[survivorIndices[1]];
      final survivorMembers = groups[0]
          .members
          .where((member) => member.peerId != originalCoordinator)
          .toList(growable: false);
      final replacement = survivorMembers.map((member) => member.peerId).reduce(
          (left, right) => _comparePeerIds(left, right) >= 0 ? left : right);
      final migrationTerm =
          groups.map((group) => group.coordinatorTerm).reduce(max) + 1;
      // Election frame exchange is covered by the protocol-level election
      // tests. Here we inject its deterministic result into both live group
      // owners after the real GATT loss, then exercise the surviving route.
      // Keeping this boundary explicit prevents the harness from pretending
      // that a direct local commit is the full wire-election implementation.
      for (final index in survivorIndices) {
        groups[index].commitMembership(survivorMembers,
            coordinator: replacement, coordinatorTerm: migrationTerm);
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
            survivorIndices.any((index) =>
                groups[index].localPeerId == survivorSource.coordinatorPeerId),
        timeout: const Duration(seconds: 8),
      );

      final receivedAfterMigration = Completer<ReliableMessageReceived>();
      final afterSubscription = survivorTarget.events.listen((event) {
        if (event is ReliableMessageReceived &&
            !receivedAfterMigration.isCompleted) {
          receivedAfterMigration.complete(event);
        }
      });
      final afterFailure = survivorSource
          .send(survivorTarget.localPeerId, [10, 11, 12], options: reliable);
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
  });
}

int _comparePeerIds(PeerId left, PeerId right) {
  for (var index = 0; index < left.bytes.length; index++) {
    final comparison = left.bytes[index].compareTo(right.bytes[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

bool _sameCommittedGroup(List<GroupSession> groups,
    {required int memberCount}) {
  if (groups.any((group) =>
      group.state != GroupState.ready ||
      group.members.length != memberCount ||
      group.coordinatorPeerId == null)) {
    return false;
  }
  final id = groups.first.groupId;
  final coordinator = groups.first.coordinatorPeerId;
  return groups.every(
      (group) => group.groupId == id && group.coordinatorPeerId == coordinator);
}

GroupConfig _groupConfig() => GroupConfig(
      applicationNamespace: const [1, 2, 3],
      groupJoinToken: List<int>.filled(16, 4),
      groupTrustMode: GroupTrustMode.openTofu,
      maxPeers: 3,
      autoAccept: true,
      autoMerge: true,
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
  late final NearbyRuntime a;
  late final NearbyRuntime b;
  late final NearbyRuntime c;
  late final List<NearbyRuntime> runtimes;
  int _generation = 0;

  static Future<_ThreePeerLink> create() async {
    final link = _ThreePeerLink._();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (var index = 0; index < link._methods.length; index++) {
      messenger.setMockMethodCallHandler(
        link._methods[index],
        (call) => link._handle(index, call),
      );
    }
    final config = const RuntimeConfig(
      trustMode: HandshakeTrustMode.tofu,
      autoReconnect: true,
      reconnectTimeoutMs: 1500,
      logger: _testLog,
    );
    final created = <NearbyRuntime>[];
    for (var index = 0; index < 3; index++) {
      created.add(await createRuntime(
        config: config,
        identityStore: InMemoryIdentityStore(
          keyPair: await Ed25519().newKeyPairFromSeed(
            Uint8List.fromList(List<int>.filled(32, index + 1)),
          ),
        ),
        platformBleBackend: PlatformBleBackend(
          methods: link._methods[index],
          eventStream: link._events[index].stream,
        ),
      ));
    }
    link.runtimes = created;
    link.a = created[0];
    link.b = created[1];
    link.c = created[2];
    return link;
  }

  Future<void> connect(String endpoint) async {
    final local = endpoint.codeUnitAt(0) - 97;
    final attempt = runtimes[local].connect(endpoint);
    await attempt.events
        .firstWhere((event) => event is ConnectionAttemptConnected);
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
        _events[local].add(PlatformGattConnected(
          endpoint,
          'central',
          connectionGeneration: generation,
        ));
        _events[remote].add(PlatformGattConnected(
          endpoint,
          'peripheral',
          connectionGeneration: generation,
        ));
        return null;
      case 'submitGattFragment':
        _events[remote].add(PlatformGattFragment(
          endpoint,
          arguments['fragment'] as Uint8List,
        ));
        return 'submitted';
      case 'closeGattConnection':
        _events[remote].add(PlatformGattDisconnected(endpoint));
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

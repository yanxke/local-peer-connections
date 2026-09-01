import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';
import 'types.dart';
import 'protocol/group_dedup.dart';
import 'protocol/group_message_id.dart';
import 'protocol/group_realtime.dart';
import 'protocol/group_routing_send.dart';

/// The runtime-owned bridge between a [GroupSession] and authenticated
/// PeerConnections.  It is deliberately expressed in terms of stable group
/// operations, rather than a destination PeerConnection: a non-coordinator
/// source must submit through its coordinator (Section 43.1), while a
/// coordinator may relay to the end destination.
///
/// Applications do not normally create this object.  It is public only so a
/// platform/runtime integration can bind the portable GroupSession core
/// without importing platform BLE types.
abstract interface class GroupRouteTransport {
  void submitReliable(
      RoutedGroupOperation operation, SendHandleController controller);

  void submitRealtime(
      GroupRealtimeDatagram datagram, RealtimeSendHandleController controller);

  /// Cancels local routing ownership.  Protocol 1.1 has no remote revocation
  /// frame; already submitted traffic may still arrive (Section 43.1.9).
  void cancelReliable(GroupMessageId groupMessageId);
}

sealed class GroupEvent {
  const GroupEvent(this.eventSequence, this.observedAtMonotonicMs);
  final int eventSequence, observedAtMonotonicMs;
}

class GroupReady extends GroupEvent {
  const GroupReady(super.sequence, super.at, this.groupId,
      this.coordinatorPeerId, this.members);
  final GroupId groupId;
  final PeerId coordinatorPeerId;
  final List<GroupMember> members;
}

class MemberJoined extends GroupEvent {
  const MemberJoined(super.sequence, super.at, this.member);
  final GroupMember member;
}

class MemberLeft extends GroupEvent {
  const MemberLeft(super.sequence, super.at, this.peerId);
  final PeerId peerId;
}

class CoordinatorChanged extends GroupEvent {
  CoordinatorChanged(super.sequence, super.at, this.previous, this.current,
      this.localIsCoordinator, [List<int>? latestCoordinatorCheckpoint])
      : latestCoordinatorCheckpoint = latestCoordinatorCheckpoint == null
            ? null
            : Uint8List.fromList(latestCoordinatorCheckpoint);
  final PeerId? previous;
  final PeerId current;
  final bool localIsCoordinator;
  final Uint8List? latestCoordinatorCheckpoint;
}

class ReliableMessageReceived extends GroupEvent {
  ReliableMessageReceived(super.sequence, super.at, this.sourcePeerId,
      this.groupMessageId, this.deliveryMode, List<int> bytes)
      : bytes = Uint8List.fromList(bytes);
  final PeerId sourcePeerId;
  final GroupMessageId groupMessageId;
  final DeliveryMode deliveryMode;
  final Uint8List bytes;
}

class RealtimeDatagramReceived extends GroupEvent {
  RealtimeDatagramReceived(super.sequence, super.at, this.sourcePeerId,
      this.channelId, this.senderTick, this.datagramSequence, List<int> bytes)
      : bytes = Uint8List.fromList(bytes);
  final PeerId sourcePeerId;
  final int channelId, senderTick, datagramSequence;
  final Uint8List bytes;
}

/// A nonterminal group-level protocol failure. It does not by itself change
/// membership or close the GroupSession.
class GroupError extends GroupEvent {
  const GroupError(
    super.sequence,
    super.at,
    this.errorCode, {
    this.peerId,
    this.groupMessageId,
    this.diagnostic,
  });

  final LpcErrorCode errorCode;
  final PeerId? peerId;
  final GroupMessageId? groupMessageId;
  final String? diagnostic;
}

class GroupClosed extends GroupEvent {
  const GroupClosed(super.sequence, super.at);
}

class SendHandle {
  SendHandle._(this._state, {void Function()? onCancel}) : _onCancel = onCancel;
  SendState _state;
  final void Function()? _onCancel;
  final _done = Completer<SendState>();
  SendState get state => _state;
  Future<SendState> get completed => _done.future;
  bool get isTerminal => _done.isCompleted;
  void _complete(SendState state) {
    if (!_done.isCompleted) {
      _state = state;
      _done.complete(state);
    }
  }

  void _transition(SendState state) {
    if (!_done.isCompleted) _state = state;
  }

  void cancel() {
    if (_done.isCompleted) return;
    _onCancel?.call();
    _complete(SendState.cancelled);
  }
}

/// Internal protocol owners use this narrow controller to reflect committed
/// transport and acknowledgment transitions without exposing mutable handle
/// state to applications.
class SendHandleController {
  SendHandleController.queued({void Function()? onCancel})
      : handle = SendHandle._(SendState.queued, onCancel: onCancel);

  SendHandleController.transmitting({void Function()? onCancel})
      : handle = SendHandle._(SendState.transmitting, onCancel: onCancel);

  final SendHandle handle;
  void transmitting() => handle._transition(SendState.transmitting);
  void sentToTransport() => handle._transition(SendState.sentToTransport);
  void complete(SendState state) => handle._complete(state);
}

class BroadcastHandle {
  BroadcastHandle(Map<PeerId, SendHandle> results)
      : results = Map.unmodifiable(results),
        targetPeerIds = List.unmodifiable(results.keys),
        handles = List.unmodifiable(results.values) {
    _watchConstituents();
  }
  final List<PeerId> targetPeerIds;
  final Map<PeerId, SendHandle> results;
  final List<SendHandle> handles;
  final _done = Completer<BroadcastState>();
  BroadcastState _state = BroadcastState.active;
  BroadcastState get state => _state;
  Future<BroadcastState> get completed => _done.future;

  void _watchConstituents() {
    if (handles.isEmpty || handles.every((handle) => handle.isTerminal)) {
      _complete(BroadcastState.completed);
      return;
    }
    Future.wait(handles.map((handle) => handle.completed))
        .then((_) => _complete(BroadcastState.completed));
  }

  void _complete(BroadcastState state) {
    if (_done.isCompleted) return;
    _state = state;
    _done.complete(state);
  }

  /// Requests local best-effort cancellation of every nonterminal constituent.
  void cancel() {
    if (_done.isCompleted || _state == BroadcastState.cancelled) return;
    for (final handle in handles) {
      handle.cancel();
    }
    _state = BroadcastState.cancelled;
    if (!_done.isCompleted) _done.complete(_state);
  }
}

class RealtimeSendHandle extends SendHandle {
  RealtimeSendHandle._(SendState state, {void Function()? onCancel})
      : super._(state, onCancel: onCancel);
}

class RealtimeSendHandleController {
  RealtimeSendHandleController.queued({void Function()? onCancel})
      : handle = RealtimeSendHandle._(SendState.queued, onCancel: onCancel);
  final RealtimeSendHandle handle;
  void transmitting() => handle._transition(SendState.transmitting);
  void complete(SendState state) => handle._complete(state);
}

class RealtimeBroadcastHandle {
  RealtimeBroadcastHandle(Map<PeerId, RealtimeSendHandle> results)
      : results = Map.unmodifiable(results),
        targetPeerIds = List.unmodifiable(results.keys),
        handles = List.unmodifiable(results.values) {
    _watchConstituents();
  }
  final List<PeerId> targetPeerIds;
  final Map<PeerId, RealtimeSendHandle> results;
  final List<RealtimeSendHandle> handles;
  final _done = Completer<BroadcastState>();
  BroadcastState _state = BroadcastState.active;
  BroadcastState get state => _state;
  Future<BroadcastState> get completed => _done.future;

  void _watchConstituents() {
    if (handles.isEmpty || handles.every((handle) => handle.isTerminal)) {
      _complete(BroadcastState.completed);
      return;
    }
    Future.wait(handles.map((handle) => handle.completed))
        .then((_) => _complete(BroadcastState.completed));
  }

  void _complete(BroadcastState state) {
    if (_done.isCompleted) return;
    _state = state;
    _done.complete(state);
  }

  /// Requests local best-effort cancellation of every nonterminal constituent.
  void cancel() {
    if (_done.isCompleted || _state == BroadcastState.cancelled) return;
    for (final handle in handles) {
      handle.cancel();
    }
    _state = BroadcastState.cancelled;
    if (!_done.isCompleted) _done.complete(_state);
  }
}

/// Serialized, in-memory GroupSession core. Platform discovery/backends feed this
/// object with committed membership and authenticated routed envelopes.
class GroupSession {
  GroupSession.internal(this._config, this._localPeerId, GroupId groupId)
      : _groupId = groupId {
    _members[_localPeerId] = GroupMember(_localPeerId, _config.maxPeers);
    _transition(GroupState.discovering);
    _transition(GroupState.forming);
    _coordinator = _localPeerId;
    _transition(GroupState.ready);
    _emit((s, a) => GroupReady(s, a, _groupId, _coordinator!, members));
  }
  final GroupConfig _config;
  final PeerId _localPeerId;
  GroupId _groupId;
  final Map<PeerId, GroupMember> _members = {};
  final StreamController<GroupEvent> _events =
      StreamController.broadcast(sync: true);
  // The bound applies to the GroupSession as a whole, while the identity is
  // the normative (source, GroupMessageId) pair (Section 43.1.4).
  final CompletedGroupMessageDedup _delivered = CompletedGroupMessageDedup();
  final GroupMessageIdAllocator _groupMessageIds = GroupMessageIdAllocator(
      List<int>.generate(8, (_) => Random.secure().nextInt(256)));
  final GroupRealtimeSequenceAllocator _realtimeSequences =
      GroupRealtimeSequenceAllocator();
  // Section 43.1.14 scopes group realtime latest-state suppression by the
  // original source and channel, not merely by channel.
  final Map<String, int> _realtimeLastSequence = {};
  final Queue<_Command> _commands = Queue<_Command>();
  final Queue<int> _checkpointPublishTimes = Queue<int>();
  Uint8List? _latestCoordinatorCheckpoint;
  GroupState _state = GroupState.starting;
  PeerId? _coordinator;
  int _coordinatorTerm = 0;
  int _eventSequence = 0;
  bool _running = false;
  GroupRouteTransport? _routeTransport;
  Stream<GroupEvent> get events => _events.stream;
  GroupId get groupId => _groupId;
  PeerId get localPeerId => _localPeerId;
  GroupConfig get config => _config;
  PeerId? get coordinatorPeerId => _coordinator;
  int get coordinatorTerm => _coordinatorTerm;
  bool get isCoordinator => _coordinator == _localPeerId;
  GroupState get state => _state;
  List<GroupMember> get members => List.unmodifiable(_members.values.toList()
    ..sort((a, b) => _comparePeerIds(a.peerId, b.peerId)));
  int get effectiveMaxPeers =>
      _members.values.map((m) => m.maxPeers).reduce(min);
  Uint8List? latestCoordinatorCheckpoint() =>
      _latestCoordinatorCheckpoint == null
          ? null
          : Uint8List.fromList(_latestCoordinatorCheckpoint!);
  void _transition(GroupState next) {
    const allowed = {
      GroupState.starting: {GroupState.discovering, GroupState.failed},
      GroupState.discovering: {
        GroupState.forming,
        GroupState.electing,
        GroupState.leaving,
        GroupState.failed
      },
      GroupState.forming: {
        GroupState.electing,
        GroupState.ready,
        GroupState.leaving,
        GroupState.failed
      },
      GroupState.electing: {
        GroupState.forming,
        GroupState.ready,
        GroupState.leaving,
        GroupState.failed
      },
      GroupState.ready: {
        GroupState.migratingCoordinator,
        GroupState.forming,
        GroupState.leaving,
        GroupState.failed
      },
      GroupState.migratingCoordinator: {
        GroupState.electing,
        GroupState.ready,
        GroupState.leaving,
        GroupState.failed
      },
      GroupState.leaving: {GroupState.closed},
      GroupState.failed: {GroupState.closed}
    };
    if (!(allowed[_state]?.contains(next) ?? false))
      throw StateError('illegal GroupState transition $_state -> $next');
    _state = next;
  }

  int _now() => DateTime.now().microsecondsSinceEpoch ~/ 1000;
  void _emit(GroupEvent Function(int, int) create) =>
      _events.add(create(++_eventSequence, _now()));
  void _enqueue(void Function() action) {
    _commands.add(_Command(action));
    if (_running) return;
    _running = true;
    while (_commands.isNotEmpty) {
      _commands.removeFirst().run();
    }
    _running = false;
  }

  /// Runtime integration hook.  Binding is intentionally one-way for a
  /// GroupSession lifetime; replacing an active routing owner could cause an
  /// already-admitted operation to bypass coordinator authority.
  void attachRouteTransport(GroupRouteTransport transport) {
    if (_routeTransport != null) {
      throw const LpcException(LpcErrorCode.invalidState,
          'group routing transport is already attached');
    }
    if (_state == GroupState.closed) {
      throw const LpcException(LpcErrorCode.invalidState);
    }
    _routeTransport = transport;
  }

  /// Whether Runtime (or an embedding integration) owns live route delivery
  /// for this session. This is an integration-state query, not protocol state.
  bool get hasRouteTransport => _routeTransport != null;

  SendHandle send(PeerId destination, List<int> bytes,
      {SendOptions options = const SendOptions()}) {
    GroupMessageId? id;
    final controller = SendHandleController.queued(onCancel: () {
      final messageId = id;
      if (messageId != null) _routeTransport?.cancelReliable(messageId);
    });
    final handle = controller.handle;
    _enqueue(() {
      if (handle.isTerminal) return;
      if (_state != GroupState.ready) {
        return controller.complete(SendState.failed);
      }
      if (destination == _localPeerId || !_members.containsKey(destination)) {
        return controller.complete(SendState.failed);
      }
      if (options.deliveryMode == DeliveryMode.realtimeLatest ||
          bytes.length > 1048576) {
        return controller.complete(SendState.failed);
      }
      final transport = _routeTransport;
      // There is no conforming local success path without a runtime-owned
      // coordinator route.  In particular, a GroupSession must not turn a
      // source-hop admission into destination-level success.
      if (transport == null) return controller.complete(SendState.failed);
      try {
        id = _groupMessageIds.allocate();
        final operation = RoutedGroupOperation(
            groupId: _groupId,
            sourcePeerId: _localPeerId,
            destinationPeerId: destination,
            groupMessageId: id!,
            deliveryMode: options.deliveryMode,
            priority: options.priority,
            bytes: bytes);
        controller.transmitting();
        transport.submitReliable(operation, controller);
      } on Object {
        controller.complete(SendState.failed);
      }
    });
    return handle;
  }

  BroadcastHandle broadcast(List<int> bytes,
          {SendOptions options = const SendOptions()}) =>
      BroadcastHandle({
        for (final peer
            in (_members.keys.where((p) => p != _localPeerId).toList()
              ..sort(_comparePeerIds)))
          peer: send(peer, bytes, options: options)
      });
  RealtimeSendHandle sendRealtime(
      PeerId destination, int channelId, List<int> bytes,
      {RealtimeOptions options = const RealtimeOptions()}) {
    final controller = RealtimeSendHandleController.queued();
    final h = controller.handle;
    _enqueue(() {
      if (h.isTerminal) return;
      if (_state != GroupState.ready ||
          destination == _localPeerId ||
          !_members.containsKey(destination) ||
          channelId < 1 ||
          channelId > 65535 ||
          bytes.length > 1100) {
        return controller.complete(SendState.failed);
      }
      final transport = _routeTransport;
      if (transport == null) return controller.complete(SendState.failed);
      try {
        final datagram = GroupRealtimeDatagram(
            groupId: _groupId,
            sourcePeerId: _localPeerId,
            destinationPeerId: destination,
            channelId: channelId,
            sequence: _realtimeSequences.allocate(destination, channelId),
            senderTick: options.senderTick,
            bytes: bytes);
        controller.transmitting();
        transport.submitRealtime(datagram, controller);
      } on Object {
        controller.complete(SendState.failed);
      }
    });
    return h;
  }

  RealtimeBroadcastHandle broadcastRealtime(int channelId, List<int> bytes,
          {RealtimeOptions options = const RealtimeOptions()}) =>
      RealtimeBroadcastHandle({
        for (final peer
            in (_members.keys.where((p) => p != _localPeerId).toList()
              ..sort(_comparePeerIds)))
          peer: sendRealtime(peer, channelId, bytes, options: options)
      });
  void leave() => _enqueue(() {
        if (_state == GroupState.closed || _state == GroupState.leaving) return;
        _transition(GroupState.leaving);
        _transition(GroupState.closed);
        _emit((s, a) => GroupClosed(s, a));
        _events.close();
      });
  void close() => leave();

  /// Retains the newest coordinator application checkpoint. The transport
  /// owner replicates this immutable value through its bounded per-target
  /// checkpoint queues after this serialized admission succeeds.
  void publishCoordinatorCheckpoint(List<int> bytes) {
    if (bytes.length > 262144) {
      throw const LpcException(LpcErrorCode.messageTooLarge);
    }
    final now = _now();
    while (_checkpointPublishTimes.isNotEmpty &&
        now - _checkpointPublishTimes.first >= 1000) {
      _checkpointPublishTimes.removeFirst();
    }
    if (_checkpointPublishTimes.length >= 4) {
      throw const LpcException(LpcErrorCode.resourceExhausted);
    }
    _checkpointPublishTimes.addLast(now);
    _latestCoordinatorCheckpoint = Uint8List.fromList(bytes);
  }

  /// Backend/core hook after a newer complete authenticated checkpoint has
  /// committed. The receiver's term/sequence validation happens before this
  /// GroupSession ownership boundary.
  void commitCoordinatorCheckpoint(List<int> bytes) {
    if (bytes.length > 262144) {
      throw const LpcException(LpcErrorCode.messageTooLarge);
    }
    _latestCoordinatorCheckpoint = Uint8List.fromList(bytes);
  }

  /// Backend/core hook for a committed nonterminal group error. The event is
  /// serialized with all other GroupSession callbacks and does not mutate
  /// group membership or public send state.
  void reportError(
    LpcErrorCode errorCode, {
    PeerId? peerId,
    GroupMessageId? groupMessageId,
    String? diagnostic,
  }) =>
      _enqueue(() {
        if (_state == GroupState.closed) return;
        _emit((s, a) => GroupError(
              s,
              a,
              errorCode,
              peerId: peerId,
              groupMessageId: groupMessageId,
              diagnostic: diagnostic,
            ));
      });

  // Backend/core hooks: callers must invoke only after authenticated protocol commit.
  void commitMembership(Iterable<GroupMember> snapshot,
          {required PeerId coordinator, int coordinatorTerm = 0}) =>
      _enqueue(() {
        final next = {for (final m in snapshot) m.peerId: m};
        if (!next.containsKey(_localPeerId))
          throw const LpcException(LpcErrorCode.destinationNotInGroup);
        if (!next.containsKey(coordinator) ||
            coordinatorTerm < _coordinatorTerm) {
          throw const LpcException(LpcErrorCode.protocolMismatch);
        }
        for (final id in next.keys.where((id) => !_members.containsKey(id))) {
          _members[id] = next[id]!;
          _emit((s, a) => MemberJoined(s, a, next[id]!));
        }
        for (final id
            in _members.keys.where((id) => !next.containsKey(id)).toList()) {
          _members.remove(id);
          _emit((s, a) => MemberLeft(s, a, id));
        }
        final previous = _coordinator;
        _coordinator = coordinator;
        _coordinatorTerm = coordinatorTerm;
        if (previous != coordinator)
          _emit((s, a) => CoordinatorChanged(s, a, previous, coordinator,
              isCoordinator, _latestCoordinatorCheckpoint));
      });

  /// Commits the state transition required before an election starts. The
  /// runtime invokes this only after the previous coordinator is unavailable
  /// or an authenticated resignation has been accepted.
  void beginCoordinatorMigration() => _enqueue(() {
        if (_state != GroupState.ready) return;
        _transition(GroupState.migratingCoordinator);
        _transition(GroupState.electing);
      });

  /// Commits a winning GROUP_MERGE or reconciliation result before any
  /// subsequent coordinator routing is allowed. The winning GroupId replaces
  /// the historical local one while this same GroupSession object survives.
  void commitMergedMembership({
    required GroupId groupId,
    required Iterable<GroupMember> members,
    required PeerId coordinator,
    required int coordinatorTerm,
  }) =>
      _enqueue(() {
        if (coordinatorTerm <= _coordinatorTerm) {
          throw const LpcException(LpcErrorCode.protocolMismatch);
        }
        _groupId = groupId;
        final next = {for (final member in members) member.peerId: member};
        if (!next.containsKey(_localPeerId) || !next.containsKey(coordinator)) {
          throw const LpcException(LpcErrorCode.protocolMismatch);
        }
        for (final id in next.keys.where((id) => !_members.containsKey(id))) {
          _members[id] = next[id]!;
          _emit((s, a) => MemberJoined(s, a, next[id]!));
        }
        for (final id
            in _members.keys.where((id) => !next.containsKey(id)).toList()) {
          _members.remove(id);
          _emit((s, a) => MemberLeft(s, a, id));
        }
        for (final entry in next.entries) {
          _members[entry.key] = entry.value;
        }
        final previous = _coordinator;
        _coordinator = coordinator;
        _coordinatorTerm = coordinatorTerm;
        if (_state == GroupState.ready) {
          _transition(GroupState.migratingCoordinator);
          _transition(GroupState.electing);
          _transition(GroupState.forming);
          _transition(GroupState.ready);
        } else if (_state == GroupState.electing) {
          _transition(GroupState.forming);
          _transition(GroupState.ready);
        }
        if (previous != coordinator) {
          _emit((s, a) => CoordinatorChanged(s, a, previous, coordinator,
              isCoordinator, _latestCoordinatorCheckpoint));
        }
      });
  void receiveReliable(
          {required PeerId source,
          required GroupMessageId id,
          required DeliveryMode mode,
          SendPriority priority = SendPriority.interactive,
          required List<int> bytes}) =>
      _enqueue(() {
        if (source == _localPeerId) {
          throw const LpcException(LpcErrorCode.protocolMismatch);
        }
        if (_state != GroupState.ready || !_members.containsKey(source)) {
          return;
        }
        if (mode == DeliveryMode.realtimeLatest) {
          throw const LpcException(LpcErrorCode.protocolMismatch);
        }
        if (!_delivered.accept(
            source: source,
            messageId: id,
            destination: _localPeerId,
            mode: mode,
            priority: priority,
            bytes: bytes)) {
          return;
        }
        _emit((s, a) => ReliableMessageReceived(s, a, source, id, mode, bytes));
      });

  /// Backend/core hook for a fully authenticated, coordinator-validated
  /// destination realtime datagram. Earlier/equal sequence numbers are
  /// silently suppressed before any application-visible event is emitted.
  void receiveRealtime({
    required PeerId source,
    required int channelId,
    required int senderTick,
    required int datagramSequence,
    required List<int> bytes,
  }) =>
      _enqueue(() {
        if (source == _localPeerId) {
          throw const LpcException(LpcErrorCode.protocolMismatch);
        }
        if (_state != GroupState.ready || !_members.containsKey(source)) {
          return;
        }
        if (channelId < 1 ||
            channelId > 65535 ||
            datagramSequence < 1 ||
            datagramSequence > 0xffffffff ||
            bytes.length > 1100) {
          throw const LpcException(LpcErrorCode.protocolMismatch);
        }
        final key = '$source:$channelId';
        final previous = _realtimeLastSequence[key];
        if (previous != null && !_newerRealtime(datagramSequence, previous)) {
          return;
        }
        _realtimeLastSequence[key] = datagramSequence;
        _emit((s, a) => RealtimeDatagramReceived(
            s, a, source, channelId, senderTick, datagramSequence, bytes));
      });

  bool _newerRealtime(int candidate, int previous) {
    final difference = (candidate - previous) & 0xffffffff;
    return difference != 0 && difference < 0x80000000;
  }
}

class _Command {
  _Command(this.run);
  final void Function() run;
}

int _comparePeerIds(PeerId a, PeerId b) {
  for (var index = 0; index < a.bytes.length; index++) {
    final comparison = a.bytes[index].compareTo(b.bytes[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

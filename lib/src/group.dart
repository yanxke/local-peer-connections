import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';
import 'types.dart';
import 'protocol/group_dedup.dart';

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
  const CoordinatorChanged(super.sequence, super.at, this.previous,
      this.current, this.localIsCoordinator);
  final PeerId? previous;
  final PeerId current;
  final bool localIsCoordinator;
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

class GroupClosed extends GroupEvent {
  const GroupClosed(super.sequence, super.at);
}

class SendHandle {
  SendHandle._(this._state);
  SendState _state;
  final _done = Completer<SendState>();
  SendState get state => _state;
  Future<SendState> get completed => _done.future;
  void _complete(SendState state) {
    if (!_done.isCompleted) {
      _state = state;
      _done.complete(state);
    }
  }

  void cancel() => _complete(SendState.cancelled);
}

class BroadcastHandle {
  BroadcastHandle(Map<PeerId, SendHandle> results)
      : results = Map.unmodifiable(results),
        targetPeerIds = List.unmodifiable(results.keys),
        handles = List.unmodifiable(results.values);
  final List<PeerId> targetPeerIds;
  final Map<PeerId, SendHandle> results;
  final List<SendHandle> handles;
  Future<List<SendState>> get completed =>
      Future.wait(handles.map((e) => e.completed));
}

class RealtimeSendHandle extends SendHandle {
  RealtimeSendHandle._(SendState state) : super._(state);
}

class RealtimeBroadcastHandle {
  RealtimeBroadcastHandle(Map<PeerId, RealtimeSendHandle> results)
      : results = Map.unmodifiable(results),
        targetPeerIds = List.unmodifiable(results.keys),
        handles = List.unmodifiable(results.values);
  final List<PeerId> targetPeerIds;
  final Map<PeerId, RealtimeSendHandle> results;
  final List<RealtimeSendHandle> handles;
  Future<List<SendState>> get completed =>
      Future.wait(handles.map((e) => e.completed));
}

/// Serialized, in-memory GroupSession core. Platform discovery/backends feed this
/// object with committed membership and authenticated routed envelopes.
class GroupSession {
  GroupSession.internal(this._config, this._localPeerId, this._groupId) {
    _members[_localPeerId] = GroupMember(_localPeerId, _config.maxPeers);
    _transition(GroupState.discovering);
    _transition(GroupState.forming);
    _coordinator = _localPeerId;
    _transition(GroupState.ready);
    _emit((s, a) => GroupReady(s, a, _groupId, _coordinator!, members));
  }
  final GroupConfig _config;
  final PeerId _localPeerId;
  final GroupId _groupId;
  final Map<PeerId, GroupMember> _members = {};
  final StreamController<GroupEvent> _events =
      StreamController.broadcast(sync: true);
  // The bound applies to the GroupSession as a whole, while the identity is
  // the normative (source, GroupMessageId) pair (Section 43.1.4).
  final CompletedGroupMessageDedup _delivered = CompletedGroupMessageDedup();
  final Queue<_Command> _commands = Queue<_Command>();
  GroupState _state = GroupState.starting;
  PeerId? _coordinator;
  int _eventSequence = 0;
  bool _running = false;
  Stream<GroupEvent> get events => _events.stream;
  GroupId get groupId => _groupId;
  PeerId get localPeerId => _localPeerId;
  PeerId? get coordinatorPeerId => _coordinator;
  bool get isCoordinator => _coordinator == _localPeerId;
  GroupState get state => _state;
  List<GroupMember> get members => List.unmodifiable(_members.values.toList()
    ..sort((a, b) => _comparePeerIds(a.peerId, b.peerId)));
  int get effectiveMaxPeers =>
      _members.values.map((m) => m.maxPeers).reduce(min);
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

  SendHandle send(PeerId destination, List<int> bytes,
      {SendOptions options = const SendOptions()}) {
    final handle = SendHandle._(SendState.queued);
    _enqueue(() {
      if (_state != GroupState.ready) return handle._complete(SendState.failed);
      if (destination == _localPeerId || !_members.containsKey(destination))
        return handle._complete(SendState.failed);
      if (options.deliveryMode == DeliveryMode.realtimeLatest ||
          bytes.length > 1048576) {
        return handle._complete(SendState.failed);
      }
      handle._state = SendState.transmitting;
      handle._complete(options.deliveryMode == DeliveryMode.reliableAcked
          ? SendState.remoteAcknowledged
          : SendState.sentToTransport);
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
    final h = RealtimeSendHandle._(SendState.queued);
    _enqueue(() {
      if (_state != GroupState.ready ||
          destination == _localPeerId ||
          !_members.containsKey(destination) ||
          channelId < 1 ||
          channelId > 65535 ||
          bytes.length > 1100) return h._complete(SendState.failed);
      h._complete(SendState.sentToTransport);
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
  // Backend/core hooks: callers must invoke only after authenticated protocol commit.
  void commitMembership(Iterable<GroupMember> snapshot,
          {required PeerId coordinator}) =>
      _enqueue(() {
        final next = {for (final m in snapshot) m.peerId: m};
        if (!next.containsKey(_localPeerId))
          throw const LpcException(LpcErrorCode.destinationNotInGroup);
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
        if (previous != coordinator)
          _emit((s, a) =>
              CoordinatorChanged(s, a, previous, coordinator, isCoordinator));
      });
  void receiveReliable(
          {required PeerId source,
          required GroupMessageId id,
          required DeliveryMode mode,
          SendPriority priority = SendPriority.interactive,
          required List<int> bytes}) =>
      _enqueue(() {
        if (_state != GroupState.ready || !_members.containsKey(source)) return;
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

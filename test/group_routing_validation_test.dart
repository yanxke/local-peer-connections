import 'package:flutter_test/flutter_test.dart';
import 'package:local_peer_connections/local_peer_connections.dart';

PeerId _peer(int value) => PeerId(List.filled(16, value));
GroupId _group(int value) => GroupId(List.filled(16, value));

GroupRoutingValidator _validator({Iterable<GroupId> aliases = const []}) =>
    GroupRoutingValidator(
      canonicalGroupId: _group(1),
      localPeerId: _peer(3),
      currentCoordinatorPeerId: _peer(1),
      committedMembers: {_peer(1), _peer(2), _peer(3)},
      activeHistoricalAliases: aliases,
    );

ReassembledGroupReliable _reliable({GroupId? groupId}) =>
    ReassembledGroupReliable(
      pairwiseMessageId: List.filled(8, 1),
      groupId: groupId ?? _group(1),
      sourcePeerId: _peer(2),
      destinationPeerId: _peer(3),
      groupMessageId: GroupMessageId(List.filled(16, 4)),
      deliveryMode: DeliveryMode.reliableAcked,
      priority: SendPriority.normal,
      bytes: [7],
    );

void main() {
  test('member source hop requires authenticated source and committed target',
      () {
    final validator = _validator();
    expect(
      () => validator.validateMemberToCoordinator(
        _reliable(),
        authenticatedSendingPeerId: _peer(1),
      ),
      throwsA(isA<LpcException>()),
    );
    expect(
      () => validator.validateMemberToCoordinator(
        ReassembledGroupReliable(
          pairwiseMessageId: List.filled(8, 1),
          groupId: _group(1),
          sourcePeerId: _peer(2),
          destinationPeerId: _peer(4),
          groupMessageId: GroupMessageId(List.filled(16, 4)),
          deliveryMode: DeliveryMode.reliableAcked,
          priority: SendPriority.normal,
          bytes: [7],
        ),
        authenticatedSendingPeerId: _peer(2),
      ),
      throwsA(isA<LpcException>()),
    );
  });

  test('member source hop accepts only active aliases and normalizes them', () {
    final alias = _group(9);
    final validator = _validator(aliases: [alias]);
    expect(
      validator
          .validateMemberToCoordinator(
            _reliable(groupId: alias),
            authenticatedSendingPeerId: _peer(2),
          )
          .groupId,
      _group(1),
    );
    expect(
      () => _validator().validateMemberToCoordinator(
        _reliable(groupId: alias),
        authenticatedSendingPeerId: _peer(2),
      ),
      throwsA(isA<LpcException>()),
    );
  });

  test('destination hop requires the current coordinator and local destination',
      () {
    final validator = _validator();
    validator.validateCoordinatorToDestination(
      _reliable(),
      authenticatedSendingPeerId: _peer(1),
    );
    expect(
      () => validator.validateCoordinatorToDestination(
        _reliable(),
        authenticatedSendingPeerId: _peer(2),
      ),
      throwsA(isA<LpcException>()),
    );
  });

  test('realtime source hops preserve fields while normalizing active alias',
      () {
    final alias = _group(9);
    final validated =
        _validator(aliases: [alias]).validateRealtimeMemberToCoordinator(
      GroupRealtimeDatagram(
        groupId: alias,
        sourcePeerId: _peer(2),
        destinationPeerId: _peer(3),
        channelId: 1,
        sequence: 1,
        senderTick: 5,
        bytes: [7],
      ),
      authenticatedSendingPeerId: _peer(2),
    );
    expect(validated.groupId, _group(1));
    expect(validated.sequence, 1);
    expect(validated.bytes, [7]);
  });
}

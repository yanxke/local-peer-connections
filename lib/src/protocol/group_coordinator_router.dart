import '../types.dart';
import 'coordinator_relay_controller.dart';
import 'group_realtime.dart';
import 'group_reliable.dart';
import 'group_routing_validation.dart';

/// Transport-agnostic coordinator routing core. Its caller supplies only
/// authenticated, complete reliable hops or authenticated realtime datagrams;
/// the returned actions are then submitted by the relevant PeerConnection.
class GroupCoordinatorRouter {
  GroupCoordinatorRouter({
    required this.validator,
    required this.reliableController,
    required this.realtimePending,
  }) {
    if (validator.currentCoordinatorPeerId !=
        reliableController.coordinatorPeerId) {
      throw ArgumentError(
          'validator and relay controller disagree on coordinator');
    }
  }

  final GroupRoutingValidator validator;
  final CoordinatorRelayController reliableController;
  final CoordinatorRealtimePending realtimePending;

  CoordinatorRelayActions receiveReliableFromMember(
    ReassembledGroupReliable operation, {
    required PeerId authenticatedSendingPeerId,
    required bool destinationReady,
    required int reservationBytes,
    List<int>? destinationPairwiseMessageId,
  }) {
    final validated = validator.validateMemberToCoordinator(
      operation,
      authenticatedSendingPeerId: authenticatedSendingPeerId,
    );
    return reliableController.admit(
      validated,
      committedMembers: validator.committedMembers,
      destinationReady: destinationReady,
      reservationBytes: reservationBytes,
      destinationPairwiseMessageId: destinationPairwiseMessageId,
    );
  }

  CoordinatorRealtimeEnqueueResult receiveRealtimeFromMember(
    GroupRealtimeDatagram datagram, {
    required PeerId authenticatedSendingPeerId,
    required bool destinationReady,
  }) {
    final validated = validator.validateRealtimeMemberToCoordinator(
      datagram,
      authenticatedSendingPeerId: authenticatedSendingPeerId,
    );
    return realtimePending.enqueue(
      validated,
      committedMembers: validator.committedMembers,
      destinationReady: destinationReady,
    );
  }

  /// Commits the Section 43.1.12 routing consequences after membership itself
  /// has changed: reliable relays are terminated/signaled and pending realtime
  /// is dropped.
  List<CoordinatorRelayActions> destinationRemoved(PeerId destination) {
    realtimePending.destinationRemoved(destination);
    return reliableController.destinationRemoved(destination);
  }

  /// Re-exposes retained final-hop relays only after the destination transport
  /// has successfully resumed. Their existing reservations are not re-admitted.
  List<CoordinatorRelayActions> destinationResumeSucceeded(
          PeerId destination) =>
      reliableController.destinationResumeSucceeded(destination);

  /// A terminal destination reconnect failure ends every still-admitted relay
  /// to that committed member; pending realtime state is already generation-
  /// local and is not recovered.
  List<CoordinatorRelayActions> destinationResumeFailed(PeerId destination) {
    realtimePending.destinationRemoved(destination);
    return reliableController.destinationResumeFailed(destination);
  }

  /// Commits coordinator authority loss. The former coordinator retains no
  /// reliable or realtime routing ownership and emits no new signaling.
  void coordinatorAuthorityLost() {
    reliableController.coordinatorAuthorityLost();
    realtimePending.coordinatorAuthorityLost();
  }
}

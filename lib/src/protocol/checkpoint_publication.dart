import 'dart:async';

import '../types.dart';

enum CheckpointAcknowledgementRequirement {
  none,
  allCommittedMembers,
  explicitPeers,
}

enum CheckpointApplicationValidationRequirement { none, required }

enum CheckpointPeerResult {
  pending,
  acknowledged,
  superseded,
  ackTimeout,
  peerLeft,
  sessionTerminated,
  authorityLost,
  groupClosed,
}

enum CheckpointPublicationStatus { pending, durable, failed }

class CheckpointPublishOptions {
  factory CheckpointPublishOptions({
    CheckpointAcknowledgementRequirement acknowledgementRequirement =
        CheckpointAcknowledgementRequirement.allCommittedMembers,
    Iterable<PeerId> explicitPeerIds = const [],
    CheckpointApplicationValidationRequirement applicationValidationRequirement =
        CheckpointApplicationValidationRequirement.none,
  }) {
    final values = explicitPeerIds.toList(growable: false);
    return CheckpointPublishOptions._(
      acknowledgementRequirement,
      values,
      Set.unmodifiable(values),
      applicationValidationRequirement,
    );
  }

  CheckpointPublishOptions._(
      this.acknowledgementRequirement,
      this._explicitPeerValues,
      this.explicitPeerIds,
      this.applicationValidationRequirement);

  final CheckpointAcknowledgementRequirement acknowledgementRequirement;
  final List<PeerId> _explicitPeerValues;
  final Set<PeerId> explicitPeerIds;
  final CheckpointApplicationValidationRequirement
      applicationValidationRequirement;

  bool get hasDuplicateExplicitPeerIds =>
      _explicitPeerValues.length != explicitPeerIds.length;
}

class CheckpointPublicationResult {
  CheckpointPublicationResult({
    required this.publicationId,
    required this.coordinatorTerm,
    required Set<PeerId> requiredPeerIds,
    required this.acceptedMembershipVersion,
    required Map<PeerId, CheckpointPeerResult> perPeerResults,
    required this.status,
  })  : requiredPeerIds = Set.unmodifiable(requiredPeerIds),
        perPeerResults = Map.unmodifiable(perPeerResults);

  final int publicationId;
  final int coordinatorTerm;
  final Set<PeerId> requiredPeerIds;
  final int acceptedMembershipVersion;
  final Map<PeerId, CheckpointPeerResult> perPeerResults;
  final CheckpointPublicationStatus status;
}

class CoordinatorCheckpointHandle {
  CoordinatorCheckpointHandle.internal({
    required this.publicationId,
    required this.coordinatorTerm,
    required Set<PeerId> requiredPeerIds,
    required this.acceptedMembershipVersion,
    required this.applicationValidationRequirement,
    this.onCompleted,
  }) : requiredPeerIds = Set.unmodifiable(requiredPeerIds) {
    _results = {
      for (final peerId in this.requiredPeerIds)
        peerId: CheckpointPeerResult.pending,
    };
  }

  final int publicationId;
  final int coordinatorTerm;
  final Set<PeerId> requiredPeerIds;
  final int acceptedMembershipVersion;
  final CheckpointApplicationValidationRequirement
      applicationValidationRequirement;
  final void Function(CheckpointPublicationResult result)? onCompleted;
  late final Map<PeerId, CheckpointPeerResult> _results;
  final Completer<CheckpointPublicationResult> _completion =
      Completer<CheckpointPublicationResult>();
  CheckpointPublicationStatus _status = CheckpointPublicationStatus.pending;

  CheckpointPublicationStatus get status => _status;
  Map<PeerId, CheckpointPeerResult> get perPeerResults =>
      Map.unmodifiable(_results);
  Future<CheckpointPublicationResult> get completion => _completion.future;
  bool get isTerminal => _completion.isCompleted;

  /// Internal state transition used by the owning GroupSession.
  bool setPeerResult(PeerId peerId, CheckpointPeerResult result) {
    if (_completion.isCompleted || !_results.containsKey(peerId)) return false;
    if (_results[peerId] != CheckpointPeerResult.pending) return false;
    _results[peerId] = result;
    _tryComplete();
    return true;
  }

  /// Internal completion used by the owning GroupSession.
  void completeImmediately() {
    if (_results.isNotEmpty || _completion.isCompleted) return;
    _status = CheckpointPublicationStatus.durable;
    _complete();
  }

  void _tryComplete() {
    if (_completion.isCompleted ||
        _results.values
            .any((result) => result == CheckpointPeerResult.pending)) {
      return;
    }
    _status = _results.values
            .every((result) => result == CheckpointPeerResult.acknowledged)
        ? CheckpointPublicationStatus.durable
        : CheckpointPublicationStatus.failed;
    _complete();
  }

  void _complete() {
    final result = _result();
    _completion.complete(result);
    onCompleted?.call(result);
  }

  CheckpointPublicationResult _result() => CheckpointPublicationResult(
        publicationId: publicationId,
        coordinatorTerm: coordinatorTerm,
        requiredPeerIds: requiredPeerIds,
        acceptedMembershipVersion: acceptedMembershipVersion,
        perPeerResults: _results,
        status: _status,
      );
}

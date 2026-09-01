import 'dart:typed_data';

/// Stable errors from Section 38 of the LPC specification.
enum LpcErrorCode {
  permissionDenied(0x0001),
  bluetoothUnavailable(0x0002),
  bluetoothPoweredOff(0x0003),
  advertisingUnavailable(0x0004),
  discoveryUnavailable(0x0005),
  endpointLost(0x0006),
  connectionTimeout(0x0007),
  connectionRejected(0x0008),
  authenticationFailed(0x0009),
  protocolMismatch(0x000A),
  transportClosed(0x000B),
  sendQueueFull(0x000C),
  messageTooLarge(0x000D),
  l2capUnavailable(0x000E),
  lanUnavailable(0x000F),
  upgradeFailed(0x0010),
  reconnectTimeout(0x0011),
  resourceExhausted(0x0012),
  invalidState(0x0013),
  platformError(0x0014),
  internalError(0x0015),
  identityCollision(0x0016),
  unsupportedFrameType(0x0017),
  sequenceWindowExceeded(0x0018),
  requestTimeout(0x0019),
  messageExpired(0x001A),
  resumeRejected(0x001B),
  channelBindingFailed(0x001C),
  ackTimeout(0x001D),
  messageIdCollision(0x001E),
  duplicateConnection(0x001F),
  unsupportedCapability(0x0020),
  groupFull(0x0021),
  groupScopeMismatch(0x0022),
  groupMergeRejected(0x0023),
  udpProbeTimeout(0x0024),
  udpEndpointChanged(0x0025),
  udpAuthenticationFailed(0x0026),
  groupStateSyncFailed(0x0027),
  destinationNotInGroup(0x0028),
  destinationUnavailable(0x0029);

  const LpcErrorCode(this.value);
  final int value;
}

class LpcException implements Exception {
  const LpcException(this.code, [this.message = '']);
  final LpcErrorCode code;
  final String message;
  @override
  String toString() =>
      'LpcException($code${message.isEmpty ? '' : ': $message'})';
}

class PeerId {
  PeerId(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (this.bytes.length != 16)
      throw ArgumentError.value(bytes, 'bytes', 'PeerId must be 16 bytes');
  }
  final Uint8List bytes;
  @override
  bool operator ==(Object other) =>
      other is PeerId && _same(bytes, other.bytes);
  @override
  int get hashCode => Object.hashAll(bytes);
  @override
  String toString() =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class GroupId {
  GroupId(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (this.bytes.length != 16)
      throw ArgumentError.value(bytes, 'bytes', 'GroupId must be 16 bytes');
  }
  final Uint8List bytes;
  @override
  bool operator ==(Object other) =>
      other is GroupId && _same(bytes, other.bytes);
  @override
  int get hashCode => Object.hashAll(bytes);
}

class GroupMessageId {
  GroupMessageId(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (this.bytes.length != 16)
      throw ArgumentError.value(
          bytes, 'bytes', 'GroupMessageId must be 16 bytes');
  }
  final Uint8List bytes;
  @override
  bool operator ==(Object other) =>
      other is GroupMessageId && _same(bytes, other.bytes);
  @override
  int get hashCode => Object.hashAll(bytes);
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var result = 0;
  for (var i = 0; i < a.length; i++) {
    result |= a[i] ^ b[i];
  }
  return result == 0;
}

enum GroupTrustMode { openTofu, groupPsk32, pairwiseSas, knownPeers }

enum HostTopology { star }

enum DiscoveryMode { tokenScoped, openProximity }

enum DeliveryMode { reliableOrdered, reliableAcked, realtimeLatest }

enum SendPriority { interactive, normal, bulk }

enum GroupState {
  starting,
  discovering,
  forming,
  electing,
  ready,
  migratingCoordinator,
  leaving,
  closed,
  failed
}

enum SendState {
  queued,
  transmitting,
  sentToTransport,
  remoteAcknowledged,
  failed,
  cancelled,
  superseded,
  expired
}

/// Aggregate state of the independent constituent sends of a broadcast.
///
/// A completed broadcast may contain successful and failed constituent sends;
/// it is intentionally not an all-destinations success result.
enum BroadcastState { active, completed, cancelled }

class RuntimeConfig {
  const RuntimeConfig(
      {List<int> serviceUuid = _defaultServiceUuid,
      this.keepaliveIntervalMs = 2000,
      this.reconnectTimeoutMs = 15000,
      this.maxQueuedBytesPerPeer = 262144,
      this.maxQueuedMessagesPerPeer = 1024,
      this.maxApplicationMessageBytes = 1048576})
      : serviceUuid = serviceUuid;
  final List<int> serviceUuid;
  final int keepaliveIntervalMs,
      reconnectTimeoutMs,
      maxQueuedBytesPerPeer,
      maxQueuedMessagesPerPeer,
      maxApplicationMessageBytes;
  void validate() {
    if (serviceUuid.length != 16 ||
        keepaliveIntervalMs < 1000 ||
        keepaliveIntervalMs > 10000 ||
        reconnectTimeoutMs < 1000 ||
        reconnectTimeoutMs > 60000) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'invalid runtime timing configuration');
    }
  }
}

/// Section 33.2 configuration for the advanced explicit-role host API.
class HostConfig {
  HostConfig({
    this.maxPeers = 7,
    this.topology = HostTopology.star,
    List<int> applicationMetadata = const [],
    this.autoAccept = false,
    this.trustMode,
  }) : applicationMetadata = Uint8List.fromList(applicationMetadata) {
    if (maxPeers < 1 || maxPeers > 31 || this.applicationMetadata.length > 31) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'invalid host configuration');
    }
  }

  final int maxPeers;
  final HostTopology topology;
  final Uint8List applicationMetadata;
  final bool autoAccept;
  final GroupTrustMode? trustMode;
}

const _defaultServiceUuid = <int>[
  0x83,
  0xf2,
  0x0a,
  0x00,
  0x8c,
  0x5a,
  0x4f,
  0x5a,
  0x9a,
  0x3a,
  0x2f,
  0x0d,
  0x7a,
  0x96,
  0xb1,
  0x00,
];

class GroupConfig {
  GroupConfig(
      {required List<int> applicationNamespace,
      this.discoveryMode = DiscoveryMode.tokenScoped,
      List<int>? groupJoinToken,
      this.maxPeers = 8,
      this.applicationCoordinatorPriority = 0,
      this.autoAccept = true,
      this.autoMerge = true,
      this.groupTrustMode = GroupTrustMode.openTofu,
      List<int>? groupPsk32,
      Iterable<PeerId> allowedPeerIds = const [],
      this.knownPeersAutoMerge = false,
      this.coordinatorCheckpointing = false})
      : applicationNamespace = Uint8List.fromList(applicationNamespace),
        groupJoinToken =
            groupJoinToken == null ? null : Uint8List.fromList(groupJoinToken),
        groupPsk32 = groupPsk32 == null ? null : Uint8List.fromList(groupPsk32),
        allowedPeerIds = Set.unmodifiable(allowedPeerIds) {
    validate();
  }
  final Uint8List applicationNamespace;
  final DiscoveryMode discoveryMode;
  final Uint8List? groupJoinToken, groupPsk32;
  final int maxPeers, applicationCoordinatorPriority;
  final bool autoAccept,
      autoMerge,
      knownPeersAutoMerge,
      coordinatorCheckpointing;
  final GroupTrustMode groupTrustMode;
  final Set<PeerId> allowedPeerIds;
  void validate() {
    if (applicationNamespace.isEmpty ||
        applicationNamespace.length > 32 ||
        maxPeers < 1 ||
        maxPeers > 31)
      throw const LpcException(
          LpcErrorCode.invalidState, 'invalid group configuration');
    if (discoveryMode == DiscoveryMode.tokenScoped &&
        groupJoinToken?.length != 16)
      throw const LpcException(LpcErrorCode.invalidState,
          'TOKEN_SCOPED requires a 16-byte join token');
    if (discoveryMode == DiscoveryMode.openProximity && groupJoinToken != null)
      throw const LpcException(
          LpcErrorCode.invalidState, 'OPEN_PROXIMITY forbids a join token');
    if (groupTrustMode == GroupTrustMode.groupPsk32 && groupPsk32?.length != 32)
      throw const LpcException(
          LpcErrorCode.invalidState, 'GROUP_PSK_32 requires 32 bytes');
    if (groupTrustMode == GroupTrustMode.knownPeers && allowedPeerIds.isEmpty)
      throw const LpcException(
          LpcErrorCode.invalidState, 'KNOWN_PEERS requires allowed peers');
    if (knownPeersAutoMerge && groupTrustMode != GroupTrustMode.knownPeers)
      throw const LpcException(LpcErrorCode.invalidState,
          'knownPeersAutoMerge requires KNOWN_PEERS');
  }
}

class SendOptions {
  const SendOptions(
      {this.deliveryMode = DeliveryMode.reliableOrdered,
      this.priority = SendPriority.interactive,
      this.expiryMs = 5000});
  final DeliveryMode deliveryMode;
  final SendPriority priority;
  final int expiryMs;
}

class RealtimeOptions {
  const RealtimeOptions({this.expiryMs = 100, this.senderTick = 0});
  final int expiryMs, senderTick;
}

class GroupMember {
  const GroupMember(this.peerId, this.maxPeers);
  final PeerId peerId;
  final int maxPeers;
}

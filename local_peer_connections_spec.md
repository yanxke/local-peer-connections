# Local Peer Connections
## Normative Cross-Platform Offline Proximity Networking Specification

**Specification version:** 0.9.6-coordinator-authority-loss-stale-routing  
**Wire protocol major:** 1  
**Wire protocol minor:** 1  
**Working project name:** `local_peer_connections`

> This document is normative. An implementation claiming conformance MUST implement all MUST requirements for the declared version.  
> The words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as normative requirements.

---

# 1. Scope

Local Peer Connections is a transport-independent nearby networking framework for local peer discovery, secure session establishment, message exchange, reconnection, and transport migration.

The first production targets are Android and iOS.

The protocol and architecture SHALL remain independent from Flutter and Dart so future implementations can target Swift, Kotlin, C, C++, Rust, C#, JavaScript, Python, desktop operating systems, game engines, and embedded systems.

The initial application target is local multiplayer for 2 to 8 nearby phones.

---

# 2. Required User-Visible Behavior

Protocol minor 1 changes the primary application model from explicit host/client selection to an automatically coordinated peer group.

A normal application MUST NOT require the user to choose "Host" or "Client".

Every phone uses the same high-level operation:

```text
runtime = createRuntime(config)
group = runtime.joinOrCreateGroup(groupConfig)
```

The framework then performs:

```text
advertise + scan
        |
        v
discover compatible peers
        |
        v
connect/bootstrap
        |
        v
join or merge local group
        |
        v
automatic coordinator election
        |
        v
automatic star formation
        |
        v
READY
```

A typical user experience is therefore:

```text
Player opens local multiplayer
        |
        v
Nearby players appear automatically
        |
        v
Players join the same local group
        |
        v
Framework selects coordinator automatically
        |
        v
Game starts
```

The application MAY still expose room selection, invitation codes, or explicit grouping UI, but it MUST NOT be required by the transport framework.

If the current coordinator disappears:

```text
coordinator link lost
       |
       v
remaining peers enter coordinator election
       |
       v
new coordinator selected automatically
       |
       v
connections reform automatically
       |
       v
CoordinatorChanged event
       |
       v
group continues
```

No user interaction is required for coordinator migration.

The user SHALL NOT be required to:

- manually pair devices in Bluetooth Settings;
- select which phone is the networking host;
- approve coordinator migration after a coordinator disappears;
- join the same Wi-Fi network for baseline BLE operation;
- know whether GATT, L2CAP, TCP, or UDP is carrying traffic;
- reconnect a gameplay/player object after temporary physical link loss;
- handle BLE MTU fragmentation;
- parse BLE advertisements directly.

The framework MUST support two application delivery classes:

1. **Reliable messages**, for events that must arrive.
2. **Realtime latest-state datagrams**, for latency-sensitive state where old data is less useful than new data.

Realtime datagrams MUST NOT require LPC ACKs, MUST NOT be retransmitted after loss, and MUST allow stale queued state to be replaced by newer state.

---

# 3. Conformance Levels

## 3.1 Core Protocol Conformance

A Core Protocol implementation MUST implement:

- packet framing;
- protocol versioning;
- session state machine;
- peer identity;
- cryptographic handshake;
- message sequencing;
- duplicate suppression;
- keepalive;
- reconnect/resume;
- transport generation and generation-specific traffic keys;
- transport upgrade coordination.

## 3.2 BLE Baseline Conformance

A BLE Baseline implementation MUST implement:

- BLE advertising;
- BLE discovery;
- GATT central/client;
- GATT peripheral/server;
- GATT RX/TX characteristics;
- cross-platform Android/iOS interoperation;
- no required OS-level bonding.

## 3.3 Full V1.1 Mobile Conformance

A product claiming **Full V1.1 Mobile Conformance** MUST implement all of the following:

- Core Protocol Conformance;
- BLE Baseline Conformance;
- protocol major 1, minor 1;
- `GroupSession` and `AUTO_GROUP`;
- automatic group formation and deterministic merge behavior;
- automatic coordinator election;
- coordinator migration/failover;
- `RELIABLE_ORDERED`;
- `RELIABLE_ACKED`;
- `REALTIME_LATEST`;
- reconnect and RESUME;
- Android implementation;
- iOS implementation;
- required diagnostics and conformance events;
- all mandatory protocol-1.1 unit, coordinator, backend, integration, and binary-vector tests applicable to implemented capabilities.

The following remain optional capability extensions unless another conformance profile explicitly requires them:

- BLE L2CAP CoC;
- Wi-Fi LAN TCP transport;
- Wi-Fi LAN UDP realtime sidecar.

A product MUST NOT claim Full V1.1 Mobile Conformance if it omits any required item above.

## 3.4 Minor-1-Only Baseline

This specification intentionally defines no backwards compatibility with any earlier unimplemented protocol draft.

A conforming wire implementation MUST support:

```text
protocol major = 1
protocol minor = 1
```

and MUST NOT claim protocol-minor-0 support.

Protocol minor 1 is the first frozen, implementation-targeted wire baseline for this project.


---

# 4. Protocol Constants and Supported Version Range

The following values are REQUIRED for this specification:

```text
Protocol magic:          ASCII "LPC1"
Protocol major:          1
Current specification minor: 1

Default service UUID:    83F20A00-8C5A-4F5A-9A3A-2F0D7A96B100
RX characteristic UUID:  83F20A01-8C5A-4F5A-9A3A-2F0D7A96B100
TX characteristic UUID:  83F20A02-8C5A-4F5A-9A3A-2F0D7A96B100
Control UUID:            83F20A03-8C5A-4F5A-9A3A-2F0D7A96B100
```

A conforming implementation of this specification MUST advertise this supported version range:

```text
supported_major = 1
min_minor = 1
max_minor = 1
```

This specification defines only protocol major 1, minor 1.

There is no normative protocol-minor-0 wire compatibility requirement.

Minor negotiation machinery remains in the wire format so future protocol-major-1 minor versions can coexist, but an implementation conforming to this specification MUST advertise:

```text
min_minor = 1
max_minor = 1
```

until a later specification explicitly adds another supported minor.

Applications MAY override the service UUID namespace, but both peers MUST use the same configured service UUID.

If overridden:

```text
RX UUID      = service UUID with final byte + 1
TX UUID      = service UUID with final byte + 2
Control UUID = service UUID with final byte + 3
```

If UUID arithmetic is unavailable in a binding, the application MUST provide all four UUIDs explicitly.


# 5. Integer and Byte Encoding

All multibyte integers in the LPC wire protocol MUST use network byte order, big-endian.

Strings MUST use UTF-8.

Boolean values MUST be encoded as:

```text
0x00 = false
0x01 = true
```

No other value is valid for a boolean.

Variable byte arrays MUST be length-prefixed with an unsigned integer specified by the containing structure.

---

# 6. Identifier and Identity Definitions

The protocol distinguishes local discovery handles from wire-visible cryptographic identities.

```text
PeerId:                  16 bytes, wire-visible, derived from identity key
SessionId:               16 bytes, wire-visible
ConnectionId:             8 bytes, local diagnostic identifier only
DiscoveryEndpointId:     opaque binding-local identifier, NOT wire-visible
ConnectionNonce:         16 bytes, wire-visible during HELLO
ResumeNonce:             16 bytes, wire-visible during RESUME
UpgradeId:               16 bytes, wire-visible during transport upgrade
MessageId:     8 bytes, wire-visible identifier for reliable application messages and ACK-required logical control operations
```

`DiscoveryEndpointId` has no fixed binary representation in the wire protocol. A binding MAY represent it as a string, integer, UUID, or opaque object identifier. It is valid only inside the runtime instance that produced it.

`ConnectionId` is generated locally for diagnostics. It is never used to authenticate a peer and is never required to match between peers.

---

## 6.1 GroupMessageId

`GroupMessageId` is a 16-byte wire-visible identifier used only by `GroupSession` routed reliable application operations.

Each `GroupSession` creates:

```text
group_sender_message_prefix = 8 cryptographically random bytes
next_group_message_counter = 1, uint64
```

The prefix and counter are retained for the lifetime of that `GroupSession`, including coordinator migration and pairwise PeerConnection RESUME.

Allocation:

```text
allocated_counter = next_group_message_counter
GroupMessageId =
    group_sender_message_prefix ||
    uint64_be(allocated_counter)
```

After allocating `UINT64_MAX`, the GroupSession MUST NOT allocate another GroupMessageId and MUST fail new reliable group sends with `RESOURCE_EXHAUSTED`.

A new GroupSession creates a fresh random prefix and counter.

`GroupMessageId` is distinct from the 8-byte pairwise LPC `MessageId`.

Pairwise `MessageId` identifies one ACK-required logical operation on one PeerConnection sender direction.

`GroupMessageId` identifies one end-destination group application operation and is preserved while that operation is relayed through the coordinator and across coordinator migration/retry.


---

# 7. Persistent Peer Identity

Each installation MUST maintain an Ed25519 identity key pair.

On first runtime initialization the SDK MUST:

1. load the existing application-scoped Ed25519 private/public key pair if present;
2. otherwise generate a new Ed25519 key pair using a cryptographically secure RNG;
3. persist the private key in application-private secure storage where the platform provides it;
4. compute:

```text
PeerId = first 16 bytes of SHA256(identity_public_key)
```

The identity public key is exactly 32 bytes.

The private key MUST NOT leave the local SDK unless the application explicitly supplies its own cryptographic identity implementation.

The SDK MUST NOT derive identity from:

- Bluetooth MAC address;
- CBPeripheral identifier;
- advertising identifier;
- IP address;
- hostname;
- device serial number;
- local display name.

A remote identity is cryptographically valid only if:

1. its HELLO `peer_id` equals the first 16 bytes of SHA256 of its supplied identity public key; and
2. its AUTH Ed25519 signature verifies against that public key.

This proves continuity/possession of the presented LPC identity key. It does **not**, by itself, prove that a first-seen PeerId belongs to a particular human or expected device. Initial peer trust is defined in Section 16.

---

# 8. BLE Discovery Advertisement

## 8.1 Canonical Cross-Platform Advertisement

The V1 BLE discovery advertisement MUST rely only on the configured 128-bit LPC service UUID.

The canonical Android and iOS advertisement MUST request advertising of:

```text
CBAdvertisementDataServiceUUIDsKey = [configured LPC service UUID]     // iOS concept
service UUID = configured LPC service UUID                            // Android concept
```

A local name MAY also be advertised as a non-authoritative UI hint, but:

- it MUST NOT be required for discovery;
- it MUST NOT contain protocol-critical fields;
- it MUST NOT contain PeerId;
- it MUST NOT contain security material;
- it MAY be truncated or absent;
- applications MUST treat it as unauthenticated.

No V1 requirement depends on manufacturer data, service data, custom AD structures, or scan-response bytes.

This restriction is normative because iOS application advertising through `CBPeripheralManager.startAdvertising` cannot emit arbitrary service-data/manufacturer-data payloads.

## 8.2 Post-Connect Bootstrap

The following fields previously considered advertisement metadata are moved to HELLO after GATT connection:

- PeerId;
- identity public key;
- protocol minor-version range;
- capabilities;
- topology;
- role;
- application metadata;
- connection nonce.

A scanner identifies a candidate LPC endpoint solely because the configured service UUID is advertised/discovered.

## 8.3 DiscoveryEndpointId

When a backend discovers a compatible advertising peripheral, it MUST create or reuse a local `DiscoveryEndpointId` that maps internally to the platform transport object, for example:

```text
Android: ScanResult/BluetoothDevice mapping
iOS: CBPeripheral mapping
```

The application receives this local opaque handle in `EndpointFound`.

The remote device never sees this identifier.

---

# 9. Discovery Deduplication and Loss

A backend MUST deduplicate repeated scan observations referring to the same platform peripheral.

`EndpointFound` MUST be emitted once per active discovery record.

`EndpointUpdated` MAY be emitted when:

- RSSI changes by at least 10 dB;
- local name changes;
- connectability changes;
- backend transport metadata changes.

The SDK MUST NOT claim authenticated PeerId, capabilities, or application metadata before HELLO.

`EndpointLost` SHOULD be emitted when no observation has been received for 5 seconds, subject to platform scan behavior.

A `DiscoveryEndpointId` remains connectable until either:

- the backend determines the physical endpoint is no longer connectable; or
- 5 seconds have elapsed after `EndpointLost`.

After that, `connect()` MUST fail with `ENDPOINT_LOST`.

---

# 10. BLE Physical Roles and Automatic Group Coordination

BLE physical roles and LPC coordinator roles are independent concepts.

```text
BLE role:
    central / peripheral

LPC group role:
    coordinator / member
```

An LPC coordinator MAY be a BLE central for one physical link and BLE peripheral for another. Applications MUST NOT reason about BLE role.

## 10.1 Baseline BLE Connection Rule

For any individual BLE connection:

```text
Advertising device = BLE peripheral / GATT server
Discovering device that invokes connect() = BLE central / GATT client
```

Every group participant MUST advertise and scan concurrently whenever the platform permits.

This allows any pair of phones to establish a bootstrap connection without preassigning host/client roles.

If the platform temporarily cannot advertise and scan simultaneously, the backend MUST time-slice those operations using:

```text
scan window:       1200 ms
advertise window:   800 ms
```

and repeat continuously until connected or stopped.

## 10.2 Duplicate Physical Connections

Because both peers advertise and scan, opposite-direction GATT connections may be created simultaneously.

After authentication, if two physical links connect the same PeerId pair, retain exactly one.

For each link compute:

```text
connection_rank =
    SHA256(
        min(peer_id_A, peer_id_B) ||
        max(peer_id_A, peer_id_B) ||
        min(connection_nonce_A, connection_nonce_B) ||
        max(connection_nonce_A, connection_nonce_B)
    )
```

Retain the link with the lexicographically smaller 32-byte `connection_rank`.

Close the other link with reason `DUPLICATE_CONNECTION`.

This rule is independent of coordinator election.

## 10.3 Primary Group API

All ordinary multi-peer applications MUST use:

```text
joinOrCreateGroup(GroupConfig) -> GroupSession
```

rather than separately choosing host/client roles.

Low-level explicit `createHostSession()` MAY remain available as an advanced compatibility API, but it is NOT the primary V1.1 developer experience.

## 10.4 Group Identifiers

Each newly formed singleton group generates:

```text
GroupId = 16 cryptographically random bytes
```

A peer joining an existing group adopts that GroupId.

If two independently created groups merge, the surviving GroupId MUST be the GroupId of the winning group determined by `GroupMergeRank` in Section 31.5.

Therefore:

1. the group with the larger `committed_member_count` wins;

2. if `committed_member_count` is equal, the lexicographically smaller GroupId wins.

The losing GroupId becomes a historical alias for exactly 30 seconds so authenticated reconnecting members can be redirected to the surviving group.

## 10.5 Coordinator Rank

Every peer has an exact coordinator rank tuple:

```text
CoordinatorRank = (
    applicationCoordinatorPriority uint16,
    coordinatorCapabilityScore uint16,
    PeerId 16 bytes
)
```

Higher tuple wins, compared lexicographically field by field.

Default:

```text
applicationCoordinatorPriority = 0
```

`coordinatorCapabilityScore` is computed exactly:

```text
+8 if LAN_LISTEN capability is available
+4 if L2CAP_LISTEN capability is available
+2 if GATT_PERIPHERAL capability is available
+1 if GATT_CENTRAL capability is available
```

No battery percentage, RSSI, device model, CPU speed, wall clock, or network latency may affect the default rank.

Applications MAY set `applicationCoordinatorPriority` from 0 through 65535 before joining a group. They MUST NOT change it while joined.

## 10.6 Stable Coordinator Rule

A healthy existing coordinator is NOT replaced merely because a newly joined peer has a higher rank.

Election occurs only when:

- the group has no committed coordinator;
- two groups merge and have different coordinators;
- the committed coordinator voluntarily resigns; or
- the committed coordinator is declared unavailable.

This prevents coordinator churn when new players join.

## 10.7 Coordinator Heartbeat

The coordinator MUST broadcast `COORDINATOR_HEARTBEAT` every:

```text
1000 ms
```

Members declare the coordinator unavailable after:

```text
3000 ms
```

without a valid coordinator heartbeat or other authenticated coordinator frame.

Heartbeat frame type:

```text
0x16 COORDINATOR_HEARTBEAT
```

Payload:

```text
16 bytes group_id
8 bytes  coordinator_term uint64
16 bytes coordinator_peer_id
32 bytes committed_membership_hash
```

## 10.8 Canonical GroupMemberRecord and Membership Snapshot

Protocol minor 1 defines one canonical committed membership record used everywhere group membership is serialized or hashed.

```text
GroupMemberRecord {
    peer_id    16 bytes
    max_peers   2 bytes uint16
}
```

Rules:

- records MUST be sorted lexicographically by `peer_id`;
- duplicate `peer_id` values are invalid;
- `max_peers` MUST be in the range 1..31;
- a peer's committed `max_peers` value is the `GroupConfig.maxPeers` value it declared when it joined the group;
- changing `maxPeers` while joined is forbidden; the peer must leave and rejoin.

Canonical committed membership bytes are:

```text
uint16 member_count
member_count * GroupMemberRecord
```

The committed membership hash is:

```text
SHA256(canonical_committed_membership_bytes)
```

The coordinator MUST send an encrypted `MEMBERSHIP_SNAPSHOT` with frame-header `ACK_REQUIRED=1` whenever committed membership changes.

Frame type:

```text
0x17 MEMBERSHIP_SNAPSHOT
```

Payload:

```text
16 bytes group_id
8 bytes  coordinator_term uint64
2 bytes  member_count uint16
N*18     GroupMemberRecord entries sorted by peer_id
32 bytes committed_membership_hash
```

The receiver MUST reject a snapshot if:

- records are not sorted;
- a `peer_id` is duplicated;
- any `max_peers` is outside 1..31;
- payload length does not exactly match `member_count`;
- the transmitted hash does not equal the hash of the canonical membership bytes.

Every member MUST retain the most recently authenticated complete `MEMBERSHIP_SNAPSHOT`.



### 10.8.1 Same-Term Membership Snapshot Ordering

Normal join, leave, kick, and non-coordinator timeout membership changes do not increment `coordinator_term`.

Therefore multiple valid `MEMBERSHIP_SNAPSHOT` operations may exist under the same coordinator term.

Snapshot ordering is scoped to one exact logical-session ordering domain:

```text
MembershipSnapshotOrderState {
    coordinator_peer_id
    coordinator_term
    session_id
    sender_message_prefix
    greatest_accepted_snapshot_counter
}
```

For snapshots from the SAME authenticated coordinator PeerId, SAME `coordinator_term`, and SAME logical `SessionId`:

```text
newer snapshot =
    snapshot with the later MessageId counter value
    from that SessionId's coordinator sender direction
```

The receiver MUST retain `greatest_accepted_snapshot_counter` separately for that exact ordering domain.

If a later snapshot B has already been accepted and committed within the same ordering domain, a subsequently received or retransmitted older snapshot A from that same ordering domain:

- MUST NOT replace committed membership;
- MUST NOT emit stale `MemberJoined` / `MemberLeft` changes;
- MUST be treated as a completed stale ACK-required operation;
- MUST be ACKed if its MessageId requires an ACK and is otherwise valid.

This stale-snapshot suppression applies across successful RESUME because RESUME retains the same logical `SessionId`, `sender_message_prefix`, and MessageId allocation state.

MessageId counters MUST NOT be compared across any of these boundaries:

```text
different SessionId
different sender_message_prefix
different coordinator PeerId
different coordinator_term
```

`SessionId` is the primary logical-session ordering boundary.

The 32-bit `sender_message_prefix` is NOT globally unique and MUST NOT be used by itself to identify the snapshot-ordering domain.

If a previous SessionId expires and a new logical SessionId is established while the same coordinator PeerId and same `coordinator_term` remain:

1. create a new `MembershipSnapshotOrderState` for the new SessionId;
2. initialize `greatest_accepted_snapshot_counter` as undefined;
3. the first valid current `MEMBERSHIP_SNAPSHOT` received from that coordinator establishes the baseline counter for the new SessionId;
4. the receiver MUST NOT reject that snapshot merely because its MessageId counter is numerically lower than a counter accepted under an earlier SessionId.

This rule applies even if the new SessionId happens to generate the same 32-bit `sender_message_prefix` bytes as an earlier expired SessionId.

If coordinator PeerId or `coordinator_term` changes, ordering is governed by coordinator-election/reconciliation rules and a new snapshot-ordering domain is established.

This rule provides same-term monotonic membership state without adding a separate wire-visible `membership_revision`.

## 10.9 Automatic Election

When the coordinator is unavailable, every remaining member enters `ELECTING`.

Election uses a bully-style deterministic procedure.

1. Set:

```text
candidate_term = last_committed_term + 1
```

2. Enable discovery and advertising immediately.
3. Establish bootstrap links to reachable known members.
4. For 1200 ms, exchange `ELECTION_ANNOUNCE`.
5. Each peer computes the highest CoordinatorRank it has observed for the candidate term.
6. A peer whose own rank is currently highest sends `COORDINATOR_CLAIM`.
7. A peer receiving a claim from a lower-ranked candidate responds with its own `ELECTION_ANNOUNCE`.
8. A candidate becomes coordinator only after 500 ms passes without observing a higher-ranked candidate for the same or higher term.
9. It then emits three `COORDINATOR_HEARTBEAT` frames 100 ms apart.
10. Other peers adopt that coordinator when the claim/heartbeat is authenticated and no higher-ranked candidate is known for that term.

Frame types:

```text
0x18 ELECTION_ANNOUNCE
0x19 COORDINATOR_CLAIM
0x1A COORDINATOR_RESIGN
```

`ELECTION_ANNOUNCE` payload:

```text
16 bytes group_id
8 bytes  candidate_term
2 bytes  application_coordinator_priority
2 bytes  coordinator_capability_score
16 bytes candidate_peer_id
32 bytes last_committed_membership_hash
```

`COORDINATOR_CLAIM` has the identical payload.

`COORDINATOR_RESIGN` payload:

```text
16 bytes group_id
8 bytes  current_term
16 bytes resigning_peer_id
```

All election frames are encrypted/authenticated LPC control frames.

## 10.10 Split-Brain Detection and Membership Reconciliation

If a peer observes two coordinators for the same GroupId:

1. higher coordinator term wins;
2. if terms are equal, higher CoordinatorRank wins.

The losing coordinator MUST immediately stop acting as coordinator.

This includes coordinator-authoritative application routing. Every unfinished admitted application relay owned by the losing coordinator MUST be terminated according to Section 43. The losing coordinator MUST NOT continue `GROUP_RELIABLE` or `GROUP_REALTIME_DATAGRAM` submission merely because the relay was admitted before election/reconciliation completed.

If the two coordinator views have different committed membership hashes, coordinator selection alone is insufficient. The winning coordinator MUST perform membership reconciliation before publishing the next stable heartbeat.

Let:

```text
term_A
term_B
snapshot_A
snapshot_B
```

be the authenticated coordinator terms and last-committed membership snapshots from the two sides.

The reconciliation term is:

```text
reconciliation_term = max(term_A, term_B) + 1
```

The candidate reconciled membership is constructed from the union of authenticated `GroupMemberRecord` values in snapshot_A, snapshot_B, and currently reachable same-GroupId peers.

If two authenticated committed records for the same `peer_id` disagree on `max_peers`, reconciliation MUST collapse them to one record:

```text
reconciled.max_peers =
    min(record_A.max_peers, record_B.max_peers, ...all authenticated conflicting records)
```

The minimum is deliberately conservative because `max_peers` is a capacity/resource constraint.

A currently reachable peer MUST NOT overwrite that conservative reconciled value merely by presenting a larger local `maxPeers` while it remains part of the same joined incarnation. To establish a different value, the peer MUST leave and later rejoin after the conflicting stale membership has been resolved.

For currently reachable authenticated peers absent from both snapshots, use the `max_peers` value from their current GroupMemberRecord admission request.

Before committing that union, the coordinator MUST apply the effective group capacity rules in Section 31.

Peers that appear in the union but are currently unreachable MAY remain in the first reconciliation snapshot for a 5000 ms grace period.

After that grace period, the coordinator MUST publish a second MEMBERSHIP_SNAPSHOT excluding peers that failed to establish or resume an authenticated connection.

The winning coordinator MUST:

1. adopt `reconciliation_term`;
2. publish an ACK-required MEMBERSHIP_SNAPSHOT with the reconciled set;
3. emit COORDINATOR_HEARTBEAT containing the new membership hash;
4. rebuild the coordinator star.

The losing coordinator MUST transition to MEMBER and MUST NOT issue coordinator-authoritative application commands after accepting the higher term or winning rank.

A stale membership snapshot from a lower term MUST be ignored.


## 10.11 Coordinator Migration Topology

After coordinator election:

- new coordinator advertises and scans;
- every member establishes or retains one direct authenticated session with the new coordinator;
- old member-to-member bootstrap/election links MAY be closed after the coordinator star is READY;
- migration MUST NOT create new application PeerIds;
- GroupId remains unchanged except during an explicit group merge.

The framework emits:

```text
CoordinatorChanged {
    groupId
    term
    oldCoordinatorPeerId optional
    newCoordinatorPeerId
    localIsCoordinator
}
```

## 10.12 Application State Migration

The networking framework can automatically migrate the coordinator role and transport topology, but it cannot infer arbitrary game simulation state.

To make game migration low-friction, `GroupSession` MUST provide an optional replicated coordinator checkpoint facility:

```text
publishCoordinatorCheckpoint(bytes)
latestCoordinatorCheckpoint()
```

Constraints:

```text
maximum checkpoint size: 262144 bytes
maximum accepted publish rate: 4 per second
wire delivery: ACK_REQUIRED checkpoint operation
replication queue per target: 1 in-flight + 1 replaceable pending
```

The framework retains the most recently published checkpoint and replicates checkpoint state to READY members using the bounded latest-pending policy defined in Section 31.

Publishing faster than transport throughput MUST NOT create an unbounded checkpoint backlog.

When a local peer becomes coordinator, `CoordinatorChanged` MUST include the most recent fully received checkpoint, if any.

Applications that do not require authoritative application-state migration MAY ignore this facility.


# 11. GATT Service Definition

The peripheral/server MUST expose exactly one primary LPC service.

Required characteristics:

## 11.1 RX

Properties:

```text
Write
Write Without Response
```

Permissions:

```text
Readable: no
Writable: yes
Encryption-required: no
Authentication-required: no
```

## 11.2 TX

Properties:

```text
Notify
Indicate optional
```

Permissions:

```text
Readable: no
Writable: no
Encryption-required: no
Authentication-required: no
```

## 11.3 CONTROL

Properties:

```text
Read
Write
Notify
```

CONTROL MAY be unused after initial LPC protocol negotiation, but MUST exist for protocol-major-1 BLE Baseline Conformance.

OS-level BLE bonding MUST NOT be required.

Security is provided by the LPC session protocol.

---

# 12. GATT Fragmentation

LPC frames are serialized over GATT as an ordered sequence of GATT fragments.

V1 MUST NOT interleave fragments belonging to different LPC frames on the same direction. Control frames may be interleaved between large application **message chunks** because large application messages are divided into multiple bounded LPC DATA frames as defined in Section 21.

Each GATT write/notification fragment MUST use:

```text
Offset  Size  Field
0       4     fragment_sequence uint32
4       1     flags
5       2     fragment_payload_length uint16
7       N     fragment_payload
```

Flags:

```text
bit 0 START
bit 1 END
bits 2-7 reserved, MUST be zero
```

Rules:

- `fragment_sequence` starts at 0 for each LPC frame;
- first fragment MUST set START;
- final fragment MUST set END;
- one-fragment frame MUST set START|END;
- sequence MUST increment by exactly 1;
- a missing, repeated with conflicting bytes, or out-of-order fragment invalidates the current frame;
- incomplete frame reassembly MUST be discarded after 2 seconds of no fragment progress.

Maximum fragment payload is:

```text
min(platform_safe_write_size - 7, 512)
```

If `platform_safe_write_size <= 7`, the transport is unusable and MUST fail with `RESOURCE_EXHAUSTED`.

The 32-bit fragment sequence makes every valid V1 LPC frame representable even on minimum-MTU links.

# 13. LPC Frame Format and Size Limits

Every LPC frame after physical transport establishment uses:

```text
Offset  Size  Field
0       4     ASCII "LPC1"
4       1     protocol_major
5       1     protocol_minor
6       1     frame_type
7       1     flags
8       2     header_length
10      4     encrypted_payload_length
14      4     transport_generation
18      8     sequence_number
26      8     message_id
34      16    session_id
50      12    nonce
62      N     encrypted_or_plain_payload
62+N    16    AEAD tag, encrypted frames only
```

`header_length` MUST equal 62 in protocol 1.x.


## 13.1 Frame Flags

The frame-header `flags` byte has this exact meaning:

```text
bit 0 ACK_REQUIRED
bits 1-7 reserved = 0
```

`ACK_REQUIRED` means the logical frame/message participates in LPC generic MessageId acknowledgment, retransmission, duplicate suppression, and RESUME retention.

Rules:

- `ACK_REQUIRED` MAY be set only on encrypted frames.
- HELLO and AUTH MUST have flags = 0.
- ACK frames MUST have flags = 0.
- A frame with any reserved flag bit set MUST be rejected with `PROTOCOL_MISMATCH`.
- For `DATA`, `ACK_REQUIRED` MUST be set if and only if `delivery_mode = RELIABLE_ACKED`.
- For `DATA` with `delivery_mode = RELIABLE_ORDERED`, `ACK_REQUIRED` MUST be clear.
- For `REALTIME_DATAGRAM`, `ACK_REQUIRED` MUST be clear.
- For `GROUP_RELIABLE`, `ACK_REQUIRED` MUST be set if and only if the embedded group delivery mode is `RELIABLE_ACKED`.
- For `GROUP_RELIABLE` with embedded delivery mode `RELIABLE_ORDERED`, `ACK_REQUIRED` MUST be clear.
- For `GROUP_REALTIME_DATAGRAM`, `ACK_REQUIRED` MUST be clear.
- `GROUP_DELIVERY_ACK` and `GROUP_RELAY_STATUS` MUST set `ACK_REQUIRED` because they are critical hop-local control operations.
- For an ACK-required non-DATA control frame, the sender MUST allocate a MessageId according to Section 19.
- For a non-ACK-required control frame, header `message_id` MUST be all zero.

Protocol minor 1 defines the following control frames as ACK-required:

```text
MEMBERSHIP_SNAPSHOT
GROUP_MERGE
COORDINATOR_CHECKPOINT
GROUP_LEAVE
GROUP_DELIVERY_ACK
GROUP_RELAY_STATUS
```

These frame types MUST always set `ACK_REQUIRED`.

All other protocol-minor-1 control frames MUST leave `ACK_REQUIRED` clear unless a future negotiated minor explicitly changes their semantics.


Limits:

```text
Maximum application message:             1,048,576 bytes
Maximum encrypted plaintext per frame:      16,384 bytes
Maximum control-frame plaintext:              4,096 bytes
Maximum DATA chunk bytes:                    16,364 bytes
Maximum GROUP_RELIABLE chunk bytes:          16,300 bytes
```

The application message maximum and LPC frame maximum are deliberately different.

A 1 MiB application message is split into multiple DATA frames. No single 1 MiB LPC frame is permitted.

The parser MUST reject an encrypted payload length greater than 16,384 before allocating the claimed payload.

---

# 14. Frame Types

Exact protocol-major-1 frame values:

```text
0x01 HELLO
0x02 AUTH
0x03 READY
0x04 PING
0x05 PONG
0x06 DATA
0x07 ACK
0x08 RESUME_REQUEST
0x09 RESUME_ACCEPT
0x0A RESUME_REJECT
0x0B RESUME_READY
0x0C CAPS
0x0D UPGRADE_OFFER
0x0E UPGRADE_ACCEPT
0x0F UPGRADE_REJECT
0x10 UPGRADE_BIND
0x11 UPGRADE_BIND_ACK
0x12 SWITCH_COMMIT
0x13 SWITCH_ACK
0x14 CLOSE
0x15 ERROR
0x16 COORDINATOR_HEARTBEAT       // protocol minor >= 1
0x17 MEMBERSHIP_SNAPSHOT          // protocol minor >= 1
0x18 ELECTION_ANNOUNCE            // protocol minor >= 1
0x19 COORDINATOR_CLAIM            // protocol minor >= 1
0x1A COORDINATOR_RESIGN           // protocol minor >= 1
0x1B REALTIME_DATAGRAM            // protocol minor >= 1
0x1C GROUP_INFO                   // protocol minor >= 1
0x1D GROUP_MERGE                  // protocol minor >= 1
0x1E COORDINATOR_CHECKPOINT       // protocol minor >= 1
0x1F UDP_OFFER                    // protocol minor >= 1
0x20 UDP_ACCEPT                   // protocol minor >= 1
0x21 UDP_CLOSE                    // protocol minor >= 1
0x22 GROUP_MERGE_REJECT           // protocol minor >= 1
0x23 GROUP_LEAVE                  // protocol minor >= 1
0x24 GROUP_RELIABLE               // protocol minor >= 1
0x25 GROUP_REALTIME_DATAGRAM      // protocol minor >= 1
0x26 GROUP_DELIVERY_ACK           // protocol minor >= 1
0x27 GROUP_RELAY_STATUS           // protocol minor >= 1
```

A sender MUST NOT transmit a frame type introduced after the negotiated minor version.

For negotiated minor 1, valid reliable-stream frame types are 0x01 through 0x27.

This specification does not define protocol-minor-0 frame semantics.

A frame type invalid for negotiated minor 1 MUST cause encrypted ERROR `UNSUPPORTED_FRAME_TYPE`, followed by connection close.

---

# 15. Cryptographic Primitives

Protocol major 1 MUST use:

```text
Persistent identity signature: Ed25519
Ephemeral key agreement:       X25519
Hash:                          SHA-256
MAC:                           HMAC-SHA256
KDF:                           HKDF-SHA256
AEAD:                          ChaCha20-Poly1305
Random source:                 platform cryptographic RNG
```

Substitution of AES-GCM or another AEAD is not wire-compatible with protocol major 1.

The implementation MUST pass published binary cryptographic test vectors.

---

# 16. Initial Handshake, Identity Authentication, and Trust

HELLO, AUTH, and the pre-key `ERROR(PROTOCOL_MISMATCH)` defined in Section 16.2 are the only LPC frames permitted in plaintext.

For HELLO and AUTH, the frame header MUST use:

```text
transport_generation = 0
sequence_number = 0
message_id = all zero
session_id = all zero
nonce = all zero
AEAD tag = omitted
```

Their `encrypted_payload_length` field contains the plaintext HELLO/AUTH payload length.

No other frame type may be sent plaintext. All ERROR frames other than the specific pre-key `PROTOCOL_MISMATCH` case in Section 16.2 MUST be encrypted.

## 16.1 Security Levels

V1 defines four explicit pairwise trust modes:

```text
0x01 KNOWN_PEER
0x02 SAS
0x03 PSK_32
0x04 TOFU
```

`TOFU` provides encrypted transport and cryptographic continuity of the presented identity key, but does not authenticate a first-seen peer to a human/device expectation.

The SDK MUST expose the resulting security level:

```text
AUTHENTICATED_KNOWN_PEER
AUTHENTICATED_SAS
AUTHENTICATED_PSK
ENCRYPTED_TOFU
```

Documentation and events MUST NOT describe `ENCRYPTED_TOFU` as authenticated peer identity on first contact.

Default V1 trust mode for connections initiated without an already-known PeerId or out-of-band secret is `SAS`.

A low-entropy room code MUST NOT be passed as `PSK_32`.

`PSK_32` requires exactly 32 cryptographically random bytes, normally transferred through QR code, deep link, NFC, or another authenticated/out-of-band channel.

## 16.2 Version Negotiation

HELLO declares:

```text
supported_major = 1
min_minor
max_minor
```

A conforming implementation of this specification MUST send:

```text
supported_major = 1
min_minor = 1
max_minor = 1
```

The generic negotiation algorithm remains:

```text
negotiated_minor =
    min(local_max_minor, remote_max_minor)
```

Connection succeeds only if:

```text
local_supported_major == remote_supported_major == 1

and

negotiated_minor >= max(local_min_minor, remote_min_minor)
```

For this specification, that means a successful connection MUST negotiate:

```text
negotiated_minor = 1
```

If the ranges do not intersect, send the exact pre-key plaintext `ERROR(PROTOCOL_MISMATCH)` defined below, then close the physical connection.

All frames after AUTH MUST set:

```text
protocol_minor = negotiated_minor
```

HELLO and AUTH headers use the sender's `max_minor`.

A conforming implementation MUST NOT attempt to encode, decode, or emulate protocol-minor-0 DATA/control semantics.

A peer advertising:

```text
max_minor = 0
```

has no compatible minor version with this specification and MUST fail version negotiation with `PROTOCOL_MISMATCH`.

### 16.2.1 Pre-Key ERROR(PROTOCOL_MISMATCH)

This plaintext ERROR is permitted only when all of the following are true:

1. both HELLO payloads have been received and parsed;
2. protocol major is compatible enough to parse the v1 HELLO structure;
3. the advertised minor-version ranges have no intersection;
4. AUTH/session-key establishment has not begun.

The frame MUST use:

```text
frame_type             = ERROR (0x15)
flags                  = 0
protocol_major         = 1
protocol_minor         = sender max_minor
header_length          = 62
transport_generation   = 0
sequence_number        = 0
message_id             = 0x0000000000000000
session_id             = 16 zero bytes
nonce                  = 12 zero bytes
AEAD tag               = omitted
```

The payload MUST use the normal ERROR payload encoding:

```text
uint16 error_code = 0x000A
uint16 message_length
N bytes UTF-8 diagnostic message
```

For this plaintext ERROR frame:

```text
encrypted_payload_length = 4 + message_length
```

As with plaintext HELLO and AUTH, `encrypted_payload_length` contains the plaintext payload length.

The diagnostic message MAY have zero length.

This plaintext ERROR is valid only in the pre-key version-negotiation state described above.

A plaintext ERROR received after AUTH/session-key establishment, or a plaintext ERROR carrying any error code other than `PROTOCOL_MISMATCH`, MUST cause the physical connection to close with local `PROTOCOL_MISMATCH`.

After sending the pre-key `ERROR(PROTOCOL_MISMATCH)`, the sender MUST close the physical connection and MUST NOT send AUTH or any encrypted LPC frame on that connection.

## 16.3 HELLO Payload

Exact payload:

```text
Offset  Size  Field
0       16    peer_id
16      32    identity_ed25519_public_key
48      32    ephemeral_x25519_public_key
80      16    connection_nonce
96      4     peer_capability_bitmap
100     1     min_minor
101     1     max_minor
102     1     topology
103     1     role
104     1     trust_mode
105     1     application_metadata_length N, 0..31
106     2     keepalive_interval_ms uint16, 1000..10000
108     4     max_application_message_bytes
112     N     application_metadata
```

Topology:

```text
0x01 POINT_TO_POINT
0x02 EXPLICIT_STAR        // legacy/advanced API
0x03 AUTO_GROUP           // protocol minor >= 1
```

Role:

```text
0x01 HOST                 // explicit-star API only
0x02 CLIENT               // explicit-star API only
0x03 PEER                 // point-to-point or AUTO_GROUP bootstrap
```

A `GroupSession` MUST send:

```text
topology = AUTO_GROUP
role = PEER
```

until a coordinator has been elected. Coordinator status is NOT encoded as a BLE role and is NOT carried in HELLO.

HELLO MUST verify:

```text
peer_id == first 16 bytes SHA256(identity_ed25519_public_key)
```

Failure closes with `AUTHENTICATION_FAILED`.

`keepalive_interval_ms` is the sender's configured local keepalive interval.
It is authenticated by the HELLO transcript. After both HELLO payloads are
parsed, both peers compute exactly:

```text
negotiated_keepalive_interval =
    max(local HELLO keepalive_interval_ms,
        remote HELLO keepalive_interval_ms)

keepalive_dead_timeout =
    max(6000, 3 * negotiated_keepalive_interval)
```

Both subsequent READY payloads MUST carry those same two derived values. This
HELLO field is the only keepalive-configuration negotiation mechanism in
protocol minor 1.

## 16.4 Peer Capability Bitmap

The HELLO `peer_capability_bitmap` is the `PeerCapabilityBitmap` defined normatively in Section 49.

For protocol minor 1, bits 0 through 8 are defined.

Bits 9 through 31 are reserved and MUST be zero.

Protocol minor 0 capability semantics are not defined by this specification.

This wire bitmap MUST NOT be confused with `LocalRuntimeCapabilityBitmap`.

The negotiated peer capability bitmap carried by READY is exactly:

```text
local_hello.peer_capability_bitmap & remote_hello.peer_capability_bitmap
```

## 16.5 Transcript

Let `H_A` and `H_B` be the complete HELLO payload bytes exactly as transmitted.

Canonical transcript bytes:

```text
if H_A < H_B lexicographically:
    hello_pair = H_A || H_B
else:
    hello_pair = H_B || H_A

T = SHA256(
    ASCII "LPC1-transcript" ||
    configured_service_uuid_16_bytes ||
    hello_pair
)
```

## 16.6 Ephemeral Shared Secret

Each peer computes:

```text
DH = X25519(local_ephemeral_private, remote_ephemeral_public)
```

If X25519 reports an invalid/all-zero shared secret, authentication fails.

## 16.7 Base Root Key

For KNOWN_PEER, SAS, and TOFU:

```text
base_root_key = HKDF-SHA256(
    IKM = DH,
    salt = T,
    info = ASCII "LPC1-base-root",
    L = 32
)
```

For PSK_32:

```text
psk_salt = HMAC-SHA256(
    key = PSK_32,
    data = ASCII "LPC1-psk" || T
)

base_root_key = HKDF-SHA256(
    IKM = DH,
    salt = psk_salt,
    info = ASCII "LPC1-base-root",
    L = 32
)
```

Both peers MUST use the same trust mode. Mismatch fails with `AUTHENTICATION_FAILED`.

## 16.8 AUTH Identity Signature

AUTH plaintext payload is exactly 64 bytes:

```text
Ed25519.Sign(
    local_identity_private_key,
    SHA256(ASCII "LPC1-auth" || T)
)
```

The receiver MUST verify using the identity public key in remote HELLO.

AUTH therefore proves possession of the private key corresponding to the presented PeerId.

## 16.9 KNOWN_PEER Trust

When `trust_mode = KNOWN_PEER`, each local side MUST configure exactly one `KnownPeerPolicy`:

```text
0x01 EXPECT_EXACT_PEER
0x02 ALLOWLIST
```

### 16.9.1 EXPECT_EXACT_PEER

Configuration:

```text
expectedPeerId: exactly 16 bytes
```

After remote HELLO is parsed and the remote AUTH signature verifies:

```text
remote_peer_id MUST equal expectedPeerId
```

Otherwise authentication fails with `AUTHENTICATION_FAILED`.

This is the default policy for low-level explicit `connect()` when the application already knows which logical PeerId it expects.

### 16.9.2 ALLOWLIST

Configuration:

```text
allowedPeerIds: non-empty set of 16-byte PeerIds
```

After remote HELLO is parsed and the remote AUTH signature verifies:

```text
remote_peer_id MUST be contained in allowedPeerIds
```

Otherwise authentication fails with `AUTHENTICATION_FAILED`.

This policy is REQUIRED for `GroupSession` when:

```text
GroupTrustMode = KNOWN_PEERS
```

because service-UUID-only discovery does not reveal PeerId before HELLO.

### 16.9.3 Policy Rules

- `EXPECTED_EXACT_PEER` and `ALLOWLIST` MUST NOT both be configured for one local connection attempt.
- An empty allowlist is invalid.
- PeerId comparison occurs only after the Ed25519 AUTH signature validates the identity public key presented in HELLO.
- The trust decision is local. The two peers may have different exact/allowlist policy shapes, but both must encode HELLO `trust_mode = KNOWN_PEER`.

## 16.10 SAS Trust

For `trust_mode = SAS`, after both AUTH signatures verify:

```text
sas_material = HMAC-SHA256(
    key = base_root_key,
    data = ASCII "LPC1-sas" || T
)

sas_number =
    uint32_big_endian(sas_material[0..3]) mod 1,000,000
```

Display as exactly six decimal digits with leading zeroes.

Example:

```text
004271
```

Both peers MUST emit:

```text
PeerVerificationRequired(peerId, sixDigitSas)
```

No READY may be sent until the local application calls:

```text
confirmPeerVerification(peerId, true)
```

If the user rejects or verification is not confirmed within 30 seconds, close with `AUTHENTICATION_FAILED`.

The application UI MUST instruct users to compare the six-digit value on both devices.

## 16.11 TOFU Trust

For TOFU:

- first connection stores remote `PeerId -> identity_public_key`;
- future connections claiming the same PeerId MUST present the identical identity key;
- a change MUST fail as `AUTHENTICATION_FAILED`.

TOFU does not protect the very first contact from an active MITM and MUST be labeled accordingly.

## 16.12 Initial Session Root and SessionId

After AUTH and any required trust verification:

```text
session_root_key = HKDF-SHA256(
    IKM = base_root_key,
    salt = T,
    info = ASCII "LPC1-session-root",
    L = 32
)

resume_secret = HKDF-SHA256(
    IKM = session_root_key,
    salt = zero-length,
    info = ASCII "LPC1-resume-secret",
    L = 32
)

session_id = first 16 bytes SHA256(
    ASCII "LPC1-session-id" ||
    T ||
    session_root_key
)
```

SessionId is deterministic for this handshake. It is NOT independently random.

## 16.13 Generation-Specific Traffic Keys

For transport generation `G` and direction label `D`:

```text
traffic_key(G,D) = HKDF-SHA256(
    IKM = session_root_key,
    salt = zero-length,
    info =
        ASCII "LPC1-traffic" ||
        uint32_be(G) ||
        D,
    L = 32
)
```

Direction labels:

```text
0x00 = lexicographically smaller PeerId -> larger PeerId
0x01 = lexicographically larger PeerId -> smaller PeerId
```

Initial active transport generation is 1.

## 16.14 READY

READY is the first encrypted frame under generation 1.

READY payload:

```text
Offset Size Field
0      16   session_id
16     4    negotiated_peer_capabilities
20     4    keepalive_interval_ms
24     4    keepalive_dead_timeout_ms
28     1    security_level
29     3    reserved = 0
```

Session becomes READY only after local READY is sent and remote READY is authenticated.

The READY payload MUST equal the authenticated handshake agreement:

- `session_id` equals the Section 16.12 derived SessionId;
- `negotiated_peer_capabilities` is the Section 16.4 bitwise intersection;
- `keepalive_interval_ms` and `keepalive_dead_timeout_ms` are the values
  derived from the two HELLO payloads above; and
- `security_level` maps exactly from the mutually encoded HELLO `trust_mode`.

# 17. AEAD Nonce and Associated Data

For encrypted session frames, ChaCha20-Poly1305 nonce is exactly:

```text
uint32_be(transport_generation) ||
uint64_be(sequence_number)
```

The 12-byte nonce field in the frame header MUST contain exactly those bytes.

Associated data is frame header bytes 0 through 49 inclusive.

The payload alone is encrypted.

The sender MUST never reuse a `(traffic_key, nonce)` pair.

Candidate reconnect control defined in Section 26 uses separate candidate traffic keys and generation 0.

---

# 18. Wire Sequence Numbers

Wire sequence numbers are scoped to one direction and one transport generation.

Rules:

```text
first encrypted frame in a generation = 1
next frame = previous + 1
```

When transport generation increments, both directional sequence counters reset to 1 because generation-specific keys are different.

Receiver maintains a highest-seen sequence for the active generation.

Exact behavior:

- sequence equal to an already accepted sequence: discard as replay;
- sequence lower than highest accepted: discard as replay;
- sequence greater than highest + 1024: close with `SEQUENCE_WINDOW_EXCEEDED`;
- otherwise buffer out-of-order frames only if the underlying backend can reorder;
- application DATA delivery remains ordered by accepted frame sequence.

GATT, L2CAP stream, and TCP backends are required to expose ordered bytes, so normal V1 operation receives sequence numbers monotonically.

---

# 19. MessageId and Generic ACK-Required Units

Each READY session creates one 4-byte random `sender_message_prefix` per direction.

It is retained across RESUME for the lifetime of the SessionId.

Each direction maintains one uint32 `next_message_counter`.

Initialization:

```text
next_message_counter = 1
```

A new MessageId MUST be allocated for:

1. every point-to-point DATA reliable message accepted by `send()`, whether `RELIABLE_ORDERED` or `RELIABLE_ACKED`;
2. every physical-hop `GROUP_RELIABLE` logical operation, whether embedded mode is `RELIABLE_ORDERED` or `RELIABLE_ACKED`; and
3. every ACK-required non-DATA logical control operation.

Allocation is exactly:

```text
allocated_counter = next_message_counter
message_id = sender_message_prefix || uint32_be(allocated_counter)

if next_message_counter == UINT32_MAX:
    message_counter_exhausted = true
else:
    next_message_counter += 1
```

Therefore the first allocated MessageId uses counter value `1`.

After allocating counter value `UINT32_MAX`, no further MessageId may be allocated within that SessionId.

A new logical SessionId MUST be established before another MessageId-bearing operation is created.

For DATA:

- every chunk of one application message uses the same MessageId;
- different application messages MUST use different MessageIds.

For GROUP_RELIABLE:

- every chunk belonging to one physical-hop relay operation uses the same pairwise MessageId;
- source->coordinator and coordinator->destination hops allocate independent pairwise MessageIds;
- RELIABLE_ORDERED still allocates this MessageId for chunk grouping/diagnostics even though ACK_REQUIRED is clear;
- the pairwise MessageId is distinct from the stable end-destination GroupMessageId carried inside the GROUP_RELIABLE payload.

For an ACK-required control operation:

- the complete logical operation uses one MessageId;
- a multi-frame logical operation such as a chunked coordinator checkpoint uses that same MessageId on every constituent frame;
- retransmissions retain the same MessageId;
- every transmitted frame receives a new reliable wire `sequence_number`.

For a non-ACK-required control frame:

```text
message_id = 0x0000000000000000
```

An ACK payload refers to exactly one logical MessageId-bearing operation.

MessageId uniqueness is per sender direction for the lifetime of the SessionId.

---

# 20. Application Delivery Modes and DATA Framing

Protocol minor 1 defines three delivery modes.

```text
0x01 RELIABLE_ORDERED
0x02 RELIABLE_ACKED
0x03 REALTIME_LATEST
```

`DeliveryMode` is the only normative public delivery selector in this specification. No earlier `requireRemoteAck` wire/API compatibility is required.

## 20.1 RELIABLE_ORDERED

Use for:

- chat messages;
- noncritical events;
- lobby updates;
- commands where transport-level reliable delivery is sufficient.

Semantics:

- ordered relative to other RELIABLE_ORDERED and RELIABLE_ACKED sends on the same PeerConnection;
- no LPC ACK;
- no application-level retransmission after `SENT_TO_TRANSPORT`;
- may be chunked;
- may survive queueing while temporarily RECONNECTING if transmission has not begun.

## 20.2 RELIABLE_ACKED

Use for:

- critical game events;
- membership changes;
- coordinator checkpoints;
- purchases/transactions in applications;
- state transitions that must survive reconnect.

Semantics:

- ordered;
- LPC ACK required;
- deterministic retransmission;
- duplicate suppression;
- exactly-once SDK delivery across successful RESUME within deduplication limits.

## 20.3 REALTIME_LATEST

Use for:

- player transform/state snapshots;
- joystick state;
- aim direction;
- camera pose;
- velocity;
- rapidly superseded sensor/game state.

Semantics:

- NO LPC ACK;
- NO LPC retransmission;
- NO retransmission after reconnect;
- gaps are allowed;
- older datagrams may be dropped;
- receiver only delivers datagrams newer than the last delivered sequence for that realtime channel;
- queued older state for the same channel is replaced by newer state before transmission begins;
- application must tolerate loss;
- application must periodically resend the current state if continued visibility is required.

This provides UDP-like application semantics even when the physical BLE/L2CAP transport itself performs lower-layer reliability.

It is NOT a claim that BLE becomes physically unreliable like IP UDP.

---

# 21. Reliable Application Message Chunking

Maximum reliable application payload:

```text
1,048,576 bytes
```

`RELIABLE_ORDERED` and `RELIABLE_ACKED` messages use frame type:

```text
0x06 DATA
```

DATA plaintext payload:

```text
Offset Size Field
0      1    delivery_mode
1      1    priority
2      2    chunk_index uint16
4      2    chunk_count uint16
6      2    reserved = 0
8      4    total_application_length uint32
12     4    chunk_offset uint32
16     2    chunk_length uint16
18     2    reserved = 0
20     N    chunk_bytes
```

`delivery_mode` MUST be:

```text
0x01 RELIABLE_ORDERED
0x02 RELIABLE_ACKED
```

Maximum `chunk_bytes`:

```text
16,364 bytes
```

Rules:

- `chunk_count = ceil(total_application_length / 16364)`;
- `chunk_index` is zero-based;
- `chunk_offset = chunk_index * 16364`;
- all chunks except final MUST have `chunk_length = 16364`;
- final chunk length is remaining bytes;
- all chunks use one MessageId;
- chunks transmit in increasing chunk_index;
- SDK control and REALTIME_LATEST frames MAY interleave between reliable DATA chunks;
- a later reliable application message MUST NOT overtake an earlier reliable application message.

Incomplete reliable-message reassembly is discarded after 10 seconds without a new valid chunk.

Priority values:

```text
1 INTERACTIVE
2 NORMAL
3 BULK
```

---

## 21.1 Incomplete DATA Reassembly and Transport-Generation Loss

Incomplete multi-frame DATA reassembly MUST NOT survive loss of the physical transport generation.

If transport loss occurs before a `RELIABLE_ORDERED` or `RELIABLE_ACKED` application message has been completely reassembled:

```text
receiver MUST discard all incomplete DATA reassembly state
for that MessageId
```

Discarded state includes:

- received chunk bitmap;
- partial application-payload buffer;
- chunk metadata;
- incomplete-message reassembly timer.

Completed MessageId deduplication state is retained according to the delivery mode and Section 23.

Pre-disconnect partial DATA chunks MUST NOT be combined with post-RESUME retransmitted chunks.

## 21.2 RELIABLE_ORDERED Partial Transmission Recovery

For one `RELIABLE_ORDERED` logical application message:

```text
if every DATA chunk reached frame-level SENT_TO_TRANSPORT
before transport loss:
    the logical message is considered fully transport-submitted;
    it MUST NOT be retransmitted automatically after RESUME

if one or more DATA chunks did NOT reach frame-level SENT_TO_TRANSPORT
before transport loss:
    after successful RESUME, retransmit the ENTIRE logical
    application message starting from chunk 0
```

The retransmission MUST use:

```text
same MessageId
identical application payload
identical DATA chunking parameters
fresh reliable wire sequence numbers
new transport generation
```

The sender MUST NOT resume from only the first unsent chunk.

The receiver starts fresh reassembly from chunk 0 because incomplete pre-loss DATA reassembly was discarded.

## 21.3 RELIABLE_ACKED Partial Transmission Recovery

For `RELIABLE_ACKED`, any transport loss before logical ACK completion retains the operation.

After successful RESUME, the sender retransmits the entire logical application message from chunk 0 with:

```text
same MessageId
identical payload
identical DATA chunking parameters
fresh reliable wire sequence numbers
new transport generation
```

This applies whether zero, some, or all DATA chunks reached frame-level `SENT_TO_TRANSPORT` before the loss, as long as the logical operation remains unacknowledged.
# 22. REALTIME_DATAGRAM Frame

Realtime latest-state uses a separate frame type:

```text
0x1B REALTIME_DATAGRAM
```

Maximum application payload:

```text
MAX_REALTIME_PAYLOAD = 1100 bytes
```

The value 1100 bytes is universal across GATT, L2CAP, TCP fallback, and the UDP realtime sidecar. A binding MUST reject a larger realtime payload with `MESSAGE_TOO_LARGE` before queueing it.

Payload:

```text
Offset Size Field
0      2    channel_id uint16
2      4    datagram_sequence uint32
6      8    sender_tick uint64
14     2    payload_length uint16
16     N    application_payload
```

Rules:

- channel_id range: 1..65535;
- channel_id 0 is reserved;
- sender maintains an independent uint32 sequence per channel per logical SessionId;
- first sequence is 1 for a new SessionId;
- sequence MUST continue across physical reconnect/RESUME and transport migration while SessionId is unchanged;
- queued pre-disconnect realtime datagrams are discarded, but the sequence counter is NOT reset;
- sequence wraps modulo 2^32;
- RFC-1982-style serial arithmetic is used to determine newer values;
- a receiver MUST deliver only a datagram newer than the last delivered sequence on that channel;
- equal or older sequence is silently discarded;
- sequence gaps are valid and produce no error;
- no ACK frame is generated;
- no retry timer exists;
- datagrams are never replayed by RESUME;
- datagrams are never placed in the reliable-message dedup set;
- datagrams do not participate in reliable application ordering.

`sender_tick` is application-defined monotonic game/simulation tick. The framework carries it unchanged and does not interpret it.

## 22.1 Realtime Queue Semantics

Per PeerConnection, the SDK maintains at most ONE not-yet-started REALTIME_DATAGRAM per channel.

If a new realtime datagram for the same channel is submitted before the previous one begins physical transmission:

```text
replace previous queued datagram with new datagram
```

The replaced SendHandle completes:

```text
SUPERSEDED
```

If transmission has already begun, the old datagram is allowed to finish and the new datagram becomes the sole queued successor.

Default realtime expiry:

```text
100 ms
```

If a realtime datagram has not begun transmission within 100 ms, it is dropped with terminal state:

```text
EXPIRED
```

No retransmission occurs.

## 22.2 GATT Mapping

For GATT:

central -> peripheral realtime traffic MUST prefer:

```text
Write Without Response
```

peripheral -> central realtime traffic MUST use:

```text
Notify
```

GATT transport fragmentation MAY still be required when the ATT payload is smaller than the LPC realtime frame.

If one GATT fragment sequence for a realtime frame cannot be completed, the entire realtime frame is discarded.

Realtime GATT reassembly timeout:

```text
250 ms
```

The frame is not retried by LPC.

## 22.3 L2CAP/TCP Mapping

L2CAP CoC and TCP remain reliable streams.

For those transports, REALTIME_LATEST still provides:

- no LPC ACK;
- no LPC retry;
- latest-only SDK queue replacement;
- receiver stale-sequence rejection.

Bytes already handed to the operating-system stream buffer cannot be withdrawn. Therefore under severe stream congestion, an implementation SHOULD prefer a datagram-capable transport if one is available.

## 22.4 Wi-Fi UDP Realtime Sidecar

Protocol minor 1 defines an OPTIONAL authenticated UDP sidecar used only for `REALTIME_LATEST`.

The UDP sidecar is NOT an LPC reliable transport and MUST NOT share:

- the reliable transport wire sequence counter;
- the reliable transport AEAD traffic key;
- the reliable transport replay window;
- the reliable transport upgrade generation transition.

Reliable traffic continues on the current GATT, L2CAP, or TCP connection while UDP is active.


### 22.4.1 Automatic Initiator

Automatic UDP sidecar establishment has exactly one initiator.

For a READY `PeerConnection` where both peers advertise `LAN_UDP_REALTIME`:

```text
if local_peer_id < remote_peer_id lexicographically:
    local MAY automatically initiate UDP_OFFER
else:
    local MUST NOT automatically initiate UDP_OFFER
```

The lexicographically smaller `PeerId` is therefore the automatic UDP initiator.

The non-initiator MUST accept or reject the incoming offer according to capability and policy, but MUST NOT send a competing automatic offer.

If the public API later exposes an explicit manual UDP-establishment operation, simultaneous explicit offers MUST still resolve by this same PeerId rule. An offer from the lexicographically larger PeerId MUST be rejected with `UDP_CLOSE(PROTOCOL_ERROR)` when a competing establishment is pending.

### 22.4.2 UDP Sidecar State

Each PeerConnection maintains:

```text
udpRealtimeState =
    DISABLED
    OFFERED
    NEGOTIATING
    PROBING
    ACTIVE
    FAILED
    CLOSED
```

A UDP sidecar is bound to:

```text
SessionId
current reliable transport_generation
udp_channel_id
```

`udp_channel_id` is a random nonzero uint32 generated by the initiator.

Only one ACTIVE UDP realtime sidecar is allowed per PeerConnection.

### 22.4.3 UDP_OFFER

`UDP_OFFER` is an encrypted LPC control frame sent over the existing reliable connection.

Payload:

```text
Offset Size Field
0      4    udp_channel_id uint32
4      1    address_family
5      1    reserved = 0
6      2    UDP port uint16
8      16   IP address field
24     16   offer_nonce
```

Address family:

```text
0x04 IPv4: first 4 address bytes valid; remaining 12 bytes MUST be zero
0x06 IPv6: all 16 address bytes valid
```

The sender MUST already have a UDP socket bound to the advertised port before sending the offer.

### 22.4.4 UDP_ACCEPT

If the receiver supports and permits UDP realtime, it binds its own UDP socket and returns encrypted `UDP_ACCEPT`.

Payload:

```text
Offset Size Field
0      4    udp_channel_id
4      1    address_family
5      1    reserved = 0
6      2    UDP port
8      16   IP address field
24     16   offer_nonce echoed exactly
40     16   accept_nonce
```

If the offer cannot be accepted, the receiver sends `UDP_CLOSE` with an appropriate reason code.

### 22.4.5 UDP Sidecar Key Derivation

Let `current_session_root_key` be the current root key of the authenticated logical session.

Compute:

```text
udp_sidecar_root =
    HKDF-SHA256(
        IKM  = current_session_root_key,
        salt = offer_nonce || accept_nonce,
        info =
            ASCII "LPC1-udp-sidecar" ||
            session_id ||
            uint32_be(reliable_transport_generation) ||
            uint32_be(udp_channel_id),
        L = 32
    )
```

As elsewhere, the lexicographically smaller PeerId is side 0 and the larger PeerId is side 1.

Directional UDP keys:

```text
udp_key_0_to_1 =
    HKDF-SHA256(
        IKM = udp_sidecar_root,
        salt = zero-length,
        info = ASCII "LPC1-udp-key-0-to-1",
        L = 32
    )

udp_key_1_to_0 =
    HKDF-SHA256(
        IKM = udp_sidecar_root,
        salt = zero-length,
        info = ASCII "LPC1-udp-key-1-to-0",
        L = 32
    )
```

These keys MUST NOT be reused as reliable-stream keys.

### 22.4.6 UDP Packet Format

UDP packets use a separate wire format with magic `LPU1`.

```text
Offset Size Field
0      4    ASCII "LPU1"
4      1    protocol_major = 1
5      1    negotiated_minor
6      1    udp_packet_type
7      1    flags = 0
8      4    bound_reliable_transport_generation uint32
12     4    udp_channel_id uint32
16     8    udp_packet_sequence uint64
24     16   session_id
40     2    encrypted_payload_length uint16
42     2    reserved = 0
44     N    encrypted_payload
44+N   16   ChaCha20-Poly1305 tag
```

UDP packet types:

```text
0x01 UDP_REALTIME
0x02 UDP_PROBE
0x03 UDP_PROBE_ACK
```

Maximum complete UDP datagram size:

```text
1232 bytes
```

The sender MUST NOT intentionally cause IP fragmentation.

### 22.4.7 UDP Cryptographic Sequence Space

Each direction maintains an independent `udp_packet_sequence uint64`.

Rules:

```text
first UDP packet sequence = 1
increment by exactly 1 for each emitted UDP packet
sequence space is independent from reliable LPC sequence_number
```

UDP AEAD nonce:

```text
uint32_be(bound_reliable_transport_generation) ||
uint64_be(udp_packet_sequence)
```

UDP associated data is bytes 0 through 43 of the UDP packet header.

The UDP receiver MUST maintain a 256-packet replay window per direction.

Replay-window initialization is exact:

```text
greatestAcceptedUdpSequence = undefined
```

Before any UDP packet has been accepted, the first authenticated packet with:

```text
udp_packet_sequence >= 1
```

MUST be accepted, MUST initialize `greatestAcceptedUdpSequence` to that value, and MUST mark that sequence as received.

`udp_packet_sequence` MUST NOT wrap.

A sender MUST establish a fresh UDP sidecar before attempting to emit sequence `UINT64_MAX`. Sending sequence 0 or reusing a sequence under the same directional UDP key is a protocol error.

A UDP packet is accepted cryptographically if:

- authentication succeeds;
- sequence has not already been accepted;
- sequence is not more than 255 below the greatest accepted UDP packet sequence.

UDP packet reordering inside that window is valid.

Missing UDP packet sequences do NOT create an error.

A UDP packet MUST NOT update or inspect the reliable-stream replay window.

### 22.4.8 UDP_REALTIME Payload

The encrypted `UDP_REALTIME` payload is exactly the REALTIME_DATAGRAM plaintext body:

```text
Offset Size Field
0      2    realtime channel_id uint16
2      4    datagram_sequence uint32
6      8    sender_tick uint64
14     2    payload_length uint16
16     N    application_payload
```

`N` MUST be 0..1100.

Maximum full packet size at N=1100:

```text
44-byte UDP header
+ 16-byte realtime header
+ 1100-byte application payload
+ 16-byte AEAD tag
= 1176 bytes
```

This fits below the 1232-byte UDP limit.

The counters have distinct purposes:

```text
udp_packet_sequence:
    cryptographic anti-replay and nonce uniqueness

datagram_sequence:
    application latest-state ordering for one realtime channel
```

### 22.4.9 UDP Probe and Activation

After UDP_ACCEPT:

1. both sides derive UDP keys;
2. both enter PROBING;
3. each generates a random 16-byte `probe_token`;
4. each sends UDP_PROBE every 250 ms until validated or timed out.

UDP_PROBE encrypted payload:

```text
16 bytes local probe_token
```

On a valid UDP_PROBE, the receiver immediately sends UDP_PROBE_ACK whose payload is the received 16-byte probe_token.

A side considers the UDP path validated only after it has:

- received at least one valid UDP_PROBE from the remote side; and
- received a valid UDP_PROBE_ACK containing its own current probe_token.

Both conditions MUST be satisfied.

Probe timeout:

```text
2000 ms
```

Maximum probe transmissions per side:

```text
8
```

When both sides are validated, each may set its local state to ACTIVE. The first valid UDP_REALTIME packet also proves that the remote side reached an operational keyed state.

If activation fails, state becomes FAILED and realtime continues over the existing reliable physical transport.

### 22.4.10 UDP_CLOSE

`UDP_CLOSE` is an encrypted reliable LPC control frame.

Payload:

```text
4 bytes udp_channel_id
2 bytes reason_code
```

Reasons:

```text
0x0001 LOCAL_REQUEST
0x0002 PROBE_TIMEOUT
0x0003 NETWORK_CHANGED
0x0004 REKEY_REQUIRED
0x0005 PROTOCOL_ERROR
```

Closing UDP MUST NOT close or increment the reliable transport generation.

### 22.4.11 Reliable Reconnect and UDP

If RESUME changes the reliable `transport_generation`:

- the old UDP sidecar becomes invalid immediately;
- all old UDP keys and replay state MUST be destroyed;
- queued realtime datagrams are discarded;
- reliable session recovery proceeds normally;
- a fresh UDP_OFFER/UDP_ACCEPT/probe exchange is required.

Realtime falls back to the active reliable transport until the new UDP sidecar becomes ACTIVE.

### 22.4.12 UDP Endpoint Rebinding

Protocol minor 1 does NOT permit unauthenticated UDP source-address rebinding.

A UDP packet received from an IP/port different from the endpoint negotiated by UDP_OFFER/UDP_ACCEPT MUST be discarded even if its AEAD verifies.

An authenticated packet arriving from an unexpected source address is NOT a protocol/security failure of the `PeerConnection`.

The required behavior is:

```text
discard unexpected-source UDP packet
mark UDP sidecar invalid
send UDP_CLOSE(NETWORK_CHANGED) over the reliable channel when possible
keep reliable PeerConnection in READY
fall back realtime traffic to the reliable transport
establish a fresh UDP sidecar if policy still allows it
```

The reliable `PeerConnection`, logical `SessionId`, and reliable transport generation MUST remain unchanged solely because of UDP endpoint movement.

This deterministic rule avoids silently accepting NAT/port rebinding in protocol minor 1 while preserving the reliable session.


# 23. Generic ACK, Retransmission, Duplicate Suppression, and RESUME Retention

The ACK mechanism applies to every encrypted LPC logical unit whose frame-header `ACK_REQUIRED` flag is set.

This includes:

- `DATA` with `delivery_mode = RELIABLE_ACKED`;
- `MEMBERSHIP_SNAPSHOT`;
- `GROUP_MERGE`;
- `COORDINATOR_CHECKPOINT`;
- `GROUP_LEAVE`;
- `GROUP_RELIABLE` with embedded `delivery_mode = RELIABLE_ACKED`;
- `GROUP_DELIVERY_ACK`;
- `GROUP_RELAY_STATUS`.

`RELIABLE_ORDERED`, `REALTIME_LATEST`, and control frames without `ACK_REQUIRED` MUST NOT generate ACK.

## 23.1 ACK Frame

ACK frame type:

```text
0x07 ACK
```

ACK header requirements:

```text
flags = 0
message_id = all zero
```

ACK plaintext payload:

```text
8 bytes acknowledged_message_id
```

The receiver sends ACK only after the complete logical ACK-required unit has:

1. been fully received;
2. passed framing and cryptographic validation;
3. passed semantic validation;
4. been accepted into the appropriate SDK state/application-delivery queue or committed protocol state.

For ACK-required DATA, this occurs after all chunks are complete.

For a multi-frame ACK-required control operation, including `COORDINATOR_CHECKPOINT`, this occurs only after all constituent frames are complete and the logical operation has been committed.

## 23.2 ACK Timeout and Retransmission

Defaults:

```text
ACK timeout = 3000 ms
maximum retransmissions = 2
```

ACK timers run only while the relevant PeerConnection is READY.

`SENT_TO_TRANSPORT` has one exact cross-platform meaning:

```text
every transport-specific physical byte/fragment required to represent
the complete LPC frame has been successfully submitted to the
underlying platform transport API
```

Internal buffering does NOT satisfy this condition.

The following MUST NOT count as `SENT_TO_TRANSPORT`:

```text
application queue insertion
LPC scheduler queue insertion
transport-backend queue insertion
GATT-fragment queue insertion
socket-write staging buffer insertion that has not yet been submitted
to the platform socket/stream API
```

Transport-specific completion rules are exact:

```text
BLE GATT:
    an LPC frame reaches SENT_TO_TRANSPORT only after the final
    GATT transport fragment for that LPC frame has been successfully
    submitted to the applicable platform GATT API.

    Android examples:
        BluetoothGatt.writeCharacteristic(...)
        BluetoothGattServer.notifyCharacteristicChanged(...)
        or the API-level-equivalent asynchronous submission call

    iOS examples:
        CBPeripheral.writeValue(...)
        CBPeripheralManager.updateValue(...)
        or the API-level-equivalent submission call

    For Write Without Response / Notify, LPC does NOT wait for
    radio-level acknowledgment or remote receipt. Successful
    submission to the platform Bluetooth stack is sufficient.

BLE L2CAP CoC:
    an LPC frame reaches SENT_TO_TRANSPORT only after all serialized
    LPC frame bytes have been accepted by the underlying L2CAP
    stream/channel write mechanism.

TCP:
    an LPC frame reaches SENT_TO_TRANSPORT only after all serialized
    LPC frame bytes have been accepted by the underlying socket/kernel
    send path.

UDP realtime sidecar:
    SENT_TO_TRANSPORT is not used for ACK timing because UDP realtime
    datagrams are never ACK_REQUIRED. A UDP send handle reaches its
    transport-sent state when the complete UDP datagram has been
    submitted to the platform UDP socket API.
```

The framework does NOT require radio-level delivery confirmation, TCP peer acknowledgment, BLE link-layer acknowledgment, or remote LPC receipt to reach `SENT_TO_TRANSPORT`.

The purpose of this state is solely to establish a deterministic lower boundary after all LPC/backend-internal buffering and fragmentation for that frame have finished submitting to the operating-system transport stack.

For one ACK-required logical operation, the ACK timeout MUST NOT begin until every frame/chunk belonging to the current transmission attempt has reached `SENT_TO_TRANSPORT`.

Exact rules:

```text
single-frame ACK-required operation:
    start ACK timer when that frame reaches SENT_TO_TRANSPORT

RELIABLE_ACKED DATA:
    start ACK timer when the final DATA chunk of the current
    transmission attempt reaches SENT_TO_TRANSPORT

chunked COORDINATOR_CHECKPOINT:
    start ACK timer when the final checkpoint chunk of the current
    transmission attempt reaches SENT_TO_TRANSPORT

GROUP_RELIABLE with RELIABLE_ACKED:
    start ACK timer when the final GROUP_RELIABLE chunk of the
    current hop transmission attempt reaches SENT_TO_TRANSPORT
```

If transmission of the logical operation itself takes longer than `ACK timeout`, that fact alone MUST NOT trigger retransmission.

If the PeerConnection enters RECONNECTING before the entire current transmission attempt reaches `SENT_TO_TRANSPORT`:

- no ACK timeout is considered active for that attempt;
- any partially transmitted attempt is abandoned for ACK-timer purposes;
- after successful RESUME, retransmission follows Section 23.4.

Each retransmission attempt starts a fresh ACK timeout only after all frames/chunks belonging to that retransmission attempt have reached `SENT_TO_TRANSPORT`.

During RECONNECTING, any already-running ACK timer pauses and resumes only if the same transmission attempt remains valid. If RESUME causes the operation to be retransmitted as a new attempt, the old timer is discarded and the new attempt uses a fresh timer according to the rules above.

A retransmission:

- retains the same MessageId;
- retains identical logical content;
- receives new reliable wire `sequence_number` values;
- for chunked DATA, retransmits all DATA chunks;
- for chunked COORDINATOR_CHECKPOINT, retransmits all checkpoint chunks;
- for chunked GROUP_RELIABLE, retransmits all GROUP_RELIABLE chunks for that physical hop.

After the second retransmission times out, the logical operation reaches terminal `ACK_TIMEOUT`.

The sender MUST then apply the exact recovery defined in Section 23.5.

## 23.3 Duplicate Set

Each receive direction maintains one completed ACK-required MessageId deduplication set containing the most recent 16,384 completed MessageIds.

The set covers ACK-required DATA and ACK-required control operations together.

For `MEMBERSHIP_SNAPSHOT`, duplicate suppression is supplemented by the SessionId-scoped same-term stale-snapshot ordering rule in Section 10. A valid but older snapshot from the same coordinator/term/SessionId ordering domain received after a newer one MUST be ACKed as appropriate but MUST NOT roll committed membership backward. Counters from different SessionIds are never compared.

If an already-completed MessageId is received again:

- authenticate and parse enough to identify the duplicate;
- MUST NOT redeliver application DATA;
- MUST NOT reapply a control-frame state mutation;
- MUST NOT replace an already-committed coordinator checkpoint a second time;
- discard duplicate logical content;
- send ACK again.

If the same MessageId is observed with different authenticated logical content, the receiver MUST close the PeerConnection with `MESSAGE_ID_COLLISION`.

## 23.4 RESUME

Every sent ACK-required logical operation remains in the sender's unacknowledged-retention set until:

- ACK is received;
- retry limit fails;
- SessionId terminates; or
- application explicitly cancels where cancellation is permitted.

For an application-cancelled operation, removal from retransmission/reroute retention does NOT imply that already-transmitted bytes or independently admitted coordinator relay state were revoked.

For routed GroupSession sends, cancellation-tombstone correlation state is retained separately according to Section 36 so valid late GROUP_DELIVERY_ACK / GROUP_RELAY_STATUS operations can still be authenticated, ACKed, and ignored semantically.

After successful RESUME:

- all still-unacknowledged ACK-required DATA and control operations are immediately eligible for retransmission;
- each retains its original MessageId;
- each uses fresh wire sequence numbers in the new transport generation;
- each such retransmission consumes one retry attempt.

Therefore unacknowledged ACK-required operations including `MEMBERSHIP_SNAPSHOT`, `GROUP_MERGE`, `COORDINATOR_CHECKPOINT`, `GROUP_LEAVE`, `GROUP_RELIABLE`, `GROUP_DELIVERY_ACK`, and `GROUP_RELAY_STATUS` survive pairwise RESUME using the same generic reliability mechanism.

## 23.5 Frame-Specific Final ACK-Timeout Recovery

After the generic retry limit is exhausted, the sender MUST perform the following exact recovery.

| ACK-required logical operation | Required recovery after final ACK timeout |
|---|---|
| `RELIABLE_ACKED DATA` | Fail the application's `SendHandle` with `ACK_TIMEOUT`. Do not disconnect the peer solely because this application message was not ACKed. |
| `MEMBERSHIP_SNAPSHOT` | Mark the target peer's `GroupSyncState=UNSYNCHRONIZED`. It MUST NOT be considered synchronized for membership-dependent group operations. Close the current group PeerConnection with `GROUP_STATE_SYNC_FAILED`, then use normal reconnect/resume. After reconnect, send the latest current `MEMBERSHIP_SNAPSHOT` and require its ACK before restoring `GroupSyncState=SYNCHRONIZED`. If reconnect ultimately times out, apply the normal abrupt-member-removal rule. |
| `GROUP_MERGE` | The already committed merge MUST NOT be rolled back. Mark that target peer `UNSYNCHRONIZED`, close its current group PeerConnection with `GROUP_STATE_SYNC_FAILED`, and require it to rebootstrap using current `GROUP_INFO` and the current GroupId. If it cannot return before normal reconnect timeout, apply normal membership-removal behavior. |
| `COORDINATOR_CHECKPOINT` | Emit `CoordinatorCheckpointReplicationFailed(peerId, checkpointSequence)`. Do NOT remove the peer, change coordinator term, fail the GroupSession, or disconnect solely because checkpoint replication failed. A later checkpoint may supersede the failed replication attempt. |
| `GROUP_LEAVE` from ordinary leaving member to coordinator | The leaving peer follows the bounded leave grace from Section 31 and closes even if ACK was lost. The coordinator converges through the received leave if it arrived, otherwise through normal terminal disconnect/removal. The leaving peer MUST NOT wait indefinitely for ACK. |
| `GROUP_LEAVE` from coordinator to a kicked member | The coordinator proceeds with committed membership removal and publishes the new `MEMBERSHIP_SNAPSHOT` regardless of target ACK. The target MUST NOT remain committed merely because its leave ACK was lost. |
| `GROUP_LEAVE` during coordinator voluntary resignation | The coordinator proceeds after the specified 500 ms resignation grace regardless of missing leave ACKs. Missing ACK MUST NOT cancel resignation or election. |
| `GROUP_RELIABLE` source -> coordinator, RELIABLE_ACKED | Fail the corresponding group SendHandle with `ACK_TIMEOUT`. A stable coordinator that did not ACK the accepted source hop is treated as failure of that group send; do not silently retain it forever. |
| `GROUP_RELIABLE` coordinator -> destination, RELIABLE_ACKED | Coordinator terminates that destination-hop relay attempt and sends `GROUP_RELAY_STATUS(DESTINATION_ACK_TIMEOUT)` to the original source. If the coordinator is also the original source, fail its local SendHandle with `ACK_TIMEOUT`. |
| `GROUP_DELIVERY_ACK` coordinator -> source | Emit `GroupError` for route-signaling failure and close/reconnect the source PeerConnection. The destination delivery remains committed. If the source did not receive the delivery ACK, its still-nonterminal GroupMessageId is eligible for whole-operation reroute after the coordinator link becomes READY; destination dedup prevents duplicate delivery. |
| `GROUP_RELAY_STATUS` coordinator -> source | Emit `GroupError` for route-signaling failure and close/reconnect the source PeerConnection. If the source did not receive the status, its nonterminal group operation follows normal whole-operation reroute semantics when the coordinator link becomes READY. |

Per committed group member, the coordinator tracks:

```text
GroupSyncState =
    SYNCHRONIZED
    UNSYNCHRONIZED
```

`GroupSyncState` is separate from cryptographic `PeerConnectionState`.

A peer is `SYNCHRONIZED` only after it has acknowledged the latest group-state operation that the coordinator requires for that peer to participate in committed membership-dependent behavior.

## 23.6 RELIABLE_ORDERED and REALTIME Behavior

`RELIABLE_ORDERED` DATA:

- uses a MessageId for chunk grouping and diagnostics;
- does not set ACK_REQUIRED;
- is not inserted into the ACK-required dedup set;
- is not retransmitted after reaching `SENT_TO_TRANSPORT`.

`REALTIME_DATAGRAM`:

- does not set ACK_REQUIRED;
- generates no ACK;
- has no ACK retry timer;
- is never replayed through RESUME;
- uses its realtime channel sequence for latest-state suppression.

---

## 23.7 GROUP_RELIABLE Non-ACKed Partial-Hop Recovery

`GROUP_RELIABLE` with embedded `RELIABLE_ORDERED` is not ACK-required, so its partial-hop transport-generation-loss behavior is not governed by the ACK retry state machine above.

Its exact whole-hop recovery is defined in Section 43.

In particular:

- incomplete receiver reassembly is discarded on generation loss;
- if all hop frames had already reached frame-level `SENT_TO_TRANSPORT`, no retransmission is triggered solely by later transport loss;
- otherwise the entire hop operation is retransmitted from chunk 0 after successful RESUME using the same pairwise MessageId and GroupMessageId with fresh wire sequence numbers.
# 24. Keepalive

Each runtime config supplies:

```text
keepalive_interval_ms
```

Allowed range:

```text
1000..10000
```

Default:

```text
2000
```

Peers negotiate from their HELLO payloads:

```text
negotiated_keepalive_interval =
    max(local_keepalive_interval, remote_keepalive_interval)
```

Dead timeout is NOT independently configurable.

It is derived exactly as:

```text
keepalive_dead_timeout =
    max(6000, 3 * negotiated_keepalive_interval)
```

A peer MUST send PING if it has sent no encrypted frame for one negotiated keepalive interval.

Any authenticated encrypted frame resets receive-liveness time.

If no valid authenticated encrypted frame is received for `keepalive_dead_timeout`, active transport is considered lost.

PING payload:

```text
8-byte random ping_id
8-byte monotonic_sender_time_us
```

PONG echoes all 16 bytes exactly.

---

# 25. Reconnect Policy

Reconnect timeout is a local policy and is not negotiated.

Default:

```text
auto_reconnect = true
reconnect_timeout_ms = 15000
```

Allowed configured range:

```text
1000..60000
```

Attempt schedule:

```text
attempt 1: immediately
attempt 2: 250 ms after attempt 1 fails
attempt 3: 500 ms after attempt 2 fails
attempt 4: 1000 ms after attempt 3 fails
attempt 5+: 2000 ms after previous failure
```

Stop when:

- resume succeeds;
- application cancels;
- local reconnect timeout expires.

A failed active transport is excluded from the first reconnect attempt if another mutually supported transport is known. Subsequent attempts may retry all supported transports in configured preference order.

---

# 26. Fully Specified RESUME Lifecycle

RESUME preserves:

- PeerId;
- SessionId;
- sender_message_prefix;
- next_message_counter;
- completed ACK-required MessageId deduplication state;
- queued-but-not-yet-transmitted application messages, subject to normal expiry rules;
- all still-unacknowledged `ACK_REQUIRED` logical operations, including `RELIABLE_ACKED DATA`, `MEMBERSHIP_SNAPSHOT`, `GROUP_MERGE`, `COORDINATOR_CHECKPOINT`, and `GROUP_LEAVE`;
- realtime per-channel `datagram_sequence` counters for the continuing SessionId.

RESUME does NOT preserve incomplete coordinator-checkpoint reassembly.


RESUME does **not** preserve:

- old wire sequence numbers;
- old traffic keys;
- old ConnectionId;
- old transport generation.

## 26.1 Fresh Candidate Handshake

Every reconnect first establishes a fresh physical connection and performs fresh HELLO and AUTH with new ephemeral X25519 keys and new `connection_nonce`.

A reconnect MUST use `trust_mode = KNOWN_PEER` internally and MUST require the presented PeerId and Ed25519 identity public key to match the peer identity retained from the previous session. The user is not asked to compare SAS again during automatic RESUME.

The previous `resume_secret` provides additional proof that the reconnecting endpoint participated in the previous logical session.

This derives:

```text
candidate_base_root_key
candidate_transcript T2
candidate_session_root_key
candidate_session_id
```

No normal READY is sent yet.

Candidate encrypted RESUME control uses generation 0 and candidate traffic keys:

```text
candidate_key(D) = HKDF-SHA256(
    IKM = candidate_session_root_key,
    salt = zero-length,
    info = ASCII "LPC1-candidate" || D,
    L = 32
)
```

Candidate sequence starts at 1.

Candidate encrypted frame header uses:

```text
transport_generation = 0
session_id = candidate_session_id
```

## 26.2 RESUME_REQUEST

Requester generates random 16-byte `resume_nonce_a`.

Payload:

```text
Offset Size Field
0      16   previous_session_id
16     16   resume_nonce_a
32     4    previous_transport_generation
36     32   proof_a
```

```text
proof_a = HMAC-SHA256(
    key = previous_resume_secret,
    data =
        ASCII "LPC1-resume-request" ||
        previous_session_id ||
        resume_nonce_a ||
        T2
)
```

## 26.3 RESUME_ACCEPT

If previous session exists, PeerId matches, session has not expired, and proof verifies, responder generates random 16-byte `resume_nonce_b`.

Payload:

```text
Offset Size Field
0      16   previous_session_id
16     16   resume_nonce_a
32     16   resume_nonce_b
48     4    new_transport_generation
52     32   proof_b
```

Where:

```text
new_transport_generation = previous_transport_generation + 1
```

and:

```text
proof_b = HMAC-SHA256(
    key = previous_resume_secret,
    data =
        ASCII "LPC1-resume-accept" ||
        previous_session_id ||
        resume_nonce_a ||
        resume_nonce_b ||
        T2 ||
        uint32_be(new_transport_generation)
)
```

If resume cannot be accepted, send RESUME_REJECT under candidate keys with a 2-byte error code and close candidate connection.

## 26.4 Resumed Root

Both sides derive:

```text
resumed_session_root_key = HKDF-SHA256(
    IKM = candidate_session_root_key,
    salt = previous_resume_secret,
    info =
        ASCII "LPC1-resumed-root" ||
        previous_session_id ||
        resume_nonce_a ||
        resume_nonce_b ||
        uint32_be(new_transport_generation),
    L = 32
)
```

Then:

```text
new_resume_secret = HKDF-SHA256(
    IKM = resumed_session_root_key,
    salt = zero-length,
    info = ASCII "LPC1-resume-secret",
    L = 32
)
```

The logical `SessionId` remains `previous_session_id`.

Generation-specific traffic keys are derived from `resumed_session_root_key` using Section 16.13 and `new_transport_generation`.

Wire sequence counters reset to 1 for the new generation.

## 26.5 RESUME_READY

Both peers send RESUME_READY as the first frame under resumed generation keys.

Payload:

```text
16 bytes previous_session_id
4 bytes new_transport_generation
```

A peer returns to READY only after:

- it sent RESUME_READY; and
- it received/authenticated remote RESUME_READY.

At that moment:

- `session_root_key = resumed_session_root_key`;
- `resume_secret = new_resume_secret`;
- `transport_generation = new_transport_generation`.

## 26.6 Message Recovery

After `RESUME_READY`:

1. application messages that never began transmission remain queued, subject to normal expiry and queue policy;

2. for `RELIABLE_ORDERED` application messages:
   - if the complete logical application message had reached `SendHandle.SENT_TO_TRANSPORT` before loss, it is not retransmitted automatically;
   - if one or more constituent DATA frames had not reached frame-level `SENT_TO_TRANSPORT`, the entire logical application message is retransmitted from chunk 0 with the same MessageId according to Section 21;

3. every still-unacknowledged `ACK_REQUIRED` logical operation defined by negotiated protocol minor 1 is retransmitted according to Section 23, including:

```text
RELIABLE_ACKED DATA
MEMBERSHIP_SNAPSHOT
GROUP_MERGE
COORDINATOR_CHECKPOINT
GROUP_LEAVE
GROUP_RELIABLE
GROUP_DELIVERY_ACK
GROUP_RELAY_STATUS
```

This list is exhaustive for protocol minor 1.

4. retransmitted ACK-required operations retain their original MessageId and logical content while using fresh reliable wire sequence numbers in the resumed transport generation;

5. completed MessageId deduplication state suppresses:
   - duplicate application delivery for ACK-required DATA; and
   - duplicate protocol-state mutation for ACK-required control operations;

6. incomplete DATA reassembly from the failed transport generation has already been discarded according to Section 21 and MUST NOT be reused after RESUME;

7. REALTIME_LATEST datagrams from before the transport loss are not replayed; the application must submit fresh current realtime state.

For application payloads, exactly-once SDK delivery across successful RESUME is provided only for `RELIABLE_ACKED DATA` within the defined MessageId deduplication limits.

ACK-required protocol control operations use the same MessageId retention, ACK, retransmission, and duplicate-suppression mechanism to prevent duplicate protocol-state mutation. They are not described as generic application SDK delivery.

Incomplete `COORDINATOR_CHECKPOINT` reassembly is handled by the explicit discard-and-restart rule in this Section: partial pre-disconnect checkpoint chunks are never combined with post-RESUME chunks.


## 26.7 Partial Checkpoint Reassembly Across Transport Loss

If transport loss occurs before a `COORDINATOR_CHECKPOINT` logical operation has been completely reassembled and committed:

```text
receiver MUST discard all incomplete checkpoint reassembly state
for that MessageId
```

This includes:

- received chunk bitmap;
- partial checkpoint byte buffer;
- checkpoint reassembly timer;
- per-chunk temporary metadata.

The receiver MUST retain only completed ACK-required MessageId deduplication state.

After successful RESUME, if the checkpoint remains unacknowledged, the sender retransmits the complete logical checkpoint from chunk 0:

- same MessageId;
- same checkpoint_sequence;
- identical checkpoint bytes;
- fresh reliable wire sequence numbers in the new transport generation.

The receiver starts fresh checkpoint reassembly from no retained partial chunks.

This rule is REQUIRED. Implementations MUST NOT attempt to merge pre-disconnect partial checkpoint chunks with post-RESUME retransmitted chunks.
# 27. Transport Generation

Initial generation is 1.

Generation increments by exactly 1 on:

- successful RESUME; or
- successful transport upgrade commit.

Generation MUST never decrement for one SessionId.

Sequence counters restart at 1 after generation change and traffic keys are re-derived for that generation.

Frames from any older generation are stale and MUST be discarded.

Generation wrap from `0xFFFFFFFF` is forbidden. The SDK MUST create a new logical session before wrap.

# 28. Complete Transport Upgrade and Fallback Protocol

Transport preference for V1:

```text
1 WIFI_LAN_TCP
2 BLE_L2CAP
3 BLE_GATT
```

The application MAY disable a transport or explicitly provide another preference ordering.

Transport values:

```text
0x01 BLE_GATT
0x02 BLE_L2CAP
0x03 WIFI_LAN_TCP
```

Upgrade states:

```text
IDLE
OFFERED
ACCEPTED
CONNECTING_CANDIDATE
BINDING_CANDIDATE
SWITCH_PENDING
ACTIVE
FAILED
```

Only one upgrade may be in progress per peer.

## 28.1 UPGRADE_OFFER

Sent on current active transport.

Payload:

```text
Offset Size Field
0      16   upgrade_id
16     1    target_transport
17     3    reserved = 0
20     4    target_generation = current_generation + 1
24     2    offer_data_length
26     N    transport-specific offer_data
```

## 28.2 UPGRADE_ACCEPT / UPGRADE_REJECT

ACCEPT echoes:

```text
upgrade_id
target_transport
target_generation
accept_data_length
accept_data
```

REJECT:

```text
16 bytes upgrade_id
2 bytes error_code
```

A rejected/failed transport MUST NOT be automatically reoffered for 30 seconds unless its capability changes.

## 28.3 Candidate Transport Keys

Candidate generation traffic keys are derived from the CURRENT session root:

```text
candidate_transport_key(D) =
    traffic_key(target_generation, D)
```

Candidate wire sequence counters start at 1.

Candidate frame header uses current SessionId and target_generation.

No application DATA may be sent on candidate before SWITCH completes.

## 28.4 UPGRADE_BIND

After candidate physical channel opens, each side MUST send UPGRADE_BIND over that candidate channel.

Payload:

```text
Offset Size Field
0      16   upgrade_id
16     16   session_id
32     1    transport_type
33     3    reserved = 0
36     4    target_generation
40     32   binding_proof
```

```text
binding_proof = HMAC-SHA256(
    key = current_resume_secret,
    data =
        ASCII "LPC1-upgrade-bind" ||
        upgrade_id ||
        session_id ||
        byte(target_transport) ||
        uint32_be(target_generation)
)
```

Both peers verify.

Each peer responds on candidate channel with UPGRADE_BIND_ACK containing:

```text
16 bytes upgrade_id
4 bytes target_generation
```

Candidate becomes BOUND only after local BIND sent and remote BIND plus remote ACK received.

## 28.5 SWITCH_COMMIT

Upgrade initiator sends SWITCH_COMMIT on OLD active transport:

```text
16 bytes upgrade_id
4 bytes target_generation
1 byte target_transport
```

Receiver verifies candidate is BOUND, sends SWITCH_ACK on OLD active transport with identical payload, then enters SWITCH_PENDING.

Initiator enters SWITCH_PENDING after receiving SWITCH_ACK.

Both peers switch active application DATA to candidate transport at that point.

The candidate transport is now ACTIVE.

Old transport:

- MUST stop carrying application DATA immediately;
- MAY carry CLOSE/diagnostics only;
- MUST be closed 2 seconds after switch.

## 28.6 Failure Before Switch

If any candidate step fails before valid SWITCH_ACK:

- candidate closes;
- old active transport remains active;
- transport generation does not change;
- emit `TransportUpgradeFailed`;
- logical PeerConnection stays READY.

## 28.7 Failure After Switch: Actual Fallback

After SWITCH, the old generation MUST never be reactivated.

If the new active transport later fails:

1. PeerConnection enters RECONNECTING;
2. failed transport is excluded from the first reconnect attempt;
3. SDK chooses the highest-preference mutually supported remaining transport, normally GATT;
4. it establishes a fresh physical connection;
5. it performs the complete RESUME protocol in Section 26;
6. successful RESUME increments generation again;
7. emit `PeerReconnected` and `TransportChanged`.

Therefore "fallback" in V1 is a secure RESUME onto another transport, not rollback to an old transport generation.

Mandatory LAN/L2CAP fallback tests MUST use this behavior.

---

# 29. Wi-Fi LAN Transport

Protocol minor 1 supports two distinct LAN functions:

```text
WIFI_LAN_TCP
    reliable LPC transport candidate

WIFI_LAN_UDP_REALTIME
    optional simultaneous realtime sidecar
```

They are independent capabilities.

## 29.1 TCP Reliable Transport

TCP transport-specific offer/accept data is:

```text
1 byte address_family
2 bytes TCP port
16 bytes IP address field
```

Address family:

```text
0x04 IPv4: first 4 bytes valid, remaining 12 zero
0x06 IPv6: all 16 bytes valid
```

The listener address is carried in UPGRADE_OFFER/UPGRADE_ACCEPT over the already-authenticated reliable session.

A new TCP connection is not trusted until UPGRADE_BIND succeeds.

If TCP becomes the primary reliable transport, the normal reliable transport-generation SWITCH protocol applies.

## 29.2 UDP Realtime Sidecar

UDP realtime MUST use the separate sidecar protocol in Section 22.4.

It MUST NOT use UPGRADE_OFFER, UPGRADE_BIND, or SWITCH.

Activating or closing UDP does not replace the reliable transport and does not increment reliable `transport_generation`.

LAN discovery may use mDNS/DNS-SD, but mDNS records and IP addresses are discovery hints only and MUST NOT be treated as peer identity.


# 30. BLE L2CAP CoC Transport

L2CAP CoC is optional.

The peer capability bit MUST be clear if the runtime cannot both create the required channel role for the negotiated topology and exchange bytes using public platform APIs.

Transport-specific L2CAP offer/accept data is:

```text
2-byte PSM, big-endian
```

The PSM MUST only be transmitted inside encrypted UPGRADE_OFFER/ACCEPT.

L2CAP carries normal LPC frames directly.

The GATT fragmentation header is NOT used over L2CAP.

The L2CAP channel is not trusted until UPGRADE_BIND succeeds.


# 31. Automatic Group Formation Protocol

Automatic group coordination runs only when:

```text
negotiated_minor >= 1
AUTO_COORDINATOR capability is mutually set
```

After the underlying PeerConnection reaches READY, each `GroupSession` bootstrap connection MUST immediately exchange `GROUP_INFO`.

## 31.1 Application Namespace and Group Join Scope

Two different concepts are REQUIRED.

```text
applicationNamespace:
    identifies the application/activity type

groupJoinToken:
    identifies which independently formed local group is allowed to merge
```

`applicationNamespace` is 1..32 bytes and is REQUIRED.

`groupJoinToken` is exactly 16 bytes in `TOKEN_SCOPED` mode.

`groupJoinToken` is a grouping/scope token, NOT an authentication secret.

Knowledge of `groupJoinToken` or `group_join_token_hash` MUST NOT grant authenticated group membership.

Applications requiring authenticated group admission MUST use `GROUP_PSK_32`, `PAIRWISE_SAS`, or `KNOWN_PEERS`.

Applications MAY derive `groupJoinToken` from low-entropy lobby codes if desired because it is not a security credential. Such derivation only affects how easily unrelated observers can guess which group scope is being advertised after connection.

Wire hashes:

```text
application_namespace_hash =
    SHA256(
        ASCII "LPC1-application-namespace" ||
        applicationNamespace
    )

group_join_token_hash =
    SHA256(
        ASCII "LPC1-group-join-token" ||
        groupJoinToken
    )
```

Only hashes are transmitted.

Group discovery modes:

```text
0x01 TOKEN_SCOPED
0x02 OPEN_PROXIMITY
```

Default:

```text
TOKEN_SCOPED
```

In `TOKEN_SCOPED` mode:

- applications MUST provide the same 16-byte groupJoinToken to peers intended to join the same group;
- groups with different token hashes MUST NOT auto-merge.

How the application shares the token is outside LPC. Examples include a lobby selection, QR code, invitation link, NFC, short-range app-specific exchange, or preconfigured activity identifier.

In `OPEN_PROXIMITY` mode:

- groupJoinToken is omitted;
- every compatible nearby group with the same application namespace is merge-compatible;
- applications MUST explicitly opt into this behavior;
- documentation MUST warn that independent nearby groups may merge.

This is the only zero-selection "merge everyone nearby" mode.

## 31.2 GROUP_INFO

Frame:

```text
0x1C GROUP_INFO
```

Payload:

```text
Offset Size Field
0      32   application_namespace_hash
32     1    discovery_mode
33     1    auto_merge boolean
34     1    group_trust_mode
35     1    known_peers_auto_merge boolean
36     32   group_join_token_hash; all zero in OPEN_PROXIMITY
68     16   group_id
84     8    coordinator_term uint64
92     16   coordinator_peer_id; all zero if none committed
108    2    committed_member_count uint16
110    N*18 committed GroupMemberRecord entries sorted by peer_id
110+N*18 32 committed_membership_hash
```

Wire `group_trust_mode` values are exactly the `GroupTrustMode` values from Section 32:

```text
0x01 OPEN_TOFU
0x02 GROUP_PSK_32
0x03 PAIRWISE_SAS
0x04 KNOWN_PEERS
```

`known_peers_auto_merge` MUST be:

- `0` for all trust modes except `KNOWN_PEERS`;
- `0` by default for `KNOWN_PEERS`;
- `1` only when the application explicitly opts into automatic merge for KNOWN_PEERS groups.

A receiver MUST reject GROUP_INFO if:

- the membership list is unsorted;
- a PeerId occurs more than once;
- any GroupMemberRecord `max_peers` is outside 1..31;
- count and payload length disagree;
- membership hash verification fails;
- group_trust_mode is unknown for the negotiated minor;
- known_peers_auto_merge is nonzero for a non-KNOWN_PEERS group.

A singleton newly created group has:

```text
committed_member_count = 1
committed member list =
    GroupMemberRecord(
        peer_id = local PeerId,
        max_peers = local GroupConfig.maxPeers
    )
coordinator_term = 0
coordinator_peer_id = all zero until election commits
```


## 31.3 Merge Compatibility and Deterministic Evaluation Order

For two groups to auto-merge, implementations MUST evaluate the following steps in this exact order:

1. verify `application_namespace_hash` matches;
2. verify both have `auto_merge=true`;
3. verify `discovery_mode` matches;
4. if mode is `TOKEN_SCOPED`, verify `group_join_token_hash` matches;
5. verify `group_trust_mode` is identical;
6. if `group_trust_mode == KNOWN_PEERS`, verify both sides explicitly set `known_peers_auto_merge=1`;
7. compute `GroupMergeRank`;
8. designate the would-be winning group/coordinator;
9. calculate `effective_max_peers` from all candidate `GroupMemberRecord.max_peers` values;
10. calculate the complete candidate union size;
11. if union exceeds capacity, only the would-be winning coordinator sends `GROUP_MERGE_REJECT`;
12. otherwise perform `GROUP_MERGE`.

If any compatibility check in steps 1 through 6 fails, automatic merge MUST NOT occur.

Trust modes MUST NOT be implicitly upgraded, downgraded, or converted during merge.

In particular:

```text
OPEN_TOFU       != GROUP_PSK_32
OPEN_TOFU       != PAIRWISE_SAS
OPEN_TOFU       != KNOWN_PEERS
GROUP_PSK_32    != PAIRWISE_SAS
GROUP_PSK_32    != KNOWN_PEERS
PAIRWISE_SAS    != KNOWN_PEERS
```

For `GROUP_PSK_32`, matching trust mode is necessary but not sufficient. The successful underlying PSK-authenticated pairwise connection proves possession of the configured group PSK.

For `KNOWN_PEERS`, automatic merge is disabled by default because different applications may have different allowlists. Automatic merge occurs only if every participating KNOWN_PEERS group explicitly opts in with `known_peers_auto_merge=1`; pairwise membership admission still requires each remote PeerId to pass the local allowlist.

If GroupIds are equal, this is membership reconciliation rather than a group merge.


## 31.4 Effective Group Capacity

Every committed peer contributes `GroupMemberRecord.max_peers`.

For a candidate group or merge:

```text
effective_max_peers =
    minimum(record.max_peers for every GroupMemberRecord in the candidate union)
```

The value is a total peer count including the local peer.

The framework MUST NOT arbitrarily select a subset of members in order to force a merge under the limit.

If:

```text
candidate_union_count > effective_max_peers
```

automatic merge MUST NOT occur.

The winning-side coordinator MUST send `GROUP_MERGE_REJECT`.

Frame:

```text
0x22 GROUP_MERGE_REJECT
```

Payload:

```text
16 bytes local_group_id
16 bytes remote_group_id
2 bytes  reason
2 bytes  effective_max_peers
2 bytes  candidate_union_count
```

Reasons:

```text
0x0001 GROUP_FULL
0x0002 NAMESPACE_MISMATCH
0x0003 JOIN_TOKEN_MISMATCH
0x0004 AUTO_MERGE_DISABLED
0x0005 DISCOVERY_MODE_MISMATCH
0x0006 STALE_TERM
```

A rejected merge leaves both groups independent.

## 31.5 Group Merge Rank

For two merge-compatible groups with different GroupIds:

```text
GroupMergeRank = (
    committed_member_count,
    group_id_preference
)
```

Higher committed_member_count wins.

If counts are equal, lexicographically smaller GroupId wins.

An established larger group therefore does not change GroupId merely because a singleton newcomer generated a smaller random GroupId.

## 31.6 GROUP_MERGE

Only the coordinator of the winning group may commit a merge.

If the winning group has no coordinator, election runs first.

Payload:

```text
16 bytes winning_group_id
16 bytes losing_group_id
8 bytes  new_coordinator_term
2 bytes  effective_max_peers
2 bytes  merged_member_count
N*18     merged GroupMemberRecord entries sorted lexicographically by peer_id
32 bytes merged_membership_hash
```

Where:

```text
new_coordinator_term =
    max(winning_term, losing_term) + 1
```

The winning coordinator already has the complete losing `GroupMemberRecord` list from authenticated GROUP_INFO.

Before sending GROUP_MERGE it MUST verify:

```text
merged_member_count <= effective_max_peers
```

The winning coordinator sends GROUP_MERGE with frame-header `ACK_REQUIRED=1` independently to all reachable members. Each recipient receives a distinct sender-allocated MessageId for that peer connection.

Members receiving a valid merge:

- replace GroupId with winning_group_id;
- retain losing_group_id as a historical alias for exactly 30 seconds;
- update coordinator term;
- update committed membership;
- update effective_max_peers;
- reconnect/reform coordinator star as needed.

A reconnecting peer presenting the losing GroupId during the 30-second alias period MUST be redirected to the winning GroupId after authentication.

After 30 seconds the alias MUST be discarded.

A GROUP_MERGE whose `new_coordinator_term` is less than or equal to the receiver's already-committed coordinator term MUST be ignored as stale unless it exactly matches an already-applied merge.

## 31.7 Same-Group Split-Brain Recovery

If authenticated GROUP_INFO records have the same GroupId but different membership hashes:

- GROUP_MERGE MUST NOT run;
- Section 10.10 reconciliation MUST run;
- reconciliation term is `max(term_A, term_B) + 1`;
- both complete `GroupMemberRecord` lists are available from GROUP_INFO;
- the capacity rule in Section 31.4 MUST be applied.

If the union exceeds effective_max_peers, the winner MUST NOT silently evict arbitrary peers.

Instead:

1. retain the winning coordinator's currently committed snapshot;
2. reject newly reconnecting members not already in that snapshot with `GROUP_FULL`;
3. emit GroupError indicating split-brain capacity conflict;
4. require application policy or explicit peer departure before expansion.

This deterministic rule prevents two implementations from choosing different victims.

## 31.8 Joining Through a Non-Coordinator

A new peer MAY first connect to any group member.

That member sends GROUP_INFO, including the complete committed membership list.

If another PeerId is coordinator, the joining peer MUST:

1. retain the bootstrap connection;
2. continue advertising and scanning;
3. attempt a direct authenticated connection to the coordinator;
4. identify the coordinator by authenticated PeerId, never a relayed BLE address;
5. wait up to 5000 ms.

If the coordinator is not directly found within 5000 ms, the existing member relays a reliable internal join indication to the coordinator.

The joining peer is not a committed member until the coordinator publishes MEMBERSHIP_SNAPSHOT containing its PeerId.

The coordinator MUST reject the join with `GROUP_FULL` if adding the peer would exceed effective_max_peers.

## 31.9 Group Leave and Membership Removal

Frame type:

```text
0x23 GROUP_LEAVE
```

`GROUP_LEAVE` MUST be encrypted and MUST set frame-header:

```text
ACK_REQUIRED = 1
```

Payload:

```text
Offset Size Field
0      16   group_id
16     8    coordinator_term uint64
24     16   leaving_peer_id
40     1    reason
41     3    reserved = 0
```

Reasons:

```text
0x01 APPLICATION_LEAVE
0x02 SESSION_CLOSING
0x03 KICKED
```

### 31.9.1 Normal Non-Coordinator Leave

When a non-coordinator calls `group.leave()`:

1. it MUST send `GROUP_LEAVE(APPLICATION_LEAVE)` to the current coordinator;
2. `leaving_peer_id` MUST equal the authenticated sender PeerId;
3. it waits up to 1000 ms for either:
   - generic ACK for the GROUP_LEAVE MessageId; or
   - a newer valid MEMBERSHIP_SNAPSHOT that excludes its PeerId;
4. after that 1000 ms grace, it MAY close its physical/group connections regardless of whether ACK arrived;
5. the coordinator, on accepting GROUP_LEAVE, MUST remove the member from committed membership without incrementing coordinator term;
6. the coordinator MUST publish a new ACK-required MEMBERSHIP_SNAPSHOT;
7. remaining members emit `MemberLeft` only after accepting the new committed snapshot.

A valid GROUP_LEAVE from a non-coordinator whose sender PeerId does not equal `leaving_peer_id` MUST be rejected with `AUTHENTICATION_FAILED`.

### 31.9.2 Session/Runtime Closing

If a non-coordinator GroupSession is being closed because its Runtime or application session is shutting down cleanly, it SHOULD send:

```text
GROUP_LEAVE(reason = SESSION_CLOSING)
```

using the same behavior as normal leave.

Failure to complete the leave exchange before process termination is handled as abrupt disappearance.

### 31.9.3 Coordinator Voluntary Leave

When the coordinator calls `group.leave()`:

1. it MUST send `COORDINATOR_RESIGN` to every READY member;
2. it MUST send `GROUP_LEAVE(APPLICATION_LEAVE)` with `leaving_peer_id = coordinator PeerId` to every READY member, with `ACK_REQUIRED=1`;
3. it SHOULD wait up to 500 ms for acknowledgments;
4. receiving members MUST immediately enter coordinator migration/election and MUST NOT wait for heartbeat timeout;
5. the newly elected coordinator MUST publish its first committed MEMBERSHIP_SNAPSHOT excluding the resigned coordinator;
6. the election MUST increment coordinator term according to the normal election rule;
7. the old coordinator MAY close after the 500 ms grace.

The resigning coordinator does not itself commit the post-leave membership snapshot.

### 31.9.4 Coordinator Kick

Only the current authenticated coordinator may issue:

```text
GROUP_LEAVE(reason = KICKED)
```

where `leaving_peer_id` identifies another committed member.

The coordinator MUST:

1. send the ACK-required GROUP_LEAVE to the target peer;
2. remove the target from committed membership;
3. publish a new ACK-required MEMBERSHIP_SNAPSHOT to remaining members;
4. close the target's group PeerConnection after ACK, after the new snapshot is sent, or after 1000 ms, whichever occurs first.

The kicked peer MUST leave the GroupSession after accepting the authenticated GROUP_LEAVE.

A non-coordinator attempting `KICKED` is a protocol error.

### 31.9.5 Abrupt Non-Coordinator Disappearance

If a non-coordinator member cannot send GROUP_LEAVE:

1. its PeerConnection enters RECONNECTING according to normal reconnect policy;
2. while reconnect is pending, the peer remains in committed membership;
3. when reconnect timeout expires and PeerConnection reaches terminal DISCONNECTED, the coordinator MUST remove that PeerId from committed membership;
4. coordinator term does NOT change;
5. coordinator MUST publish a new ACK-required MEMBERSHIP_SNAPSHOT;
6. remaining peers emit MemberLeft after accepting that snapshot.

This rule prevents permanently stale members from consuming `effective_max_peers`.

### 31.9.6 Abrupt Coordinator Disappearance

Abrupt coordinator disappearance follows automatic election.

The replacement coordinator's first committed MEMBERSHIP_SNAPSHOT MUST exclude the unavailable old coordinator.

If the old coordinator later returns, it MUST rejoin as a normal member using current GroupId/trust/capacity rules.

### 31.9.7 Membership Term Semantics

Normal join, leave, kick, and non-coordinator timeout membership changes:

```text
do NOT increment coordinator_term
```

Coordinator election, coordinator migration, group merge, and split-brain reconciliation:

```text
DO establish a newer coordinator_term according to their respective rules
```


## 31.10 Coordinator Checkpoint Frame

`publishCoordinatorCheckpoint(bytes)` uses frame type:

```text
0x1E COORDINATOR_CHECKPOINT
```

A coordinator checkpoint is one logical ACK-required operation that MAY consist of multiple `COORDINATOR_CHECKPOINT` frames.

The general control-frame plaintext limit remains:

```text
4096 bytes
```

The protocol MUST NOT increase that limit to carry checkpoints.

Maximum complete checkpoint data:

```text
MAX_COORDINATOR_CHECKPOINT = 262144 bytes
```

Maximum checkpoint data carried in one control frame:

```text
MAX_COORDINATOR_CHECKPOINT_CHUNK = 4000 bytes
```

Each checkpoint frame plaintext payload is:

```text
Offset Size Field
0      8    coordinator_term uint64
8      8    checkpoint_sequence uint64
16     4    total_length uint32
20     2    chunk_index uint16
22     2    chunk_count uint16
24     4    chunk_offset uint32
28     2    chunk_length uint16
30     2    reserved = 0
32     N    chunk_bytes
```

Where:

```text
0 <= N <= 4000
```

Maximum plaintext size:

```text
32 + 4000 = 4032 bytes
```

which is below the 4096-byte control-frame limit.

For EACH target peer for which a published checkpoint becomes an actual `in_flight_checkpoint` logical replication operation, the coordinator MUST:

1. allocate one `checkpoint_sequence` according to the per-target rules in the Coordinator Checkpoint Replication Queue subsection;

2. allocate one MessageId according to Section 19 for that target peer's `PeerConnection` and sender direction;

3. calculate:

```text
chunk_count = max(1, ceil(total_length / 4000))
```

4. send chunks in increasing `chunk_index`;

5. use the SAME per-peer MessageId in every chunk belonging to that target peer's logical checkpoint operation;

6. set `ACK_REQUIRED=1` on every chunk;

7. use a fresh reliable wire `sequence_number` on every chunk.

One application call to:

```text
publishCoordinatorCheckpoint(checkpoint_bytes)
```

does NOT allocate one global MessageId and does NOT allocate one global `checkpoint_sequence`.

Different target peers MAY transmit the same application checkpoint value using different MessageIds and different `checkpoint_sequence` values because:

- each target peer has an independent `PeerConnection`;
- MessageId allocation is scoped to one sender direction within one SessionId;
- checkpoint replication queues progress independently per target peer;
- a checkpoint may be in-flight for one peer, pending for another, and replaced before transmission for a third.

Checkpoint sequence allocation follows the per-target promotion rules in Section 31. It starts at 1 for each coordinator term and target peer, and increments only when a checkpoint becomes an actual in-flight wire operation.

For chunk `i`:

```text
chunk_index = i
chunk_offset = i * 4000
chunk_length = min(4000, total_length - chunk_offset)
```

For a zero-length checkpoint:

```text
total_length = 0
chunk_count = 1
chunk_index = 0
chunk_offset = 0
chunk_length = 0
```

For a non-empty checkpoint:

- every non-final chunk MUST have `chunk_length=4000`;
- the final chunk MUST satisfy `chunk_offset + chunk_length = total_length`.

The receiver MUST reject the logical checkpoint if:

- `total_length > 262144`;
- `chunk_count == 0`;
- `chunk_index >= chunk_count`;
- `chunk_offset != chunk_index * 4000`;
- `chunk_length > 4000`;
- a non-final non-empty chunk has `chunk_length != 4000`;
- final chunk boundaries do not equal `total_length`;
- chunks sharing one MessageId disagree on `coordinator_term`, `checkpoint_sequence`, `total_length`, or `chunk_count`;
- the same MessageId/chunk_index is received with different authenticated chunk bytes.

Checkpoint reassembly timeout:

```text
10000 ms
```

The reassembly timer runs only while the PeerConnection is READY.

If the PeerConnection leaves READY because of transport loss before reassembly completes, the receiver MUST immediately discard incomplete checkpoint reassembly state as defined in Section 26. It does NOT pause and retain the partial checkpoint across RECONNECTING.

The receiver MUST NOT ACK individual checkpoint chunks.

It sends exactly one generic ACK for the shared MessageId only after:

1. every checkpoint chunk has arrived;
2. the full checkpoint is reassembled;
3. the checkpoint is semantically accepted;
4. it is committed to local checkpoint storage.

A completed duplicate checkpoint MessageId MUST NOT be reapplied and MUST cause ACK to be sent again.

On retransmission, the sender MUST resend ALL chunks:

- with the same MessageId;
- with the same checkpoint_sequence;
- with identical checkpoint payload bytes;
- using new reliable wire sequence numbers.

An unacknowledged checkpoint survives RESUME under Section 23.

A member retains only the highest `checkpoint_sequence` for the highest coordinator term it has accepted.

An older valid checkpoint MAY be ACKed for dedup/reliability purposes but MUST NOT replace a newer retained checkpoint.



## 31.11 Coordinator Checkpoint Replication Queue

Coordinator checkpoints are ACK-required logical operations, but checkpoint publication is latest-state replication rather than an unbounded reliable event stream.

For EACH READY target peer, the coordinator MUST maintain exactly these bounded checkpoint replication slots:

```text
in_flight_checkpoint: 0 or 1 logical checkpoint operation
pending_checkpoint:   0 or 1 unpublished-to-wire checkpoint value
```

No additional per-peer checkpoint queue is permitted.

### 31.11.1 Publication While Idle

If `publishCoordinatorCheckpoint(bytes)` is called and a target peer has no `in_flight_checkpoint`:

1. the published checkpoint becomes that peer's `in_flight_checkpoint`;
2. allocate a new `checkpoint_sequence`;
3. allocate a new MessageId;
4. chunk and transmit it according to Section 31's coordinator-checkpoint frame rules.

### 31.11.2 Publication While a Checkpoint Is In Flight

If `publishCoordinatorCheckpoint(bytes)` is called while that target peer already has an `in_flight_checkpoint`:

```text
pending_checkpoint = newly published checkpoint
```

If a `pending_checkpoint` already exists, the new publication MUST replace it.

The replaced pending checkpoint:

- MUST NOT be transmitted;
- MUST NOT allocate a MessageId;
- MUST NOT allocate a `checkpoint_sequence`;
- MUST NOT consume ACK retry state;
- MUST NOT emit checkpoint-replication failure.

A newly published checkpoint MUST NOT cancel, truncate, or replace an already in-flight ACK-required checkpoint operation.

### 31.11.3 Promotion of Pending Checkpoint

When the current in-flight checkpoint reaches ANY terminal replication result for that target peer:

```text
ACK success
final ACK-timeout recovery
peer disconnect/session termination
checkpoint operation cancelled because target left group
```

the `in_flight_checkpoint` slot becomes empty.

If the target peer is still eligible for checkpoint replication and a `pending_checkpoint` exists:

1. remove the latest value from `pending_checkpoint`;
2. promote it to `in_flight_checkpoint`;
3. only NOW allocate its `checkpoint_sequence`;
4. allocate its MessageId;
5. transmit it as a fresh logical checkpoint operation.

Therefore checkpoints replaced while pending never consume checkpoint sequence values.

### 31.11.4 Sequence Allocation

`checkpoint_sequence` is allocated PER TARGET PEER when a checkpoint value becomes an actual `in_flight_checkpoint` logical replication operation.

It is NOT allocated merely because the application called `publishCoordinatorCheckpoint()`.

For each coordinator term and target peer:

```text
first transmitted checkpoint_sequence = 1
next transmitted checkpoint_sequence = previous transmitted sequence + 1
```

Pending replacement does not create sequence gaps.

If the same application checkpoint value becomes in-flight for multiple target peers:

- each peer's operation MUST allocate its own MessageId from that peer connection's sender-direction MessageId sequence;
- each peer's operation MUST allocate its own `checkpoint_sequence` from that peer's checkpoint-replication sequence;
- those values MAY differ across peers even though the application checkpoint bytes are identical.

An implementation MAY internally share immutable checkpoint payload storage or assign a non-wire application checkpoint version identifier, but neither optimization changes the per-peer wire-visible MessageId or `checkpoint_sequence` rules.

### 31.11.5 Retained Latest Checkpoint Value

Independently from per-peer replication slots, `GroupSession` MUST retain exactly one application-level:

```text
latestCoordinatorCheckpoint
```

representing the most recent value passed to `publishCoordinatorCheckpoint()`.

This retained latest value:

- replaces the previous retained value immediately on publish;
- is returned by `latestCoordinatorCheckpoint()`;
- is the value supplied to a newly promoted coordinator when available;
- does not imply that every peer has already ACKed that checkpoint.

### 31.11.6 Peer Join and Resynchronization

When a peer newly becomes READY or returns to synchronized group membership after reconnect:

- if `latestCoordinatorCheckpoint` exists;
- and checkpoint replication is enabled;

the coordinator SHOULD schedule that latest value for the peer using the same one-in-flight/one-pending rules.

It MUST NOT reconstruct or enqueue every historical checkpoint publication.

### 31.11.7 Memory Bound

Per target peer, the implementation may retain checkpoint payload memory for at most:

```text
1 in-flight checkpoint
1 pending checkpoint
```

plus the single GroupSession-wide `latestCoordinatorCheckpoint` value.

Implementations MAY share immutable buffers between these references, but observable queue semantics MUST remain exactly as specified.

This rule is REQUIRED even if checkpoint publication occurs faster than transport throughput.


## 31.12 Group Ready Condition

A GroupSession enters READY only when:

- connection/session security satisfies GroupConfig.groupTrustMode;
- a GroupId is committed;
- a coordinator is committed;
- local peer appears in the committed MEMBERSHIP_SNAPSHOT;
- if local peer is not coordinator, a direct authenticated/encrypted PeerConnection to coordinator is READY.

`GroupReady` MUST NOT be emitted earlier.


# 32. Automatic Group API

`GroupSession` is the primary multi-peer application object for protocol minor 1.

It automates networking coordinator selection and migration. It does not imply strong first-contact peer authentication unless the application selects a trust mode that provides it.

## 32.1 Runtime Method

```text
joinOrCreateGroup(GroupConfig config) -> GroupSession
```

`joinOrCreateGroup()` MUST:

1. begin BLE advertising;
2. begin BLE discovery;
3. discover compatible LPC peers;
4. establish bootstrap connections as needed;
5. apply the configured GroupTrustMode;
6. exchange GROUP_INFO;
7. join one compatible group or create a singleton group;
8. merge compatible groups if permitted and capacity allows;
9. elect or adopt a coordinator;
10. establish the coordinator star;
11. emit GroupReady.

## 32.2 GroupTrustMode

Exact values:

```text
0x01 OPEN_TOFU
0x02 GROUP_PSK_32
0x03 PAIRWISE_SAS
0x04 KNOWN_PEERS
```

Default for `GroupSession`:

```text
OPEN_TOFU
```

This is an intentional product choice to make casual local multiplayer zero-confirmation.

Security meaning:

```text
OPEN_TOFU:
    encrypted session;
    persistent Ed25519 identity continuity;
    first-contact human/device identity is NOT authenticated;
    no verification UI required.

GROUP_PSK_32:
    all group members possess the same exact 32-byte cryptographically random secret;
    first-contact group membership is authenticated by that secret;
    no pairwise SAS prompts.

PAIRWISE_SAS:
    each newly established PeerConnection to a previously unknown peer requires SAS confirmation;
    highest user friction.

KNOWN_PEERS:
    only pre-known PeerIds are admitted.
```

Documentation MUST call OPEN_TOFU "encrypted TOFU", not "authenticated identity".

A low-entropy room code is not valid GROUP_PSK_32.

The lower-level `RuntimeConfig.trustMode` remains the default for explicit PeerConnection/HostSession APIs. GroupSession uses `groupTrustMode` from GroupConfig instead.



### Security Profile Guidance

`OPEN_TOFU` is the default only for low-friction casual local multiplayer.

Applications handling private or persistent user content SHOULD select a stronger mode.

| Application | Recommended trust profile |
|---|---|
| Casual party game | `OPEN_TOFU` |
| Private game room | `GROUP_PSK_32` |
| Ad-hoc whiteboard | `PAIRWISE_SAS` or `GROUP_PSK_32` |
| Private messaging | `PAIRWISE_SAS`, `KNOWN_PEERS`, or strong `GROUP_PSK_32` |

These are security guidance, not additional wire modes.

GroupSession relay encryption is hop-by-hop between authenticated PeerConnections. The coordinator necessarily sees relayed application plaintext after LPC decryption and before forwarding.

Applications requiring cryptographic end-to-end confidentiality between two non-coordinator members MUST additionally encrypt their application payload end-to-end above LPC.

For `PAIRWISE_SAS`, SAS authentication applies to each actual PeerConnection that is established. In a coordinator star, non-coordinator members do not automatically establish pairwise SAS-authenticated links to every other member.

## 32.3 Pairwise Handshake Mapping

For every `PeerConnection` created internally by `GroupSession`, the pairwise HELLO `trust_mode` and credential source MUST be selected exactly as follows:

| GroupTrustMode | Pairwise HELLO trust_mode | Credential / verification source |
|---|---:|---|
| `OPEN_TOFU` | `TOFU` (`0x04`) | none |
| `GROUP_PSK_32` | `PSK_32` (`0x03`) | `GroupConfig.groupPsk32` |
| `PAIRWISE_SAS` | `SAS` (`0x02`) | normal SAS confirmation callback/UI |
| `KNOWN_PEERS` | `KNOWN_PEER` (`0x01`) | `KnownPeerPolicy=ALLOWLIST`, using `GroupConfig.allowedPeerIds` |

Rules:

- `RuntimeConfig.trustMode` MUST NOT affect any `PeerConnection` created internally by `GroupSession`.
- `GroupSession` MUST configure the pairwise HELLO `trust_mode` before the transport connection sends HELLO.
- Both peers MUST use the same mapped pairwise trust mode for the connection to continue.
- For `GROUP_PSK_32`, the exact 32 bytes from `GroupConfig.groupPsk32` MUST be used as the pairwise `PSK_32` input.
- For `KNOWN_PEERS`, GroupSession MUST configure pairwise `KnownPeerPolicy=ALLOWLIST` with exactly `GroupConfig.allowedPeerIds`; the authenticated remote `PeerId` MUST be present or the connection fails `AUTHENTICATION_FAILED`.
- `OPEN_TOFU` provides encrypted first-contact continuity only. It MUST NOT be described as verified human/device identity.


## 32.4 GroupConfig

```text
GroupConfig {
    applicationNamespace: bytes 1..32
    discoveryMode = TOKEN_SCOPED
    groupJoinToken: 16 bytes required in TOKEN_SCOPED mode
    maxPeers = 8
    applicationCoordinatorPriority = 0
    autoAccept = true
    autoMerge = true
    groupTrustMode = OPEN_TOFU
    groupPsk32 optional, required for GROUP_PSK_32
    allowedPeerIds = []          // required/non-empty for KNOWN_PEERS
    knownPeersAutoMerge = false
    coordinatorCheckpointing = false
}
```

Validation:

- `applicationNamespace` is mandatory;
- `groupJoinToken` MUST be exactly 16 bytes in TOKEN_SCOPED mode;
- `groupJoinToken` MUST be absent in OPEN_PROXIMITY mode;
- GROUP_PSK_32 requires exactly 32 cryptographically random secret bytes;
- KNOWN_PEERS requires a non-empty `allowedPeerIds` set;
- `knownPeersAutoMerge` MUST be false unless `groupTrustMode == KNOWN_PEERS`;
- maxPeers valid range is 1..31.

`TOKEN_SCOPED` is the default because the networking layer cannot infer which independently intended game/lobby a nearby peer belongs to.

`groupJoinToken` scopes automatic merging only. It is not an authentication credential and MUST NOT be used to bypass GroupTrustMode checks.

Applications wanting "everyone nearby automatically becomes one group" MUST explicitly select `OPEN_PROXIMITY`.


### Group Scoping Examples

```text
Quick nearby party game:
    discoveryMode = OPEN_PROXIMITY

Room/lobby game:
    discoveryMode = TOKEN_SCOPED
    groupJoinToken = lobby-specific 16-byte token

Ad-hoc whiteboard:
    discoveryMode = TOKEN_SCOPED
    groupJoinToken = document/session-specific 16-byte token

Private messaging room:
    discoveryMode = TOKEN_SCOPED
    groupJoinToken = conversation/room-specific 16-byte token
```

`groupJoinToken` is only a grouping scope value and is never an authentication secret.

## 32.5 GroupMember Public Structure

`members()` returns an immutable snapshot of:

```text
GroupMember {
    peerId: PeerId
    maxPeers: uint16
}
```

Membership in this list means the peer is present in the latest committed `MEMBERSHIP_SNAPSHOT`.

It does NOT imply that the local device has a direct member-to-member PeerConnection to that peer.

In the coordinator-star topology, non-coordinator members normally have only a direct PeerConnection to the coordinator.

## 32.6 GroupSession Methods

```text
groupId() -> GroupId
localPeerId() -> PeerId
coordinatorPeerId() -> PeerId optional
isCoordinator() -> bool
members() -> snapshot list<GroupMember>
effectiveMaxPeers() -> uint16
state() -> GroupState

send(peerId, bytes, SendOptions) -> SendHandle
broadcast(bytes, SendOptions) -> BroadcastHandle

sendRealtime(peerId, channelId, bytes, RealtimeOptions) -> RealtimeSendHandle
broadcastRealtime(channelId, bytes, RealtimeOptions) -> RealtimeBroadcastHandle

publishCoordinatorCheckpoint(bytes)
latestCoordinatorCheckpoint() -> bytes optional

events()
leave()
close()
```



### Method State Validity

Application traffic methods:

```text
send
broadcast
sendRealtime
broadcastRealtime
```

are accepted only while `GroupState == READY`.

Otherwise they fail synchronously/return a failed handle with `INVALID_STATE`.

If one of these calls races with `leave()`, the per-object serialization rule in Section 52 determines which operation is accepted first:

```text
send/broadcast accepted first:
    its handle is created;
    if LEAVING commits while still nonterminal, normal leave
    cancellation rules apply

LEAVING commits first:
    new send/broadcast fails INVALID_STATE
```

`members()`, `state()`, coordinator getters, diagnostics, and event subscription remain valid until CLOSED according to their normal snapshot semantics.

## 32.7 GroupSession Send Routing Semantics

The `peerId` argument to:

```text
send(peerId, ...)
sendRealtime(peerId, ...)
```

always names the END APPLICATION DESTINATION.

It does NOT require a direct local `PeerConnection` to that peer.

For a READY coordinator-star group:

```text
source is coordinator:
    coordinator -> destination

destination is coordinator:
    source -> coordinator

source and destination are both non-coordinators:
    source -> coordinator -> destination
```

The coordinator relay behavior in Section 43 is REQUIRED.

A conforming implementation MUST NOT:

- create an ad-hoc member-to-member application PeerConnection merely because `send(peerId, ...)` was called;
- fail `send(peerId, ...)` solely because no direct source-to-destination PeerConnection exists;
- keep all bootstrap member-to-member links open merely to implement application sends.

`send(localPeerId, ...)` and `sendRealtime(localPeerId, ...)` MUST fail with `INVALID_ARGUMENT`.

A destination PeerId not present in the current committed membership snapshot MUST fail with `DESTINATION_NOT_IN_GROUP`.

For `GroupSession.send(..., RELIABLE_ORDERED)`, public `SendHandle.SENT_TO_TRANSPORT` means the complete routed logical message has reached frame-level `SENT_TO_TRANSPORT` on the final end-destination hop.

For a non-coordinator source sending to another non-coordinator, the source waits for authenticated `GROUP_RELAY_STATUS(SENT_TO_DESTINATION_TRANSPORT)` before its public SendHandle reaches `SENT_TO_TRANSPORT`.

This is still NOT proof of destination application delivery.

The `final end-destination hop` is defined exactly as:

```text
non-coordinator source -> coordinator destination:
    source -> coordinator is the final end-destination hop

coordinator source -> non-coordinator destination:
    coordinator -> destination is the final end-destination hop

non-coordinator source -> non-coordinator destination:
    coordinator -> destination is the final end-destination hop
```

For `GroupSession.send(..., RELIABLE_ACKED)`, public `SendHandle.REMOTE_ACKNOWLEDGED` means the requested destination peer accepted and committed the complete application message.

A hop-local generic ACK from the coordinator to the source MUST NOT complete the public SendHandle.

The coordinator emits `GROUP_DELIVERY_ACK` only after destination acceptance as defined in Section 43.

`sendRealtime()` remains unacknowledged latest-state delivery.

For a non-coordinator source, `RealtimeSendHandle.SENT_TO_TRANSPORT` means the routed realtime envelope reached `SENT_TO_TRANSPORT` on the source-to-coordinator hop. It does NOT confirm coordinator-to-destination submission or destination receipt.

## 32.8 GroupState

Exact states:

```text
STARTING
DISCOVERING
FORMING
ELECTING
READY
MIGRATING_COORDINATOR
LEAVING
CLOSED
FAILED
```

Exact allowed transitions:

```text
STARTING -> DISCOVERING
STARTING -> FAILED

DISCOVERING -> FORMING
DISCOVERING -> ELECTING
DISCOVERING -> LEAVING
DISCOVERING -> FAILED

FORMING -> ELECTING
FORMING -> READY
FORMING -> LEAVING
FORMING -> FAILED

ELECTING -> FORMING
ELECTING -> READY
ELECTING -> LEAVING
ELECTING -> FAILED

READY -> MIGRATING_COORDINATOR
READY -> FORMING
READY -> LEAVING
READY -> FAILED

MIGRATING_COORDINATOR -> ELECTING
MIGRATING_COORDINATOR -> READY
MIGRATING_COORDINATOR -> LEAVING
MIGRATING_COORDINATOR -> FAILED

LEAVING -> CLOSED
FAILED -> CLOSED
```

No other GroupState transition is valid.

A coordinator heartbeat timeout while READY MUST cause:

```text
READY -> MIGRATING_COORDINATOR -> ELECTING
```

A successful election and direct coordinator link MUST cause:

```text
ELECTING -> FORMING -> READY
```

## 32.9 Group Events

All GroupSession events begin with:

```text
GroupEventHeader {
    eventSequence: uint64
    observedAtMonotonicMs: uint64
}
```

`eventSequence` starts at 1 for each GroupSession and increments by exactly 1 for every application-visible GroupSession event.

`observedAtMonotonicMs` is local diagnostic time and is not comparable across devices.

Exact event payloads:

```text
GroupReady {
    header
    groupId
    coordinatorPeerId
    coordinatorTerm: uint64
    members: snapshot list<GroupMember>
}

MemberFound {
    header
    peerId
    securityLevel
}

MemberJoined {
    header
    member: GroupMember
}

MemberLeft {
    header
    peerId
    reason:
        APPLICATION_LEAVE
        SESSION_CLOSING
        KICKED
        CONNECTION_TIMEOUT
        RECONCILIATION
}

CoordinatorElectionStarted {
    header
    previousCoordinatorPeerId optional
    candidateTerm: uint64
}

CoordinatorChanged {
    header
    previousCoordinatorPeerId optional
    coordinatorPeerId
    coordinatorTerm: uint64
    localIsCoordinator: bool
    latestCheckpoint: bytes optional
}

CoordinatorCheckpointUpdated {
    header
    coordinatorPeerId
    checkpointSequence: uint64
    bytes
}

CoordinatorCheckpointReplicationFailed {
    header
    peerId
    checkpointSequence: uint64
    errorCode
}

ReliableMessageReceived {
    header
    sourcePeerId
    groupMessageId: GroupMessageId
    deliveryMode: RELIABLE_ORDERED | RELIABLE_ACKED
    bytes
}

RealtimeDatagramReceived {
    header
    sourcePeerId
    channelId: uint16
    senderTick: uint64
    datagramSequence: uint32
    bytes
}

GroupTransportChanged {
    header
    peerId
    previousTransport optional
    currentTransport
    transportGeneration: uint32
}

GroupMergeRejected {
    header
    remoteGroupId
    reason
    effectiveMaxPeers: uint16
    candidateUnionCount: uint16
}

GroupError {
    header
    errorCode
    peerId optional
    groupMessageId optional
    diagnostic: UTF-8 string optional
}

GroupClosed {
    header
    reason
}
```

`ReliableMessageReceived.sourcePeerId` and `RealtimeDatagramReceived.sourcePeerId` are always the ORIGINAL application sender, not the coordinator relay.

The Section 43 relay source-identity validation rules MUST pass before either event is emitted.

Pairwise LPC `MessageId` values are protocol-internal and MUST NOT be substituted for `ReliableMessageReceived.groupMessageId`.

`MemberFound` is emitted only after a bootstrap PeerConnection has authenticated enough to establish the peer's PeerId and SecurityLevel. Raw unauthenticated BLE discovery remains a Runtime-level `EndpointFound` event and MUST NOT be exposed as an authenticated GroupSession MemberFound.


## 32.10 Coordinator Transparency

The application MAY query `isCoordinator()` when it needs to run authoritative application logic.

The application MUST NOT be required to choose the coordinator.

When coordinator migration completes, all remaining members keep the same GroupSession object.

No new GroupSession is created.

## 32.11 Coordinator Application State

The framework migrates networking coordination automatically.

Application authority can migrate automatically only if the application supplies recoverable state.

For games using an authoritative simulation, the application SHOULD:

```text
publishCoordinatorCheckpoint(serializedAuthoritativeState)
```

at 1 to 4 Hz.

After local promotion, the application receives:

```text
CoordinatorChanged(
    localIsCoordinator = true,
    latestCheckpoint = ...
)
```

The application restores its own authoritative state from that checkpoint.

The framework MUST NOT interpret game-specific checkpoint bytes.


# 33. Low-Level Public API Contract and Ownership

All bindings MUST preserve the object ownership and lifecycle defined here.

## 33.1 NearbyRuntime

Construction returns one runtime object.

Configuration:

```text
RuntimeConfig {
    serviceUuid
    trustMode = SAS   // low-level explicit connection default; GroupSession overrides via GroupConfig
    expectedPeerId optional
    psk32 optional
    enableGatt = true
    enableL2cap = true
    enableLan = true
    autoReconnect = true
    keepaliveIntervalMs = 2000
    reconnectTimeoutMs = 15000
    maxQueuedBytesPerPeer = 262144
    maxQueuedMessagesPerPeer = 1024
    maxApplicationMessageBytes = 1048576
}
```

Validation:

- `PSK_32` requires exactly 32-byte `psk32`;
- `KNOWN_PEER` connection requires either `EXPECT_EXACT_PEER(expectedPeerId)` or `ALLOWLIST(nonEmptyAllowedPeerIds)`;
- `keepaliveIntervalMs` must be 1000..10000;
- `reconnectTimeoutMs` must be 1000..60000.

Ownership:

- Runtime owns every GroupSession, HostSession, DiscoverySession, ConnectionAttempt, and PeerConnection created from it.
- Child objects MUST NOT outlive Runtime.
- `runtime.close()` cascades closure to all children.

Methods:

```text
capabilities() -> LocalRuntimeCapabilities
joinOrCreateGroup(config) -> GroupSession
createHostSession(config) -> HostSession  // advanced explicit-role API
startDiscovery(config) -> DiscoverySession
connect(discoveryEndpointId, config) -> ConnectionAttempt
events() -> event source
close()
```

A runtime may have:

```text
at most 1 active HostSession advertising
at most 1 active DiscoverySession per configured service UUID
multiple PeerConnections
```

`close()` is idempotent.

After RuntimeClosed, mutating operations fail `INVALID_STATE`.

## 33.2 HostSession

Configuration:

```text
HostConfig {
    maxPeers = 7
    topology = STAR
    applicationMetadata = bytes <= 31
    autoAccept = false
    trustMode optional override
}
```

Methods:

```text
startAdvertising()
stopAdvertising()
accept(requestId)
reject(requestId, reason)
confirmPeerVerification(peerId, accepted)
send(peerId, bytes, options) -> SendHandle
broadcast(bytes, options) -> BroadcastHandle
disconnect(peerId, reason)
peers() -> snapshot list<PeerConnection>
events()
close()
```

Ownership/lifecycle:

- HostSession owns no Runtime. Runtime owns HostSession.
- `close()` stops advertising first.
- It then sends graceful CLOSE to READY peers.
- It waits at most 1000 ms for close flushing.
- It force-closes remaining transports.
- It emits terminal HostSessionClosed.
- Repeated `close()` is idempotent.

## 33.3 DiscoverySession

Methods:

```text
currentEndpoints() -> snapshot list<DiscoveredEndpoint>
events()
stop()
```

`currentEndpoints()` returns a snapshot, not a live mutable collection.

`stop()`:

- stops platform scanning;
- emits DiscoveryStopped once;
- is idempotent;
- does not close existing PeerConnections;
- does not close Runtime.

## 33.4 ConnectionAttempt

`runtime.connect()` returns a ConnectionAttempt immediately in callback/event bindings, or an awaitable wrapper around the same conceptual object.

Methods:

```text
cancel()
confirmPeerVerification(accepted)
events()
```

Terminal outcomes:

```text
Connected(PeerConnection)
Failed(error)
Cancelled
```

On `Connected`, Runtime owns the resulting PeerConnection. The ConnectionAttempt becomes terminal.

`cancel()` after terminal state is a no-op.

## 33.5 PeerConnection

PeerConnection remains a valid read-only diagnostic handle after disconnection, but cannot send.

Methods:

```text
peerId()
sessionId()
securityLevel()
state()
activeTransport()
send(bytes, options) -> SendHandle
confirmPeerVerification(accepted)  // valid only while verification pending
events()
disconnect()
```

`disconnect()` is idempotent.

After DISCONNECTED:

- `send()` fails `INVALID_STATE`;
- identity/session diagnostics remain readable.

## 33.6 Event Subscription Ownership

Every event subscription MUST have explicit cancellation/disposal.

Closing the owning Runtime/Session/Connection automatically terminates its event subscriptions.

No event callback may be invoked after its subscription has emitted the owner's terminal closed event.

---

# 34. Application Events

Exact event names:

```text
RuntimeReady
RuntimeCapabilityChanged
RuntimeError
EndpointFound
EndpointUpdated
EndpointLost
ConnectionRequested
PeerAuthenticating
PeerVerificationRequired
PeerConnected
PeerReconnecting
PeerReconnected
PeerDisconnected
MessageReceived
RealtimeDatagramReceived
MessageAcknowledged
CoordinatorElectionStarted
CoordinatorChanged
TransportUpgradeStarted
TransportChanged
TransportUpgradeFailed
QueuePressure
SessionError
RuntimeClosed
```

Every event includes monotonic local timestamp.

`PeerConnected` MUST include:

```text
PeerId
SessionId
SecurityLevel
authenticated application metadata
active transport
```

Application metadata received in HELLO becomes authenticated only after AUTH succeeds.

---

# 35. Connection Request Behavior

When the host accepts a physical request, before authentication it emits:

```text
ConnectionRequested {
    requestId
    discoveryEndpointId/local backend handle if available
    unauthenticated local-name hint optional
    expiresAt
}
```

Default request timeout is 10,000 ms.

If not accepted/rejected before timeout, SDK rejects and reports `REQUEST_TIMEOUT`.

PeerId is not available as trusted identity until HELLO/AUTH.

If `autoAccept=true`, transport establishment may proceed automatically, but `PeerConnected` still waits for AUTH and configured trust-mode verification.

---

# 36. Send API and Delivery Semantics

The old `requireRemoteAck` option is removed from the public API.

`SendOptions` MUST contain:

```text
deliveryMode
priority
expiryMs
```

Delivery modes:

```text
RELIABLE_ORDERED
RELIABLE_ACKED
REALTIME_LATEST
```

For convenience, bindings MUST expose dedicated realtime methods rather than requiring callers to construct generic DATA messages.

## 36.1 Reliable SendHandle

States:

```text
QUEUED
TRANSMITTING
SENT_TO_TRANSPORT
REMOTE_ACKNOWLEDGED
FAILED
CANCELLED
```

For `RELIABLE_ORDERED`, successful terminal state is `SENT_TO_TRANSPORT`.

For `RELIABLE_ACKED`, successful terminal state is `REMOTE_ACKNOWLEDGED`.

Defaults for `send()`:

```text
deliveryMode = RELIABLE_ORDERED
priority = INTERACTIVE
expiryMs = 5000
```

Therefore normal messages do NOT require an LPC ACK by default.

Application-facing documentation MUST state prominently:

```text
RELIABLE_ORDERED
    = ordered, transport-submitted message
    = no destination application acknowledgment guarantee

RELIABLE_ACKED
    = destination-recipient-confirmed reliable message
    = duplicate-suppressed exactly once only within the bounded
      GroupMessageId/MessageId deduplication window
```

Documentation MUST NOT claim that `RELIABLE_ORDERED` guarantees application delivery after it reaches `SENT_TO_TRANSPORT`.

## 36.2 RealtimeSendHandle

`sendRealtime()` uses REALTIME_LATEST and has terminal states:

```text
QUEUED
TRANSMITTING
SENT_TO_TRANSPORT
SUPERSEDED
EXPIRED
FAILED
CANCELLED
```

Defaults:

```text
expiryMs = 100
```

It has no REMOTE_ACKNOWLEDGED state.

## 36.3 Reconnect Behavior

After a reconnect:

- RELIABLE_ACKED messages that were not ACKed are retransmitted according to Section 23;
- RELIABLE_ORDERED messages already at SENT_TO_TRANSPORT are not retransmitted;
- queued reliable messages that never began transmission remain eligible to send unless expired;
- REALTIME_LATEST messages from before the disconnect are discarded;
- the application is expected to submit a fresh current realtime state after PeerReconnected/CoordinatorChanged.

## 36.4 Frame-Level vs SendHandle-Level SENT_TO_TRANSPORT

The protocol uses `SENT_TO_TRANSPORT` at two different scopes.

### 36.4.1 Frame-Level SENT_TO_TRANSPORT

One serialized LPC frame reaches frame-level `SENT_TO_TRANSPORT` only at the exact platform-submission boundary defined in Section 23.

### 36.4.2 SendHandle SENT_TO_TRANSPORT

For a logical application message represented by one or more DATA frames:

```text
SendHandle.SENT_TO_TRANSPORT
```

is reached only after EVERY DATA frame/chunk belonging to that logical application message has individually reached frame-level `SENT_TO_TRANSPORT`.

A successfully submitted earlier chunk MUST NOT cause the application `SendHandle` itself to enter `SENT_TO_TRANSPORT`.

For a one-frame application message, frame-level and SendHandle-level transitions occur at the same point.

For a multi-frame message:

```text
chunk 0 SENT_TO_TRANSPORT
chunk 1 SENT_TO_TRANSPORT
...
chunk N SENT_TO_TRANSPORT
        |
        v
SendHandle.SENT_TO_TRANSPORT
```

If transport failure occurs before all chunks reach frame-level `SENT_TO_TRANSPORT`, the SendHandle has NOT reached its successful `SENT_TO_TRANSPORT` state.

For `RELIABLE_ORDERED`, recovery then follows Section 21.2.

For `RELIABLE_ACKED`, successful terminal state remains `REMOTE_ACKNOWLEDGED`, and recovery follows Sections 21.3 and 23.

## 36.5 BroadcastHandle

`broadcast(bytes, options)` is a set of independent `send(peerId, ...)` operations.

The target set is captured atomically when `broadcast()` is accepted:

```text
targetPeerIds =
    all PeerIds in the current committed membership snapshot
    except localPeerId
```

The local peer is never included.

A member joining afterward MUST NOT receive that broadcast.

A member leaving afterward remains a constituent target and its individual SendHandle may fail normally.

```text
BroadcastHandle {
    targetPeerIds: immutable lexicographically sorted list<PeerId>
    results: immutable-key map<PeerId, SendHandle>

    state:
        ACTIVE
        COMPLETED
        CANCELLED
}
```

`results[peerId]` exists for every target when the handle is returned.

`ACTIVE` means at least one constituent is non-terminal.

`COMPLETED` means every constituent SendHandle is terminal. It does NOT mean all succeeded.

`CANCELLED` means cancellation was requested and every non-terminal constituent has been asked to cancel.

For an empty target set, the handle is immediately `COMPLETED`.

Cancellation cannot undo delivery already committed at a destination.

## 36.6 RealtimeBroadcastHandle

`broadcastRealtime()` snapshots the same committed remote-member target set and creates one independent `sendRealtime()` per target.

Constituent realtime submissions MUST be created in lexicographic target order.

```text
RealtimeBroadcastHandle {
    targetPeerIds: immutable lexicographically sorted list<PeerId>
    results: immutable-key map<PeerId, RealtimeSendHandle>

    state:
        ACTIVE
        COMPLETED
        CANCELLED
}
```

`COMPLETED` means every constituent is terminal, including any mix of:

```text
SENT_TO_TRANSPORT
SUPERSEDED
EXPIRED
FAILED
CANCELLED
```

A realtime broadcast is not atomic and has no all-destinations delivery guarantee.

## 36.7 No Group-Wide Total Ordering or Atomic Broadcast

LPC does NOT provide a total order across application messages originating from different PeerConnections or different source PeerIds.

Reliable ordering is defined per source/destination routing stream in Section 43.

`broadcast()` does NOT create an atomic group operation.

Each broadcast destination is an independent delivery operation with its own GroupMessageId, SendHandle, route outcome, retry state, and terminal result.

Applications requiring consensus, a globally ordered log, atomic commit, CRDT semantics, or causal ordering across multiple senders MUST implement that behavior above LPC.


## 36.8 Reliable Send Cancellation

`SendHandle.cancel()` is a LOCAL best-effort cancellation operation.

Protocol minor 1 defines no routed application-message revocation frame.

Therefore cancellation MUST NOT be interpreted as proof that the destination did not receive the operation.

Exact behavior:

```text
if reliable operation has not begun transmission:
    remove it from the local application/reliable queue
    transmit no application frame
    transition public SendHandle -> CANCELLED

if transmission has begun and public SendHandle is still nonterminal:
    stop future source-side transmission/retransmission where possible
    remove the operation from future source-side reroute/retry eligibility
    transition public SendHandle -> CANCELLED
```

For a `GroupSession` routed send, once any source-hop bytes may have been accepted by the coordinator:

- the coordinator MAY already have admitted the destination relay;
- the coordinator MAY continue forwarding after the source handle becomes `CANCELLED`;
- the destination MAY still receive and commit the message;
- no protocol-minor-1 frame exists for the source to revoke an already admitted relay operation.

A subsequent valid `GROUP_DELIVERY_ACK` or `GROUP_RELAY_STATUS` for that cancelled GroupMessageId MUST NOT transition the public SendHandle out of `CANCELLED`.

`CANCELLED` means:

```text
the local SDK stopped pursuing/reporting normal completion
for that send
```

It does NOT mean:

```text
the destination definitely did not receive the send
```

Applications MUST NOT use `CANCELLED` as proof that an externally consequential operation, such as a purchase, mutation, command, or state transition, did not occur remotely.

### 36.8.1 Cancelled GroupMessageId Tombstone

When a routed reliable GroupSession send becomes `CANCELLED`, the source MUST retain a lightweight cancellation tombstone:

```text
CancelledGroupSendTombstone {
    groupMessageId
    destinationPeerId
    originalDeliveryMode
}
```

The tombstone MUST NOT retain application payload bytes and MUST NOT preserve reroute/retry eligibility.

The tombstone MUST be retained until the EARLIER of:

```text
1. GroupSession closes

or

2. all pairwise route-signaling operations that were already validly
   in flight for that GroupMessageId can no longer arrive because
   every PeerConnection SessionId capable of carrying such signaling
   has terminated
```

Either condition independently makes the tombstone unnecessary.

When condition 2 occurs while the GroupSession remains open, the tombstone MUST be released immediately and MUST no longer consume cancellation-tombstone capacity.

When condition 1 occurs, all tombstones are released as part of GroupSession destruction.

An implementation MAY use a bounded tombstone table.

If the bound would be exceeded, it MUST fail a NEW routed send with `RESOURCE_EXHAUSTED` rather than silently evicting a tombstone that is still required to recognize valid late signaling.

### 36.8.2 Late Route Signaling After Cancellation

If `GROUP_DELIVERY_ACK` or `GROUP_RELAY_STATUS` arrives for a recently cancelled send whose tombstone matches:

1. authenticate and validate the control frame normally;
2. verify source/destination/GroupMessageId correlation against the tombstone;
3. generic-ACK the ACK-required signaling operation normally;
4. record diagnostics if desired;
5. discard the semantic completion/failure result;
6. leave the public SendHandle permanently `CANCELLED`.

A valid late signaling frame matching a cancellation tombstone MUST NOT be treated as `PROTOCOL_MISMATCH`, `MESSAGE_ID_COLLISION`, or unknown-send corruption merely because the original public handle is already terminal.

Former-coordinator stale signaling is governed by Section 43. A coordinator migration race does not grant the old coordinator semantic completion authority, but an already-in-flight ACK-required signaling operation may still be generic-ACKed and discarded deterministically.

### 36.8.3 Broadcast Cancellation

Cancelling a `BroadcastHandle` or `RealtimeBroadcastHandle` invokes cancellation on each nonterminal constituent handle according to that handle's own rules.

Cancellation of a reliable broadcast does NOT revoke any constituent operation already accepted by a coordinator or destination.

The broadcast handle's terminal state remains `CANCELLED` once broadcast cancellation is requested, even if some constituent remote deliveries complete later.
# 37. Queueing and Scheduling

Reliable queue defaults per peer:

```text
maxQueuedBytes = 262144
maxQueuedMessages = 1024
```

Reliable messages preserve acceptance order.

SDK control frames may interleave between reliable chunks.

Realtime traffic uses a separate queue keyed by:

```text
(peerId, channelId)
```

There may be at most one not-yet-started realtime datagram for each key.

New realtime state replaces the old queued state for the same key.

Scheduling precedence:

```text
SDK CONTROL
REALTIME_LATEST
RELIABLE INTERACTIVE
RELIABLE NORMAL
RELIABLE BULK
```

To prevent starvation, after transmitting 8 consecutive realtime datagrams, the scheduler MUST transmit one queued reliable INTERACTIVE/NORMAL chunk if one exists.

A BULK transfer MUST yield after every DATA chunk.

No queue may grow without a configured bound.


---

## 37.1 Group Routing Queue Rules

GroupSession reliable routing uses existing bounded per-peer reliable queues on each physical hop.

The coordinator MUST NOT create an unbounded relay queue.

Coordinator realtime pending state is keyed by:

```text
(sourcePeerId, destinationPeerId, channelId)
```

There may be at most one not-yet-submitted `GROUP_REALTIME_DATAGRAM` for each key.

A newer datagram for the same key replaces the older pending datagram.
# 38. Error Codes

Exact protocol/application error codes:

```text
0x0001 PERMISSION_DENIED
0x0002 BLUETOOTH_UNAVAILABLE
0x0003 BLUETOOTH_POWERED_OFF
0x0004 ADVERTISING_UNAVAILABLE
0x0005 DISCOVERY_UNAVAILABLE
0x0006 ENDPOINT_LOST
0x0007 CONNECTION_TIMEOUT
0x0008 CONNECTION_REJECTED
0x0009 AUTHENTICATION_FAILED
0x000A PROTOCOL_MISMATCH
0x000B TRANSPORT_CLOSED
0x000C SEND_QUEUE_FULL
0x000D MESSAGE_TOO_LARGE
0x000E L2CAP_UNAVAILABLE
0x000F LAN_UNAVAILABLE
0x0010 UPGRADE_FAILED
0x0011 RECONNECT_TIMEOUT
0x0012 RESOURCE_EXHAUSTED
0x0013 INVALID_STATE
0x0014 PLATFORM_ERROR
0x0015 INTERNAL_ERROR
0x0016 IDENTITY_COLLISION
0x0017 UNSUPPORTED_FRAME_TYPE
0x0018 SEQUENCE_WINDOW_EXCEEDED
0x0019 REQUEST_TIMEOUT
0x001A MESSAGE_EXPIRED
0x001B RESUME_REJECTED
0x001C CHANNEL_BINDING_FAILED
0x001D ACK_TIMEOUT
0x001E MESSAGE_ID_COLLISION
0x001F DUPLICATE_CONNECTION
0x0020 UNSUPPORTED_CAPABILITY
0x0021 GROUP_FULL
0x0022 GROUP_SCOPE_MISMATCH
0x0023 GROUP_MERGE_REJECTED
0x0024 UDP_PROBE_TIMEOUT
0x0025 UDP_ENDPOINT_CHANGED
0x0026 UDP_AUTHENTICATION_FAILED
0x0027 GROUP_STATE_SYNC_FAILED
0x0028 DESTINATION_NOT_IN_GROUP
0x0029 DESTINATION_UNAVAILABLE
```

Protocol ERROR frame payload:

```text
2-byte error_code
2-byte UTF-8 message_length
N-byte UTF-8 diagnostic message
```

Diagnostic text MUST NOT be required for program logic.

---

# 39. Runtime State Machine

Exact allowed transitions:

```text
CREATED -> INITIALIZING
INITIALIZING -> READY
INITIALIZING -> FAILED
READY -> CLOSING
FAILED -> CLOSING
CLOSING -> CLOSED
```

No other transitions are valid.

---

# 40. Peer State Machine

Exact allowed transitions:

```text
DISCOVERED -> CONNECTING
CONNECTING -> TRANSPORT_CONNECTED
CONNECTING -> FAILED
TRANSPORT_CONNECTED -> AUTHENTICATING
TRANSPORT_CONNECTED -> FAILED
AUTHENTICATING -> READY
AUTHENTICATING -> FAILED
READY -> RECONNECTING
READY -> DISCONNECTING
READY -> FAILED
RECONNECTING -> READY
RECONNECTING -> DISCONNECTED
RECONNECTING -> DISCONNECTING
DISCONNECTING -> DISCONNECTED
FAILED -> DISCONNECTED
```

Any impossible platform callback MUST be ignored and logged as a diagnostic rather than causing an illegal transition.

---

# 41. Default Timing Constants

```text
EndpointLost observation timeout:       5000 ms
Endpoint connect grace after lost:      5000 ms
Connection request timeout:            10000 ms
Physical connect timeout:              10000 ms
HELLO/AUTH handshake timeout:           5000 ms
SAS verification timeout:              30000 ms
Default keepalive interval:             2000 ms
Derived dead timeout:         max(6000, 3 * negotiated interval)
Default reconnect timeout:             15000 ms
GATT frame fragment inactivity:         2000 ms
DATA message chunk inactivity:         10000 ms
Upgrade candidate connect timeout:      5000 ms
Old transport post-switch grace:        2000 ms
ACK timeout:                            3000 ms
ACK retransmissions:                       2
Upgrade retry cooldown:                30000 ms
HostSession graceful close flush:       1000 ms
```

---

# 42. Application Lifecycle Example

## 42.1 Normal Frictionless Multiplayer Flow

Every phone executes the same application flow:

```text
1. runtime = createRuntime(config)
2. wait RuntimeReady
3. group = runtime.joinOrCreateGroup(groupConfig)
4. group enters DISCOVERING / FORMING
5. compatible nearby peers authenticate
6. groups merge if necessary
7. coordinator is adopted or automatically elected
8. group enters READY
9. application receives GroupReady
10. application observes CoordinatorChanged when coordinator identity is relevant
11. exchange reliable and realtime application traffic
12. coordinator may disappear
13. group automatically enters MIGRATING_COORDINATOR
14. remaining peers elect replacement
15. star topology reforms
16. application receives CoordinatorChanged
17. group returns READY
18. group.leave()
19. runtime.close()
```

No step asks the user to select host/client.

## 42.2 Reliable Game Event

Example:

```text
group.broadcast(
    bytes = playerScoredEvent,
    deliveryMode = RELIABLE_ACKED
)
```

Use for a discrete event that must not disappear during reconnect.

## 42.3 Ordinary Reliable Message

Example:

```text
group.send(
    peerId,
    chatMessage,
    deliveryMode = RELIABLE_ORDERED
)
```

This does not require an LPC ACK by default.

## 42.4 Realtime Game State

Example at 20 to 60 Hz:

```text
group.broadcastRealtime(
    channelId = 1,
    bytes = latestAuthoritativeGameSnapshot
)
```

If three snapshots queue faster than the radio can transmit:

```text
snapshot 100 queued
snapshot 101 replaces 100
snapshot 102 replaces 101
```

Only snapshot 102 remains queued.

The receiver may observe:

```text
98, 99, 102, 104
```

Missing snapshots are valid.

The receiver MUST NOT wait for 100, 101, or 103.

## 42.5 Coordinator Migration with Application State

If the application uses an authoritative coordinator, it SHOULD periodically call:

```text
group.publishCoordinatorCheckpoint(serializedGameState)
```

When the coordinator disappears and the local peer is promoted:

```text
CoordinatorChanged {
    localIsCoordinator = true
    latestCheckpoint = ...
}
```

The application restores that checkpoint and resumes authoritative simulation.

Network-role election and reconnection are automatic. Interpretation of game-state bytes remains application-specific.


---

## 42.6 Group Scoping Examples

Quick zero-setup nearby game:

```text
discoveryMode = OPEN_PROXIMITY
groupTrustMode = OPEN_TOFU
```

Room/lobby game:

```text
discoveryMode = TOKEN_SCOPED
groupJoinToken = lobbySpecific16ByteToken
```

Ad-hoc whiteboard or messaging room:

```text
discoveryMode = TOKEN_SCOPED
groupJoinToken = documentOrRoomSpecific16ByteToken
groupTrustMode = PAIRWISE_SAS | KNOWN_PEERS | GROUP_PSK_32
```

`TOKEN_SCOPED` requires the application to arrange the common token through lobby, invitation, document-sharing, QR, NFC, or equivalent UX before independently formed groups can merge.
# 43. Coordinator Star Topology Behavior

When a GroupSession is READY, the elected coordinator is the center of the preferred application topology:

```text
           Coordinator
          /    |    \
       Peer A Peer B Peer C
```

This is an LPC logical topology. It does NOT require the coordinator to use the same BLE physical role on every link.

Default group size:

```text
8 total peers
```

For every READY non-coordinator member, the coordinator MUST maintain an independent coordinator<->member logical PeerConnection.

Each such coordinator-member link has independent:

- reliable queue;
- realtime latest-state queue per channel;
- receive sequence state;
- transport generation;
- reconnect state.

A non-coordinator is NOT required to maintain direct PeerConnections to the other non-coordinator members.

A stalled member MUST NOT block traffic to another member.

Reliable `broadcast()` is implemented as independent routed sends to the committed remote-member snapshot defined in Section 36.

`broadcastRealtime(channelId, ...)` is implemented as independent routed latest-state submissions to the same committed remote-member snapshot.

If one peer is congested, its old realtime state may be superseded without affecting other peers.

Coordinator loss MUST trigger Section 10 election and topology reconstruction automatically.


---

## 43.1 Normative Group Application Routing

GroupSession application traffic MUST use coordinator relay in the preferred star topology.

A non-coordinator MUST route group application traffic only through the current coordinator, even if a temporary/bootstrap direct PeerConnection to the destination happens to exist.

The coordinator MUST validate source and destination membership before forwarding.

### 43.1.1 GROUP_RELIABLE

Frame type:

```text
0x24 GROUP_RELIABLE
```

Maximum application payload remains 1,048,576 bytes.

Plaintext payload:

```text
Offset Size Field
0      16   group_id
16     16   source_peer_id
32     16   destination_peer_id
48     16   group_message_id
64     1    delivery_mode
65     1    priority
66     2    reserved = 0
68     2    chunk_index uint16
70     2    chunk_count uint16
72     4    total_application_length uint32
76     4    chunk_offset uint32
80     2    chunk_length uint16
82     2    reserved = 0
84     N    chunk_bytes
```

Delivery mode:

```text
0x01 RELIABLE_ORDERED
0x02 RELIABLE_ACKED
```

Maximum `chunk_bytes = 16300`.

```text
chunk_count = max(1, ceil(total_application_length / 16300))
chunk_offset = chunk_index * 16300
```

For zero length, send one chunk with `chunk_length=0`.

For non-empty messages, every non-final chunk has 16300 bytes and the final chunk ends exactly at `total_application_length`.

All chunks for one end-destination operation use the same GroupMessageId.

Each PHYSICAL HOP allocates exactly one 8-byte pairwise LPC MessageId for the complete GROUP_RELIABLE hop operation, regardless of whether the embedded mode is RELIABLE_ORDERED or RELIABLE_ACKED.

A member-to-member RELIABLE_ACKED route therefore uses one stable GroupMessageId end-to-end, plus independent source->coordinator and coordinator->destination pairwise MessageIds.

For `RELIABLE_ACKED`, GROUP_RELIABLE sets `ACK_REQUIRED=1` on each hop.

For `RELIABLE_ORDERED`, it clears `ACK_REQUIRED`.

### 43.1.2 Source and Destination Validation

Member -> coordinator:

```text
source_peer_id == authenticated sending PeerId
```

The destination MUST be a committed member other than the source.

The source-hop `group_id` MUST equal either:

- the current canonical GroupId; or
- an active historical GroupId alias still valid under the 30-second merge-alias rule.

The coordinator MUST normalize the forwarded destination-hop `group_id` to the CURRENT canonical GroupId.

Coordinator -> destination:

- authenticated hop sender MUST be the current coordinator;
- source_peer_id MUST name a committed member;
- destination_peer_id MUST equal the receiving peer;
- coordinator MUST preserve source/destination GroupMessageId, delivery mode, application bytes, and chunk structure.

A non-coordinator receiving relayed group application traffic from a peer other than the current coordinator MUST first apply the stale former-coordinator rules in this section.

If those rules do not classify the frame as valid stale-authority traffic, the receiver MUST close that PeerConnection with `PROTOCOL_MISMATCH`.

### 43.1.3 Coordinator Relay Processing

If destination is the coordinator, the coordinator delivers locally.

Otherwise routing depends on the coordinator's destination PeerConnection state:

```text
destination PeerConnection READY:
    forward normally

destination still committed but PeerConnection is not READY:
    return DESTINATION_UNAVAILABLE

destination no longer committed:
    return DESTINATION_NOT_IN_GROUP
```

The coordinator MUST NOT hold a newly accepted group application operation waiting for a destination PeerConnection to recover.

This makes relay acceptance deterministic and avoids a second hidden queue/expiry domain at the coordinator.

Applications may retry a failed reliable send after the destination route becomes available again.

Realtime datagrams for an unavailable destination are dropped.

For `RELIABLE_ACKED`, source-hop receive completion and relay admission are separate concepts.

After the complete source-hop `GROUP_RELIABLE` operation has been reassembled and validated, the coordinator MUST perform one atomic relay-admission decision for the complete logical operation.

Exact rule:

```text
if destination is coordinator:
    commit local application delivery
    generic-ACK the source hop
    send GROUP_DELIVERY_ACK

else if destination PeerConnection is READY
     and its bounded reliable queue can reserve capacity
     for the complete routed logical operation:
    atomically reserve/enqueue the complete destination relay operation
    generic-ACK the source hop
    begin/continue forwarding

else:
    retain NO destination relay operation
    generic-ACK the source hop
    send GROUP_RELAY_STATUS with the exact route failure:
        DESTINATION_UNAVAILABLE
        DESTINATION_NOT_IN_GROUP
        RELAY_QUEUE_FULL
```

The source-hop generic ACK means only:

```text
the coordinator fully received and dispositioned this hop operation
```

It does NOT mean the coordinator accepted responsibility to deliver successfully to the destination.

In the route-admission failure case, the coordinator MUST still generic-ACK the source hop after the complete operation has been validated so that the source does not retransmit the same potentially large hop operation merely because relay admission failed.

`GROUP_RELAY_STATUS` is the authoritative group-routing failure signal.

The coordinator MUST NOT:

- generic-ACK a partially received source operation;
- reserve only part of a logical routed message;
- accept a relay operation without enough bounded destination-queue capacity for the complete logical operation;
- retain the operation after sending `RELAY_QUEUE_FULL`, `DESTINATION_UNAVAILABLE`, or `DESTINATION_NOT_IN_GROUP`.

That hop ACK is INTERNAL and MUST NOT complete the public source SendHandle.

The forwarded destination hop gets a fresh pairwise MessageId but retains the original GroupMessageId.

### 43.1.4 Destination Group Deduplication

Each destination GroupSession retains ONE shared cache containing the most recent 16,384 completed:

```text
(source_peer_id, group_message_id)
```

pairs across ALL source PeerIds.

The 16,384-entry limit applies to the destination GroupSession as a whole.

It is NOT a separate 16,384-entry allocation per source PeerId.

GroupMessageId duplicate suppression is bounded.

Exactly-once GroupSession `RELIABLE_ACKED` application delivery is guaranteed only while the completed:

```text
(source_peer_id, group_message_id)
```

entry remains within this 16,384-entry destination deduplication window.

After that entry is evicted, replay or reroute of the older GroupMessageId is NOT guaranteed to be recognized as a duplicate and MAY produce another application delivery event.

Therefore `RELIABLE_ACKED` MUST NOT be documented as mathematically permanent exactly-once delivery.

Its guarantee is:

```text
destination-confirmed delivery
+
duplicate suppression within the defined completed-GroupMessageId
retention window
```

An identical duplicate:

- MUST NOT emit another ReliableMessageReceived;
- is treated as already accepted;
- for RELIABLE_ACKED, permits normal hop ACK and regeneration of destination-level acknowledgment.

For GroupMessageId duplicate equivalence, the logical content identity consists of:

```text
source_peer_id
destination_peer_id
delivery_mode
application payload bytes
```

Priority and chunk representation MUST also be semantically consistent.

`group_id` is routing/merge metadata and MAY change from an active historical alias to the current canonical GroupId during reroute. That normalization MUST NOT by itself constitute a GroupMessageId collision.

Pairwise MessageId, wire sequence numbers, transport generation, and coordinator identity are hop metadata and are excluded from GroupMessageId content identity.

The same `(source_peer_id, group_message_id)` with conflicting end-destination logical content MUST close with `MESSAGE_ID_COLLISION`.

### 43.1.5 GROUP_DELIVERY_ACK

Frame type:

```text
0x26 GROUP_DELIVERY_ACK
```

Coordinator -> original source only.

Payload:

```text
Offset Size Field
0      16   group_id
16     16   source_peer_id
32     16   destination_peer_id
48     16   group_message_id
```

It MUST set pairwise `ACK_REQUIRED=1`.

For normal nonterminal sends, a non-coordinator source accepts `GROUP_DELIVERY_ACK` only if:

- authenticated hop sender is the current coordinator;
- `source_peer_id` equals localPeerId;
- destination and GroupMessageId match one retained nonterminal group send.

For a cancelled send with a valid `CancelledGroupSendTombstone`, the unified stale former-coordinator handling subsection below applies when signaling races with coordinator migration.

The coordinator sends it only when:

```text
destination == coordinator:
    complete message has been reassembled, validated, committed,
    and queued for application event delivery

destination != coordinator:
    coordinator received generic ACK for the complete
    coordinator->destination GROUP_RELIABLE operation
```

For a non-coordinator source, a valid GROUP_DELIVERY_ACK transitions the source public SendHandle to `REMOTE_ACKNOWLEDGED`.

If the coordinator itself is the original source and the destination is another member, no GROUP_DELIVERY_ACK frame is sent to self. The coordinator's local SendHandle transitions to `REMOTE_ACKNOWLEDGED` directly when the destination-hop generic ACK is accepted.

If the coordinator itself is the destination, it commits the application delivery locally and then sends GROUP_DELIVERY_ACK to the non-coordinator source.

### 43.1.6 GROUP_RELAY_STATUS

Frame type:

```text
0x27 GROUP_RELAY_STATUS
```

Payload:

```text
Offset Size Field
0      16   group_id
16     16   source_peer_id
32     16   destination_peer_id
48     16   group_message_id
64     1    status
65     1    reserved = 0
66     2    error_code
```

Status:

```text
0x01 SENT_TO_DESTINATION_TRANSPORT
0x02 DESTINATION_NOT_IN_GROUP
0x03 DESTINATION_UNAVAILABLE
0x04 DESTINATION_ACK_TIMEOUT
0x05 RELAY_QUEUE_FULL
0x06 GROUP_NOT_READY
```

Status/error mapping is exact:

```text
SENT_TO_DESTINATION_TRANSPORT -> error_code = 0
DESTINATION_NOT_IN_GROUP      -> 0x0028 DESTINATION_NOT_IN_GROUP
DESTINATION_UNAVAILABLE       -> 0x0029 DESTINATION_UNAVAILABLE
DESTINATION_ACK_TIMEOUT       -> 0x001D ACK_TIMEOUT
RELAY_QUEUE_FULL              -> 0x000C SEND_QUEUE_FULL
GROUP_NOT_READY               -> 0x0013 INVALID_STATE
```

It MUST set pairwise `ACK_REQUIRED=1`.

For normal nonterminal sends, a non-coordinator source accepts `GROUP_RELAY_STATUS` only if:

- authenticated hop sender is the current coordinator;
- `source_peer_id` equals localPeerId;
- destination and GroupMessageId match a retained nonterminal group send.

For a cancelled send with a valid `CancelledGroupSendTombstone`, the unified stale former-coordinator handling subsection below applies when signaling races with coordinator migration.

For RELIABLE_ORDERED member-to-member routing, coordinator sends `SENT_TO_DESTINATION_TRANSPORT` only after every forwarded chunk reaches frame-level `SENT_TO_TRANSPORT` on the final hop.

Only that authenticated status permits the source public SendHandle to become `SENT_TO_TRANSPORT`.

For RELIABLE_ACKED, successful completion uses GROUP_DELIVERY_ACK.

A terminal failure status fails the source SendHandle with the mapped route error.

### 43.1.7 Coordinator Loss and Retry

A RELIABLE_ACKED source retains an uncompleted GroupMessageId until destination ACK, terminal retry failure, target removal, cancellation, or GroupSession close.

If the source's coordinator PeerConnection is lost or the coordinator itself changes before destination acknowledgment, source-side reroute follows this subsection. Loss of the coordinator-to-destination hop while the same coordinator remains active follows the dedicated GROUP_RELIABLE transport-generation-loss rules below.

1. retain the same GroupMessageId;
2. perform normal PeerConnection RESUME and/or coordinator migration;
3. when the GroupSession has a READY route to the current coordinator, retransmit the complete operation through that coordinator if the public handle is still nonterminal;
4. new logical-hop attempts allocate the appropriate pairwise MessageIds and fresh wire sequences;
5. destination GroupMessageId dedup suppresses duplicate application delivery.

If the stable coordinator's destination hop exhausts generic ACK retries, it sends `DESTINATION_ACK_TIMEOUT`; the source fails with `ACK_TIMEOUT`.

No implementation may report REMOTE_ACKNOWLEDGED without GROUP_DELIVERY_ACK.

A RELIABLE_ORDERED group operation is retained until the PUBLIC handle reaches final-hop `SENT_TO_TRANSPORT`.

If the coordinator route is lost before that state, retain the same GroupMessageId and retransmit the complete operation after the source again has a READY route to the current coordinator.

After public `SENT_TO_TRANSPORT`, RELIABLE_ORDERED is not automatically retransmitted.


### 43.1.8 GROUP_RELIABLE Transport-Generation Loss

Incomplete `GROUP_RELIABLE` reassembly MUST NOT survive loss of the physical transport generation on that hop.

When a PeerConnection transport generation is lost before one logical `GROUP_RELIABLE` hop operation has been completely reassembled, the receiver MUST discard all incomplete reassembly state for that pairwise MessageId.

Discarded state includes:

- received chunk bitmap;
- partial application buffer;
- GROUP_RELIABLE routing metadata;
- chunk metadata;
- incomplete reassembly timer.

Completed pairwise MessageId deduplication state and completed GroupMessageId destination deduplication state are retained according to their normal SessionId/GroupSession lifetimes.

Pre-loss partial GROUP_RELIABLE chunks MUST NOT be combined with post-RESUME chunks.

#### RELIABLE_ACKED hop recovery

For a `GROUP_RELIABLE` hop whose embedded delivery mode is `RELIABLE_ACKED`:

```text
if the hop operation remains unacknowledged after transport loss:
    retain the same pairwise MessageId
    retain the same GroupMessageId
    retain identical logical routing metadata and application bytes
    after successful RESUME, retransmit the COMPLETE hop operation
    from chunk 0
    use fresh reliable wire sequence_numbers
```

This is the normal Section 23 ACK-required recovery applied to chunked `GROUP_RELIABLE`.

The sender MUST NOT resume from only the first unsent chunk.

#### RELIABLE_ORDERED hop recovery

For a `GROUP_RELIABLE` hop whose embedded delivery mode is `RELIABLE_ORDERED`:

```text
if EVERY constituent GROUP_RELIABLE frame on that hop reached
frame-level SENT_TO_TRANSPORT before transport loss:
    do not retransmit that hop solely because transport loss
    occurred afterward

if one or more constituent GROUP_RELIABLE frames had NOT reached
frame-level SENT_TO_TRANSPORT before transport loss:
    retain the logical hop operation
    retain the SAME pairwise MessageId
    retain the SAME GroupMessageId
    retain identical logical routing metadata and application bytes
    after successful RESUME, retransmit the COMPLETE hop operation
    from chunk 0
    use fresh reliable wire sequence_numbers
```

The sender MUST NOT resume from a middle chunk.

For a coordinator-to-destination relay hop, the coordinator MUST retain an already-admitted `RELIABLE_ORDERED` relay operation across that destination PeerConnection's `RECONNECTING` state when the final end-destination hop had not yet reached complete `SENT_TO_TRANSPORT`.

This retained admitted relay operation is NOT a new queue entry and MUST continue to count against the bounded destination reliable-queue byte/message reservation that was made at relay admission.

If destination PeerConnection RESUME succeeds:

- retransmit the complete destination-hop operation from chunk 0;
- use the same pairwise MessageId for that hop;
- use the same GroupMessageId;
- preserve original source/destination/application content;
- use fresh wire sequence numbers.

If destination PeerConnection reconnect/RESUME ultimately fails:

- discard the admitted relay operation;
- send `GROUP_RELAY_STATUS(DESTINATION_UNAVAILABLE)` to the original source if that source route is still available;
- otherwise retain no hidden relay state.

If the coordinator itself is the original source, fail the local `SendHandle` with `DESTINATION_UNAVAILABLE`.

#### Public handle consequences

For a non-coordinator source sending `RELIABLE_ORDERED` to another non-coordinator:

- source->coordinator may remain READY while coordinator->destination is RECONNECTING;
- the source public SendHandle remains nonterminal until either:
  - coordinator reports `SENT_TO_DESTINATION_TRANSPORT`; or
  - coordinator reports a terminal relay failure.

The coordinator MUST NOT report `SENT_TO_DESTINATION_TRANSPORT` until every constituent frame of the successful final-hop attempt reaches frame-level `SENT_TO_TRANSPORT`.

This rule prevents independent implementations from choosing partial-chunk continuation, premature failure, or silent drop after an admitted relay operation.


### 43.1.9 Source Cancellation of Routed Operations

Source cancellation affects only the source's future participation.

If a source cancels a routed reliable operation before coordinator relay admission, normal local cancellation may prevent the operation from ever being admitted.

If the coordinator has already admitted the relay:

- coordinator relay state is independent of the source public SendHandle;
- the coordinator MAY continue the already-admitted destination-hop operation;
- the source MUST NOT reroute or retransmit the cancelled GroupMessageId after later source-link reconnect or coordinator migration;
- destination deduplication remains valid if a previously admitted relay later arrives;
- late GROUP_DELIVERY_ACK / GROUP_RELAY_STATUS is handled through the cancellation tombstone rules in Section 36.

The coordinator is not required to learn that the source cancelled because protocol minor 1 defines no route-cancel control frame.

Therefore an admitted relay MUST NOT be silently deleted merely because the source application locally cancelled its handle.

This rule intentionally favors deterministic ownership transfer at relay admission over a partially reliable remote-cancellation mechanism.




### 43.1.10 Coordinator Authority Loss During Admitted Relay

Loss of coordinator authority has stronger precedence than source-cancellation relay ownership.

When a coordinator commits loss of coordinator authority, it MUST immediately stop acting as coordinator for application routing.

For every admitted `GROUP_RELIABLE` relay operation that has NOT yet reached its final end-destination terminal state, the former coordinator MUST:

1. stop initiating or submitting additional destination-hop `GROUP_RELIABLE` frames;
2. discard every not-yet-submitted destination-hop frame/chunk;
3. stop any destination-hop retransmission or RESUME recovery for that relay;
4. release the destination reliable-queue byte/message reservation held for that relay;
5. discard its local admitted-relay ownership state;
6. NOT create a new `GROUP_DELIVERY_ACK` or `GROUP_RELAY_STATUS` after authority loss;
7. NOT transfer or reuse the old destination-hop pairwise MessageId through the new coordinator;
8. retain no hidden reroute responsibility after authority loss.

For realtime traffic, the former coordinator MUST immediately stop initiating or submitting additional `GROUP_REALTIME_DATAGRAM` frames as coordinator and MUST discard queued stale coordinator realtime state.

Already-submitted platform bytes cannot be retracted. Therefore this rule governs future submission after the authority-loss commit point.

The original source remains responsible for every still-nonterminal public routed operation.

After the source has a READY route to the new coordinator:

```text
retain same GroupMessageId
retransmit whole routed logical operation through new coordinator
allocate new pairwise MessageId(s) for the new logical hop(s)
use fresh wire sequence numbers
```

The rule that permits an already-admitted relay to continue after SOURCE cancellation does NOT permit a former coordinator to continue coordinator-authoritative application transmission after it loses coordinator authority.

Coordinator-authority loss always wins that conflict.

If destination application delivery had already fully committed before authority loss, that delivery remains valid.

The destination's completed `(source_peer_id, group_message_id)` dedup entry suppresses a later source reroute through the new coordinator.

### 43.1.11 Stale Former-Coordinator Traffic

Coordinator migration can race with bytes or ACK-required control operations that were validly created while the previous coordinator still held authority.

#### Already-in-flight GROUP_DELIVERY_ACK / GROUP_RELAY_STATUS

A valid authenticated `GROUP_DELIVERY_ACK` or `GROUP_RELAY_STATUS` from the IMMEDIATELY PREVIOUS coordinator MUST be classified as stale-authority signaling, rather than protocol corruption, only when ALL of the following hold:

1. the signaling operation was already created and eligible for transmission before that peer committed loss of coordinator authority;
2. it arrives on the same pairwise logical `SessionId` that was valid while that peer held coordinator authority;
3. the sender PeerId is the immediately previous coordinator for this GroupSession transition;
4. `group_id`, `source_peer_id`, `destination_peer_id`, and `group_message_id` are valid for the historical route;
5. the frame passes normal cryptographic, sequence, and generic ACK-required validation.

When all conditions hold, the receiver MUST:

- generic-ACK the signaling logical operation normally;
- classify it as `STALE_COORDINATOR_SIGNALING` in diagnostics;
- discard its semantic completion/failure result;
- NOT complete or fail any nonterminal SendHandle;
- NOT alter any cancelled SendHandle;
- NOT create reroute/retry eligibility;
- NOT alter membership, coordinator, or routing state.

For a nonterminal source operation, normal reroute/retry proceeds only through the CURRENT coordinator.

For a cancelled source operation, the `CancelledGroupSendTombstone` remains useful for correlation, but the public handle remains permanently `CANCELLED`.

A former coordinator MUST NOT create a NEW `GROUP_DELIVERY_ACK` or `GROUP_RELAY_STATUS` after loss of authority.

#### Already-submitted GROUP_RELIABLE from former coordinator

A destination MAY receive a `GROUP_RELIABLE` frame after it has committed a new coordinator even though the frame was submitted by the previous coordinator before authority changed.

A frame from the immediately previous coordinator MUST be treated as stale-authority application traffic, rather than `PROTOCOL_MISMATCH`, only when:

1. it arrives on the same historically valid pairwise `SessionId`;
2. the sender was the immediately previous coordinator;
3. it is part of a relay operation already in flight before coordinator migration;
4. all cryptographic and framing checks pass.

After the receiver has committed the new coordinator:

- stale former-coordinator `GROUP_RELIABLE` frames MUST NOT produce a new application delivery;
- incomplete stale `GROUP_RELIABLE` reassembly MUST be discarded;
- stale chunks MUST NOT be combined with chunks received through the new coordinator;
- no generic ACK is required for `RELIABLE_ORDERED`;
- for an ACK-required stale `RELIABLE_ACKED` hop operation already validly in flight, the receiver MUST generic-ACK the complete stale hop operation if it can be fully authenticated/reassembled from already-submitted data, but MUST NOT emit application delivery or destination-level completion;
- if only a partial ACK-required stale hop arrives, discard incomplete reassembly and do not synthesize an ACK.

This exception exists only to avoid treating normal migration races as malicious protocol corruption.

#### Already-submitted GROUP_REALTIME_DATAGRAM from former coordinator

A `GROUP_REALTIME_DATAGRAM` from the immediately previous coordinator on the historically valid SessionId that arrives after coordinator migration MUST be authenticated and silently discarded as stale-authority traffic.

It MUST NOT emit `RealtimeDatagramReceived`.

It MUST NOT cause `PROTOCOL_MISMATCH` solely because coordinator authority changed after submission.

#### Other non-authoritative coordinator traffic

Any coordinator-authoritative application or route-signaling frame from:

- a peer other than the current coordinator or immediately previous coordinator;
- a different/unrecognized SessionId;
- a former coordinator that originated the operation after authority loss;
- a peer whose historical authority cannot be proven;

does NOT qualify for stale-authority handling and follows normal non-authoritative coordinator protocol-error handling.

### 43.1.12 Destination Membership Removal During Relay

When a destination PeerId is removed from committed membership, the coordinator MUST immediately examine every queued or nonterminal admitted relay operation targeting that destination.

For each such operation:

```text
if destination application delivery had already committed:
    delivery remains valid
    for RELIABLE_ACKED, complete normal destination-ack signaling
    if still possible

else if final end-destination hop had already reached its successful
terminal delivery state:
    preserve that terminal result

else:
    terminate the admitted relay operation
    release its reserved destination queue capacity
    do not transmit additional application chunks to the removed peer
```

For a remote source whose route remains available, the coordinator MUST send:

```text
GROUP_RELAY_STATUS(DESTINATION_NOT_IN_GROUP)
```

for each terminated nonterminal routed send.

If the coordinator itself is the original source, fail the local SendHandle with `DESTINATION_NOT_IN_GROUP`.

A kicked or otherwise removed member MUST NOT continue receiving queued application traffic after membership removal has committed.

This rule does not revoke an application message already committed at the destination before removal.

### 43.1.13 Per-Source Reliable Ordering

For one exact:

```text
(sourcePeerId, destinationPeerId)
```

the coordinator MUST preserve source acceptance order for GROUP_RELIABLE operations.

No total order exists across different source PeerIds.

### 43.1.14 GROUP_REALTIME_DATAGRAM

Frame type:

```text
0x25 GROUP_REALTIME_DATAGRAM
```

Plaintext payload:

```text
Offset Size Field
0      16   group_id
16     16   source_peer_id
32     16   destination_peer_id
48     2    channel_id uint16
50     2    reserved = 0
52     4    datagram_sequence uint32
56     8    sender_tick uint64
64     2    application_payload_length uint16
66     2    reserved = 0
68     N    application_payload
```

Maximum application payload is 1100 bytes.

Maximum plaintext is 1168 bytes.

With 60-byte LPU1 outer overhead the total is 1228 bytes, below the 1232-byte UDP bound.

The originating GroupSession maintains one uint32 `datagram_sequence` per:

```text
(destinationPeerId, channelId)
```

It starts at 1, increments by 1 for each newly created datagram for that key, and is retained across coordinator migration for the lifetime of the GroupSession.

Sequence 0 is invalid.

A counter MUST NOT wrap. Before UINT32_MAX would be reused, that destination/channel realtime stream MUST fail with `RESOURCE_EXHAUSTED` until a new GroupSession is created.

GROUP_REALTIME_DATAGRAM:

- never sets ACK_REQUIRED;
- is never retransmitted;
- preserves original source_peer_id through relay;
- destination latest-state suppression key is `(source_peer_id, channel_id)`;
- coordinator pending replacement key is `(source_peer_id, destination_peer_id, channel_id)`.

A non-coordinator sends it only to the coordinator.

Coordinator forwards only to the named committed destination.

Unavailable destination causes drop, not reliable recovery.

### 43.1.15 UDP Sidecar Relay

When a group hop has ACTIVE LPU1 UDP realtime, the exact 68-byte GROUP_REALTIME_DATAGRAM envelope MAY be carried as LPU1 realtime plaintext instead of LPC frame 0x25.

LPU1 authentication, replay, packet sequence, and endpoint binding remain hop-local.

Coordinator decrypts and re-encrypts independently per hop.

### 43.1.16 Relay Confidentiality

Relay traffic is authenticated and encrypted on every PeerConnection hop.

It is NOT end-to-end encrypted between two non-coordinator members.

The coordinator can observe relayed application payloads.

Applications requiring end-to-end member secrecy MUST encrypt `bytes` above LPC.
# 44. Platform Backend Interface

Every backend MUST implement the operations it claims in its local runtime capability bitmap:

```text
queryCapabilities()

startAdvertising(serviceUuid, optionalLocalName)
stopAdvertising()

startDiscovery(serviceUuid)
stopDiscovery()

listenGatt(serviceUuid)
connectGatt(discoveryEndpointId)

listenL2cap(parameters)
connectL2cap(parameters)

listenLan(parameters)
connectLan(parameters)

close()
```

No backend advertisement API accepts protocol-critical custom service-data in V1.

Unsupported methods return `UNSUPPORTED_CAPABILITY`.

---



## 44.1 Transport Write Completion Contract

A backend write operation MUST expose an asynchronous completion object conceptually equivalent to:

```text
TransportWrite {
    state:
        PENDING
        SUBMITTED_TO_PLATFORM
        FAILED

    completion()
}
```

The portable core MAY express this as a Future/Promise, callback, event, pollable handle, completion queue entry, or equivalent binding-specific mechanism.

The semantic contract is fixed:

```text
SUBMITTED_TO_PLATFORM
    == the LPC frame has reached frame-level SENT_TO_TRANSPORT
       as defined in Section 23
```

A backend MUST NOT report `SUBMITTED_TO_PLATFORM` merely because it accepted bytes into an internal queue.

For a backend that performs additional transport-specific fragmentation, including BLE GATT, the write completion MUST remain `PENDING` until the backend has submitted the final required transport fragment to the platform API.

### 44.1.1 Transient Backpressure

A transient platform inability to accept more output MUST NOT transition `TransportWrite` to `FAILED`.

Examples include:

```text
platform queue temporarily full
platform reports not writable / would block
GATT notification buffer temporarily unavailable
Write Without Response flow-control capacity exhausted
L2CAP/TCP send path temporarily lacks writable capacity
```

Required behavior:

```text
TransportWrite remains PENDING
unsent bytes/fragments remain queued inside the bounded backend write
backend waits for Writable / platform readiness indication
backend resumes submission from the next unsent byte/fragment
```

No LPC ACK timer starts while the frame remains `PENDING`.

Backpressure MUST NOT by itself change `PeerConnectionState`.

The backend MUST enforce its bounded queue limits while waiting. If accepting NEW writes would exceed those limits, those new writes may be rejected with the normal queue/backpressure error, but an already accepted `TransportWrite` remains `PENDING`.

### 44.1.2 Terminal Submission Failure

`FAILED` is reserved for a terminal condition where the backend cannot complete submission of the LPC frame on the current physical transport.

Examples include:

```text
physical connection closed
GATT connection terminated
platform reports terminal characteristic/notification submission error
L2CAP channel closed or fatally errored
TCP/socket write fails terminally
transport enters an invalid state from which submission cannot resume
```

When a `TransportWrite` reaches `FAILED` because a required byte/fragment cannot be submitted:

1. that LPC frame MUST NOT transition to frame-level `SENT_TO_TRANSPORT`;

2. no ACK timer may begin because of that frame;

3. the current physical transport MUST be considered failed;

4. unless the PeerConnection is already DISCONNECTING/CLOSED, the PeerConnection MUST enter the normal transport-loss path and then `RECONNECTING` according to Sections 25 and 26;

5. the failed transport generation MUST immediately stop accepting or submitting additional LPC frames;

6. every still-PENDING `TransportWrite` belonging to that physical transport generation MUST complete `FAILED`;

7. all unsent transport-specific bytes/fragments belonging to that failed generation MUST be discarded;

8. recovery of the logical operation after successful RESUME follows Sections 21, 23, and 26.

For ACK-required logical operations, the retained operation remains unacknowledged and after RESUME is retransmitted with:

```text
same MessageId
identical logical content
fresh wire sequence numbers
new transport generation
```

A terminal `TransportWrite.FAILED` is therefore a transport-loss signal, not a per-frame retry signal.

### 44.1.3 No Same-Generation Retry After FAILED

After terminal `FAILED`, the core/backend MUST NOT retry the failed LPC frame on the same physical transport generation.

All recovery occurs only through:

```text
transport loss
-> reconnect / fallback
-> RESUME
-> retransmission according to logical delivery semantics
```

This rule prevents independent implementations from making different same-generation retry choices.

# 45. Backend Connection Contract

Each physical connection object exposes:

```text
ConnectionId localDiagnosticId
TransportType transportType
TransportConnectionState state
int maxWriteSize
write(bytes) -> TransportWrite
close()
events()
```

Events:

```text
Opened
BytesReceived
Writable
Closed
Error
```

Backends MUST preserve byte ordering.

GATT backend performs LPC GATT fragmentation/reassembly and exposes whole LPC frame bytes upward.

L2CAP/TCP backends expose ordered stream bytes and core framing parses LPC frames.

The backend MUST NOT perform peer authentication itself.



`write(bytes) -> TransportWrite` accepts exactly one complete serialized LPC frame from the portable core.

The backend may internally segment that frame for GATT or stream it through multiple platform writes.

The returned `TransportWrite` completion MUST follow Section 44 and MUST reach `SUBMITTED_TO_PLATFORM` only at the exact Section 23 `SENT_TO_TRANSPORT` boundary.

The portable core MUST transition that LPC frame to `SENT_TO_TRANSPORT` only from this backend completion signal.
# 46. Android Requirements

Android BLE implementation MUST use public Android Bluetooth APIs.

Required:

```text
BluetoothLeScanner
BluetoothLeAdvertiser
BluetoothGatt
BluetoothGattServer
```

L2CAP MUST use public API-level-supported L2CAP APIs.

The Android backend MUST expose raw platform error codes for diagnostics but map them to stable LPC error categories.

The library MUST document permission requirements by Android API level.

---

# 47. iOS Requirements

iOS BLE implementation MUST use CoreBluetooth.

Required classes:

```text
CBCentralManager
CBPeripheralManager
CBPeripheral
CBService
CBCharacteristic
CBL2CAPChannel when supported
```

The library MUST support:

- central scanning;
- peripheral advertising;
- GATT client;
- GATT server;
- runtime Bluetooth state changes.

CBPeripheral identifiers MUST NOT be used as PeerId.

---

# 48. Background Semantics

Protocol major 1 guarantees foreground operation only.

If an app is backgrounded:

- implementation SHOULD preserve connections when OS permits;
- implementation MUST NOT fabricate PeerConnected state if OS suspended radio activity;
- on foreground resume, runtime MUST reconcile backend state within 1 second;
- if transport is gone, normal reconnect logic begins.

Real-time gameplay while suspended is NOT a V1 guarantee.

---

# 49. Capability Bitmaps

Protocol major 1 defines two different capability bitmaps. They MUST use different type names.

## 49.1 PeerCapabilityBitmap, Wire-Visible in HELLO

```text
bit 0  GATT_BASELINE
bit 1  L2CAP_COC
bit 2  LAN_TCP
bit 3  RESUME
bit 4  TRANSPORT_UPGRADE
bit 5  REMOTE_ACK
bit 6  REALTIME_LATEST
bit 7  AUTO_COORDINATOR
bit 8  LAN_UDP_REALTIME
bits 9-31 reserved = 0
```

For protocol minor 1:

```text
bits 0-8 may be used
bits 9-31 MUST be zero
```

Protocol minor 0 capability semantics are not defined by this specification.

A peer MUST set `REALTIME_LATEST` only if it implements Section 22.

A peer MUST set `AUTO_COORDINATOR` only if it implements Section 10 automatic group coordination.

A peer MUST set `LAN_UDP_REALTIME` only if it can establish the independent authenticated UDP realtime sidecar defined in Sections 22.4 and 29.

## 49.2 LocalRuntimeCapabilityBitmap, API-Only

```text
bit 0  BLE_SCAN
bit 1  BLE_ADVERTISE
bit 2  GATT_CENTRAL
bit 3  GATT_PERIPHERAL
bit 4  L2CAP_CONNECT
bit 5  L2CAP_LISTEN
bit 6  LAN_DISCOVER
bit 7  LAN_LISTEN
bit 8  LAN_CONNECT
bit 9  SECURE_IDENTITY_STORAGE
bit 10 LAN_UDP
bits 11-31 reserved = 0
```

This bitmap is never serialized directly in HELLO.

Runtime capability changes emit `RuntimeCapabilityChanged`.

Examples include Bluetooth off/on, permission changes, and Wi-Fi availability.


---

# 50. Diagnostics

Per-peer diagnostics MUST expose:

```text
PeerId
SessionId
ConnectionId
activeTransport
transportGeneration
connectionDurationMs
reconnectCount
bytesSent
bytesReceived
messagesSent
messagesReceived
queueBytes
queueMessages
lastRttMs
rssi optional
lastErrorCode optional
protocolMajor
protocolMinor
```

Secrets MUST NOT be exposed.

---

# 51. Repository Structure

A conforming reference project SHOULD use:

```text
/spec
    PROTOCOL.md
    API.md
    STATE_MACHINES.md
    SECURITY.md
    TEST_VECTORS.md

/core
    protocol/session implementation

/backends
    android
    ios
    macos
    windows
    linux

/bindings
    flutter
    swift
    kotlin
    c
    rust
    unity

/tests
    unit
    protocol
    backend-conformance
    integration
    security
    performance

/examples
    flutter_game
    native_ios
    native_android
```

---

# 52. Binding Requirements

A language binding MAY change naming style only.

For example:

```text
Dart:   startAdvertising()
Swift:  startAdvertising()
Kotlin: startAdvertising()
C:      lp_host_start_advertising()
```

All bindings MUST preserve:

- state semantics;
- timing semantics;
- wire identifier sizes and opaque local DiscoveryEndpointId semantics;
- event ordering;
- error categories;
- send completion semantics;
- queue behavior;
- cryptographic behavior;
- packet bytes.

---

## 52.1 Observable Event Ordering

Every Runtime, GroupSession, PeerConnection, DiscoverySession, and HostSession MUST behave as a logically serialized state machine.

For one GroupSession, all application-visible events pass through one logical dispatcher in protocol-state commit order:

```text
state mutation committed
    ->
snapshot getters updated
    ->
next eventSequence assigned
    ->
event delivered
    ->
next event delivered
```

Callbacks/events for one GroupSession MUST NOT execute concurrently.

Before MemberJoined, `members()` already includes the member.

Before MemberLeft, `members()` already excludes the member.

Before CoordinatorChanged, coordinator getters already reflect the new coordinator.

Before GroupReady, `state()` already returns READY.

This local event serialization does NOT create a total order across messages from different source PeerIds.

## 52.2 Public Concurrency and Reentrancy Contract

All public methods on Runtime, GroupSession, PeerConnection, DiscoverySession, HostSession, SendHandle, BroadcastHandle, and realtime handles MUST be safe for concurrent invocation.

Implementations need not use one OS thread, but mutations of each object MUST be logically serialized.

If concurrent mutating calls have no application happens-before relationship, either acceptance order is permitted, but the chosen order MUST remain internally consistent.

Snapshot getters return the latest committed state when called.

Event callbacks MAY call public methods reentrantly.

Reentrant mutation is queued into the object's serialized command stream and MUST NOT deadlock waiting for the current callback.

Mutations caused by a reentrant call occur after the current callback returns/yields.

`leave()` and `close()` are idempotent.

When GroupSession commits LEAVING, new application send/broadcast calls fail `INVALID_STATE`; non-terminal queued application sends are cancelled unless an explicit graceful protocol rule requires them.

When an object commits CLOSING/CLOSED, new mutating operations fail `INVALID_STATE`.
# 53. Mandatory Binary Test Vectors

Before protocol minor 1 is considered interoperable across independent implementations, the repository MUST publish byte-for-byte vectors for all items below.


## 53.1 Protocol 1.1 Baseline Core Vectors

- HELLO minor 1 encoding including `PeerCapabilityBitmap`;
- HELLO `keepalive_interval_ms` encoding and READY derivation from unequal
  local configured intervals;
- `REALTIME_DATAGRAM` reliable-fallback frame encoding;
- exact `GroupTrustMode -> HELLO trust_mode` mapping cases;
- canonical `GroupMemberRecord`;
- canonical committed membership bytes;
- membership hash including each member's `max_peers`;
- `MEMBERSHIP_SNAPSHOT`;
- `COORDINATOR_HEARTBEAT`;
- `ELECTION_ANNOUNCE`;
- `COORDINATOR_CLAIM`;
- `COORDINATOR_RESIGN`;
- `GROUP_INFO`;
- `GROUP_MERGE`;
- `GROUP_MERGE_REJECT`;
- `COORDINATOR_CHECKPOINT` single-chunk encoding;
- `COORDINATOR_CHECKPOINT` multi-chunk encoding using one MessageId;
- `ACK_REQUIRED` frame-header bit encoding;
- ACK-required `MEMBERSHIP_SNAPSHOT` with a nonzero MessageId;
- duplicate ACK-required control operation followed by repeated ACK;
- `GROUP_LEAVE`;
- `KNOWN_PEER` using `KnownPeerPolicy=ALLOWLIST`, including acceptance and rejection cases.


- ACK timer start event for single-frame ACK-required operation;
- ACK timer start event after final chunk of multi-chunk RELIABLE_ACKED DATA;
- ACK timer start event after final chunk of multi-chunk COORDINATOR_CHECKPOINT;
- checkpoint partial-reassembly discard on transport loss and full retransmission after RESUME;

- TransportWrite/SENT_TO_TRANSPORT completion trace for GATT fragmentation;
- ACK-timer trace showing final physical GATT fragment of final LPC frame triggers timer start;
- RESUME trace containing an unacknowledged ACK-required control operation and post-RESUME duplicate suppression;


### 53.1.1 Group Routing Binary Vectors

The published test-vector package MUST contain exact byte-for-byte vectors for all of the following.

#### GroupMessageId allocation

Given fixed:

```text
group_sender_message_prefix = 8 bytes
next_group_message_counter
```

vectors MUST show:

- first GroupMessageId allocation;
- incremented allocation;
- uint64 big-endian counter encoding.

#### GROUP_RELIABLE

Exact complete encrypted-frame vectors are REQUIRED for:

```text
one-chunk RELIABLE_ORDERED
one-chunk RELIABLE_ACKED
multi-chunk RELIABLE_ACKED
zero-length RELIABLE_ORDERED
zero-length RELIABLE_ACKED
```

Each vector MUST include:

- complete 62-byte LPC header;
- frame flags;
- pairwise MessageId;
- GroupMessageId;
- source/destination PeerIds;
- delivery_mode;
- priority;
- chunk_index/chunk_count;
- total_application_length;
- chunk_offset/chunk_length;
- ciphertext;
- AEAD tag;
- expected decoded logical payload.

The multi-chunk vector MUST prove:

```text
GROUP_RELIABLE pre-payload header = 84 bytes
maximum chunk bytes = 16300
all hop chunks share one pairwise MessageId
all end-destination chunks share one GroupMessageId
```

#### GROUP_REALTIME_DATAGRAM

At least one exact frame vector is REQUIRED containing:

- source PeerId;
- destination PeerId;
- channelId;
- datagramSequence;
- senderTick;
- payload length;
- application bytes;
- complete LPC encryption bytes.

At least one LPU1-sidecar vector MUST carry the same exact group realtime envelope as UDP plaintext.

#### GROUP_DELIVERY_ACK

One exact complete encrypted-frame vector is REQUIRED.

It MUST include:

```text
group_id
source_peer_id
destination_peer_id
group_message_id
pairwise ACK_REQUIRED MessageId
```

#### GROUP_RELAY_STATUS

One exact complete encrypted-frame vector is REQUIRED for EACH status:

```text
SENT_TO_DESTINATION_TRANSPORT
DESTINATION_NOT_IN_GROUP
DESTINATION_UNAVAILABLE
DESTINATION_ACK_TIMEOUT
RELAY_QUEUE_FULL
GROUP_NOT_READY
```

Each vector MUST contain the exact status/error-code pairing from Section 43.

#### Two-hop relay trace

A complete deterministic trace is REQUIRED for:

```text
B -> coordinator A -> C
```

for `RELIABLE_ACKED`.

The trace MUST prove:

```text
same GroupMessageId on B->A and A->C
different pairwise MessageIds on B->A and A->C
source_peer_id remains B
destination_peer_id remains C
B->A generic ACK does not complete B public SendHandle
C->A generic ACK causes A to emit GROUP_DELIVERY_ACK
GROUP_DELIVERY_ACK causes B public SendHandle REMOTE_ACKNOWLEDGED
```

#### Destination duplicate trace

A trace is REQUIRED where destination C has already completed:

```text
(source_peer_id = B, group_message_id = G)
```

and receives the same logical operation again after reroute/coordinator migration.

Expected behavior:

- no second application event;
- hop operation is ACKed normally;
- coordinator may regenerate GROUP_DELIVERY_ACK;
- no MessageId collision for canonical GroupId normalization alone.

#### Partial-hop GROUP_RELIABLE RESUME trace

A deterministic trace is REQUIRED where:

```text
B -> A remains READY
A -> C sends RELIABLE_ORDERED GROUP_RELIABLE chunks
some, but not all, destination-hop chunks reach SENT_TO_TRANSPORT
A -> C transport generation is lost
A -> C RESUME succeeds
```

The vector/trace MUST prove:

- C discards pre-loss incomplete reassembly;
- A retains the admitted relay operation;
- A retransmits from chunk 0;
- pairwise MessageId is unchanged across successful RESUME of that same logical hop;
- GroupMessageId is unchanged;
- wire sequence numbers are fresh;
- C emits exactly one ReliableMessageReceived;
- A sends SENT_TO_DESTINATION_TRANSPORT only after the full retransmitted hop reaches frame-level SENT_TO_TRANSPORT.

A second trace is REQUIRED where every RELIABLE_ORDERED destination-hop frame reached frame-level SENT_TO_TRANSPORT before generation loss. No retransmission is expected solely because of that later loss.



## 53.2 UDP Sidecar Vectors

- UDP_OFFER reliable control frame;
- UDP_ACCEPT reliable control frame;
- UDP sidecar root derivation;
- `udp_key_0_to_1`;
- `udp_key_1_to_0`;
- exact `LPU1` header bytes;
- UDP nonce construction;
- UDP_PROBE plaintext and encrypted packet;
- UDP_PROBE_ACK plaintext and encrypted packet;
- UDP_REALTIME plaintext and encrypted packet;
- replay-window initialization example;
- reordered accepted UDP packet example;
- replayed UDP packet rejection example;
- UDP_CLOSE control frame.

Every language implementation claiming protocol minor 1 support MUST reproduce these vectors exactly.

The vector package MUST include:

```text
input fields
expected serialized bytes
expected cryptographic intermediate values where non-secret test keys are used
expected final packet bytes
expected parser result
```


# 54. Mandatory Unit Tests

- [ ] UT-001 iOS-compatible canonical discovery requires service UUID only.
- [ ] UT-002 HELLO exact binary encode/decode.
- [ ] UT-003 PeerId = truncated SHA256(identity key).
- [ ] UT-004 AUTH Ed25519 known vector.
- [ ] UT-005 MITM substituted identity key produces different PeerId and fails KNOWN_PEER.
- [ ] UT-006 SAS known vector and six-digit formatting.
- [ ] UT-007 SAS rejection prevents READY.
- [ ] UT-008 PSK_32 known vector.
- [ ] UT-009 Version negotiation succeeds only when the peer's supported range includes minor 1.
- [ ] UT-010 Peer advertising max_minor=0 has no compatible minor and receives pre-key PROTOCOL_MISMATCH.
- [ ] UT-011 PeerCapabilityBitmap encoding exact.
- [ ] UT-012 LocalRuntimeCapabilityBitmap never serialized in HELLO.
- [ ] UT-013 GATT uint32 fragment sequence handles >65535 fragments.
- [ ] UT-014 GATT fragmentation exact reassembly.
- [ ] UT-015 LPC frame >16384 payload rejected.
- [ ] UT-016 1 MiB application message produces correct DATA chunk count.
- [ ] UT-017 PING can be scheduled between DATA chunks.
- [ ] UT-018 derived keepalive dead timeout always >= 3x interval.
- [ ] UT-019 ACK timeout retransmits same MessageId with new wire sequences.
- [ ] UT-020 duplicate retransmission delivered once and ACKed again.
- [ ] UT-021 conflicting duplicate chunk closes MESSAGE_ID_COLLISION.
- [ ] UT-022 initial SessionId deterministic and no alternate random definition.
- [ ] UT-023 RESUME candidate generation 0 behavior.
- [ ] UT-024 RESUME proof success.
- [ ] UT-025 RESUME proof failure.
- [ ] UT-026 RESUME preserves SessionId and MessageId prefix.
- [ ] UT-027 RESUME resets wire sequence to 1 at incremented generation.
- [ ] UT-028 unacked ACK-required message retransmits after resume.
- [ ] UT-029 non-ACK sent message is not auto-retransmitted after resume.
- [ ] UT-030 upgrade BIND exact proof.
- [ ] UT-031 upgrade failure before SWITCH leaves old transport active.
- [ ] UT-032 failure after SWITCH triggers RESUME fallback, never old-generation rollback.
- [ ] UT-033 symmetric dual GATT connection chooses one deterministic rank winner.
- [ ] UT-034 queue preserves application send order.
- [ ] UT-035 queue bounds enforced.
- [ ] UT-036 queued message expiry before transmission.
- [ ] UT-037 runtime.close cascades child closure once.
- [ ] UT-038 DiscoverySession.stop does not close PeerConnection.
- [ ] UT-039 PeerConnection send after disconnect returns INVALID_STATE.
- [ ] UT-040 illegal backend callback does not create illegal state transition.
- [ ] UT-041 First MessageId allocation uses counter value 1.
- [ ] UT-042 MessageId allocation permits UINT32_MAX exactly once, then requires a new SessionId.
- [ ] UT-043 A 262144-byte coordinator checkpoint chunks into control frames whose plaintext is <=4032 bytes.
- [ ] UT-044 Every chunk of one coordinator checkpoint shares one MessageId and uses a fresh reliable wire sequence number.
- [ ] UT-045 Coordinator checkpoint ACK is emitted only after complete reassembly and commit.
- [ ] UT-046 Duplicate completed coordinator checkpoint is not reapplied and emits ACK again.
- [ ] UT-047 Checkpoint retransmission resends all chunks with the same MessageId and new reliable wire sequences.
- [ ] UT-048 ACK_REQUIRED header-bit binary vector matches exactly.
- [ ] UT-049 Duplicate ACK-required MEMBERSHIP_SNAPSHOT does not reapply membership state and emits ACK again.
- [ ] UT-050 KnownPeerPolicy ALLOWLIST vector accepts a listed identity and rejects an unlisted identity.
- [ ] UT-051 MEMBERSHIP_SNAPSHOT final ACK timeout sets GroupSyncState=UNSYNCHRONIZED and triggers reconnect/resync.
- [ ] UT-052 GROUP_MERGE final ACK timeout preserves committed merge and forces target rebootstrap.
- [ ] UT-053 COORDINATOR_CHECKPOINT final ACK timeout reports replication failure without changing membership.

---
- [ ] UT-054 ACK timer for multi-chunk RELIABLE_ACKED DATA starts only after the final DATA chunk of the attempt reaches SENT_TO_TRANSPORT.
- [ ] UT-055 ACK timer for chunked COORDINATOR_CHECKPOINT starts only after the final checkpoint chunk of the attempt reaches SENT_TO_TRANSPORT.
- [ ] UT-056 A transmission attempt taking longer than 3000 ms does not trigger ACK timeout before its final frame/chunk reaches SENT_TO_TRANSPORT.
- [ ] UT-057 SENT_TO_TRANSPORT means backend acceptance of the complete serialized LPC frame, not scheduler enqueue.
- [ ] UT-058 Transport loss before final chunk SENT_TO_TRANSPORT starts no ACK timeout for that incomplete attempt.
- [ ] UT-059 Post-RESUME retransmission starts a fresh ACK timer only after the final retransmitted frame/chunk reaches SENT_TO_TRANSPORT.
- [ ] UT-060 Incomplete checkpoint reassembly is discarded immediately on transport loss.
- [ ] UT-061 After RESUME, unacknowledged checkpoint retransmits from chunk 0 with same MessageId and fresh wire sequences.
- [ ] UT-062 Section 6 MessageId semantics cover ACK-required control operations.
- [ ] UT-063 GATT LPC frame does not reach SENT_TO_TRANSPORT when merely inserted into the backend fragmentation queue.
- [ ] UT-064 GATT LPC frame reaches SENT_TO_TRANSPORT only after its final GATT fragment is submitted to the platform API.
- [ ] UT-065 ACK timer for multi-chunk DATA begins only after the final physical GATT fragment of the final LPC DATA frame is submitted.
- [ ] UT-066 TCP LPC frame reaches SENT_TO_TRANSPORT only after all serialized frame bytes are accepted by the socket/kernel send path.
- [ ] UT-067 L2CAP LPC frame reaches SENT_TO_TRANSPORT only after all serialized frame bytes are accepted by the L2CAP stream write mechanism.
- [ ] UT-068 Backend TransportWrite remains PENDING while transport-specific fragmentation is only internally queued.
- [ ] UT-069 A TransportWrite failure before final platform submission does not start an ACK timer.
- [ ] UT-070 After RESUME_READY, unacknowledged ACK-required control operations are retransmitted and duplicate protocol-state mutation is suppressed.
- [ ] UT-071 Transient backend not-writable/backpressure keeps TransportWrite PENDING and does not enter RECONNECTING.
- [ ] UT-072 Terminal GATT fragment submission error transitions TransportWrite to FAILED and PeerConnection into transport-loss/RECONNECTING.
- [ ] UT-073 TransportWrite.FAILED never starts an ACK timer and same transport generation sends no further LPC frames.
- [ ] UT-074 All PENDING TransportWrites on a terminally failed physical transport complete FAILED.
- [ ] UT-075 Partially reassembled RELIABLE_ORDERED DATA is discarded when transport generation is lost.
- [ ] UT-076 Partially reassembled RELIABLE_ACKED DATA is discarded when transport generation is lost.
- [ ] UT-077 Partially transmitted RELIABLE_ORDERED message retransmits from chunk 0 after RESUME when at least one chunk never reached frame-level SENT_TO_TRANSPORT.
- [ ] UT-078 Fully frame-submitted RELIABLE_ORDERED message is not retransmitted after RESUME.
- [ ] UT-079 RELIABLE_ACKED message retransmits all chunks after RESUME regardless of how many chunks reached SENT_TO_TRANSPORT before loss.
- [ ] UT-080 Multi-frame SendHandle reaches SENT_TO_TRANSPORT only after every DATA chunk reaches frame-level SENT_TO_TRANSPORT.
- [ ] UT-081 Protocol-minor no-overlap emits exact pre-key plaintext ERROR(PROTOCOL_MISMATCH) with zero session/message/nonce fields and no AEAD tag.
- [ ] UT-082 Pre-key ERROR(PROTOCOL_MISMATCH) uses protocol_minor equal to sender max_minor.
- [ ] UT-083 Plaintext ERROR with a non-PROTOCOL_MISMATCH error code is rejected.
- [ ] UT-084 Plaintext ERROR after AUTH/session-key establishment is rejected.
- [ ] UT-085 After sending pre-key ERROR(PROTOCOL_MISMATCH), sender closes without sending AUTH.
- [ ] UT-086 GroupId merge winner uses larger committed_member_count before lexicographic GroupId tie-break.
- [ ] UT-087 Conforming HELLO advertises min_minor=1 and max_minor=1.
- [ ] UT-088 Peer advertising only minor 0 is rejected with pre-key PROTOCOL_MISMATCH before AUTH.
- [ ] UT-089 Implementation does not attempt to encode a minor-0 DATA frame after version negotiation failure.
- [ ] UT-090 When checkpoint A is in flight and B then C are published, only A and C are transmitted; B is replaced before transmission.
- [ ] UT-091 Checkpoint replication retains at most one in-flight and one pending checkpoint per target peer.
- [ ] UT-092 Publishing a newer checkpoint does not cancel or truncate an ACK-required checkpoint already in flight.
- [ ] UT-093 After in-flight checkpoint terminal completion, the most recent pending checkpoint becomes the next transmitted checkpoint.
- [ ] UT-094 A checkpoint replaced while pending allocates neither MessageId nor checkpoint_sequence.
- [ ] UT-095 checkpoint_sequence increments only when a checkpoint is promoted to an actual in-flight operation, so pending replacement creates no sequence gap.
- [ ] UT-096 A newly READY peer receives only the latest retained coordinator checkpoint rather than historical checkpoint backlog.
- [ ] UT-097 Given peers A and B have different checkpoint replication progress, one application checkpoint publication may become in-flight for A while remaining pending for B; A and B allocate MessageId and checkpoint_sequence independently only when that checkpoint becomes in-flight for the respective peer.
- [ ] UT-098 Same coordinator and same term: later membership-snapshot MessageId counter is considered newer.
- [ ] UT-099 Older same-term MEMBERSHIP_SNAPSHOT received after newer accepted snapshot is ACKed but does not mutate committed membership.
- [ ] UT-100 Membership snapshot MessageIds from different coordinator PeerIds or different terms are never ordered against each other by counter.
- [ ] UT-101 Membership snapshot MessageId ordering is scoped by SessionId and MUST NOT compare counters across logical sessions.
- [ ] UT-102 A new SessionId with same coordinator and coordinator_term accepts its first valid membership snapshot as a fresh ordering baseline even when its counter is lower than the previous SessionId's counter.
- [ ] UT-103 Different SessionIds remain distinct membership-ordering domains even if sender_message_prefix bytes are equal.
- [ ] UT-104 Non-coordinator B sending to non-coordinator C routes B->coordinator->C and does not require a B-C PeerConnection.
- [ ] UT-105 RELIABLE_ACKED GroupSession SendHandle does not complete on source->coordinator generic ACK and completes only after GROUP_DELIVERY_ACK for destination C.
- [ ] UT-106 Relayed GROUP_RELIABLE preserves GroupMessageId end-to-end while each hop uses an independently allocated pairwise MessageId.
- [ ] UT-107 Destination duplicate (sourcePeerId, GroupMessageId) with identical content is not redelivered and permits destination ACK regeneration.
- [ ] UT-108 GROUP_REALTIME_DATAGRAM preserves original sourcePeerId through coordinator relay.
- [ ] UT-109 broadcast excludes local peer and snapshots committed remote membership at acceptance time.
- [ ] UT-110 BroadcastHandle COMPLETED means all constituent SendHandles are terminal, including partial failures.
- [ ] UT-111 RealtimeBroadcastHandle COMPLETED permits mixed terminal constituent results.
- [ ] UT-112 ReliableMessageReceived exposes sourcePeerId, GroupMessageId, deliveryMode, and bytes.
- [ ] UT-113 RealtimeDatagramReceived exposes sourcePeerId, channelId, senderTick, datagramSequence, and bytes.
- [ ] UT-114 members() is updated before MemberJoined/MemberLeft callback delivery.
- [ ] UT-115 coordinator getters are updated before CoordinatorChanged callback delivery.
- [ ] UT-116 GroupSession callbacks are serialized and never concurrent.
- [ ] UT-117 Public GroupSession methods are safe under concurrent invocation and reentrant send() from an event callback does not deadlock.
- [ ] UT-118 No total order is inferred across messages from different source PeerIds.
- [ ] UT-119 GROUP_RELIABLE source-to-coordinator final hop ACK timeout terminates the group send with ACK_TIMEOUT rather than retaining forever.
- [ ] UT-120 GROUP_RELIABLE coordinator-to-destination final ACK timeout produces GROUP_RELAY_STATUS(DESTINATION_ACK_TIMEOUT).
- [ ] UT-121 Final ACK timeout of GROUP_DELIVERY_ACK forces source-link reconnect; if source never received it, retained GroupMessageId reroutes and destination dedup avoids redelivery.
- [ ] UT-122 Committed destination whose coordinator PeerConnection is not READY yields DESTINATION_UNAVAILABLE immediately for a new reliable group send; realtime is dropped.
- [ ] UT-123 GROUP_RELAY_STATUS status values map to exact public error codes.
- [ ] UT-124 Coordinator with insufficient destination reliable-queue capacity fully receives and validates RELIABLE_ACKED GROUP_RELIABLE, generic-ACKs the source hop, retains no relay operation, and sends GROUP_RELAY_STATUS(RELAY_QUEUE_FULL).
- [ ] UT-125 Coordinator does not source-hop ACK a partial GROUP_RELIABLE operation.
- [ ] UT-126 Relay admission reserves one complete logical operation's byte/message budget atomically before source-hop ACK.
- [ ] UT-127 Route admission failure never causes repeated retransmission of the same large source hop solely because destination queue is full.
- [ ] UT-128 Incomplete GROUP_RELIABLE reassembly is discarded on transport-generation loss.
- [ ] UT-129 Partially submitted RELIABLE_ORDERED coordinator-to-destination GROUP_RELIABLE retransmits the complete hop from chunk 0 after successful RESUME using the same pairwise MessageId and GroupMessageId.
- [ ] UT-130 Partially submitted RELIABLE_ACKED GROUP_RELIABLE retransmits the complete hop from chunk 0 after RESUME with the same pairwise MessageId and GroupMessageId.
- [ ] UT-131 Fully frame-submitted RELIABLE_ORDERED GROUP_RELIABLE is not retransmitted solely because transport fails afterward.
- [ ] UT-132 A retained admitted RELIABLE_ORDERED relay continues to consume its original bounded destination-queue reservation while destination PeerConnection is RECONNECTING.
- [ ] UT-133 If destination-hop RESUME fails after partial RELIABLE_ORDERED relay, coordinator discards retained relay state and reports DESTINATION_UNAVAILABLE.
- [ ] UT-134 After a completed (sourcePeerId, GroupMessageId) entry is evicted from the 16,384-entry destination dedup window, a later replay of that older GroupMessageId is not required to be recognized as duplicate and may redeliver.
- [ ] UT-135 Queued reliable send cancelled before transmission sends no application frame and terminates CANCELLED.
- [ ] UT-136 RELIABLE_ACKED source operation cancelled after partial local transmission performs no future source-side retry or reroute.
- [ ] UT-137 Routed RELIABLE_ACKED send cancelled after coordinator relay admission may still complete destination delivery while source handle remains CANCELLED.
- [ ] UT-138 GROUP_DELIVERY_ACK arriving after local cancellation is authenticated and generic-ACKed through the cancellation tombstone but does not transition the cancelled handle.
- [ ] UT-139 GROUP_RELAY_STATUS arriving after local cancellation is authenticated and generic-ACKed through the cancellation tombstone but does not transition the cancelled handle.
- [ ] UT-140 CANCELLED does not imply destination non-delivery when destination committed before cancellation result reached the source.
- [ ] UT-141 When destination membership removal commits, nonterminal admitted relay operations targeting that destination are terminated and queued application traffic is not sent afterward.
- [ ] UT-142 Cancelled routed send creates a tombstone; when all PeerConnection SessionIds capable of valid late signaling terminate while GroupSession remains open, the tombstone is released and no longer consumes tombstone capacity.
- [ ] UT-143 GroupSession close releases all cancellation tombstones even if a previously signaling-capable PeerConnection SessionId would otherwise remain live.
- [ ] UT-144 Delayed GROUP_DELIVERY_ACK from a former coordinator on the same historically valid SessionId and matching a cancellation tombstone is generic-ACKed and discarded as stale-authority signaling without changing CANCELLED.
- [ ] UT-145 Former coordinator signaling for a nonterminal send never completes or fails that send after coordinator migration.
- [ ] UT-146 A former coordinator cannot use the stale-authority exception to originate new route signaling after loss of coordinator authority.
- [ ] UT-147 The 16,384 completed GroupMessageId dedup entries form one shared destination-GroupSession cache across all source PeerIds rather than a per-source cache.
- [ ] UT-148 When coordinator authority loss commits, every nonterminal admitted relay owned by the former coordinator stops future GROUP_RELIABLE submission, releases queue reservation, and retains no reroute ownership.
- [ ] UT-149 Source-cancellation relay continuation is overridden by coordinator authority loss.
- [ ] UT-150 Already-in-flight GROUP_DELIVERY_ACK from immediately previous coordinator on the historically valid SessionId is generic-ACKed and semantically discarded after migration without completing/failing a nonterminal send.
- [ ] UT-151 Already-in-flight GROUP_RELAY_STATUS from immediately previous coordinator on the historically valid SessionId is generic-ACKed and semantically discarded after migration.
- [ ] UT-152 Stale former-coordinator GROUP_RELIABLE arriving after new coordinator commit does not emit application delivery or cause PROTOCOL_MISMATCH when historical authority/SessionId checks pass.
- [ ] UT-153 Incomplete stale former-coordinator GROUP_RELIABLE reassembly is discarded and never combined with rerouted chunks from the new coordinator.
- [ ] UT-154 Stale former-coordinator GROUP_REALTIME_DATAGRAM is authenticated then discarded without RealtimeDatagramReceived.
- [ ] UT-155 A former coordinator newly originating routing/signaling after authority loss does not qualify for stale-authority handling.
- [ ] UT-156 HELLO `keepalive_interval_ms` is encoded at offset 106 and both
  peers derive identical READY keepalive interval/dead-timeout values.

# 55. Mandatory Physical Integration Tests

Every mobile release candidate MUST run:

- [ ] IT-001 iOS advertises only service UUID and Android discovers it.
- [ ] IT-002 Android canonical service-UUID advertisement is discovered by iOS.
- [ ] IT-003 Android central -> iOS peripheral.
- [ ] IT-004 iOS central -> Android peripheral.
- [ ] IT-005 Ed25519 identity continuity verified across reconnect.
- [ ] IT-006 SAS values match on honest Android/iOS connection.
- [ ] IT-007 deliberately altered handshake fails SAS/known-peer authentication.
- [ ] IT-008 1000 x 32-byte messages, zero corruption.
- [ ] IT-009 1 MiB application message over GATT succeeds via DATA chunking.
- [ ] IT-010 keepalive remains healthy during 1 MiB transfer.
- [ ] IT-011 ACK retry with intentionally dropped ACK produces one app delivery.
- [ ] IT-012 out-of-range enters Reconnecting.
- [ ] IT-013 return within timeout resumes same SessionId.
- [ ] IT-014 resumed wire generation increments and sequence restarts.
- [ ] IT-015 return after timeout produces PeerDisconnected.
- [ ] IT-016 Bluetooth off/on recovery.
- [ ] IT-017 30-minute two-player soak.
- [ ] IT-018 four-player star.
- [ ] IT-019 eight-player star where hardware permits.
- [ ] IT-020 weak client does not stall other clients.
- [ ] IT-021 simultaneous symmetric connect leaves exactly one PeerConnection.
- [ ] IT-022 background/foreground no crash and state reconciles.
- [ ] IT-023 L2CAP upgrade if supported.
- [ ] IT-024 forced L2CAP upgrade failure remains on GATT.
- [ ] IT-025 LAN upgrade if supported.
- [ ] IT-026 LAN failure after switch triggers secure RESUME to GATT.
- [ ] IT-027 transport switch under continuous traffic has zero duplicate ACK-required app messages.
- [ ] IT-028 262144-byte coordinator checkpoint replicates successfully using bounded checkpoint chunks and one logical ACK.
- [ ] IT-029 Injected terminal GATT submission failure during multi-chunk RELIABLE_ACKED DATA enters RECONNECTING and resumes/retransmits successfully.
- [ ] IT-030 Injected terminal GATT submission failure during partially transmitted RELIABLE_ORDERED DATA resumes by retransmitting the entire logical message from chunk 0.
- [ ] IT-031 Simulated transient GATT backpressure does not disconnect/reconnect and transmission resumes when writable.



## Automatic Coordinator Tests

- [ ] COORD-001 Three peers starting simultaneously converge on one coordinator without user host selection.
- [ ] COORD-002 Existing healthy coordinator remains coordinator when a higher-ranked peer joins.
- [ ] COORD-003 Coordinator disappears and remaining peers elect exactly one replacement.
- [ ] COORD-004 Coordinator migration retains the same GroupId.
- [ ] COORD-005 Coordinator migration retains all PeerIds.
- [ ] COORD-006 Coordinator migration rebuilds star automatically.
- [ ] COORD-007 Two singleton groups merge and deterministically retain lexicographically smaller GroupId.
- [ ] COORD-008 Same-term competing coordinator claims converge to higher CoordinatorRank.
- [ ] COORD-009 Higher election term always supersedes lower term.
- [ ] COORD-010 Latest committed membership snapshot survives coordinator loss.
- [ ] COORD-011 Coordinator checkpoint is available to newly promoted coordinator.
- [ ] COORD-012 No UI/user approval callback is required for migration.
- [ ] COORD-013 Two partitioned halves independently elect coordinators, reconnect, and converge to one coordinator.
- [ ] COORD-014 Divergent same-GroupId membership snapshots reconcile at `max(termA, termB)+1`.
- [ ] COORD-015 A 6-member group and 5-member group refuse automatic merge when effective_max_peers=8.
- [ ] COORD-016 Different maxPeers values negotiate `min(all member maxPeers)`.
- [ ] COORD-017 Winning coordinator learns complete losing membership from GROUP_INFO before merge.
- [ ] COORD-018 Losing GroupId alias redirects an authenticated reconnecting member for exactly 30 seconds.
- [ ] COORD-019 Three compatible groups discovered simultaneously converge deterministically on one GroupId.
- [ ] COORD-020 Stale GROUP_MERGE from an older/equal already-superseded term is ignored.
- [ ] COORD-021 Same namespace but different TOKEN_SCOPED join tokens never auto-merge.
- [ ] COORD-022 OPEN_PROXIMITY groups do auto-merge when all other compatibility checks pass.
- [ ] COORD-023 Split-brain union exceeding capacity does not arbitrarily evict existing committed members.
- [ ] COORD-024 GROUP_INFO carries every member's max_peers and remote peer computes the same effective_max_peers.
- [ ] COORD-025 Groups with different GroupTrustMode values refuse automatic merge.
- [ ] COORD-026 KNOWN_PEERS groups with knownPeersAutoMerge=false remain separate.
- [ ] COORD-027 GROUP_MERGE_REJECT is emitted only by the would-be winning coordinator.
- [ ] COORD-028 Normal member GROUP_LEAVE removes it and produces a same-term MEMBERSHIP_SNAPSHOT.
- [ ] COORD-029 Abrupt non-coordinator disconnect retains membership through reconnect window then removes it on terminal timeout.
- [ ] COORD-030 Coordinator voluntary leave triggers immediate election without waiting for heartbeat timeout.
- [ ] COORD-031 Replacement coordinator first snapshot excludes voluntarily/abruptly departed old coordinator.
- [ ] COORD-032 Coordinator KICKED leave removes only the target member and publishes a new snapshot.
- [ ] COORD-033 Membership changes caused by normal join/leave/kick do not increment coordinator term.
- [ ] COORD-034 Conflicting same-PeerId max_peers snapshots reconcile to the minimum value.
- [ ] COORD-035 MEMBERSHIP_SNAPSHOT final ACK timeout marks peer UNSYNCHRONIZED and forces reconnect/resynchronization.
- [ ] COORD-036 GROUP_MERGE final ACK timeout does not roll back merge and forces target peer to rebootstrap.
- [ ] COORD-037 COORDINATOR_CHECKPOINT final ACK timeout reports replication failure without removing/disconnecting the peer.
- [ ] COORD-038 Ordinary GROUP_LEAVE ACK loss does not prevent leaving peer from closing after its grace period.
- [ ] COORD-039 Kicked-member GROUP_LEAVE ACK loss does not keep that peer committed.
- [ ] COORD-040 Coordinator-resignation GROUP_LEAVE ACK loss does not cancel resignation or election.
- [ ] COORD-041 A 5-member group with lexicographically larger GroupId merges with a 1-member group with smaller GroupId; the 5-member group's GroupId survives.
- [ ] COORD-042 Two equally sized groups merge; the lexicographically smaller GroupId survives.
- [ ] COORD-043 Rapid checkpoint publication over slow BLE keeps exactly one in-flight and one pending checkpoint per peer.
- [ ] COORD-044 With A in flight and B then C published, a slow peer receives A then C, never B.
- [ ] COORD-045 A peer that reconnects receives the latest retained checkpoint without replaying historical checkpoint publications.
- [ ] COORD-046 Same published checkpoint may be in-flight for peer A and pending for peer B; each peer allocates its own MessageId/checkpoint_sequence only at that peer's promotion time.
- [ ] COORD-047 Same-term membership snapshot B accepted after A MUST prevent later A retransmission from replacing B after RESUME.
- [ ] COORD-048 A ACKed, B partially transmitted, transport loss, RESUME, and B retransmission converges to B without stale rollback to A.
- [ ] COORD-049 A ACKed, B fully transmitted but ACK lost, transport loss, RESUME, duplicate B remains committed exactly once.
- [ ] COORD-050 B accepted remotely but ACK lost; post-RESUME retransmission of B is ACKed again without duplicate membership mutation.
- [ ] COORD-051 Transport loss during retransmission of newer same-term snapshot B cannot allow older snapshot A to overwrite B.
- [ ] COORD-052 Coordinator C remains at term T. Under SessionId S1, receiver accepts snapshot counter 100. S1 expires and cannot RESUME. Under new SessionId S2, receiver accepts current snapshot counter 1 as the new ordering baseline and MUST NOT compare it against S1 counter 100.
- [ ] COORD-053 Same coordinator/term establishes a new SessionId whose sender_message_prefix bytes collide with an expired prior SessionId; receiver still treats the new SessionId as a distinct membership-ordering domain.
- [ ] COORD-054 B sends to C in a coordinator star with no B-C PeerConnection; A relays and C receives sourcePeerId=B.
- [ ] COORD-055 B RELIABLE_ACKED send to C survives coordinator loss before destination acknowledgment by retaining GroupMessageId and rerouting through the new coordinator.
- [ ] COORD-056 Destination C accepted B's message but destination acknowledgment was lost during coordinator failure; post-migration duplicate relay does not redeliver and regenerates acknowledgment.
- [ ] COORD-057 RELIABLE_ORDERED B->C SendHandle reaches SENT_TO_TRANSPORT only after coordinator reports final-hop submission.
- [ ] COORD-058 Broadcast from B snapshots committed remote members, excludes B, and produces independent per-destination results.
- [ ] COORD-059 Coordinator queue-full relay admission ACKs the fully received source hop exactly once, sends RELAY_QUEUE_FULL, retains no destination relay operation, and source fails without re-sending the 1 MiB source hop.
- [ ] COORD-060 B->A remains healthy while A->C fails halfway through a multi-chunk RELIABLE_ORDERED relay. A->C RESUMEs, A retransmits the complete destination hop from chunk 0 with the same pairwise MessageId and GroupMessageId, C emits exactly one application event, and B eventually reaches SENT_TO_TRANSPORT.
- [ ] COORD-061 A->C fails after every RELIABLE_ORDERED GROUP_RELIABLE chunk reached frame-level SENT_TO_TRANSPORT but before any later unrelated traffic; A does not retransmit that completed hop solely because of the transport failure.
- [ ] COORD-062 GroupMessageId dedup eviction is bounded: after C completes message G, more than 16,384 newer completed source/message pairs evict G, and a later replay of G is not required to be suppressed as duplicate.
- [ ] COORD-063 B sends G to C through A. A admits and generic-ACKs the source hop. B cancels before A->C completes. A may complete delivery, C emits exactly one event, A sends GROUP_DELIVERY_ACK, B authenticates/ACKs the late signaling through its cancellation tombstone, B remains CANCELLED, and B never reroutes G.
- [ ] COORD-064 A has admitted B->C. C is removed from committed membership before destination delivery commits. A terminates the relay, releases reservation, sends DESTINATION_NOT_IN_GROUP to B when possible, and sends no additional application chunks to C.
- [ ] COORD-065 A is coordinator and has an already-created/in-flight GROUP_DELIVERY_ACK for G. B has cancelled G. D becomes coordinator before B receives A's signaling. Delayed signaling from former coordinator A on the same historically valid SessionId is authenticated and generic-ACKed as stale-authority signaling, cannot alter B's CANCELLED handle, and cannot revive/reroute G.
- [ ] COORD-066 B sends G to C through coordinator A. A admits G and transmits only part of the final-hop GROUP_RELIABLE. Before C commits the complete application message, D becomes committed coordinator. A stops future relay transmission and releases its admitted relay state. B reroutes G through D with the same GroupMessageId and new pairwise MessageIds. C commits G exactly once.
- [ ] COORD-067 A submitted a GROUP_RELIABLE frame while still coordinator, but C receives it only after committing D as new coordinator. C classifies it as stale-authority traffic on the historically valid A-C SessionId, does not redeliver, and does not treat the healthy historical A-C PeerConnection as malicious protocol corruption.
- [ ] COORD-068 B has a nonterminal routed send when an already-in-flight GROUP_DELIVERY_ACK from old coordinator A arrives after D becomes coordinator. B generic-ACKs and discards A's stale signaling, leaves the SendHandle nonterminal, and continues completion only through D.
















## Realtime Datagram Tests

- [ ] RT-001 REALTIME_LATEST emits no ACK.
- [ ] RT-002 REALTIME_LATEST is never retransmitted after simulated loss.
- [ ] RT-003 New queued state supersedes older queued state on same channel.
- [ ] RT-004 Realtime states on different channelIds do not supersede each other.
- [ ] RT-005 Receiver drops older/equal datagram sequence.
- [ ] RT-006 Receiver accepts sequence gaps.
- [ ] RT-007 1101-byte realtime payload fails deterministically.
- [ ] RT-008 Queued realtime packet expires after 100 ms by default.
- [ ] RT-009 Reconnect discards pre-disconnect realtime queue.
- [ ] RT-010 RESUME preserves realtime channel sequence counters, discards old queued state, and accepts the next freshly generated sequence.
- [ ] RT-011 GATT realtime uses Write Without Response central->peripheral.
- [ ] RT-012 GATT realtime uses Notify peripheral->central.
- [ ] RT-013 Optional LAN UDP carries realtime only, never reliable DATA.
- [ ] RT-014 Heavy realtime traffic cannot permanently starve reliable interactive traffic.
- [ ] RT-015 A delayed reliable frame is accepted after a numerically later UDP packet arrives.
- [ ] RT-016 UDP packet loss does not create a reliable sequence gap or reliable replay failure.
- [ ] RT-017 UDP packets may reorder within the 256-packet UDP replay window without affecting reliable traffic.
- [ ] RT-018 A maximum 1100-byte realtime payload produces a UDP datagram <=1232 bytes.
- [ ] RT-019 A spoofed or modified UDP datagram fails AEAD authentication.
- [ ] RT-020 UDP source IP/port change is rejected and deterministically triggers sidecar re-establishment.
- [ ] RT-021 UDP sidecar loss falls back to the existing reliable transport without changing reliable transport generation.
- [ ] RT-022 UDP packet sequence and realtime datagram_sequence advance independently.
- [ ] RT-023 Reliable RESUME destroys the old UDP sidecar and requires fresh UDP key derivation.
- [ ] RT-024 Simultaneous UDP capability detection causes only the lexicographically smaller PeerId to initiate automatically.
- [ ] RT-025 First valid UDP packet initializes an empty replay window and is accepted.
- [ ] RT-026 UDP packet sequence never wraps; fresh sidecar is required before UINT64_MAX.
- [ ] RT-027 Unexpected-source authenticated UDP packet invalidates sidecar only; reliable PeerConnection remains READY.



---

# 56. Performance Acceptance Targets

For at least one modern Android/iOS pair:

```text
Foreground discovery p95:      <= 3000 ms
Initial READY p95:             <= 5000 ms
32-byte ping RTT p95 on GATT:  <= 150 ms
Reconnect p95:                 <= 5000 ms
GATT throughput:               >= 20 KB/s
Coordinator migration p95:       <= 5000 ms after coordinator declared unavailable
Realtime queued-state age p95:    <= 150 ms under supported game load
Duplicate RELIABLE_ACKED DATA:    0
Corrupted app DATA:            0
Unbounded memory growth:       0
```

If a target is not met on a platform/device, the release MUST document the exception in `COMPATIBILITY.md`.

---

# 57. Version Roadmap

## v0.1

MUST deliver:

- iOS-compatible service-UUID-only BLE discovery advertisement;
- mutual discovery;
- GATT service;
- GATT fragmentation;
- frame parser;
- exact packet format;
- cross-platform byte exchange.

## v0.2

MUST deliver:

- exact cryptographic handshake;
- PeerId;
- SessionId;
- sequence numbers;
- keepalive;
- reconnect;
- RESUME;
- star topology.

## v0.2.1 / Protocol Minor 1

MUST deliver:

- symmetric `joinOrCreateGroup`;
- automatic coordinator election;
- automatic coordinator migration;
- deterministic group merging;
- replicated membership snapshots;
- optional coordinator checkpoints;
- RELIABLE_ORDERED;
- RELIABLE_ACKED;
- REALTIME_LATEST;
- coordinator-relayed GroupSession application routing and destination-level ACK semantics;
- latest-only realtime queue replacement;
- optional authenticated LAN UDP realtime path.

## v0.3

MUST deliver:

- L2CAP capability;
- L2CAP upgrade;
- fallback.

## v0.4

MUST deliver:

- LAN TCP;
- LAN upgrade;
- fallback.

## v0.5

MUST deliver:

- binding-independent protocol package;
- published test vectors;
- Swift proof-of-concept binding;
- Kotlin proof-of-concept binding;
- binding conformance suite.

## v1.0

MUST deliver:

- stable protocol major 1;
- stable API semantics;
- Android/iOS production support;
- security review;
- compatibility matrix;
- complete mandatory tests.

---

# 58. AI / Developer Implementation Rules

A developer or AI implementation agent MUST follow these rules:

1. Do not invent alternate packet formats.
2. Do not substitute Ed25519/X25519/HKDF-SHA256/ChaCha20-Poly1305 cryptographic primitives.
3. Do not change integer endianness.
4. Do not use platform Bluetooth identity as PeerId.
5. Do not require Bluetooth bonding. Use LPC identity authentication and explicit trust modes instead.
6. Do not make shared Wi-Fi a baseline requirement.
7. Do not expose GATT details in the public common API.
8. Do not use unbounded queues.
9. Do not silently retry forever.
10. Do not silently downgrade from authenticated LPC sessions to unauthenticated transport.
11. Do not mark TRANSPORT_CONNECTED as application READY.
12. Do not deliver duplicate completed application messages. ACK-required retransmissions reuse MessageId and must deduplicate.
13. Do not change state outside the defined state machine.
14. Do not make unsupported transports silently succeed.
15. Do not implement mesh before protocol major 1 is stable.
16. Every protocol change requires an updated wire-protocol version and test vectors.
17. Every backend must pass backend conformance tests.
18. Every language binding must pass binary protocol vectors.
19. Every completed feature must map to a test ID.
20. If a platform cannot implement a REQUIRED V1 feature, document the incompatibility and fail capability checks explicitly.
21. Do not require an application or user to preselect a networking host when using GroupSession.
22. Coordinator election and migration MUST follow Section 10 exactly.
23. Do not equate LPC coordinator with BLE central/peripheral role.
24. Do not ACK or retransmit REALTIME_LATEST datagrams.
25. Do not queue more than one unsent REALTIME_LATEST datagram per peer/channel.
26. Do not replay realtime datagrams after RESUME.
27. Normal `send()` defaults to RELIABLE_ORDERED, not RELIABLE_ACKED.
28. Use RELIABLE_ACKED only when the application explicitly requests acknowledgment semantics.


---

29. Do not invent direct member-to-member routing for GroupSession application traffic. Non-coordinator traffic routes through the current coordinator.
30. Do not treat a hop-local generic ACK from the coordinator as `SendHandle.REMOTE_ACKNOWLEDGED`; only destination-level GROUP_DELIVERY_ACK completes a RELIABLE_ACKED group send.
31. Do not expose coordinator PeerId as the source of relayed application events; preserve the original sourcePeerId.
32. Do not invent total ordering or atomic broadcast semantics across multiple source peers.
33. Serialize callbacks/events per object and implement the public concurrency/reentrancy contract in Section 52.
# 59. Final Developer Experience

The target application code must remain conceptually this simple:

```text
runtime = createRuntime(config)

group = runtime.joinOrCreateGroup(groupConfig)

group.events().on(CoordinatorChanged, ...)
group.events().on(MemberJoined, ...)
group.events().on(ReliableMessageReceived, ...)
group.events().on(RealtimeDatagramReceived, ...)

group.broadcast(reliableEvent, deliveryMode=RELIABLE_ACKED)

group.broadcastRealtime(
    channelId=1,
    bytes=currentGameState
)

group.leave()
runtime.close()
```

The framework is responsible for:

```text
BLE discovery
BLE role selection and duplicate-link resolution
GATT service management
fragmentation
secure authentication
message framing
sequence numbers
duplicate suppression
keepalive
reconnect
resume
transport negotiation
transport upgrade
transport fallback
multi-peer isolation
coordinator relay routing
broadcast fanout/result aggregation
event serialization and thread-safe public method dispatch
platform-specific behavior
```

The application is responsible for:

```text
game rules
lobby rules
UI
player naming
game-state replication
authoritative game-state restore logic when coordinator changes
application payload format
```

---


# 60. Review Issue Resolution Record

This section records the redesign made after independent protocol review.

| Review issue | Validity | Normative resolution |
|---|---|---|
| iOS cannot emit custom advertisement format | Valid blocker | V1 canonical advertisement now uses service UUID only. All protocol metadata moves to HELLO. |
| Initial handshake did not authenticate peer identity | Valid blocker | Persistent Ed25519 identity key, PeerId derived from public key, signed AUTH, explicit KNOWN_PEER/SAS/PSK_32/TOFU trust levels. Default first-contact mode is SAS. |
| P2P role election conflicted with connect API | Valid blocker | Advertiser is peripheral, caller of connect is central. Symmetric dual-connect is resolved after authentication by deterministic duplicate-link ranking. |
| uint16 fragment sequence insufficient | Valid blocker | Fragment sequence changed to uint32. |
| 1 MiB GATT frame conflicts with keepalive | Valid blocker | Frame plaintext capped at 16,384 bytes. 1 MiB application messages are chunked into multiple DATA frames; control frames interleave between chunks. |
| RESUME lifecycle underspecified | Valid blocker | Fresh candidate handshake, generation-0 candidate encryption, exact request/accept proofs, resumed-root derivation, SessionId preservation, generation increment, sequence reset, RESUME_READY specified. |
| Upgrade/fallback incomplete | Valid blocker | Exact offer/accept/reject/bind/bind-ack/switch/switch-ack flow. Post-switch failure falls back via secure RESUME to another transport. |
| DATA/API size contradiction | Valid major | 1 MiB is now application-message max, while each LPC frame plaintext is max 16,384 bytes. |
| Keepalive interval could exceed dead timeout | Valid major | Dead timeout is derived as max(6000, 3 x negotiated interval) and is not independently configurable. |
| ACK retry missing | Valid major | 3 s ACK timeout, exactly 2 retransmissions, same MessageId/new wire sequences, 16,384-entry completed-ID dedup set. |
| SessionId contradictory | Valid major | SessionId is now deterministically derived for initial handshake and explicitly preserved across RESUME. No random SessionId rule remains. |
| Minor-version negotiation missing | Valid major | HELLO carries min/max minor; highest common minor is selected. |
| Capability bitmap definitions conflicted | Valid major | `PeerCapabilityBitmap` wire format and `LocalRuntimeCapabilityBitmap` API-only format are now distinct. |
| API ownership/lifecycle incomplete | Valid medium | Runtime/HostSession/DiscoverySession/ConnectionAttempt/PeerConnection ownership, cascade closure, idempotence, and terminal behavior are explicitly specified. |
| Explicit host/client UX creates friction and host failure ends topology | Valid design limitation | Added symmetric `joinOrCreateGroup`, deterministic automatic coordinator election, group merge, coordinator heartbeat, migration, and optional replicated coordinator checkpoint. |
| Protocol minor contradictory | Valid | Section 4 now distinguishes current spec minor from the supported minor range; minor is negotiated rather than treated as a protocol-major constant. |
| UDP shares reliable sequence/key space | Valid blocker | UDP is now an independent `LPU1` sidecar with directional UDP keys, uint64 UDP packet sequences, and a separate 256-packet replay window. |
| 1200-byte realtime payload exceeds 1232-byte UDP packet | Valid blocker | Universal realtime application maximum reduced to 1100 bytes; full UDP packet is 1176 bytes. |
| UDP binding/establishment underspecified | Valid blocker | Added UDP_OFFER, UDP_ACCEPT, encrypted UDP_PROBE/ACK, UDP_CLOSE, key derivation, endpoint binding, activation, failure, and re-establishment. |
| Losing group membership unavailable | Valid | GROUP_INFO now carries the complete sorted committed PeerId list plus verified hash. |
| Split-brain membership reconciliation missing | Valid | Same-GroupId divergent views reconcile at a new term using both authenticated snapshots plus reachable members. |
| maxPeers absent from merge semantics | Valid | Effective capacity is the minimum maxPeers across candidate members; over-capacity merges are rejected without arbitrary member selection. |
| SAS conflicts with frictionless GroupSession | Valid product conflict | GroupSession now defaults to encrypted OPEN_TOFU; stronger GROUP_PSK_32, PAIRWISE_SAS, and KNOWN_PEERS are explicit options. |
| Empty namespace can merge unrelated games | Valid | Replaced with mandatory applicationNamespace plus default TOKEN_SCOPED 16-byte groupJoinToken; OPEN_PROXIMITY is explicit opt-in. |
| GroupTrustMode not mapped to pairwise HELLO trust mode | Valid blocker | Added an exact mapping table; RuntimeConfig.trustMode is ignored for GroupSession-internal PeerConnections. |
| effective_max_peers cannot be computed from GROUP_INFO | Valid blocker | Introduced canonical 18-byte GroupMemberRecord containing PeerId + max_peers and use it in GROUP_INFO, MEMBERSHIP_SNAPSHOT, GROUP_MERGE, reconciliation, and membership hashing. |
| Simultaneous UDP_OFFER collision | Valid | Only the lexicographically smaller PeerId may automatically initiate the UDP sidecar. |
| UDP replay-window initialization/wrap unspecified | Valid | First authenticated sequence initializes the window; sequence 0 is invalid; uint64 sequence must never wrap/reuse under one sidecar key. |
| Unexpected UDP source could fail whole peer | Valid operational issue | It now invalidates/rebuilds only the UDP sidecar while the reliable PeerConnection remains READY. |
| GROUP_MERGE_REJECT sender ambiguous | Valid | Merge rank is computed before capacity; only the would-be winning coordinator sends rejection. |
| groupJoinToken could be mistaken for a secret | Valid documentation/security issue | Explicitly defined as merge scoping only, never authentication. |
| Group trust mode absent from GROUP_INFO | Valid | GROUP_INFO now carries group_trust_mode and KNOWN_PEERS merge policy; differing trust modes never auto-merge. |
| Protocol 1.1 test vectors incomplete | Valid | Added mandatory minor-1 group/realtime/UDP binary test vectors including GroupMemberRecord membership hashes. |
| KNOWN_PEERS conflicts with exact expectedPeerId KNOWN_PEER | Valid blocker | KNOWN_PEER now has exact `EXPECT_EXACT_PEER` and `ALLOWLIST` policies; GroupSession KNOWN_PEERS normatively uses ALLOWLIST. |
| ACK-required special control frames underspecified | Valid blocker | Added frame-header ACK_REQUIRED bit and one generic MessageId/ACK/retry/dedup/RESUME mechanism for RELIABLE_ACKED DATA plus MEMBERSHIP_SNAPSHOT, GROUP_MERGE, COORDINATOR_CHECKPOINT, and GROUP_LEAVE. |
| group.leave and membership removal underspecified | Valid blocker | Added GROUP_LEAVE 0x23 with exact normal leave, coordinator resign, kick, abrupt disappearance, snapshot, and term behavior. |
| conflicting max_peers during split-brain | Valid | Same-PeerId conflicting records reconcile to the minimum max_peers until clean leave/rejoin. |
| stale AUTH HMAC vector wording | Valid editorial/protocol-vector issue | Replaced with Ed25519 AUTH signature vector. |
| duplicate coordinator topology heading | Valid editorial issue | Removed duplicate and normalized subsection numbering. |
| normative summary missing protocol 1.1 constructs | Valid | Expanded summary to include GroupMemberRecord, trust mapping/scoping, group frames, generic ACK_REQUIRED, and LPU1/UDP rules. |
| COORDINATOR_CHECKPOINT exceeds control-frame limit | Valid blocker | Checkpoints now use <=4000-byte chunks inside <=4032-byte plaintext control frames; all chunks share one MessageId and receive one ACK only after full reassembly/commit. |
| MessageId counter has off-by-one ambiguity | Valid | Replaced with `next_message_counter=1`; allocation uses the current value then increments. |
| ACK-timeout control recovery unspecified | Valid | Added an exact recovery table for MEMBERSHIP_SNAPSHOT, GROUP_MERGE, COORDINATOR_CHECKPOINT, and each GROUP_LEAVE role. |
| New ACK/control vectors incomplete | Valid | Added ACK_REQUIRED, membership duplicate/ACK, GROUP_LEAVE, ALLOWLIST, and checkpoint chunk/retransmission vectors and tests. |
| ACK timeout start time undefined | Valid blocker | ACK timer now starts only after every frame/chunk in the current attempt reaches SENT_TO_TRANSPORT; transmission duration itself cannot trigger timeout. |
| Section 6 MessageId wording stale | Valid normative inconsistency | MessageId now explicitly covers reliable application messages and ACK-required logical control operations. |
| RESUME preservation list stale | Valid normative inconsistency | Section 26 now preserves all unacknowledged ACK_REQUIRED logical operations and explicitly discards incomplete checkpoint reassembly on transport loss. |
| SENT_TO_TRANSPORT ambiguous for GATT fragmentation | Valid freeze blocker | SENT_TO_TRANSPORT now occurs only after all transport-specific bytes/fragments for the LPC frame are submitted to the underlying platform API; backend/internal queues do not count. Added TransportWrite completion contract. |
| Section 26.6 application-message-only wording stale | Valid normative inconsistency | RESUME delivery/retransmission subsection now covers every unacknowledged ACK_REQUIRED logical operation and separately states exactly-once application-delivery vs control-state idempotence. |
| TransportWrite.FAILED core behavior undefined | Valid state-machine blocker | Terminal submission failure now invalidates the physical transport, fails all pending writes, forbids further same-generation sends, and enters normal RECONNECTING/RESUME recovery. |
| Backpressure vs FAILED ambiguous | Valid | Transient not-writable conditions keep TransportWrite PENDING and resume on Writable; FAILED is terminal only. |
| Partially transmitted RELIABLE_ORDERED undefined | Valid | Incomplete DATA reassembly is discarded on generation loss; partially submitted RELIABLE_ORDERED retransmits the entire message from chunk 0 after RESUME with same MessageId. |
| SendHandle SENT_TO_TRANSPORT scope ambiguous | Valid | SendHandle-level SENT_TO_TRANSPORT now occurs only after every constituent DATA frame reaches frame-level SENT_TO_TRANSPORT. |
| GroupId merge winner contradiction between Sections 10 and 31 | Valid interoperability blocker | Section 10 now delegates to GroupMergeRank: larger committed group wins, equal sizes use lexicographically smaller GroupId. |
| Plaintext PROTOCOL_MISMATCH ERROR contradicted plaintext-frame rule | Valid interoperability blocker | Added exact pre-key plaintext ERROR exception, wire fields, permitted state, and mandatory close behavior. |
| Protocol minor 0 compatibility undefined | Valid blocker if minor 0 were claimed | Backward compatibility was intentionally removed. This spec now advertises/supports only major 1 minor 1; minor 0 DATA/control/capability semantics are explicitly undefined and unsupported. |
| Coordinator checkpoint queueing underspecified | Valid freeze-level behavior gap | Checkpoint replication now has exactly one in-flight and one replaceable pending checkpoint per target peer; pending replacement allocates no MessageId/sequence and cannot cancel in-flight delivery. |
| Checkpoint publish still implied one global MessageId/checkpoint_sequence | Valid normative inconsistency | Checkpoint logical operation identity is now explicitly per target peer and allocated only when that peer promotes the checkpoint to in-flight transmission. |
| Pre-key ERROR exact field names stale | Valid editorial/normative precision issue | Replaced `nonce_suffix` with header field `nonce` and `payload_length` with `encrypted_payload_length`, explicitly noting plaintext payload sizing. |
| Section 61 major-version freeze wording conflicted with future minor negotiation | Valid conceptual inconsistency | Minor 1 semantics are fixed forever; future major-1 minors may add negotiated backward-compatible extensions; incompatible changes require a new major. |
| Section 11 stale v1.0 negotiation wording | Valid editorial inconsistency | Reworded to initial LPC protocol negotiation and protocol-major-1 BLE Baseline Conformance. |
| Full V1 Mobile Conformance too loose/stale | Valid | Renamed Full V1.1 Mobile Conformance and explicitly requires minor 1, GroupSession/AUTO_GROUP, coordinator behavior, all three delivery modes, Android+iOS, diagnostics, and mandatory tests. |
| Same-term membership snapshot stale overwrite risk | Valid adversarial validation concern | Added deterministic same-coordinator/same-term ordering using retained MessageId allocation order, stale-snapshot suppression, and RESUME regression tests without adding membership_revision. |
| Snapshot ordering lacked SessionId scope | Valid normative ambiguity | MembershipSnapshotOrderState now includes coordinator PeerId, term, SessionId, sender prefix, and greatest accepted counter. New SessionId establishes a fresh baseline even if counter decreases or prefix bytes collide. |
| GroupSession routing undefined in coordinator star | Valid freeze blocker | Added normative coordinator relay with GROUP_RELIABLE/GROUP_REALTIME, stable GroupMessageId, per-hop MessageIds, destination-level GROUP_DELIVERY_ACK, relay status, deduplication, migration, and source preservation. |
| BroadcastHandle semantics undefined | Valid API gap | Defined immutable target snapshot, per-peer handles/results, ACTIVE/COMPLETED/CANCELLED states, local-peer exclusion, and non-atomic partial-success semantics. |
| Group event payloads undefined | Valid API gap | Defined exact payload structures and common eventSequence metadata for every public GroupSession event. |
| Event ordering undefined | Valid API/concurrency gap | Added one logical per-object event dispatcher in protocol-state commit order, with getters updated before events. |
| Public concurrency/thread-safety undefined | Valid API gap | All public methods are thread-safe with per-object serialized mutation; callbacks are non-concurrent and reentrant calls are permitted. |
| RELIABLE_ORDERED name may imply guaranteed delivery | Valid documentation risk | API docs now prominently define RELIABLE_ORDERED as ordered transport-submitted and RELIABLE_ACKED as destination-recipient-confirmed. |
| Group-wide ordering/broadcast atomicity unspecified | Valid semantic gap | Explicitly no total order across different sources and no atomic broadcast; each destination is independent. |
| TOKEN_SCOPED default UX unclear | Valid documentation gap | Added concrete OPEN_PROXIMITY game and TOKEN_SCOPED room/whiteboard/messaging examples. |
| Security mode guidance by application type | Valid guidance improvement | Added use-case trust profiles and clarified coordinator relay is hop-by-hop, not member-to-member end-to-end encrypted. |
| Section 26.6 stale after group-routing additions | Valid freeze blocker | RESUME Message Recovery now exhaustively includes GROUP_RELIABLE, GROUP_DELIVERY_ACK, and GROUP_RELAY_STATUS for protocol minor 1. |
| Group-routing binary vectors missing | Valid interoperability blocker | Added mandatory byte-for-byte GroupMessageId, GROUP_RELIABLE, GROUP_REALTIME_DATAGRAM, GROUP_DELIVERY_ACK, all GROUP_RELAY_STATUS variants, two-hop relay, and destination-duplicate vectors. |
| Coordinator relay admission boundary ambiguous | Valid normative gap | Coordinator now atomically admits/reserves the complete destination relay operation; on route/queue rejection it ACKs the fully received source hop, retains no relay state, and reports failure with GROUP_RELAY_STATUS. |
| Normative Summary stale after routing additions | Valid normative consistency issue | Section 61 now explicitly lists GroupMessageId, all four routing frame types, relay semantics, broadcast handles, event serialization, and concurrency/reentrancy rules. |
| GROUP_RELIABLE partial-hop transport loss undefined | Valid freeze blocker | Added generation-loss discard/reassembly rules and whole-hop retransmission from chunk 0 for both RELIABLE_ORDERED and RELIABLE_ACKED, including coordinator->destination partial relay recovery while source->coordinator remains healthy. |
| Final coordinator-to-destination hop wording too narrow | Valid precision issue | Replaced with `final end-destination hop` and defined all three source/destination topology cases. |
| GroupMessageId dedup lifetime caveat insufficiently prominent | Valid reliability/documentation issue | Section 43 now states exactly-once GroupSession RELIABLE_ACKED delivery is guaranteed only while the completed source/GroupMessageId remains in the 16,384-entry destination dedup window; post-eviction replay may redeliver. |
| Routed-send cancellation semantics undefined | Valid API/normative gap | SendHandle.cancel is now explicitly local best-effort only; no minor-1 remote revocation exists, cancelled sends stop source retry/reroute, and admitted coordinator relays may still complete. |
| Late route signaling after cancellation ambiguous | Valid protocol-race gap | Added bounded cancellation tombstones so late GROUP_DELIVERY_ACK/GROUP_RELAY_STATUS is authenticated and ACKed normally while cancelled public handles remain terminal. |
| Membership removal during admitted relay ambiguous | Valid routing gap | Committed destination removal now terminates nonterminal queued/admitted relays that have not already completed destination delivery and reports DESTINATION_NOT_IN_GROUP when possible. |
| Cancellation tombstone retention used later-of instead of earlier-of | Valid normative bug | Tombstones now release at the earlier of GroupSession close or termination of every SessionId capable of valid late signaling. |
| Former-coordinator late route signaling race undefined | Valid edge-case precision issue | Added stale-authority signaling rules: only already-in-flight controls on the historically valid SessionId may be ACKed/discarded for cancelled tombstones; they can never affect send state or grant ongoing authority. |
| GroupMessageId dedup cache scope implicit | Valid implementation-precision issue | Defined one shared 16,384-entry completed GroupMessageId cache per destination GroupSession across all source PeerIds. |
| Already-admitted relay behavior on coordinator authority loss undefined | Valid routing/state-machine gap | Former coordinator now immediately terminates unfinished admitted relays, stops future application-frame submission, releases reservations, and transfers no pairwise relay identity/responsibility. Source reroutes through the new coordinator with the same GroupMessageId. |
| Non-authoritative/stale coordinator handling referenced but undefined | Valid normative gap | Added unified stale former-coordinator handling for already-in-flight GROUP_DELIVERY_ACK, GROUP_RELAY_STATUS, GROUP_RELIABLE, and GROUP_REALTIME_DATAGRAM with historical SessionId/authority checks and deterministic ACK/discard behavior. |





| All application traffic effectively reliable/ordered | Valid game-latency limitation | Added `REALTIME_LATEST` datagrams with no LPC ACK/retry, latest-only queue replacement, stale-sequence dropping, 100 ms default expiry, and optional authenticated LAN UDP. |


---

# 61. Normative Summary


For protocol major 1, the following are fixed and MUST match across implementations:

- iOS-compatible service-UUID-only BLE discovery advertisement;
- wire identifier sizes and opaque local DiscoveryEndpointId semantics;
- GATT UUID behavior;
- fragmentation header;
- LPC frame header;
- frame type numeric values;
- big-endian integer encoding;
- Ed25519 persistent identity signatures;
- X25519 ephemeral key agreement;
- SHA-256;
- HKDF-SHA256;
- ChaCha20-Poly1305;
- explicit KNOWN_PEER/SAS/PSK_32/TOFU trust semantics;
- handshake transcript ordering;
- SessionId derivation;
- AEAD nonce construction;
- sequence rules;
- minor-version negotiation;
- application-message chunking;
- reconnect timing defaults;
- fully specified RESUME candidate keys, proofs, root rotation, generation, and sequence reset;
- transport generation and generation-specific traffic keys;
- complete upgrade offer/accept/bind/switch/fallback behavior;
- state transitions;
- error codes;
- queue defaults;
- automatic GroupSession coordinator election and migration;
- coordinator rank, heartbeat, membership, election, split-brain, and merge behavior;
- RELIABLE_ORDERED / RELIABLE_ACKED / REALTIME_LATEST delivery modes;
- REALTIME_DATAGRAM format and latest-only queue semantics;
- coordinator control frame numeric values 0x16 through 0x1A;
- REALTIME_DATAGRAM frame value 0x1B;
- protocol-minor-1 PeerCapabilityBitmap bits 6 through 8;
- optional authenticated Wi-Fi UDP realtime path;
- canonical 18-byte GroupMemberRecord encoding;
- canonical committed membership hash construction including max_peers;
- GroupTrustMode values and exact mapping to pairwise HELLO trust_mode/KnownPeerPolicy;
- applicationNamespace and groupJoinToken scoping rules;
- group trust compatibility and KNOWN_PEERS auto-merge rules;
- GROUP_INFO format and full committed GroupMemberRecord list;
- GROUP_MERGE and GROUP_MERGE_REJECT semantics;
- GROUP_LEAVE semantics and committed membership removal rules;
- generic ACK_REQUIRED flag and ACK/retry/dedup/RESUME behavior for critical control frames;
- coordinator checkpoint chunking with a 4000-byte checkpoint-data maximum per control frame and one MessageId per per-target logical checkpoint operation;
- MessageId `next_message_counter` initialization, allocation, and exhaustion behavior;
- exact frame-specific final ACK-timeout recovery and per-peer GroupSyncState;
- exact ACK timer start semantics based on final frame/chunk reaching SENT_TO_TRANSPORT;
- SENT_TO_TRANSPORT backend-acceptance definition;
- RESUME preservation of all ACK_REQUIRED logical operations;
- mandatory discard of incomplete checkpoint reassembly on transport loss;
- transport-specific SENT_TO_TRANSPORT boundary after final GATT fragment/all stream bytes are submitted to the platform API;
- backend TransportWrite completion semantics;
- terminal TransportWrite failure semantics and transient-backpressure distinction;
- failed-generation prohibition on further LPC submission;
- discard of incomplete DATA reassembly on transport-generation loss;
- RELIABLE_ORDERED whole-message retransmission after partial submission;
- logical SendHandle-level vs frame-level SENT_TO_TRANSPORT semantics;
- GroupMergeRank-derived surviving GroupId selection;
- exact pre-key plaintext ERROR(PROTOCOL_MISMATCH) wire format and permitted state;
- RESUME retransmission/idempotence semantics for all ACK_REQUIRED control operations;
- LPU1 UDP packet format;
- UDP sidecar key derivation, independent replay sequence space, replay-window initialization, and endpoint-change behavior;
- 16-byte GroupMessageId allocation and end-destination deduplication;
- bounded 16,384-entry GroupMessageId duplicate-suppression window and exactly-once-within-retention semantics;
- GROUP_RELIABLE frame 0x24 and its 84-byte group-routing header/chunking rules;
- GROUP_REALTIME_DATAGRAM frame 0x25 and hop-relay/UDP-sidecar semantics;
- GROUP_DELIVERY_ACK frame 0x26 and destination-level RELIABLE_ACKED completion semantics;
- GROUP_RELAY_STATUS frame 0x27 and exact status/error mappings;
- coordinator-relayed GroupSession routing and per-source/destination ordering;
- relay-admission atomic reservation and queue-full source-hop ACK/status behavior;
- GROUP_RELIABLE partial-hop transport-generation-loss recovery, incomplete-reassembly discard, and whole-hop retransmission rules;
- final end-destination-hop SendHandle completion semantics;
- BroadcastHandle and RealtimeBroadcastHandle immutable target snapshots, per-peer results, and terminal-state aggregation;
- exact GroupSession event payloads and GroupEventHeader/eventSequence semantics;
- per-object event serialization, thread safety, and callback reentrancy contract;
- explicit absence of cross-source total ordering and atomic broadcast;
- local best-effort reliable-send cancellation semantics without remote revocation;
- CancelledGroupSendTombstone handling for valid late route signaling;
- earlier-of cancellation-tombstone release rule based on GroupSession close or termination of all signaling-capable SessionIds;
- stale-authority handling for already-in-flight former-coordinator route signaling;
- coordinator-authority-loss termination of unfinished admitted relays and source reroute ownership;
- stale former-coordinator GROUP_RELIABLE and GROUP_REALTIME_DATAGRAM race handling;
- one shared 16,384-entry completed GroupMessageId dedup cache per destination GroupSession across all sources;
- termination of nonterminal admitted relays when destination membership removal commits;
- API semantics.

For negotiated protocol minor 1, the rules above are fixed and MUST match across conforming implementations.

A future protocol-major-1 minor version MAY add backward-compatible wire or semantic extensions when those extensions are governed by minor-version negotiation.

A change that is incompatible with the already-defined semantics of an existing negotiated minor requires a new protocol major.

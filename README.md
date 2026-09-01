# local_peer_connections

`local_peer_connections` is an open-source, cross-platform proximity networking library for offline local multiplayer, collaboration, messaging, and nearby device-to-device applications.

It targets Android and iOS first, uses BLE as the baseline transport, and is designed so applications do not manually choose host/client roles.

## Status

This repository now contains an installable Flutter plugin scaffold and a
portable Dart foundation for configuration validation, LPC frame encoding,
GATT fragment envelopes, identity-derived PeerIds, serialized GroupSession
state/event handling, authenticated handshake and RESUME primitives, and unit
tests. It is **not yet a Full V1.1 Mobile Conformance implementation**:
native BLE GATT service/client I/O, automatic connection/reconnect and RESUME
orchestration, discovery-driven formation/election/migration, end-to-end
routed delivery, optional transport upgrades, and the mandatory full
conformance suite are still required before that claim can be made.

### Implementation checklist

Implemented:

- [x] Flutter package metadata and Android/iOS plugin registration shells
- [x] Protocol constants, fixed frame header, frame-type registry, and bounds checks
- [x] PeerId derivation from an Ed25519 public key
- [x] GATT fragment envelope parsing/serialization with START/END flags, per-frame uint32 sequences, bounded payloads, and expiry-aware reassembly
- [x] Group/runtime configuration validation, including SAS-by-default low-level trust, PSK_32 and KNOWN_PEER credential validation
- [x] Runtime transport enablement flags enforced at public GATT discovery, host, and connection entry points
- [x] Serialized GroupSession snapshots, deterministic broadcast target snapshots, and event dispatch foundation
- [x] BroadcastHandle and RealtimeBroadcastHandle aggregate lifecycle state, completion, and local cancellation
- [x] Serialized GroupSession callbacks with reentrant public-method command queuing
- [x] DATA/realtime payload codecs, reliable DATA chunking, MessageId allocation, and bounded dedup primitives
- [x] DATA reassembly, generation-loss discard, and realtime uint32 sequence filtering
- [x] ChaCha20-Poly1305 frame protection, Section 17 AAD/nonce layout, and traffic-key derivation
- [x] HELLO/AUTH plaintext frame envelopes, HELLO codec (including negotiated keepalive input), transcript/base-root/session derivation, and SAS formatting primitives
- [x] Serialized HELLO/AUTH handshake controller with version-mismatch close and explicit SAS confirmation gate
- [x] Runtime/HostSession SAS verification events and explicit confirmation APIs, with the required 30-second authentication timeout and runtime-scoped TOFU continuity
- [x] X25519 shared-secret, Ed25519 AUTH signing/verification, and in-memory TOFU continuity helper
- [x] Android/iOS protected persistent Ed25519 key-storage adapter (Android Keystore-encrypted seed; iOS device-only Keychain seed)
- [x] READY agreement validation, exact pre-key `ERROR(PROTOCOL_MISMATCH)` codec, and encrypted-generation receive-sequence window
- [x] Backend-driven portable HELLO/AUTH/READY PeerConnection lifecycle with encrypted READY gating and sequence-2 handoff to the authenticated core
- [x] Fresh candidate-only HELLO/AUTH mode for Section 26 reconnects; it exposes the authenticated candidate transcript/secrets without emitting normal READY
- [x] Android/iOS service-UUID-only BLE advertising/scanning bridge with platform endpoint events and stable error mapping
- [x] Android/iOS Section 11 GATT service host with canonical RX/TX/CONTROL UUID derivation
- [x] Android/iOS GATT client connection and Section 11 service/characteristic discovery validation
- [x] Portable GATT BackendConnection adapter with bounded fragmentation queues, backpressure retention, final-fragment completion, and terminal-failure fanout
- [x] Generic ACK payload, bounded ACK-required retention/deadlines, ACK correlation, and RESUME retry eligibility
- [x] Deterministic coordinator rank and canonical committed-membership snapshot codec
- [x] SessionId-scoped same-term membership-snapshot ordering and stale rollback suppression
- [x] Election announcement/resignation codecs and deterministic candidate selection
- [x] Section 10.9 timed election controller (announcement, claim, quiet period, and heartbeat cadence)
- [x] Deterministic group-merge compatibility, winner, and capacity evaluation
- [x] GROUP_INFO codec with canonical membership and trust-mode validation
- [x] GROUP_MERGE and GROUP_MERGE_REJECT codecs with merged-capacity validation
- [x] COORDINATOR_HEARTBEAT codec, 1s/3s liveness timing, and submission-aware periodic broadcaster
- [x] GROUP_RELIABLE codec/chunking with stable end-destination IDs
- [x] GROUP_RELIABLE authenticated-hop reassembly, collision detection, expiry, and generation-loss discard
- [x] GROUP_DELIVERY_ACK and GROUP_RELAY_STATUS codecs with exact public error mapping
- [x] Bounded coordinator relay admission/reservation state with exact route-failure outcomes and authority-loss/target-removal cleanup
- [x] Source-side routed-send state: destination ACK completion, ordered final-hop completion, terminal relay failure, cancellation, and reroute retention
- [x] Coordinator relay transition/actions for generic hop ACKs, local delivery, final-hop completion, authoritative route signaling, target removal, and authority loss
- [x] Authenticated group-route validation for committed membership, coordinator authority, active GroupId aliases, and canonical forwarding
- [x] Stale former-coordinator classifier for historical ACK/status, reliable, and realtime migration races
- [x] Transport-agnostic coordinator routing core composing authenticated ingress, relay admission, realtime coalescing, and cleanup
- [x] Per-source/destination reliable relay ordering with next-operation promotion only after terminal final-hop result
- [x] Bounded cancelled-send tombstones that authenticate, ACK, and discard valid late relay signaling without reviving cancellation
- [x] Retained admitted final-hop relays across destination RESUME, with whole-operation retry actions and terminal unavailable cleanup
- [x] Former-coordinator route-signaling classification that ACKs/discards only proven historical traffic and leaves current sends unchanged
- [x] Destination-side stale-authority reliable/realtime discard paths, with ACK eligibility only for complete ACK-required historical hops
- [x] Serialized `RealtimeDatagramReceived` delivery with source/channel latest-state suppression
- [x] Serialized `ReliableMessageReceived` delivery with bounded GroupMessageId duplicate suppression
- [x] Group membership and coordinator getters commit before their corresponding callbacks
- [x] Relayed reliable operations retain one GroupMessageId while using distinct source/destination hop MessageIds
- [x] Destination duplicate suppression remains ACK-eligible; every relay-status value has its exact public error mapping
- [x] Unavailable committed destinations fail new reliable relays immediately and drop routed realtime state
- [x] Queue-full relay admission ACKs a complete source hop exactly once, retains no relay, and reports `RELAY_QUEUE_FULL`
- [x] Successful relay admission atomically reserves the complete destination-hop byte/message budget before source-hop ACK
- [x] Transport-agnostic member routing core for authenticated coordinator signaling, public completion, cancellation, and reroute retention
- [x] Transport-agnostic destination routing core for final-hop validation, shared reliable deduplication, duplicate ACK eligibility, and per-source realtime suppression
- [x] GROUP_REALTIME_DATAGRAM codec and per-destination/channel non-wrapping sequences
- [x] Bounded coordinator realtime pending state with per-route latest-value coalescing and authority-loss/target-removal discard
- [x] GroupSession-scoped 16-byte GroupMessageId allocator
- [x] Bounded shared destination GroupMessageId deduplication
- [x] Bounded cancellation tombstones for valid late route signaling
- [x] COORDINATOR_CHECKPOINT codec and protocol-limit chunking
- [x] Per-target bounded checkpoint replication queue with latest-pending coalescing
- [x] Coordinator-wide latest checkpoint retention with independent READY-peer replication promotion
- [x] Checkpoint reassembly, collision detection, expiry, and generation-loss discard
- [x] Exact PeerConnection lifecycle transition guard
- [x] Portable backend connection/write-completion contract
- [x] Runtime ownership and idempotent cascade-close of connection attempts and authenticated PeerConnections
- [x] Public PeerConnection identity/session diagnostics, authenticated security level, active transport, direct reliable send, latest-only realtime send/receive streams, and disconnect lifecycle
- [x] PeerConnection lifecycle event stream for committed reconnecting, reconnected, and disconnected transitions
- [x] Authenticated DATA framing/commit boundary before application callbacks, with terminal malformed-frame handling
- [x] Explicit HostSession authenticated-peer snapshot and direct unicast/broadcast send entry points
- [x] Authenticated PeerConnection frame submission through backend completion and generation-wide terminal-write failure handling
- [x] Bounded per-peer scheduler with realtime coalescing, expiry removal, and fairness
- [x] Keepalive timing negotiation, exact PING/PONG payload, authenticated liveness bookkeeping, deterministic pending-PING controller, and automatic live-connection PING/PONG/dead-time polling
- [x] Backend-bound candidate RESUME request/accept/reject exchange with generation-0 candidate encryption, resumed-root rotation, and bidirectional RESUME_READY gating
- [x] Deterministic Section 25 reconnect-attempt backoff/timeout schedule primitive
- [x] Section 28 UPGRADE_OFFER/ACCEPT/REJECT, candidate BIND/ACK, and SWITCH payload codecs; binding-proof verification; and failure-phase lifecycle guard
- [x] Section 29 TCP endpoint and Section 30 L2CAP PSM upgrade-data codecs
- [x] Section 22.4 UDP sidecar offer/accept/close codecs and directional key derivation
- [x] Section 22.4 LPU1 encrypted packet codec, independent UDP sequence allocator, 256-packet replay window, and probe activation controller
- [x] Binary vector for HELLO keepalive negotiation and unit tests for implemented binary/layout and lifecycle rules
- [x] Native BLE GATT client I/O, Dart fragment binding, and permission-request UX

Not implemented yet (and therefore not claimable as V1.1 conformance):

- [ ] Complete reconnect and RESUME lifecycle (outbound GATT reconnect now uses the Section 25 schedule, fresh KNOWN_PEER candidate handshake, candidate RESUME, core rebind, and direct-operation recovery; inbound candidate-session matching and group-operation recovery remain)
- [ ] Automatic discovery-driven formation, timed election, merge application, and coordinator migration
- [ ] End-to-end GroupSession/PeerConnection routing: live authenticated frame dispatch, hop ACK emission, scheduler submission, relay signaling, and automatic reroute after RESUME or coordinator migration
- [ ] L2CAP, LAN TCP, and authenticated UDP sidecar upgrades
- [ ] Remaining mandatory binary vectors and the full mandatory unit/integration test suite

Wire baseline:

```text
protocol major 1
protocol minor 1
```

The canonical protocol definition is:

```text
local_peer_connections_spec.md
```

That file is the source of truth for wire formats, state machines, timing, routing, security, recovery, conformance, and test requirements.

## Platform permissions

The Android manifest declares `BLUETOOTH_SCAN` and `BLUETOOTH_ADVERTISE` on
Android 12+; the host application must request them at runtime before starting
discovery or advertising. On Android 6–11, scanning additionally requires
runtime location permission. iOS hosts must provide an appropriate Bluetooth
usage-description string in their application `Info.plist`. A denied or
powered-off Bluetooth state is returned as the matching stable LPC error.

The current native bridge advertises and scans by service UUID only. Its
platform endpoint IDs are transient discovery handles, never protocol PeerIds;
GATT transport remains unfinished.

## What the library provides

At a high level:

- nearby discovery without Internet access;
- Android ↔ iOS BLE interoperability;
- automatic group formation;
- automatic coordinator election and migration;
- coordinator-routed member-to-member messaging;
- reliable ordered messaging;
- destination-acknowledged reliable messaging;
- latest-state realtime messaging;
- reconnect and secure RESUME;
- optional coordinator state checkpoints;
- bounded queues and duplicate suppression;
- optional L2CAP and LAN transport upgrades;
- binding-independent core protocol with a Flutter-first API target.

Typical group size is small, usually 2 to 8 nearby devices.

## Example API

```text
runtime = createRuntime(config)

group = runtime.joinOrCreateGroup(groupConfig)

group.events().on(MemberJoined, ...)
group.events().on(ReliableMessageReceived, ...)
group.events().on(RealtimeDatagramReceived, ...)

group.send(peerId, bytes, deliveryMode=RELIABLE_ACKED)
group.broadcast(bytes, deliveryMode=RELIABLE_ORDERED)

group.sendRealtime(peerId, channelId=1, bytes=state)
group.broadcastRealtime(channelId=1, bytes=state)

group.leave()
runtime.close()
```

The coordinator is selected automatically. The application does not choose a networking host.

## Group model

A READY group normally forms a star:

```text
        Coordinator
        /    |    \
       B     C     D
```

A member can still call:

```text
group.send(peerId=C, ...)
```

even if it has no direct connection to C. The library routes the operation through the coordinator according to the protocol specification.

## Delivery modes

### `RELIABLE_ORDERED`

Ordered, transport-submitted delivery.

Use when application-level destination acknowledgment is not required.

### `RELIABLE_ACKED`

Destination-confirmed reliable delivery.

Use when the sender must know the destination accepted the operation.

Duplicate suppression is bounded, so this is not permanent mathematical exactly-once delivery.

### `REALTIME_LATEST`

Latest-state delivery with no LPC ACK or retransmission.

Useful for rapidly changing state such as movement, aim, cursor position, or current game state.

## Security

GroupSession supports:

```text
OPEN_TOFU
GROUP_PSK_32
PAIRWISE_SAS
KNOWN_PEERS
```

`OPEN_TOFU` is intended for low-friction casual use. Applications with stronger identity or privacy requirements should select an appropriate stronger mode.

`groupJoinToken` scopes group discovery/merging. It is not an authentication secret.

Coordinator-relayed traffic is encrypted on each hop. Applications requiring member-to-member end-to-end confidentiality should encrypt their payloads above LPC.

## Discovery modes

`TOKEN_SCOPED` is the default and is appropriate for lobbies, rooms, whiteboards, and messaging sessions.

`OPEN_PROXIMITY` is an explicit opt-in for experiences where all compatible nearby peers may discover and merge automatically.

## Transport support

Required baseline:

```text
BLE GATT
```

Optional upgrades:

```text
BLE L2CAP CoC
Wi-Fi LAN TCP
authenticated Wi-Fi UDP realtime sidecar
```

The protocol defines exact behavior for negotiation and fallback.

## Repository layout

A typical repository structure is:

```text
/spec
/core
/backends
/bindings
/tests
/examples
```

The exact structure may evolve, but protocol behavior must remain consistent with the canonical specification.

## Conformance and testing

Independent implementations are expected to pass the mandatory protocol tests and binary vectors defined in `local_peer_connections_spec.md`.

Wire-format behavior must reproduce the normative vectors byte-for-byte.

## Contributing

For protocol changes:

1. update `local_peer_connections_spec.md` first;
2. add or update the required tests and binary vectors;
3. search for stale contradictory wording;
4. preserve protocol-1.1 compatibility unless the change intentionally requires a new protocol version.

For implementation-only changes, do not alter externally observable protocol behavior.

See [`AGENTS.md`](./AGENTS.md) for repository instructions for human and AI coding agents.

## License

Add the selected project license here.

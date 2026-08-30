# local_peer_connections

`local_peer_connections` is an open-source, cross-platform proximity networking library for offline local multiplayer, collaboration, messaging, and nearby device-to-device applications.

It targets Android and iOS first, uses BLE as the baseline transport, and is designed so applications do not manually choose host/client roles.

## Status

This repository now contains an installable Flutter plugin scaffold and a
portable Dart foundation for configuration validation, LPC frame encoding,
GATT fragment envelopes, identity-derived PeerIds, serialized GroupSession
state/event handling, and unit tests. It is **not yet a Full V1.1 Mobile
Conformance implementation**: Android/iOS BLE scanning, GATT I/O, the
authenticated handshake, RESUME, coordinator formation/election, and routed
delivery are still required before that claim can be made.

### Implementation checklist

Implemented:

- [x] Flutter package metadata and Android/iOS plugin registration shells
- [x] Protocol constants, fixed frame header, frame-type registry, and bounds checks
- [x] PeerId derivation from an Ed25519 public key
- [x] GATT fragment envelope parsing/serialization with uint32 fragment sequences
- [x] Group/runtime configuration validation
- [x] Serialized GroupSession snapshots and event dispatch foundation
- [x] DATA/realtime payload codecs, reliable DATA chunking, MessageId allocation, and bounded dedup primitives
- [x] DATA reassembly, generation-loss discard, and realtime uint32 sequence filtering
- [x] ChaCha20-Poly1305 frame protection, Section 17 AAD/nonce layout, and traffic-key derivation
- [x] HELLO/AUTH plaintext frame envelopes, HELLO codec (including negotiated keepalive input), transcript/base-root/session derivation, and SAS formatting primitives
- [x] X25519 shared-secret, Ed25519 AUTH signing/verification, and in-memory TOFU continuity helper
- [x] READY agreement validation, exact pre-key `ERROR(PROTOCOL_MISMATCH)` codec, and encrypted-generation receive-sequence window
- [x] Generic ACK payload, bounded ACK-required retention/deadlines, ACK correlation, and RESUME retry eligibility
- [x] Deterministic coordinator rank and canonical committed-membership snapshot codec
- [x] Election announcement/resignation codecs and deterministic candidate selection
- [x] Deterministic group-merge compatibility, winner, and capacity evaluation
- [x] GROUP_INFO codec with canonical membership and trust-mode validation
- [x] GROUP_MERGE and GROUP_MERGE_REJECT codecs with merged-capacity validation
- [x] COORDINATOR_HEARTBEAT codec and 1s/3s liveness timing primitive
- [x] GROUP_RELIABLE codec/chunking with stable end-destination IDs
- [x] GROUP_DELIVERY_ACK and GROUP_RELAY_STATUS codecs with exact public error mapping
- [x] GROUP_REALTIME_DATAGRAM codec and per-destination/channel non-wrapping sequences
- [x] GroupSession-scoped 16-byte GroupMessageId allocator
- [x] Bounded shared destination GroupMessageId deduplication
- [x] Bounded cancellation tombstones for valid late route signaling
- [x] COORDINATOR_CHECKPOINT codec and protocol-limit chunking
- [x] Per-target bounded checkpoint replication queue with latest-pending coalescing
- [x] Checkpoint reassembly, collision detection, expiry, and generation-loss discard
- [x] Exact PeerConnection lifecycle transition guard
- [x] Portable backend connection/write-completion contract
- [x] Authenticated PeerConnection frame submission through backend completion and generation-wide terminal-write failure handling
- [x] Bounded per-peer scheduler with realtime coalescing, expiry removal, and fairness
- [x] Keepalive timing negotiation, exact PING/PONG payload, and timer-free liveness bookkeeping
- [x] RESUME request/accept proofs and payload codecs, resumed-root rotation, and RESUME_READY codec
- [x] Binary vector for HELLO keepalive negotiation and unit tests for implemented binary/layout and lifecycle rules

Not implemented yet (and therefore not claimable as V1.1 conformance):

- [ ] Android/iOS protected persistent Ed25519 key-storage adapter (portable IdentityStore integration is implemented)
- [ ] Backend-driven HELLO/AUTH/READY PeerConnection lifecycle (portable HELLO/AUTH verification and READY agreement validation are implemented)
- [ ] Android/iOS BLE advertising, scanning, GATT service, permission flow, and transport-write completion adapter
- [ ] Automatic PeerConnection timers/retransmission, reconnect orchestration, and complete RESUME lifecycle (state guard, retention, terminal transport-loss, and codec primitives are implemented)
- [ ] Automatic discovery-driven formation, timed election, merge application, and coordinator migration
- [ ] Routed relay state
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

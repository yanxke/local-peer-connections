# local_peer_connections

`local_peer_connections` is an open-source, cross-platform proximity networking library for offline local multiplayer, collaboration, messaging, and nearby device-to-device applications.

It targets Android and iOS first, uses BLE as the baseline transport, and is designed so applications do not manually choose host/client roles.

## Status

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

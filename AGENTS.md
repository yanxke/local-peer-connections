# AGENTS.md

This file contains repository instructions for human developers and AI coding agents working on `local_peer_connections`.

The canonical source of truth is:

```text
local_peer_connections_spec.md
```

If this file conflicts with the specification, **the specification wins**.

## Core rule

Do not invent protocol behavior.

Before implementing or changing anything involving:

- wire format;
- state transitions;
- coordinator behavior;
- routing;
- delivery semantics;
- reconnect/RESUME;
- cancellation;
- security;
- timing;
- queues;
- events;
- conformance;

find the relevant normative section in `local_peer_connections_spec.md` and implement it exactly.

If the spec is ambiguous and two implementations could reasonably diverge, stop and fix the specification instead of choosing an undocumented interpretation.

## Required workflow

For protocol-affecting work:

1. locate the relevant spec section;
2. identify the existing normative rule;
3. update the spec first if behavior must change;
4. update/add required unit tests;
5. update/add binary vectors if wire bytes change;
6. run structural validation on the spec;
7. search for stale contradictory wording;
8. verify test IDs remain unique;
9. verify explicit Section references still resolve.

For implementation-only work, do not modify protocol semantics.

## Do not invent alternatives

Unless the specification explicitly changes, do not:

- change frame layouts or numeric frame types;
- change identifier sizes;
- change endianness;
- substitute cryptographic primitives;
- change ACK or retry behavior;
- change chunking rules;
- change coordinator election or merge behavior;
- introduce mesh routing;
- introduce hidden unbounded queues;
- introduce permanent exactly-once guarantees;
- introduce global total ordering;
- introduce atomic broadcast semantics;
- require Bluetooth bonding;
- equate coordinator role with BLE Central/Peripheral role.

## GroupSession routing

Follow the routing model in the specification.

The public destination PeerId is the end application destination.

Do not create ad-hoc member-to-member links simply because `send(peerId, ...)` was called.

Do not bypass coordinator relay with an implementation-specific shortcut.

Keep hop-local pairwise `MessageId` separate from end-to-destination `GroupMessageId`.

## Delivery semantics

Do not reinterpret the delivery-mode names.

Use the specification definitions:

```text
RELIABLE_ORDERED
RELIABLE_ACKED
REALTIME_LATEST
```

In particular:

- a hop-local ACK must not become destination-level success;
- `CANCELLED` must not be treated as proof of remote non-delivery;
- bounded deduplication must not be described as permanent exactly-once delivery.

## Coordinator migration

When coordinator authority changes, follow the exact authority-loss, stale-former-coordinator, reroute, and dedup rules from the spec.

Do not allow an old coordinator to continue application routing just because it previously admitted a relay.

Do not treat historically valid race traffic as malicious unless the spec says to.

## Reconnect and partial transmission

Do not combine incomplete reassembly across transport generations.

Where the spec requires whole-operation recovery, retransmit from chunk 0.

Do not resume from an arbitrary middle chunk.

Do not change MessageId/GroupMessageId reuse rules.

## Cancellation

Implement cancellation exactly as specified.

Protocol 1.1 does not define remote routed-message revocation.

Do not invent a cancellation control frame.

Respect the cancellation tombstone rules for valid late route signaling.

## Membership

Committed membership is authoritative.

When a peer is removed, apply the exact relay-termination behavior from the spec.

Do not continue queued application traffic to a removed member.

## Events and concurrency

Preserve the spec's observable ordering model.

Do not emit an event before the associated state/getter mutation has committed.

Do not deliver callbacks for the same object concurrently when the spec requires serialization.

Public methods must follow the documented thread-safety and reentrancy contract.

## Memory bounds

All protocol queues and retention structures must remain bounded.

Never silently replace a required bound with an unbounded container.

On exhaustion, use the specified error behavior.

## Platform boundaries

Keep native platform details behind backend abstractions.

Core protocol code should not depend directly on Flutter, Android BluetoothGatt, or iOS CoreBluetooth types.

Backends translate platform events into the protocol-defined backend interface.

## Testing

Every normative behavior change needs test coverage.

Use existing test ID families and allocate the next unused ID:

```text
UT-xxx
COORD-xxx
RT-xxx
IT-xxx
```

Do not renumber existing IDs casually.

For wire changes, binary vectors are mandatory.

Independent implementations must reproduce normative vector bytes exactly.

## Spec validation checklist

Before finishing any spec edit, verify:

- top-level section numbering;
- H2/H3 numbering;
- no duplicate numbered headings;
- no broken `Section X` / `Section X.Y` references;
- no duplicate test IDs;
- no duplicate frame type numbers;
- frame-size arithmetic still fits protocol limits;
- normative summary reflects new frozen behavior;
- no stale wording contradicts newer sections.

## Security

Use only the cryptographic algorithms and trust semantics defined by the spec.

Do not log secrets.

Do not substitute platform Bluetooth identity for protocol identity.

Do not weaken authentication or silently downgrade trust.

## Scope discipline

`local_peer_connections` protocol 1.1 is not a general:

- consensus protocol;
- mesh network;
- distributed transaction system;
- permanent exactly-once queue;
- globally ordered event log;
- end-to-end encrypted group messenger by itself.

Do not add those semantics implicitly.

## When uncertain

If you cannot point to the normative rule that justifies an implementation choice, do not guess.

Check `local_peer_connections_spec.md`.

If the rule is missing, document the ambiguity and fix the specification first.

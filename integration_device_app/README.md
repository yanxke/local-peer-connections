# LPC integration device app

This is a small debug-only Flutter application for exercising the public LPC
API on real Android, iOS, and macOS devices. It contains no messenger concepts such as
friends, conversations, or application envelopes.

## Run on a device

From this directory:

```sh
flutter pub get
flutter run --debug -d <device-id> \
  --dart-define=LPC_TEST_NAME='Device A'
```

The app starts advertising and scanning automatically. The displayed
`PeerId`, endpoint identifiers, connection state, SessionId, transport, and
generation-related events are diagnostic values; private keys and payload
bytes are never included in logs.

The on-device status card and every runner JSON result include LPC telemetry:
total application messages/bytes sent and received, message and byte rates
over the most recent five seconds, and the percentage of measured connection
time spent connecting, reconnecting, or connected. Rates and counters include
direct, realtime, and group application traffic; a send is counted after LPC
reports transport delivery or a remote acknowledgement.

The default direct trust mode is TOFU. To exercise SAS confirmation, launch
both fixtures with `--dart-define=LPC_TEST_TRUST_MODE=sas`; the host runner
automatically accepts the displayed verification request for this test-only
fixture.

On Android the fixture requests the Bluetooth permissions required by the
platform before starting LPC. On iOS the Bluetooth usage descriptions are
included in the app and CoreBluetooth presents authorization as needed. The
macOS runner includes the App Sandbox Bluetooth entitlement and Bluetooth usage
descriptions; macOS may still show a system authorization prompt on first run.

To run the desktop fixture:

```sh
flutter run --debug -d macos \
  --dart-define=LPC_TEST_NAME='LPC Mac' \
  --dart-define=LPC_TEST_PORT=8765
```

The macOS control API is available directly at `http://127.0.0.1:8765`. For an
iOS device, forward its control port with `iproxy 18766 8765 <udid>`; both
fixtures then use the same HTTP commands and LPC automatically probes known
peers without an upper-layer reconnect direction.

## Control API

Debug builds bind only to `127.0.0.1` on port `8765` by default. The three
debug harnesses use separate loopback ports by default: LPC `8765`, LPM
`8766`, and LPGE `8767`. Override LPC with
`--dart-define=LPC_TEST_PORT=<port>` only for a custom deployment layout.

```text
GET  /health
GET  /snapshot
GET  /events?after=<sequence>
POST /command {"action": "...", "arguments": {...}}
```

Useful commands include:

```json
{"action":"startPresence"}
{"action":"connect","arguments":{"endpointId":"..."}}
{"action":"sendReliable","arguments":{"peerId":"...","text":"hello","deliveryMode":"reliableAcked"}}
{"action":"sendRealtime","arguments":{"peerId":"...","channelId":1,"text":"state"}}
{"action":"createGroup","arguments":{"namespace":[1,2,3],"token":[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]}}
{"action":"createCheckpointGroup"}
{"action":"sendGroup","arguments":{"peerId":"...","text":"group hello"}}
{"action":"publishCheckpoint","arguments":{"size":262144}}
{"action":"startCheckpointTest","arguments":{"checkpointSize":1024,"checkpointsPerSecond":1}}
{"action":"updateCheckpointTest","arguments":{"checkpointSize":2048,"checkpointsPerSecond":2}}
{"action":"stopCheckpointTest"}
{"action":"startSendTest","arguments":{"peerId":"...","messageSize":1024,"messagesPerSecond":2,"deliveryMode":"reliableAcked"}}
{"action":"updateSendTest","arguments":{"messageSize":2048,"messagesPerSecond":1}}
{"action":"stopSendTest"}
{"action":"startGroupSendTest","arguments":{"peerId":"...","messageSize":1024,"messagesPerSecond":2,"deliveryMode":"realtimeLatest"}}
{"action":"updateGroupSendTest","arguments":{"messageSize":2048,"messagesPerSecond":1}}
{"action":"stopGroupSendTest"}
{"action":"provisionKnownPeer","arguments":{"peerId":"<32-hex-peer-id>"}}
{"action":"removeKnownPeer","arguments":{"peerId":"<32-hex-peer-id>"}}
{"action":"clearKnownPeers"}
```

The fixture persists confirmed friend PeerIds and starts LPC with automatic
known-peer probing/reconnect enabled. Provision a PeerId from the other
device's `/snapshot` over the host's trusted USB/control connection (or use
the Remember button after an authenticated connection). BLE endpoint IDs are
ephemeral and are never persisted. Provisioning a PeerId does not by itself
trust an unauthenticated advertisement; LPC still authenticates the remote
identity before retaining the connection.

The UI exposes the same direct and group traffic controls with a message-size
slider at powers of two from 8 bytes through 64 KiB and a send-rate slider.
Each generated data packet carries an 8-byte fixture envelope;
the receiver sends a reliable application-level ACK for both reliable and
realtime traffic. The sender reports sent, ACKed, pending, timed-out, ACK,
and loss rates in the snapshot and UI. ACKs are diagnostic fixture traffic and
are not LPC protocol acknowledgements.

For the group traffic panel, tap **Create group** on both connected devices.
The panel lists a destination only after the AUTO_GROUP membership handshake
commits that peer; a direct LPC connection by itself is not yet a group route.

The **Coordinator checkpoint test** panel requires a checkpoint-enabled group;
tap **Create checkpoint group** on both devices when no group is active. Only
the elected LPC coordinator publishes. Its size slider covers 64 bytes through
64 KiB and its rate slider covers 1 through 20 publications/second. Slider
changes apply immediately to an active run without resetting its counters or
in-flight publication. The panel reports accepted and durable payload bytes,
durable payload bandwidth, failed-publication rate, pending publications, and
accepted-to-DURABLE latency (last/average/maximum). LPC accepts at most four
checkpoint publications per second; higher UI rates intentionally exercise
that bounded resource limit rather than silently queueing an unbounded stream;
admission failures are shown separately from failed accepted publications.
For a passing bandwidth/latency run, use 4 publications/second and hold each
size for five seconds. The test budget for a publication is
`ceil(checkpointSize / 200 B/s) + 2 seconds`; the two seconds cover checkpoint
ACK/validation overhead and are not a protocol timeout.

The native Android and iOS GATT bindings report their negotiated ATT payload
size to LPC (with a 20-byte minimum), so encrypted frames are not needlessly
fragmented into the legacy minimum-MTU size. The fixed-rate runner scenario
waits for persisted-friend auto-connect before starting traffic to avoid
overlapping manual and automatic GATT attempts.

For a USB-forwarded port, use `adb forward tcp:18765 tcp:8765` on Android or
`iproxy 18766 8765 <udid>` on iOS. The host-side runner can then use the same
HTTP API against each forwarded port.

To provision both fixtures with each other's current stable PeerId and let LPC
probe/reconnect automatically, add `--provision-known-peers` to a run:

```sh
python3 tool/device_integration_runner.py \
  --device android=18765 --device ios=18766 \
  --provision-known-peers --scenario IT-003 --timeout 60
```

## Automated physical scenarios

The stdlib-only runner keeps device labels generic and does not log payload
bytes or secrets:

~~~sh
python3 tool/device_integration_runner.py \
  --device device-a=18765 \
  --device device-b=18766 \
  --scenario IT-003 \
  --scenario IT-004 \
  --scenario IT-009 \
  --scenario IT-021 \
  --scenario IT-032 \
  --scenario IT-033 \
  --scenario IT-034 \
  --scenario IT-035 \
  --json-output artifacts/device-run.json
~~~

The runner fails fast when a device is not advertising/discoverable and
reports unsupported fault-injection scenarios as blocked; it never reports
those as passing. See [TODO.md](TODO.md) for the remaining scenarios.

`IT-040`, `IT-041`, and `IT-043` are bidirectional direct-message scenarios. `IT-042`
forms a two-device LPC group and sends reliable 64-byte group messages from
both members concurrently, verifying delivery and payload digests in both
directions. All three scenarios use bounded waits and report connection or ACK
failures separately from message assertions.

For star scenarios, make each --device label match the corresponding
fixture's normalized LPC_TEST_NAME, so the runner can select the intended
advertised endpoint.

To exercise the reliability boundary in both directions with small and
multi-chunk payloads (hard-capped at five minutes), run `IT-040`:

```sh
python3 tool/device_integration_runner.py \
  --device android=18765 --device ios=18766 \
  --scenario IT-040 --timeout 60
```

For a symmetric one-minute reliability run at a fixed rate, use `IT-041`:

```sh
python3 tool/device_integration_runner.py \
  --device android=18765 --device ios=18766 \
  --scenario IT-041 --timeout 60 \
  --json-output artifacts/it-041.json
```

It sends 64-byte `reliableAcked` packets at 5 packets/second from each device,
checks that both links remain ready, and requires every application-level ACK
to arrive before reporting a pass.

For the staged large-message/backpressure run, use `IT-043`:

```sh
python3 tool/device_integration_runner.py \
  --device android=18765 --device ios=18766 \
  --scenario IT-043 --timeout 60 \
  --json-output artifacts/it-043.json
```

It sends `reliableAcked` packets in both directions at 1 Hz for 5 seconds at
each size in `64, 128, 256, 512, 1024, 2048, 1024, 512, 256, 128, 64` bytes.
Each phase drains before the next begins. Its timeout budget is
`ceil(messageSize / 200 B/s) + 2 seconds`; the two seconds are an explicit
buffer for the expected minimum bandwidth, and the final 64-byte phase proves
that large-message backpressure did not strand the link.

For a concurrent two-device group-message smoke test, use `IT-042`:

```sh
python3 tool/device_integration_runner.py \
  --device android=18765 --device ios=18766 \
  --scenario IT-042 --timeout 60
```

It forms one committed group, sends one reliable 64-byte message from each
member at the same time, and verifies both `groupMessageReceived` events and
their payload digests.

For the coordinator checkpoint bandwidth/latency ramp, use `IT-044`:

```sh
python3 tool/device_integration_runner.py \
  --device device-a=18765 --device device-b=18766 \
  --scenario IT-044 --timeout 60 \
  --json-output artifacts/it-044.json
```

It creates a checkpoint-enabled two-device group and runs the elected
coordinator through `64, 128, 256, 512, 1024, 2048, 1024, 512, 256, 128, 64`
bytes at 4 publications/second for five seconds per phase. Each phase prints
durable payload bandwidth, accepted-to-DURABLE average/maximum latency, and
failed-publication rate. Every phase requires at least 200 B/s durable payload
bandwidth, less than 10% failed publications, and READY connections after the
bounded pending-publication drain.

See [TODO.md](TODO.md) for the conformance scenarios that still need
capability support, fault injection, or longer multi-device runs.

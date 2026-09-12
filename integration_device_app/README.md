# LPC integration device app

This is a small debug-only Flutter application for exercising the public LPC
API on real Android and iOS devices. It contains no messenger concepts such as
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
included in the app and CoreBluetooth presents authorization as needed.

## Control API

Debug builds bind only to `127.0.0.1` on port `8765` by default. Override it
with `--dart-define=LPC_TEST_PORT=8765` when multiple device forwards are used.

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
{"action":"sendGroup","arguments":{"peerId":"...","text":"group hello"}}
{"action":"publishCheckpoint","arguments":{"size":262144}}
{"action":"startSendTest","arguments":{"peerId":"...","messageSize":1024,"messagesPerSecond":2,"deliveryMode":"reliableAcked"}}
{"action":"stopSendTest"}
{"action":"startGroupSendTest","arguments":{"peerId":"...","messageSize":1024,"messagesPerSecond":2,"deliveryMode":"realtimeLatest"}}
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

See [TODO.md](TODO.md) for the conformance scenarios that still need
capability support, fault injection, or longer multi-device runs.

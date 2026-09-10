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
```

For a USB-forwarded port, use `adb forward tcp:18765 tcp:8765` on Android or
`iproxy 18766 8765 <udid>` on iOS. The host-side runner can then use the same
HTTP API against each forwarded port.

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

See [TODO.md](TODO.md) for the conformance scenarios that still need
capability support, fault injection, or longer multi-device runs.

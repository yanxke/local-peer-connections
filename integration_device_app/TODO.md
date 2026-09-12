# LPC cross-platform device-test app

This checklist tracks the debug fixture described in the LPC physical
integration-test section. The fixture is deliberately independent of the
messenger application: it drives the public LPC API and reports raw LPC
identity, lifecycle, transport, and group events.

## Implemented

- [x] Cross-platform Flutter application with the LPC plugin as a local path dependency.
- [x] Durable platform identity and visible non-secret `PeerId` diagnostics.
- [x] Debug-only loopback HTTP control server for USB port forwarding.
- [x] Structured event stream with monotonic sequence numbers and bounded in-memory history.
- [x] Host advertising and discovery controls.
- [x] Endpoint listing with endpoint id, RSSI, and discovery name.
- [x] Outbound connection attempts, inbound connections, SAS confirmation, and connection lifecycle events.
- [x] Reliable ordered/acked and realtime direct traffic.
- [x] Group creation, membership/coordinator events, reliable group traffic, and group leave.
- [x] Runtime capability reporting and reset/cleanup.
- [x] On-device diagnostics screen suitable for manual testing.
- [x] Controller unit tests for command payload parsing and bounded event history.

## Remaining

- [x] Add a host-side Python runner that orchestrates forwarded Android/iOS control APIs and optionally collects JSON results.
- [x] Add executable two-direction connection scenarios for IT-003 and IT-004.
- [x] Add executable scenarios for IT-005, IT-006, IT-008, IT-009, IT-021, and IT-032 through IT-035.
- [ ] Add raw advertisement assertions for IT-001 and IT-002; the current platform API intentionally exposes only filtered endpoint observations.
- [ ] Add test-only transport fault injection for altered authentication, dropped ACKs, terminal writes, and transient backpressure.
- [ ] Add complete automated assertions for IT-007 and IT-011 through IT-016, including SessionId and transport-generation continuity.
- [x] Add executable two-device soak and multi-device star scenarios for IT-017 through IT-019.
- [ ] Complete a physical IT-041 bidirectional 64-byte, 5-packet/second, 60-second reliability run (fixture is implemented; current devices are not discovering the iOS advertisement).
- [ ] Add weak-client and foreground/background scenarios for IT-020 and IT-022.
- [ ] Add capability-gated L2CAP/LAN upgrade and fallback scenarios for IT-023 through IT-027.
- [x] Add raw LPC ownership/coexistence scenarios for IT-032 through IT-035.
- [ ] Add fault-complete three-device checkpoint barrier scenarios for IT-036 through IT-038; the runner currently contains only the non-faulted checkpoint path.
- [ ] Add structured log export to a file without logging payload contents or secrets.
- [ ] Add CI validation for the app's Android debug build and iOS simulator build.

The checked-in app is a fixture and is not a production application. Release
builds intentionally do not expose the control server.

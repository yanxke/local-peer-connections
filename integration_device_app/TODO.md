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
- [x] Coordinator checkpoint size/rate/timing test controls with live slider updates.
- [x] Runtime capability reporting and reset/cleanup.
- [x] On-device diagnostics screen suitable for manual testing.
- [x] Controller unit tests for command payload parsing and bounded event history.

## Remaining

### Specification and conformance audit follow-ups

- [ ] Add raw advertisement assertions for IT-001 and IT-002; the current platform API intentionally exposes only filtered endpoint observations.
- [ ] Add deliberately altered-handshake authentication-fault coverage for IT-007.
- [ ] Complete physical reconnect/RESUME coverage for IT-011 through IT-016, including SessionId preservation, transport-generation changes, timeout behavior, and Bluetooth off/on recovery.
- [ ] Add weak-client and foreground/background scenarios for IT-020 and IT-022.
- [ ] Add capability-gated L2CAP/LAN upgrade, fallback, and duplicate-free transport-switching scenarios for IT-023 through IT-027.
- [ ] Add injected terminal-write and transient-backpressure coverage for IT-029 through IT-031.
- [ ] Add faulted three-peer checkpoint scenarios for IT-036 through IT-038.
- [ ] Complete the physical IT-041 fixed-rate reliability run.
- [ ] Complete the mandatory physical/conformance checkpoint size-ramp run for IT-044.
- [ ] Implement and verify UT-247 same-PeerId replacement of a RECONNECTING logical owner.
- [ ] Publish the required group-routing and UDP binary-vector package from Sections 53.1.1 and 53.2; the current vector set is incomplete.
- [ ] Add a complete performance-acceptance report for the Section 56 discovery, READY, RTT, reconnect, throughput, migration, and realtime-latency targets.
- [ ] Add dedicated macOS platform requirements and lifecycle conformance coverage if macOS remains an officially supported LPC target.
- [ ] Document the fixture HTTP control API (`/snapshot`, `/events`, and `/command`) as fixture-only behavior, separate from the LPC protocol.
- [ ] Document platform lifecycle guarantees for per-central server endpoints, GATT generation guards, stale-link replacement, Android GATT cleanup, and asynchronous macOS Keychain access.
- [ ] Fix IT-039 three-peer convergence and keep the full Flutter test suite green.
- [ ] Reconcile README claims about automatic group formation, election, migration, routed delivery, and checkpoint routing with the implemented runtime.
- [ ] Add integration coverage for the iOS/macOS stale peripheral-binding case where a discovered endpoint is reachable but the authenticated peer does not become online.

- [x] Add a host-side Python runner that orchestrates forwarded Android/iOS control APIs and optionally collects JSON results.
- [x] Add executable two-direction connection scenarios for IT-003 and IT-004.
- [x] Add executable scenarios for IT-005, IT-006, IT-008, IT-009, IT-021, and IT-032 through IT-035.
- [x] Add executable bidirectional direct-message scenarios (IT-040/IT-041) and a concurrent bidirectional group-message scenario (IT-042).
- [x] Add executable coordinator checkpoint bandwidth/latency size-ramp scenario (IT-044) and expose its metrics in the manual fixture UI.
- [x] Require continuous-traffic scenarios to sample lifecycle events during traffic and for a 30-second post-drain stability window.
- [ ] Add test-only transport fault injection for altered authentication, dropped ACKs, terminal writes, and transient backpressure.
- [x] Add executable two-device soak and multi-device star scenarios for IT-017 through IT-019.
- [x] Complete physical IT-043 Android/iOS reliability size-ramp run (the connected Android+iOS run passed all 11 phases with zero application-level loss).
- [ ] Add capability-gated L2CAP/LAN upgrade and fallback scenarios for IT-023 through IT-027.
- [x] Add raw LPC ownership/coexistence scenarios for IT-032 through IT-035.
- [ ] Add structured log export to a file without logging payload contents or secrets.
- [ ] Add CI validation for the app's Android debug build and iOS simulator build.

The checked-in app is a fixture and is not a production application. Release
builds intentionally do not expose the control server.

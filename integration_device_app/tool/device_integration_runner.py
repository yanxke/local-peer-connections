#!/usr/bin/env python3
"""Run the executable LPC physical-integration scenarios over USB forwards.

The fixture stays deliberately small: this runner owns orchestration and
assertions, while each device owns LPC state.  It never records payload bytes
or secrets; event assertions use sizes, states, PeerIds, SessionIds, and
GroupIds only.

Example:

    python3 tool/device_integration_runner.py \
      --device device-a=18765 --device device-b=18766 \
      --scenario IT-001 --scenario IT-003 --scenario IT-032

The device names are labels only.  They do not need to match hardware model
names.  The app must already be running on each device and its loopback
control port must be forwarded to the host.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


class RunnerFailure(RuntimeError):
    """A scenario assertion or device precondition failed."""


class ScenarioBlocked(RunnerFailure):
    """The selected scenario needs a capability/fault hook not exposed yet."""


@dataclass(frozen=True)
class Device:
    label: str
    port: int

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}"


class DeviceApi:
    def __init__(self, device: Device, timeout: float = 30.0) -> None:
        self.device = device
        self.timeout = timeout
        self.cursor = 0

    def request(self, method: str, path: str, body: object | None = None) -> Any:
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(
            f"{self.device.base}{path}",
            data=data,
            method=method,
            headers={"content-type": "application/json"} if data else {},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.load(response)
        except (urllib.error.URLError, TimeoutError, ConnectionResetError) as error:
            raise RunnerFailure(f"{self.device.label}: control API unavailable: {error}") from error

    def snapshot(self) -> dict[str, Any]:
        value = self.request("GET", "/snapshot")
        if not isinstance(value, dict):
            raise RunnerFailure(f"{self.device.label}: invalid snapshot")
        return value

    def events(self) -> list[dict[str, Any]]:
        query = urllib.parse.urlencode({"after": self.cursor})
        value = self.request("GET", f"/events?{query}")
        events = value.get("events", [])
        if not isinstance(events, list):
            raise RunnerFailure(f"{self.device.label}: invalid event response")
        for event in events:
            if isinstance(event, dict) and isinstance(event.get("sequence"), int):
                self.cursor = max(self.cursor, event["sequence"])
        return [event for event in events if isinstance(event, dict)]

    def command(self, action: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        value = self.request(
            "POST",
            "/command",
            {"action": action, "arguments": arguments or {}},
        )
        if not isinstance(value, dict) or value.get("ok") is not True:
            raise RunnerFailure(f"{self.device.label}: command {action} failed: {value}")
        result = value.get("result")
        if not isinstance(result, dict):
            raise RunnerFailure(f"{self.device.label}: command {action} returned no snapshot")
        return result


class Runner:
    def __init__(self, devices: list[Device], timeout: float, soak_seconds: int) -> None:
        self.devices = devices
        self.apis = [DeviceApi(device, timeout=timeout) for device in devices]
        self.timeout = timeout
        self.soak_seconds = soak_seconds

    def wait(self, predicate: Callable[[], bool], description: str, timeout: float | None = None) -> None:
        deadline = time.monotonic() + (timeout if timeout is not None else self.timeout)
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.25)
        raise RunnerFailure(f"timeout waiting for {description}")

    def drain_events(self) -> None:
        for api in self.apis:
            api.events()

    def wait_for_event(
        self,
        api: DeviceApi,
        event_type: str,
        predicate: Callable[[dict[str, Any]], bool] | None = None,
        timeout: float | None = None,
    ) -> dict[str, Any]:
        found: dict[str, Any] | None = None

        def check() -> bool:
            nonlocal found
            for event in api.events():
                if event.get("type") == event_type and (predicate is None or predicate(event)):
                    found = event
                    return True
            return False

        self.wait(check, f"{api.device.label} event {event_type}", timeout)
        assert found is not None
        return found

    def preflight(self) -> None:
        for api in self.apis:
            health = api.request("GET", "/health")
            snapshot = health.get("snapshot", {})
            if snapshot.get("runtimeState") != "ready":
                raise RunnerFailure(f"{api.device.label}: runtime is not ready: {snapshot}")
            if snapshot.get("capabilities") is None:
                diagnostics = api.events()
                failure = next(
                    (event for event in reversed(diagnostics)
                     if event.get("type") == "runtimeInitializationFailed"),
                    None,
                )
                raise RunnerFailure(
                    f"{api.device.label}: presence initialization failed: "
                    f"{failure or 'capabilities were not reported'}"
                )
        self.wait(
            lambda: all(self._presence_started(api) for api in self.apis),
            "presence on every device",
        )

    def _presence_started(self, api: DeviceApi) -> bool:
        snapshot = api.snapshot()
        if snapshot.get("capabilities") is not None and snapshot.get("endpoints") is not None:
            for event in api.events():
                if event.get("type") == "presenceStarted":
                    return True
        return False

    def endpoint(self, api: DeviceApi, other: DeviceApi) -> str:
        endpoints = api.snapshot().get("endpoints", [])
        if not endpoints:
            raise RunnerFailure(f"{api.device.label}: no endpoint for {other.device.label}")
        target_hint = "".join(
            character for character in other.device.label.lower()
            if character.isalnum()
        )
        matching = [
            endpoint for endpoint in endpoints
            if isinstance(endpoint, dict)
            and "".join(
                character for character in str(endpoint.get("localName", "")).lower()
                if character.isalnum()
            ) == target_hint
        ]
        if len(matching) == 1:
            endpoint = matching[0]
        elif len(endpoints) == 1:
            endpoint = endpoints[0]
        else:
            raise RunnerFailure(
                f"{api.device.label}: cannot select {other.device.label}; "
                "use matching --device labels and LPC_TEST_NAME values"
            )
        if not isinstance(endpoint, dict) or not isinstance(endpoint.get("id"), str):
            raise RunnerFailure(f"{api.device.label}: malformed endpoint: {endpoint}")
        return endpoint["id"]

    def connect(self, source: DeviceApi, target: DeviceApi) -> bool:
        endpoint_id = self.endpoint(source, target)
        source.command("connect", {"endpointId": endpoint_id})
        verified = set()
        sas_by_device: dict[str, str] = {}
        saw_verification = False

        def both_ready() -> bool:
            nonlocal saw_verification
            for api in (source, target):
                for event in api.events():
                    if event.get("type") != "verificationRequired":
                        continue
                    peer_id = event.get("peerId")
                    if not isinstance(peer_id, str):
                        raise RunnerFailure(
                            f"{api.device.label}: verification event omitted PeerId"
                        )
                    key = (api.device.label, peer_id)
                    if key in verified:
                        continue
                    verified.add(key)
                    saw_verification = True
                    sas = event.get("sas")
                    if isinstance(sas, str):
                        sas_by_device[api.device.label] = sas
                    api.command("confirmVerification", {
                        "peerId": peer_id,
                        "accepted": True,
                    })
            source_snapshot = source.snapshot()
            target_snapshot = target.snapshot()
            return bool(source_snapshot.get("connections")) and bool(target_snapshot.get("connections"))

        self.wait(both_ready, f"authenticated connection {source.device.label}->{target.device.label}")
        if saw_verification and len(sas_by_device) < 2:
            raise RunnerFailure(
                "IT-006: SAS was not observed on both sides of the connection"
            )
        if saw_verification and len(set(sas_by_device.values())) != 1:
            raise RunnerFailure(
                f"IT-006: SAS values differed across devices: {sas_by_device}"
            )
        return saw_verification

    def peer_id(self, api: DeviceApi, other: DeviceApi) -> str:
        for connection in api.snapshot().get("connections", []):
            if isinstance(connection, dict) and isinstance(connection.get("peerId"), str):
                return connection["peerId"]
        raise RunnerFailure(f"{api.device.label}: no authenticated peer for {other.device.label}")

    def backend_resource_counts(self, api: DeviceApi) -> dict[str, int]:
        counts = {"listenGatt": 0, "startAdvertising": 0, "startDiscovery": 0}
        for event in api.events():
            if event.get("type") != "lpcBackendLog":
                continue
            message = event.get("message", "")
            for method in counts:
                if f"invoke method={method}" in message:
                    counts[method] += 1
        return counts

    def reset_all(self) -> None:
        for api in self.apis:
            api.command("resetRuntime")
        self.preflight()

    def assert_discovery(self) -> None:
        def discovered() -> bool:
            return all(bool(api.snapshot().get("endpoints")) for api in self.apis)

        self.wait(discovered, "bidirectional LPC discovery")

    @staticmethod
    def payload_digest(size: int) -> str:
        value = 2166136261
        for index in range(size):
            value = ((value ^ (index % 251)) * 16777619) & 0xFFFFFFFF
        return f"{value:08x}"

    def scenario_discovery(self, scenario: str) -> None:
        self.assert_discovery()
        print(f"{scenario}: discovered LPC endpoints in both directions")

    def scenario_connect(self, scenario: str, source_index: int) -> None:
        self.reset_all()
        source = self.apis[source_index]
        target = self.apis[1 - source_index]
        self.connect(source, target)
        print(f"{scenario}: authenticated connection established in requested direction")

    def scenario_identity(self) -> None:
        self.reset_all()
        source, target = self.apis[:2]
        self.connect(source, target)
        before = [api.snapshot().get("localPeerId") for api in self.apis]
        source.command("disconnectPeer", {"peerId": self.peer_id(source, target)})
        self.wait(
            lambda: not source.snapshot().get("connections")
            and not target.snapshot().get("connections"),
            "explicit connection teardown before identity reconnect",
        )
        self.connect(source, target)
        after = [api.snapshot().get("localPeerId") for api in self.apis]
        if before != after or any(not isinstance(value, str) for value in after):
            raise RunnerFailure(f"IT-005: identity changed across reconnect: {before} -> {after}")
        print("IT-005: PeerIds remained stable across reconnect")

    def scenario_sas(self) -> None:
        self.reset_all()
        source, target = self.apis[:2]
        if not self.connect(source, target):
            raise RunnerFailure(
                "IT-006: no SAS verification event; launch both fixtures with "
                "--dart-define=LPC_TEST_TRUST_MODE=sas"
            )
        print("IT-006: both devices completed the SAS-confirmed connection")

    def scenario_messages(self) -> None:
        self.reset_all()
        source, target = self.apis[:2]
        self.connect(source, target)
        target_peer = self.peer_id(source, target)
        expected = 1000
        received = 0
        # Send in bounded batches so this test exercises the public queue rather
        # than turning the fixture into an unbounded host-side producer.
        for _ in range(20):
            for _ in range(50):
                source.command("sendReliable", {
                    "peerId": target_peer,
                    "size": 32,
                    "deliveryMode": "reliableAcked",
                })
            deadline = time.monotonic() + self.timeout
            while time.monotonic() < deadline:
                events = target.events()
                received += sum(
                    1 for event in events
                    if event.get("type") == "directMessageReceived"
                    and event.get("bytes") == 32
                    and event.get("digest") == self.payload_digest(32)
                )
                if received >= (_ + 1) * 50:
                    break
                time.sleep(0.1)
            if received < (_ + 1) * 50:
                raise RunnerFailure(f"IT-008: only received {received}/{expected} messages")
        print(f"IT-008: received {received} reliable 32-byte messages")

    def scenario_large_message(self) -> None:
        self.reset_all()
        source, target = self.apis[:2]
        self.connect(source, target)
        source.command("sendReliable", {
            "peerId": self.peer_id(source, target),
            "size": 1048576,
            "deliveryMode": "reliableAcked",
        })
        deadline = time.monotonic() + max(self.timeout, 120)
        received = False
        expected_digest = self.payload_digest(1048576)
        while time.monotonic() < deadline:
            for event in target.events():
                if (
                    event.get("type") == "directMessageReceived"
                    and event.get("bytes") == 1048576
                ):
                    if event.get("digest") != expected_digest:
                        raise RunnerFailure("IT-009: 1 MiB payload digest mismatch")
                    received = True
            for api in (source, target):
                for connection in api.snapshot().get("connections", []):
                    if connection.get("state") != "ready":
                        raise RunnerFailure(
                            f"IT-010: connection left ready state during transfer on {api.device.label}"
                        )
            if received:
                break
            time.sleep(0.1)
        if not received:
            raise RunnerFailure("timeout waiting for 1 MiB reliable message")
        print("IT-009: received a 1 MiB reliable message")
        print("IT-010: connection remained ready during the 1 MiB transfer")

    def scenario_symmetric_connect(self) -> None:
        self.reset_all()
        first, second = self.apis[:2]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [
                pool.submit(self.connect, first, second),
                pool.submit(self.connect, second, first),
            ]
            for future in futures:
                future.result()
        self.wait(
            lambda: len(first.snapshot().get("connections", [])) == 1
            and len(second.snapshot().get("connections", [])) == 1,
            "one logical connection after symmetric connect",
        )
        print("IT-021: symmetric connect collapsed to one logical PeerConnection")

    def create_group(self, checkpointing: bool = False) -> None:
        arguments = {
            "namespace": [76, 80, 67, 45, 73, 84],
            "token": list(range(16)),
            "maxPeers": len(self.apis),
            "checkpointing": checkpointing,
        }
        for api in self.apis:
            api.command("createGroup", arguments)

    def wait_group(self, members: int) -> str:
        group_ids: list[str] = []

        def converged() -> bool:
            nonlocal group_ids
            snapshots = [api.snapshot().get("group") for api in self.apis]
            if any(not isinstance(group, dict) for group in snapshots):
                return False
            group_ids = [group.get("groupId") for group in snapshots if isinstance(group, dict)]
            return all(
                isinstance(group, dict)
                and group.get("state") == "ready"
                and len(group.get("members", [])) == members
                and group.get("coordinatorPeerId")
                and group.get("groupId") == group_ids[0]
                for group in snapshots
            )

        self.wait(converged, f"group convergence with {members} members", timeout=max(self.timeout, 30))
        return group_ids[0]

    def scenario_group(self) -> None:
        self.reset_all()
        self.connect(self.apis[0], self.apis[1])
        resource_counts = [self.backend_resource_counts(api) for api in self.apis]
        self.create_group()
        self.wait_group(2)
        for api, before in zip(self.apis, resource_counts):
            after = self.backend_resource_counts(api)
            if after != before:
                raise RunnerFailure(
                    f"IT-032/033: group created duplicate physical resources on "
                    f"{api.device.label}: {before} -> {after}"
                )
            if len(api.snapshot().get("connections", [])) != 1:
                raise RunnerFailure(
                    f"IT-033: group ownership created a redundant logical connection on {api.device.label}"
                )
        source, target = self.apis[:2]
        target_peer = self.peer_id(source, target)
        source.command("sendReliable", {
            "peerId": target_peer,
            "size": 32,
            "deliveryMode": "reliableAcked",
        })
        self.wait_for_event(
            target,
            "directMessageReceived",
            lambda event: event.get("bytes") == 32
            and event.get("digest") == self.payload_digest(32),
        )
        source.command("sendGroup", {"peerId": target_peer, "size": 64})
        self.wait_for_event(
            target,
            "groupMessageReceived",
            lambda event: event.get("bytes") == 64
            and event.get("digest") == self.payload_digest(64),
        )
        print("IT-032/033: group converged and routed reliable traffic")

    def scenario_group_leave(self) -> None:
        self.reset_all()
        self.connect(self.apis[0], self.apis[1])
        self.create_group()
        self.wait_group(2)
        source, target = self.apis[:2]
        target_peer = self.peer_id(source, target)
        source.command("leaveGroup")
        self.wait(lambda: source.snapshot().get("group") is None, "source group leave")
        source.command("sendReliable", {
            "peerId": target_peer,
            "size": 24,
            "deliveryMode": "reliableAcked",
        })
        self.wait_for_event(target, "directMessageReceived", lambda event: event.get("bytes") == 24)
        print("IT-034: direct connection remained usable after leaving group")

    def scenario_group_ownership(self) -> None:
        self.reset_all()
        self.connect(self.apis[0], self.apis[1])
        self.create_group()
        self.wait_group(2)
        source, target = self.apis[:2]
        target_peer = self.peer_id(source, target)
        source.command("releasePeerRetention", {"peerId": target_peer})
        source.command("sendGroup", {"peerId": target_peer, "size": 48})
        self.wait_for_event(target, "groupMessageReceived", lambda event: event.get("bytes") == 48)
        source.command("leaveGroup")
        target.command("leaveGroup")
        self.wait(
            lambda: not source.snapshot().get("connections") and not target.snapshot().get("connections"),
            "connection close after final group owner release",
        )
        print("IT-035: releasing direct retention preserved group ownership and final close")

    def scenario_checkpoint(self) -> None:
        self.reset_all()
        self.connect(self.apis[0], self.apis[1])
        self.create_group(checkpointing=True)
        self.wait_group(2)
        snapshots = [api.snapshot() for api in self.apis]
        coordinator = next(
            api for api, snapshot in zip(self.apis, snapshots)
            if snapshot["group"]["localIsCoordinator"]
        )
        coordinator.command("publishCheckpoint", {"size": 262144})
        self.wait_for_event(
            coordinator,
            "checkpointAccepted",
            lambda event: event.get("bytes") == 262144,
        )
        self.wait_for_event(
            coordinator,
            "checkpointCompleted",
            lambda event: event.get("status") == "durable",
            timeout=max(self.timeout, 120),
        )
        print("IT-028: 262144-byte checkpoint reached durable")

    def scenario_star(self, minimum_devices: int) -> None:
        if len(self.apis) < minimum_devices:
            raise ScenarioBlocked(
                f"IT-018/019: requires at least {minimum_devices} connected test devices"
            )
        self.reset_all()
        center = self.apis[0]
        for target in self.apis[1:minimum_devices]:
            self.connect(center, target)
        self.wait(
            lambda: len(center.snapshot().get("connections", [])) == minimum_devices - 1
            and all(
                len(api.snapshot().get("connections", [])) == 1
                for api in self.apis[1:minimum_devices]
            ),
            f"{minimum_devices}-device star",
            timeout=max(self.timeout, 120),
        )
        scenario = "IT-018" if minimum_devices == 4 else "IT-019"
        print(f"{scenario}: {minimum_devices}-device star converged")

    def scenario_soak(self) -> None:
        self.reset_all()
        source, target = self.apis[:2]
        self.connect(source, target)
        peer_id = self.peer_id(source, target)
        sent = 0
        received = 0
        deadline = time.monotonic() + self.soak_seconds
        while time.monotonic() < deadline:
            source.command("sendReliable", {
                "peerId": peer_id,
                "size": 32,
                "deliveryMode": "reliableAcked",
            })
            sent += 1
            for api in (source, target):
                if any(
                    connection.get("state") != "ready"
                    for connection in api.snapshot().get("connections", [])
                ):
                    raise RunnerFailure(
                        f"IT-017: connection left ready state on {api.device.label}"
                    )
            received += sum(
                1 for event in target.events()
                if event.get("type") == "directMessageReceived"
                and event.get("bytes") == 32
                and event.get("digest") == self.payload_digest(32)
            )
            time.sleep(1)
        grace_deadline = time.monotonic() + max(self.timeout, 30)
        while received < sent and time.monotonic() < grace_deadline:
            received += sum(
                1 for event in target.events()
                if event.get("type") == "directMessageReceived"
                and event.get("bytes") == 32
                and event.get("digest") == self.payload_digest(32)
            )
            time.sleep(0.1)
        if received != sent:
            raise RunnerFailure(f"IT-017: received {received}/{sent} soak messages")
        print(f"IT-017: two-device soak delivered {received} messages")

    def scenario_three_peer_checkpoint(self) -> None:
        if len(self.apis) < 3:
            raise ScenarioBlocked("IT-036: requires at least three connected test devices")
        self.reset_all()
        for target_index in range(1, len(self.apis)):
            self.connect(self.apis[0], self.apis[target_index])
        self.create_group(checkpointing=True)
        self.wait_group(len(self.apis))
        snapshots = [api.snapshot() for api in self.apis]
        coordinator = next(
            api for api, snapshot in zip(self.apis, snapshots)
            if snapshot["group"]["localIsCoordinator"]
        )
        coordinator.command("publishCheckpoint", {"size": 262144})
        self.wait_for_event(
            coordinator,
            "checkpointAccepted",
            lambda event: event.get("bytes") == 262144,
        )
        self.wait_for_event(
            coordinator,
            "checkpointCompleted",
            lambda event: event.get("status") == "durable"
            and len(event.get("requiredPeerIds", [])) == len(self.apis) - 1,
            timeout=max(self.timeout, 180),
        )
        print("IT-036: three-peer checkpoint barrier reached durable")

    def run(self, scenario: str) -> None:
        if scenario in {"IT-001", "IT-002"}:
            self.scenario_discovery(scenario)
        elif scenario == "IT-003":
            self.scenario_connect(scenario, 0)
        elif scenario == "IT-004":
            self.scenario_connect(scenario, 1)
        elif scenario == "IT-005":
            self.scenario_identity()
        elif scenario == "IT-006":
            self.scenario_sas()
        elif scenario == "IT-008":
            self.scenario_messages()
        elif scenario == "IT-009":
            self.scenario_large_message()
        elif scenario == "IT-017":
            self.scenario_soak()
        elif scenario == "IT-018":
            self.scenario_star(4)
        elif scenario == "IT-019":
            self.scenario_star(8)
        elif scenario == "IT-021":
            self.scenario_symmetric_connect()
        elif scenario == "IT-028":
            self.scenario_checkpoint()
        elif scenario == "IT-036":
            self.scenario_three_peer_checkpoint()
        elif scenario in {"IT-032", "IT-033"}:
            self.scenario_group()
        elif scenario == "IT-034":
            self.scenario_group_leave()
        elif scenario == "IT-035":
            self.scenario_group_ownership()
        else:
            raise ScenarioBlocked(
                f"{scenario}: requires a real-device fault/capability hook not exposed by the fixture yet"
            )


def parse_device(value: str) -> Device:
    try:
        label, port = value.rsplit("=", 1)
        return Device(label=label, port=int(port))
    except ValueError as error:
        raise argparse.ArgumentTypeError("device must be LABEL=HOST_PORT") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", action="append", type=parse_device, required=True,
                        help="generic device label and forwarded host port, e.g. device-a=18765")
    parser.add_argument("--scenario", action="append", required=True,
                        help="IT-001 through IT-038; repeat for multiple scenarios")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--soak-seconds", type=int, default=1800)
    parser.add_argument("--json-output", type=Path)
    args = parser.parse_args()
    if len(args.device) < 2:
        parser.error("at least two --device values are required")

    results: list[dict[str, str]] = []
    for scenario in args.scenario:
        started = time.monotonic()
        try:
            runner = Runner(args.device, args.timeout, args.soak_seconds)
            runner.preflight()
            runner.run(scenario.upper())
            status = "passed"
            detail = ""
        except ScenarioBlocked as error:
            status = "blocked"
            detail = str(error)
        except RunnerFailure as error:
            status = "failed"
            detail = str(error)
        results.append({
            "scenario": scenario.upper(),
            "status": status,
            "detail": detail,
            "durationSeconds": f"{time.monotonic() - started:.3f}",
        })
        print(f"{scenario.upper()}: {status}{': ' + detail if detail else ''}", file=sys.stderr if status != "passed" else sys.stdout)
        if status == "failed":
            break

    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(json.dumps({"results": results}, indent=2) + "\n")
    return 0 if all(result["status"] == "passed" for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())

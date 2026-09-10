#!/usr/bin/env python3
"""Small stdlib-only client for the LPC integration device app."""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request


def request(base: str, method: str, path: str, body: object | None = None) -> object:
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        f"{base.rstrip('/')}{path}",
        data=data,
        method=method,
        headers={"content-type": "application/json"} if data else {},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--host", default="127.0.0.1")
    subparsers = parser.add_subparsers(dest="operation", required=True)
    subparsers.add_parser("health")
    subparsers.add_parser("snapshot")
    events = subparsers.add_parser("events")
    events.add_argument("--after", type=int, default=0)
    command = subparsers.add_parser("command")
    command.add_argument("action")
    command.add_argument("arguments", nargs="?", default="{}")
    args = parser.parse_args()
    base = f"http://{args.host}:{args.port}"
    try:
        if args.operation == "health":
            result = request(base, "GET", "/health")
        elif args.operation == "snapshot":
            result = request(base, "GET", "/snapshot")
        elif args.operation == "events":
            query = urllib.parse.urlencode({"after": args.after})
            result = request(base, "GET", f"/events?{query}")
        else:
            try:
                arguments = json.loads(args.arguments)
            except json.JSONDecodeError as error:
                raise SystemExit(f"arguments must be JSON: {error}") from error
            if not isinstance(arguments, dict):
                raise SystemExit("arguments must be a JSON object")
            result = request(
                base,
                "POST",
                "/command",
                {"action": args.action, "arguments": arguments},
            )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except urllib.error.HTTPError as error:
        print(error.read().decode("utf-8"), file=sys.stderr)
        return 1
    except urllib.error.URLError as error:
        print(f"cannot reach device control API: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

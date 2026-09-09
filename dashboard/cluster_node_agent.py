#!/usr/bin/env python3
"""Read-only telemetry agent for the private cluster network."""

from __future__ import annotations

import argparse
import hmac
import json
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

try:
    from .cluster_monitor import (
        collect_node_snapshot,
        load_config,
        read_token,
        utc_now,
    )
except ImportError:
    from cluster_monitor import collect_node_snapshot, load_config, read_token, utc_now


def _run_iperf_direction(
    config: dict[str, Any], reverse: bool, duration: int, parallel: int
) -> tuple[bool, str, dict[str, Any]]:
    command = [
        "iperf3",
        "-c",
        str(config.get("peer_ip", "")),
        "-B",
        str(config.get("local_ip", "")),
        "-p",
        str(config.get("iperf_port", 5201)),
        "-P",
        str(parallel),
        "-t",
        str(duration),
        "--json",
    ]
    if reverse:
        command.append("-R")
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=duration + 45,
        )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc), {}

    details: dict[str, Any] = {}
    try:
        parsed = json.loads(completed.stdout)
        if isinstance(parsed, dict):
            details = parsed
    except json.JSONDecodeError:
        pass

    if completed.returncode != 0:
        raw_message = completed.stderr.strip() or completed.stdout.strip()
        if isinstance(details.get("error"), dict):
            error_message = json.dumps(details["error"], separators=(",", ":"))
        elif details.get("error"):
            error_message = str(details["error"])
        else:
            error_message = (
                raw_message.splitlines()[0] if raw_message else "no error text"
            )
        return (
            False,
            f"iperf3 exited {completed.returncode}: {error_message[:500]}",
            details,
        )

    end = details.get("end")
    if not isinstance(end, dict):
        return False, "iperf3 returned an invalid end section", details
    summary = end.get("sum_received")
    if not isinstance(summary, dict):
        summary = end.get("sum_sent")
    if not isinstance(summary, dict):
        return False, "iperf3 did not report a summary", details
    bits_per_second = summary.get("bits_per_second")
    if not isinstance(bits_per_second, (int, float)):
        return False, "iperf3 did not report bits_per_second", details
    gbps = float(bits_per_second) / 1_000_000_000
    target = float(config.get("iperf_target_gbps", 8.0))
    return gbps >= target, f"{gbps:.3f} Gbit/s (target {target:.3f})", details


def run_usb4_agent_test(
    config: dict[str, Any], body: dict[str, Any]
) -> tuple[int, dict[str, Any]]:
    if str(config.get("role", "")) != "peer":
        return 400, {"error": "USB4 agent tests must run on the worker"}
    try:
        duration = int(body.get("duration", config.get("iperf_duration", 10)))
        parallel = int(body.get("parallel", config.get("iperf_parallel", 4)))
    except (TypeError, ValueError):
        return 400, {"error": "duration and parallel must be integers"}
    if duration < 5 or duration > 120:
        return 400, {"error": "duration must be between 5 and 120 seconds"}
    if parallel < 1 or parallel > 32:
        return 400, {"error": "parallel must be between 1 and 32"}

    results: dict[str, Any] = {}
    for reverse, name in (
        (False, "worker_to_controller"),
        (True, "controller_to_worker"),
    ):
        ok, message, details = _run_iperf_direction(
            config, reverse, duration, parallel
        )
        results[name] = {"ok": ok, "message": message, "data": details}
    success = all(item["ok"] for item in results.values())
    return 200, {"status": "ok" if success else "failed", "results": results}


class AgentHandler(BaseHTTPRequestHandler):
    server_version = "StrixHaloNodeAgent/1"

    def _json(self, status: int, body: dict[str, Any]) -> None:
        encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _authorized(self) -> bool:
        expected = getattr(self.server, "agent_token", "")
        if not expected:
            return True
        supplied = self.headers.get("X-Cluster-Agent-Token", "")
        return hmac.compare_digest(supplied, expected)

    def do_GET(self) -> None:
        if not self._authorized():
            self._json(403, {"status": "forbidden", "error": "invalid agent token"})
            return

        if self.path == "/healthz":
            self._json(200, {"status": "ok", "timestamp": utc_now()})
            return
        if self.path == "/metrics":
            config = getattr(self.server, "agent_config")
            role = getattr(self.server, "agent_role")
            self._json(200, collect_node_snapshot(config, role=role))
            return
        self._json(404, {"status": "not_found", "error": "unknown endpoint"})

    def do_POST(self) -> None:
        if not self._authorized():
            self._json(403, {"status": "forbidden", "error": "invalid agent token"})
            return
        if self.path != "/tests/usb4":
            self._json(404, {"status": "not_found", "error": "unknown endpoint"})
            return
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._json(400, {"status": "invalid_request", "error": "invalid content length"})
            return
        if content_length < 0 or content_length > 65536:
            self._json(413, {"status": "invalid_request", "error": "request is too large"})
            return
        try:
            body = json.loads(self.rfile.read(content_length).decode("utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            self._json(400, {"status": "invalid_request", "error": str(exc)})
            return
        if not isinstance(body, dict):
            self._json(400, {"status": "invalid_request", "error": "JSON body must be an object"})
            return
        config = getattr(self.server, "agent_config")
        status, response = run_usb4_agent_test(config, body)
        self._json(status, response)

    def log_message(self, format_string: str, *args: Any) -> None:
        return


def serve(config: dict[str, Any], bind: str, port: int) -> None:
    server = ThreadingHTTPServer((bind, port), AgentHandler)
    server.agent_config = config
    server.agent_role = str(config.get("role", "unknown"))
    server.agent_token = read_token(config.get("agent_token_file"))
    print(f"node agent listening on {bind}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        default="/etc/qwen3d8/dashboard.json",
        help="dashboard JSON configuration",
    )
    parser.add_argument("--bind", help="address for the private telemetry listener")
    parser.add_argument("--port", type=int, help="telemetry listener port")
    args = parser.parse_args()

    config = load_config(args.config)
    bind = args.bind or str(config.get("agent_bind", "127.0.0.1"))
    port = args.port or int(config.get("agent_port", 8765))
    serve(config, bind, port)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""residency-agent - peer-node companion to residencyd.

Canonical editable source deployed by setup-strixhalo-ai-server.sh. Lets the
head node start and stop peer-resident vLLM models without root-to-root SSH
between the two boxes.

Deliberately narrow:
  * binds ONLY to this node's USB4 address (never the LAN, never 0.0.0.0);
  * accepts only model names that already exist in the shared catalog, so it
    can never be talked into starting an arbitrary systemd unit;
  * the firewall additionally restricts the source to the head node.
"""

import json
import os
import re
import subprocess
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def read_env_file(path):
    out = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


RUNTIME = read_env_file("/etc/llm/runtime.env")
CLUSTER = read_env_file("/etc/llm/cluster.env")
CATALOG_DIR = os.path.join(RUNTIME.get("LLM_ETC", "/etc/llm"), "models.d")
BIND = CLUSTER.get("CLUSTER_LOCAL_IP", "127.0.0.1")
PORT = int(RUNTIME.get("AGENT_PORT", "8099"))
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def log(msg):
    sys.stderr.write("residency-agent: %s\n" % msg)
    sys.stderr.flush()


def mem_available_gib():
    """This node's MemAvailable in GiB, so the head node can gate peer-resident
    loads against real memory instead of the declared-budget ledger alone."""
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("MemAvailable:"):
                    return float(line.split()[1]) / (1024.0 * 1024.0)
    except OSError:
        pass
    return None


def known(name):
    return bool(NAME_RE.match(name or "")) and \
        os.path.isfile(os.path.join(CATALOG_DIR, name + ".conf"))


def systemctl(*args):
    try:
        proc = subprocess.run(("systemctl",) + args, capture_output=True, timeout=180)
        return proc.returncode, (proc.stdout + proc.stderr).decode("utf-8", "replace")
    except Exception as exc:            # noqa: BLE001 - answer the caller, never
        return 1, str(exc)              # drop the connection on a systemctl hiccup


class Handler(BaseHTTPRequestHandler):
    server_version = "residency-agent/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if length <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8", "replace"))
        except Exception:               # noqa: BLE001
            return {}

    def do_GET(self):
        path, _, query = self.path.partition("?")
        params = urllib.parse.parse_qs(query)
        if path == "/health":
            self._send(200, {"status": "ok", "node": "peer", "bind": BIND})
        elif path == "/meminfo":
            self._send(200, {"node": "peer", "mem_available_gib": mem_available_gib()})
        elif path == "/status":
            models = {}
            if os.path.isdir(CATALOG_DIR):
                for entry in sorted(os.listdir(CATALOG_DIR)):
                    if not entry.endswith(".conf"):
                        continue
                    name = entry[:-5]
                    rc, _ = systemctl("is-active", "--quiet", "vllm@%s.service" % name)
                    models[name] = "active" if rc == 0 else "inactive"
            self._send(200, {"models": models})
        elif path == "/logs":
            name = (params.get("model") or [""])[0]
            if not known(name):
                self._send(404, {"error": "unknown model %r (not in %s)" % (name, CATALOG_DIR)})
                return
            try:
                mins = max(1, min(60, int(float((params.get("minutes") or ["5"])[0]))))
            except (TypeError, ValueError):
                mins = 5
            unit = "vllm@%s.service" % name
            try:
                proc = subprocess.run(
                    ["journalctl", "-u", unit, "--since", "-%dmin" % mins, "--no-pager"],
                    capture_output=True, text=True, timeout=15)
                text = (proc.stdout or "") + (proc.stderr or "")
            except Exception as exc:                # noqa: BLE001
                text = "(could not read journal: %s)" % exc
            self._send(200, {"model": name, "node": "peer", "log": text.strip()[-20000:]})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        body = self._body()
        name = body.get("model", "")
        if path not in ("/start", "/stop"):
            self._send(404, {"error": "not found"})
            return
        if not known(name):
            self._send(404, {"error": "unknown model %r (not in %s)" % (name, CATALOG_DIR)})
            return
        unit = "vllm@%s.service" % name
        if path == "/start":
            # Same reasoning as residencyd's _start_unit: clear any StartLimit
            # counter so a deliberate load is never refused for something that
            # went wrong earlier.
            systemctl("reset-failed", unit)
            rc, out = systemctl("start", "--no-block", unit)
        else:
            rc, out = systemctl("stop", unit)
        log("%s %s -> rc=%d" % (path[1:], unit, rc))
        self._send(200 if rc == 0 else 500,
                   {"model": name, "action": path[1:], "rc": rc, "output": out[-500:]})


def main():
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    server.daemon_threads = True
    log("listening on %s:%d (catalog %s)" % (BIND, PORT, CATALOG_DIR))
    server.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    main()

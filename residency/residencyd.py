#!/usr/bin/env python3
"""residencyd - model residency manager for the two-node Strix Halo LLM cluster.

Canonical editable source deployed by setup-strixhalo-ai-server.sh. Runs as
root on the head node and is reachable ONLY through a unix socket (never the
LAN), as the plan requires.

It owns:
  * the model catalog                (/etc/llm/models.d/*.conf)
  * model state and memory budgets   (per node, in GiB)
  * active-request leases            (a leased model is never evicted)
  * admission locking                (simultaneous cold loads serialise)
  * idle-model eviction              (least-recently-used, deterministic)
  * the vllm@<name>.service lifecycle, locally and on the peer
  * health checks

Deliberately written against the Python standard library only: it runs as root,
so the fewer third-party packages in its import path the better.
"""

import glob
import json
import math
import os
import re
import shlex
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler

# --------------------------------------------------------------------------- config

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


def _patch_conf_fields(path, updates):
    """Rewrite just the given KEY=VALUE line(s) of a catalog .conf in place,
    preserving everything else (comments, field order, unrelated settings).
    Appends any key that is not already present. Used to persist a placement
    self-correction (see Residency._autofix_placement) so 'llm-model show' and
    the next reload both agree with what this process is already running."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError as exc:
        log("could not read %s to persist a placement correction: %s" % (path, exc))
        return
    remaining = dict(updates)
    out = []
    for line in lines:
        stripped = line.strip()
        matched = False
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key in remaining:
                out.append("%s=%s\n" % (key, remaining.pop(key)))
                matched = True
        if not matched:
            out.append(line)
    for key, val in remaining.items():
        out.append("%s=%s\n" % (key, val))
    try:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.writelines(out)
        os.replace(tmp, path)
    except OSError as exc:
        log("could not persist a placement correction to %s: %s" % (path, exc))


def _cli_arg(argv, flag, value):
    """Append flag/value to an 'llm-model' argv list, skipping None/blank/False
    so callers (the HTTP add/delete endpoints below) only pass what the
    operator actually filled in and 'llm-model add' applies its own defaults
    for everything else, exactly as it does for a human typing the command."""
    if value is None or value == "":
        return
    if value is True:
        argv.append(flag)
    else:
        argv.extend([flag, str(value)])


def _derive_name(repo):
    """Same derivation 'llm-model pull' uses for an unnamed download: the last
    path segment of the repo id, non-identifier characters folded to '-'. Only
    needed here so a follow-up 'llm-model set' (applying dashboard-supplied
    overrides after the download's own 'add' has run) knows which catalog
    entry to target when the caller left --name blank."""
    base = repo.rstrip("/").rsplit("/", 1)[-1]
    return re.sub(r"[^A-Za-z0-9._-]", "-", base) or "model"


RUNTIME = read_env_file("/etc/llm/runtime.env")
CLUSTER = read_env_file("/etc/llm/cluster.env")

LLM_ETC = RUNTIME.get("LLM_ETC", "/etc/llm")
CATALOG_DIR = os.path.join(LLM_ETC, "models.d")
# 'llm-model' is the single source of truth for catalog mutation (name
# validation, port picking, budget defaulting, and the same single-vs-
# distributed auto-placement math _autofix_placement below also runs). The
# HTTP add/delete endpoints below are a thin wrapper that shells out to it
# rather than re-implementing any of that, so there is exactly one place
# that logic lives.
MODEL_CLI = "/usr/local/bin/llm-model"
# Where 'llm-model pull' stores downloaded models. residencyd stamps a
# .last_used marker in here on every use so 'llm-model gc' can evict the
# least-recently-used pulled models when the shared volume runs low.
LLM_ROOT = RUNTIME.get("LLM_ROOT", "/srv/models")
PULLED_DIR = os.path.join(LLM_ROOT, "pulled")
# A Hugging Face/ModelScope download can run for many minutes, so it is
# launched as a transient systemd unit (fire-and-forget: 'systemd-run' itself
# returns almost instantly) rather than a blocking subprocess -- residencyd's
# request thread must not be tied up for the whole download, and the dashboard
# polls progress via journalctl instead. '--collect' garbage-collects the
# transient unit once it exits; journald keeps its log by unit name regardless,
# so the log stays tailable after that. Naming it a fixed unit (rather than
# one name per job) is what makes "only one download at a time" a simple
# 'systemctl is-active' check instead of extra bookkeeping.
PULL_UNIT_NAME = "llm-pull"
PULL_UNIT = PULL_UNIT_NAME + ".service"
SOCKET_PATH = RUNTIME.get("RESIDENCY_SOCK", "/run/residencyd/control.sock")
SOCKET_GROUP = RUNTIME.get("GATEWAY_USER", "llmgateway")
SERVER_IP = CLUSTER.get("CLUSTER_SERVER_IP", "10.44.0.1")
PEER_IP = CLUSTER.get("CLUSTER_WORKER_IP", "10.44.0.2")
AGENT_PORT = int(RUNTIME.get("AGENT_PORT", "8099"))
BUDGET_GIB = float(RUNTIME.get("RESIDENCY_BUDGET_GIB", "100"))
IDLE_TIMEOUT = float(RUNTIME.get("RESIDENCY_IDLE_TIMEOUT", "1800"))
LOAD_TIMEOUT = float(RUNTIME.get("RESIDENCY_LOAD_TIMEOUT", "1800"))
# A lease is held for the lifetime of one request. The gateway always releases
# it, but a gateway that is SIGKILLed cannot, and a leaked lease pins a model
# resident forever and eventually starves everything else with 409s. So leases
# also expire on their own: generously longer than any real request, short
# enough that a crash heals itself without operator involvement.
LEASE_TTL = float(RUNTIME.get("RESIDENCY_LEASE_TTL", "7200"))

# --- live memory-safety gate (all GiB unless noted) -------------------------
# The declared per-model budget is only a ledger. On this unified-memory APU the
# real ceiling is physical RAM, so before committing any cold load residencyd
# also checks the target node's ACTUAL free memory (its own /proc/meminfo, or
# the peer agent's /meminfo). This is what stops the ledger and the hardware
# from disagreeing until the box freezes -- the failure that took mighty-ai1
# down when two large models loaded at once.
RESERVE_FLOOR_GIB = float(RUNTIME.get("RESIDENCY_RESERVE_FLOOR_GIB", "12"))
CRITICAL_FLOOR_GIB = float(RUNTIME.get("RESIDENCY_CRITICAL_FLOOR_GIB", "8"))
# A cold load PEAKS above its steady state (torch.compile / CUDA-graph capture /
# Mamba cache), so require this multiple of the budget to be free to start one.
LOAD_PEAK_FACTOR = float(RUNTIME.get("RESIDENCY_LOAD_PEAK_FACTOR", "1.10"))
MEASURE_ENABLE = RUNTIME.get("RESIDENCY_MEASURE", "1") != "0"
# When a node's free memory cannot be measured (peer agent too old/unreachable),
# strict=1 refuses the load; strict=0 falls back to the ledger for that node.
# Default lenient so a headless peer running an older agent still loads models;
# the head node -- where the desktop runs and the lockup happened -- is always
# locally measurable regardless of this setting.
MEASURE_STRICT = RUNTIME.get("RESIDENCY_MEASURE_STRICT", "0") == "1"
STATE_DIR = RUNTIME.get("RESIDENCY_STATE_DIR", "/var/lib/residencyd")
EFFECTIVE_PATH = os.path.join(STATE_DIR, "effective_budgets.json")

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

CAPACITY_ERROR = {
    "error": {
        "message": "[model_capacity_unavailable] The requested model cannot be "
                   "loaded because cluster memory is currently in active use.",
        "type": "cluster_capacity_error",
        "param": "model",
        "code": "model_capacity_unavailable",
    }
}


def distributed_budget_gib(budget):
    """Estimate the per-node budget for a two-node pipeline split."""
    half = float(budget) / 2.0
    return int(math.ceil(half + max(0.30 * half, 6.0)))


def log(msg):
    sys.stderr.write("residencyd: %s\n" % msg)
    sys.stderr.flush()


# --------------------------------------------------------------------------- model

class Model(object):
    __slots__ = ("name", "path", "served_name", "port", "placement", "tp", "pp",
                 "budget", "enabled", "keep_warm", "max_model_len",
                 "state", "leases", "last_used", "last_error", "loaded_at",
                 "current_node", "operation_phase", "operation_started",
                 "operation_finished")

    def __init__(self, name, conf):
        self.name = name
        self.path = conf.get("MODEL_PATH", "")
        self.served_name = conf.get("SERVED_NAME") or name
        try:
            self.port = int(conf.get("PORT", "0"))
        except ValueError:
            self.port = 0
        self.placement = conf.get("PLACEMENT", "auto")
        if self.placement not in ("server", "peer", "distributed", "auto"):
            self.placement = "auto"
        try:
            self.tp = int(conf.get("TENSOR_PARALLEL", "1"))
        except ValueError:
            self.tp = 1
        try:
            self.pp = int(conf.get("PIPELINE_PARALLEL", "1"))
        except ValueError:
            self.pp = 1
        try:
            # Round up to the next whole GiB. A .conf can carry a fractional
            # value (a hand-edit, or an explicit --budget-gib from the CLI/
            # dashboard) but residencyd's admission math and the dashboard
            # never needed that precision, so it is normalized on every load.
            self.budget = float(math.ceil(float(conf.get("MEM_BUDGET_GIB", "16"))))
        except ValueError:
            self.budget = 16.0
        self.enabled = conf.get("ENABLED", "1") != "0"
        # KEEP_WARM exempts a model from *idle* reaping only. An interactive
        # client (an IDE agent, say) is bursty: busy for ten minutes, quiet for
        # forty. Under plain LRU it gets reaped between sessions and every
        # session reopens with a multi-minute cold start. It is deliberately
        # NOT exempt from eviction under memory pressure -- a model that could
        # never be evicted would let one entry permanently wedge a node budget.
        self.keep_warm = conf.get("KEEP_WARM", "0") == "1"
        try:
            self.max_model_len = int(conf.get("MAX_MODEL_LEN") or 0) or None
        except ValueError:
            self.max_model_len = None
        # Runtime state, preserved across catalog reloads by merge().
        self.state = "unloaded"      # unloaded|loading|ready|stopping|failed
        self.leases = set()
        self.last_used = 0.0
        self.loaded_at = 0.0
        self.last_error = ""
        self.operation_phase = "idle"
        self.operation_started = 0.0
        self.operation_finished = 0.0
        # Which node an 'auto'-placement model actually landed on for its
        # current (or most recent) residency. None until _choose_node() picks
        # one; cleared again on every unload/failure so the next load is free
        # to land somewhere else if conditions have changed. Unused for the
        # server/peer/distributed placements, which already know their node
        # from PLACEMENT itself.
        self.current_node = None

    @property
    def nodes(self):
        """Which node budgets this model consumes while resident."""
        if self.placement == "distributed":
            return ("server", "peer")
        if self.placement == "auto":
            return (self.current_node,) if self.current_node else ()
        return (self.placement,)

    @property
    def backend(self):
        node = self.current_node if self.placement == "auto" else self.placement
        host = PEER_IP if node == "peer" else "127.0.0.1"
        return "http://%s:%d" % (host, self.port)

    @property
    def resident(self):
        return self.state in ("loading", "ready")

    def public(self):
        active_operation = (
            self.state in ("loading", "stopping")
            or self.operation_phase in ("admitting", "loading", "compiling",
                                        "redistributing", "stopping",
                                        "deleting", "failed")
        )
        elapsed = ((self.operation_finished or time.time()) - self.operation_started
                   if self.operation_started and (active_operation or self.operation_finished)
                   else 0.0)
        return {
            "id": self.name,
            "name": self.name,
            "served_name": self.served_name,
            "state": self.state,
            "placement": self.placement,
            "node": ("+".join(self.nodes)
                     if (self.resident or self.state == "stopping"
                         or self.operation_phase in
                         ("admitting", "loading", "compiling", "redistributing"))
                     else None),
            "tensor_parallel": self.tp,
            "pipeline_parallel": self.pp,
            "budget_gib": self.budget,
            "port": self.port,
            "backend": self.backend if self.state == "ready" else None,
            "active_leases": len(self.leases),
            "idle_seconds": (time.time() - self.last_used) if (self.state == "ready" and not self.leases) else 0,
            "path": self.path,
            "enabled": self.enabled,
            "keep_warm": self.keep_warm,
            "max_model_len": self.max_model_len,
            "last_error": self.last_error,
            # Additive operation fields: existing catalog clients can ignore
            # them, while the dashboard can show progress without guessing
            # from the coarse residency state alone.
            "phase": self.operation_phase,
            "operation_phase": self.operation_phase,
            "operation_started": (self.operation_started or None),
            "operation_finished": (self.operation_finished or None),
            "elapsed_seconds": elapsed,
        }


# --------------------------------------------------------------------------- helpers

def http_json(url, payload=None, timeout=10):
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8", "replace")
    return json.loads(body) if body.strip() else {}


def http_text(url, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read().decode("utf-8", "replace")


def local_mem_available_gib():
    """Physically available memory on THIS node, in GiB, or None if unreadable.

    MemAvailable already discounts reclaimable page cache, and amdgpu's GTT
    allocations (vLLM weights + KV cache) are unreclaimable pinned pages that
    lower it directly -- so on this unified-memory APU it is an honest 'how much
    room is left before the box thrashes / OOM-kills' proxy.
    """
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("MemAvailable:"):
                    return float(line.split()[1]) / (1024.0 * 1024.0)  # kB->GiB
    except OSError:
        pass
    return None


def systemctl(*args):
    try:
        proc = subprocess.run(("systemctl",) + args, capture_output=True, timeout=180)
        return proc.returncode, (proc.stdout + proc.stderr).decode("utf-8", "replace")
    except Exception as exc:            # noqa: BLE001 - never let systemd kill the daemon
        return 1, str(exc)


# --------------------------------------------------------------------------- daemon

class Residency(object):
    def __init__(self):
        self.lock = threading.RLock()        # guards the model table
        self.admission = threading.Lock()    # serialises cold loads
        self.models = {}
        self.leases = {}                     # lease id -> model name
        self.lease_born = {}                 # lease id -> grant timestamp
        # Per-model footprints LEARNED from real loads (name -> GiB), persisted
        # across restarts, and a short-lived cache of each node's last measured
        # free memory so /catalog can report it without a fresh probe per call.
        self.effective = self._load_effective()
        self._free_cache = {}                # node -> (gib, monotonic_ts)
        self.load_catalog()
        self.stop_event = threading.Event()
        self.reaper = threading.Thread(target=self._reap_loop, daemon=True)
        self.reaper.start()

    # ------------------------------------------------------------- catalog
    def _autofix_placement(self, model, conf_path):
        """Make sure a catalog entry's PLACEMENT/PIPELINE_PARALLEL agree with
        the memory budget and parallelism it actually declares, self-healing
        any mismatch instead of leaving a model that can only ever 409. Runs
        once per model on every load_catalog() (llm-model add, 'llm-model
        catalog-reload', or a hand-edited .conf picked up by a reload) --
        models bypass this only if they never go through load_catalog(),
        which does not happen in production (Residency.__init__ always calls
        it, and it is the only path that populates self.models)."""
        # Rule 1: tp/pp >= 2 already spans both nodes (this cluster has one
        # GPU per node; vllm-serve wires up the Ray backend for ANY tp/pp > 1
        # regardless of what PLACEMENT says), so any placement other than
        # 'distributed' here is a ledger/reality mismatch -- residencyd would
        # charge only ONE node's budget for a model actually resident on both.
        # This is a hardware fact, so it overrides even an explicit pin.
        if (model.tp >= 2 or model.pp >= 2) and model.placement != "distributed":
            log("catalog: %s declares tp=%d/pp=%d (spans both nodes) but "
                "PLACEMENT=%s; self-healing to distributed"
                % (model.name, model.tp, model.pp, model.placement))
            model.placement = "distributed"
            if model.pp < 2:
                model.pp = 2
            _patch_conf_fields(conf_path, {
                "PLACEMENT": "distributed",
                "PIPELINE_PARALLEL": str(model.pp),
            })
            if model.budget > BUDGET_GIB:
                log("catalog: WARNING %s needs %.0f GiB/node even split across "
                    "both nodes, more than this node's %.0f GiB budget"
                    % (model.name, model.budget, BUDGET_GIB))
            return
        # Rule 2: an explicit server/peer pin that no longer fits a single
        # node is left alone -- an operator's explicit pin is never silently
        # moved -- but flagged loudly, since it can now only ever 409.
        if model.placement in ("server", "peer") and model.budget > BUDGET_GIB:
            log("catalog: ERROR %s is pinned to '%s' but needs %.0f GiB, more "
                "than this node's %.0f GiB budget; it can never load until "
                "PLACEMENT is changed to 'distributed' (or 'auto') by hand"
                % (model.name, model.placement, model.budget, BUDGET_GIB))
            return
        # Rule 3: an 'auto'-placement model whose (possibly learned) budget no
        # longer fits a single node is upgraded to distributed using the same
        # halving shape llm-profile uses for a fresh pull, so it becomes
        # admittable instead of refusing every load attempt forever.
        if model.placement == "auto" and model.budget > BUDGET_GIB:
            per_node = distributed_budget_gib(model.budget)
            log("catalog: %s needs %.0f GiB, more than this node's %.0f GiB "
                "budget; self-healing to distributed (pp=2, ~%d GiB/node)"
                % (model.name, model.budget, BUDGET_GIB, per_node))
            model.placement = "distributed"
            model.pp = 2
            model.budget = float(per_node)
            _patch_conf_fields(conf_path, {
                "PLACEMENT": "distributed",
                "PIPELINE_PARALLEL": "2",
                "MEM_BUDGET_GIB": str(per_node),
            })
            if per_node > BUDGET_GIB:
                log("catalog: WARNING %s still needs ~%d GiB/node even split "
                    "across both nodes, more than this node's %.0f GiB budget"
                    % (model.name, per_node, BUDGET_GIB))

    def load_catalog(self):
        found = {}
        for path in sorted(glob.glob(os.path.join(CATALOG_DIR, "*.conf"))):
            name = os.path.basename(path)[:-5]
            if not NAME_RE.match(name):
                log("ignoring catalog entry with an unsafe name: %r" % name)
                continue
            model = Model(name, read_env_file(path))
            if not model.enabled:
                continue
            # Fold in any footprint we LEARNED on a previous residency, so
            # admission reserves for the per-process overhead the declared
            # budget omits (HIP context, Ray object store, the desktop) --
            # this must happen BEFORE _autofix_placement so a model that only
            # becomes oversized once the learned figure is folded in is still
            # caught, and so a distributed model's already-halved per-node
            # budget below is never subsequently overwritten by the old
            # whole-model learned figure.
            learned = self.effective.get(name)
            if learned and learned > model.budget:
                model.budget = float(math.ceil(learned))
            self._autofix_placement(model, path)
            found[name] = model
        with self.lock:
            for name, model in found.items():
                old = self.models.get(name)
                if old is not None:
                    # A running model keeps its state across a catalog reload.
                    model.state = old.state
                    model.leases = old.leases
                    model.last_used = old.last_used
                    model.loaded_at = old.loaded_at
                    model.last_error = old.last_error
                    model.current_node = old.current_node
                    model.operation_phase = old.operation_phase
                    model.operation_started = old.operation_started
                    model.operation_finished = old.operation_finished
            orphans = [old for name, old in self.models.items()
                       if name not in found and old.resident]
            for old in orphans:
                old.state = "stopping"
            self.models = found
        # Stopping may hit the peer over HTTP, so do it with the lock released.
        for old in orphans:
            log("model %s vanished from the catalog while resident; stopping it" % old.name)
            self._stop_unit(old)
        log("catalog: %d model(s) [%s]" % (len(found), ", ".join(sorted(found))))


    # ------------------------------------------------------------ capacity
    def _used(self, node, exclude=None):
        total = 0.0
        for model in self.models.values():
            if model is exclude or not model.resident:
                continue
            if node in model.nodes:
                total += model.budget
        return total

    def _fits(self, model):
        return all(self._used(node, exclude=model) + model.budget <= BUDGET_GIB
                   for node in model.nodes)

    def _choose_node(self, model):
        """Pick server or peer for an 'auto'-placement model that has not yet
        landed anywhere for this residency. Prefers a node it already fits on
        without evicting anything; if neither does, prefers whichever node
        has more free headroom, since that is the one _make_room() will need
        to evict the least on. Ties (e.g. both nodes empty) favour the head
        node, which is one less USB4 hop for the gateway to reach."""
        def free(node):
            return BUDGET_GIB - self._used(node, exclude=model)
        fits_now = [n for n in ("server", "peer") if free(n) >= model.budget]
        if fits_now:
            return max(fits_now, key=lambda n: (free(n), n == "server"))
        return max(("server", "peer"), key=lambda n: (free(n), n == "server"))

    # ------------------------------------------------- live memory safety
    def _node_free_gib(self, node):
        """Measured free memory on `node` in GiB, or None if it cannot be read.

        server -> our own /proc/meminfo; peer -> the agent's /meminfo over USB4.
        Every result is cached for /catalog. None means 'unknown', and callers
        treat unknown per MEASURE_STRICT: fail-closed when strict, fall back to
        the ledger when not.
        """
        if not MEASURE_ENABLE:
            return None
        val = None
        if node == "server":
            val = local_mem_available_gib()
        elif node == "peer":
            try:
                data = http_json("http://%s:%d/meminfo" % (PEER_IP, AGENT_PORT),
                                 timeout=4)
                val = float(data.get("mem_available_gib"))
            except Exception:            # noqa: BLE001 - unreachable == unknown
                val = None
        if val is not None:
            self._free_cache[node] = (val, time.monotonic())
        return val

    def _mem_ok(self, model):
        """(ok, detail): does every node this model occupies have enough ACTUAL
        free memory for its peak footprint, over and above the reserve floor?"""
        if not MEASURE_ENABLE:
            return True, ""
        need = model.budget * LOAD_PEAK_FACTOR
        for node in model.nodes:
            free = self._node_free_gib(node)
            if free is None:
                if MEASURE_STRICT:
                    return False, "%s free memory could not be measured" % node
                continue                 # lenient: trust the ledger for this node
            if free - RESERVE_FLOOR_GIB < need:
                return False, ("%s has %.1f GiB free; needs %.1f + %.1f reserve"
                               % (node, free, need, RESERVE_FLOOR_GIB))
        return True, ""

    def _free_memory_for(self, model):
        """Evict LRU idle models until the LIVE memory gate passes for `model`.

        Complements _make_room, which is ledger-driven: the ledger can believe a
        node has room while the hardware disagrees, because real footprints drift
        above declared budgets. Runs WITHOUT self.lock, like _make_room, since
        every probe and stop below is a network or systemd call.
        """
        ok, _ = self._mem_ok(model)
        if ok:
            return True
        with self.lock:
            candidates = self._evict_candidates(model)
        for victim in candidates:
            if self._busy(victim):
                continue
            with self.lock:
                if victim.state != "ready" or victim.leases:
                    continue
                log("evicting idle %s to satisfy the live memory gate for %s"
                    % (victim.name, model.name))
                victim.state = "stopping"
            self._stop_unit(victim)
            time.sleep(1.0)              # let the kernel reclaim the freed pages
            ok, _ = self._mem_ok(model)
            if ok:
                return True
        ok, _ = self._mem_ok(model)
        return ok

    def _try_distributed(self, model, single_why):
        """Retry an auto model as a two-node pipeline split after a live
        single-node memory refusal.

        The catalog's declared budget can fit on one node while the cold-load
        peak cannot. In that case a PP=2 split may fit, so test the actual
        per-node budget and live memory on both nodes before persisting the
        placement change.
        """
        if model.placement != "auto" or model.tp >= 2 or model.pp >= 2:
            return False, "model is not eligible for automatic distribution"

        target = model.current_node or "unknown"
        peak = model.budget * LOAD_PEAK_FACTOR
        log("admission: single-node attempt for %s: placement=auto->%s, "
            "budget=%.0f GiB/node, peak=%.1f GiB + %.1f GiB reserve; %s"
            % (model.name, target, model.budget, peak, RESERVE_FLOOR_GIB,
               single_why))

        per_node = distributed_budget_gib(model.budget)
        distributed_peak = per_node * LOAD_PEAK_FACTOR
        server_free = self._node_free_gib("server")
        peer_free = self._node_free_gib("peer")
        server_text = ("%.1f" % server_free) if server_free is not None else "unknown"
        peer_text = ("%.1f" % peer_free) if peer_free is not None else "unknown"
        log("admission: trying distributed %s: placement=distributed, "
            "pp=2, budget=%.0f GiB/node, peak=%.1f GiB + %.1f GiB reserve, "
            "server free=%s GiB, peer free=%s GiB"
            % (model.name, per_node, distributed_peak, RESERVE_FLOOR_GIB,
               server_text, peer_text))

        if per_node > BUDGET_GIB:
            detail = ("distributed candidate needs %.0f GiB/node, above the "
                      "configured %.0f GiB/node budget" % (per_node, BUDGET_GIB))
            log("admission: distributed rejected for %s: %s"
                % (model.name, detail))
            return False, detail

        original_placement = model.placement
        original_pp = model.pp
        original_budget = model.budget
        original_node = model.current_node

        with self.lock:
            model.placement = "distributed"
            model.pp = 2
            model.budget = float(per_node)
            model.current_node = None
            model.operation_phase = "redistributing"

        if not self._make_room(model):
            detail = ("distributed ledger could not make room for %.0f GiB/node"
                      % per_node)
            with self.lock:
                model.placement = original_placement
                model.pp = original_pp
                model.budget = original_budget
                model.current_node = original_node
            log("admission: distributed rejected for %s: %s"
                % (model.name, detail))
            return False, detail

        if not self._free_memory_for(model):
            _, why = self._mem_ok(model)
            detail = "distributed memory gate refused: %s" % why
            with self.lock:
                model.placement = original_placement
                model.pp = original_pp
                model.budget = original_budget
                model.current_node = original_node
            log("admission: distributed rejected for %s: %s"
                % (model.name, detail))
            return False, detail

        conf_path = os.path.join(CATALOG_DIR, model.name + ".conf")
        _patch_conf_fields(conf_path, {
            "PLACEMENT": "distributed",
            "PIPELINE_PARALLEL": "2",
            "MEM_BUDGET_GIB": str(per_node),
        })
        if model.name in self.effective:
            self.effective.pop(model.name, None)
            self._save_effective()
        log("admission: distributed accepted for %s: pp=2, "
            "requesting %.0f GiB on each node (peak %.1f + %.1f reserve)"
            % (model.name, per_node, distributed_peak, RESERVE_FLOOR_GIB))
        return True, ""

    def _relieve_pressure(self):
        """Evict the LRU idle model on any node whose measured free has fallen
        below CRITICAL_FLOOR -- a relief valve for real usage creeping past the
        ledger (a warm model's KV cache growing, say) before the idle timer
        would have fired."""
        if not MEASURE_ENABLE:
            return
        for node in ("server", "peer"):
            free = self._node_free_gib(node)
            if free is None or free >= CRITICAL_FLOOR_GIB:
                continue
            with self.lock:
                victims = [m for m in self.models.values()
                           if m.state == "ready" and not m.leases
                           and node in m.nodes]
                victims.sort(key=lambda m: (m.keep_warm, m.last_used))
            for victim in victims:
                if self._busy(victim):
                    continue
                with self.lock:
                    if victim.state != "ready" or victim.leases:
                        continue
                    log("node %s low on memory (%.1f GiB free < %.1f floor): "
                        "evicting idle %s" % (node, free, CRITICAL_FLOOR_GIB,
                                              victim.name))
                    victim.state = "stopping"
                self._stop_unit(victim)
                break                    # one per pass; re-measure next cycle

    def _free_snapshot(self, model):
        return {node: self._node_free_gib(node) for node in model.nodes}

    def _load_effective(self):
        try:
            with open(EFFECTIVE_PATH, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            # Ceil on load too, so a value written before this rounding was
            # added (or edited by hand) self-heals on the next restart instead
            # of needing a fresh measurement to clean up.
            return {k: float(math.ceil(float(v))) for k, v in data.items()
                    if isinstance(v, (int, float))}
        except Exception:                # noqa: BLE001 - absent/corrupt == none
            return {}

    def _save_effective(self):
        try:
            os.makedirs(STATE_DIR, exist_ok=True)
            tmp = EFFECTIVE_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(self.effective, fh)
            os.replace(tmp, EFFECTIVE_PATH)
        except OSError as exc:
            log("could not persist learned budgets: %s" % exc)

    def _learn_budget(self, model, free_before):
        """Fold the real footprint just observed into this model's effective
        budget, so future admissions reserve for the per-process overhead the
        declared budget omits. Only ever RAISES the budget toward reality, never
        lowers it -- a noisy sample can cost a little headroom but never an
        over-commit."""
        if not MEASURE_ENABLE:
            return
        observed = 0.0
        for node in model.nodes:
            before = free_before.get(node)
            after = self._node_free_gib(node)
            if before is None or after is None:
                continue
            observed = max(observed, before - after)   # per-node share
        if observed <= 0 or observed > BUDGET_GIB:
            return
        # Round up to the next whole GiB: the raw before/after diff carries
        # false precision (e.g. 25.303897857666016) down to fractions of a
        # kB. Nothing downstream -- admission math or the dashboard -- needs
        # more than a whole GiB, and rounding up (never down) keeps the
        # "never under-commit" guarantee this method already makes.
        learned = math.ceil(max(model.budget, observed))
        if learned > model.budget + 0.5:
            log("learned %s footprint %.1f GiB (declared %.1f) -- raising its "
                "effective budget" % (model.name, observed, model.budget))
        with self.lock:
            model.budget = float(learned)
            self.effective[model.name] = float(learned)
        self._save_effective()

    def _inflight(self, model):
        """True when the backend itself still has requests running or queued.

        Deliberately ignores leases: lease expiry needs to know whether real work
        is happening, and by definition it is asking about a model that still
        holds one.
        """
        try:
            body = http_text(model.backend + "/metrics", timeout=3)
        except Exception:               # noqa: BLE001 - unreachable == not busy
            return False
        for line in body.splitlines():
            if line.startswith("vllm:num_requests_running") or \
               line.startswith("vllm:num_requests_waiting"):
                try:
                    if float(line.rsplit(" ", 1)[-1]) > 0:
                        return True
                except ValueError:
                    continue
        return False

    def _busy(self, model):
        """True when the model is actively serving, so it must not be evicted."""
        if model.leases:
            return True
        return self._inflight(model)

    def _evict_candidates(self, model):
        """Idle, unleased, resident models, least-recently-used first."""
        others = [m for m in self.models.values()
                  if m is not model and m.state == "ready" and not m.leases
                  and any(n in model.nodes for n in m.nodes)]
        # LRU is still the whole policy, with exactly one tie-break: a
        # keep-warm model is the last thing considered, so it is only evicted
        # when nothing else on that node can free enough room. False sorts
        # before True, so this puts keep_warm at the end.
        others.sort(key=lambda m: (m.keep_warm, m.last_used))
        return others

    def _make_room(self, model):
        """Evict LRU idle models until 'model' fits. Runs WITHOUT self.lock:
        every probe and stop below is a network or systemd call, and blocking
        /release or /catalog behind a hung peer is how a slow cable turns into
        a dead control plane. self.admission serialises cold starts for us."""
        with self.lock:
            if self._fits(model):
                return True
            candidates = self._evict_candidates(model)
        for victim in candidates:
            if self._busy(victim):
                continue
            with self.lock:
                # Re-validate: a request may have leased this model while we
                # were probing it over the network.
                if victim.state != "ready" or victim.leases:
                    continue
                if victim.keep_warm:
                    log("evicting keep-warm model %s to make room for %s: "
                        "nothing else on this node could free enough memory"
                        % (victim.name, model.name))
                else:
                    log("evicting idle model %s (LRU) to make room for %s"
                        % (victim.name, model.name))
                victim.state = "stopping"
            self._stop_unit(victim)
            with self.lock:
                if self._fits(model):
                    return True
        with self.lock:
            return self._fits(model)

    # --------------------------------------------------------------- units
    def _operation(self, model, phase, state=None, reset=False):
        """Update the additive live-operation fields without holding them
        across systemd or peer calls."""
        with self.lock:
            if reset or not model.operation_started:
                model.operation_started = time.time()
                model.operation_finished = 0.0
            model.operation_phase = phase
            if phase not in ("idle", "ready"):
                model.operation_finished = 0.0
            if state is not None:
                model.state = state

    def _operation_failed(self, model, detail, state=None):
        with self.lock:
            model.operation_phase = "failed"
            model.last_error = detail
            model.operation_finished = time.time()
            if state is not None:
                model.state = state

    def _operation_idle(self, model):
        with self.lock:
            model.operation_phase = "idle"
            model.operation_started = 0.0
            model.operation_finished = 0.0

    def _unit(self, model):
        return "vllm@%s.service" % model.name

    def _node_of(self, model):
        """Which single node this model's vllm@ unit actually runs on right
        now. 'distributed' has no single answer (it spans both); callers that
        need to route a systemctl-vs-peer-HTTP decision never call this for
        a distributed model."""
        return model.current_node if model.placement == "auto" else model.placement

    def _start_unit(self, model):
        if self._node_of(model) == "peer":
            http_json("http://%s:%d/start" % (PEER_IP, AGENT_PORT),
                      {"model": model.name}, timeout=30)
            return 0, "started on peer"
        # vllm@ carries StartLimitBurst so a broken model cannot restart-loop
        # forever, but systemd counts our deliberate demand-driven starts against
        # that same budget. Clearing the counter first leaves the rate limit
        # governing only the automatic restarts it was meant for, and stops a
        # model that failed three times an hour ago from being permanently
        # un-loadable.
        systemctl("reset-failed", self._unit(model))
        return systemctl("start", "--no-block", self._unit(model))

    def _stop_unit(self, model):
        self._operation(model, "stopping", state="stopping")
        try:
            if self._node_of(model) == "peer":
                http_json("http://%s:%d/stop" % (PEER_IP, AGENT_PORT),
                          {"model": model.name}, timeout=60)
            else:
                systemctl("stop", self._unit(model))
        except Exception as exc:        # noqa: BLE001
            log("stopping %s failed: %s" % (model.name, exc))
        with self.lock:
            model.state = "unloaded"
            model.loaded_at = 0.0
        self._operation_idle(model)
        # Free the node choice: the next load may find a different node with
        # more room, especially right after this same stop made room somewhere.
        with self.lock:
            model.current_node = None

    def _wait_ready(self, model, deadline):
        url = model.backend + "/health"
        while time.time() < deadline:
            if self.stop_event.is_set():
                return None
            try:
                with urllib.request.urlopen(url, timeout=5) as resp:
                    if 200 <= resp.status < 300:
                        return True
            except Exception:           # noqa: BLE001 - still starting
                pass
            # A crashed unit will never become healthy; fail fast instead of
            # making the caller wait out the whole cold-start budget. This
            # must check for the terminal 'failed' state specifically, NOT
            # merely "not active": the unit is legitimately 'activating' for
            # as long as ExecStartPre (llm-runtime-wait) is still blocking on
            # the runtime container, and treating that normal, transient
            # state as a crash turned every cold start into a coin flip -
            # whichever the very first poll (a few milliseconds after
            # 'systemctl start --no-block' returns) happened to win the race
            # against ExecStartPre finishing. Losing the race made us stop
            # the still-starting unit ourselves, which is what sent
            # ExecStartPre the SIGINT ('code=killed, signal=INT' in the
            # journal) that then looked like the mysterious failure.
            if self._node_of(model) != "peer":
                _, out = systemctl("is-active", self._unit(model))
                state = out.strip().splitlines()[0] if out.strip() else ""
                if state == "failed":
                    return False
            time.sleep(2)
        return None

    # ------------------------------------------------------------ requests
    def _touch_used(self, model):
        """Stamp a pulled model's on-disk LRU marker with the current time, so
        'llm-model gc' reclaims the genuinely stale downloads first. A no-op for
        models not managed by 'pull' (they have no pulled/ directory)."""
        d = os.path.join(PULLED_DIR, model.name)
        if not os.path.isdir(d):
            return
        try:
            with open(os.path.join(d, ".last_used"), "a"):
                os.utime(os.path.join(d, ".last_used"), None)
        except OSError:
            pass

    def _grant(self, model):
        """Hand out a lease for a ready model. Caller must hold self.lock."""
        lease = uuid.uuid4().hex
        model.leases.add(lease)
        model.last_used = time.time()
        self._touch_used(model)
        self.leases[lease] = model.name
        self.lease_born[lease] = model.last_used
        return lease

    def acquire(self, name):
        with self.lock:
            model = self.models.get(name)
            if model is None:
                return 404, {"error": {"message": "unknown model %r" % name,
                                       "type": "invalid_request_error",
                                       "param": "model", "code": "model_not_found"}}
            if model.state == "ready":
                lease = self._grant(model)
                return 200, {"lease": lease, "backend": model.backend,
                             "served_name": model.served_name, "model": model.name,
                             "cold_start": False}

        # Cold path. One at a time, so two simultaneous first requests for
        # different models cannot both decide there is room for them.
        with self.admission:
            with self.lock:
                model = self.models.get(name)
                if model is None:
                    return 404, {"error": {"message": "unknown model %r" % name,
                                           "type": "invalid_request_error",
                                           "param": "model", "code": "model_not_found"}}
                if model.state == "ready":
                    lease = self._grant(model)
                    return 200, {"lease": lease, "backend": model.backend,
                                 "served_name": model.served_name,
                                 "model": model.name, "cold_start": False}
                self._operation(model, "admitting", reset=True)
                if model.placement == "auto" and not model.current_node:
                    model.current_node = self._choose_node(model)
                needs_room = not self._fits(model)

            # Eviction talks to the peer over HTTP and to systemd, so it runs
            # WITHOUT the model-table lock held: a peer that has gone away must
            # not be able to freeze /release and /catalog for a whole minute.
            # self.admission still serialises us against other cold starts.
            if needs_room and not self._make_room(model):
                log("no capacity for %s (needs %.0f GiB on %s)"
                    % (model.name, model.budget, "+".join(model.nodes)))
                if model.placement == "auto":
                    model.current_node = None    # let the next attempt re-pick
                self._operation_failed(model, "cluster memory is currently in active use")
                return 409, CAPACITY_ERROR

            # The ledger says it fits; now confirm the HARDWARE agrees. On a
            # unified-memory APU the real ceiling is physical RAM, and a load the
            # box cannot survive freezes it (this is what took mighty-ai1 down).
            # Evict idle models until the live gate passes, and refuse rather
            # than start a load that would breach the reserve floor.
            if not self._free_memory_for(model):
                _, why = self._mem_ok(model)
                distributed_ok = False
                distributed_detail = ""
                if model.placement == "auto":
                    distributed_ok, distributed_detail = self._try_distributed(
                        model, why)
                if not distributed_ok:
                    detail = why
                    if distributed_detail:
                        detail += "; " + distributed_detail
                    log("memory gate refused %s: %s" % (model.name, detail))
                    if model.placement == "auto":
                        model.current_node = None
                    self._operation_failed(model, detail)
                    return 409, CAPACITY_ERROR

            with self.lock:
                if model.state == "ready":
                    # Someone else finished loading it while we were evicting.
                    lease = self._grant(model)
                    return 200, {"lease": lease, "backend": model.backend,
                                 "served_name": model.served_name,
                                 "model": model.name, "cold_start": False}
                if not self._fits(model):
                    log("no capacity for %s (needs %.0f GiB on %s)"
                        % (model.name, model.budget, "+".join(model.nodes)))
                    if model.placement == "auto":
                        model.current_node = None    # let the next attempt re-pick
                    self._operation_failed(model, "cluster memory is currently in active use")
                    return 409, CAPACITY_ERROR
                model.state = "loading"
                model.operation_phase = "loading"
                model.last_error = ""

            placement_desc = ("auto->%s" % model.current_node) \
                if model.placement == "auto" else model.placement
            log("loading %s (%s, tp=%d, %.0f GiB)"
                % (model.name, placement_desc, model.tp, model.budget))
            # Snapshot free memory now (the gate just proved there is enough) so
            # the real footprint can be learned once the model is up.
            free_before = self._free_snapshot(model)
            started_ok = True
            try:
                rc, out = self._start_unit(model)
                if rc != 0:
                    started_ok = False
                    detail = out.strip().splitlines()[-1] if out.strip() else "systemctl failed"
            except Exception as exc:    # noqa: BLE001
                started_ok = False
                detail = str(exc)

            if started_ok:
                self._operation(model, "compiling")
                ready = self._wait_ready(model, time.time() + LOAD_TIMEOUT)
                started_ok = bool(ready)
                if ready is False:
                    detail = "vllm@%s.service failed while starting (check journalctl -u vllm@%s.service)" \
                              % (model.name, model.name)
                else:
                    detail = "vLLM did not become healthy within %ds" % int(LOAD_TIMEOUT)

            if not started_ok:
                with self.lock:
                    model.state = "stopping"
                    model.operation_phase = "stopping"
                    model.last_error = detail
                    operation_started = model.operation_started
                log("failed to load %s: %s" % (model.name, detail))
                self._stop_unit(model)          # unlocked: may talk to the peer
                with self.lock:
                    model.state = "failed"
                    model.operation_phase = "failed"
                    model.operation_started = operation_started
                    model.last_error = detail
                    model.operation_finished = time.time()
                return 503, {"error": {
                    "message": "[model_load_failed] %s could not be started: %s"
                               % (model.name, detail),
                    "type": "cluster_backend_error",
                    "param": "model", "code": "model_load_failed"}}
            self._learn_budget(model, free_before)   # measure the real footprint
            with self.lock:
                model.state = "ready"
                model.operation_phase = "ready"
                model.loaded_at = time.time()
                model.operation_finished = time.time()
                lease = self._grant(model)
                log("%s is ready on %s" % (model.name, model.backend))
                return 200, {"lease": lease, "backend": model.backend,
                             "served_name": model.served_name, "model": model.name,
                             "cold_start": True}

    def release(self, lease):
        with self.lock:
            name = self.leases.pop(lease, None)
            self.lease_born.pop(lease, None)
            if name is None:
                return 200, {"released": False}
            model = self.models.get(name)
            if model is not None:
                model.leases.discard(lease)
                model.last_used = time.time()
            return 200, {"released": True, "model": name}

    def _expire_leases(self, now):
        """Reclaim leases whose holder died without releasing them.

        A lease older than LEASE_TTL is *probably* leaked, but it could also be
        one very long generation, so any model whose backend still reports work
        in flight is left alone - reclaiming its lease would let an operator
        force-unload it mid-stream.
        """
        if LEASE_TTL <= 0:
            return 0
        with self.lock:
            old = [(l, self.leases.get(l)) for l, born in self.lease_born.items()
                   if now - born > LEASE_TTL]
        if not old:
            return 0
        # The /metrics probe is a network call: keep it out of the lock.
        busy = set()
        for name in set(n for _, n in old if n):
            model = self.models.get(name)
            if model is not None and self._inflight(model):
                busy.add(name)
        with self.lock:
            dead = 0
            for lease, name in old:
                if name in busy or lease not in self.lease_born:
                    continue
                self.leases.pop(lease, None)
                self.lease_born.pop(lease, None)
                model = self.models.get(name) if name else None
                if model is not None:
                    model.leases.discard(lease)
                    model.last_used = time.time()
                dead += 1
            return dead

    def unload(self, name, force=False):
        with self.lock:
            model = self.models.get(name)
            if model is None:
                return 404, {"error": "unknown model %r" % name}
            if model.leases and not force:
                return 409, {"error": "%s has %d active lease(s)" % (name, len(model.leases))}
            self._operation(model, "stopping", state="stopping", reset=True)
        # Stopping a peer-resident model is an HTTP call to the other box; do it
        # with the table unlocked so an unresponsive peer cannot wedge the daemon.
        self._stop_unit(model)
        return 200, {"unloaded": name}

    # ------------------------------------------------------- catalog CRUD
    # These back the gateway's /cluster/models/add and /cluster/models/delete
    # (in turn the dashboard's Add/Delete forms). Both just shell out to the
    # real 'llm-model' CLI -- the same one an operator runs over SSH -- so
    # name validation, port picking, budget defaulting and the distributed
    # auto-placement math all come from exactly one implementation. residencyd
    # runs this as root with no sandboxing, so the subprocess inherits full
    # access to the catalog directory the same way residencyd's own
    # _patch_conf_fields already does.
    def add_model(self, fields):
        name = fields.get("name")
        if not isinstance(name, str) or not NAME_RE.match(name):
            return 400, {"error": "a valid 'name' is required"}
        path = fields.get("path")
        if not isinstance(path, str) or not path:
            return 400, {"error": "'path' is required"}
        if os.path.exists(os.path.join(CATALOG_DIR, name + ".conf")):
            return 409, {"error": "a model named %r already exists" % name}
        argv = [MODEL_CLI, "add", "--name", name, "--path", path]
        _cli_arg(argv, "--served-name", fields.get("served_name"))
        _cli_arg(argv, "--placement", fields.get("placement"))
        _cli_arg(argv, "--tp", fields.get("tp"))
        _cli_arg(argv, "--pp", fields.get("pp"))
        _cli_arg(argv, "--budget-gib", fields.get("budget_gib"))
        _cli_arg(argv, "--max-len", fields.get("max_len"))
        _cli_arg(argv, "--port", fields.get("port"))
        _cli_arg(argv, "--gpu-util", fields.get("gpu_util"))
        _cli_arg(argv, "--quantization", fields.get("quantization"))
        _cli_arg(argv, "--tool-parser", fields.get("tool_parser"))
        _cli_arg(argv, "--reasoning-parser", fields.get("reasoning_parser"))
        _cli_arg(argv, "--extra", fields.get("extra"))
        if fields.get("enforce_eager"):
            argv.append("--enforce-eager")
        if fields.get("keep_warm"):
            argv.append("--keep-warm")
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        except Exception as exc:                   # noqa: BLE001
            return 500, {"error": "could not run 'llm-model add': %s" % exc}
        if proc.returncode != 0:
            return 400, {"error": (proc.stderr or proc.stdout or
                                   "llm-model add failed").strip()}
        self.load_catalog()
        return 200, {"added": name, "detail": proc.stdout.strip()}

    def delete_model(self, name):
        if not isinstance(name, str) or not NAME_RE.match(name):
            return 400, {"error": "a valid 'name' is required"}
        if not os.path.exists(os.path.join(CATALOG_DIR, name + ".conf")):
            return 404, {"error": "no such model: %r" % name}
        with self.lock:
            model = self.models.get(name)
            if model is not None:
                self._operation(model, "stopping" if model.resident else "deleting",
                                state="stopping" if model.resident else None,
                                reset=True)
        try:
            proc = subprocess.run([MODEL_CLI, "remove", name],
                                  capture_output=True, text=True, timeout=30)
        except Exception as exc:                   # noqa: BLE001
            if model is not None:
                self._operation_failed(model, "could not run 'llm-model remove': %s" % exc)
            return 500, {"error": "could not run 'llm-model remove': %s" % exc}
        if proc.returncode != 0:
            if model is not None:
                self._operation_failed(
                    model, (proc.stderr or proc.stdout or
                            "llm-model remove failed").strip())
            return 400, {"error": (proc.stderr or proc.stdout or
                                   "llm-model remove failed").strip()}
        self.load_catalog()
        return 200, {"removed": name, "detail": proc.stdout.strip()}

    def edit_model(self, fields):
        """Back the dashboard's per-model Save button. Shells out to the real
        'llm-model set' -- the same validation and auto-distribute self-heal
        'add' runs -- so an edit that pushes a model past this node's budget
        gets upgraded to distributed placement exactly like a hand-added model
        would, instead of silently writing a .conf residencyd can never admit."""
        name = fields.get("name")
        if not isinstance(name, str) or not NAME_RE.match(name):
            return 400, {"error": "a valid 'name' is required"}
        if not os.path.exists(os.path.join(CATALOG_DIR, name + ".conf")):
            return 404, {"error": "no such model: %r" % name}
        argv = [MODEL_CLI, "set", name]
        _cli_arg(argv, "--path", fields.get("path"))
        _cli_arg(argv, "--served-name", fields.get("served_name"))
        _cli_arg(argv, "--placement", fields.get("placement"))
        _cli_arg(argv, "--tp", fields.get("tp"))
        _cli_arg(argv, "--pp", fields.get("pp"))
        _cli_arg(argv, "--budget-gib", fields.get("budget_gib"))
        _cli_arg(argv, "--max-len", fields.get("max_len"))
        _cli_arg(argv, "--port", fields.get("port"))
        _cli_arg(argv, "--gpu-util", fields.get("gpu_util"))
        _cli_arg(argv, "--quantization", fields.get("quantization"))
        _cli_arg(argv, "--tool-parser", fields.get("tool_parser"))
        _cli_arg(argv, "--reasoning-parser", fields.get("reasoning_parser"))
        _cli_arg(argv, "--extra", fields.get("extra"))
        if "enforce_eager" in fields:
            argv.append("--enforce-eager" if fields.get("enforce_eager") else "--no-enforce-eager")
        if "keep_warm" in fields:
            argv.append("--keep-warm" if fields.get("keep_warm") else "--no-keep-warm")
        if "enabled" in fields:
            argv.append("--enable" if fields.get("enabled") else "--disable")
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        except Exception as exc:                   # noqa: BLE001
            return 500, {"error": "could not run 'llm-model set': %s" % exc}
        if proc.returncode != 0:
            return 400, {"error": (proc.stderr or proc.stdout or
                                   "llm-model set failed").strip()}
        self.load_catalog()
        return 200, {"updated": name, "detail": proc.stdout.strip()}

    def model_conf(self, name):
        """Raw .conf key/values for the dashboard's editable-fields form.
        Fields like quantization/tool-parser/extra-args are startup args the
        systemd unit reads straight from the .conf and never enter residencyd's
        own Model object (they do not affect admission math) -- read_env_file
        (already used to parse runtime.env/cluster.env) hands them back exactly
        as written, with no separate parser to keep in sync."""
        if not isinstance(name, str) or not NAME_RE.match(name):
            return 400, {"error": "a valid 'name' is required"}
        path = os.path.join(CATALOG_DIR, name + ".conf")
        if not os.path.isfile(path):
            return 404, {"error": "no such model: %r" % name}
        return 200, read_env_file(path)

    def force_load(self, name):
        """Back the dashboard's per-model Force-load button. Reuses
        acquire()/release() rather than any new admission logic, so node
        choice, eviction-for-room, the live memory gate and budget learning
        all run exactly as they would for a real inference request; releasing
        immediately leaves the model at zero active leases, still eligible for
        normal idle eviction."""
        if not isinstance(name, str) or not NAME_RE.match(name):
            return 400, {"error": {"message": "a valid 'name' is required",
                                   "type": "invalid_request_error",
                                   "param": "name", "code": "invalid_model"}}
        code, payload = self.acquire(name)
        if code == 200 and payload.get("lease"):
            self.release(payload["lease"])
            return 200, {"loaded": name, "cold_start": payload.get("cold_start", False)}
        return code, payload

    def _clamp_minutes(self, minutes):
        try:
            return max(1, min(60, int(float(minutes))))
        except (TypeError, ValueError):
            return 5

    def _journal_tail(self, unit, minutes):
        try:
            proc = subprocess.run(
                ["journalctl", "-u", unit, "--since", "-%dmin" % minutes,
                 "--no-pager"],
                capture_output=True, text=True, timeout=15)
            return (proc.stdout or "") + (proc.stderr or "")
        except Exception as exc:                    # noqa: BLE001
            return "(could not read %s journal: %s)" % (unit, exc)

    def model_log(self, name, minutes=5):
        """Tail vllm@<name>.service on BOTH nodes and concatenate.
        current_node is cleared to None on every stop (see _stop_unit), so
        once an 'auto'-placement model is fully unloaded there is no reliable
        way to know which node it last ran on -- querying both is simpler and
        safer than guessing, and this is a manual, low-frequency, refresh-
        button action rather than a hot path."""
        if not isinstance(name, str) or not NAME_RE.match(name):
            return 400, {"error": "a valid 'name' is required"}
        with self.lock:
            known = name in self.models
        if not known:
            return 404, {"error": "no such model: %r" % name}
        mins = self._clamp_minutes(minutes)
        unit = "vllm@%s.service" % name
        local_log = self._journal_tail(unit, mins)
        try:
            data = http_json("http://%s:%d/logs?model=%s&minutes=%d"
                             % (PEER_IP, AGENT_PORT, name, mins), timeout=8)
            peer_log = data.get("log", "")
        except Exception as exc:                    # noqa: BLE001
            peer_log = "(peer unreachable: %s)" % exc
        text = ("--- server ---\n%s\n\n--- peer ---\n%s"
               % (local_log.strip() or "(no entries)", peer_log.strip() or "(no entries)"))
        return 200, {"name": name, "log": text[-40000:]}

    def model_progress(self, name, minutes=5):
        """Return a bounded live operation snapshot and the journals relevant
        to the selected model. The snapshot is lock-only; journal reads happen
        afterwards so progress polling never blocks catalog or lease updates."""
        if not isinstance(name, str) or not NAME_RE.match(name):
            return 400, {"error": "a valid 'name' is required"}
        with self.lock:
            model = self.models.get(name)
            if model is None:
                return 404, {"error": "no such model: %r" % name}
            info = model.public()
            placement = model.placement
            current_node = model.current_node
        mins = self._clamp_minutes(minutes)
        local_log = self._journal_tail("residencyd.service", mins)
        local_vllm = self._journal_tail("vllm@%s.service" % name, mins)
        peer_log = ""
        if placement in ("peer", "distributed") or current_node == "peer":
            try:
                data = http_json("http://%s:%d/logs?model=%s&minutes=%d"
                                 % (PEER_IP, AGENT_PORT, name, mins), timeout=8)
                peer_log = data.get("log", "")
            except Exception as exc:                # noqa: BLE001
                peer_log = "(peer unreachable: %s)" % exc
        text = ("--- residencyd.service ---\n%s\n\n"
                "--- server vllm@%s.service ---\n%s"
                % (local_log.strip() or "(no entries)", name,
                   local_vllm.strip() or "(no entries)"))
        if peer_log:
            text += "\n\n--- peer vllm@%s.service ---\n%s" % (
                name, peer_log.strip() or "(no entries)")
        info["log"] = text[-40000:]
        info["recent_log"] = info["log"]
        return 200, info

    # ------------------------------------------------------- model download
    # A Hugging Face/ModelScope pull happens as a transient systemd unit (see
    # PULL_UNIT above) so this request thread never blocks on the download
    # itself; the dashboard polls /models/pull/status and tails
    # /models/pull/log instead.
    def _pull_active(self):
        rc, _ = systemctl("is-active", "--quiet", PULL_UNIT)
        return rc == 0

    def start_pull(self, fields):
        if self._pull_active():
            return 409, {"error": "a download is already in progress; only one "
                                  "runs at a time -- check /models/pull/log or "
                                  "wait for it to finish before starting another"}
        source = fields.get("source")
        repo = fields.get("repo")
        if source not in ("hf", "ms"):
            return 400, {"error": "'source' must be 'hf' or 'ms'"}
        if not isinstance(repo, str) or not repo.strip():
            return 400, {"error": "'repo' is required"}
        repo = repo.strip()
        ref = "%s:%s" % (source, repo)
        pull_argv = [MODEL_CLI, "pull", ref]
        _cli_arg(pull_argv, "--name", fields.get("name"))
        _cli_arg(pull_argv, "--placement", fields.get("placement"))
        _cli_arg(pull_argv, "--max-len", fields.get("max_len"))
        _cli_arg(pull_argv, "--revision", fields.get("revision"))
        if fields.get("no_parser"):
            pull_argv.append("--no-parser")
        if fields.get("keep_warm"):
            pull_argv.append("--keep-warm")

        # 'pull' derives tp/pp/budget/port/gpu-util/quantization/parsers/extra
        # from the model's own config.json -- it does not accept overrides for
        # them. Apply any the caller gave as a follow-up 'llm-model set' once
        # the download's own 'add' has written the catalog entry, so a single
        # job still ends with exactly the catalog entry the operator asked for.
        name_for_set = fields.get("name") or _derive_name(repo)
        set_argv = [MODEL_CLI, "set", name_for_set]
        before = len(set_argv)
        _cli_arg(set_argv, "--tp", fields.get("tp"))
        _cli_arg(set_argv, "--pp", fields.get("pp"))
        _cli_arg(set_argv, "--budget-gib", fields.get("budget_gib"))
        _cli_arg(set_argv, "--port", fields.get("port"))
        _cli_arg(set_argv, "--gpu-util", fields.get("gpu_util"))
        _cli_arg(set_argv, "--quantization", fields.get("quantization"))
        _cli_arg(set_argv, "--tool-parser", fields.get("tool_parser"))
        _cli_arg(set_argv, "--reasoning-parser", fields.get("reasoning_parser"))
        _cli_arg(set_argv, "--extra", fields.get("extra"))
        if fields.get("enforce_eager"):
            set_argv.append("--enforce-eager")
        has_overrides = len(set_argv) > before or fields.get("enforce_eager")

        shell_cmd = " ".join(shlex.quote(a) for a in pull_argv)
        if has_overrides:
            shell_cmd += " && " + " ".join(shlex.quote(a) for a in set_argv)

        argv = ["systemd-run", "--unit=" + PULL_UNIT_NAME, "--collect",
               "/bin/bash", "-c", shell_cmd]
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=15)
        except Exception as exc:                    # noqa: BLE001
            return 500, {"error": "could not start download job: %s" % exc}
        if proc.returncode != 0:
            return 500, {"error": (proc.stderr or proc.stdout or
                                   "systemd-run failed").strip()}
        return 200, {"started": True, "repo": ref, "name": name_for_set}

    def pull_status(self):
        return {"active": self._pull_active()}

    def pull_log(self, minutes=5):
        mins = self._clamp_minutes(minutes)
        try:
            proc = subprocess.run(
                ["journalctl", "-u", PULL_UNIT, "--since", "-%dmin" % mins, "--no-pager"],
                capture_output=True, text=True, timeout=15)
            text = (proc.stdout or "") + (proc.stderr or "")
        except Exception as exc:                    # noqa: BLE001
            text = "(could not read journal: %s)" % exc
        return {"active": self._pull_active(),
               "log": text.strip()[-40000:] or "(no entries yet)"}

    def catalog(self):
        with self.lock:
            models = [m.public() for m in sorted(self.models.values(), key=lambda m: m.name)]
            nodes = {}
            for node in ("server", "peer"):
                used = self._used(node)
                cached = self._free_cache.get(node)
                nodes[node] = {"budget_gib": BUDGET_GIB, "used_gib": used,
                               "free_gib": max(0.0, BUDGET_GIB - used),
                               "mem_available_gib": cached[0] if cached else None}
        return {"object": "list", "data": models, "nodes": nodes,
                "idle_timeout_seconds": IDLE_TIMEOUT}

    # ------------------------------------------------------------- reaper
    def _reap_loop(self):
        while not self.stop_event.wait(30):
            try:
                now = time.time()
                # 1. Reclaim leases nobody will ever release (gateway killed).
                expired = self._expire_leases(now)
                if expired:
                    log("expired %d leaked lease(s) after %ds" % (expired, int(LEASE_TTL)))
                if IDLE_TIMEOUT <= 0:
                    continue
                # 2. Evict models that have been idle for too long.
                now = time.time()
                with self.lock:
                    stale = [m for m in self.models.values()
                             if m.state == "ready" and not m.leases
                             and not m.keep_warm
                             and now - m.last_used > IDLE_TIMEOUT]
                for model in stale:
                    # The /metrics probe is a network call: keep it unlocked.
                    if self._busy(model):
                        with self.lock:
                            model.last_used = time.time()
                        continue
                    with self.lock:
                        # Re-validate everything under the lock. Without this a
                        # request that arrived while we were probing would have
                        # its model stopped out from under it.
                        if model.state != "ready" or model.leases or \
                                time.time() - model.last_used <= IDLE_TIMEOUT:
                            continue
                        log("evicting %s after %ds idle" % (model.name, int(IDLE_TIMEOUT)))
                        model.state = "stopping"
                    self._stop_unit(model)
                # Relief valve: evict on any node whose live free memory has
                # crept below the critical floor, even if nothing is idle yet.
                self._relieve_pressure()
            except Exception as exc:    # noqa: BLE001 - the reaper must never die
                log("reaper error: %s" % exc)

    def shutdown(self):
        self.stop_event.set()


# --------------------------------------------------------------------------- HTTP

RES = None


class Handler(BaseHTTPRequestHandler):
    server_version = "residencyd/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):     # quieter journal
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
            self._send(200, {"status": "ok", "socket": SOCKET_PATH,
                             "budget_gib": BUDGET_GIB})
        elif path in ("/catalog", "/v1/models"):
            self._send(200, RES.catalog())
        elif path == "/models/conf":
            name = (params.get("name") or [""])[0]
            code, payload = RES.model_conf(name)
            self._send(code, payload)
        elif path == "/models/log":
            name = (params.get("name") or [""])[0]
            minutes = (params.get("minutes") or ["5"])[0]
            code, payload = RES.model_log(name, minutes)
            self._send(code, payload)
        elif path == "/models/progress":
            name = (params.get("name") or [""])[0]
            minutes = (params.get("minutes") or ["5"])[0]
            code, payload = RES.model_progress(name, minutes)
            self._send(code, payload)
        elif path == "/models/pull/status":
            self._send(200, RES.pull_status())
        elif path == "/models/pull/log":
            minutes = (params.get("minutes") or ["5"])[0]
            self._send(200, RES.pull_log(minutes))
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        body = self._body()
        if path == "/acquire":
            name = body.get("model")
            if not isinstance(name, str) or not NAME_RE.match(name):
                self._send(400, {"error": {"message": "a valid 'model' is required",
                                           "type": "invalid_request_error",
                                           "param": "model", "code": "invalid_model"}})
                return
            code, payload = RES.acquire(name)
            self._send(code, payload)
        elif path == "/release":
            code, payload = RES.release(body.get("lease", ""))
            self._send(code, payload)
        elif path == "/unload":
            code, payload = RES.unload(body.get("model", ""), bool(body.get("force")))
            self._send(code, payload)
        elif path == "/reload":
            RES.load_catalog()
            self._send(200, {"reloaded": True})
        elif path == "/models/add":
            code, payload = RES.add_model(body)
            self._send(code, payload)
        elif path == "/models/delete":
            code, payload = RES.delete_model(body.get("name", ""))
            self._send(code, payload)
        elif path == "/models/edit":
            code, payload = RES.edit_model(body)
            self._send(code, payload)
        elif path == "/models/load":
            code, payload = RES.force_load(body.get("name", ""))
            self._send(code, payload)
        elif path == "/models/pull":
            code, payload = RES.start_pull(body)
            self._send(code, payload)
        else:
            self._send(404, {"error": "not found"})


class UnixHTTPServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True
    # BaseHTTPRequestHandler expects a (host, port) tuple; a unix socket has no
    # peer address at all, so supply a stable placeholder.
    def get_request(self):
        conn, _ = self.socket.accept()
        return conn, ("local", 0)


def main():
    global RES
    os.umask(0o007)
    sock_dir = os.path.dirname(SOCKET_PATH)
    os.makedirs(sock_dir, mode=0o755, exist_ok=True)
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    RES = Residency()
    server = UnixHTTPServer(SOCKET_PATH, Handler)

    # root:llmgateway 0660 -- the gateway may talk to us, nothing else may, and
    # the socket is the ONLY interface. residencyd never listens on the network.
    try:
        import grp
        gid = grp.getgrnam(SOCKET_GROUP).gr_gid
        os.chown(SOCKET_PATH, 0, gid)
    except Exception as exc:            # noqa: BLE001
        log("could not chown the socket to group %s: %s" % (SOCKET_GROUP, exc))
    os.chmod(SOCKET_PATH, 0o660)

    def on_term(_signum, _frame):
        log("shutting down")
        RES.shutdown()
        threading.Thread(target=server.shutdown, daemon=True).start()

    def on_hup(_signum, _frame):
        log("SIGHUP: reloading the catalog")
        RES.load_catalog()

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    signal.signal(signal.SIGHUP, on_hup)

    log("listening on %s (budget %.0f GiB/node, idle timeout %ds)"
        % (SOCKET_PATH, BUDGET_GIB, int(IDLE_TIMEOUT)))
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        try:
            os.unlink(SOCKET_PATH)
        except OSError:
            pass


if __name__ == "__main__":
    main()

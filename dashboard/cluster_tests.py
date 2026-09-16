#!/usr/bin/env python3
"""On-demand verification tests for the Strix Halo cluster."""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
from statistics import median
import threading
import time
from concurrent.futures import (
    Future,
    ThreadPoolExecutor,
    TimeoutError as FutureTimeoutError,
)
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable
from uuid import uuid4
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

try:
    from .cluster_monitor import (
        collect_cluster_snapshots,
        http_json,
        http_post_json,
        local_tcp_listener,
        load_config,
        read_token,
        service_state,
    )
except ImportError:
    from cluster_monitor import (
        collect_cluster_snapshots,
        http_json,
        http_post_json,
        local_tcp_listener,
        load_config,
        read_token,
        service_state,
    )

try:
    from .token_metrics import (
        TokenMetric,
        TokenRateStore,
        metric_as_dict,
        metric_from_response,
    )
except ImportError:
    from token_metrics import (
        TokenMetric,
        TokenRateStore,
        metric_as_dict,
        metric_from_response,
    )


TARGET_PARALLEL_SLOTS = 3
TARGET_CONTEXT_TOKENS = 262144
DEFAULT_OUTPUT_TOKENS = 2048
DEFAULT_TEST_SAFETY_MARGIN = 96
DEFAULT_CAPACITY_INPUT_TOKENS = 65536
DEFAULT_CAPACITY_OUTPUT_TOKENS = 8192
DEFAULT_CAPACITY_PARALLEL_SLOTS = 1
DEFAULT_CAPACITY_REPETITIONS = 3
DEFAULT_CAPACITY_TIMEOUT_SECONDS = 3600.0
CAPACITY_TIMEOUT_SAFETY_FACTOR = 2.0


@dataclass
class TestResult:
    name: str
    ok: bool
    lines: list[str] = field(default_factory=list)
    details: dict[str, Any] = field(default_factory=dict)

    def render(self) -> str:
        header = f"{'PASS' if self.ok else 'FAIL'}: {self.name}"
        return "\n".join([header, *self.lines])


def _pass(result: TestResult, message: str) -> None:
    result.lines.append(f"[PASS] {message}")


def _fail(result: TestResult, message: str) -> None:
    result.ok = False
    result.lines.append(f"[FAIL] {message}")


def _warn(result: TestResult, message: str) -> None:
    result.lines.append(f"[WARN] {message}")


def _info(result: TestResult, message: str) -> None:
    result.lines.append(f"[INFO] {message}")


def _capacity_timeout(
    config: dict[str, Any],
    input_tokens: int,
    output_tokens: int,
    parallel_slots: int,
) -> float:
    configured = config.get("capacity_timeout")
    if configured is not None:
        return max(60.0, float(configured))

    workload_tokens = (input_tokens + output_tokens) * parallel_slots
    baseline_tokens = TARGET_CONTEXT_TOKENS * TARGET_PARALLEL_SLOTS
    scaled_timeout = (
        DEFAULT_CAPACITY_TIMEOUT_SECONDS
        * CAPACITY_TIMEOUT_SAFETY_FACTOR
        * workload_tokens
        / baseline_tokens
    )
    return max(DEFAULT_CAPACITY_TIMEOUT_SECONDS, scaled_timeout)


def _capacity_test_slots(
    slots_body: Any, target_parallel: int
) -> list[dict[str, Any]]:
    if not isinstance(slots_body, list):
        return []
    test_slot_ids = set(range(target_parallel))
    return [
        slot
        for slot in slots_body
        if isinstance(slot, dict) and slot.get("id") in test_slot_ids
    ]


def _progress(
    progress: Callable[..., Any] | None, value: float, description: str
) -> None:
    if progress is not None:
        progress(max(0.0, min(1.0, value)), desc=description)


def _rate_text(value: Any) -> str:
    if not isinstance(value, (int, float)):
        return "n/a"
    return f"{value:,.1f} tok/s"


def _token_context_label(tokens: int) -> str:
    if tokens % 1024 == 0:
        return f"{tokens // 1024}K"
    return f"{tokens:,}"


def _unit_text(unit: str) -> str | None:
    candidates = (
        Path("/etc/systemd/system") / unit,
        Path("/lib/systemd/system") / unit,
        Path("/usr/lib/systemd/system") / unit,
    )
    for path in candidates:
        try:
            return path.read_text(encoding="utf-8")
        except FileNotFoundError:
            continue
        except OSError:
            return None
    return None


def _flag_value(unit_text: str, flag: str) -> str | None:
    match = re.search(rf"(?:^|\s){re.escape(flag)}\s+(\S+)", unit_text)
    return match.group(1) if match else None


def _matches_float(value: str | None, expected: float) -> bool:
    try:
        return abs(float(value or "") - expected) < 1e-6
    except (TypeError, ValueError):
        return False


def _post_json(
    url: str, body: dict[str, Any], timeout: float
) -> tuple[int, Any]:
    request = Request(
        url,
        data=json.dumps(body, separators=(",", ":")).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            raw = response.read()
            try:
                return int(response.status), json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                return int(response.status), {"body": raw.decode(errors="replace")}
    except HTTPError as exc:
        try:
            raw = exc.read()
        except OSError:
            raw = b""
        try:
            parsed: Any = json.loads(raw.decode("utf-8")) if raw else {}
        except (UnicodeDecodeError, json.JSONDecodeError):
            parsed = {"body": raw.decode(errors="replace")}
        if isinstance(parsed, dict):
            parsed.setdefault("error", f"HTTP {exc.code}")
        return int(exc.code), parsed
    except (OSError, TimeoutError, URLError) as exc:
        return 0, {"error": str(exc)}


def configuration_test(
    config: dict[str, Any],
    cancel_event: threading.Event | None = None,
    progress: Callable[..., Any] | None = None,
) -> TestResult:
    result = TestResult("Effective Qwen configuration", True)
    _progress(progress, 0.05, "Configuration: reading installed Qwen settings")
    if cancel_event and cancel_event.is_set():
        _warn(result, "test cancelled before starting")
        result.ok = False
        return result
    expected_slots = int(config.get("expected_parallel_slots", TARGET_PARALLEL_SLOTS))
    expected_context = int(
        config.get("expected_context_per_slot", TARGET_CONTEXT_TOKENS)
    )
    native_context = int(
        config.get("native_context_per_slot", TARGET_CONTEXT_TOKENS)
    )
    if native_context < 1:
        native_context = TARGET_CONTEXT_TOKENS
    requires_yarn = expected_context > native_context
    expected_yarn_scale = expected_context / native_context
    env_path = Path("/etc/qwen3d8/cluster.env")

    try:
        env_lines = env_path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        _fail(result, f"{env_path} is unavailable: {exc}")
        return result

    env: dict[str, str] = {}
    for line in env_lines:
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip()

    if "Q4" in env.get("MODEL_QUANT", "").upper():
        _pass(result, f"Q4 model selected: {env.get('MODEL_QUANT')}")
    else:
        _fail(result, f"expected a Q4 model, found {env.get('MODEL_QUANT', 'unset')}")

    actual_slots = env.get("PARALLEL_SLOTS")
    if actual_slots == str(expected_slots):
        _pass(result, f"cluster.env declares {actual_slots} parallel slots")
    else:
        _fail(
            result,
            f"cluster.env declares {actual_slots or 'unset'} slots; expected {expected_slots}",
        )

    actual_context = env.get("CONTEXT_PER_SLOT")
    if actual_context == str(expected_context):
        _pass(result, f"cluster.env declares {actual_context} tokens per slot")
    else:
        _fail(
            result,
            "cluster.env declares "
            f"{actual_context or 'unset'} tokens per slot; expected {expected_context}",
        )

    if requires_yarn:
        expected_override = f"qwen4exp.context_length=int:{expected_context}"
        if (
            env.get("NATIVE_CONTEXT_PER_SLOT") == str(native_context)
            and env.get("CONTEXT_SCALING", "").lower() == "yarn"
            and _matches_float(env.get("YARN_ROPE_SCALE"), expected_yarn_scale)
            and env.get("YARN_MODEL_CONTEXT_OVERRIDE") == expected_override
        ):
            _pass(
                result,
                f"cluster.env enables YaRN {expected_yarn_scale:g}x from "
                f"{native_context} tokens",
            )
        else:
            _fail(
                result,
                "cluster.env YaRN settings are invalid; expected "
                f"scale={expected_yarn_scale:g}, native={native_context}, "
                f"override={expected_override}",
            )

    service_name = (
        "qwen3d8-server.service"
        if env.get("NODE_ROLE", config.get("role")) == "server"
        else "qwen3d8-rpc.service"
    )
    state = service_state(service_name)
    if state.get("active"):
        _pass(result, f"{service_name} is active")
    else:
        _fail(result, f"{service_name} is {state.get('state', 'unknown')}")

    unit_text = _unit_text(service_name)
    if unit_text is None:
        _fail(result, f"unit definition is unavailable: {service_name}")
        return result

    if service_name == "qwen3d8-server.service":
        _progress(progress, 0.35, "Configuration: checking llama-server")
        unit_slots = _flag_value(unit_text, "--parallel")
        unit_context = _flag_value(unit_text, "--kv-unified-per-slot")
        if unit_slots == str(expected_slots):
            _pass(result, f"systemd starts llama-server with --parallel {unit_slots}")
        else:
            _fail(
                result,
                f"systemd uses --parallel {unit_slots or 'unset'}; expected {expected_slots}",
            )
        if unit_context == str(expected_context):
            _pass(
                result,
                "systemd starts llama-server with "
                f"--kv-unified-per-slot {unit_context}",
            )
        else:
            _fail(
                result,
                "systemd uses "
                f"--kv-unified-per-slot {unit_context or 'unset'}; "
                f"expected {expected_context}",
            )
        if requires_yarn:
            expected_override = f"qwen4exp.context_length=int:{expected_context}"
            unit_scaling = _flag_value(unit_text, "--rope-scaling")
            unit_scale = _flag_value(unit_text, "--rope-scale")
            unit_origin = _flag_value(unit_text, "--yarn-orig-ctx")
            unit_override = _flag_value(unit_text, "--override-kv")
            if (
                unit_scaling == "yarn"
                and _matches_float(unit_scale, expected_yarn_scale)
                and unit_origin == str(native_context)
                and unit_override == expected_override
            ):
                _pass(
                    result,
                    f"systemd enables YaRN {expected_yarn_scale:g}x and "
                    "overrides the model context limit",
                )
            else:
                _fail(
                    result,
                    "systemd YaRN settings are invalid; expected "
                    f"--rope-scaling yarn --rope-scale {expected_yarn_scale:g} "
                    f"--yarn-orig-ctx {native_context} --override-kv "
                    f"{expected_override}",
                )

        base_url = str(config.get("llama_url", "")).rstrip("/")
        health_status, health_body = http_json(f"{base_url}/health", timeout=5)
        if health_status == 200:
            _pass(result, "llama-server health endpoint reports ready")
        else:
            _fail(result, f"llama-server health returned {health_status}: {health_body}")

        props_status, props_body = http_json(f"{base_url}/props", timeout=5)
        if props_status == 200 and isinstance(props_body, dict):
            runtime_slots = props_body.get("total_slots")
            if runtime_slots == expected_slots:
                _pass(result, f"runtime reports total_slots={runtime_slots}")
            else:
                _fail(
                    result,
                    f"runtime reports total_slots={runtime_slots}; expected {expected_slots}",
                )
        else:
            _fail(result, f"could not read /props: {props_body}")

        slots_status, slots_body = http_json(f"{base_url}/slots", timeout=5)
        if slots_status == 200 and isinstance(slots_body, list):
            contexts = [
                slot.get("n_ctx")
                for slot in slots_body
                if isinstance(slot, dict)
            ]
            if len(slots_body) == expected_slots and len(contexts) == len(slots_body) and all(
                value == expected_context for value in contexts
            ):
                _pass(
                    result,
                    f"runtime exposes {len(slots_body)} slots at {expected_context} tokens each",
                )
            else:
                _fail(
                    result,
                    f"runtime slot contexts are {contexts}; "
                    f"expected {expected_slots} x {expected_context}",
                )
        else:
            _fail(result, f"could not read /slots: {slots_body}")
    else:
        local_ip = str(config.get("local_ip", ""))
        rpc_port = int(config.get("rpc_port", 50053))
        listening, error = local_tcp_listener(local_ip, rpc_port)
        if listening:
            _pass(result, f"RPC worker listens on {local_ip}:{rpc_port}")
        else:
            _fail(
                result,
                f"RPC worker listener {local_ip}:{rpc_port} is unavailable: {error}",
            )

    result.details = {
        "expected_parallel_slots": expected_slots,
        "expected_context_per_slot": expected_context,
        "native_context_per_slot": native_context,
        "requires_yarn": requires_yarn,
        "environment": env,
    }
    _progress(progress, 1.0, "Configuration: complete")
    return result


def runtime_health_test(
    config: dict[str, Any],
    cancel_event: threading.Event | None = None,
    progress: Callable[..., Any] | None = None,
) -> TestResult:
    result = TestResult("Cluster runtime health", True)
    _progress(progress, 0.05, "Runtime health: collecting controller and worker telemetry")
    if cancel_event and cancel_event.is_set():
        _warn(result, "test cancelled before starting")
        result.ok = False
        return result
    cluster, errors = collect_cluster_snapshots(config)
    if cancel_event and cancel_event.is_set():
        _warn(result, "test cancelled after telemetry collection")
        result.ok = False
    result.details = cluster

    if cluster.get("status") == "healthy":
        _pass(result, "controller and worker snapshots report healthy")
    else:
        _fail(result, "cluster snapshot is degraded")
    for error in errors:
        _fail(result, error)

    nodes = cluster.get("nodes", [])
    if not isinstance(nodes, list):
        _fail(result, "cluster snapshot returned a non-list nodes field")
        return result
    for node in nodes:
        if not isinstance(node, dict):
            _fail(result, f"cluster snapshot contained an invalid node: {node!r}")
            continue
        hostname = node.get("hostname", "unknown")
        memory = node.get("memory", {})
        if not isinstance(memory, dict):
            memory = {}
        available = memory.get("available_bytes")
        if node.get("status") == "healthy":
            _pass(
                result,
                f"{hostname}: RAM available="
                f"{available if available is not None else 'n/a'} bytes, "
                f"status={node.get('status', 'unknown')}",
            )
        else:
            _fail(result, f"{hostname}: status={node.get('status', 'unknown')}")
    _progress(progress, 1.0, "Runtime health: complete")
    return result


def capacity_test(
    config: dict[str, Any],
    context_tokens: int | None = None,
    input_tokens: int | None = None,
    output_tokens: int | None = None,
    parallel: int | None = None,
    cancel_event: threading.Event | None = None,
    progress: Callable[..., Any] | None = None,
    record_metrics: bool = True,
) -> TestResult:
    base_url = str(config.get("llama_url", "")).rstrip("/")
    output_tokens = int(
        output_tokens
        if output_tokens is not None
        else config.get(
            "capacity_test_output_tokens", DEFAULT_CAPACITY_OUTPUT_TOKENS
        )
    )
    target_parallel = int(
        parallel
        if parallel is not None
        else config.get(
            "capacity_test_parallel_slots", DEFAULT_CAPACITY_PARALLEL_SLOTS
        )
    )
    safety_margin = int(
        config.get("capacity_test_safety_margin_tokens", DEFAULT_TEST_SAFETY_MARGIN)
    )
    configured_input = config.get("capacity_test_input_tokens")
    if input_tokens is None and context_tokens is None and configured_input is not None:
        input_tokens = int(configured_input)
    target_context = int(
        context_tokens
        if context_tokens is not None
        else config.get("capacity_test_context_tokens", 0)
    )
    if target_context <= 0:
        target_context = (
            (input_tokens if input_tokens is not None else DEFAULT_CAPACITY_INPUT_TOKENS)
            + output_tokens
            + safety_margin
        )
    result = TestResult(
        f"Capacity test ({_token_context_label(target_context)} per slot, "
        f"{target_parallel} slots)",
        True,
    )
    if cancel_event and cancel_event.is_set():
        _warn(result, "test cancelled before starting")
        result.ok = False
        return result
    _progress(
        progress,
        0.03,
        f"Capacity: preparing {target_parallel} slots at "
        f"{_token_context_label(target_context)} each",
    )
    if target_parallel < 1:
        _fail(result, f"parallel slot count must be positive, got {target_parallel}")
        return result
    if target_context < 1:
        _fail(result, f"context token count must be positive, got {target_context}")
        return result
    if output_tokens < 0:
        _fail(result, f"output token count must not be negative, got {output_tokens}")
        return result
    if input_tokens is None:
        input_tokens = target_context - output_tokens - safety_margin
    if input_tokens <= 0 or input_tokens + output_tokens > target_context:
        _fail(
            result,
            f"input/output token budget {input_tokens}+{output_tokens} exceeds "
            f"the {target_context}-token slot limit",
        )
        return result

    request_timeout = _capacity_timeout(
        config,
        input_tokens,
        output_tokens,
        target_parallel,
    )
    health_status, health_body = http_json(f"{base_url}/health", timeout=5)
    if health_status != 200:
        _fail(result, f"llama-server is not ready: {health_status} {health_body}")
        return result
    _progress(progress, 0.12, "Capacity: llama-server is ready; submitting requests")

    token_ids = [100 + (index % 9900) for index in range(input_tokens)]
    payloads = [
        {
            "prompt": token_ids,
            "id_slot": slot,
            "n_predict": output_tokens,
            "ignore_eos": True,
            "cache_prompt": False,
            "stream": False,
            "temperature": 0,
            "return_tokens": True,
        }
        for slot in range(target_parallel)
    ]
    barrier = threading.Barrier(target_parallel + 1)
    def submit(slot: int) -> tuple[int, int, Any, float]:
        barrier.wait()
        if cancel_event and cancel_event.is_set():
            return slot, 499, {"error": "test cancelled"}, 0.0
        started = time.monotonic()
        status, body = _post_json(
            f"{base_url}/completion", payloads[slot], request_timeout
        )
        return slot, status, body, time.monotonic() - started

    executor = ThreadPoolExecutor(max_workers=target_parallel)
    futures: list[Future[tuple[int, int, Any, float]]] = [
        executor.submit(submit, slot) for slot in range(target_parallel)
    ]
    test_started = time.monotonic()
    barrier.wait()

    maximum_active = 0
    observed_contexts: list[int] = []
    timed_out = False
    cancelled = False
    deadline = time.monotonic() + request_timeout + 10
    try:
        while not all(future.done() for future in futures):
            if cancel_event and cancel_event.is_set():
                cancelled = True
                _warn(result, "cancellation requested")
                break
            slots_status, slots_body = http_json(f"{base_url}/slots", timeout=5)
            if slots_status == 200 and isinstance(slots_body, list):
                test_slots = _capacity_test_slots(slots_body, target_parallel)
                active = sum(
                    1
                    for slot in test_slots
                    if slot.get("is_processing")
                )
                maximum_active = max(maximum_active, active)
                observed_contexts = [
                    int(slot["n_ctx"])
                    for slot in test_slots
                    if isinstance(slot.get("n_ctx"), int)
                ]
                elapsed = time.monotonic() - test_started
                _progress(
                    progress,
                    0.15 + min(0.65, elapsed / max(request_timeout, 1.0) * 0.65),
                    f"Capacity: {active}/{target_parallel} slots active; "
                    f"{elapsed:.0f}s elapsed",
                )
            if time.monotonic() > deadline:
                _fail(result, "capacity test exceeded its timeout")
                timed_out = True
                break
            time.sleep(0.25)
    finally:
        results: list[tuple[int, int, Any, float]] = []
        for future in futures:
            if not future.done():
                future.cancel()
                results.append((-1, 0, {"error": "request timed out"}, 0.0))
                continue
            try:
                results.append(future.result(timeout=5))
            except (
                FutureTimeoutError,
                OSError,
                RuntimeError,
                ValueError,
                threading.BrokenBarrierError,
            ) as exc:
                results.append((-1, 0, {"error": str(exc)}, 0.0))
        executor.shutdown(
            wait=not (timed_out or cancelled), cancel_futures=True
        )

    if cancelled:
        result.ok = False
        result.details = {
            "cancelled": True,
            "target_context": target_context,
            "parallel": target_parallel,
        }
        return result

    if maximum_active >= target_parallel:
        _pass(result, f"observed {maximum_active} active inference slots concurrently")
    else:
        _fail(
            result,
            f"observed at most {maximum_active} active slots; expected {target_parallel}",
        )

    if observed_contexts and all(
        context >= target_context for context in observed_contexts
    ):
        _pass(result, f"runtime slots provide at least {target_context} tokens each")
    elif observed_contexts:
        _fail(
            result,
            f"runtime slot contexts were {observed_contexts}; expected {target_context}",
        )
    else:
        _warn(result, "could not sample /slots while requests were active")

    run_id = uuid4().hex
    token_metrics = []
    for slot, status, body, elapsed in sorted(results, key=lambda item: item[0]):
        if status != 200 or not isinstance(body, dict) or "error" in body:
            _fail(result, f"slot {slot} returned HTTP {status}: {body}")
            continue
        tokens_evaluated = body.get("tokens_evaluated")
        truncated = body.get("truncated")
        if isinstance(tokens_evaluated, int) and tokens_evaluated < input_tokens:
            _fail(
                result,
                f"slot {slot} evaluated {tokens_evaluated} tokens; "
                f"expected at least {input_tokens}",
            )
        elif isinstance(tokens_evaluated, int):
            _pass(
                result,
                f"slot {slot} accepted the prompt and evaluated {tokens_evaluated} tokens",
            )
        else:
            _pass(result, f"slot {slot} completed with HTTP 200")
        if truncated is True:
            _fail(result, f"slot {slot} reported context truncation")

        metric = metric_from_response(
            body,
            run_id=run_id,
            test_name=result.name,
            slot_id=slot,
            wall_seconds=elapsed,
            expected_prompt_tokens=input_tokens,
            expected_output_tokens=output_tokens,
            context_tokens=target_context,
            parallel_slots=target_parallel,
        )
        token_metrics.append(metric)
        estimate_suffix = " (estimated)" if metric.estimated else ""
        _info(
            result,
            f"slot {slot}: prompt {_rate_text(metric.prompt_tokens_per_second)}, "
            f"generation {_rate_text(metric.generation_tokens_per_second)}, "
            f"total {_rate_text(metric.total_tokens_per_second)}{estimate_suffix}",
        )

    test_wall_seconds = time.monotonic() - test_started
    prompt_tokens_total = sum(
        metric.prompt_tokens or 0 for metric in token_metrics
    )
    generated_tokens_total = sum(
        metric.generated_tokens or 0 for metric in token_metrics
    )
    prompt_seconds_total = sum(
        metric.prompt_seconds or 0 for metric in token_metrics
    )
    generation_seconds_total = sum(
        metric.generation_seconds or 0 for metric in token_metrics
    )
    aggregate_rates = {
        "prompt_tokens": prompt_tokens_total,
        "generated_tokens": generated_tokens_total,
        "prompt_tokens_per_second": (
            prompt_tokens_total / prompt_seconds_total
            if prompt_seconds_total > 0
            else None
        ),
        "generation_tokens_per_second": (
            generated_tokens_total / generation_seconds_total
            if generation_seconds_total > 0
            else None
        ),
        "aggregate_tokens_per_second": (
            (prompt_tokens_total + generated_tokens_total) / test_wall_seconds
            if test_wall_seconds > 0
            else None
        ),
        "wall_seconds": test_wall_seconds,
    }
    _info(
        result,
        "aggregate: prompt "
        f"{_rate_text(aggregate_rates['prompt_tokens_per_second'])}, "
        "generation "
        f"{_rate_text(aggregate_rates['generation_tokens_per_second'])}, "
        "wall-throughput "
        f"{_rate_text(aggregate_rates['aggregate_tokens_per_second'])}",
    )
    _progress(progress, 1.0, "Capacity: complete")

    result.details = {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "target_context": target_context,
        "parallel": target_parallel,
        "safety_margin_tokens": safety_margin,
        "parameters": {
            "context_tokens": target_context,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "parallel_slots": target_parallel,
            "safety_margin_tokens": safety_margin,
            "timeout_seconds": request_timeout,
        },
        "maximum_active_slots": maximum_active,
        "observed_contexts": observed_contexts,
        "token_metrics": [metric_as_dict(metric) for metric in token_metrics],
        "token_rate_summary": aggregate_rates,
    }
    metrics_db = str(config.get("metrics_db", ""))
    if record_metrics and metrics_db and token_metrics:
        try:
            TokenRateStore(metrics_db).record_run(
                token_metrics,
                test_name=result.name,
                context_tokens=target_context,
                parallel_slots=target_parallel,
                wall_seconds=test_wall_seconds,
                success=result.ok,
                details={
                    **aggregate_rates,
                    "parameters": {
                        "context_tokens": target_context,
                        "input_tokens": input_tokens,
                        "output_tokens": output_tokens,
                        "parallel_slots": target_parallel,
                        "safety_margin_tokens": safety_margin,
                        "timeout_seconds": request_timeout,
                    },
                },
            )
            _info(result, f"token-rate metrics persisted to {metrics_db}")
        except (OSError, sqlite3.Error) as exc:
            _warn(result, f"could not persist token-rate metrics: {exc}")
    elif record_metrics and not metrics_db:
        _warn(result, "token-rate metrics are not persisted; metrics_db is not configured")
    return result


def _median_rate(summaries: list[dict[str, Any]], key: str) -> float | None:
    values = [
        float(summary[key])
        for summary in summaries
        if isinstance(summary, dict)
        and isinstance(summary.get(key), (int, float))
    ]
    return float(median(values)) if values else None


def capacity_test_series(
    config: dict[str, Any],
    context_tokens: int | None = None,
    input_tokens: int | None = None,
    output_tokens: int | None = None,
    parallel: int | None = None,
    warmup: bool = True,
    repetitions: int = DEFAULT_CAPACITY_REPETITIONS,
    cancel_event: threading.Event | None = None,
    progress: Callable[..., Any] | None = None,
) -> TestResult:
    """Run an optional warmup followed by repeated measurements."""

    try:
        repetitions = int(repetitions)
    except (TypeError, ValueError):
        repetitions = DEFAULT_CAPACITY_REPETITIONS
    result = TestResult(
        f"Capacity timing test (median of {repetitions} measurements)",
        True,
    )
    if repetitions < 1:
        _fail(result, f"measurement repetitions must be positive, got {repetitions}")
        return result

    effective_context_tokens = context_tokens
    if effective_context_tokens is None and input_tokens is not None:
        effective_output_tokens = (
            output_tokens
            if output_tokens is not None
            else int(
                config.get(
                    "capacity_test_output_tokens",
                    DEFAULT_CAPACITY_OUTPUT_TOKENS,
                )
            )
        )
        effective_safety_margin = int(
            config.get(
                "capacity_test_safety_margin_tokens",
                DEFAULT_TEST_SAFETY_MARGIN,
            )
        )
        effective_context_tokens = (
            int(input_tokens) + int(effective_output_tokens) + effective_safety_margin
        )

    warmup_result: TestResult | None = None
    measured_results: list[TestResult] = []
    cycle_count = repetitions + (1 if warmup else 0)

    def run_cycle(index: int, label: str) -> TestResult:
        def child_progress(value: float, desc: str = "") -> None:
            _progress(
                progress,
                (index + value) / cycle_count,
                f"{label}: {desc}",
            )

        return capacity_test(
            config,
            context_tokens=effective_context_tokens,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            parallel=parallel,
            cancel_event=cancel_event,
            progress=child_progress,
            record_metrics=False,
        )

    cycle_index = 0
    if warmup:
        warmup_result = run_cycle(cycle_index, "Warmup")
        cycle_index += 1
        result.lines.extend(
            f"[INFO] warmup: {line}" for line in warmup_result.lines
        )
        if not warmup_result.ok:
            result.ok = False
            result.lines.insert(0, "[FAIL] warmup request did not complete")
            return result

    for repetition in range(1, repetitions + 1):
        measured = run_cycle(cycle_index, f"Measurement {repetition}/{repetitions}")
        cycle_index += 1
        measured_results.append(measured)
        result.lines.extend(
            f"[INFO] measurement {repetition}: {line}"
            for line in measured.lines
        )
        if not measured.ok:
            result.ok = False
            result.lines.insert(
                0,
                f"[FAIL] measurement {repetition} did not complete",
            )
            return result

    summaries = [
        measured.details.get("token_rate_summary", {})
        for measured in measured_results
    ]
    median_summary = {
        key: _median_rate(summaries, key)
        for key in (
            "prompt_tokens_per_second",
            "generation_tokens_per_second",
            "aggregate_tokens_per_second",
            "wall_seconds",
        )
    }
    samples = [
        {
            "repetition": index,
            **summary,
        }
        for index, summary in enumerate(summaries, start=1)
    ]
    first_parameters = measured_results[0].details.get("parameters", {})
    if not isinstance(first_parameters, dict):
        first_parameters = {}
    result.details = {
        "warmup": bool(warmup),
        "repetitions": repetitions,
        "parameters": first_parameters,
        "median": median_summary,
        "samples": samples,
    }
    result.lines.append(
        "[PASS] median prompt "
        f"{_rate_text(median_summary['prompt_tokens_per_second'])}, "
        "generation "
        f"{_rate_text(median_summary['generation_tokens_per_second'])}, "
        "wall-throughput "
        f"{_rate_text(median_summary['aggregate_tokens_per_second'])}"
    )

    metrics_db = str(config.get("metrics_db", ""))
    if metrics_db:
        series_id = uuid4().hex
        series_details = {
            "series_id": series_id,
            "warmup": bool(warmup),
            "repetitions": repetitions,
            "median": median_summary,
            "samples": samples,
        }
        try:
            store = TokenRateStore(metrics_db)
            for repetition, measured in enumerate(measured_results, start=1):
                raw_metrics = measured.details.get("token_metrics", [])
                metrics: list[TokenMetric] = []
                for raw_metric in raw_metrics:
                    if not isinstance(raw_metric, dict):
                        continue
                    metrics.append(TokenMetric(**raw_metric))
                if not metrics:
                    continue
                details = dict(measured.details)
                details["series"] = {
                    **series_details,
                    "repetition": repetition,
                }
                parameters = measured.details.get("parameters", {})
                summary = measured.details.get("token_rate_summary", {})
                store.record_run(
                    metrics,
                    test_name=measured.name,
                    context_tokens=int(parameters.get("context_tokens", 0)),
                    parallel_slots=int(parameters.get("parallel_slots", 0)),
                    wall_seconds=float(summary.get("wall_seconds", 0)),
                    success=measured.ok,
                    details=details,
                )
            _info(result, f"token-rate metrics persisted to {metrics_db}")
        except (OSError, TypeError, ValueError, sqlite3.Error) as exc:
            _warn(result, f"could not persist token-rate metrics: {exc}")
    else:
        _warn(result, "token-rate metrics are not persisted; metrics_db is not configured")
    return result


def usb4_test(
    config: dict[str, Any],
    cancel_event: threading.Event | None = None,
    progress: Callable[..., Any] | None = None,
) -> TestResult:
    result = TestResult("USB4 throughput", True)
    _progress(progress, 0.05, "USB4: contacting worker test agent")
    if cancel_event and cancel_event.is_set():
        _warn(result, "test cancelled before starting")
        result.ok = False
        return result
    agent_url = str(config.get("peer_agent_url", "")).rstrip("/")
    if not agent_url:
        _fail(result, "peer_agent_url is not configured")
        return result

    headers: dict[str, str] = {}
    token = read_token(config.get("peer_agent_token_file"))
    if token:
        headers["X-Cluster-Agent-Token"] = token
    status, body = http_post_json(
        f"{agent_url}/tests/usb4",
        {
            "duration": int(config.get("iperf_duration", 10)),
            "parallel": int(config.get("iperf_parallel", 4)),
        },
        timeout=int(config.get("iperf_duration", 10)) + 60,
        headers=headers,
    )
    if cancel_event and cancel_event.is_set():
        _warn(result, "test cancelled")
        result.ok = False
        return result
    _progress(progress, 0.75, "USB4: received both direction results")
    if status != 200 or not isinstance(body, dict):
        _fail(result, f"worker USB4 agent returned HTTP {status}: {body}")
        return result

    results = body.get("results")
    if not isinstance(results, dict):
        _fail(result, f"worker USB4 agent returned an invalid result: {body}")
        return result
    for key, label in (
        ("worker_to_controller", "worker -> controller"),
        ("controller_to_worker", "controller -> worker"),
    ):
        entry = results.get(key)
        if not isinstance(entry, dict):
            _fail(result, f"{label}: missing worker-agent result")
            continue
        result.details[label] = entry.get("data", {})
        if entry.get("ok") is True:
            _pass(result, f"{label}: {entry.get('message', 'throughput passed')}")
        else:
            _fail(result, f"{label}: {entry.get('message', 'throughput failed')}")
    _progress(progress, 1.0, "USB4: complete")
    return result


def full_test(
    config: dict[str, Any],
    cancel_event: threading.Event | None = None,
    progress: Callable[..., Any] | None = None,
) -> TestResult:
    result = TestResult("Full cluster diagnostic", True)
    tests = (
        ("Effective Qwen configuration", configuration_test),
        ("Cluster runtime health", runtime_health_test),
        ("Capacity test", capacity_test),
        ("USB4 throughput", usb4_test),
    )
    results = []
    for index, (name, test) in enumerate(tests):
        start = index / len(tests)
        end = (index + 1) / len(tests)

        def child_progress(
            value: float, desc: str = "", start=start, end=end, name=name
        ) -> None:
            _progress(progress, start + (end - start) * value, f"{name}: {desc}")

        _progress(progress, start, f"Full diagnostic: starting {name}")
        try:
            results.append(
                test(
                    config,
                    cancel_event=cancel_event,
                    progress=child_progress,
                )
            )
        except (AttributeError, OSError, RuntimeError, TypeError, ValueError) as exc:
            results.append(
                TestResult(
                    name,
                    False,
                    [f"[FAIL] test raised {type(exc).__name__}: {exc}"],
                )
            )
        _progress(progress, end, f"Full diagnostic: finished {name}")
    for child in results:
        result.ok = result.ok and child.ok
        result.lines.append(child.render())
        result.details[child.name] = child.details
    return result


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        default="/etc/qwen3d8/dashboard.json",
        help="dashboard JSON configuration",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit machine-readable result JSON after the human summary",
    )
    parser.add_argument(
        "--metrics-db",
        help="override the SQLite token-rate history path",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("configuration", "runtime", "usb4", "all"):
        subparsers.add_parser(name)
    capacity = subparsers.add_parser("capacity")
    capacity.add_argument(
        "--context-tokens",
        type=int,
        help="test context per slot; defaults to dashboard configuration",
    )
    capacity.add_argument("--input-tokens", type=int)
    capacity.add_argument("--output-tokens", type=int)
    capacity.add_argument("--parallel", type=int)
    capacity.add_argument("--repetitions", type=int)
    warmup = capacity.add_mutually_exclusive_group()
    warmup.add_argument("--warmup", dest="warmup", action="store_true")
    warmup.add_argument("--no-warmup", dest="warmup", action="store_false")
    capacity.set_defaults(warmup=None)
    capacity.add_argument(
        "--metrics-db",
        dest="capacity_metrics_db",
        help="override the SQLite token-rate history path for this run",
    )
    return parser


def main() -> int:
    args = _parser().parse_args()
    config = load_config(args.config)
    metrics_db = args.metrics_db or getattr(args, "capacity_metrics_db", None)
    if metrics_db:
        config["metrics_db"] = metrics_db
    if args.command == "configuration":
        result = configuration_test(config)
    elif args.command == "runtime":
        result = runtime_health_test(config)
    elif args.command == "capacity":
        result = capacity_test_series(
            config,
            context_tokens=args.context_tokens,
            input_tokens=args.input_tokens,
            output_tokens=args.output_tokens,
            parallel=args.parallel,
            warmup=(
                bool(args.warmup)
                if args.warmup is not None
                else bool(config.get("capacity_test_warmup", True))
            ),
            repetitions=(
                args.repetitions
                if args.repetitions is not None
                else int(config.get("capacity_test_repetitions", 3))
            ),
        )
    elif args.command == "usb4":
        result = usb4_test(config)
    else:
        result = full_test(config)

    print(result.render())
    if args.json:
        print(json.dumps({"ok": result.ok, "name": result.name, "details": result.details}))
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

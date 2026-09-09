#!/usr/bin/env python3
"""Gradio dashboard for the Strix Halo cluster."""

from __future__ import annotations

import argparse
from html import escape
import sqlite3
import threading
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

try:
    from .cluster_monitor import (
        collect_cluster_snapshots,
        format_bytes,
        format_fans,
        format_temperature,
        load_config,
    )
    from .token_metrics import TokenRateStore
    from .cluster_tests import (
        TestResult,
        capacity_test,
        configuration_test,
        full_test,
        runtime_health_test,
        usb4_test,
    )
except ImportError:
    from cluster_monitor import (
        collect_cluster_snapshots,
        format_bytes,
        format_fans,
        format_temperature,
        load_config,
    )
    from token_metrics import TokenRateStore
    from cluster_tests import (
        TestResult,
        capacity_test,
        configuration_test,
        full_test,
        runtime_health_test,
        usb4_test,
    )


def _service_text(services: Any) -> str:
    if not isinstance(services, dict) or not services:
        return "n/a"
    return ", ".join(
        f"{_status_icon(state.get('state'))} "
        f"{name.removesuffix('.service')}={state.get('state', 'unknown')}"
        for name, state in services.items()
        if isinstance(state, dict)
    )


def _status_icon(status: Any) -> str:
    normalized = str(status or "unknown").lower()
    if normalized in {"healthy", "active", "ok", "ready", "up", "processing"}:
        return "🟢"
    if normalized in {"degraded", "warning", "warn", "inactive", "unknown"}:
        return "🟡"
    if normalized in {"error", "failed", "fail", "unreachable", "invalid"}:
        return "🔴"
    return "⚪"


def _gpu_text(gpu: Any) -> str:
    if not isinstance(gpu, dict):
        return "n/a"
    cards = gpu.get("cards", [])
    values = []
    for card in cards:
        if not isinstance(card, dict):
            continue
        used = format_bytes(card.get("gtt_used_bytes"))
        total = format_bytes(card.get("gtt_total_bytes"))
        if used != "n/a" or total != "n/a":
            values.append(f"{card.get('card', 'GPU')}: GTT {used}/{total}")
    ttm = format_bytes(gpu.get("ttm_limit_bytes"))
    if ttm != "n/a":
        values.append(f"TTM limit {ttm}")
    return ", ".join(values) if values else "n/a"


def _rate_text(value: Any) -> str:
    if not isinstance(value, (int, float)):
        return "n/a"
    return f"{value:,.1f} tok/s"


def _configuration_value(value: Any) -> str:
    text = str(value or "n/a").replace("\n", " ")
    return escape(text).replace("|", r"\|")


def _installed_positive_int(config: dict[str, Any], *keys: str) -> int | None:
    for key in keys:
        try:
            value = int(config.get(key, 0))
        except (TypeError, ValueError):
            continue
        if value > 0:
            return value
    return None


def render_installed_configuration(config: dict[str, Any]) -> str:
    """Render the Qwen settings loaded when the dashboard starts."""

    model = str(config.get("model_alias") or "").strip()
    if not model:
        model_file = str(config.get("model_file") or "").strip()
        model = Path(model_file).stem if model_file else "n/a"
    quantization = config.get("model_quant")
    context_tokens = _installed_positive_int(
        config,
        "installed_context_per_slot",
        "expected_context_per_slot",
        "context_per_slot",
    )
    parallel_slots = _installed_positive_int(
        config,
        "installed_parallel_slots",
        "expected_parallel_slots",
        "parallel_slots",
    )
    if context_tokens is None:
        context_text = "n/a"
    elif context_tokens % 1024 == 0:
        context_text = (
            f"{context_tokens:,} tokens per slot ({context_tokens // 1024} Ki)"
        )
    else:
        context_text = f"{context_tokens:,} tokens per slot"
    context_scaling = str(config.get("context_scaling") or "native").lower()
    if context_scaling == "yarn":
        native_context = _installed_positive_int(
            config, "native_context_per_slot"
        ) or 262144
        try:
            yarn_scale = float(config.get("yarn_rope_scale", 0))
        except (TypeError, ValueError):
            yarn_scale = 0.0
        scale_text = (
            f"YaRN {yarn_scale:g}x from {native_context:,} tokens"
            if yarn_scale > 0
            else f"YaRN from {native_context:,} tokens"
        )
    elif context_scaling == "native":
        scale_text = "Native"
    else:
        scale_text = context_scaling

    return "\n".join(
        (
            "## Installed Qwen configuration",
            "Values loaded from the controller's Qwen installation at dashboard startup.",
            "",
            "| Active model | Quantization level | Context window | Context scaling | Parallel slots |",
            "| --- | --- | --- | --- | ---: |",
            "| {model} | {quantization} | {context} | {scaling} | {parallel} |".format(
                model=_configuration_value(model),
                quantization=_configuration_value(quantization),
                context=_configuration_value(context_text),
                scaling=_configuration_value(scale_text),
                parallel=_configuration_value(parallel_slots),
            ),
        )
    )


def render_token_history(summary: dict[str, Any]) -> str:
    if summary.get("error"):
        return f"## Token-rate statistics\n\n**Unavailable:** {summary['error']}"

    lines = [
        "## Token-rate statistics",
        "Rates are recorded from triggered capacity tests and retained in SQLite.",
        "",
        "| Window | Test runs | Requests | Prompt rate | Generation rate | Aggregate wall throughput |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    windows = summary.get("windows", [])
    if not isinstance(windows, list):
        return "## Token-rate statistics\n\n**Unavailable:** invalid history payload"
    for window in windows:
        if not isinstance(window, dict):
            continue
        lines.append(
            "| {label} | {test_runs} | {requests} | {prompt} | {generation} | {aggregate} |".format(
                label=window.get("label", "unknown"),
                test_runs=window.get("test_runs", 0),
                requests=window.get("requests", 0),
                prompt=_rate_text(window.get("prompt_tokens_per_second")),
                generation=_rate_text(window.get("generation_tokens_per_second")),
                aggregate=_rate_text(window.get("aggregate_tokens_per_second")),
            )
        )

    latest = summary.get("latest")
    if isinstance(latest, dict):
        latest_context = latest.get("context_tokens")
        context_text = (
            f"{latest_context:,}"
            if isinstance(latest_context, int)
            else str(latest_context or "n/a")
        )
        lines.extend(
            [
                "",
                (
                    f"**Latest:** {latest.get('test_name', 'capacity test')} at "
                    f"{latest.get('recorded_at_iso', 'unknown')}  |  "
                    f"context {context_text} tokens/slot  |  "
                    f"parallel {latest.get('parallel_slots', 'n/a')}"
                ),
            ]
        )
    return "\n".join(lines)


def render_status(cluster: dict[str, Any]) -> str:
    status = str(cluster.get("status", "unknown")).upper()
    if status in {"HEALTHY", "OK", "READY"}:
        status_color = "#15803d"
    elif status in {"DEGRADED", "WARNING", "WARN"}:
        status_color = "#ca8a04"
    elif status in {"ERROR", "FAILED", "FAIL", "UNREACHABLE"}:
        status_color = "#dc2626"
    else:
        status_color = "#6b7280"
    status_badge = (
        f'<span style="color:{status_color};font-weight:700;">'
        f"{escape(status)}</span>"
    )
    active = cluster.get("active_inference_users", 0)
    capacity = cluster.get("inference_capacity")
    capacity_text = str(capacity) if isinstance(capacity, int) else "?"
    nodes = cluster.get("nodes", [])
    if not isinstance(nodes, list):
        nodes = []
    show_fans = any(
        isinstance(node, dict)
        and isinstance(node.get("fans"), list)
        and bool(node.get("fans"))
        for node in nodes
    )
    os_sessions = 0
    for node in nodes:
        if not isinstance(node, dict):
            continue
        users = node.get("users", {})
        if isinstance(users, dict) and isinstance(users.get("sessions"), int):
            os_sessions += users["sessions"]
    lines = [
        f"## Cluster status: {status_badge}",
        (
            f"**Inference users:** {active}/{capacity_text} active slots  |  "
            f"**OS sessions:** {os_sessions}  |  "
            f"**Last update:** {cluster.get('collected_at', 'unknown')}"
        ),
        "",
    ]
    headers = [
        "Node",
        "Role",
        "RAM used / available",
        "GPU memory",
        "Temperature",
    ]
    if show_fans:
        headers.append("Fans")
    headers.extend(["Users (inference / OS)", "Services"])
    lines.extend(
        [
            "| " + " | ".join(headers) + " |",
            "| " + " | ".join("---" for _ in headers) + " |",
        ]
    )
    for node in nodes:
        if not isinstance(node, dict):
            continue
        memory = node.get("memory", {})
        if not isinstance(memory, dict):
            memory = {}
        users = node.get("users", {})
        if not isinstance(users, dict):
            users = {}
        active_users = users.get("active_inference", "n/a")
        if not isinstance(active_users, int):
            active_users = "n/a"
        inference_capacity = users.get("inference_capacity")
        if isinstance(inference_capacity, int):
            user_text = (
                f"{active_users}/{inference_capacity}; "
                f"OS {users.get('sessions', 'n/a')}"
            )
        else:
            user_text = f"{active_users}; OS {users.get('sessions', 'n/a')}"
        row = [
            f"{_status_icon(node.get('status'))} {node.get('hostname', 'unknown')}",
            str(node.get("role", "unknown")),
            f"{format_bytes(memory.get('used_bytes'))} / "
            f"{format_bytes(memory.get('available_bytes'))}",
            _gpu_text(node.get("gpu_memory")),
            format_temperature(node.get("temperatures")),
        ]
        if show_fans:
            row.append(format_fans(node.get("fans")))
        row.extend([user_text, _service_text(node.get("services"))])
        lines.append("| " + " | ".join(row) + " |")

    if cluster.get("errors"):
        lines.extend(["", "🟡 **Warnings:**"])
        lines.extend(f"- 🔴 {error}" for error in cluster["errors"])
    return "\n".join(lines)


def _sensor_text(readings: Any, value_key: str, suffix: str) -> str:
    if not isinstance(readings, list) or not readings:
        return "n/a"
    values = []
    for reading in readings:
        if not isinstance(reading, dict):
            continue
        name = reading.get("name", "sensor")
        value = reading.get(value_key)
        if isinstance(value, (int, float)):
            values.append(f"{name}: {value:g}{suffix}")
    return ", ".join(values) if values else "n/a"


def _uptime_text(seconds: Any) -> str:
    if not isinstance(seconds, (int, float)) or seconds < 0:
        return "n/a"
    total_minutes = int(seconds // 60)
    days, remainder = divmod(total_minutes, 1440)
    hours, minutes = divmod(remainder, 60)
    return f"{days}d {hours}h {minutes}m"


def render_detailed_telemetry(details: dict[str, Any]) -> str:
    cluster = details.get("cluster")
    if not isinstance(cluster, dict):
        error = details.get("error", "telemetry is unavailable")
        return f"## Detailed telemetry\n\n**Unavailable:** {error}"

    nodes = cluster.get("nodes", [])
    if not isinstance(nodes, list):
        return "## Detailed telemetry\n\n**Unavailable:** invalid node payload"
    show_fans = any(
        isinstance(node, dict)
        and isinstance(node.get("fans"), list)
        and bool(node.get("fans"))
        for node in nodes
    )

    lines = [
        "## Detailed telemetry",
        (
            f"Cluster snapshot: {_status_icon(cluster.get('status'))} "
            f"**{cluster.get('status', 'unknown').upper()}**  |  "
            f"Collected: {cluster.get('collected_at', 'unknown')}"
        ),
    ]
    for node in nodes:
        if not isinstance(node, dict):
            continue
        memory = node.get("memory", {})
        memory = memory if isinstance(memory, dict) else {}
        users = node.get("users", {})
        users = users if isinstance(users, dict) else {}
        network = node.get("network", {})
        network = network if isinstance(network, dict) else {}
        inference = node.get("inference")
        inference = inference if isinstance(inference, dict) else {}
        lines.extend(
            [
                "",
                f"### {_status_icon(node.get('status'))} "
                f"{node.get('hostname', 'unknown')} ({node.get('role', 'unknown')})",
                f"**Status:** {_status_icon(node.get('status'))} "
                f"{str(node.get('status', 'unknown')).upper()}",
                "",
                "| Metric | Value |",
                "| --- | --- |",
                f"| RAM | {format_bytes(memory.get('used_bytes'))} used / "
                f"{format_bytes(memory.get('available_bytes'))} available of "
                f"{format_bytes(memory.get('total_bytes'))} |",
                f"| Swap | {format_bytes(memory.get('swap_used_bytes'))} used of "
                f"{format_bytes(memory.get('swap_total_bytes'))} |",
                f"| Load average | {', '.join(f'{value:.2f}' for value in node.get('load_average', []) if isinstance(value, (int, float))) or 'n/a'} |",
                f"| Uptime | {_uptime_text(node.get('uptime_seconds'))} |",
                f"| Temperatures | {_sensor_text(node.get('temperatures'), 'celsius', ' C')} |",
                *(
                    [f"| Fans | {_sensor_text(node.get('fans'), 'rpm', ' RPM')} |"]
                    if show_fans
                    else []
                ),
                f"| GPU/GTT | {_gpu_text(node.get('gpu_memory'))} |",
                f"| Users | {users.get('active_inference', 'n/a')} active inference / "
                f"{users.get('sessions', 'n/a')} OS sessions |",
                f"| USB4 | {network.get('interface', 'n/a')} "
                f"{network.get('operstate', 'unknown')}; RPC "
                f"{'reachable' if network.get('rpc_reachable') else 'unreachable/unknown'} |",
                f"| Services | {_service_text(node.get('services'))} |",
            ]
        )

        disk = node.get("disk", [])
        if isinstance(disk, list) and disk:
            lines.extend(
                [
                    "",
                    "**Disk usage**",
                    "",
                    "| Requested path | Measured filesystem | Used | Available | Total |",
                    "| --- | --- | ---: | ---: | ---: |",
                ]
            )
            for entry in disk:
                if not isinstance(entry, dict):
                    continue
                path_icon = (
                    "🔴"
                    if entry.get("error")
                    else "🟡"
                    if entry.get("warning")
                    else "🟢"
                )
                lines.append(
                    f"| {path_icon} {entry.get('path', 'n/a')} | "
                    f"{entry.get('usage_path', 'n/a')} | "
                    f"{format_bytes(entry.get('used_bytes'))} | "
                    f"{format_bytes(entry.get('available_bytes'))} | "
                    f"{format_bytes(entry.get('total_bytes'))} |"
                )
                if entry.get("warning"):
                    lines.append(
                        f"| 🟡 Warning | {entry.get('warning')} | | | |"
                    )
                elif entry.get("error"):
                    lines.append(
                        f"| 🔴 Error | {entry.get('error')} | | | |"
                    )

        if inference:
            health = inference.get("health")
            health_status = (
                health.get("status_code", "n/a")
                if isinstance(health, dict)
                else "n/a"
            )
            lines.extend(
                [
                    "",
                    "**Inference runtime**",
                    "",
                    f"Health: {health_status}  |  "
                    f"Model: {inference.get('model_path', 'n/a')}  |  "
                    f"Slots: {inference.get('active_slots', 'n/a')}/"
                    f"{inference.get('total_slots', 'n/a')}",
                ]
            )
            slots = inference.get("slots", [])
            if isinstance(slots, list) and slots:
                lines.extend(
                    [
                        "",
                        "| Slot | Context | Processing | Decoded tokens |",
                        "| ---: | ---: | --- | ---: |",
                    ]
                )
                for slot in slots:
                    if not isinstance(slot, dict):
                        continue
                    lines.append(
                        f"| {_status_icon('processing' if slot.get('is_processing') else 'idle')} "
                        f"{slot.get('id', 'n/a')} | {slot.get('n_ctx', 'n/a')} | "
                        f"{slot.get('is_processing', 'n/a')} | "
                        f"{slot.get('n_decoded', 'n/a')} |"
                    )

    errors = cluster.get("errors", [])
    if isinstance(errors, list) and errors:
        lines.extend(["", "**Cluster warnings**"])
        lines.extend(f"- {error}" for error in errors)
    return "\n".join(lines)


class DashboardApp:
    def __init__(self, config: dict[str, Any]):
        self.config = config
        self._cancel_event = threading.Event()
        self._test_lock = threading.Lock()
        self._active_test = ""
        self._error_log: deque[str] = deque(maxlen=200)
        self._last_error = ""

    def _log_error(self, message: str) -> None:
        if message == self._last_error:
            return
        timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        self._error_log.append(f"{timestamp} {message}")
        self._last_error = message

    def error_log_text(self) -> str:
        return "\n".join(self._error_log)

    def clear_error_log(self) -> str:
        with self._test_lock:
            self._error_log.clear()
            self._last_error = ""
        return ""

    def request_cancel(self) -> str:
        with self._test_lock:
            active_test = self._active_test
            if active_test:
                self._cancel_event.set()
                self._log_error(f"Cancellation requested for {active_test}")
            else:
                self._log_error("Cancellation requested, but no test is running")
        return self.error_log_text()

    def _start_test(self, name: str) -> None:
        with self._test_lock:
            self._cancel_event.clear()
            self._active_test = name

    def _finish_test(self) -> None:
        with self._test_lock:
            self._active_test = ""

    def _record_result_errors(self, result: TestResult) -> None:
        for block in result.lines:
            for line in block.splitlines():
                if line.startswith("[FAIL]") or line.startswith("[WARN]"):
                    self._log_error(f"{result.name}: {line}")

    def _token_history(self) -> dict[str, Any]:
        metrics_db = str(self.config.get("metrics_db", ""))
        if not metrics_db:
            return {"error": "metrics_db is not configured"}
        try:
            return TokenRateStore(metrics_db).summary()
        except (OSError, sqlite3.Error) as exc:
            return {"error": str(exc)}

    def refresh(self) -> tuple[str, str, str, str]:
        try:
            cluster, _ = collect_cluster_snapshots(self.config)
        except (AttributeError, OSError, RuntimeError, TypeError, ValueError) as exc:
            self._log_error(f"Status refresh failed: {type(exc).__name__}: {exc}")
            token_history = self._token_history()
            details = {"error": str(exc), "token_rates": token_history}
            return (
                "## Cluster status: **ERROR**\n\nThe telemetry collector failed.",
                render_token_history(token_history),
                self.error_log_text(),
                render_detailed_telemetry(details),
            )
        for error in cluster.get("errors", []):
            if isinstance(error, str):
                self._log_error(error)
        token_history = self._token_history()
        details = {"cluster": cluster, "token_rates": token_history}
        return (
            render_status(cluster),
            render_token_history(token_history),
            self.error_log_text(),
            render_detailed_telemetry(details),
        )

    def _run(
        self,
        name: str,
        test: Callable[..., TestResult],
        progress: Callable[..., Any] | None = None,
    ) -> tuple[str, str, str, str, str]:
        self._start_test(name)
        if progress is not None:
            progress(0.0, desc=f"{name}: starting")
        try:
            result = test(
                self.config,
                cancel_event=self._cancel_event,
                progress=progress,
            )
        except (AttributeError, OSError, RuntimeError, TypeError, ValueError) as exc:
            result = TestResult(
                name,
                False,
                [f"[FAIL] test raised {type(exc).__name__}: {exc}"],
            )
        finally:
            self._finish_test()
        if progress is not None:
            progress(1.0, desc=f"{name}: complete")
        self._record_result_errors(result)
        summary, token_history, error_log, details = self.refresh()
        return result.render(), summary, token_history, error_log, details

    def run_configuration(
        self, progress: Callable[..., Any] | None = None
    ) -> tuple[str, str, str, str, str]:
        return self._run("configuration", configuration_test, progress)

    def run_runtime(
        self, progress: Callable[..., Any] | None = None
    ) -> tuple[str, str, str, str, str]:
        return self._run("runtime health", runtime_health_test, progress)

    def run_capacity(
        self,
        context_tokens: float | None = None,
        output_tokens: float | None = None,
        parallel: float | None = None,
        progress: Callable[..., Any] | None = None,
    ) -> tuple[str, str, str, str, str]:
        def integer_or_none(value: float | None) -> int | None:
            return int(value) if value is not None else None

        def execute(
            config: dict[str, Any],
            cancel_event: threading.Event | None = None,
            progress: Callable[..., Any] | None = None,
        ) -> TestResult:
            return capacity_test(
                config,
                context_tokens=integer_or_none(context_tokens),
                output_tokens=integer_or_none(output_tokens),
                parallel=integer_or_none(parallel),
                cancel_event=cancel_event,
                progress=progress,
            )

        return self._run(
            "capacity test",
            execute,
            progress,
        )

    def run_usb4(
        self, progress: Callable[..., Any] | None = None
    ) -> tuple[str, str, str, str, str]:
        return self._run("USB4 throughput", usb4_test, progress)

    def run_all(
        self, progress: Callable[..., Any] | None = None
    ) -> tuple[str, str, str, str, str]:
        return self._run("full diagnostic", full_test, progress)


def _read_auth_password(path: str | None) -> str:
    if not path:
        return ""
    try:
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            if line.strip():
                return line.strip()
    except OSError:
        return ""
    return ""


def build_demo(app: DashboardApp) -> Any:
    try:
        import gradio as gr
    except ImportError as exc:
        raise RuntimeError(
            "Gradio is not installed; run dashboard/setup-dashboard.sh first"
        ) from exc

    def run_configuration_with_progress(progress=gr.Progress()):
        return app.run_configuration(progress=progress)

    def run_runtime_with_progress(progress=gr.Progress()):
        return app.run_runtime(progress=progress)

    def run_capacity_with_progress(
        context_tokens,
        output_tokens,
        parallel,
        progress=gr.Progress(),
    ):
        return app.run_capacity(
            context_tokens,
            output_tokens,
            parallel,
            progress=progress,
        )

    def run_usb4_with_progress(progress=gr.Progress()):
        return app.run_usb4(progress=progress)

    def run_all_with_progress(progress=gr.Progress()):
        return app.run_all(progress=progress)

    with gr.Blocks(title="Strix Halo Cluster Dashboard") as demo:
        gr.Markdown("# Strix Halo Cluster Dashboard")
        gr.Markdown(render_installed_configuration(app.config))
        status = gr.Markdown("Loading cluster status...")
        token_history = gr.Markdown("Loading token-rate statistics...")
        error_log = gr.Textbox(
            label="Error log",
            lines=8,
            max_lines=20,
            interactive=False,
        )
        details = gr.Markdown("Loading detailed telemetry...")

        gr.Markdown("## On-demand verification")
        gr.Markdown(
            "Capacity testing sends synthetic requests to the controller. "
            "Run it when no production workload is active."
        )
        with gr.Row():
            context_input = gr.Number(
                label="Test context per slot (tokens)",
                value=app.config.get("capacity_test_context_tokens", 262144),
                precision=0,
            )
            output_input = gr.Number(
                label="Test output tokens",
                value=app.config.get("capacity_test_output_tokens", 2048),
                precision=0,
            )
            parallel_input = gr.Number(
                label="Test parallel slots",
                value=app.config.get("capacity_test_parallel_slots", 3),
                precision=0,
            )
        with gr.Row():
            refresh_button = gr.Button("Refresh status")
            configuration_button = gr.Button("Verify configuration")
            runtime_button = gr.Button("Runtime health and slots")
        with gr.Row():
            capacity_button = gr.Button("Run configured capacity test")
            usb4_button = gr.Button("Test USB4 throughput")
            all_button = gr.Button("Run full diagnostic")
            cancel_button = gr.Button("Cancel running test", variant="stop")
            clear_log_button = gr.Button("Clear error log")
        output = gr.Textbox(
            label="Test output",
            lines=24,
            max_lines=40,
            interactive=False,
        )

        refresh_button.click(
            app.refresh, outputs=[status, token_history, error_log, details]
        )
        configuration_event = configuration_button.click(
            run_configuration_with_progress,
            outputs=[output, status, token_history, error_log, details],
        )
        runtime_event = runtime_button.click(
            run_runtime_with_progress,
            outputs=[output, status, token_history, error_log, details],
        )
        capacity_event = capacity_button.click(
            run_capacity_with_progress,
            inputs=[context_input, output_input, parallel_input],
            outputs=[output, status, token_history, error_log, details],
        )
        usb4_event = usb4_button.click(
            run_usb4_with_progress,
            outputs=[output, status, token_history, error_log, details],
        )
        all_event = all_button.click(
            run_all_with_progress,
            outputs=[output, status, token_history, error_log, details],
        )
        cancel_button.click(
            app.request_cancel,
            outputs=[error_log],
            cancels=[
                configuration_event,
                runtime_event,
                capacity_event,
                usb4_event,
                all_event,
            ],
        )
        clear_log_button.click(app.clear_error_log, outputs=[error_log])
        demo.load(app.refresh, outputs=[status, token_history, error_log, details])

        if hasattr(gr, "Timer"):
            timer = gr.Timer(5)
            timer.tick(
                app.refresh, outputs=[status, token_history, error_log, details]
            )

    return demo


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        default="/etc/qwen3d8/dashboard.json",
        help="dashboard JSON configuration",
    )
    parser.add_argument("--host", help="Gradio listen address")
    parser.add_argument("--port", type=int, help="Gradio listen port")
    parser.add_argument("--auth-user", help="optional Gradio basic-auth username")
    parser.add_argument(
        "--auth-password-file",
        help="file containing the optional Gradio basic-auth password",
    )
    args = parser.parse_args()

    config = load_config(args.config)
    app = DashboardApp(config)
    demo = build_demo(app)

    host = args.host or str(config.get("dashboard_host", "127.0.0.1"))
    port = args.port or int(config.get("dashboard_port", 7860))
    auth_user = args.auth_user or str(config.get("auth_user", ""))
    auth_file = args.auth_password_file or str(
        config.get("auth_password_file", "")
    )
    password = _read_auth_password(auth_file)
    auth = (auth_user, password) if auth_user and password else None

    demo.queue()
    demo.launch(
        server_name=host,
        server_port=port,
        auth=auth,
        share=False,
        show_error=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

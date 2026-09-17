"""Regression tests for dashboard cluster telemetry checks."""

from __future__ import annotations

import subprocess
import threading
import unittest
from unittest.mock import patch

from dashboard import cluster_dashboard, cluster_monitor, cluster_tests


class ClusterNetworkTests(unittest.TestCase):
    def test_controller_uses_established_rpc_connection(self) -> None:
        completed = subprocess.CompletedProcess(
            args=["ss"],
            returncode=0,
            stdout=(
                "ESTAB 0 0 10.200.0.1:47612 10.200.0.2:50053\n"
                "ESTAB 0 0 10.200.0.1:40184 10.200.0.2:8765\n"
            ),
            stderr="",
        )
        with patch.object(
            cluster_monitor.subprocess, "run", return_value=completed
        ) as run:
            network = cluster_monitor.collect_network(
                {
                    "cluster_iface": "",
                    "local_ip": "10.200.0.1",
                    "peer_ip": "10.200.0.2",
                    "rpc_port": 50053,
                },
                role="server",
            )

        self.assertTrue(network["rpc_reachable"])
        self.assertNotIn("rpc_error", network)
        self.assertEqual(
            run.call_args.args[0], ["ss", "-Htn", "state", "established"]
        )

    def test_controller_reports_missing_established_rpc_connection(self) -> None:
        completed = subprocess.CompletedProcess(
            args=["ss"],
            returncode=0,
            stdout="ESTAB 0 0 10.200.0.1:40184 10.200.0.2:8765\n",
            stderr="",
        )
        with patch.object(
            cluster_monitor.subprocess, "run", return_value=completed
        ):
            network = cluster_monitor.collect_network(
                {
                    "cluster_iface": "",
                    "local_ip": "10.200.0.1",
                    "peer_ip": "10.200.0.2",
                    "rpc_port": 50053,
                },
                role="server",
            )

        self.assertFalse(network["rpc_reachable"])
        self.assertEqual(
            network["rpc_error"],
            "no established TCP connection from 10.200.0.1 to 10.200.0.2:50053",
        )


class PeerConfigurationTests(unittest.TestCase):
    def test_peer_configuration_checks_its_local_rpc_listener(self) -> None:
        environment = "\n".join(
            (
                "NODE_ROLE=peer",
                "MODEL_QUANT=UD-Q4_K_XL",
                "PARALLEL_SLOTS=3",
                "CONTEXT_PER_SLOT=196608",
            )
        )
        with (
            patch.object(cluster_tests.Path, "read_text", return_value=environment),
            patch.object(cluster_tests, "_unit_text", return_value="[Service]\n"),
            patch.object(
                cluster_tests,
                "service_state",
                return_value={"active": True, "state": "active"},
            ),
            patch.object(
                cluster_tests, "local_tcp_listener", return_value=(True, "")
            ) as listener,
        ):
            result = cluster_tests.configuration_test(
                {
                    "role": "peer",
                    "local_ip": "10.200.0.2",
                    "peer_ip": "10.200.0.1",
                    "rpc_port": 50053,
                    "expected_parallel_slots": 3,
                    "expected_context_per_slot": 196608,
                }
            )

        self.assertTrue(result.ok, result.render())
        self.assertIn(
            "[PASS] RPC worker listens on 10.200.0.2:50053", result.lines
        )
        listener.assert_called_once_with("10.200.0.2", 50053)


class DashboardCapacityTests(unittest.TestCase):
    def test_capacity_activity_is_limited_to_requested_slot_ids(self) -> None:
        slots = [
            {"id": 0, "is_processing": True, "n_ctx": 262144},
            {"id": 1, "is_processing": True, "n_ctx": 262144},
            {"id": 2, "is_processing": True, "n_ctx": 262144},
        ]

        selected = cluster_tests._capacity_test_slots(slots, target_parallel=1)

        self.assertEqual([slot["id"] for slot in selected], [0])

    def test_capacity_request_honors_end_of_sequence(self) -> None:
        started = threading.Event()
        release = threading.Event()
        captured: list[dict[str, object]] = []
        response = {
            "tokens_evaluated": 3,
            "truncated": False,
            "timings": {
                "prompt_n": 3,
                "predicted_n": 2,
                "prompt_ms": 3.0,
                "predicted_ms": 2.0,
            },
        }

        def fake_http_json(url: str, timeout: float) -> tuple[int, object]:
            if url.endswith("/health"):
                return 200, {"status": "ok"}
            started.wait(timeout=1)
            release.set()
            return 200, [{"id": 0, "is_processing": True, "n_ctx": 101}]

        def fake_post_json(
            url: str, body: dict[str, object], timeout: float
        ) -> tuple[int, object]:
            captured.append(body)
            started.set()
            release.wait(timeout=1)
            return 200, response

        with (
            patch.object(cluster_tests, "http_json", side_effect=fake_http_json),
            patch.object(
                cluster_tests, "_post_json", side_effect=fake_post_json
            ),
        ):
            result = cluster_tests.capacity_test(
                {
                    "llama_url": "http://127.0.0.1:8081",
                    "metrics_db": "",
                },
                context_tokens=101,
                input_tokens=3,
                output_tokens=2,
                parallel=1,
                record_metrics=False,
            )

        self.assertTrue(result.ok, result.render())
        self.assertEqual(len(captured), 1)
        self.assertFalse(captured[0]["ignore_eos"])
        self.assertEqual(captured[0]["n_predict"], 2)

    def test_capacity_retries_transient_generation_error(self) -> None:
        generation_error = 500, {
            "error": {
                "code": 500,
                "message": (
                    "The model produced output that does not match the "
                    "expected Content-only format"
                ),
                "type": "server_error",
            }
        }
        success = 200, {
            "tokens_evaluated": 3,
            "truncated": False,
            "timings": {
                "prompt_n": 3,
                "predicted_n": 2,
                "prompt_ms": 3.0,
                "predicted_ms": 2.0,
            },
        }
        attempts: list[dict[str, object]] = []

        def fake_http_json(url: str, timeout: float) -> tuple[int, object]:
            if url.endswith("/health"):
                return 200, {"status": "ok"}
            return 200, [{"id": 0, "is_processing": True, "n_ctx": 101}]

        def fake_post_json(
            url: str, body: dict[str, object], timeout: float
        ) -> tuple[int, object]:
            attempts.append(body)
            return generation_error if len(attempts) == 1 else success

        with (
            patch.object(cluster_tests, "http_json", side_effect=fake_http_json),
            patch.object(
                cluster_tests, "_post_json", side_effect=fake_post_json
            ),
        ):
            result = cluster_tests.capacity_test(
                {
                    "llama_url": "http://127.0.0.1:8081",
                    "metrics_db": "",
                },
                context_tokens=101,
                input_tokens=3,
                output_tokens=2,
                parallel=1,
                record_metrics=False,
            )

        self.assertTrue(result.ok, result.render())
        self.assertEqual(len(attempts), 2)
        self.assertTrue(
            any("retried 1 time(s)" in line for line in result.lines),
            result.render(),
        )

    def test_capacity_fails_after_exhausting_generation_error_retries(
        self,
    ) -> None:
        generation_error = 500, {
            "error": {
                "code": 500,
                "message": (
                    "The model produced output that does not match the "
                    "expected Content-only format"
                ),
                "type": "server_error",
            }
        }
        attempts: list[dict[str, object]] = []

        def fake_http_json(url: str, timeout: float) -> tuple[int, object]:
            if url.endswith("/health"):
                return 200, {"status": "ok"}
            return 200, [{"id": 0, "is_processing": True, "n_ctx": 101}]

        def fake_post_json(
            url: str, body: dict[str, object], timeout: float
        ) -> tuple[int, object]:
            attempts.append(body)
            return generation_error

        with (
            patch.object(cluster_tests, "http_json", side_effect=fake_http_json),
            patch.object(
                cluster_tests, "_post_json", side_effect=fake_post_json
            ),
        ):
            result = cluster_tests.capacity_test(
                {
                    "llama_url": "http://127.0.0.1:8081",
                    "metrics_db": "",
                },
                context_tokens=101,
                input_tokens=3,
                output_tokens=2,
                parallel=1,
                record_metrics=False,
            )

        self.assertFalse(result.ok, result.render())
        self.assertEqual(
            len(attempts), cluster_tests.CAPACITY_GENERATION_ERROR_RETRIES + 1
        )
        self.assertTrue(
            any(
                f"retried {cluster_tests.CAPACITY_GENERATION_ERROR_RETRIES} "
                "time(s)" in line
                for line in result.lines
            ),
            result.render(),
        )

    def test_capacity_wrapper_accepts_runner_progress(self) -> None:
        app = cluster_dashboard.DashboardApp({})

        def outer_progress(*args: object, **kwargs: object) -> None:
            return None

        def runner_progress(*args: object, **kwargs: object) -> None:
            return None

        with patch.object(app, "_run", return_value=()) as run:
            app.run_capacity(
                context_tokens=196608,
                output_tokens=1,
                parallel=3,
                progress=outer_progress,
            )
            execute = run.call_args.args[1]

        cancel_event = threading.Event()
        expected = cluster_dashboard.TestResult("capacity", True)
        with patch.object(
            cluster_dashboard, "capacity_test_series", return_value=expected
        ) as capacity:
            result = execute(
                {"llama_url": "http://127.0.0.1:8081"},
                cancel_event=cancel_event,
                progress=runner_progress,
            )

        self.assertIs(result, expected)
        capacity.assert_called_once_with(
            {"llama_url": "http://127.0.0.1:8081"},
            context_tokens=196608,
            input_tokens=None,
            output_tokens=1,
            parallel=3,
            warmup=True,
            repetitions=3,
            cancel_event=cancel_event,
            progress=runner_progress,
        )


class DashboardRestartTests(unittest.TestCase):
    def test_restart_starts_restricted_helper(self) -> None:
        app = cluster_dashboard.DashboardApp({"role": "server"})
        completed = subprocess.CompletedProcess(
            args=["systemctl"],
            returncode=0,
            stdout="",
            stderr="",
        )
        with (
            patch.object(
                cluster_dashboard.subprocess, "run", return_value=completed
            ) as run,
            patch.object(
                app,
                "refresh",
                return_value=("status", "history", "errors", "details"),
            ),
        ):
            response = app.restart_server()

        self.assertTrue(response[0].startswith("[PASS]"))
        run.assert_called_once_with(
            ["systemctl", "start", "qwen3d8-server-restart.service"],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_restart_refuses_while_test_is_running(self) -> None:
        app = cluster_dashboard.DashboardApp({"role": "server"})
        app._active_test = "capacity test"
        with patch.object(
            app,
            "refresh",
            return_value=("status", "history", "errors", "details"),
        ):
            response = app.restart_server()

        self.assertTrue(response[0].startswith("[FAIL]"))
        self.assertIn("capacity test is running", response[0])


class InstalledConfigurationTests(unittest.TestCase):
    def test_renders_latest_capacity_parameters(self) -> None:
        rendered = cluster_dashboard.render_token_history(
            {
                "windows": [],
                "latest": {
                    "test_name": "Capacity test",
                    "recorded_at_iso": "2026-09-15T07:00:00+00:00",
                    "details": {
                        "parameters": {
                            "context_tokens": 262144,
                            "input_tokens": 260000,
                            "output_tokens": 2048,
                            "parallel_slots": 3,
                            "safety_margin_tokens": 96,
                            "timeout_seconds": 14400,
                        }
                    },
                },
            }
        )

        self.assertIn("## Capacity test results", rendered)
        self.assertIn(
            "**Parameters:** context 262,144 tokens/slot  |  "
            "input 260,000 tokens  |  output 2,048 tokens  |  "
            "parallel 3 slots  |  safety margin 96 tokens  |  "
            "timeout 240 min",
            rendered,
        )

    def test_renders_installed_qwen_settings(self) -> None:
        rendered = cluster_dashboard.render_installed_configuration(
            {
                "model_alias": "qwen3.8-flash-next-q4",
                "model_quant": "UD-Q4_K_XL",
                "installed_context_per_slot": 196608,
                "installed_parallel_slots": 3,
            }
        )

        self.assertIn("## Installed Qwen configuration", rendered)
        self.assertIn(
            "| qwen3.8-flash-next-q4 | UD-Q4_K_XL | "
            "196,608 tokens per slot (192 Ki) | Native | 3 |",
            rendered,
        )

    def test_renders_yarn_configuration(self) -> None:
        rendered = cluster_dashboard.render_installed_configuration(
            {
                "model_alias": "qwen3.8-flash-next-q4",
                "model_quant": "UD-Q4_K_XL",
                "installed_context_per_slot": 524288,
                "installed_parallel_slots": 3,
                "native_context_per_slot": 262144,
                "context_scaling": "yarn",
                "yarn_rope_scale": 2,
            }
        )

        self.assertIn(
            "524,288 tokens per slot (512 Ki) | "
            "YaRN 2x from 262,144 tokens",
            rendered,
        )


class CapacityTimeoutTests(unittest.TestCase):
    def test_default_timeout_scales_with_workload(self) -> None:
        timeout = cluster_tests._capacity_timeout(
            {},
            input_tokens=524288,
            output_tokens=0,
            parallel_slots=3,
        )

        self.assertEqual(timeout, 14400)

    def test_explicit_timeout_overrides_automatic_timeout(self) -> None:
        timeout = cluster_tests._capacity_timeout(
            {"capacity_timeout": 7200},
            input_tokens=524288,
            output_tokens=0,
            parallel_slots=3,
        )

        self.assertEqual(timeout, 7200)

    def test_capacity_series_reports_median_and_excludes_warmup(self) -> None:
        summaries = iter(
            [
                {
                    "prompt_tokens_per_second": 10.0,
                    "generation_tokens_per_second": 20.0,
                    "aggregate_tokens_per_second": 15.0,
                    "wall_seconds": 4.0,
                },
                {
                    "prompt_tokens_per_second": 30.0,
                    "generation_tokens_per_second": 40.0,
                    "aggregate_tokens_per_second": 35.0,
                    "wall_seconds": 2.0,
                },
                {
                    "prompt_tokens_per_second": 20.0,
                    "generation_tokens_per_second": 30.0,
                    "aggregate_tokens_per_second": 25.0,
                    "wall_seconds": 3.0,
                },
                {
                    "prompt_tokens_per_second": 40.0,
                    "generation_tokens_per_second": 50.0,
                    "aggregate_tokens_per_second": 45.0,
                    "wall_seconds": 1.0,
                },
            ]
        )

        def fake_capacity_test(*args: object, **kwargs: object) -> cluster_tests.TestResult:
            summary = next(summaries)
            return cluster_tests.TestResult(
                "capacity",
                True,
                details={
                    "parameters": {
                        "context_tokens": 73824,
                        "input_tokens": 65536,
                        "output_tokens": 8192,
                        "parallel_slots": 1,
                    },
                    "token_rate_summary": summary,
                    "token_metrics": [],
                },
            )

        with patch.object(cluster_tests, "capacity_test", side_effect=fake_capacity_test):
            result = cluster_tests.capacity_test_series(
                {"metrics_db": ""},
                warmup=True,
                repetitions=3,
            )

        self.assertTrue(result.ok, result.render())
        self.assertEqual(
            result.details["median"]["prompt_tokens_per_second"], 30.0
        )
        self.assertEqual(
            result.details["median"]["generation_tokens_per_second"], 40.0
        )
        self.assertEqual(len(result.details["samples"]), 3)


class DashboardConfigurationTests(unittest.TestCase):
    def test_preserves_smaller_timing_defaults_over_installed_capacity(self) -> None:
        cluster_environment = {
            "NODE_ROLE": "server",
            "PARALLEL_SLOTS": "3",
            "CONTEXT_PER_SLOT": "524288",
        }
        dashboard_config = (
            '{"capacity_test_input_tokens":65536,'
            '"capacity_test_context_tokens":73824,'
            '"capacity_test_output_tokens":8192,'
            '"capacity_test_parallel_slots":1,'
            '"capacity_test_warmup":true,'
            '"capacity_test_repetitions":3}'
        )
        with (
            patch.object(
                cluster_monitor,
                "parse_env_file",
                side_effect=[cluster_environment, {}],
            ),
            patch.object(
                cluster_monitor.Path,
                "read_text",
                return_value=dashboard_config,
            ),
        ):
            config = cluster_monitor.load_config("/etc/qwen3d8/dashboard.json")

        self.assertEqual(config["capacity_test_input_tokens"], 65536)
        self.assertEqual(config["capacity_test_context_tokens"], 73824)
        self.assertEqual(config["capacity_test_output_tokens"], 8192)
        self.assertEqual(config["capacity_test_parallel_slots"], 1)
        self.assertTrue(config["capacity_test_warmup"])
        self.assertEqual(config["capacity_test_repetitions"], 3)

    def test_loads_yarn_settings_from_cluster_environment(self) -> None:
        cluster_environment = {
            "NODE_ROLE": "server",
            "PARALLEL_SLOTS": "3",
            "CONTEXT_PER_SLOT": "524288",
            "NATIVE_CONTEXT_PER_SLOT": "262144",
            "CONTEXT_SCALING": "yarn",
            "YARN_ROPE_SCALE": "2",
        }
        with patch.object(
            cluster_monitor,
            "parse_env_file",
            side_effect=[cluster_environment, {}],
        ):
            config = cluster_monitor.load_config()

        self.assertEqual(config["expected_context_per_slot"], 524288)
        self.assertEqual(config["capacity_test_context_tokens"], 524288)
        self.assertEqual(config["native_context_per_slot"], 262144)
        self.assertEqual(config["context_scaling"], "yarn")
        self.assertEqual(config["yarn_rope_scale"], 2.0)


class YarnConfigurationTests(unittest.TestCase):
    def test_server_configuration_validates_yarn_settings(self) -> None:
        environment = "\n".join(
            (
                "NODE_ROLE=server",
                "MODEL_QUANT=UD-Q4_K_XL",
                "PARALLEL_SLOTS=3",
                "CONTEXT_PER_SLOT=524288",
                "NATIVE_CONTEXT_PER_SLOT=262144",
                "CONTEXT_SCALING=yarn",
                "YARN_ROPE_SCALE=2",
                "YARN_MODEL_CONTEXT_OVERRIDE=qwen4exp.context_length=int:524288",
            )
        )
        unit = "\n".join(
            (
                "[Service]",
                "ExecStart=/usr/local/bin/llama-server \\",
                "  --parallel 3 \\",
                "  --kv-unified-per-slot 524288 \\",
                "  --override-kv qwen4exp.context_length=int:524288 \\",
                "  --rope-scaling yarn \\",
                "  --rope-scale 2 \\",
                "  --yarn-orig-ctx 262144",
            )
        )
        slots = [{"n_ctx": 524288} for _ in range(3)]
        with (
            patch.object(cluster_tests.Path, "read_text", return_value=environment),
            patch.object(cluster_tests, "_unit_text", return_value=unit),
            patch.object(
                cluster_tests,
                "service_state",
                return_value={"active": True, "state": "active"},
            ),
            patch.object(
                cluster_tests,
                "http_json",
                side_effect=[
                    (200, {"status": "ok"}),
                    (200, {"total_slots": 3}),
                    (200, slots),
                ],
            ),
        ):
            result = cluster_tests.configuration_test(
                {
                    "role": "server",
                    "llama_url": "http://127.0.0.1:8081",
                    "expected_parallel_slots": 3,
                    "expected_context_per_slot": 524288,
                    "native_context_per_slot": 262144,
                }
            )

        self.assertTrue(result.ok, result.render())
        self.assertIn(
            "[PASS] cluster.env enables YaRN 2x from 262144 tokens",
            result.lines,
        )
        self.assertIn(
            "[PASS] systemd enables YaRN 2x and overrides the model context limit",
            result.lines,
        )

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
            cluster_dashboard, "capacity_test", return_value=expected
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
            output_tokens=1,
            parallel=3,
            cancel_event=cancel_event,
            progress=runner_progress,
        )


class InstalledConfigurationTests(unittest.TestCase):
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


class DashboardConfigurationTests(unittest.TestCase):
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

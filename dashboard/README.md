# Strix Halo Cluster Dashboard

This directory is intentionally independent from the cluster provisioning
scripts. It contains the read-only node telemetry agent, the on-demand
verification tests, the Gradio dashboard, and the installer for those
components.

## Install

Run the installer on the controller and worker after the normal cluster setup:

```bash
# For three extended 512 Ki Q4 slots, configure Qwen3.8 first:
# setup-qwen3d8.sh enables 2x YaRN automatically above the native 256 Ki limit.
sudo bash setup-qwen3d8.sh --role server --user <linux-user> --quant Q4 --context 512 --skip-foundation
sudo bash setup-qwen3d8.sh --role peer --user <linux-user> --quant Q4 --context 512 --skip-foundation

# Controller
sudo bash dashboard/setup-dashboard.sh \
  --role server \
  --dashboard-host 0.0.0.0

# Worker
sudo bash dashboard/setup-dashboard.sh --role peer
```

The installer reads `/etc/qwen3d8/cluster.env` and
`/etc/default/usb4-cluster`, installs the dashboard into
`/opt/qwen3d8-dashboard`, and creates:

- `qwen3d8-node-agent.service` on both nodes
- `qwen3d8-dashboard.service` on the controller

Rerunning the installer copies the current dashboard files and restarts its
managed services, so it is also the supported way to deploy dashboard updates.

The worker agent listens only on the private cluster address. The dashboard
defaults to port `7860`; the agent defaults to port `8765`. UFW rules are
added for the private agent link and the configured LAN networks.

The capacity-test defaults are configurable at install time:

```bash
sudo bash dashboard/setup-dashboard.sh \
  --role server \
  --test-output 2048 \
  --test-safety-margin 96
```

The dashboard installer does not accept context or parallel-capacity
parameters. It reads `CONTEXT_PER_SLOT` and `PARALLEL_SLOTS` from
`/etc/qwen3d8/cluster.env`, which is written by `setup-qwen3d8.sh`. Those
installed values are used for configuration checks and as the default capacity
test target. The dashboard UI and CLI can still request a smaller one-off test,
but a stale dashboard JSON value cannot override the installed Qwen capacity.
For Q4, `--context 512` configures a 512 Ki per-slot context with 2x YaRN
scaling from the model's native 256 Ki window.

Because the dashboard can start a large capacity test, use basic authentication
when it is reachable by more than a fully trusted LAN:

```bash
sudo bash dashboard/setup-dashboard.sh \
  --role server \
  --auth-user admin \
  --auth-password-file /root/dashboard-password
```

## Command-line tests

The test runner can be used without Gradio:

```bash
python3 dashboard/cluster_tests.py --config /etc/qwen3d8/dashboard.json configuration
python3 dashboard/cluster_tests.py --config /etc/qwen3d8/dashboard.json runtime
python3 dashboard/cluster_tests.py --config /etc/qwen3d8/dashboard.json capacity
python3 dashboard/cluster_tests.py --config /etc/qwen3d8/dashboard.json usb4
python3 dashboard/cluster_tests.py --config /etc/qwen3d8/dashboard.json all
```

The capacity test sends the configured number of concurrent synthetic requests
to `llama-server`. By default, each request uses the installed per-slot context
minus the configured output budget and safety margin. For a 256 Ki slot, this
is a 260,000-token prompt plus 2,048 generated tokens. Override it for a
smaller one-off CLI run:

```bash
python3 dashboard/cluster_tests.py \
  --config /etc/qwen3d8/dashboard.json \
  capacity --context-tokens 131072 --output-tokens 1024 --parallel 3
```

Each completed capacity request records prompt tokens/s, generation tokens/s,
wall-clock throughput, token counts, context size, and concurrency in the
SQLite database configured by `metrics_db` (normally
`/var/lib/qwen-dashboard/token-rates.sqlite3`). The dashboard shows
last-hour, last-24-hour, last-7-day, and all-time aggregates, plus per-slot
rates from the latest triggered test. Run capacity tests when no production
inference is active.

## Dashboard contents

The status area refreshes every five seconds and reports:

- installed Qwen model, quantization, per-slot context window, and slot count
- controller and worker health
- active inference slots and configured slot capacity
- used and available system RAM, swap, load, uptime, and disk space
- kernel temperature sensors and fan RPM readings when exposed by `hwmon`
- AMD DRM VRAM/GTT readings and the configured TTM limit when exposed by sysfs
- Qwen, RPC, Nginx, and ComfyUI service state
- USB4 link state and the established controller-to-worker RPC connection

The dashboard counts active llama.cpp slots as active inference users. The
current API does not authenticate human identities, so an idle Open WebUI
browser session cannot be distinguished from an idle client connection.

The controller checks its existing RPC connection rather than opening a second
connection to `ggml-rpc-server`, which serves one controller connection at a
time. The worker reports whether its private RPC listener is bound locally.

The USB4 throughput test is executed by the worker agent against the
controller's existing private `iperf3` service, then reports both worker-to-
controller and controller-to-worker directions.

The dashboard also includes a **Cancel running test** control and an in-memory
**Clear error log** control. The error log is in-memory. Cancellation is cooperative for inference tests and
terminates an active USB4 `iperf3` subprocess. The error log records telemetry
errors, failed assertions, warnings, and cancellation requests.

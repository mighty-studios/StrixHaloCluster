#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NODE_ROLE="${NODE_ROLE:-}"
DASHBOARD_HOST="${DASHBOARD_HOST:-0.0.0.0}"
DASHBOARD_PORT="${DASHBOARD_PORT:-7860}"
AGENT_PORT="${AGENT_PORT:-8765}"
LAN_NETS="${LAN_NETS:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"
AUTH_USER="${AUTH_USER:-}"
AUTH_PASSWORD_FILE="${AUTH_PASSWORD_FILE:-}"

APP_ROOT="${APP_ROOT:-/opt/qwen3d8-dashboard}"
CONFIG_ROOT="${CONFIG_ROOT:-/etc/qwen3d8}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_ROOT/dashboard.json}"
SERVICE_USER="${SERVICE_USER:-qwen-dashboard}"
VENV="${VENV:-$APP_ROOT/venv}"
METRICS_DB="${METRICS_DB:-/var/lib/$SERVICE_USER/token-rates.sqlite3}"
SERVER_RESTART_UNIT="${SERVER_RESTART_UNIT:-qwen3d8-server-restart.service}"
SERVER_RESTART_POLKIT_RULE="${SERVER_RESTART_POLKIT_RULE:-/etc/polkit-1/rules.d/49-qwen3d8-dashboard-restart.rules}"

CLUSTER_ENV="${CLUSTER_ENV:-/etc/qwen3d8/cluster.env}"
USB4_ENV="${USB4_ENV:-/etc/default/usb4-cluster}"
CLUSTER_IFACE="${CLUSTER_IFACE:-usb4llm0}"
LOCAL_IP="${LOCAL_IP:-10.200.0.1}"
PEER_IP="${PEER_IP:-10.200.0.2}"
RPC_PORT="${RPC_PORT:-50053}"
LLAMA_PORT="${LLAMA_PORT:-8081}"
IPERF_PORT="${IPERF_PORT:-5201}"
PARALLEL_SLOTS="${PARALLEL_SLOTS:-3}"
CONTEXT_PER_SLOT="${CONTEXT_PER_SLOT:-262144}"
CAPACITY_TEST_OUTPUT_TOKENS="${CAPACITY_TEST_OUTPUT_TOKENS:-8192}"
CAPACITY_TEST_SAFETY_MARGIN="${CAPACITY_TEST_SAFETY_MARGIN:-96}"
CAPACITY_TEST_INPUT_TOKENS="${CAPACITY_TEST_INPUT_TOKENS:-65536}"
CAPACITY_TEST_PARALLEL_SLOTS="${CAPACITY_TEST_PARALLEL_SLOTS:-1}"
CAPACITY_TEST_REPETITIONS="${CAPACITY_TEST_REPETITIONS:-3}"
CAPACITY_TEST_WARMUP="${CAPACITY_TEST_WARMUP:-1}"

BOLD=$'\e[1m'
RED=$'\e[31m'
GRN=$'\e[32m'
YLW=$'\e[33m'
BLU=$'\e[34m'
RST=$'\e[0m'

log()  { echo "${BLU}${BOLD}==>${RST} ${BOLD}$*${RST}"; }
ok()   { echo "${GRN}  ok:${RST} $*"; }
warn() { echo "${YLW}  warn:${RST} $*"; }
die()  { echo "${RED}${BOLD}ERROR:${RST} $*" >&2; exit 1; }

trap 'die "failed at line $LINENO. See the output above."' ERR

usage() {
  cat <<USAGE
Usage:
  sudo bash $SCRIPT_NAME --role <server|peer> [options]

Installs the dashboard tools independently from the main cluster installers.
Both roles receive the private read-only telemetry agent. The server role also
receives the Gradio dashboard and on-demand test runner.

Options:
  --role <server|peer>       Controller dashboard or worker telemetry agent
  --dashboard-host <addr>    Gradio bind address (server, default: $DASHBOARD_HOST)
  --dashboard-port <port>    Gradio port (server, default: $DASHBOARD_PORT)
  --agent-port <port>        Private telemetry port (default: $AGENT_PORT)
  --lan-nets "<cidrs>"       Networks allowed to reach the dashboard
  --auth-user <name>         Optional Gradio basic-auth username
  --auth-password-file <p>   File containing the optional Gradio password
  --test-input <tokens>      Capacity-test prompt input tokens (default: $CAPACITY_TEST_INPUT_TOKENS)
  --test-output <tokens>     Capacity-test generated tokens (default: $CAPACITY_TEST_OUTPUT_TOKENS)
  --test-parallel <slots>    Capacity-test concurrent slots (default: $CAPACITY_TEST_PARALLEL_SLOTS)
  --test-repetitions <n>     Measured capacity-test repetitions (default: $CAPACITY_TEST_REPETITIONS)
  --test-no-warmup           Disable the capacity-test warmup request
  --test-safety-margin <n>   Tokens reserved below the configured context (default: $CAPACITY_TEST_SAFETY_MARGIN)
  --metrics-db <path>        SQLite token-rate history path (default: $METRICS_DB)
  -h, --help                 Show this help

The script reads /etc/qwen3d8/cluster.env and /etc/default/usb4-cluster when
they exist. Run it on the controller first or copy the dashboard directory to
each node and run the matching role independently.
USAGE
}

need_arg() {
  [ -n "${2:-}" ] || die "$1 requires a value"
}

if [ -r "$CLUSTER_ENV" ]; then
  # shellcheck disable=SC1090
  . "$CLUSTER_ENV"
  NODE_ROLE="${NODE_ROLE:-${CLUSTER_ROLE:-}}"
  LOCAL_IP="${CLUSTER_LOCAL_IP:-$LOCAL_IP}"
  PEER_IP="${CLUSTER_PEER_IP:-$PEER_IP}"
  RPC_PORT="${RPC_PORT:-$RPC_PORT}"
  LLAMA_PORT="${LLAMA_PORT:-$LLAMA_PORT}"
  PARALLEL_SLOTS="${PARALLEL_SLOTS:-$PARALLEL_SLOTS}"
  CONTEXT_PER_SLOT="${CONTEXT_PER_SLOT:-$CONTEXT_PER_SLOT}"
fi
if [ -r "$USB4_ENV" ]; then
  # shellcheck disable=SC1090
  . "$USB4_ENV"
  CLUSTER_IFACE="${CLUSTER_IFACE:-$CLUSTER_IFACE}"
  IPERF_PORT="${IPERF_PORT:-$IPERF_PORT}"
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --role)
      need_arg "$1" "${2:-}"
      NODE_ROLE="$2"
      shift
      ;;
    --dashboard-host)
      need_arg "$1" "${2:-}"
      DASHBOARD_HOST="$2"
      shift
      ;;
    --dashboard-port)
      need_arg "$1" "${2:-}"
      DASHBOARD_PORT="$2"
      shift
      ;;
    --agent-port)
      need_arg "$1" "${2:-}"
      AGENT_PORT="$2"
      shift
      ;;
    --lan-nets)
      need_arg "$1" "${2:-}"
      LAN_NETS="$2"
      shift
      ;;
    --auth-user)
      need_arg "$1" "${2:-}"
      AUTH_USER="$2"
      shift
      ;;
    --auth-password-file)
      need_arg "$1" "${2:-}"
      AUTH_PASSWORD_FILE="$2"
      shift
      ;;
    --test-input)
      need_arg "$1" "${2:-}"
      CAPACITY_TEST_INPUT_TOKENS="$2"
      shift
      ;;
    --test-output)
      need_arg "$1" "${2:-}"
      CAPACITY_TEST_OUTPUT_TOKENS="$2"
      shift
      ;;
    --test-parallel)
      need_arg "$1" "${2:-}"
      CAPACITY_TEST_PARALLEL_SLOTS="$2"
      shift
      ;;
    --test-repetitions)
      need_arg "$1" "${2:-}"
      CAPACITY_TEST_REPETITIONS="$2"
      shift
      ;;
    --test-no-warmup)
      CAPACITY_TEST_WARMUP=0
      ;;
    --test-safety-margin)
      need_arg "$1" "${2:-}"
      CAPACITY_TEST_SAFETY_MARGIN="$2"
      shift
      ;;
    --metrics-db)
      need_arg "$1" "${2:-}"
      METRICS_DB="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
  shift
done

[ "$EUID" -eq 0 ] || die "run this installer with sudo"
command -v apt-get >/dev/null 2>&1 || die "this installer requires apt"
command -v systemctl >/dev/null 2>&1 || die "this installer requires systemd"
[ -r "$CLUSTER_ENV" ] \
  || die "$CLUSTER_ENV is missing; run setup-qwen3d8.sh on this node first"

# The Qwen installer is the source of truth for runtime capacity. The
# dashboard keeps its timing-test workload smaller than the installed capacity.
CAPACITY_TEST_CONTEXT_TOKENS=""
EXPECTED_CONTEXT_PER_SLOT="$CONTEXT_PER_SLOT"
EXPECTED_PARALLEL_SLOTS="$PARALLEL_SLOTS"

case "$NODE_ROLE" in
  server|controller|head|a) NODE_ROLE=server ;;
  peer|worker|b) NODE_ROLE=peer ;;
  *) die "--role must be server or peer" ;;
esac

for value in "$DASHBOARD_PORT" "$AGENT_PORT" "$RPC_PORT" "$LLAMA_PORT" "$IPERF_PORT"; do
  [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ] \
    || die "invalid port: $value"
done
[[ "$PARALLEL_SLOTS" =~ ^[0-9]+$ ]] && [ "$PARALLEL_SLOTS" -gt 0 ] \
  || die "parallel slot count must be positive"
[[ "$CONTEXT_PER_SLOT" =~ ^[0-9]+$ ]] && [ "$CONTEXT_PER_SLOT" -gt 0 ] \
  || die "context per slot must be positive"
[[ "$CAPACITY_TEST_INPUT_TOKENS" =~ ^[0-9]+$ ]] \
  && [ "$CAPACITY_TEST_INPUT_TOKENS" -gt 0 ] \
  || die "test input token count must be positive"
[[ "$CAPACITY_TEST_INPUT_TOKENS" =~ ^[0-9]+$ ]] \
  && [ "$CAPACITY_TEST_INPUT_TOKENS" -le 1048576 ] \
  || die "test input token count must be at most 1048576"
[[ "$CAPACITY_TEST_PARALLEL_SLOTS" =~ ^[0-9]+$ ]] \
  && [ "$CAPACITY_TEST_PARALLEL_SLOTS" -ge 1 ] \
  || die "test parallel slot count must be positive"
[[ "$CAPACITY_TEST_OUTPUT_TOKENS" =~ ^[0-9]+$ ]] \
  && [ "$CAPACITY_TEST_OUTPUT_TOKENS" -gt 0 ] \
  || die "test output token count must be positive"
[[ "$CAPACITY_TEST_SAFETY_MARGIN" =~ ^[0-9]+$ ]] \
  && [ "$CAPACITY_TEST_SAFETY_MARGIN" -ge 0 ] \
  || die "test safety margin must not be negative"
CAPACITY_TEST_CONTEXT_TOKENS=$(
  printf '%s\n' "$((CAPACITY_TEST_INPUT_TOKENS + CAPACITY_TEST_OUTPUT_TOKENS + CAPACITY_TEST_SAFETY_MARGIN))"
)
[[ "$CAPACITY_TEST_CONTEXT_TOKENS" -le 1048576 ]] \
  || die "test context must be at most 1048576 tokens"
[[ "$CAPACITY_TEST_CONTEXT_TOKENS" -le "$CONTEXT_PER_SLOT" ]] \
  || die "test context must not exceed the installed context per slot"
[[ "$CAPACITY_TEST_INPUT_TOKENS" -lt "$CONTEXT_PER_SLOT" ]] \
  || die "test input must be less than the installed context per slot"
[[ "$CAPACITY_TEST_PARALLEL_SLOTS" =~ ^[0-9]+$ ]] \
  && [ "$CAPACITY_TEST_PARALLEL_SLOTS" -ge 1 ] \
  && [ "$CAPACITY_TEST_PARALLEL_SLOTS" -le 32 ] \
  || die "test parallel slots must be between 1 and 32"
[[ "$CAPACITY_TEST_PARALLEL_SLOTS" -le "$PARALLEL_SLOTS" ]] \
  || die "test parallel slots must not exceed the installed slot count"
[[ "$CAPACITY_TEST_REPETITIONS" =~ ^[0-9]+$ ]] \
  && [ "$CAPACITY_TEST_REPETITIONS" -ge 1 ] \
  && [ "$CAPACITY_TEST_REPETITIONS" -le 10 ] \
  || die "test repetitions must be between 1 and 10"
case "$CAPACITY_TEST_WARMUP" in
  0|1) ;;
  *) die "test warmup setting must be 0 or 1" ;;
esac
[[ "$LOCAL_IP" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || die "invalid local IP: $LOCAL_IP"
[[ "$PEER_IP" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || die "invalid peer IP: $PEER_IP"
[[ "$DASHBOARD_HOST" =~ ^[A-Za-z0-9:.%-]+$ ]] || die "invalid dashboard host"
[[ "$CLUSTER_IFACE" =~ ^[A-Za-z][A-Za-z0-9_-]{0,14}$ ]] || die "invalid cluster interface"
[[ "$AUTH_USER" =~ ^[A-Za-z0-9._-]*$ ]] || die "auth username contains unsupported characters"
if [ -n "$AUTH_USER" ] && [ -z "$AUTH_PASSWORD_FILE" ]; then
  die "--auth-user requires --auth-password-file"
fi
if [ -n "$AUTH_PASSWORD_FILE" ]; then
  [ -r "$AUTH_PASSWORD_FILE" ] || die "auth password file is not readable: $AUTH_PASSWORD_FILE"
fi
[[ "$METRICS_DB" =~ ^/[A-Za-z0-9._/-]+$ ]] \
  || die "metrics database path must be an absolute path without spaces"

for file in \
    cluster_monitor.py \
    cluster_tests.py \
    cluster_node_agent.py \
    cluster_dashboard.py \
    token_metrics.py \
    requirements.txt; do
  [ -f "$SCRIPT_DIR/$file" ] || die "missing dashboard file: $SCRIPT_DIR/$file"
done

export DEBIAN_FRONTEND=noninteractive
log "Installing dashboard prerequisites"
apt-get update -y
apt-get install -y polkitd python3 python3-pip python3-venv ufw

if ! getent group "$SERVICE_USER" >/dev/null 2>&1; then
  groupadd --system "$SERVICE_USER"
fi
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd \
    --system \
    --gid "$SERVICE_USER" \
    --home-dir "/var/lib/$SERVICE_USER" \
    --create-home \
    --shell /usr/sbin/nologin \
    "$SERVICE_USER"
fi

install -d -m 0755 "$APP_ROOT"
install -d -m 0755 "$CONFIG_ROOT"
for file in \
    cluster_monitor.py \
    cluster_tests.py \
    cluster_node_agent.py \
    cluster_dashboard.py \
    token_metrics.py; do
  install -m 0644 "$SCRIPT_DIR/$file" "$APP_ROOT/$file"
done
install -m 0644 "$SCRIPT_DIR/requirements.txt" "$APP_ROOT/requirements.txt"

if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install --quiet -r "$APP_ROOT/requirements.txt"

AUTH_DEST=""
if [ -n "$AUTH_PASSWORD_FILE" ]; then
  AUTH_DEST="$CONFIG_ROOT/dashboard-password"
  install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0600 \
    "$AUTH_PASSWORD_FILE" "$AUTH_DEST"
fi

METRICS_DIR="$(dirname "$METRICS_DB")"
[ -d "$METRICS_DIR" ] \
  || die "metrics database directory does not exist: $METRICS_DIR"
if ! sudo -u "$SERVICE_USER" test -w "$METRICS_DIR"; then
  die "service user '$SERVICE_USER' cannot write metrics directory: $METRICS_DIR"
fi

if [ "$NODE_ROLE" = "server" ]; then
  MONITORED_PATHS='["/", "/srv/models"]'
else
  MONITORED_PATHS='["/", "/srv/llama-rpc-cache"]'
fi

cat > "$CONFIG_FILE" <<CONFIG
{
  "role": "$NODE_ROLE",
  "local_ip": "$LOCAL_IP",
  "peer_ip": "$PEER_IP",
  "agent_bind": "$LOCAL_IP",
  "agent_port": $AGENT_PORT,
  "peer_agent_url": "$([ "$NODE_ROLE" = "server" ] && printf 'http://%s:%s' "$PEER_IP" "$AGENT_PORT" || true)",
  "peer_agent_token_file": "",
  "llama_url": "$([ "$NODE_ROLE" = "server" ] && printf 'http://127.0.0.1:%s' "$LLAMA_PORT" || true)",
  "rpc_port": $RPC_PORT,
  "iperf_port": $IPERF_PORT,
  "cluster_iface": "$CLUSTER_IFACE",
  "parallel_slots": $PARALLEL_SLOTS,
  "context_per_slot": $CONTEXT_PER_SLOT,
  "expected_parallel_slots": $EXPECTED_PARALLEL_SLOTS,
  "expected_context_per_slot": $EXPECTED_CONTEXT_PER_SLOT,
  "capacity_test_input_tokens": $CAPACITY_TEST_INPUT_TOKENS,
  "capacity_test_context_tokens": $CAPACITY_TEST_CONTEXT_TOKENS,
  "capacity_test_output_tokens": $CAPACITY_TEST_OUTPUT_TOKENS,
  "capacity_test_parallel_slots": $CAPACITY_TEST_PARALLEL_SLOTS,
  "capacity_test_safety_margin_tokens": $CAPACITY_TEST_SAFETY_MARGIN,
  "capacity_test_warmup": $([ "$CAPACITY_TEST_WARMUP" = "1" ] && printf true || printf false),
  "capacity_test_repetitions": $CAPACITY_TEST_REPETITIONS,
  "metrics_db": "$METRICS_DB",
  "dashboard_host": "$DASHBOARD_HOST",
  "dashboard_port": $DASHBOARD_PORT,
  "auth_user": "$AUTH_USER",
  "auth_password_file": "$AUTH_DEST",
  "paths": $MONITORED_PATHS
}
CONFIG
chown "$SERVICE_USER:$SERVICE_USER" "$CONFIG_FILE"
chmod 0644 "$CONFIG_FILE"

cat > /etc/systemd/system/qwen3d8-node-agent.service <<UNIT
[Unit]
Description=Strix Halo cluster read-only node telemetry agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$APP_ROOT
Environment=PYTHONUNBUFFERED=1
Environment=HOME=/var/lib/$SERVICE_USER
ExecStart=$VENV/bin/python $APP_ROOT/cluster_node_agent.py --config $CONFIG_FILE --bind $LOCAL_IP --port $AGENT_PORT
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/lib/$SERVICE_USER
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
UNIT

if [ "$NODE_ROLE" = "server" ]; then
  cat > /etc/systemd/system/qwen3d8-dashboard.service <<UNIT
[Unit]
Description=Strix Halo Gradio cluster dashboard
After=network-online.target qwen3d8-server.service qwen3d8-node-agent.service
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$APP_ROOT
Environment=PYTHONUNBUFFERED=1
Environment=HOME=/var/lib/$SERVICE_USER
ExecStart=$VENV/bin/python $APP_ROOT/cluster_dashboard.py --config $CONFIG_FILE
Restart=always
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/lib/$SERVICE_USER
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
UNIT

  cat > /etc/systemd/system/$SERVER_RESTART_UNIT <<UNIT
[Unit]
Description=Controlled Qwen server restart requested by the dashboard
ConditionPathExists=/etc/systemd/system/qwen3d8-server.service

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart qwen3d8-server.service
UNIT

  install -d -m 0755 /etc/polkit-1/rules.d
  cat > "$SERVER_RESTART_POLKIT_RULE" <<POLKIT
// Managed by $SCRIPT_NAME. Allow only the dashboard service to start the
// dedicated helper; the helper performs the privileged Qwen restart.
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "$SERVER_RESTART_UNIT" &&
        action.lookup("verb") == "start" &&
        subject.user == "$SERVICE_USER") {
        return polkit.Result.YES;
    }
});
POLKIT
  chmod 0644 "$SERVER_RESTART_POLKIT_RULE"
else
  systemctl disable --now qwen3d8-dashboard.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/qwen3d8-dashboard.service
  rm -f "/etc/systemd/system/$SERVER_RESTART_UNIT" "$SERVER_RESTART_POLKIT_RULE"
fi

systemctl daemon-reload
systemctl enable qwen3d8-node-agent.service
systemctl restart qwen3d8-node-agent.service
systemctl is-active --quiet qwen3d8-node-agent.service \
  || die "qwen3d8-node-agent.service did not start"

if [ "$NODE_ROLE" = "server" ]; then
  systemctl enable qwen3d8-dashboard.service
  systemctl restart qwen3d8-dashboard.service
  systemctl is-active --quiet qwen3d8-dashboard.service \
    || die "qwen3d8-dashboard.service did not start"
fi

if command -v ufw >/dev/null 2>&1; then
  ufw allow in on "$CLUSTER_IFACE" from "$PEER_IP" \
    to "$LOCAL_IP" port "$AGENT_PORT" proto tcp >/dev/null 2>&1 || true
  if [ "$NODE_ROLE" = "server" ]; then
    for net in $LAN_NETS; do
      ufw allow from "$net" to any port "$DASHBOARD_PORT" proto tcp >/dev/null 2>&1 || true
    done
  fi
  if ufw status 2>/dev/null | grep '^Status: active' >/dev/null; then
    ufw reload >/dev/null 2>&1 || true
  fi
fi

echo
echo "${GRN}${BOLD}Dashboard tooling installed on $(hostname -s)${RST}"
echo "  role:          $NODE_ROLE"
echo "  node agent:    $LOCAL_IP:$AGENT_PORT"
if [ "$NODE_ROLE" = "server" ]; then
  echo "  dashboard:     http://$(hostname -s):$DASHBOARD_PORT"
  echo "  config:        $CONFIG_FILE"
  echo "  service:       qwen3d8-dashboard.service"
fi
echo "  agent service:  qwen3d8-node-agent.service"

#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NODE_ROLE="${NODE_ROLE:-}"
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || true)}}"
TARGET_PASSWORD_FILE="${TARGET_PASSWORD_FILE:-}"

RUN_FOUNDATION="${RUN_FOUNDATION:-1}"
INSTALL_ROCM="${INSTALL_ROCM:-1}"
CONFIGURE_MEMORY="${CONFIGURE_MEMORY:-1}"
BUILD_LLAMA_CPP="${BUILD_LLAMA_CPP:-1}"
DOWNLOAD_MODEL="${DOWNLOAD_MODEL:-1}"
INSTALL_WEBUI="${INSTALL_WEBUI:-1}"

ROCM_VERSION="${ROCM_VERSION:-10.0.0}"
ROCM_APT_VERSION="${ROCM_APT_VERSION:-10.0}"
ROCM_GFX="${ROCM_GFX:-gfx1151}"
ROCM_REPO_URL="${ROCM_REPO_URL:-}"
ROCM_GPG_URL="${ROCM_GPG_URL:-https://stable.repo.amd.com/rocm/gpg/packages.gpg}"
ROCM_PKG="${ROCM_PKG:-}"
ROCM_DEV_PKG="${ROCM_DEV_PKG:-}"

GTT_GIB="${GTT_GIB:-120}"

LLAMA_CPP_REPO="${LLAMA_CPP_REPO:-https://github.com/ggml-org/llama.cpp}"
LLAMA_CPP_TAG="${LLAMA_CPP_TAG:-v0.4.0}"
LLAMA_CPP_COMMIT="${LLAMA_CPP_COMMIT:-427291b5b34cd914a31b3fd3b61a68f6184f4b9f}"
LLAMA_SRC="${LLAMA_SRC:-/opt/llama.cpp-qwen3d8}"
LLAMA_BUILD="${LLAMA_BUILD:-$LLAMA_SRC/build}"

LLAMA_USER="${LLAMA_USER:-llama}"
LLAMA_HOME="${LLAMA_HOME:-/var/lib/llama}"
MODEL_ROOT="${MODEL_ROOT:-/srv/models/Qwen3.8-Flash-Next}"
QUANT="${QUANT:-Q4}"
MODEL_QUANT=""
MODEL_DIR=""
MODEL_FILE=""
MODEL_REPO="${MODEL_REPO:-unsloth/Qwen3.8-Flash-Next-GGUF}"
MODEL_REVISION="${MODEL_REVISION:-38bb39ee97821de2c9009abb7e93950eec396e66}"
MODEL_EXPECTED_BYTES=""
MODEL_SHARD_COUNT=""
MODEL_MEMORY_ESTIMATE_GIB=""
MODEL_ARTIFACT_GIB=""
MODEL_ALIAS=""
HF_TOOLS_VENV="${HF_TOOLS_VENV:-/opt/qwen3d8-hf-tools}"
LARGE_QUANT_BLOCKER_SOURCE="${LARGE_QUANT_BLOCKER_SOURCE:-https://github.com/ggml-org/llama.cpp/issues/27865#issuecomment-5551333251}"
MODEL_SIZE_SOURCE="${MODEL_SIZE_SOURCE:-https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/tree/$MODEL_REVISION}"
CONFIG_ROOT="/etc/qwen3d8"

RPC_CACHE="${RPC_CACHE:-/srv/llama-rpc-cache}"
RPC_CACHE_ENABLED="${RPC_CACHE_ENABLED:-0}"
RPC_CACHE_MIN_GIB="${RPC_CACHE_MIN_GIB:-}"
RPC_PORT="${RPC_PORT:-50053}"
LLAMA_PORT="${LLAMA_PORT:-8081}"
WEBUI_HOST_PORT="${WEBUI_HOST_PORT:-3000}"
NGINX_PORT="${NGINX_PORT:-80}"

PARALLEL_SLOTS="${PARALLEL_SLOTS:-3}"
CONTEXT_K="${CONTEXT_K:-}"
LEGACY_CONTEXT_PER_SLOT="${CONTEXT_PER_SLOT:-}"
CONTEXT_PER_SLOT=""
NATIVE_CONTEXT_K=256
NATIVE_CONTEXT_PER_SLOT=$((NATIVE_CONTEXT_K * 1024))
MAX_Q4_CONTEXT_K=512
CONTEXT_SCALING="native"
YARN_ROPE_SCALE=""
YARN_MODEL_CONTEXT_OVERRIDE=""
YARN_SERVER_ARGS=""
KV_CACHE_TYPE="${KV_CACHE_TYPE:-f16}"
TENSOR_SPLIT="${TENSOR_SPLIT:-}"
HOST_BUFFER_ESTIMATE_GIB="${HOST_BUFFER_ESTIMATE_GIB:-60}"
MIN_HEADROOM_GIB="${MIN_HEADROOM_GIB:-8}"
KV_MEMORY_ESTIMATE_GIB=""
TOTAL_DISTRIBUTED_ESTIMATE_GIB=""
CONTROLLER_ESTIMATE_GIB=""
PEER_ESTIMATE_GIB=""
CONTROLLER_HEADROOM_GIB=""
PEER_HEADROOM_GIB=""

OPENWEBUI_IMAGE="${OPENWEBUI_IMAGE:-ghcr.io/open-webui/open-webui:main}"
OPENWEBUI_CONTAINER="${OPENWEBUI_CONTAINER:-open-webui}"
OPENWEBUI_DATA="${OPENWEBUI_DATA:-/var/lib/open-webui}"
OPENWEBUI_SECRET_FILE="${OPENWEBUI_SECRET_FILE:-/etc/qwen3d8/openwebui-secret}"

LAN_NETS="${LAN_NETS:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"

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

ACTIONS=()
note_action() { ACTIONS+=("$*"); }
REBOOT_REQUIRED=0

ensure_boot_unit() {
  local unit="$1"
  local state

  systemctl enable "$unit" >/dev/null 2>&1 || true
  state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  case "$state" in
    enabled|enabled-runtime|static|indirect|generated|alias)
      ok "$unit is boot-persistent ($state)"
      ;;
    *)
      die "$unit is not boot-persistent (state: ${state:-unknown})"
      ;;
  esac
}

# =============================================================================
# 1. CONFIGURATION AND VALIDATION
# =============================================================================
usage() {
  cat <<USAGE
Usage:
  sudo bash $SCRIPT_NAME --role <server|peer> [options]

Recommended order:
  1. Run --role server on the controller.
  2. Run --role peer on the RPC worker.
  3. Reboot both nodes if requested.

The same script is used on both nodes so ROCm and llama.cpp remain identical.

Options:
  --role <server|peer>       Controller/API node or RPC worker
  --quant <Q4|Q5|Q6>        Model quantization (default: Q4)
  --balance <a,b>            Controller,peer ratio (default: computed per quant)
  --context <K>              Context per slot in Ki-tokens; 256 = 262,144 tokens
                             (default: 192 = 196,608 tokens; Q4 maximum: 512)
                             Q4 contexts above 256 use YaRN automatically;
                             Q5 and Q6 are limited to the native 256 Ki context.
  --user <name>              Desktop account passed to setup-environment.sh
  --password-file <path>     Password file passed to setup-environment.sh
  --model-root <path>        Controller model root (default: $MODEL_ROOT)
  --rpc-cache <path>         Optional peer RPC cache path (default: $RPC_CACHE)
  --enable-rpc-cache         Enable the optional peer RPC disk cache
  --gtt-gib <gib>            TTM/GTT mapping limit (default: $GTT_GIB)
  --kv-cache <type>          llama.cpp K/V cache type (default: $KV_CACHE_TYPE)
  --tensor-split <a,b>       Alias for --balance
  --skip-foundation          Do not run setup-environment.sh
  --skip-rocm                Do not install ROCm
  --skip-memory              Do not configure TTM/GTT
  --skip-build               Do not build llama.cpp
  --skip-model               Do not download/verify the selected model
  --no-webui                 Do not install Docker, Open WebUI, or Nginx
  -h, --help                 Show this help

Planning values:
  Q4 = 110 GiB, Q5 = 150 GiB, Q6 = 160 GiB.
  Controller-only Gated DeltaNet host buffer allowance = 60 GiB.
  The automatic balance ratio equalizes estimated node use while preserving
  slightly more headroom on the controller.

Known upstream-tracker report:
  A non-maintainer user reported that Qwen3.8 Q5/Q6 RPC on two gfx1151 nodes
  exhausted the controller because an approximately 52 GiB Gated DeltaNet host
  buffer was not distributed. This is not a maintainer-confirmed limitation.
  Source: $LARGE_QUANT_BLOCKER_SOURCE
USAGE
}

need_arg() {
  [ -n "${2:-}" ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --role)
      need_arg "$1" "${2:-}"
      NODE_ROLE="$2"
      shift
      ;;
    --quant)
      need_arg "$1" "${2:-}"
      QUANT="$2"
      shift
      ;;
    --balance|--tensor-split)
      need_arg "$1" "${2:-}"
      TENSOR_SPLIT="$2"
      shift
      ;;
    --context|--context-k)
      need_arg "$1" "${2:-}"
      CONTEXT_K="$2"
      shift
      ;;
    --user)
      need_arg "$1" "${2:-}"
      TARGET_USER="$2"
      shift
      ;;
    --password-file)
      need_arg "$1" "${2:-}"
      TARGET_PASSWORD_FILE="$2"
      shift
      ;;
    --model-root)
      need_arg "$1" "${2:-}"
      MODEL_ROOT="$2"
      shift
      ;;
    --rpc-cache)
      need_arg "$1" "${2:-}"
      RPC_CACHE="$2"
      shift
      ;;
    --enable-rpc-cache)
      RPC_CACHE_ENABLED=1
      ;;
    --gtt-gib)
      need_arg "$1" "${2:-}"
      GTT_GIB="$2"
      shift
      ;;
    --kv-cache)
      need_arg "$1" "${2:-}"
      KV_CACHE_TYPE="$2"
      shift
      ;;
    --skip-foundation)
      RUN_FOUNDATION=0
      ;;
    --skip-rocm)
      INSTALL_ROCM=0
      ;;
    --skip-memory)
      CONFIGURE_MEMORY=0
      ;;
    --skip-build)
      BUILD_LLAMA_CPP=0
      ;;
    --skip-model)
      DOWNLOAD_MODEL=0
      ;;
    --no-webui)
      INSTALL_WEBUI=0
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
command -v apt-get >/dev/null 2>&1 || die "this installer requires Ubuntu or another apt-based system"
command -v systemctl >/dev/null 2>&1 || die "this installer requires systemd"

case "$NODE_ROLE" in
  server|controller|head|a) NODE_ROLE=server ;;
  peer|worker|b) NODE_ROLE=peer ;;
  *) die "--role must be server or peer" ;;
esac

# =============================================================================
# 2. MODEL AND MEMORY PLAN
# =============================================================================
resolve_quant() {
  # Exact byte totals come from the pinned Hugging Face repository tree.
  # Planning sizes are each exact GiB total rounded upward to the next 10 GiB.
  case "${QUANT^^}" in
    Q4|Q4_K_XL|UD-Q4_K_XL)
      QUANT=Q4
      MODEL_QUANT=UD-Q4_K_XL
      MODEL_SHARD_COUNT=4
      MODEL_EXPECTED_BYTES=111334654784
      MODEL_MEMORY_ESTIMATE_GIB=110
      MODEL_FILE="$MODEL_ROOT/$MODEL_QUANT/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf"
      ;;
    Q5|Q5_K_XL|UD-Q5_K_XL)
      QUANT=Q5
      MODEL_QUANT=UD-Q5_K_XL
      MODEL_SHARD_COUNT=6
      MODEL_EXPECTED_BYTES=158286406650
      MODEL_MEMORY_ESTIMATE_GIB=150
      MODEL_FILE="$MODEL_ROOT/$MODEL_QUANT/Qwen3.8-Flash-Next-UD-Q5_K_XL-00001-of-00006.gguf"
      ;;
    Q6|Q6_K_XL|UD-Q6_K_XL)
      QUANT=Q6
      MODEL_QUANT=UD-Q6_K_XL
      MODEL_SHARD_COUNT=6
      MODEL_EXPECTED_BYTES=169165382688
      MODEL_MEMORY_ESTIMATE_GIB=160
      MODEL_FILE="$MODEL_ROOT/$MODEL_QUANT/Qwen3.8-Flash-Next-UD-Q6_K_XL-00001-of-00006.gguf"
      ;;
    *)
      die "--quant must be Q4, Q5, or Q6"
      ;;
  esac
  MODEL_DIR="$MODEL_ROOT/$MODEL_QUANT"
  MODEL_ALIAS="qwen3.8-flash-next-${QUANT,,}"
  MODEL_ARTIFACT_GIB="$(
    awk -v bytes="$MODEL_EXPECTED_BYTES" \
      'BEGIN { printf "%.3f", bytes / 1073741824 }'
  )"
}

estimate_kv_memory() {
  local bytes_per_element
  case "$KV_CACHE_TYPE" in
    f16|bf16) bytes_per_element=2 ;;
    q8_0|q5_0|q5_1|q4_0|q4_1|iq4_nl)
      # Conservative allowance for block scales and alignment overhead.
      bytes_per_element=1.125
      ;;
    *) bytes_per_element=2 ;;
  esac

  # 12 QSA layers, 2 KV heads, head_dim 256, K+V. Quantized layouts include
  # scale/block overhead, so q4/q5 are conservatively budgeted like q8 here.
  KV_MEMORY_ESTIMATE_GIB="$(
    awk \
      -v slots="$PARALLEL_SLOTS" \
      -v context="$CONTEXT_PER_SLOT" \
      -v bytes="$bytes_per_element" \
      'BEGIN {
        gib = slots * context * 12 * 2 * 256 * 2 * bytes / 1073741824;
        print int(gib) + (gib > int(gib) ? 1 : 0);
      }'
  )"
}

compute_memory_plan() {
  estimate_kv_memory
  TOTAL_DISTRIBUTED_ESTIMATE_GIB=$((MODEL_MEMORY_ESTIMATE_GIB + KV_MEMORY_ESTIMATE_GIB))

  if [ -z "$TENSOR_SPLIT" ]; then
    local controller_ratio
    local peer_ratio
    controller_ratio="$(
      awk \
        -v distributed="$TOTAL_DISTRIBUTED_ESTIMATE_GIB" \
        -v host="$HOST_BUFFER_ESTIMATE_GIB" \
        'BEGIN {
          ratio = int(((distributed - host) / (2 * distributed)) * 100);
          if (ratio < 1) ratio = 1;
          if (ratio > 49) ratio = 49;
          print ratio;
        }'
    )"
    peer_ratio=$((100 - controller_ratio))
    TENSOR_SPLIT="$controller_ratio,$peer_ratio"
  fi

  local controller_ratio
  local peer_ratio
  local ratio_sum
  controller_ratio="${TENSOR_SPLIT%%,*}"
  peer_ratio="${TENSOR_SPLIT#*,}"
  ratio_sum=$((controller_ratio + peer_ratio))
  [ "$ratio_sum" -gt 0 ] || die "node balance must sum to more than zero"

  CONTROLLER_ESTIMATE_GIB="$(
    awk \
      -v distributed="$TOTAL_DISTRIBUTED_ESTIMATE_GIB" \
      -v ratio="$controller_ratio" \
      -v total="$ratio_sum" \
      -v host="$HOST_BUFFER_ESTIMATE_GIB" \
      'BEGIN { printf "%.1f", distributed * ratio / total + host }'
  )"
  PEER_ESTIMATE_GIB="$(
    awk \
      -v distributed="$TOTAL_DISTRIBUTED_ESTIMATE_GIB" \
      -v ratio="$peer_ratio" \
      -v total="$ratio_sum" \
      'BEGIN { printf "%.1f", distributed * ratio / total }'
  )"
  CONTROLLER_HEADROOM_GIB="$(
    awk -v limit="$GTT_GIB" -v used="$CONTROLLER_ESTIMATE_GIB" \
      'BEGIN { printf "%.1f", limit - used }'
  )"
  PEER_HEADROOM_GIB="$(
    awk -v limit="$GTT_GIB" -v used="$PEER_ESTIMATE_GIB" \
      'BEGIN { printf "%.1f", limit - used }'
  )"

  if awk -v value="$CONTROLLER_HEADROOM_GIB" 'BEGIN { exit !(value < 0) }'; then
    die "balance $TENSOR_SPLIT estimates controller use at ${CONTROLLER_ESTIMATE_GIB} GiB, above the ${GTT_GIB} GiB limit"
  fi
  if awk -v value="$PEER_HEADROOM_GIB" 'BEGIN { exit !(value < 0) }'; then
    die "balance $TENSOR_SPLIT estimates peer use at ${PEER_ESTIMATE_GIB} GiB, above the ${GTT_GIB} GiB limit"
  fi

  if [ "$RPC_CACHE_ENABLED" = "1" ] && [ -z "$RPC_CACHE_MIN_GIB" ]; then
    RPC_CACHE_MIN_GIB="$(
      awk \
        -v model="$MODEL_MEMORY_ESTIMATE_GIB" \
        -v ratio="$peer_ratio" \
        -v total="$ratio_sum" \
        'BEGIN {
          required = model * ratio / total + 20;
          print int(required) + (required > int(required) ? 1 : 0);
        }'
    )"
  fi
}

resolve_quant

[ -n "$TARGET_USER" ] || die "could not determine the desktop account; pass --user"
case "$RPC_CACHE_ENABLED" in
  0|1) ;;
  *) die "RPC_CACHE_ENABLED must be 0 or 1" ;;
esac
[[ "$GTT_GIB" =~ ^[0-9]+$ ]] || die "--gtt-gib must be a whole number"
[[ "$HOST_BUFFER_ESTIMATE_GIB" =~ ^[0-9]+$ ]] \
  || die "HOST_BUFFER_ESTIMATE_GIB must be a whole number"
[[ "$MIN_HEADROOM_GIB" =~ ^[0-9]+$ ]] \
  || die "MIN_HEADROOM_GIB must be a whole number"
if [ -n "$RPC_CACHE_MIN_GIB" ]; then
  [[ "$RPC_CACHE_MIN_GIB" =~ ^[0-9]+$ ]] \
    || die "RPC_CACHE_MIN_GIB must be a whole number"
fi
[[ "$RPC_PORT" =~ ^[0-9]+$ ]] || die "RPC_PORT must be numeric"
[[ "$LLAMA_PORT" =~ ^[0-9]+$ ]] || die "LLAMA_PORT must be numeric"
[[ "$PARALLEL_SLOTS" =~ ^[0-9]+$ ]] || die "PARALLEL_SLOTS must be numeric"
if [ -z "$CONTEXT_K" ]; then
  if [ -n "$LEGACY_CONTEXT_PER_SLOT" ]; then
    [[ "$LEGACY_CONTEXT_PER_SLOT" =~ ^[0-9]+$ ]] \
      || die "CONTEXT_PER_SLOT must be numeric"
    [ $((LEGACY_CONTEXT_PER_SLOT % 1024)) -eq 0 ] \
      || die "CONTEXT_PER_SLOT must be a whole multiple of 1024 tokens"
    CONTEXT_K=$((LEGACY_CONTEXT_PER_SLOT / 1024))
  else
    CONTEXT_K=192
  fi
fi
[[ "$CONTEXT_K" =~ ^[0-9]+$ ]] || die "--context must be a whole Ki-token value"
[ "$CONTEXT_K" -ge 1 ] && [ "$CONTEXT_K" -le "$MAX_Q4_CONTEXT_K" ] \
  || die "--context must be between 1 and $MAX_Q4_CONTEXT_K Ki-tokens"
CONTEXT_PER_SLOT=$((CONTEXT_K * 1024))
if [ "$CONTEXT_K" -gt "$NATIVE_CONTEXT_K" ]; then
  [ "$QUANT" = "Q4" ] \
    || die "--context above $NATIVE_CONTEXT_K Ki-tokens is supported only with Q4"
  CONTEXT_SCALING="yarn"
  YARN_ROPE_SCALE="$(
    awk -v context="$CONTEXT_PER_SLOT" -v native="$NATIVE_CONTEXT_PER_SLOT" \
      'BEGIN { printf "%.9g", context / native }'
  )"
  YARN_MODEL_CONTEXT_OVERRIDE="qwen4exp.context_length=int:$CONTEXT_PER_SLOT"
  YARN_SERVER_ARGS="--override-kv $YARN_MODEL_CONTEXT_OVERRIDE --rope-scaling yarn --rope-scale $YARN_ROPE_SCALE --yarn-orig-ctx $NATIVE_CONTEXT_PER_SLOT"
  note_action "YaRN extends Qwen's native ${NATIVE_CONTEXT_K} Ki context; validate capacity and long-context quality before production use."
fi
if [ -n "$TENSOR_SPLIT" ]; then
  [[ "$TENSOR_SPLIT" =~ ^[0-9]+,[0-9]+$ ]] \
    || die "--balance must contain two positive integer proportions"
  [ "${TENSOR_SPLIT%%,*}" -gt 0 ] && [ "${TENSOR_SPLIT#*,}" -gt 0 ] \
    || die "--balance proportions must both be greater than zero"
fi
case "$KV_CACHE_TYPE" in
  f16|bf16|q8_0|q4_0|q4_1|iq4_nl|q5_0|q5_1) ;;
  *) die "unsupported KV cache type: $KV_CACHE_TYPE" ;;
esac

compute_memory_plan

for path in \
    "$MODEL_ROOT" \
    "$RPC_CACHE" \
    "$LLAMA_SRC" \
    "$LLAMA_BUILD" \
    "$LLAMA_HOME" \
    "$HF_TOOLS_VENV" \
    "$OPENWEBUI_DATA" \
    "$CONFIG_ROOT"; do
  [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "unsafe path: $path"
  case "$path" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "refusing broad system path: $path"
      ;;
  esac
done
[ "$MODEL_ROOT" != "$RPC_CACHE" ] || die "MODEL_ROOT and RPC_CACHE must differ"
[ "$LLAMA_SRC" != "$LLAMA_BUILD" ] || die "LLAMA_SRC and LLAMA_BUILD must differ"

if [ "$RUN_FOUNDATION" = "1" ]; then
  [ -f "$SCRIPT_DIR/setup-environment.sh" ] \
    || die "setup-environment.sh must be beside $SCRIPT_NAME"

  foundation_args=(--role "$NODE_ROLE" --user "$TARGET_USER" --headless-boot)
  if [ -n "$TARGET_PASSWORD_FILE" ]; then
    foundation_args+=(--password-file "$TARGET_PASSWORD_FILE")
  fi

  log "Installing the shared cluster foundation"
  bash "$SCRIPT_DIR/setup-environment.sh" "${foundation_args[@]}"
fi

[ -r /etc/default/usb4-cluster ] \
  || die "/etc/default/usb4-cluster is missing; run setup-environment.sh first"
# shellcheck disable=SC1091
. /etc/default/usb4-cluster

[ "${CLUSTER_ROLE:-}" = "$NODE_ROLE" ] \
  || die "USB4 role '${CLUSTER_ROLE:-unset}' does not match requested role '$NODE_ROLE'"
[ -n "${CLUSTER_LOCAL_IP:-}" ] && [ -n "${CLUSTER_PEER_IP:-}" ] \
  || die "USB4 addresses are missing from /etc/default/usb4-cluster"

log "Selected Qwen3.8 configuration"
echo "  quant:                    $QUANT ($MODEL_QUANT)"
echo "  context per slot:         ${CONTEXT_K} Ki ($CONTEXT_PER_SLOT tokens)"
if [ "$CONTEXT_SCALING" = "yarn" ]; then
  echo "  context scaling:          YaRN ${YARN_ROPE_SCALE}x from ${NATIVE_CONTEXT_PER_SLOT} tokens"
  echo "  context override:         $YARN_MODEL_CONTEXT_OVERRIDE"
else
  echo "  context scaling:          native"
fi
echo "  exact artifact:           $MODEL_ARTIFACT_GIB GiB"
echo "  rounded model budget:     $MODEL_MEMORY_ESTIMATE_GIB GiB"
echo "  KV estimate:              $KV_MEMORY_ESTIMATE_GIB GiB"
echo "  controller-only buffer:   $HOST_BUFFER_ESTIMATE_GIB GiB"
echo "  balance:                  $TENSOR_SPLIT (controller,peer)"
echo "  estimated controller use: $CONTROLLER_ESTIMATE_GIB GiB"
echo "  estimated peer use:       $PEER_ESTIMATE_GIB GiB"
echo "  estimated headroom:       controller $CONTROLLER_HEADROOM_GIB GiB, peer $PEER_HEADROOM_GIB GiB"
if [ "$RPC_CACHE_ENABLED" = "1" ]; then
  echo "  peer RPC disk cache:       enabled; at least $RPC_CACHE_MIN_GIB GiB"
else
  echo "  peer RPC disk cache:       disabled"
fi
echo "  artifact source:           $MODEL_SIZE_SOURCE"
echo "  host-buffer source:        $LARGE_QUANT_BLOCKER_SOURCE"

if awk -v value="$CONTROLLER_HEADROOM_GIB" -v minimum="$MIN_HEADROOM_GIB" \
    'BEGIN { exit !(value < minimum) }'; then
  warn "controller estimated headroom is below ${MIN_HEADROOM_GIB} GiB"
fi
if awk -v value="$PEER_HEADROOM_GIB" -v minimum="$MIN_HEADROOM_GIB" \
    'BEGIN { exit !(value < minimum) }'; then
  warn "peer estimated headroom is below ${MIN_HEADROOM_GIB} GiB"
fi

if [ "$QUANT" != "Q4" ]; then
  warn "$QUANT is experimental on this exact two-node RPC topology."
  warn "A non-maintainer upstream-tracker report describes a controller OOM from a"
  warn "non-distributed Gated DeltaNet host buffer: $LARGE_QUANT_BLOCKER_SOURCE"
fi

# =============================================================================
# 3. FOUNDATION AND BUILD PREREQUISITES
# =============================================================================
export DEBIAN_FRONTEND=noninteractive
log "Installing build and service prerequisites"
apt-get update -y
apt-get install -y \
  build-essential ca-certificates cmake curl git gnupg jq libcurl4-openssl-dev \
  libssl-dev netcat-openbsd ninja-build openssl python3 python3-pip \
  python3-venv rsync sudo ufw unzip

ensure_llama_user() {
  if ! getent group "$LLAMA_USER" >/dev/null 2>&1; then
    groupadd --system "$LLAMA_USER"
  fi
  if ! id "$LLAMA_USER" >/dev/null 2>&1; then
    useradd \
      --system \
      --gid "$LLAMA_USER" \
      --home-dir "$LLAMA_HOME" \
      --create-home \
      --shell /usr/sbin/nologin \
      "$LLAMA_USER"
  fi
  usermod -aG render,video "$LLAMA_USER"
  install -d -m 0755 -o "$LLAMA_USER" -g "$LLAMA_USER" "$LLAMA_HOME"
  ok "service account '$LLAMA_USER' is ready"
}

ensure_llama_user

# =============================================================================
# 4. ROCm AND GPU MEMORY CONFIGURATION
# =============================================================================
install_rocm() {
  [ "$INSTALL_ROCM" = "1" ] || return 0

  log "Installing ROCm $ROCM_VERSION for $ROCM_GFX"

  local ubuntu_version
  local repo_ready=0
  local key_dir
  local package_regex
  local dev_package_regex

  ubuntu_version="$(. /etc/os-release; echo "${VERSION_ID:-26.04}")"
  if [ -z "$ROCM_REPO_URL" ]; then
    ROCM_REPO_URL="https://stable.repo.amd.com/rocm/core/packages/ubuntu$(tr -d '.' <<<"$ubuntu_version")/"
  fi

  curl -fsSL --max-time 30 -o /dev/null "${ROCM_REPO_URL}dists/stable/Release" \
    || die "AMD does not publish the requested ROCm repository at $ROCM_REPO_URL"
  repo_ready=1

  install -d -m 0755 /etc/apt/keyrings
  key_dir="$(mktemp -d)"
  if curl -fsSL --max-time 60 "$ROCM_GPG_URL" \
      | gpg --batch --dearmor -o "$key_dir/amdrocm.gpg" \
      && gpg --batch --show-keys "$key_dir/amdrocm.gpg" >/dev/null 2>&1; then
    install -m 0644 "$key_dir/amdrocm.gpg" /etc/apt/keyrings/amdrocm.gpg
  else
    rm -rf "$key_dir"
    die "could not install the ROCm signing key"
  fi
  rm -rf "$key_dir"

  if [ "$repo_ready" = "1" ]; then
    cat > /etc/apt/sources.list.d/amdrocm-stable.sources <<ROCMSOURCE
# Managed by $SCRIPT_NAME
X-Repo-Id: amdrocm-stable
Types: deb
URIs: $ROCM_REPO_URL
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/amdrocm.gpg
Enabled: yes
ROCMSOURCE
  fi

  for legacy_repo in /etc/apt/sources.list.d/rocm.list /etc/apt/sources.list.d/amdgpu.list; do
    if [ -f "$legacy_repo" ]; then
      mv "$legacy_repo" "$legacy_repo.disabled-by-$SCRIPT_NAME"
    fi
  done

  apt-get update -y

  if [ -z "$ROCM_PKG" ]; then
    package_regex="${ROCM_APT_VERSION//./\\.}"
    ROCM_PKG="$(apt-cache pkgnames amdrocm 2>/dev/null \
      | grep -E "^amdrocm${package_regex}-${ROCM_GFX}$" \
      | sort -V \
      | tail -n1 || true)"
  fi
  [ -n "$ROCM_PKG" ] \
    || die "no exact ROCm $ROCM_APT_VERSION package for $ROCM_GFX is available"

  if [ -z "$ROCM_DEV_PKG" ]; then
    dev_package_regex="${ROCM_APT_VERSION//./\\.}"
    ROCM_DEV_PKG="$(apt-cache pkgnames amdrocm-core-dev 2>/dev/null \
      | grep -E "^amdrocm-core-dev${dev_package_regex}-${ROCM_GFX}$" \
      | sort -V \
      | tail -n1 || true)"
  fi
  [ -n "$ROCM_DEV_PKG" ] \
    || die "no ROCm $ROCM_APT_VERSION development package for $ROCM_GFX is available; HIP CMake support is required"

  apt-get install -y "$ROCM_PKG" "$ROCM_DEV_PKG"
  ok "installed $ROCM_PKG and HIP development package $ROCM_DEV_PKG"

  cat > /etc/profile.d/rocm.sh <<'PROFILE'
if [ -d /opt/rocm/bin ]; then
  case ":$PATH:" in
    *":/opt/rocm/bin:"*) ;;
    *) PATH="$PATH:/opt/rocm/bin"; export PATH ;;
  esac
fi
PROFILE
  chmod 0644 /etc/profile.d/rocm.sh

  : > /etc/ld.so.conf.d/rocm.conf
  for library_dir in /opt/rocm/lib /opt/rocm/lib64; do
    [ -d "$library_dir" ] && echo "$library_dir" >> /etc/ld.so.conf.d/rocm.conf
  done
  ldconfig
  export PATH="$PATH:/opt/rocm/bin"

  local rocminfo_bin=""
  command -v rocminfo >/dev/null 2>&1 && rocminfo_bin="$(command -v rocminfo)"
  [ -n "$rocminfo_bin" ] || [ ! -x /opt/rocm/bin/rocminfo ] || rocminfo_bin=/opt/rocm/bin/rocminfo
  if [ -n "$rocminfo_bin" ] && "$rocminfo_bin" 2>/dev/null | grep "$ROCM_GFX" >/dev/null; then
    ok "ROCm detects $ROCM_GFX"
  else
    warn "ROCm does not report $ROCM_GFX yet; recheck after reboot"
    REBOOT_REQUIRED=1
  fi
}

configure_ttm() {
  [ "$CONFIGURE_MEMORY" = "1" ] || return 0

  log "Configuring $GTT_GIB GiB of GPU-addressable TTM/GTT memory"

  local mem_kib
  local mem_gib
  local target_pages
  local current_pages
  local ttm_venv=/opt/amd-debug-tools
  local configured=0

  mem_kib="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
  mem_gib=$((mem_kib / 1024 / 1024))
  [ "$GTT_GIB" -lt "$mem_gib" ] \
    || die "GTT_GIB=$GTT_GIB leaves no memory for Linux (detected about $mem_gib GiB)"

  target_pages=$((GTT_GIB * 262144))
  current_pages="$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo 0)"

  if python3 -m venv "$ttm_venv" \
      && "$ttm_venv/bin/pip" install --quiet --upgrade pip \
      && "$ttm_venv/bin/pip" install --quiet amd-debug-tools \
      && [ -x "$ttm_venv/bin/amd-ttm" ]; then
    printf 'n\n' | "$ttm_venv/bin/amd-ttm" --set "$GTT_GIB" >/dev/null 2>&1 || true
    if grep -q "pages_limit" /etc/modprobe.d/ttm.conf 2>/dev/null; then
      configured=1
      ln -sfn "$ttm_venv/bin/amd-ttm" /usr/local/bin/amd-ttm
      ok "TTM configured with AMD's amd-ttm helper"
    fi
  fi

  if [ "$configured" != "1" ]; then
    cat > /etc/modprobe.d/ttm.conf <<TTM
# Managed by $SCRIPT_NAME
options ttm pages_limit=$target_pages
TTM
    ok "TTM configured directly in /etc/modprobe.d/ttm.conf"
  fi

  update-initramfs -u >/dev/null 2>&1 || warn "update-initramfs returned non-zero"

  if [ "$current_pages" != "$target_pages" ]; then
    REBOOT_REQUIRED=1
    note_action "Reboot this node to activate the $GTT_GIB GiB TTM/GTT limit."
  else
    ok "the live TTM/GTT limit is already $GTT_GIB GiB"
  fi

  note_action "BIOS: use the smallest UMA/dedicated VRAM setting and keep IOMMU enabled."
  note_action "BIOS: enable Above 4G Decoding."
}

install_rocm
configure_ttm

# =============================================================================
# 5. LLAMA.CPP BUILD
# =============================================================================
# Vendored source patches applied to the pinned llama.cpp checkout; see
# patches/README.md for what each one does and why. Reruns are safe: a patch
# already applied is detected via its reverse-check and skipped.
apply_llama_patches() {
  local patch_dir="$SCRIPT_DIR/patches"
  [ -d "$patch_dir" ] || return 0

  local patch
  for patch in "$patch_dir"/*.patch; do
    [ -e "$patch" ] || continue
    if git -C "$LLAMA_SRC" apply --check "$patch" 2>/dev/null; then
      git -C "$LLAMA_SRC" apply "$patch"
      ok "applied $(basename "$patch")"
    elif git -C "$LLAMA_SRC" apply --reverse --check "$patch" 2>/dev/null; then
      ok "$(basename "$patch") already applied"
    else
      die "$(basename "$patch") does not apply to llama.cpp commit $LLAMA_CPP_COMMIT; refresh the patch"
    fi
  done
}

build_llama_cpp() {
  [ "$BUILD_LLAMA_CPP" = "1" ] || return 0

  log "Building llama.cpp $LLAMA_CPP_TAG for $ROCM_GFX with HIP and RPC"

  if [ -d "$LLAMA_SRC/.git" ]; then
    git -C "$LLAMA_SRC" fetch --tags --prune
  elif [ -e "$LLAMA_SRC" ]; then
    die "$LLAMA_SRC exists but is not a llama.cpp checkout"
  else
    git clone "$LLAMA_CPP_REPO" "$LLAMA_SRC"
  fi

  git -C "$LLAMA_SRC" checkout --detach "$LLAMA_CPP_COMMIT"
  local actual_commit
  actual_commit="$(git -C "$LLAMA_SRC" rev-parse HEAD)"
  [ "$actual_commit" = "$LLAMA_CPP_COMMIT" ] \
    || die "llama.cpp checkout is $actual_commit instead of $LLAMA_CPP_COMMIT"

  apply_llama_patches

  unset GGML_CUDA_ENABLE_UNIFIED_MEMORY
  local hipconfig_bin
  hipconfig_bin="$(command -v hipconfig 2>/dev/null || true)"
  [ -n "$hipconfig_bin" ] || [ ! -x /opt/rocm/bin/hipconfig ] || hipconfig_bin=/opt/rocm/bin/hipconfig
  [ -n "$hipconfig_bin" ] || die "hipconfig is unavailable after ROCm installation"

  local rocm_root
  local hip_path
  local hip_clang_path
  local hip_compiler
  local hip_lang_config=""
  local search_root
  local candidate
  local cmake_prefix_path
  local required_dev_pkg

  required_dev_pkg="${ROCM_DEV_PKG:-amdrocm-core-dev${ROCM_APT_VERSION}-${ROCM_GFX}}"
  rocm_root="$("$hipconfig_bin" -R 2>/dev/null || true)"
  [ -n "$rocm_root" ] && [ -d "$rocm_root" ] \
    || die "hipconfig did not return a usable ROCm root"
  hip_path="$("$hipconfig_bin" -p 2>/dev/null || true)"
  [ -n "$hip_path" ] || hip_path="$rocm_root"
  hip_clang_path="$("$hipconfig_bin" -l 2>/dev/null || true)"
  hip_compiler="$hip_clang_path/clang"
  [ -x "$hip_compiler" ] || [ ! -x "$rocm_root/llvm/bin/clang" ] \
    || hip_compiler="$rocm_root/llvm/bin/clang"
  [ -x "$hip_compiler" ] || die "HIP clang compiler is unavailable under $rocm_root"

  for search_root in "$rocm_root" /opt/rocm; do
    [ -d "$search_root" ] || continue
    while IFS= read -r candidate; do
      [ -f "$candidate" ] || continue
      hip_lang_config="$candidate"
      break 2
    done < <(find "$search_root" -type f -path '*/cmake/hip-lang/hip-lang-config.cmake' 2>/dev/null | sort -V)
  done
  [ -n "$hip_lang_config" ] \
    || die "HIP CMake package is missing; install $required_dev_pkg so hip-lang-config.cmake is available under $rocm_root"

  cmake_prefix_path="$rocm_root;$rocm_root/lib/cmake;$rocm_root/lib64/cmake"

  HIPCXX="$hip_compiler" \
  HIP_PATH="$hip_path" \
  ROCM_PATH="$rocm_root" \
  CMAKE_PREFIX_PATH="$cmake_prefix_path" \
  cmake -S "$LLAMA_SRC" -B "$LLAMA_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_HIP_COMPILER="$hip_compiler" \
    -DCMAKE_HIP_COMPILER_ROCM_ROOT="$rocm_root" \
    -DGGML_HIP=ON \
    -DGGML_RPC=ON \
    -DGPU_TARGETS="$ROCM_GFX"
  cmake --build "$LLAMA_BUILD" --config Release -j "$(nproc)"

  [ -x "$LLAMA_BUILD/bin/llama-server" ] || die "llama-server was not built"
  [ -x "$LLAMA_BUILD/bin/ggml-rpc-server" ] || die "ggml-rpc-server was not built"

  ln -sfn "$LLAMA_BUILD/bin/llama-server" /usr/local/bin/llama-server
  ln -sfn "$LLAMA_BUILD/bin/ggml-rpc-server" /usr/local/bin/ggml-rpc-server
  ok "llama.cpp binaries installed from commit $actual_commit"
}

build_llama_cpp

# =============================================================================
# 6. MODEL DOWNLOAD AND PEER CACHE
# =============================================================================
check_free_space() {
  local path="$1"
  local required_bytes="$2"
  local label="$3"
  local available

  install -d -m 0755 "$path"
  available="$(df -B1 --output=avail "$path" | tail -n1 | tr -d ' ')"
  if [ "$available" -lt "$required_bytes" ]; then
    die "$label needs at least $((required_bytes / 1024 / 1024 / 1024)) GiB free at $path"
  fi
  ok "$label disk has $((available / 1024 / 1024 / 1024)) GiB free"
}

download_model() {
  [ "$NODE_ROLE" = "server" ] || return 0
  [ "$DOWNLOAD_MODEL" = "1" ] || return 0

  log "Downloading Qwen3.8-Flash-Next $MODEL_QUANT"

  local reserve_bytes=$((25 * 1024 * 1024 * 1024))
  local existing_bytes
  local remaining_bytes
  local required_bytes
  local actual_bytes
  local shard_count

  install -d -m 2775 -o "$LLAMA_USER" -g "$LLAMA_USER" "$MODEL_DIR"
  existing_bytes="$(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' -printf '%s\n' 2>/dev/null \
    | awk '{total += $1} END {print total + 0}')"
  if [ "$existing_bytes" -ge "$MODEL_EXPECTED_BYTES" ]; then
    remaining_bytes=0
  else
    remaining_bytes=$((MODEL_EXPECTED_BYTES - existing_bytes))
  fi
  required_bytes=$((remaining_bytes + reserve_bytes))
  check_free_space "$MODEL_ROOT" "$required_bytes" "$QUANT model"
  install -d -m 2775 -o "$LLAMA_USER" -g "$LLAMA_USER" "$MODEL_ROOT"

  if [ ! -x "$HF_TOOLS_VENV/bin/hf" ]; then
    python3 -m venv "$HF_TOOLS_VENV"
    "$HF_TOOLS_VENV/bin/pip" install --quiet --upgrade pip
    "$HF_TOOLS_VENV/bin/pip" install --quiet "huggingface_hub[cli]"
  fi

  sudo -u "$LLAMA_USER" -H env \
    HF_HOME="$LLAMA_HOME/huggingface" \
    HF_TOKEN="${HF_TOKEN:-}" \
    "$HF_TOOLS_VENV/bin/hf" download "$MODEL_REPO" \
      --revision "$MODEL_REVISION" \
      --include "$MODEL_QUANT/*" \
      --local-dir "$MODEL_ROOT"

  shard_count="$(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' | wc -l)"
  actual_bytes="$(find "$MODEL_DIR" -maxdepth 1 -type f -name '*.gguf' -printf '%s\n' \
    | awk '{total += $1} END {print total + 0}')"

  [ "$shard_count" -eq "$MODEL_SHARD_COUNT" ] \
    || die "expected $MODEL_SHARD_COUNT $QUANT shards, found $shard_count"
  [ "$actual_bytes" -eq "$MODEL_EXPECTED_BYTES" ] \
    || die "$QUANT artifact size is $actual_bytes bytes; expected $MODEL_EXPECTED_BYTES"
  [ -f "$MODEL_FILE" ] || die "first $QUANT shard is missing: $MODEL_FILE"

  chown -R "$LLAMA_USER:$LLAMA_USER" "$MODEL_ROOT"
  ok "$QUANT model verified: $actual_bytes bytes across $MODEL_SHARD_COUNT shards"
}

prepare_peer_cache() {
  [ "$NODE_ROLE" = "peer" ] || return 0

  if [ "$RPC_CACHE_ENABLED" = "1" ]; then
    local required_bytes=$((RPC_CACHE_MIN_GIB * 1024 * 1024 * 1024))
    check_free_space "$RPC_CACHE" "$required_bytes" "RPC tensor cache"
  fi
  install -d -m 2775 -o "$LLAMA_USER" -g "$LLAMA_USER" "$RPC_CACHE"
}

download_model
prepare_peer_cache

# =============================================================================
# 7. RUNTIME HELPERS AND STATUS
# =============================================================================
install_runtime_helpers() {
  install -d -m 0755 "$CONFIG_ROOT"

  cat > "$CONFIG_ROOT/cluster.env" <<ENV
NODE_ROLE=$NODE_ROLE
CLUSTER_LOCAL_IP=$CLUSTER_LOCAL_IP
CLUSTER_PEER_IP=$CLUSTER_PEER_IP
RPC_PORT=$RPC_PORT
LLAMA_PORT=$LLAMA_PORT
RPC_CACHE=$RPC_CACHE
RPC_CACHE_ENABLED=$RPC_CACHE_ENABLED
MODEL_FILE=$MODEL_FILE
MODEL_EXPECTED_BYTES=$MODEL_EXPECTED_BYTES
MODEL_ARTIFACT_GIB=$MODEL_ARTIFACT_GIB
MODEL_QUANT=$MODEL_QUANT
MODEL_ALIAS=$MODEL_ALIAS
MODEL_MEMORY_ESTIMATE_GIB=$MODEL_MEMORY_ESTIMATE_GIB
HOST_BUFFER_ESTIMATE_GIB=$HOST_BUFFER_ESTIMATE_GIB
KV_MEMORY_ESTIMATE_GIB=$KV_MEMORY_ESTIMATE_GIB
TENSOR_SPLIT=$TENSOR_SPLIT
PARALLEL_SLOTS=$PARALLEL_SLOTS
CONTEXT_K=$CONTEXT_K
CONTEXT_PER_SLOT=$CONTEXT_PER_SLOT
NATIVE_CONTEXT_PER_SLOT=$NATIVE_CONTEXT_PER_SLOT
CONTEXT_SCALING=$CONTEXT_SCALING
YARN_ROPE_SCALE=$YARN_ROPE_SCALE
YARN_MODEL_CONTEXT_OVERRIDE=$YARN_MODEL_CONTEXT_OVERRIDE
KV_CACHE_TYPE=$KV_CACHE_TYPE
MODEL_SIZE_SOURCE=$MODEL_SIZE_SOURCE
ENV
  chmod 0644 "$CONFIG_ROOT/cluster.env"

  cat > /usr/local/bin/qwen3d8-wait-rpc <<'WAITRPC'
#!/usr/bin/env bash
set -uo pipefail

[ -r /etc/qwen3d8/cluster.env ] && . /etc/qwen3d8/cluster.env

while true; do
  if timeout 2 bash -c "</dev/tcp/${CLUSTER_PEER_IP}/${RPC_PORT}" >/dev/null 2>&1; then
    exit 0
  fi
  echo "Waiting for Qwen3.8 RPC worker at ${CLUSTER_PEER_IP}:${RPC_PORT}" >&2
  sleep 10
done
WAITRPC
  chmod 0755 /usr/local/bin/qwen3d8-wait-rpc

  cat > /usr/local/bin/qwen3d8-status <<'STATUS'
#!/usr/bin/env bash
set -uo pipefail

[ -r /etc/qwen3d8/cluster.env ] && . /etc/qwen3d8/cluster.env

echo "role: ${NODE_ROLE:-unknown}"
echo "quant: ${MODEL_QUANT:-unknown}"
echo "balance: ${TENSOR_SPLIT:-unknown}"
echo "context: ${CONTEXT_K:-?} Ki per slot (${CONTEXT_PER_SLOT:-?} tokens; ${CONTEXT_SCALING:-native})"
if [ "${CONTEXT_SCALING:-native}" = "yarn" ]; then
  echo "YaRN: ${YARN_ROPE_SCALE:-?}x from ${NATIVE_CONTEXT_PER_SLOT:-262144} tokens"
fi
echo "local/peer: ${CLUSTER_LOCAL_IP:-?} / ${CLUSTER_PEER_IP:-?}"
echo

if [ "${NODE_ROLE:-}" = "peer" ]; then
  systemctl status qwen3d8-rpc.service --no-pager -n 8 || true
  ss -ltnp 2>/dev/null | grep ":${RPC_PORT:-50053}" || true
else
  systemctl status qwen3d8-server.service --no-pager -n 8 || true
  systemctl status nginx.service --no-pager -n 5 || true
  docker ps --filter name=open-webui 2>/dev/null || true
  echo
  curl -fsS --max-time 5 "http://127.0.0.1:${LLAMA_PORT:-8081}/v1/models" || true
  echo
fi
STATUS
chmod 0755 /usr/local/bin/qwen3d8-status
}

install_runtime_helpers

# =============================================================================
# 8. RPC WORKER SERVICE
# =============================================================================
install_peer_service() {
  [ "$NODE_ROLE" = "peer" ] || return 0

  log "Installing the Qwen3.8 RPC worker service"

  local rpc_cache_environment=""
  local rpc_cache_argument=""
  if [ "$RPC_CACHE_ENABLED" = "1" ]; then
    rpc_cache_environment="Environment=LLAMA_CACHE=$RPC_CACHE"
    rpc_cache_argument="-c"
  fi

  cat > /etc/systemd/system/qwen3d8-rpc.service <<UNIT
[Unit]
Description=Qwen3.8 llama.cpp RPC worker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$LLAMA_USER
Group=$LLAMA_USER
SupplementaryGroups=render video
Environment=HOME=$LLAMA_HOME
$rpc_cache_environment
Environment=GGML_RPC_NO_RDMA=1
UnsetEnvironment=GGML_CUDA_ENABLE_UNIFIED_MEMORY
ExecStart=/usr/bin/env -u GGML_CUDA_ENABLE_UNIFIED_MEMORY \
  /usr/local/bin/ggml-rpc-server \
  --host $CLUSTER_LOCAL_IP \
  --port $RPC_PORT \
  --device ROCm0 $rpc_cache_argument
Restart=always
RestartSec=10
LimitMEMLOCK=infinity
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  ensure_boot_unit qwen3d8-rpc.service
  if [ "$REBOOT_REQUIRED" = "1" ]; then
    warn "qwen3d8-rpc.service is enabled and will start after reboot"
  else
    systemctl restart qwen3d8-rpc.service
    systemctl is-active --quiet qwen3d8-rpc.service \
      || die "qwen3d8-rpc.service did not start"
    ok "RPC worker listening on $CLUSTER_LOCAL_IP:$RPC_PORT"
  fi

  systemctl disable --now qwen3d8-server.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/qwen3d8-server.service
  systemctl daemon-reload >/dev/null 2>&1 || true
}

# =============================================================================
# 9. CONTROLLER SERVICE
# =============================================================================
install_server_service() {
  [ "$NODE_ROLE" = "server" ] || return 0

  log "Installing the Qwen3.8 $QUANT controller service"

  if [ "$CONTEXT_SCALING" = "yarn" ]; then
    local llama_help
    llama_help="$(
      /usr/local/bin/llama-server --help 2>&1
    )" || die "could not read llama-server help for YaRN validation"
    local option
    for option in --override-kv --rope-scaling --rope-scale --yarn-orig-ctx; do
      grep -F -- "$option " <<<"$llama_help" >/dev/null \
        || die "installed llama-server lacks required YaRN option: $option"
    done
  fi

  cat > /etc/systemd/system/qwen3d8-server.service <<UNIT
[Unit]
Description=Qwen3.8-Flash-Next $QUANT distributed llama-server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=2

[Service]
Type=simple
User=$LLAMA_USER
Group=$LLAMA_USER
SupplementaryGroups=render video
Environment=HOME=$LLAMA_HOME
Environment=GGML_RPC_NO_RDMA=1
Environment=MALLOC_ARENA_MAX=2
UnsetEnvironment=GGML_CUDA_ENABLE_UNIFIED_MEMORY
WorkingDirectory=$MODEL_ROOT
ExecStartPre=/usr/local/bin/qwen3d8-wait-rpc
ExecStart=/usr/bin/env -u GGML_CUDA_ENABLE_UNIFIED_MEMORY \
  /usr/local/bin/llama-server \
  --model $MODEL_FILE \
  --alias $MODEL_ALIAS \
  --rpc $CLUSTER_PEER_IP:$RPC_PORT \
  --device ROCm0,RPC0 \
  --split-mode layer \
  --tensor-split $TENSOR_SPLIT \
  --gpu-layers all \
  --fit off \
  --parallel $PARALLEL_SLOTS \
  --kv-unified \
  --kv-unified-per-slot $CONTEXT_PER_SLOT $YARN_SERVER_ARGS \
  --cache-type-k $KV_CACHE_TYPE \
  --cache-type-v $KV_CACHE_TYPE \
  --load-mode mmap \
  --lazy-mode on \
  --cache-ram 0 \
  --batch-size 1024 \
  --ubatch-size 128 \
  --flash-attn on \
  --no-mmproj \
  --jinja \
  --reasoning on \
  --host 0.0.0.0 \
  --port $LLAMA_PORT
Restart=on-failure
RestartSec=30
TimeoutStartSec=infinity
OOMPolicy=stop
LimitMEMLOCK=infinity
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  ensure_boot_unit qwen3d8-server.service
  systemctl disable --now qwen3d8-rpc.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/qwen3d8-rpc.service
  systemctl daemon-reload >/dev/null 2>&1 || true

  if [ "$REBOOT_REQUIRED" = "1" ]; then
    warn "controller service is enabled and will start after reboot"
  else
    ok "controller service enabled; startup is deferred until firewall setup completes"
  fi
}

install_peer_service
install_server_service

# =============================================================================
# 10. OPEN WEBUI AND NGINX
# =============================================================================
install_open_webui() {
  [ "$NODE_ROLE" = "server" ] || return 0
  [ "$INSTALL_WEBUI" = "1" ] || return 0

  log "Installing Open WebUI and Nginx"

  apt-get install -y docker.io nginx
  ensure_boot_unit docker.service
  systemctl start docker.service

  install -d -m 0755 "$CONFIG_ROOT"
  install -d -m 0755 "$OPENWEBUI_DATA"
  if [ ! -s "$OPENWEBUI_SECRET_FILE" ]; then
    openssl rand -hex 32 > "$OPENWEBUI_SECRET_FILE"
    chmod 0600 "$OPENWEBUI_SECRET_FILE"
  fi
  local webui_secret
  webui_secret="$(cat "$OPENWEBUI_SECRET_FILE")"

  docker pull "$OPENWEBUI_IMAGE"
  docker rm -f "$OPENWEBUI_CONTAINER" >/dev/null 2>&1 || true
  docker run -d \
    --name "$OPENWEBUI_CONTAINER" \
    --restart always \
    -p "127.0.0.1:${WEBUI_HOST_PORT}:8080" \
    --add-host=host.docker.internal:host-gateway \
    -v "$OPENWEBUI_DATA:/app/backend/data" \
    -e "WEBUI_SECRET_KEY=$webui_secret" \
    -e "ENABLE_OLLAMA_API=False" \
    -e "ENABLE_OPENAI_API=True" \
    -e "OPENAI_API_BASE_URLS=http://host.docker.internal:${LLAMA_PORT}/v1" \
    -e "OPENAI_API_KEYS=EMPTY" \
    -e "DEFAULT_MODELS=$MODEL_ALIAS" \
    "$OPENWEBUI_IMAGE"

  docker inspect \
    --format '{{index .RepoDigests 0}}' "$OPENWEBUI_IMAGE" \
    > "$CONFIG_ROOT/openwebui-image.digest" 2>/dev/null || true
  ok "Open WebUI container started with restart=always"

  cat > /etc/nginx/sites-available/qwen3d8 <<NGINX
server {
    listen $NGINX_PORT default_server;
    listen [::]:$NGINX_PORT default_server;
    server_name _;

    client_max_body_size 100m;

    location /v1/ {
        proxy_pass http://127.0.0.1:$LLAMA_PORT/v1/;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location / {
        proxy_pass http://127.0.0.1:$WEBUI_HOST_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX

  rm -f /etc/nginx/sites-enabled/default
  ln -sfn /etc/nginx/sites-available/qwen3d8 /etc/nginx/sites-enabled/qwen3d8
  nginx -t
  ensure_boot_unit nginx.service
  systemctl restart nginx.service

  local net
  for net in $LAN_NETS; do
    ufw allow from "$net" to any port "$NGINX_PORT" proto tcp >/dev/null
  done
  yes | ufw enable >/dev/null 2>&1 || true
  grep -q '^ENABLED=yes' /etc/ufw/ufw.conf \
    || die "UFW is not configured to restore at boot"

  ok "Open WebUI is available through Nginx on port $NGINX_PORT"
}

install_open_webui

# =============================================================================
# 11. FIREWALL AND SUMMARY
# =============================================================================
configure_runtime_firewall() {
  log "Finalizing persistent runtime firewall rules"

  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true

  if [ "$NODE_ROLE" = "peer" ]; then
    ufw allow in on "$CLUSTER_IFACE" from "$CLUSTER_PEER_IP" \
      to "$CLUSTER_LOCAL_IP" port "$RPC_PORT" proto tcp >/dev/null
  else
    local net
    if [ "$INSTALL_WEBUI" = "1" ]; then
      for net in $LAN_NETS; do
        ufw allow from "$net" to any port "$NGINX_PORT" proto tcp >/dev/null
      done
      ufw allow in on docker0 to any port "$LLAMA_PORT" proto tcp >/dev/null
    else
      for net in $LAN_NETS; do
        ufw allow from "$net" to any port "$LLAMA_PORT" proto tcp >/dev/null
      done
    fi
  fi

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  yes | ufw enable >/dev/null 2>&1 || true
  systemctl enable ufw.service >/dev/null 2>&1 || true
  ufw reload >/dev/null 2>&1 || true

  grep -q '^ENABLED=yes' /etc/ufw/ufw.conf \
    || die "UFW is not configured to restore at boot"
  ufw status verbose | grep '^Status: active' >/dev/null \
    || die "UFW is not active"
  ok "UFW is active, default-deny, and persistent"
}

configure_runtime_firewall

if [ "$NODE_ROLE" = "server" ] && [ "$REBOOT_REQUIRED" != "1" ]; then
  systemctl start --no-block qwen3d8-server.service >/dev/null 2>&1 || true
  ok "controller service started; it waits for RPC at $CLUSTER_PEER_IP:$RPC_PORT"
fi

echo
echo "${GRN}${BOLD}Qwen3.8 $QUANT installation complete on $(hostname -s)${RST}"
echo "  role:          $NODE_ROLE"
echo "  quant:         $MODEL_QUANT"
echo "  balance:       $TENSOR_SPLIT (controller,peer)"
echo "  context:       ${CONTEXT_K} Ki per slot ($CONTEXT_PER_SLOT tokens; $CONTEXT_SCALING)"
if [ "$CONTEXT_SCALING" = "yarn" ]; then
  echo "  YaRN scale:    ${YARN_ROPE_SCALE}x from $NATIVE_CONTEXT_PER_SLOT tokens"
fi
echo "  ROCm target:   $ROCM_VERSION / $ROCM_GFX"
echo "  llama.cpp:     $LLAMA_CPP_TAG ($LLAMA_CPP_COMMIT)"
echo "  USB4:          $CLUSTER_LOCAL_IP -> $CLUSTER_PEER_IP"
if [ "$NODE_ROLE" = "server" ]; then
  echo "  model:         $MODEL_FILE"
  echo "  API:           http://127.0.0.1:$LLAMA_PORT/v1"
  [ "$INSTALL_WEBUI" = "1" ] && echo "  LAN UI/API:    http://$(hostname -s):$NGINX_PORT"
  echo "  status:        sudo qwen3d8-status"
else
  echo "  RPC worker:    $CLUSTER_LOCAL_IP:$RPC_PORT"
  if [ "$RPC_CACHE_ENABLED" = "1" ]; then
    echo "  RPC cache:     $RPC_CACHE (enabled)"
  else
    echo "  RPC cache:     disabled"
  fi
  echo "  status:        sudo qwen3d8-status"
fi

if [ "$QUANT" != "Q4" ]; then
  echo
  echo "${YLW}${BOLD}Known large-quant tracker report${RST}"
  echo "  A non-maintainer user reported Q5/Q6 controller OOM on this exact two-node"
  echo "  gfx1151 RPC topology, attributing it to an approximately 52 GiB Gated"
  echo "  DeltaNet host buffer that remains on the controller."
  echo "  This is not a maintainer-confirmed llama.cpp limitation."
  echo "  Source: $LARGE_QUANT_BLOCKER_SOURCE"
fi

if [ "$REBOOT_REQUIRED" = "1" ]; then
  echo
  echo "${YLW}${BOLD}Reboot required${RST}"
  echo "  Reboot this node before evaluating service startup."
fi

if [ "${#ACTIONS[@]}" -gt 0 ]; then
  echo
  echo "${YLW}${BOLD}Action required${RST}"
  for action in "${ACTIONS[@]}"; do
    echo "${YLW}  *${RST} $action"
  done
fi

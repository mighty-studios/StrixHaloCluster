#!/usr/bin/env bash
# =============================================================================
# verify-and-seed-strixhalo-ai-server.sh
# -----------------------------------------------------------------------------
# Companion to setup-strixhalo-ai-server.sh. Run it on EACH node AFTER setup has
# finished and the machine has rebooted -- the reboot is what makes the TTM
# memory limit, the render/video/aimodels group membership, the udev device
# permissions and the USB4 interface rename actually take hold.
#
# It does two things:
#
#   1. VERIFY  Walks the whole stack in dependency order and reports on each
#              piece: kernel, GPU devices, ROCm + RCCL, unified memory, the USB4
#              link to the other node, NFS shared storage, the vLLM/Ray runtime,
#              the model catalog, residencyd, the gateway, Open WebUI, ComfyUI,
#              XRDP and the firewall. It knows which node it is on and only
#              checks what belongs there.
#
#   2. SEED    Downloads models ONCE into the shared stores:
#                LLMs     -> /srv/models/<name>   (vLLM format, not GGUF)
#                ComfyUI  -> /srv/comfyui/models/<subdir>
#              Both are NFS-shared, so the other node sees them immediately.
#              Seeding LLMs only works on the server: /srv/models is exported
#              read-only, which is deliberate.
#              Newly downloaded LLMs are registered in the catalog for you, so
#              they appear in the gateway's /v1/models straight away.
#
# Safe to re-run: verification is read-only and downloads are idempotent.
#
# Usage:
#   ./verify-and-seed-strixhalo-ai-server.sh --server m5-a --peer m5-b
#   ./verify-and-seed-strixhalo-ai-server.sh --server m5-a --peer m5-b --verify-only
#   sudo ./verify-and-seed-strixhalo-ai-server.sh --server m5-a --peer m5-b --seed-only -y
#
# Some checks (ufw rules, NFS exports, the residencyd socket) need root; without
# it they are reported as skipped rather than failed.
# =============================================================================

set -uo pipefail   # NOT -e: every check must run and report, not abort.

# ------------------------------- CONFIG --------------------------------------
# Defaults mirror the setup script. Anything the setup script recorded on disk
# (/etc/llm/runtime.env, /etc/default/usb4-cluster) overrides these further down,
# so you do not have to repeat the flags you used at install time.
SERVER_HOST="${SERVER_HOST:-}"
PEER_HOST="${PEER_HOST:-}"
NODE_ROLE="${NODE_ROLE:-auto}"
# Deliberately left EMPTY here. The real resolution happens after load_facts(),
# in this order: --user > $SUDO_USER > what the setup script recorded > the
# invoking account. logname(1) used to be in that chain and is not any more: in
# a non-login shell it can succeed while printing nothing, which produced a
# blank user, a home of '/home/' and a page of nonsense failures.
TARGET_USER="${TARGET_USER:-}"
USER_FROM_CLI=0
SETUP_TARGET_USER=""

ROCM_GFX="${ROCM_GFX:-gfx1151}"
OS_RESERVE_GIB="${OS_RESERVE_GIB:-8}"

CLUSTER_IFACE="${CLUSTER_IFACE:-usb4llm0}"
CLUSTER_NET="${CLUSTER_NET:-10.44.0}"
CLUSTER_CIDR="${CLUSTER_CIDR:-30}"
CLUSTER_MTU="${CLUSTER_MTU:-1500}"

LLM_ROOT="${LLM_ROOT:-/srv/models}"
COMFY_ROOT="${COMFY_ROOT:-/srv/comfyui}"
LLM_ETC="${LLM_ETC:-/etc/llm}"
LLM_USER="${LLM_USER:-llm}"
SHARE_GROUP="${SHARE_GROUP:-aimodels}"
LLM_LOCAL_CACHE="${LLM_LOCAL_CACHE:-/var/lib/llm-cache}"

GATEWAY_PORT="${GATEWAY_PORT:-8000}"
WEBUI_PORT="${WEBUI_PORT:-3000}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
XRDP_PORT="${XRDP_PORT:-3389}"
RAY_PORT="${RAY_PORT:-6379}"
AGENT_PORT="${AGENT_PORT:-8099}"
RESIDENCY_SOCK="${RESIDENCY_SOCK:-/run/residencyd/control.sock}"

HF_TOOLS_VENV="${HF_TOOLS_VENV:-/opt/hf-tools}"
GATEWAY_VENV="${GATEWAY_VENV:-/opt/llm-gateway}"
GATEWAY_USER="${GATEWAY_USER:-llmgateway}"
WEBUI_VENV="${WEBUI_VENV:-/opt/open-webui}"
UV_PYTHON_DIR="${UV_PYTHON_DIR:-/opt/uv-python}"

# Which components to check (set 0 to skip a section entirely).
INSTALL_ROCM="${INSTALL_ROCM:-1}"
CONFIGURE_MEMORY="${CONFIGURE_MEMORY:-1}"
INSTALL_CLUSTER="${INSTALL_CLUSTER:-1}"
INSTALL_NFS="${INSTALL_NFS:-1}"
INSTALL_VLLM="${INSTALL_VLLM:-1}"
INSTALL_RESIDENCY="${INSTALL_RESIDENCY:-1}"
INSTALL_GATEWAY="${INSTALL_GATEWAY:-1}"
INSTALL_WEBUI="${INSTALL_WEBUI:-1}"
INSTALL_COMFYUI="${INSTALL_COMFYUI:-1}"
INSTALL_XRDP="${INSTALL_XRDP:-1}"
INSTALL_SAMBA="${INSTALL_SAMBA:-1}"
XFER_ROOT="${XFER_ROOT:-/srv/xfer}"
XFER_SHARE="${XFER_SHARE:-xfer}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-1}"
CONFIGURE_UPDATES="${CONFIGURE_UPDATES:-1}"
CONFIGURE_JOURNAL="${CONFIGURE_JOURNAL:-1}"
CONFIGURE_DISK_HEALTH="${CONFIGURE_DISK_HEALTH:-1}"
DISABLE_WIFI="${DISABLE_WIFI:-1}"
DISABLE_BLUETOOTH="${DISABLE_BLUETOOTH:-1}"
JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-2G}"
COMFY_CACHE_MODE="${COMFY_CACHE_MODE:-ram}"
COMFY_RESERVE_VRAM="${COMFY_RESERVE_VRAM:-16}"
COMFY_ENABLE_ASSETS="${COMFY_ENABLE_ASSETS:-0}"
XRDP_DESKTOP="${XRDP_DESKTOP:-xfce}"
DESKTOP_HEADLESS_BOOT="${DESKTOP_HEADLESS_BOOT:-0}"
XFCE_COMPOSITING="${XFCE_COMPOSITING:-0}"
# Must match the setup script's UNATTENDED_HOLD defaults: these are the packages
# whose unattended upgrade would break gfx1151.
UNATTENDED_HOLD="${UNATTENDED_HOLD:-linux-image linux-headers linux-modules linux-generic rocm amdgpu}"

# -----------------------------------------------------------------------------
BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
if [ ! -t 1 ]; then BOLD=""; RED=""; GRN=""; YLW=""; BLU=""; RST=""; fi
PASS_N=0; WARN_N=0; FAIL_N=0; SKIP_N=0
section(){ printf '\n%s%s== %s ==%s\n' "$BLU" "$BOLD" "$*" "$RST"; }
pass(){  printf '  %sPASS%s %s\n' "$GRN" "$RST" "$*"; PASS_N=$((PASS_N+1)); }
warnc(){ printf '  %sWARN%s %s\n' "$YLW" "$RST" "$*"; WARN_N=$((WARN_N+1)); }
fail(){  printf '  %sFAIL%s %s\n' "$RED" "$RST" "$*"; FAIL_N=$((FAIL_N+1)); }
skip(){  printf '  %sSKIP%s %s\n' "$BLU" "$RST" "$*"; SKIP_N=$((SKIP_N+1)); }
info(){  printf '       %s\n' "$*"; }
die(){   printf '%sERROR:%s %s\n' "$RED$BOLD" "$RST" "$*" >&2; exit 1; }

IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1

# =============================================================================
# ARGUMENTS
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_FILE="${MODELS_FILE:-$SCRIPT_DIR/strixhalo-models.txt}"
DO_VERIFY=1; DO_SEED=1; ASSUME_YES=0; DO_REGISTER=1

usage() {
  cat <<USAGE
${BOLD}Usage:${RST} $(basename "$0") --server <hostname> --peer <hostname> [options]

${BOLD}REQUIRED${RST} (same two names you gave the setup script)
  --server <hostname>      the head node: NFS + Ray head + gateway + Open WebUI
  --peer   <hostname>      the worker node

${BOLD}OPTIONS${RST}
  --role server|peer|auto  override role detection (default: auto, from hostname)
  --user <name>            the desktop/service account
                           (default: whatever setup recorded in components.env)
  --verify-only            run the checks, download nothing
  --seed-only              download models, skip the checks
  --models FILE            model list (default: $MODELS_FILE)
  --no-register            download models but do NOT add them to the catalog
  --write-example-models   scaffold an example model list, then exit
  -y, --yes                do not prompt before downloading
  -h, --help               this help

Run on EACH node after setup + reboot. Verification is read-only; a few checks
need root and are reported as SKIP without it.
USAGE
}

need_arg(){ [ -n "${2:-}" ] || die "$1 needs a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --server)      need_arg "$1" "${2:-}"; SERVER_HOST="$2"; shift ;;
    --peer)        need_arg "$1" "${2:-}"; PEER_HOST="$2"; shift ;;
    --role)        need_arg "$1" "${2:-}"; NODE_ROLE="$2"; shift ;;
    --user)        need_arg "$1" "${2:-}"; TARGET_USER="$2"; USER_FROM_CLI=1; shift ;;
    --verify-only) DO_SEED=0 ;;
    --seed-only)   DO_VERIFY=0 ;;
    --models)      need_arg "$1" "${2:-}"; MODELS_FILE="$2"; shift ;;
    --no-register) DO_REGISTER=0 ;;
    --write-example-models) WRITE_EXAMPLE=1 ;;
    -y|--yes)      ASSUME_YES=1 ;;
    -h|--help)     usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# =============================================================================
# ROLE + RECORDED FACTS
# =============================================================================
# Prefer what the setup script actually wrote over what was typed on the command
# line: if they disagree, the disk is right and the operator needs to know.
load_facts() {
  local f
  for f in "$LLM_ETC/runtime.env" "$LLM_ETC/components.env" /etc/default/usb4-cluster; do
    [ -r "$f" ] || continue
    while IFS='=' read -r k v; do
      case "$k" in ''|\#*) continue ;; esac
      v="${v%\"}"; v="${v#\"}"
      case "$k" in
        TARGET_USER) [ -n "$v" ] && SETUP_TARGET_USER="$v" ;;
        LLM_ROOT|LLM_ETC|LLM_USER|SHARE_GROUP|RAY_PORT|AGENT_PORT|GATEWAY_PORT|\
        RESIDENCY_SOCK|VLLM_RUNTIME|VLLM_IMAGE|VLLM_CONTAINER|VLLM_VENV|\
        CONTAINER_ENGINE|CE_BIN|RESIDENCY_BUDGET_GIB|VLLM_PORT_BASE|\
        CLUSTER_IFACE|CLUSTER_LOCAL_IP|CLUSTER_PEER_IP|CLUSTER_MTU|CLUSTER_ROLE|\
        INSTALL_ROCM|CONFIGURE_MEMORY|INSTALL_CLUSTER|INSTALL_NFS|INSTALL_VLLM|\
        INSTALL_RESIDENCY|INSTALL_GATEWAY|INSTALL_WEBUI|INSTALL_COMFYUI|\
        INSTALL_XRDP|CONFIGURE_FIREWALL|CONFIGURE_UPDATES|CONFIGURE_JOURNAL|\
        INSTALL_SAMBA|XFER_ROOT|XFER_SHARE|\
        CONFIGURE_DISK_HEALTH|DISABLE_WIFI|DISABLE_BLUETOOTH|JOURNAL_MAX_USE|\
        COMFY_CACHE_MODE|COMFY_RESERVE_VRAM|COMFY_ENABLE_ASSETS|HF_TOOLS_VENV|\
        GATEWAY_VENV|GATEWAY_USER|WEBUI_VENV|UV_PYTHON_DIR|\
        XRDP_DESKTOP|DESKTOP_HEADLESS_BOOT|XFCE_COMPOSITING)
          [ -n "$v" ] && printf -v "$k" '%s' "$v" ;;
      esac
    done < "$f"
  done
}
VLLM_RUNTIME="${VLLM_RUNTIME:-}"; VLLM_VENV="${VLLM_VENV:-/opt/vllm}"
VLLM_CONTAINER="${VLLM_CONTAINER:-llm-runtime}"; CE_BIN="${CE_BIN:-}"
CLUSTER_LOCAL_IP="${CLUSTER_LOCAL_IP:-}"; CLUSTER_PEER_IP="${CLUSTER_PEER_IP:-}"
CLUSTER_ROLE="${CLUSTER_ROLE:-}"; RESIDENCY_BUDGET_GIB="${RESIDENCY_BUDGET_GIB:-}"
load_facts

# ---------------------------------------------------------------------------
# Resolve the desktop/service account, and REFUSE to continue without a real
# one. Getting this wrong is not a cosmetic problem: an empty user makes
# 'id -nG' fail, so the render/video/aimodels group checks all report FAIL, and
# USER_HOME collapses to '/home/', so every ComfyUI symlink check reports FAIL
# too - six red lines that have nothing to do with the machine's actual state.
if [ "$USER_FROM_CLI" != "1" ]; then
  # The account the SETUP script recorded wins over whoever happens to be
  # running this: they are frequently different people, and it is the recorded
  # one that owns ~/ComfyUI and the render/video group memberships.
  for _cand in "$SETUP_TARGET_USER" "${SUDO_USER:-}" "${USER:-}" "$(id -un 2>/dev/null || true)"; do
    if [ -n "$_cand" ] && getent passwd "$_cand" >/dev/null 2>&1; then
      TARGET_USER="$_cand"; break
    fi
  done
fi
if [ -z "$TARGET_USER" ] || ! getent passwd "$TARGET_USER" >/dev/null 2>&1; then
  die "cannot determine the desktop account (got '${TARGET_USER}'). Pass --user <name>."
fi

MY_HOST="$(hostname -s 2>/dev/null || hostname)"
resolve_role() {
  if [ -z "$SERVER_HOST" ] || [ -z "$PEER_HOST" ]; then
    # Fall back to what the setup script recorded, so --verify-only still works
    # without repeating the hostnames.
    if [ -n "$CLUSTER_ROLE" ]; then
      NODE_ROLE="$CLUSTER_ROLE"
      [ -n "$SERVER_HOST" ] || SERVER_HOST="$([ "$NODE_ROLE" = "server" ] && echo "$MY_HOST" || echo "<server>")"
      [ -n "$PEER_HOST" ]   || PEER_HOST="$([ "$NODE_ROLE" = "peer" ] && echo "$MY_HOST" || echo "<peer>")"
      return 0
    fi
    die "--server and --peer are required (this node has no /etc/llm/runtime.env to read them from)."
  fi
  [ "$SERVER_HOST" != "$PEER_HOST" ] || die "--server and --peer must be different hostnames"
  case "$NODE_ROLE" in
    server|peer) ;;
    auto)
      if [ "$MY_HOST" = "$SERVER_HOST" ]; then NODE_ROLE=server
      elif [ "$MY_HOST" = "$PEER_HOST" ]; then NODE_ROLE=peer
      elif [ -n "$CLUSTER_ROLE" ]; then
        NODE_ROLE="$CLUSTER_ROLE"
        warnc "hostname '$MY_HOST' matches neither --server nor --peer; using the recorded role '$NODE_ROLE'"
      else
        die "hostname '$MY_HOST' is neither '$SERVER_HOST' nor '$PEER_HOST'. Pass --role server|peer."
      fi
      ;;
    *) die "--role must be server, peer or auto" ;;
  esac
  if [ -n "$CLUSTER_ROLE" ] && [ "$CLUSTER_ROLE" != "$NODE_ROLE" ]; then
    warnc "this node was SET UP as '$CLUSTER_ROLE' but is being verified as '$NODE_ROLE'"
  fi
}
resolve_role
IS_SERVER=0; IS_PEER=0
if [ "$NODE_ROLE" = "server" ]; then IS_SERVER=1; OTHER_HOST="$PEER_HOST"; else IS_PEER=1; OTHER_HOST="$SERVER_HOST"; fi
[ -n "$CLUSTER_LOCAL_IP" ] || CLUSTER_LOCAL_IP="${CLUSTER_NET}.$([ "$IS_SERVER" = "1" ] && echo 1 || echo 2)"
[ -n "$CLUSTER_PEER_IP" ]  || CLUSTER_PEER_IP="${CLUSTER_NET}.$([ "$IS_SERVER" = "1" ] && echo 2 || echo 1)"
SERVER_IP="$([ "$IS_SERVER" = "1" ] && echo "$CLUSTER_LOCAL_IP" || echo "$CLUSTER_PEER_IP")"

USER_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$USER_HOME" ] || USER_HOME="/home/$TARGET_USER"
COMFY_DIR="$USER_HOME/ComfyUI"

run_user() {
  if [ "$IS_ROOT" = "1" ] && [ "$TARGET_USER" != "root" ]; then sudo -u "$TARGET_USER" -H "$@"; else "$@"; fi
}
http_ok(){  curl -fsS --max-time "${2:-5}" "$1" >/dev/null 2>&1; }
http_get(){ curl -fsS --max-time "${2:-5}" "$1" 2>/dev/null; }
uds_get(){  curl -fsS --max-time "${3:-5}" --unix-socket "$1" "http://residencyd$2" 2>/dev/null; }
port_open(){ ss -ltn 2>/dev/null | grep -E "[:.]${1}[[:space:]]" >/dev/null; }

# Run a command under a hard time limit and print what it produced.
#
# '$(timeout N cmd)' is NOT enough. timeout signals only the process it started;
# 'podman exec' leaves the process it spawned INSIDE the container running, and
# that surviving grandchild still holds the write end of the command
# substitution's pipe. The substitution then blocks forever even though timeout
# has already returned - which is exactly where this script stopped dead on
# mighty-ai2, at 'llm-run ray status' against a Ray that had no GCS to reach.
# Capturing through a file instead of a pipe removes anything to wait on, so the
# limit is real no matter what the command leaves behind.
run_capped() {  # $1 seconds  $2.. command
  local secs="$1"; shift
  local out rc
  out="$(mktemp 2>/dev/null)" || return 124
  timeout -k 5 "$secs" "$@" >"$out" 2>/dev/null </dev/null
  rc=$?
  cat "$out" 2>/dev/null
  rm -f "$out"
  return "$rc"
}

# 203/EXEC is the most opaque failure systemd produces, and here it has exactly
# one cause worth naming: uv puts the interpreters it downloads under
# $HOME/.local/share/uv/python, which for root is /root/... at mode 0700. A venv
# built there by root has bin/python pointing somewhere no service account can
# traverse. systemd then reports "Permission denied" when ExecStart is a script
# (its interpreter is unreachable) or "No such file or directory" when ExecStart
# is the symlink itself - neither of which mentions the real problem.
venv_user_check() {  # <unit> <label> <venv> <service-user>
  local unit="$1" label="$2" venv="$3" u="$4" py real
  py="$venv/bin/python"
  [ -d "$venv" ] || return 0
  if [ ! -e "$py" ]; then
    fail "$label: $py does not exist - its virtualenv was never built"
    info "re-run the setup script on this node to rebuild it"
    return 0
  fi
  id "$u" >/dev/null 2>&1 || return 0
  if [ "$IS_ROOT" != "1" ]; then
    skip "$label interpreter permission check (needs root)"
    return 0
  fi
  local rc=1
  local g; g="$(id -gn "$u" 2>/dev/null || echo "$u")"
  # Prove the drop-privileges mechanism works before trusting a failure from it:
  # inside a container or a user namespace setpriv cannot switch uid at all, and
  # reporting that as "the service account cannot execute python" is a lie.
  if command -v setpriv >/dev/null 2>&1 \
     && setpriv --reuid="$u" --regid="$g" --clear-groups /bin/true >/dev/null 2>&1; then
    setpriv --reuid="$u" --regid="$g" --clear-groups "$py" -c 'import sys' >/dev/null 2>&1 && rc=0
  elif command -v runuser >/dev/null 2>&1 && runuser -u "$u" -- /bin/true >/dev/null 2>&1; then
    runuser -u "$u" -- "$py" -c 'import sys' >/dev/null 2>&1 && rc=0
  elif command -v sudo >/dev/null 2>&1 && sudo -n -u "$u" /bin/true >/dev/null 2>&1; then
    sudo -n -u "$u" "$py" -c 'import sys' >/dev/null 2>&1 && rc=0
  else
    skip "$label interpreter permission check (cannot drop privileges here)"
    return 0
  fi
  if [ "$rc" = "0" ]; then
    pass "$label interpreter is executable by '$u'"
  else
    real="$(readlink -f "$py" 2>/dev/null || echo "$py")"
    fail "$label: '$u' cannot execute $py - $unit will fail with 203/EXEC"
    info "it resolves to $real"
    info "fix: sudo chmod -R a+rX $UV_PYTHON_DIR $venv && sudo systemctl restart $unit"
    info "if it resolves under /root, re-run setup: the venv must be rebuilt elsewhere"
  fi
}

# Check a systemd unit and, optionally, the port and URL it should answer on.
#   svc_check <unit> <label> [port] [url]
svc_check() {
  local unit="$1" label="$2" port="${3:-}" url="${4:-}" active enabled
  if ! systemctl list-unit-files "$unit" >/dev/null 2>&1 \
     && [ ! -f "/etc/systemd/system/$unit" ]; then
    fail "$label: $unit does not exist - the setup script never got this far"
    return
  fi
  active="$(systemctl is-active "$unit" 2>/dev/null)"
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null)"
  if [ "$active" = "active" ]; then
    pass "$label: $unit active (enabled: ${enabled:-unknown})"
  else
    fail "$label: $unit is '$active' (enabled: ${enabled:-unknown})"
    local jl; jl="$(journalctl -u "$unit" -n 8 --no-pager -o cat 2>/dev/null)"
    if [ -n "$jl" ]; then
      info "last log lines (journalctl -u $unit -e for more):"
      printf '%s\n' "$jl" | sed 's/^/         | /'
    fi
    return
  fi
  if [ -n "$port" ]; then
    if port_open "$port"; then pass "$label: listening on $port"
    else warnc "$label: nothing listening on port $port yet"; fi
  fi
  if [ -n "$url" ]; then
    if http_ok "$url" 10; then pass "$label: responding at $url"
    else warnc "$label: no answer yet at $url"; fi
  fi
}

# =============================================================================
# VERIFY
# =============================================================================
verify() {
  printf '%s%sVerifying %s%s  role=%s  peer=%s  user=%s\n' \
    "$BLU" "$BOLD" "$MY_HOST" "$RST" "$NODE_ROLE" "$OTHER_HOST" "$TARGET_USER"
  [ "$IS_ROOT" = "1" ] || info "(not root: firewall, NFS export and residencyd socket checks will be skipped)"

  # Anything the setup script was told to skip is reported once, here, so the
  # sections below stay silent instead of failing for something nobody asked for.
  local _pair _var _label _any=0
  for _pair in "INSTALL_ROCM:ROCm + RCCL" "CONFIGURE_MEMORY:unified GPU memory" \
               "INSTALL_CLUSTER:USB4 cluster link" "INSTALL_NFS:shared storage (NFS)" \
               "INSTALL_VLLM:vLLM runtime and Ray" "INSTALL_RESIDENCY:residency control plane" \
               "INSTALL_GATEWAY:llm-gateway" "INSTALL_WEBUI:Open WebUI" \
               "INSTALL_COMFYUI:ComfyUI" "INSTALL_XRDP:remote desktop (XRDP)" \
               "INSTALL_SAMBA:Windows file share (Samba)" \
               "CONFIGURE_FIREWALL:firewall"; do
    _var="${_pair%%:*}"; _label="${_pair#*:}"
    if [ "${!_var}" != "1" ]; then
      [ "$_any" = "1" ] || section "Not installed on this node"
      _any=1
      skip "$_label - setup was run with --skip, so it is not checked"
    fi
  done

  # ---------------------------------------------------------------- OS -----
  section "OS / kernel"
  command -v lsb_release >/dev/null 2>&1 && info "$(lsb_release -ds 2>/dev/null)"
  local kr kmaj kmin; kr="$(uname -r)"; kmaj="${kr%%.*}"; kmin="$(echo "$kr" | cut -d. -f2)"
  if [ "${kmaj:-0}" -gt 6 ] || { [ "${kmaj:-0}" -eq 6 ] && [ "${kmin:-0}" -ge 17 ]; }; then
    pass "kernel $kr includes the gfx1151 KFD/memory fixes"
  else
    warnc "kernel $kr is older than 6.17; the iGPU may expose only ~15 GB to ROCm"
  fi
  local mem_gib; mem_gib=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  if [ "$mem_gib" -ge 96 ]; then pass "RAM ~${mem_gib} GiB"
  else warnc "RAM ~${mem_gib} GiB - the plan assumes 128 GB per node"; fi

  # --------------------------------------------------------------- GPU -----
  section "GPU devices and permissions"
  if [ -e /dev/kfd ]; then pass "/dev/kfd present"; else fail "/dev/kfd missing - amdgpu did not bind the iGPU"; fi
  local rd; rd="$(ls /dev/dri/renderD* 2>/dev/null | head -n1)"
  if [ -n "$rd" ]; then pass "render node $rd present"; else fail "no /dev/dri/renderD* - no GPU access at all"; fi
  local ugroups; ugroups="$(id -nG "$TARGET_USER" 2>/dev/null || true)"
  for g in render video "$SHARE_GROUP"; do
    if grep -w "$g" <<<"$ugroups" >/dev/null; then pass "$TARGET_USER is in group '$g'"
    else fail "$TARGET_USER is NOT in group '$g' (log out and back in, or reboot)"; fi
  done
  if id -u "$LLM_USER" >/dev/null 2>&1; then
    pass "service account '$LLM_USER' exists (uid $(id -u "$LLM_USER"))"
    info "NFS maps ownership by NUMBER: this uid must be identical on both nodes"
  else
    fail "service account '$LLM_USER' is missing"
  fi

  # -------------------------------------------------------------- ROCm -----
  if [ "$INSTALL_ROCM" = "1" ]; then
    section "ROCm + RCCL"
    local rocminfo_bin=""
    command -v rocminfo >/dev/null 2>&1 && rocminfo_bin="$(command -v rocminfo)"
    [ -n "$rocminfo_bin" ] || { [ -x /opt/rocm/bin/rocminfo ] && rocminfo_bin=/opt/rocm/bin/rocminfo; }
    if [ -z "$rocminfo_bin" ]; then
      fail "rocminfo not found - ROCm is not installed"
    elif "$rocminfo_bin" 2>/dev/null | grep "$ROCM_GFX" >/dev/null; then
      pass "rocminfo reports $ROCM_GFX"
    else
      fail "rocminfo does not report $ROCM_GFX - vLLM will not see the iGPU"
      info "check 'Above 4G Decoding' is enabled in the BIOS, then: $rocminfo_bin | grep gfx"
    fi
    if ldconfig -p 2>/dev/null | grep 'librccl\.so' >/dev/null || ls /opt/rocm/lib/librccl.so* >/dev/null 2>&1; then
      pass "RCCL present (cross-node tensor parallelism)"
    else
      fail "RCCL is missing - distributed (TP=2) models cannot run"
    fi
    if command -v amd-smi >/dev/null 2>&1; then
      info "$(amd-smi static -g 0 2>/dev/null | grep -iE 'market_name|vram' | head -n2 | tr -s ' ' | paste -sd'; ' -)"
    fi
    if [ -n "${HSA_OVERRIDE_GFX_VERSION:-}" ]; then
      fail "HSA_OVERRIDE_GFX_VERSION is set ('$HSA_OVERRIDE_GFX_VERSION') - gfx1151 is native; this loads the WRONG kernels"
    fi
  fi

  # ------------------------------------------------------------ memory -----
  if [ "$CONFIGURE_MEMORY" = "1" ]; then
    section "Unified GPU memory (TTM/GTT)"
    local pl; pl="$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo 0)"
    if [ "${pl:-0}" -gt 0 ]; then
      local gib=$(( pl / 262144 ))
      local want=$(( mem_gib - OS_RESERVE_GIB ))
      if [ "$gib" -ge $(( want - 8 )) ]; then
        pass "TTM pages_limit = $pl (~${gib} GiB GPU-addressable)"
      else
        fail "TTM pages_limit is only ~${gib} GiB (expected ~${want} GiB) - did you reboot after setup?"
      fi
    else
      fail "/sys/module/ttm/parameters/pages_limit unreadable"
    fi
    if grep -s 'pages_limit' /etc/modprobe.d/ttm.conf >/dev/null 2>&1; then
      pass "/etc/modprobe.d/ttm.conf persists the limit across reboots"
    else
      fail "/etc/modprobe.d/ttm.conf has no pages_limit - the setting will vanish on reboot"
    fi
    if [ -n "$RESIDENCY_BUDGET_GIB" ]; then
      info "residencyd admits models against ${RESIDENCY_BUDGET_GIB} GiB on this node"
    fi
  fi

  # -------------------------------------------------------------- USB4 -----
  if [ "$INSTALL_CLUSTER" = "1" ]; then
    section "USB4 cluster link ($CLUSTER_IFACE)"
    if lsmod 2>/dev/null | grep '^thunderbolt_net' >/dev/null; then
      pass "thunderbolt_net module loaded"
    else
      fail "thunderbolt_net is NOT loaded - this is the #1 cause of a missing interface"
      info "load it with: sudo modprobe thunderbolt_net"
    fi
    if [ -d "/sys/class/net/$CLUSTER_IFACE" ]; then
      pass "interface $CLUSTER_IFACE exists"
      local oper mtu addr
      oper="$(cat "/sys/class/net/$CLUSTER_IFACE/operstate" 2>/dev/null)"
      if [ "$oper" = "up" ]; then pass "$CLUSTER_IFACE is up"
      else fail "$CLUSTER_IFACE is '$oper' - is the cable connected at BOTH ends?"; fi
      mtu="$(cat "/sys/class/net/$CLUSTER_IFACE/mtu" 2>/dev/null || echo 0)"
      if [ "$mtu" = "$CLUSTER_MTU" ]; then pass "MTU $mtu"
      else warnc "MTU is $mtu, expected $CLUSTER_MTU (BOTH nodes must agree or the link fragments)"; fi
      addr="$(ip -4 -br addr show "$CLUSTER_IFACE" 2>/dev/null | awk '{print $3}')"
      if [ "$addr" = "$CLUSTER_LOCAL_IP/$CLUSTER_CIDR" ]; then pass "address $addr"
      elif [ -n "$addr" ]; then warnc "address is $addr, expected $CLUSTER_LOCAL_IP/$CLUSTER_CIDR"
      else fail "no IPv4 address on $CLUSTER_IFACE - netplan did not apply"; fi
    else
      local real
      real="$(for n in /sys/class/net/*; do
                [ -e "$n/device/driver" ] || continue
                case "$(basename "$(readlink -f "$n/device/driver")")" in
                  thunderbolt-net|thunderbolt_net) basename "$n" ;;
                esac
              done | head -n1)"
      if [ -n "$real" ]; then
        fail "the link enumerated as '$real', not '$CLUSTER_IFACE' - the .link rename did not take"
        info "check /etc/systemd/network/70-usb4-cluster.link, then reboot"
      else
        fail "no thunderbolt-net interface at all - check the cable and 'boltctl list'"
      fi
    fi
    [ -f /etc/netplan/60-usb4-cluster.yaml ] \
      && pass "netplan config present (/etc/netplan/60-usb4-cluster.yaml)" \
      || fail "/etc/netplan/60-usb4-cluster.yaml is missing"
    if ping -c2 -W2 -n "$CLUSTER_PEER_IP" >/dev/null 2>&1; then
      pass "$OTHER_HOST answers on $CLUSTER_PEER_IP over the cable"
    else
      fail "$OTHER_HOST ($CLUSTER_PEER_IP) is unreachable over $CLUSTER_IFACE"
      info "on the other node check: ip -br addr show $CLUSTER_IFACE, and its ufw rule"
    fi
    if command -v boltctl >/dev/null 2>&1; then
      # A host-to-host USB4 link is an XDomain connection: the kernel gives it no
      # 'authorized' attribute and bolt has nothing to enrol, because there is no
      # peripheral to trust - the two host routers brought the link up between
      # themselves. Route strings ending in -0 are this machine's OWN host
      # routers, which DO carry an 'authorized' file and must not be counted.
      local tb_peer=0 tb_xdom=0 tb
      for tb in /sys/bus/thunderbolt/devices/[0-9]*-[0-9]*; do
        [ -d "$tb" ] || continue
        case "${tb##*/}" in *-0) continue ;; esac
        if [ -e "$tb/authorized" ]; then tb_peer=$((tb_peer+1)); else tb_xdom=$((tb_xdom+1)); fi
      done
      if boltctl list 2>/dev/null | grep -i 'authorized' >/dev/null; then
        pass "bolt reports an authorized peer device"
      elif [ "$tb_peer" -eq 0 ] && [ "$tb_xdom" -gt 0 ]; then
        pass "USB4 runs as a host-to-host XDomain link (nothing to authorize)"
      else
        warnc "bolt lists no authorized device (fine if IOMMU auto-authorization handled it)"
      fi
    fi
    if command -v iperf3 >/dev/null 2>&1; then
      info "measure the link: on $OTHER_HOST run 'iperf3 -s', here run 'iperf3 -c $CLUSTER_PEER_IP -P 4'"
      info "expect roughly 10-16 Gbit/s. 40 Gbit/s is the cable rating, not the throughput."
    fi
    if dmesg 2>/dev/null | grep -i 'ucsi' | grep -iE 'fail|error|timeout' >/dev/null; then
      warnc "UCSI errors in dmesg - the known Strix Halo PPM firmware bug; only a BIOS/AGESA update fixes it"
    fi
    info "full diagnostics: sudo usb4-cluster-status"
  fi

  # --------------------------------------------------------------- NFS -----
  if [ "$INSTALL_NFS" = "1" ]; then
    section "Shared storage (NFS)"
    if [ "$IS_SERVER" = "1" ]; then
      svc_check nfs-server.service "NFS server"
      if [ -f /etc/exports.d/llm-cluster.exports ]; then
        pass "export file present"
        info "$(tr -s ' ' < /etc/exports.d/llm-cluster.exports | grep -v '^#' | paste -sd'; ' -)"
      else
        fail "/etc/exports.d/llm-cluster.exports is missing"
      fi
      if [ "$IS_ROOT" = "1" ]; then
        local ex; ex="$(exportfs -s 2>/dev/null)"
        if grep "$LLM_ROOT" <<<"$ex" >/dev/null; then pass "$LLM_ROOT is exported"
        else fail "$LLM_ROOT is not in the active export table (exportfs -ra)"; fi
        if grep "$COMFY_ROOT" <<<"$ex" >/dev/null; then pass "$COMFY_ROOT is exported"
        else fail "$COMFY_ROOT is not in the active export table"; fi
        # exportfs -s prints the FULL resolved option list, not the abbreviated
        # form from the exports file: 'ro' lands in the middle of
        # (sync,wdelay,hide,no_subtree_check,ro,root_squash,...), so matching on
        # a literal '(ro' reports the export as writable when it is not.
        # Check the model line only - /srv/comfyui is rw on purpose.
        local exline
        exline="$(grep -E "^${LLM_ROOT}[[:space:]]" <<<"$ex" | head -n1)"
        [ -n "$exline" ] || exline="$ex"
        if grep -E '[(,]ro[,)]' <<<"$exline" >/dev/null; then
          pass "the model repository is exported READ-ONLY (as designed)"
        else
          warnc "$LLM_ROOT is not exported read-only - the peer could write to it"
          info "active options: ${exline}"
        fi
      else
        skip "export table check (needs root)"
      fi
      for d in "$LLM_ROOT" "$COMFY_ROOT"; do
        [ -d "$d" ] && pass "$d exists ($(du -sh "$d" 2>/dev/null | cut -f1) used)" || fail "$d is missing"
      done
    else
      for d in "$LLM_ROOT" "$COMFY_ROOT"; do
        if mountpoint -q "$d" 2>/dev/null; then
          pass "$d is mounted ($(findmnt -no SOURCE,FSTYPE "$d" 2>/dev/null | tr -s ' '))"
        elif [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
          pass "$d is readable (automount may not register as a mountpoint until touched)"
        else
          fail "$d is not mounted from $SERVER_HOST"
          info "try: sudo mount $d   then check 'journalctl -u ${d#/}.mount'"
        fi
      done
      if [ -r "$LLM_ROOT" ] && ls "$LLM_ROOT" >/dev/null 2>&1; then
        pass "the model repository is readable"
        if run_user test -w "$LLM_ROOT" 2>/dev/null; then
          warnc "$LLM_ROOT is WRITABLE here - it should be exported read-only"
        else
          pass "$LLM_ROOT is read-only here (as designed)"
        fi
      fi
      if run_user test -w "$COMFY_ROOT" 2>/dev/null; then
        pass "$COMFY_ROOT is writable (ComfyUI can download into the shared store)"
      else
        fail "$COMFY_ROOT is not writable by $TARGET_USER - shared ComfyUI downloads will fail"
      fi
      if [ -r "$COMFY_ROOT/.cluster-ids" ]; then
        local sv_uid lo_uid
        sv_uid="$(awk -F= '$1=="LLM_UID"{print $2}' "$COMFY_ROOT/.cluster-ids" 2>/dev/null)"
        lo_uid="$(id -u "$LLM_USER" 2>/dev/null)"
        if [ -n "$sv_uid" ] && [ "$sv_uid" = "$lo_uid" ]; then
          pass "uid of '$LLM_USER' matches the server ($lo_uid)"
        else
          fail "uid mismatch: server has $sv_uid, this node has $lo_uid - NFS permissions WILL misbehave"
        fi
      fi
      [ -d "$LLM_LOCAL_CACHE" ] && pass "local scratch $LLM_LOCAL_CACHE present" \
                                || warnc "$LLM_LOCAL_CACHE missing (Ray spill and compile caches have nowhere fast to go)"
    fi
  fi

  # -------------------------------------------------------- vLLM / Ray -----
  if [ "$INSTALL_VLLM" = "1" ]; then
    section "vLLM runtime and Ray"
    [ -x /usr/local/bin/llm-run ] && pass "/usr/local/bin/llm-run present" \
                                  || fail "/usr/local/bin/llm-run missing"
    [ -r "$LLM_ETC/cluster.env" ] && pass "$LLM_ETC/cluster.env present" \
                                  || fail "$LLM_ETC/cluster.env missing"
    if [ -r "$LLM_ETC/cluster.env" ]; then
      local ifn; ifn="$(awk -F= '$1=="NCCL_SOCKET_IFNAME"{print $2}' "$LLM_ETC/cluster.env")"
      if [ "$ifn" = "$CLUSTER_IFACE" ]; then
        pass "collectives pinned to $CLUSTER_IFACE (NCCL_SOCKET_IFNAME)"
      else
        fail "NCCL_SOCKET_IFNAME is '$ifn', not '$CLUSTER_IFACE' - RCCL will use the slow LAN"
      fi
      awk -F= '$1=="RAY_memory_monitor_refresh_ms" && $2=="0"' "$LLM_ETC/cluster.env" | grep . >/dev/null \
        && pass "Ray's memory monitor is disabled (required: GPU memory IS host RAM here)" \
        || warnc "RAY_memory_monitor_refresh_ms is not 0 - Ray may OOM-kill healthy workers"
    fi
    case "$VLLM_RUNTIME" in
      container)
        info "runtime: container ($VLLM_CONTAINER via ${CE_BIN:-podman})"
        # The unit runs --ipc host, so the container shares THIS pool. Too small
        # and torch's shared-memory tensors die with a bare "Bus error".
        local shm_g; shm_g="$(df -B1G --output=size /dev/shm 2>/dev/null | tail -n1 | tr -dc '0-9')"
        if [ -z "$shm_g" ]; then
          warnc "could not read the size of /dev/shm"
        elif [ "$shm_g" -ge 8 ]; then
          pass "/dev/shm is ${shm_g} GiB (shared with the container via --ipc host)"
        else
          fail "/dev/shm is only ${shm_g} GiB - torch tensors will fail with a bus error"
          info "raise it: sudo mount -o remount,size=32G /dev/shm (and add it to /etc/fstab)"
        fi
        # Match the ExecStart line only: the unit carries a comment explaining
        # why --shm-size is absent, and a bare grep flags that comment as the
        # very fault it documents.
        if grep -E '^ExecStart=.*--shm-size' /etc/systemd/system/llm-runtime.service >/dev/null 2>&1; then
          fail "llm-runtime.service still passes --shm-size alongside --ipc host"
          info "podman refuses that combination outright (exit 125); re-run setup to fix"
        else
          pass "llm-runtime.service does not combine --shm-size with --ipc host"
        fi
        # podman resolves --group-add NAMES in the CONTAINER's /etc/group. The
        # ROCm image has no 'render' entry, so a name here aborts the container
        # with "unable to find group render" before vLLM ever starts.
        if grep -E '^[^#]*--group-add[[:space:]]+[A-Za-z]' \
             /etc/systemd/system/llm-runtime.service >/dev/null 2>&1; then
          fail "llm-runtime.service passes --group-add by NAME"
          info "podman looks that name up inside the image, which has no 'render' group"
          info "re-run setup: it emits the numeric host gids instead"
        else
          pass "llm-runtime.service passes GPU groups as numeric gids"
        fi
        # On the server the model tree and HF_HOME are the same path, and the
        # unit used to name it twice. podman rejects that outright:
        # "duplicate mount destination".
        dupv="$(grep -oE '^[[:space:]]*-v [^:]+:[^:]+' \
                  /etc/systemd/system/llm-runtime.service 2>/dev/null \
                | awk -F: '{print $NF}' | sort | uniq -d | head -3 || true)"
        if [ -n "$dupv" ]; then
          fail "llm-runtime.service mounts the same destination twice: $(echo "$dupv" | tr '\n' ' ')"
          info "podman refuses a duplicate mount destination; re-run setup to fix"
        else
          pass "llm-runtime.service has no duplicate mount destination"
        fi
        svc_check llm-runtime.service "runtime container"
        # The units that call llm-run are podman CLIENTS in container mode.
        # podman is rootless for everyone but root, so a client running as an
        # unprivileged account looks in its own empty container store and never
        # finds the root-owned runtime container - every llm-run then fails with
        # "container 'llm-runtime' is not running" while root sees it running.
        # That is precisely how mighty-ai2's Ray worker died.
        local cu ru
        for cu in ray-head.service ray-worker.service vllm@.service; do
          [ -f "/etc/systemd/system/$cu" ] || continue
          ru="$(grep -E '^User=' "/etc/systemd/system/$cu" 2>/dev/null | tail -n1 | cut -d= -f2)"
          if [ -n "$ru" ] && [ "$ru" != "root" ]; then
            fail "$cu runs as '$ru', but podman is rootless for that account"
            info "it would never see the root-owned '$VLLM_CONTAINER'; re-run setup to fix"
          else
            pass "$cu drives podman as root (the container does the confining)"
          fi
        done
        if [ -n "$CE_BIN" ] && [ -x "$CE_BIN" ]; then
          if "$CE_BIN" inspect -f '{{.State.Running}}' "$VLLM_CONTAINER" 2>/dev/null | grep true >/dev/null; then
            pass "container '$VLLM_CONTAINER' is running"
            # Same podman-exec hazard as 'ray status' below: bound it.
            if run_capped 60 /usr/local/bin/llm-run python -c 'import vllm' >/dev/null; then
              pass "vLLM imports inside the container"
            else
              fail "vLLM does not import inside the container - wrong image?"
            fi
          else
            fail "container '$VLLM_CONTAINER' is not running"
          fi
        fi
        ;;
      venv)
        info "runtime: venv ($VLLM_VENV)"
        if [ -x "$VLLM_VENV/bin/python" ]; then
          "$VLLM_VENV/bin/python" -c 'import torch' >/dev/null 2>&1 \
            && pass "torch imports in the venv" || fail "torch does not import in $VLLM_VENV"
          if "$VLLM_VENV/bin/python" -c 'import vllm' >/dev/null 2>&1; then
            pass "vLLM imports in the venv"
          else
            fail "vLLM is NOT installed in the venv"
            info "AMD publishes no gfx1151 vllm wheel. Re-run setup with --vllm-runtime container."
          fi
        else
          fail "$VLLM_VENV/bin/python missing"
        fi
        venv_user_check "vllm@.service" "vLLM" "$VLLM_VENV" "$LLM_USER"
        ;;
      *) warnc "no runtime recorded in $LLM_ETC/runtime.env - was the vLLM section skipped?" ;;
    esac
    if [ "$IS_SERVER" = "1" ]; then svc_check ray-head.service "Ray head" "$RAY_PORT"
    else svc_check ray-worker.service "Ray worker"; fi
    local rs; rs="$(run_capped 45 /usr/local/bin/llm-run ray status)"
    if [ -n "$rs" ]; then
      local nodes; nodes="$(grep -cE '^ *1 node_' <<<"$rs" 2>/dev/null || echo 0)"
      [ "${nodes:-0}" -eq 0 ] && nodes="$(grep -c 'node_' <<<"$rs" 2>/dev/null || echo 0)"
      if [ "${nodes:-0}" -ge 2 ]; then
        pass "Ray cluster has $nodes nodes - both machines have joined"
      else
        fail "Ray reports $nodes node(s); distributed (TP=2) models need 2"
        info "on the peer: systemctl status ray-worker; it must reach ${SERVER_IP}:${RAY_PORT}"
      fi
      grep -E 'GPU' <<<"$rs" | head -n2 | sed 's/^/         | /'
    else
      warnc "'llm-run ray status' produced no output (runtime not up yet?)"
    fi
    [ -f /etc/systemd/system/vllm@.service ] && pass "vllm@.service template installed" \
                                             || fail "vllm@.service template missing"
  fi

  # ----------------------------------------------------------- catalog -----
  section "Model catalog"
  if [ -L "$LLM_ETC/models.d" ]; then
    local tgt; tgt="$(readlink -f "$LLM_ETC/models.d" 2>/dev/null)"
    if [ -d "$LLM_ETC/models.d" ]; then
      pass "$LLM_ETC/models.d -> $tgt (shared by both nodes)"
    else
      fail "$LLM_ETC/models.d points at $tgt, which does not resolve (is $LLM_ROOT mounted?)"
    fi
  elif [ -d "$LLM_ETC/models.d" ]; then
    warnc "$LLM_ETC/models.d is a LOCAL directory, not a link into $LLM_ROOT/catalog"
    info "the two nodes can disagree about which models exist; re-run setup to fix"
  else
    fail "$LLM_ETC/models.d does not exist"
  fi
  local ncat; ncat="$(ls "$LLM_ETC/models.d"/*.conf 2>/dev/null | wc -l)"
  if [ "${ncat:-0}" -gt 0 ]; then
    pass "$ncat model(s) in the catalog"
    /usr/local/bin/llm-model list 2>/dev/null | sed 's/^/         | /'
    # A model with no tool parser cannot emit tool_calls, so an agentic editor
    # client (Cline, Copilot Chat agent mode) connects, looks healthy, and then
    # silently does nothing. Worth naming explicitly rather than leaving the
    # operator to discover it from the other end.
    local notools=() nokeepwarm=1 c cname
    for c in "$LLM_ETC/models.d"/*.conf; do
      [ -e "$c" ] || continue
      cname="$(basename "$c" .conf)"
      grep -qE '^TOOL_CALL_PARSER=.+' "$c" || notools+=("$cname")
      grep -qE '^KEEP_WARM=1' "$c" && nokeepwarm=0
    done
    if [ "${#notools[@]}" -eq 0 ]; then
      pass "every catalogued model has a tool-call parser (function calling works)"
    else
      warnc "no tool-call parser set for: ${notools[*]}"
      info "those models cannot emit tool_calls, so agentic editor clients will do nothing"
      info "list the names this build accepts: sudo llm-model parsers"
      info "then: sudo llm-model remove <name> and re-add with --tool-parser <name>"
    fi
    if [ "$nokeepwarm" = "1" ]; then
      info "no model is marked keep-warm; every idle model is reaped after ${RESIDENCY_IDLE_TIMEOUT:-1800}s"
      info "for an editor-facing model: re-add it with --keep-warm to avoid cold starts"
    fi
  else
    warnc "the catalog is empty - nothing can be served yet"
    info "add one with: sudo llm-model add --name X --path $LLM_ROOT/X"
    info "or let this script seed and register models for you (drop --verify-only)"
  fi
  # Checked here rather than only in the seeding pass, so --verify-only tells you
  # the box cannot download models BEFORE you go looking for a network problem.
  if detect_hf; then
    pass "Hugging Face CLI present ($HF_BIN)"
  else
    fail "no Hugging Face CLI in $HF_TOOLS_VENV - this node cannot seed models"
    info "sudo python3 -m venv $HF_TOOLS_VENV && sudo $HF_TOOLS_VENV/bin/pip install 'huggingface_hub[cli,hf_transfer]'"
  fi

  # --------------------------------------------------------- residency -----
  if [ "$INSTALL_RESIDENCY" = "1" ]; then
    section "Residency control plane"
    if [ "$IS_SERVER" = "1" ]; then
      svc_check residencyd.service "residencyd"
      if [ -S "$RESIDENCY_SOCK" ]; then
        pass "control socket $RESIDENCY_SOCK present"
        if [ "$IS_ROOT" = "1" ]; then
          local h; h="$(uds_get "$RESIDENCY_SOCK" /health)"
          if [ -n "$h" ]; then pass "residencyd /health answers"; info "$h"
          else fail "residencyd is not answering on its socket"; fi
        else
          skip "residencyd /health probe (needs root to open the socket)"
        fi
      else
        fail "$RESIDENCY_SOCK does not exist - the gateway has nothing to talk to"
      fi
    else
      svc_check residency-agent.service "residency agent" "$AGENT_PORT"
      if http_ok "http://${CLUSTER_LOCAL_IP}:${AGENT_PORT}/health" 5; then
        pass "residency agent answers on ${CLUSTER_LOCAL_IP}:${AGENT_PORT}"
      else
        fail "residency agent is not answering - the head node cannot place models here"
      fi
      if http_ok "http://127.0.0.1:${AGENT_PORT}/health" 3; then
        warnc "the agent is also reachable on loopback; it should bind ONLY $CLUSTER_LOCAL_IP"
      fi
    fi
  fi

  # ----------------------------------------------------------- gateway -----
  if [ "$INSTALL_GATEWAY" = "1" ] && [ "$IS_SERVER" = "1" ]; then
    section "llm-gateway"
    svc_check llm-gateway.service "gateway" "$GATEWAY_PORT" "http://127.0.0.1:${GATEWAY_PORT}/health"
    venv_user_check llm-gateway.service "gateway" "$GATEWAY_VENV" "$GATEWAY_USER"
    local models; models="$(http_get "http://127.0.0.1:${GATEWAY_PORT}/v1/models" 15)"
    if [ -n "$models" ]; then
      local n; n="$(grep -o '"id"' <<<"$models" | wc -l)"
      pass "/v1/models lists $n model(s)"
      info "point every client at: http://${MY_HOST}:${GATEWAY_PORT}/v1"
    else
      warnc "/v1/models returned nothing yet"
    fi
  elif [ "$INSTALL_GATEWAY" = "1" ]; then
    section "llm-gateway"
    if http_ok "http://${CLUSTER_PEER_IP}:${GATEWAY_PORT}/health" 8; then
      pass "the gateway on $SERVER_HOST answers over the cluster link"
    else
      warnc "no answer from the gateway on $SERVER_HOST ($CLUSTER_PEER_IP:$GATEWAY_PORT)"
      info "that is served by the head node; verify it there"
    fi
  fi

  # ---------------------------------------------------------- Open WebUI ---
  if [ "$INSTALL_WEBUI" = "1" ] && [ "$IS_SERVER" = "1" ]; then
    section "Open WebUI"
    svc_check open-webui.service "Open WebUI" "$WEBUI_PORT" "http://127.0.0.1:${WEBUI_PORT}/health"
    venv_user_check open-webui.service "Open WebUI" "$WEBUI_VENV" openwebui
    info "browse to http://${MY_HOST}:${WEBUI_PORT}/ (first account registered becomes admin)"
  fi

  # ------------------------------------------------------------ ComfyUI ----
  if [ "$INSTALL_COMFYUI" = "1" ]; then
    section "ComfyUI (this node)"
    # On the peer the store is an NFS automount that only exists once the USB4
    # link is up. A hard RequiresMountsFor= there turns a slow link into a
    # PERMANENT failure: systemd reports "Dependency failed", and a dependency
    # failure does not trigger Restart=on-failure, so the service never retries.
    if [ "$IS_PEER" = "1" ] && [ -f /etc/systemd/system/comfyui.service ]; then
      if grep -q '^RequiresMountsFor=' /etc/systemd/system/comfyui.service; then
        fail "comfyui.service hard-requires the $COMFY_ROOT mount"
        info "if the link is slow at boot it fails once and never retries; re-run setup"
      elif [ -x /usr/local/bin/comfy-store-wait ]; then
        pass "ComfyUI waits for the shared store instead of hard-requiring it"
      else
        warnc "/usr/local/bin/comfy-store-wait is missing - ComfyUI may start before $COMFY_ROOT"
      fi
    fi
    svc_check comfyui.service "ComfyUI" "$COMFYUI_PORT" "http://127.0.0.1:${COMFYUI_PORT}/system_stats"
    local linked=0 total=0
    for d in models input output; do
      total=$((total+1))
      if [ -L "$COMFY_DIR/$d" ] && [ "$(readlink -f "$COMFY_DIR/$d")" = "$(readlink -f "$COMFY_ROOT/$d")" ]; then
        linked=$((linked+1))
      fi
    done
    if [ "$linked" = "$total" ]; then
      pass "models/, input/ and output/ all point at the shared store $COMFY_ROOT"
      info "a model downloaded here is immediately usable on $OTHER_HOST"
    else
      fail "only $linked/$total ComfyUI directories are linked to $COMFY_ROOT"
      info "downloads will land on local disk and NOT be shared; re-run setup"
    fi
    if [ -L "$COMFY_DIR/user/default/workflows" ]; then
      pass "workflows are shared with $OTHER_HOST"
    else
      warnc "user/default/workflows is not linked to $COMFY_ROOT/workflows"
    fi
    if [ -d "$COMFY_DIR/user" ] && [ ! -L "$COMFY_DIR/user" ]; then
      pass "user/ is local to this node (correct: settings must not be shared)"
    fi

    # ComfyUI is not alone on this machine: its cache and vLLM's weights are
    # the same physical memory, because the GPU's VRAM is carved out of system
    # RAM. Upstream's default cache ceiling is the whole box.
    local unit_exec=""
    unit_exec="$(systemctl cat comfyui.service 2>/dev/null | grep -e '^ *--listen' -e '^ExecStart' | tr '\n' ' ')"
    if [ -z "$unit_exec" ]; then
      warnc "could not read comfyui.service to check its launch flags"
    else
      case "$COMFY_CACHE_MODE" in
        ram)
          if grep -e '--cache-ram' <<<"$unit_exec" >/dev/null; then
            pass "ComfyUI cache is bounded ($(grep -oE -e '--cache-ram [0-9.]+ [0-9.]+' <<<"$unit_exec"))"
          else
            warnc "ComfyUI has no --cache-ram bound; its cache can grow into the memory vLLM is using"
            info "re-run setup, or add --cache-ram <active> <inactive> to comfyui.service"
          fi ;;
        classic|lru|none)
          if grep -e "--cache-$COMFY_CACHE_MODE" <<<"$unit_exec" >/dev/null; then
            pass "ComfyUI cache mode is $COMFY_CACHE_MODE as configured"
          else
            warnc "ComfyUI is not running with --cache-$COMFY_CACHE_MODE"
          fi ;;
      esac
      if [ "${COMFY_RESERVE_VRAM%%.*}" != "0" ]; then
        if grep -e '--reserve-vram' <<<"$unit_exec" >/dev/null; then
          pass "ComfyUI reserves ${COMFY_RESERVE_VRAM} GiB of GPU memory for vLLM and the OS"
        else
          warnc "ComfyUI is not reserving GPU memory; it may starve vLLM on this shared box"
        fi
      fi
      if [ "$COMFY_ENABLE_ASSETS" != "1" ]; then
        if grep -e '--enable-assets' <<<"$unit_exec" >/dev/null; then
          warnc "the ComfyUI asset scanner is enabled; it walks $COMFY_ROOT continuously from BOTH nodes"
        else
          pass "ComfyUI asset scanning is off (the model store is NFS-shared)"
        fi
      fi
    fi
  fi

  # --------------------------------------------------------------- XRDP ----
  if [ "$INSTALL_XRDP" = "1" ]; then
    section "Remote desktop (XRDP)"
    svc_check xrdp.service "xrdp" "$XRDP_PORT"
    systemctl is-active --quiet xrdp-sesman.service \
      && pass "xrdp-sesman active" || fail "xrdp-sesman is not active - sessions will not start"
    if [ -f /etc/X11/Xwrapper.config ] && grep 'allowed_users=anybody' /etc/X11/Xwrapper.config >/dev/null; then
      pass "Xwrapper allows non-console users to start an X server"
    else
      fail "/etc/X11/Xwrapper.config does not allow non-console X - RDP will connect then drop"
    fi

    # The desktop is overhead on a box whose GPU is the product: every
    # compositing session holds GTT memory that vLLM and ComfyUI allocate from.
    if [ -x /usr/bin/xfce4-session ]; then
      pass "XFCE is installed"
    else
      fail "xfce4-session is missing - RDP has no session to start"
    fi
    local sm; sm="$(readlink -f /etc/alternatives/x-session-manager 2>/dev/null || true)"
    case "$sm" in
      */xfce4-session) pass "x-session-manager points at XFCE" ;;
      "")              warnc "x-session-manager alternative is not set" ;;
      *)               warnc "x-session-manager is $sm, not XFCE" ;;
    esac
    if [ -f "$USER_HOME/.xsession" ] && grep 'startxfce4' "$USER_HOME/.xsession" >/dev/null 2>&1; then
      pass "$TARGET_USER's RDP session launches XFCE"
    else
      warnc "$USER_HOME/.xsession does not launch XFCE"
    fi
    if [ "$XFCE_COMPOSITING" != "1" ]; then
      if grep 'use_compositing' /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml 2>/dev/null \
           | grep 'false' >/dev/null; then
        pass "XFCE compositing is off by default (the desktop is not a GL client)"
      else
        warnc "no system default disabling XFCE compositing - the desktop will use the iGPU"
      fi
    fi
    local deftgt; deftgt="$(systemctl get-default 2>/dev/null || echo unknown)"
    if [ "$DESKTOP_HEADLESS_BOOT" = "1" ]; then
      if [ "$deftgt" = "multi-user.target" ]; then
        pass "boots to multi-user.target - nothing holds the iGPU when nobody is connected"
      else
        fail "default boot target is $deftgt; a desktop will run on the console and hold GPU memory"
        info "fix: sudo systemctl set-default multi-user.target (takes effect next boot)"
      fi
      if systemctl is-active --quiet display-manager.service 2>/dev/null; then
        warnc "a display manager is still running from before the last reboot"
        info "it will not start again after a reboot"
      else
        pass "no display manager is running"
      fi
    else
      # graphical.target only means "start display-manager.service". If nothing
      # is installed under that name the box boots to the same text login as
      # multi-user.target, which is the failure this check exists to catch.
      local dmu=""
      [ -L /etc/systemd/system/display-manager.service ] \
        && dmu="$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" 2>/dev/null)"
      if [ -z "$dmu" ]; then
        fail "no display manager is installed - the console boots to a text login, not a desktop"
        info "fix: sudo apt-get install -y lightdm lightdm-gtk-greeter"
      else
        pass "display manager installed: ${dmu%.service}"
        # Do NOT ask 'is-enabled gdm.service'. On Debian/Ubuntu a display
        # manager is not enabled the usual way: the package points
        # /etc/systemd/system/display-manager.service at its unit, and upstream
        # graphical.target carries Wants=display-manager.service. gdm's only
        # [Install] directive is Alias=, so is-enabled reports it as not
        # enabled while it starts perfectly well - a false FAIL.
        case "$(systemctl is-enabled display-manager.service 2>/dev/null || echo unknown)" in
          masked|masked-runtime)
            fail "display-manager.service is masked - the console will boot to a text login"
            info "fix: sudo systemctl unmask display-manager.service" ;;
          *)
            pass "${dmu%.service} starts at boot (graphical.target wants display-manager.service)" ;;
        esac
      fi
      if [ "$deftgt" = "graphical.target" ]; then
        pass "boots to graphical.target - the console shows the desktop login"
      else
        fail "default boot target is $deftgt; the console will boot to a text login"
        info "fix: sudo systemctl set-default graphical.target (takes effect next boot)"
      fi
      # LightDM otherwise starts whichever session sorts first, which on a box
      # that also has GNOME installed is not XFCE.
      if [ "$dmu" = "lightdm.service" ] && [ "$XRDP_DESKTOP" = "xfce" ]; then
        # Braces + '|| true': grep exits 2 when one of the named paths does not
        # exist, and under 'set -o pipefail' that status would sink the whole
        # pipeline even though the other path matched.
        if { grep -rhE '^[[:space:]]*user-session[[:space:]]*=' \
               /etc/lightdm 2>/dev/null || true; } \
             | grep -iE 'xfce|xubuntu' >/dev/null; then
          pass "lightdm is set to log into the XFCE session"
        else
          warnc "lightdm has no XFCE 'user-session' default - the console may start another desktop"
          info "fix: re-run the setup script, or set user-session=xfce in /etc/lightdm/lightdm.conf.d/"
        fi
      elif [ -n "$dmu" ] && [ "$XRDP_DESKTOP" = "xfce" ]; then
        # GDM and friends read the per-user AccountsService record instead of a
        # global default. On a box that also has GNOME, this file is the only
        # thing standing between a console login and gnome-shell holding GTT.
        if grep -iE '^X?Session=.*(xfce|xubuntu)' \
             "/var/lib/AccountsService/users/$TARGET_USER" >/dev/null 2>&1; then
          pass "$TARGET_USER's console session is XFCE (AccountsService)"
        else
          warnc "${dmu%.service} has no XFCE default for $TARGET_USER - the console may start GNOME"
          info "gnome-shell is a compositing GL client and holds memory vLLM needs"
          info "fix: re-run setup, or pick XFCE from the gear menu at the login screen"
        fi
      fi
    fi
    if systemctl is-active --quiet gnome-shell.service 2>/dev/null \
       || pgrep -x gnome-shell >/dev/null 2>&1; then
      warnc "gnome-shell is running; it holds GTT memory that vLLM and ComfyUI need"
    fi
  fi

  # ------------------------------------------------- Windows file share ----
  if [ "$INSTALL_SAMBA" = "1" ]; then
    section "Windows file share (\\\\${MY_HOST}\\${XFER_SHARE})"
    if ! command -v smbd >/dev/null 2>&1 && [ ! -x /usr/sbin/smbd ]; then
      fail "samba is not installed - there is no way to push files from Windows to this box"
    else
      svc_check smbd.service "smbd" 445
      if systemctl is-active --quiet nmbd.service 2>/dev/null; then
        pass "nmbd active (\\\\${MY_HOST} resolves without a DNS entry)"
      else
        warnc "nmbd is not active - use the IP address rather than \\\\${MY_HOST}"
        # nmbd fails for a small number of specific reasons (no broadcast-capable
        # interface, a conflicting 'interfaces =' line, a masked unit). Printing
        # the reason here saves a round trip: the warning above is otherwise
        # identical whatever went wrong.
        { systemctl status nmbd.service --no-pager -n 6 2>&1 || true; } \
          | sed 's/^/         | /' | head -8 || true
      fi

      if [ -d "$XFER_ROOT" ]; then
        local xmode xown
        xmode="$(stat -c '%a' "$XFER_ROOT" 2>/dev/null)"
        xown="$(stat -c '%U:%G' "$XFER_ROOT" 2>/dev/null)"
        pass "$XFER_ROOT exists (mode $xmode, owner $xown)"
        # Without setgid, files copied in from Windows do not inherit the share
        # group and the services on this box cannot read what was just dropped.
        case "$xmode" in
          2*) pass "$XFER_ROOT is setgid - files keep the share group" ;;
          *)  warnc "$XFER_ROOT is not setgid (mode $xmode); dropped files may not be group-readable" ;;
        esac
      else
        fail "$XFER_ROOT does not exist"
      fi

      if [ "$IS_ROOT" = "1" ] && command -v testparm >/dev/null 2>&1; then
        local tp; tp="$(testparm -s 2>/dev/null || true)"
        if grep -E "^\[${XFER_SHARE}\]" <<<"$tp" >/dev/null; then
          pass "samba is serving the [$XFER_SHARE] share"
        else
          fail "[$XFER_SHARE] is not in the running samba config - re-run the setup script"
        fi
        # SMB1 is not merely old: Windows 10/11 do not install it, so a share
        # that only speaks SMB1 cannot be opened from a stock Windows client.
        grep -E 'server min protocol *= *SMB[23]' <<<"$tp" >/dev/null \
          && pass "SMB1 is refused (Windows 10/11 cannot speak it anyway)" \
          || warnc "no 'server min protocol = SMB2' - SMB1 may still be offered"
        grep -E 'guest ok *= *[Yy]es' <<<"$tp" >/dev/null \
          && pass "the share is open - no sign-in needed from Windows" \
          || warnc "the share is not marked 'guest ok' - Windows will ask for credentials"
      elif [ "$IS_ROOT" != "1" ]; then
        skip "samba config inspection (needs root)"
      fi

      # The only test that matters: can it actually be opened anonymously?
      if command -v smbclient >/dev/null 2>&1; then
        if smbclient "//127.0.0.1/${XFER_SHARE}" -N -c 'ls' >/dev/null 2>&1; then
          pass "//127.0.0.1/$XFER_SHARE opens anonymously and lists"
        else
          fail "$XFER_SHARE cannot be opened locally - it will not open from Windows either"
          info "check: sudo smbclient //127.0.0.1/$XFER_SHARE -N"
        fi
      fi

      if systemctl is-active --quiet wsdd.service 2>/dev/null; then
        pass "wsdd running - this node appears under 'Network' in Windows Explorer"
      else
        info "wsdd is not running: browse to \\\\${MY_HOST}\\${XFER_SHARE} directly"
      fi
      info "from Windows: open Explorer and type  \\\\${MY_HOST}\\${XFER_SHARE}"
    fi
  fi

  # ----------------------------------------------------------- firewall ----
  if [ "$CONFIGURE_FIREWALL" = "1" ]; then
    section "Firewall"
    if ! command -v ufw >/dev/null 2>&1; then
      warnc "ufw is not installed"
    elif [ "$IS_ROOT" != "1" ]; then
      skip "ufw rule inspection (needs root)"
    else
      local fw; fw="$(ufw status verbose 2>/dev/null)"
      if grep '^Status: active' <<<"$fw" >/dev/null; then
        pass "ufw is active"
        grep 'deny (incoming)' <<<"$fw" >/dev/null \
          && pass "default incoming policy is deny" \
          || fail "default incoming policy is NOT deny - the allow rules restrict nothing"
        local want="on ${CLUSTER_IFACE}[[:space:]]+ALLOW IN[[:space:]]+${CLUSTER_PEER_IP//./\\.}"
        grep -E "$want" <<<"$fw" >/dev/null \
          && pass "the cluster peer is allowed in on $CLUSTER_IFACE only" \
          || fail "no rule allowing $CLUSTER_PEER_IP in on $CLUSTER_IFACE - NFS/Ray/vLLM will be blocked"
        local p
        for p in $COMFYUI_PORT $XRDP_PORT; do
          grep -E "(^|[[:space:]])${p}/tcp[[:space:]]+ALLOW IN" <<<"$fw" >/dev/null \
            && pass "port $p reachable from the LAN" \
            || warnc "no LAN allow rule for port $p"
        done
        if [ "$INSTALL_SAMBA" = "1" ]; then
          grep -E "(^|[[:space:]])445/tcp[[:space:]]+ALLOW IN" <<<"$fw" >/dev/null \
            && pass "SMB (445/tcp) reachable from the LAN" \
            || fail "no LAN allow rule for 445/tcp - the '$XFER_SHARE' share is unreachable from Windows"
          grep -E "(^|[[:space:]])137/udp[[:space:]]+ALLOW IN" <<<"$fw" >/dev/null \
            && pass "NetBIOS name lookups (137/udp) allowed" \
            || warnc "no rule for 137/udp - \\\\${MY_HOST} may not resolve; use the IP instead"
          grep -E "(^|[[:space:]])445/tcp[[:space:]]+ALLOW IN[[:space:]]+Anywhere" <<<"$fw" >/dev/null \
            && fail "SMB is open to Anywhere, not just the LAN - restrict it before this box is routable"
        fi
        if [ "$IS_SERVER" = "1" ]; then
          for p in $GATEWAY_PORT $WEBUI_PORT; do
            grep -E "(^|[[:space:]])${p}/tcp[[:space:]]+ALLOW IN" <<<"$fw" >/dev/null \
              && pass "port $p reachable from the LAN" \
              || warnc "no LAN allow rule for port $p"
          done
        fi
        for p in $RAY_PORT $AGENT_PORT; do
          if grep -E "(^|[[:space:]])${p}/tcp[[:space:]]+ALLOW IN[[:space:]]+Anywhere" <<<"$fw" >/dev/null; then
            fail "port $p is open to the whole LAN - it is UNAUTHENTICATED and must stay on the cable"
          fi
        done
      else
        fail "ufw is NOT active - every port on this box is exposed"
      fi
    fi
  fi

  # ------------------------------------------- maintenance / hardening ----
  section "Unattended maintenance and hardening"

  if [ "$CONFIGURE_UPDATES" != "1" ]; then
    skip "unattended security updates - setup was run with --skip updates"
  elif ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    fail "unattended-upgrades is not installed - this node never gets security patches"
  else
    pass "unattended-upgrades installed"
    local uu_reboot uu_bl uu_period h miss=""
    uu_reboot="$(apt-config dump --format '%v%n' Unattended-Upgrade::Automatic-Reboot 2>/dev/null | head -n1)"
    if [ "$uu_reboot" = "false" ]; then
      pass "automatic reboot is disabled"
    else
      fail "Unattended-Upgrade::Automatic-Reboot is '${uu_reboot:-unset}' - this node can reboot mid-inference"
    fi
    # Read back what apt itself resolved. Anything else in /etc/apt/apt.conf.d
    # can append to these lists, so the file we wrote is not proof on its own.
    uu_bl="$(apt-config dump Unattended-Upgrade::Package-Blacklist 2>/dev/null || true)"
    for h in $UNATTENDED_HOLD; do
      grep -F "\"$h\"" <<<"$uu_bl" >/dev/null || miss="$miss $h"
    done
    if [ -z "$miss" ]; then
      pass "held back from unattended upgrades: $(echo "$UNATTENDED_HOLD" | tr ' ' ',')"
    else
      fail "NOT held back:$miss - an unattended bump of these silently breaks gfx1151"
    fi
    uu_period="$(apt-config dump --format '%v%n' APT::Periodic::Unattended-Upgrade 2>/dev/null | head -n1)"
    if [ "${uu_period:-0}" != "0" ] && [ -n "${uu_period:-}" ]; then
      pass "APT::Periodic::Unattended-Upgrade = $uu_period"
    else
      fail "APT::Periodic::Unattended-Upgrade is 0/unset - the policy exists but never runs"
    fi
    local t
    for t in apt-daily.timer apt-daily-upgrade.timer; do
      if systemctl is-enabled "$t" >/dev/null 2>&1; then pass "$t enabled"
      else warnc "$t is not enabled"; fi
    done
    if [ -f /var/run/reboot-required ]; then
      warnc "a reboot is pending on this node (expected: nothing reboots itself)"
      info "packages: $(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null || echo '?')"
    fi
  fi

  if [ "$CONFIGURE_JOURNAL" != "1" ]; then
    skip "journald size cap - setup was run with --skip journal"
  else
    local jr_conf="/etc/systemd/journald.conf.d/10-llm-cluster.conf" jr_max jr_use rootpct
    if [ -f "$jr_conf" ]; then
      jr_max="$(awk -F= '/^SystemMaxUse=/{print $2; exit}' "$jr_conf" 2>/dev/null)"
      pass "journald cap in place${jr_max:+ (SystemMaxUse=$jr_max)}"
    else
      fail "$jr_conf is missing - the journal can grow until / is full"
    fi
    jr_use="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?[KMGTP]' | head -n1 || true)"
    [ -n "$jr_use" ] && info "journal currently uses ${jr_use}B"
    rootpct="$(df --output=pcent / 2>/dev/null | tail -n1 | tr -dc '0-9')"
    if [ -n "$rootpct" ]; then
      if [ "$rootpct" -lt 85 ]; then pass "root filesystem ${rootpct}% used"
      else warnc "root filesystem is ${rootpct}% used - investigate before it fills"; fi
    fi
  fi

  if [ "$CONFIGURE_DISK_HEALTH" != "1" ]; then
    skip "SMART monitoring and TRIM - setup was run with --skip diskhealth"
  else
    local sm_unit="" u
    for u in smartd.service smartmontools.service; do
      if systemctl cat "$u" >/dev/null 2>&1; then sm_unit="$u"; break; fi
    done
    if [ -z "$sm_unit" ]; then
      fail "smartmontools is not installed - a dying NVMe would go unnoticed"
    elif systemctl is-active --quiet "$sm_unit"; then
      pass "$sm_unit active"
    else
      fail "$sm_unit is not running - nothing is watching the drives"
    fi
    if systemctl is-enabled fstrim.timer >/dev/null 2>&1; then
      pass "fstrim.timer enabled"
    else
      warnc "fstrim.timer is not enabled - SSD write performance decays over time"
    fi
    if [ "$IS_ROOT" != "1" ]; then
      skip "per-drive SMART read-out (needs root)"
    elif command -v smartctl >/dev/null 2>&1; then
      local d out used temp dn dtran drm
      # NAME/TYPE alone is not enough: a USB stick is TYPE=disk too, and SMART
      # is not exposed through most USB bridges. Reporting the boot stick as a
      # dying drive every single run trains the operator to ignore this section.
      # Queried per-device rather than as extra lsblk columns, because an empty
      # TRAN silently shifts the remaining fields.
      for dn in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
        d="/dev/$dn"
        dtran="$(lsblk -dno TRAN "$d" 2>/dev/null | tr -d '[:space:]')"
        drm="$(cat "/sys/block/$dn/removable" 2>/dev/null || echo 0)"
        if [ "$dtran" = "usb" ] || [ "$drm" = "1" ]; then
          info "$d is removable/USB - skipped (SMART is not exposed through USB bridges)"
          continue
        fi
        out="$(smartctl -H -A "$d" 2>/dev/null || true)"
        [ -n "$out" ] || continue
        if grep -Ei 'overall-health.*PASSED|SMART Health Status: *OK' <<<"$out" >/dev/null; then
          used="$(awk -F: '/Percentage Used/{gsub(/[^0-9]/,"",$2); print $2; exit}' <<<"$out")"
          temp="$(awk -F: '/^Temperature:/{gsub(/[^0-9]/,"",$2); print $2; exit}' <<<"$out")"
          if [[ "$used" =~ ^[0-9]+$ ]] && [ "$used" -ge 80 ]; then
            warnc "$d is healthy but ${used}% of its rated write endurance is used"
          else
            pass "$d SMART healthy${used:+ (${used}% endurance used)}${temp:+, ${temp} C}"
          fi
        elif grep -Ei 'lacks SMART capability|SMART support is:( +)?Unavailable|Unknown USB bridge|Operation not supported|please specify device type' <<<"$out" >/dev/null; then
          # "cannot be read" is not the same as "reads unhealthy".
          info "$d does not expose SMART - not checked"
        else
          fail "$d does not report a healthy SMART status - run: sudo smartctl -a $d"
        fi
      done
    fi
  fi

  if [ "$DISABLE_WIFI" != "1" ] && [ "$DISABLE_BLUETOOTH" != "1" ]; then
    skip "Wi-Fi/Bluetooth lockout - not requested on this node"
  else
    local rconf="/etc/modprobe.d/llm-cluster-radios.conf" n wif="" m
    if [ -f "$rconf" ]; then
      pass "$rconf present"
    else
      fail "$rconf is missing - the radios return on the next boot"
    fi
    if [ "$DISABLE_WIFI" = "1" ]; then
      for n in /sys/class/net/*; do
        [ -e "$n/phy80211" ] && wif="$wif $(basename "$n")"
      done
      if [ -z "$wif" ]; then pass "no 802.11 interface is present"
      else fail "Wi-Fi interface(s) still present:$wif"; fi
      for m in cfg80211 mac80211; do
        if lsmod 2>/dev/null | awk '{print $1}' | grep -x "$m" >/dev/null; then
          fail "module '$m' is still loaded - reboot to complete the lockout"
        else
          pass "module '$m' is not loaded"
        fi
      done
    fi
    if [ "$DISABLE_BLUETOOTH" = "1" ]; then
      if compgen -G "/sys/class/bluetooth/hci*" >/dev/null 2>&1; then
        fail "a Bluetooth controller is still registered - reboot to complete the lockout"
      else
        pass "no Bluetooth controller is present"
      fi
      if systemctl is-active --quiet bluetooth.service; then
        fail "bluetooth.service is running"
      else
        pass "bluetooth.service is not running"
      fi
    fi
  fi

  # -------------------------------------------------------- end-to-end -----
  if [ "$IS_SERVER" = "1" ] && [ "$INSTALL_GATEWAY" = "1" ] && [ "${ncat:-0}" -gt 0 ]; then
    section "End-to-end"
    info "the real test is a completion. Pick a model from the catalog and run:"
    info "  curl -s http://127.0.0.1:${GATEWAY_PORT}/v1/chat/completions \\"
    info "    -H 'Content-Type: application/json' \\"
    info "    -d '{\"model\":\"<name>\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
    info "The FIRST call to a cold model can take minutes; a 409 means it does not fit."
  fi
}

# =============================================================================
# SEED
# =============================================================================
# Model list format (whitespace separated, '#' comments):
#   llm    <repo_id>  [dir-name]  [server|peer|distributed]  [tools=P] [reason=P]
#                                                            [maxlen=N] [keepwarm]
#   comfy  <repo_id>  <path/in/repo>  <models-subdir>
LLM_MODELS=( ); COMFY_MODELS=( )

# Files that are duplicate formats of the same weights. Downloading them wastes
# tens of GB and vLLM never looks at them.
HF_EXCLUDES=( --exclude "original/*" --exclude "metal/*" --exclude "consolidated*"
              --exclude "*.gguf" --exclude "*.pth" --exclude "*.msgpack"
              --exclude "*.h5" --exclude "*.onnx" )

HF_BIN=""
detect_hf() {
  local c
  for c in "$HF_TOOLS_VENV/bin/hf" "$HF_TOOLS_VENV/bin/huggingface-cli"; do
    [ -x "$c" ] && { HF_BIN="$c"; return 0; }
  done
  for c in hf huggingface-cli; do
    command -v "$c" >/dev/null 2>&1 && { HF_BIN="$(command -v "$c")"; return 0; }
  done
  return 1
}

USE_HF_TRANSFER=1
hf_run() {   # hf_run <HF_HOME> <args...>
  local home="$1"; shift
  local extra=(HF_HUB_ENABLE_HF_TRANSFER=0)
  if [ "$USE_HF_TRANSFER" = "1" ] && [ -x "$HF_TOOLS_VENV/bin/python" ] \
     && "$HF_TOOLS_VENV/bin/python" -c 'import hf_transfer' >/dev/null 2>&1; then
    extra=(HF_HUB_ENABLE_HF_TRANSFER=1)
  fi
  env HF_HOME="$home" "${extra[@]}" "$HF_BIN" "$@"
}

seed_llm() {   # $1 repo $2 dir-name $3 placement $4 tool-parser $5 reasoning-parser $6 max-len $7 keep-warm
  local repo="$1" name="$2" placement="${3:-server}" dest out rc
  local tparser="${4:-}" rparser="${5:-}" maxlen="${6:-}" keepwarm="${7:-0}"
  dest="$LLM_ROOT/$name"
  printf '  %s->%s LLM  %s  ->  %s\n' "$BLU" "$RST" "$repo" "$dest"
  if [ -f "$dest/config.json" ] && ls "$dest"/*.safetensors >/dev/null 2>&1; then
    pass "already present: $dest"
  else
    install -d -m 2775 -o "$LLM_USER" -g "$SHARE_GROUP" "$dest" 2>/dev/null || mkdir -p "$dest"
    out="$(hf_run "$LLM_ROOT" download "$repo" --local-dir "$dest" "${HF_EXCLUDES[@]}" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && [ "$USE_HF_TRANSFER" = "1" ]; then
      warnc "download failed; retrying without hf_transfer (disabled for the rest of this run)"
      USE_HF_TRANSFER=0
      out="$(hf_run "$LLM_ROOT" download "$repo" --local-dir "$dest" "${HF_EXCLUDES[@]}" 2>&1)"; rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      fail "download failed for $repo"
      printf '%s\n' "$out" | tail -n3 | sed 's/^/         | /'
      return 0
    fi
    chown -R "$LLM_USER:$SHARE_GROUP" "$dest" 2>/dev/null || true
    pass "downloaded $repo ($(du -sh "$dest" 2>/dev/null | cut -f1))"
  fi
  if [ "$DO_REGISTER" = "1" ] && [ -x /usr/local/bin/llm-model ]; then
    if [ -e "$LLM_ETC/models.d/$name.conf" ]; then
      info "already in the catalog as '$name'"
    else
      # --tool-parser is what turns on OpenAI-style function calling, which
      # every agentic IDE client needs. --keep-warm exempts the model from
      # idle eviction. Both are optional columns in the model list.
      local -a addargs=( --name "$name" --path "$dest" --placement "$placement" )
      if [ -n "$tparser" ]; then addargs+=( --tool-parser "$tparser" ); fi
      if [ -n "$rparser" ]; then addargs+=( --reasoning-parser "$rparser" ); fi
      if [ -n "$maxlen" ];  then addargs+=( --max-len "$maxlen" ); fi
      if [ "$keepwarm" = "1" ]; then addargs+=( --keep-warm ); fi
      if out="$(/usr/local/bin/llm-model add "${addargs[@]}" 2>&1)"; then
        pass "registered '$name' (placement=$placement${tparser:+ tools=$tparser}${maxlen:+ maxlen=$maxlen}$([ "$keepwarm" = 1 ] && echo ' keep-warm'))"
      else
        warnc "could not register '$name' automatically"
        printf '%s\n' "$out" | tail -n3 | sed 's/^/         | /'
        info "add it by hand: sudo llm-model add ${addargs[*]}"
      fi
    fi
  fi
}

seed_comfy() { # $1 repo  $2 path-in-repo  $3 subdir
  local repo="$1" file="$2" subdir="${3:-checkpoints}" dest base src top out rc
  dest="$COMFY_ROOT/models/$subdir"
  base="$(basename "$file")"
  printf '  %s->%s ComfyUI  %s  ->  models/%s/%s\n' "$BLU" "$RST" "$repo/$file" "$subdir" "$base"
  run_user mkdir -p "$dest" 2>/dev/null || mkdir -p "$dest"
  # Idempotent AND cross-family dedup: several model families ship the identical
  # file under the same basename (the FLUX VAE, the Wan umt5 encoder, CLIP-L).
  if [ -f "$dest/$base" ]; then pass "already present: models/$subdir/$base"; return 0; fi
  out="$(run_user env "$HF_BIN" download "$repo" "$file" --local-dir "$dest" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "download failed for $repo/$file"
    printf '%s\n' "$out" | tail -n2 | sed 's/^/         | /'
    return 0
  fi
  # Comfy-Org repos nest files under 'split_files/...' and hf preserves that
  # path. Flatten so ComfyUI sees models/<subdir>/<basename>.
  src="$dest/$file"
  if [ "$file" != "$base" ] && [ -f "$src" ]; then
    run_user mv -f "$src" "$dest/$base" 2>/dev/null || mv -f "$src" "$dest/$base"
    top="${file%%/*}"
    if [ -n "$top" ] && [ "$top" != "$base" ]; then rm -rf "${dest:?}/$top"; fi
  fi
  pass "downloaded into models/$subdir/$base"
}

seed() {
  section "Seeding models into the shared stores"
  if ! detect_hf; then
    fail "the Hugging Face CLI was not found (expected in $HF_TOOLS_VENV)"
    info "setup installs it; if that step failed, build it by hand with:"
    info "  sudo python3 -m venv $HF_TOOLS_VENV"
    info "  sudo $HF_TOOLS_VENV/bin/pip install 'huggingface_hub[cli,hf_transfer]'"
    return 0
  fi

  if [ -n "${MODELS_FILE:-}" ] && [ -f "$MODELS_FILE" ]; then
    info "reading $MODELS_FILE"
    local type a b c _rest
    while IFS=$' \t\r' read -r type a b c _rest; do
      [ -z "${type:-}" ] && continue
      case "$type" in
        \#*) continue ;;
        llm|LLM)
          [ -n "${a:-}" ] || continue
          local nm="${b:-}"; [ -n "$nm" ] && [ "${nm:0:1}" != "#" ] || nm="$(basename "$a")"
          local pl="${c:-server}"; [ "${pl:0:1}" = "#" ] && pl="server"
          # Everything after the placement column is optional key=value tuning,
          # so old three-column rows keep working untouched.
          local tp="" rp="" ml="" kw=0 opt
          for opt in ${_rest:-}; do
            case "$opt" in
              \#*)      break ;;
              tools=*)  tp="${opt#tools=}" ;;
              reason=*) rp="${opt#reason=}" ;;
              maxlen=*) ml="${opt#maxlen=}" ;;
              keepwarm) kw=1 ;;
              *) warnc "unknown option '$opt' on the llm row for $a (ignored)" ;;
            esac
          done
          LLM_MODELS+=("$a|$nm|$pl|$tp|$rp|$ml|$kw") ;;
        comfy|COMFY)
          [ -n "${a:-}" ] && [ -n "${b:-}" ] && COMFY_MODELS+=("$a|$b|${c:-checkpoints}") ;;
        *) warnc "unknown row type '$type' in $MODELS_FILE (skipped)" ;;
      esac
    done < "$MODELS_FILE"
  else
    warnc "no model list at $MODELS_FILE"
  fi

  local n_llm=${#LLM_MODELS[@]} n_comfy=${#COMFY_MODELS[@]}
  if [ "$n_llm" -eq 0 ] && [ "$n_comfy" -eq 0 ]; then
    warnc "no models configured."
    info "run '$(basename "$0") --write-example-models' to scaffold a list, then edit it."
    return 0
  fi

  # /srv/models is exported read-only, on purpose. Downloading LLMs from the
  # peer would either fail confusingly or (worse) write into a local directory
  # that is shadowed the moment the mount comes back.
  if [ "$IS_PEER" = "1" ] && [ "$n_llm" -gt 0 ]; then
    warnc "LLM seeding is skipped on the peer: $LLM_ROOT is a read-only NFS mount."
    info "run the seed on $SERVER_HOST; this node sees the result immediately."
    n_llm=0; LLM_MODELS=()
  fi
  if [ "$n_llm" -gt 0 ] && [ "$IS_ROOT" != "1" ]; then
    warnc "not root: LLM downloads into $LLM_ROOT and catalog registration will probably fail."
    info "re-run with sudo for LLM seeding."
  fi

  info "plan: $n_llm LLM(s) -> $LLM_ROOT ; $n_comfy ComfyUI file(s) -> $COMFY_ROOT/models/"
  info "both trees are NFS-shared, so this downloads ONCE for the whole cluster."
  if [ "$ASSUME_YES" != "1" ] && [ -t 0 ]; then
    read -r -p "Proceed with the downloads now? [y/N] " ans
    case "$ans" in [Yy]*) ;; *) warnc "seeding skipped"; return 0 ;; esac
  fi

  local entry repo nm pl spec sub e_tp e_rp e_ml e_kw
  for entry in ${LLM_MODELS[@]+"${LLM_MODELS[@]}"}; do
    [ -z "$entry" ] && continue
    IFS='|' read -r repo nm pl e_tp e_rp e_ml e_kw <<<"$entry"
    seed_llm "$repo" "$nm" "$pl" "$e_tp" "$e_rp" "$e_ml" "$e_kw"
  done
  for entry in ${COMFY_MODELS[@]+"${COMFY_MODELS[@]}"}; do
    [ -z "$entry" ] && continue
    repo="${entry%%|*}"; spec="${entry#*|}"; sub="${spec#*|}"; spec="${spec%%|*}"
    [ "$sub" = "$spec" ] && sub="checkpoints"
    seed_comfy "$repo" "$spec" "$sub"
  done

  if [ "$IS_SERVER" = "1" ] && [ "$DO_REGISTER" = "1" ]; then
    systemctl reload residencyd.service 2>/dev/null \
      && info "residencyd reloaded the catalog" || true
  fi
}

write_example_models() {
  local f="${1:-$MODELS_FILE}"
  [ -e "$f" ] && die "refusing to overwrite the existing $f"
  cat > "$f" <<'EX'
# Strix Halo cluster - model seed list.
# Whitespace-separated columns; '#' starts a comment.
#
#   llm    <repo_id>  [dir-name]  [server|peer|distributed]  [options...]
#       -> full HF model directory into /srv/models/<dir-name>, then registered
#          in the shared catalog. vLLM wants safetensors, NOT GGUF.
#          placement: which node holds it. 'distributed' splits it across both
#          over the USB4 link (TP=2) - only worth it for models too big for one.
#       options (all optional, any order):
#          tools=<parser>   enable OpenAI function calling with this tool parser.
#                           Required by agentic IDE clients (Cline, Copilot Chat
#                           agent mode). Names are specific to the installed
#                           vLLM build - list them with 'llm-model parsers'.
#          reason=<parser>  reasoning parser; without it a thinking model's
#                           <think> blocks leak into the reply body.
#          maxlen=<n>       cap the context window. Worth setting: several
#                           checkpoints declare 262144, which will not fit.
#          keepwarm         exempt from idle eviction, so an editor session
#                           does not begin with a multi-minute cold start.
#
#   comfy  <repo_id>  <path/in/repo>  <models-subdir>
#       -> /srv/comfyui/models/<subdir>/<basename>, shared by both nodes.
#
# llm    openai/gpt-oss-20b                  gpt-oss-20b        server
# llm    Qwen/Qwen3.6-35B-A3B                qwen3.6-35b-a3b    server  tools=qwen3_coder maxlen=65536 keepwarm
# comfy  Comfy-Org/flux1-schnell             flux1-schnell-fp8.safetensors  diffusion_models
EX
  pass "wrote an example model list to $f (edit it, then re-run)"
}

# =============================================================================
# MAIN
# =============================================================================
if [ "${WRITE_EXAMPLE:-0}" = "1" ]; then write_example_models "$MODELS_FILE"; exit 0; fi
command -v curl >/dev/null 2>&1 || die "curl is required (the setup script installs it)."

[ "$DO_VERIFY" = "1" ] && verify
[ "$DO_SEED"   = "1" ] && seed

printf '\n%s%s==================== RESULTS (%s / %s) ====================%s\n' \
  "$BOLD" "$BLU" "$MY_HOST" "$NODE_ROLE" "$RST"
printf '  %sPASS %d%s   %sWARN %d%s   %sFAIL %d%s   %sSKIP %d%s\n' \
  "$GRN" "$PASS_N" "$RST" "$YLW" "$WARN_N" "$RST" "$RED" "$FAIL_N" "$RST" "$BLU" "$SKIP_N" "$RST"
if [ "$FAIL_N" -gt 0 ]; then
  printf '  %sSome checks failed.%s Work down the FAIL lines in order - the stack is a\n' "$RED$BOLD" "$RST"
  printf '  chain, so an early failure usually explains the later ones.\n'
  exit 1
fi
printf '  %sAll good on this node.%s Remember to run this on %s as well.\n' "$GRN$BOLD" "$RST" "$OTHER_HOST"
exit 0

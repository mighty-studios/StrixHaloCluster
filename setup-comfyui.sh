#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

SERVER_HOST="${SERVER_HOST:-}"
PEER_HOST="${PEER_HOST:-}"
NODE_ROLE="${NODE_ROLE:-auto}"
SERVER_IP="${SERVER_IP:-10.200.0.1}"
PEER_IP="${PEER_IP:-10.200.0.2}"
CLUSTER_IFACE="${CLUSTER_IFACE:-usb4llm0}"

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || true)}}"
SHARE_GROUP="${SHARE_GROUP:-aimodels}"
SHARE_GID="${SHARE_GID:-971}"

COMFY_ROOT="${COMFY_ROOT:-/srv/comfyui}"
COMFY_LOCAL_CACHE="${COMFY_LOCAL_CACHE:-/var/lib/comfyui-local}"
COMFY_DIR="${COMFY_DIR:-}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
LAN_NETS="${LAN_NETS:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-1}"

COMFY_PY="${COMFY_PY:-3.12}"
ROCM_GFX="${ROCM_GFX:-gfx1151}"
ROCM_VERSION="${ROCM_VERSION:-10.0.0}"
TORCH_INDEX="${TORCH_INDEX:-https://stable.repo.amd.com/rocm/whl-next/}"
TORCH_EXPECTED_VERSION="${TORCH_EXPECTED_VERSION:-2.11.0+rocm10.0.0}"
TORCHVISION_EXPECTED_VERSION="${TORCHVISION_EXPECTED_VERSION:-0.26.0+rocm10.0.0}"
TORCHAUDIO_EXPECTED_VERSION="${TORCHAUDIO_EXPECTED_VERSION:-2.11.0+rocm10.0.0}"

COMFY_MANAGER_SECURITY="${COMFY_MANAGER_SECURITY:-weak}"
COMFY_CACHE_MODE="${COMFY_CACHE_MODE:-ram}"
COMFY_CACHE_ACTIVE_GB="${COMFY_CACHE_ACTIVE_GB:-4}"
COMFY_CACHE_INACTIVE_GB="${COMFY_CACHE_INACTIVE_GB:-32}"
COMFY_CACHE_LRU="${COMFY_CACHE_LRU:-8}"
COMFY_RESERVE_VRAM="${COMFY_RESERVE_VRAM:-16}"
COMFY_PREVIEW_METHOD="${COMFY_PREVIEW_METHOD:-auto}"
COMFY_ENABLE_ASSETS="${COMFY_ENABLE_ASSETS:-0}"
COMFY_DISABLE_API_NODES="${COMFY_DISABLE_API_NODES:-0}"

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
  sudo bash $SCRIPT_NAME --server <hostname> --peer <hostname> [options]

Installs only:
  - One local ComfyUI service on this node
  - One read-write NFS ComfyUI store shared by both nodes
  - LAN access to this node's ComfyUI web service

Required:
  --server <hostname>          Hostname of the node exporting the shared store
  --peer <hostname>            Hostname of the node mounting the shared store

Role and network:
  --role <server|peer|auto>    Node role (default: auto from hostname)
  --server-ip <address>        Private server address (default: $SERVER_IP)
  --peer-ip <address>          Private peer address (default: $PEER_IP)
  --cluster-iface <name>       Private interface used by NFS (default: $CLUSTER_IFACE)

Paths and account:
  --user <name>                Account that runs ComfyUI
  --share-group <name>         Shared NFS group (default: $SHARE_GROUP)
  --share-gid <number>         Numeric group ID on both nodes (default: $SHARE_GID)
  --comfy-root <path>          Shared store (default: $COMFY_ROOT)
  --comfy-dir <path>           Local checkout (default: <user-home>/ComfyUI)
  --local-cache <path>         Local temp/user cache (default: $COMFY_LOCAL_CACHE)

ComfyUI:
  --port <port>                Web service port (default: $COMFYUI_PORT)
  --comfy-cache <mode>         ram, classic, lru, or none
  --reserve-vram <gib>         GPU memory ComfyUI leaves free (default: $COMFY_RESERVE_VRAM)
  --preview <mode>             none, auto, latent2rgb, or taesd
  --enable-assets              Enable the shared-store asset scanner
  --disable-api-nodes          Disable frontend API nodes
  --manager-security <level>   Manager security level (default: $COMFY_MANAGER_SECURITY)

Other:
  --lan-nets "<cidrs>"         Space-separated LAN ranges allowed through UFW
  --no-firewall               Do not add UFW rules
  -h, --help                  Show this help

All settings can also be supplied through matching environment variables.
USAGE
}

need_arg() {
  [ -n "${2:-}" ] || die "$1 requires a value"
}

valid_hostname() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --server)
      need_arg "$1" "${2:-}"
      SERVER_HOST="$2"
      shift
      ;;
    --peer)
      need_arg "$1" "${2:-}"
      PEER_HOST="$2"
      shift
      ;;
    --role)
      need_arg "$1" "${2:-}"
      NODE_ROLE="$2"
      shift
      ;;
    --server-ip)
      need_arg "$1" "${2:-}"
      SERVER_IP="$2"
      shift
      ;;
    --peer-ip)
      need_arg "$1" "${2:-}"
      PEER_IP="$2"
      shift
      ;;
    --cluster-iface)
      need_arg "$1" "${2:-}"
      CLUSTER_IFACE="$2"
      shift
      ;;
    --user)
      need_arg "$1" "${2:-}"
      TARGET_USER="$2"
      shift
      ;;
    --share-group)
      need_arg "$1" "${2:-}"
      SHARE_GROUP="$2"
      shift
      ;;
    --share-gid)
      need_arg "$1" "${2:-}"
      SHARE_GID="$2"
      shift
      ;;
    --comfy-root)
      need_arg "$1" "${2:-}"
      COMFY_ROOT="$2"
      shift
      ;;
    --comfy-dir)
      need_arg "$1" "${2:-}"
      COMFY_DIR="$2"
      shift
      ;;
    --local-cache)
      need_arg "$1" "${2:-}"
      COMFY_LOCAL_CACHE="$2"
      shift
      ;;
    --port)
      need_arg "$1" "${2:-}"
      COMFYUI_PORT="$2"
      shift
      ;;
    --comfy-cache)
      need_arg "$1" "${2:-}"
      COMFY_CACHE_MODE="$2"
      shift
      ;;
    --reserve-vram)
      need_arg "$1" "${2:-}"
      COMFY_RESERVE_VRAM="$2"
      shift
      ;;
    --preview)
      need_arg "$1" "${2:-}"
      COMFY_PREVIEW_METHOD="$2"
      shift
      ;;
    --enable-assets)
      COMFY_ENABLE_ASSETS=1
      ;;
    --disable-api-nodes)
      COMFY_DISABLE_API_NODES=1
      ;;
    --manager-security)
      need_arg "$1" "${2:-}"
      COMFY_MANAGER_SECURITY="$2"
      shift
      ;;
    --lan-nets)
      need_arg "$1" "${2:-}"
      LAN_NETS="$2"
      shift
      ;;
    --no-firewall)
      CONFIGURE_FIREWALL=0
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

[ "$EUID" -eq 0 ] || die "run this script as root, for example: sudo bash $SCRIPT_NAME ..."
command -v apt-get >/dev/null 2>&1 || die "this installer requires an apt-based Linux distribution"
command -v systemctl >/dev/null 2>&1 || die "this installer requires systemd"

[ -n "$SERVER_HOST" ] && [ -n "$PEER_HOST" ] || die "--server and --peer are required"
valid_hostname "$SERVER_HOST" || die "invalid server hostname: $SERVER_HOST"
valid_hostname "$PEER_HOST" || die "invalid peer hostname: $PEER_HOST"
[ "$SERVER_HOST" != "$PEER_HOST" ] || die "server and peer hostnames must differ"

[ -n "$TARGET_USER" ] || die "could not determine the ComfyUI user; pass --user <name>"
[ "$TARGET_USER" != "root" ] || die "--user must name an unprivileged account"
id "$TARGET_USER" >/dev/null 2>&1 || die "user '$TARGET_USER' does not exist; run setup-environment.sh first or create the account"

[[ "$SHARE_GID" =~ ^[0-9]+$ ]] || die "share GID must be numeric"
[[ "$COMFYUI_PORT" =~ ^[0-9]+$ ]] || die "ComfyUI port must be numeric"
[ "$COMFYUI_PORT" -ge 1 ] && [ "$COMFYUI_PORT" -le 65535 ] || die "ComfyUI port must be between 1 and 65535"
[[ "$CLUSTER_IFACE" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]] || die "invalid private interface name: $CLUSTER_IFACE"
[[ "$SHARE_GROUP" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "invalid shared group name: $SHARE_GROUP"
[[ "$SERVER_IP" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || die "invalid server IPv4 address: $SERVER_IP"
[[ "$PEER_IP" =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]] || die "invalid peer IPv4 address: $PEER_IP"
[[ "$COMFY_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid shared-store path: $COMFY_ROOT"
[[ "$COMFY_LOCAL_CACHE" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid local-cache path: $COMFY_LOCAL_CACHE"
[[ "$COMFY_MANAGER_SECURITY" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid Manager security level"
case "$COMFY_ROOT" in
  /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
    die "refusing unsafe shared-store path: $COMFY_ROOT"
    ;;
esac
case "$COMFY_LOCAL_CACHE" in
  /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
    die "refusing unsafe local-cache path: $COMFY_LOCAL_CACHE"
    ;;
esac

case "$COMFY_CACHE_MODE" in
  ram|classic|lru|none) ;;
  *) die "--comfy-cache must be ram, classic, lru, or none" ;;
esac

case "$COMFY_PREVIEW_METHOD" in
  none|auto|latent2rgb|taesd) ;;
  *) die "--preview must be none, auto, latent2rgb, or taesd" ;;
esac

for value in "$COMFY_CACHE_ACTIVE_GB" "$COMFY_CACHE_INACTIVE_GB" "$COMFY_RESERVE_VRAM"; do
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "ComfyUI memory values must be numeric GiB values"
done
[[ "$COMFY_CACHE_LRU" =~ ^[0-9]+$ ]] || die "COMFY_CACHE_LRU must be a whole number"
[ "${COMFY_CACHE_ACTIVE_GB%%.*}" -le "${COMFY_CACHE_INACTIVE_GB%%.*}" ] \
  || die "active cache must not exceed inactive cache"
for value in "$COMFY_ENABLE_ASSETS" "$COMFY_DISABLE_API_NODES" "$CONFIGURE_FIREWALL"; do
  case "$value" in
    0|1) ;;
    *) die "boolean settings must be 0 or 1" ;;
  esac
done

THIS_HOST="$(hostname -s 2>/dev/null || true)"
[ -n "$THIS_HOST" ] || THIS_HOST="$(head -n1 /etc/hostname 2>/dev/null || true)"

case "$NODE_ROLE" in
  server|peer)
    ;;
  auto)
    if [ "$THIS_HOST" = "$SERVER_HOST" ]; then
      NODE_ROLE=server
    elif [ "$THIS_HOST" = "$PEER_HOST" ]; then
      NODE_ROLE=peer
    else
      die "hostname '$THIS_HOST' matches neither '$SERVER_HOST' nor '$PEER_HOST'; pass --role server or --role peer"
    fi
    ;;
  *)
    die "--role must be server, peer, or auto"
    ;;
esac

if [ "$NODE_ROLE" = "server" ]; then
  IS_SERVER=1
  IS_PEER=0
  MY_HOST="$SERVER_HOST"
  OTHER_HOST="$PEER_HOST"
  OTHER_IP="$PEER_IP"
else
  IS_SERVER=0
  IS_PEER=1
  MY_HOST="$PEER_HOST"
  OTHER_HOST="$SERVER_HOST"
  OTHER_IP="$SERVER_IP"
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$USER_HOME" ] && [ -d "$USER_HOME" ] || die "home directory for '$TARGET_USER' was not found"
[ -n "$COMFY_DIR" ] || COMFY_DIR="$USER_HOME/ComfyUI"
[[ "$COMFY_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid ComfyUI checkout path: $COMFY_DIR"
case "$COMFY_DIR" in
  /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
    die "refusing unsafe ComfyUI checkout path: $COMFY_DIR"
    ;;
esac
[ "$COMFY_DIR" != "$COMFY_ROOT" ] || die "the local checkout and shared store must be different paths"
[ "$COMFY_LOCAL_CACHE" != "$COMFY_ROOT" ] || die "the local cache and shared store must be different paths"
TARGET_PRIMARY_GROUP="$(id -gn "$TARGET_USER")"

as_user() {
  sudo -u "$TARGET_USER" -H bash -lc "$1"
}

ensure_share_group() {
  local current_gid
  local gid_owner

  if getent group "$SHARE_GROUP" >/dev/null 2>&1; then
    current_gid="$(getent group "$SHARE_GROUP" | cut -d: -f3)"
    [ "$current_gid" = "$SHARE_GID" ] \
      || die "group '$SHARE_GROUP' is GID $current_gid here but must be $SHARE_GID on both nodes"
  else
    gid_owner="$(getent group "$SHARE_GID" | cut -d: -f1 || true)"
    [ -z "$gid_owner" ] || die "GID $SHARE_GID is already used by group '$gid_owner'"
    groupadd -g "$SHARE_GID" "$SHARE_GROUP"
    ok "created group '$SHARE_GROUP' with GID $SHARE_GID"
  fi

  usermod -aG "$SHARE_GROUP",render,video "$TARGET_USER"
  ok "$TARGET_USER added to $SHARE_GROUP, render, and video"
}

# =============================================================================
# 2. SHARED NFS STORE
# =============================================================================
export DEBIAN_FRONTEND=noninteractive
log "Installing ComfyUI and shared-store prerequisites"
apt-get update -y
BASE_PACKAGES=(ca-certificates curl git sudo findutils coreutils util-linux iputils-ping)
[ "$CONFIGURE_FIREWALL" = "1" ] && BASE_PACKAGES+=(ufw)
apt-get install -y "${BASE_PACKAGES[@]}"
ensure_share_group

configure_shared_store_server() {
  log "Exporting the shared ComfyUI store to $PEER_IP"

  apt-get install -y nfs-kernel-server

  install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" "$COMFY_ROOT"
  for directory in models input output workflows hf; do
    install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" "$COMFY_ROOT/$directory"
  done

  install -d -m 0755 /etc/nfs.conf.d
  cat > /etc/nfs.conf.d/10-comfyui-cluster.conf <<NFSCONF
# Managed by $SCRIPT_NAME
[nfsd]
vers2 = n
vers3 = n
udp = n
tcp = y
NFSCONF

  install -d -m 0755 /etc/exports.d
  cat > /etc/exports.d/comfyui-cluster.exports <<EXPORTS
# Managed by $SCRIPT_NAME
# Read-write export restricted to the private peer address.
$COMFY_ROOT	$PEER_IP/32(rw,sync,no_subtree_check,root_squash)
EXPORTS
  chmod 0644 /etc/exports.d/comfyui-cluster.exports

  cat > "$COMFY_ROOT/.cluster-ids" <<IDS
# Managed by $SCRIPT_NAME on $SERVER_HOST
SERVER_HOST=$SERVER_HOST
TARGET_USER=$TARGET_USER
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_GID=$(id -g "$TARGET_USER")
SHARE_GROUP=$SHARE_GROUP
SHARE_GID=$SHARE_GID
IDS
  chown "$TARGET_USER:$SHARE_GROUP" "$COMFY_ROOT/.cluster-ids"
  chmod 0664 "$COMFY_ROOT/.cluster-ids"

  ensure_boot_unit nfs-server
  systemctl restart nfs-server >/dev/null 2>&1 \
    || systemctl start nfs-server >/dev/null 2>&1
  exportfs -rav
  systemctl is-active --quiet nfs-server || die "nfs-server is not active"
  ok "$COMFY_ROOT exported read-write to $PEER_IP"
}

configure_shared_store_peer() {
  log "Mounting the shared ComfyUI store from $SERVER_IP"

  apt-get install -y nfs-common
  mountpoint -q "$COMFY_ROOT" 2>/dev/null || install -d -m 0755 "$COMFY_ROOT"

  sed -i '\%^# >>> qwen3d8 ComfyUI shared store%,\%^# <<< qwen3d8 ComfyUI shared store%d' /etc/fstab
  sed -i "\#[[:space:]]${COMFY_ROOT}[[:space:]]#d" /etc/fstab
  cat >> /etc/fstab <<FSTAB
# >>> qwen3d8 ComfyUI shared store (managed by $SCRIPT_NAME) >>>
$SERVER_IP:$COMFY_ROOT	$COMFY_ROOT	nfs4	rw,_netdev,noatime,nofail,nconnect=4,x-systemd.automount,x-systemd.mount-timeout=30	0	0
# <<< qwen3d8 ComfyUI shared store <<<
FSTAB
  systemctl daemon-reload >/dev/null 2>&1 || true

  if ping -c1 -W2 -n "$SERVER_IP" >/dev/null 2>&1; then
    if mountpoint -q "$COMFY_ROOT"; then
      ok "$COMFY_ROOT already mounted"
    elif timeout 45 mount "$COMFY_ROOT" >/dev/null 2>&1; then
      ok "$COMFY_ROOT mounted from $SERVER_IP"
    else
      warn "$COMFY_ROOT did not mount immediately; systemd will automount it when the server is available"
    fi
  else
    warn "$SERVER_IP is not reachable yet; the shared store will automount later"
  fi

  if [ -r "$COMFY_ROOT/.cluster-ids" ]; then
    local server_uid
    local server_gid
    local local_uid
    local local_gid

    server_uid="$(awk -F= '$1=="TARGET_UID"{print $2}' "$COMFY_ROOT/.cluster-ids")"
    server_gid="$(awk -F= '$1=="SHARE_GID"{print $2}' "$COMFY_ROOT/.cluster-ids")"
    local_uid="$(id -u "$TARGET_USER")"
    local_gid="$(getent group "$SHARE_GROUP" | cut -d: -f3)"

    if [ -n "$server_uid" ] && [ "$server_uid" != "$local_uid" ]; then
      warn "UID mismatch: $TARGET_USER is $local_uid here and $server_uid on $SERVER_HOST"
      note_action "Make '$TARGET_USER' use UID $server_uid on both nodes before writing to $COMFY_ROOT"
    else
      ok "$TARGET_USER has the same UID on both nodes"
    fi

    if [ -n "$server_gid" ] && [ "$server_gid" != "$local_gid" ]; then
      warn "GID mismatch: $SHARE_GROUP is $local_gid here and $server_gid on $SERVER_HOST"
      note_action "Make '$SHARE_GROUP' use GID $server_gid on both nodes"
    else
      ok "$SHARE_GROUP has the same GID on both nodes"
    fi
  fi
}

if [ "$IS_SERVER" = "1" ]; then
  configure_shared_store_server
else
  configure_shared_store_peer
fi
echo

# =============================================================================
# 3. COMFYUI CHECKOUT, PYTHON ENVIRONMENT, AND SHARED LINKS
# =============================================================================
install_uv() {
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
    ok "uv already installed at $UV_BIN"
    return
  fi

  log "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh
  UV_BIN=/usr/local/bin/uv
  [ -x "$UV_BIN" ] || die "uv installation did not create $UV_BIN"
  ok "uv installed at $UV_BIN"
}

install_uv

log "Installing the local ComfyUI checkout"
if [ -d "$COMFY_DIR/.git" ]; then
  if as_user "cd '$COMFY_DIR' && git pull --ff-only"; then
    ok "updated the existing ComfyUI checkout"
  else
    warn "the existing ComfyUI checkout could not be fast-forwarded; keeping its current revision"
  fi
else
  as_user "git clone https://github.com/comfyanonymous/ComfyUI '$COMFY_DIR'"
fi

install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" \
  "$COMFY_LOCAL_CACHE" "$COMFY_LOCAL_CACHE/temp"
install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_PRIMARY_GROUP" \
  "$COMFY_LOCAL_CACHE/user"

shared_store_ready=0
if [ "$IS_SERVER" = "1" ] || findmnt -T "$COMFY_ROOT" -n -o FSTYPE 2>/dev/null | grep nfs >/dev/null; then
  shared_store_ready=1
else
  warn "$COMFY_ROOT is not mounted yet; links will target the future automount"
fi

link_shared() {
  local relative_path="$1"
  local target="$2"
  local source="$COMFY_DIR/$relative_path"
  local copy_error=""
  local copy_ok=0

  install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" "$target" 2>/dev/null || true

  if [ -L "$source" ]; then
    if [ "$(readlink -f "$source")" = "$(readlink -f "$target")" ]; then
      return 0
    fi
    rm -f "$source"
  elif [ -d "$source" ]; then
    if [ -n "$(ls -A "$source" 2>/dev/null)" ]; then
      log "  migrating existing $relative_path into the shared store"
      if copy_error="$(cp -a "$source/." "$target/" 2>&1)"; then
        copy_ok=1
      elif copy_error="$(as_user "cp -a '$source/.' '$target/'" 2>&1)"; then
        copy_ok=1
      fi

      if [ "$copy_ok" = "0" ]; then
        if [ -n "$(find "$source" -type f ! -name '.gitkeep' ! -name 'put_*' -print -quit 2>/dev/null)" ]; then
          warn "could not migrate $source into $target; leaving it local"
          [ -n "$copy_error" ] && warn "  ${copy_error%%$'\n'*}"
          return 1
        fi
      fi
    fi
    rm -rf "$source"
  fi

  ln -sfn "$target" "$source"
  chown -h "$TARGET_USER:$TARGET_PRIMARY_GROUP" "$source" 2>/dev/null || true
}

link_shared_pending_mount() {
  local relative_path="$1"
  local target="$2"
  local source="$COMFY_DIR/$relative_path"

  if [ -L "$source" ]; then
    if [ "$(readlink "$source" 2>/dev/null || true)" = "$target" ]; then
      return 0
    fi
    rm -f "$source"
  elif [ -d "$source" ]; then
    if [ -n "$(find "$source" -type f ! -name '.gitkeep' ! -name 'put_*' -print -quit 2>/dev/null)" ]; then
      die "$source contains real files but the shared store is unavailable; mount $COMFY_ROOT before rerunning"
    fi
    rm -rf "$source"
  fi

  ln -sfn "$target" "$source"
  chown -h "$TARGET_USER:$TARGET_PRIMARY_GROUP" "$source" 2>/dev/null || true
}

if [ "$shared_store_ready" = "1" ]; then
  for pair in \
      "models:$COMFY_ROOT/models" \
      "input:$COMFY_ROOT/input" \
      "output:$COMFY_ROOT/output"; do
    link_shared "${pair%%:*}" "${pair#*:}"
    ok "ComfyUI/${pair%%:*} -> ${pair#*:}"
  done

  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_PRIMARY_GROUP" \
    "$COMFY_DIR/user" "$COMFY_DIR/user/default"
  link_shared user/default/workflows "$COMFY_ROOT/workflows"
  ok "ComfyUI/user/default/workflows -> $COMFY_ROOT/workflows"
else
  for pair in \
      "models:$COMFY_ROOT/models" \
      "input:$COMFY_ROOT/input" \
      "output:$COMFY_ROOT/output"; do
    link_shared_pending_mount "${pair%%:*}" "${pair#*:}"
    ok "ComfyUI/${pair%%:*} -> ${pair#*:} (pending NFS mount)"
  done

  install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_PRIMARY_GROUP" \
    "$COMFY_DIR/user" "$COMFY_DIR/user/default"
  link_shared_pending_mount user/default/workflows "$COMFY_ROOT/workflows"
  ok "ComfyUI/user/default/workflows -> $COMFY_ROOT/workflows (pending NFS mount)"
fi

cat > "$USER_HOME/.comfyui_provision.sh" <<'PROVISION'
#!/usr/bin/env bash
set -Eeuo pipefail

exec </dev/null
export GIT_TERMINAL_PROMPT=0

cd "$COMFY_DIR"

if [ -x .venv/bin/python ]; then
  existing_py="$(.venv/bin/python -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
  if [ "$existing_py" != "$COMFY_PY" ]; then
    echo "Rebuilding .venv because Python $existing_py does not match $COMFY_PY"
    rm -rf .venv
  fi
fi

if [ ! -x .venv/bin/python ] || ! .venv/bin/python -c '' >/dev/null 2>&1; then
  rm -rf .venv
  "$UV_BIN" venv --python "$COMFY_PY" .venv
fi

"$UV_BIN" pip install --python .venv/bin/python \
  --index-url "$TORCH_INDEX" \
  --extra-index-url https://pypi.org/simple \
  --index-strategy unsafe-best-match \
  "torch==${TORCH_EXPECTED_VERSION}" \
  "amd-torch-device-gfx1151==${TORCH_EXPECTED_VERSION}" \
  "rocm-sdk-devel==${ROCM_VERSION}" \
  "rocm-sdk-device-gfx1151==${ROCM_VERSION}" \
  "torchvision==${TORCHVISION_EXPECTED_VERSION}" \
  "torchaudio==${TORCHAUDIO_EXPECTED_VERSION}"

grep -viE '^(torch|torchvision|torchaudio)([[:space:]<>=!~;]|$)' requirements.txt \
  > .reqs-notorch.txt || cp requirements.txt .reqs-notorch.txt
"$UV_BIN" pip install --python .venv/bin/python -r .reqs-notorch.txt

manager_ok=0
if [ -f manager_requirements.txt ]; then
  grep -viE '^(torch|torchvision|torchaudio)([[:space:]<>=!~;]|$)' manager_requirements.txt \
    > .mgr-reqs.txt || cp manager_requirements.txt .mgr-reqs.txt
  if "$UV_BIN" pip install --python .venv/bin/python -r .mgr-reqs.txt; then
    manager_ok=1
  fi
fi

if [ "$manager_ok" != "1" ] || ! .venv/bin/python -c 'import comfyui_manager' 2>/dev/null; then
  mkdir -p custom_nodes
  if [ -d custom_nodes/comfyui-manager/.git ]; then
    git -C custom_nodes/comfyui-manager pull --ff-only || true
  else
    git clone https://github.com/Comfy-Org/ComfyUI-Manager custom_nodes/comfyui-manager || true
  fi

  if [ -f custom_nodes/comfyui-manager/requirements.txt ]; then
    grep -viE '^(torch|torchvision|torchaudio)([[:space:]<>=!~;]|$)' \
      custom_nodes/comfyui-manager/requirements.txt \
      > .mgr-cn-reqs.txt || cp custom_nodes/comfyui-manager/requirements.txt .mgr-cn-reqs.txt
    "$UV_BIN" pip install --python .venv/bin/python -r .mgr-cn-reqs.txt || true
  fi
fi

"$UV_BIN" pip install --python .venv/bin/python --no-deps \
  --index-url "$TORCH_INDEX" \
  --extra-index-url https://pypi.org/simple \
  --index-strategy unsafe-best-match \
  "torch==${TORCH_EXPECTED_VERSION}" \
  "amd-torch-device-gfx1151==${TORCH_EXPECTED_VERSION}" \
  "rocm-sdk-devel==${ROCM_VERSION}" \
  "rocm-sdk-device-gfx1151==${ROCM_VERSION}" \
  "torchvision==${TORCHVISION_EXPECTED_VERSION}" \
  "torchaudio==${TORCHAUDIO_EXPECTED_VERSION}"

mkdir -p custom_nodes
if [ -d custom_nodes/comfyui-url-downloader/.git ]; then
  git -C custom_nodes/comfyui-url-downloader pull --ff-only || true
else
  git clone https://github.com/mighty-bean/comfyui-url-downloader custom_nodes/comfyui-url-downloader || true
fi
PROVISION
chown "$TARGET_USER:$TARGET_PRIMARY_GROUP" "$USER_HOME/.comfyui_provision.sh"
chmod 0755 "$USER_HOME/.comfyui_provision.sh"

if as_user "COMFY_DIR='$COMFY_DIR' UV_BIN='$UV_BIN' COMFY_PY='$COMFY_PY' TORCH_INDEX='$TORCH_INDEX' TORCH_EXPECTED_VERSION='$TORCH_EXPECTED_VERSION' TORCHVISION_EXPECTED_VERSION='$TORCHVISION_EXPECTED_VERSION' TORCHAUDIO_EXPECTED_VERSION='$TORCHAUDIO_EXPECTED_VERSION' ROCM_VERSION='$ROCM_VERSION' bash '$USER_HOME/.comfyui_provision.sh'"; then
  ok "ComfyUI Python environment ready"
else
  die "ComfyUI Python provisioning failed; rerun: sudo -u $TARGET_USER bash $USER_HOME/.comfyui_provision.sh"
fi

comfy_has_flag() {
  as_user "grep -q -- '$1' '$COMFY_DIR/comfy/cli_args.py'"
}

COMFY_TUNE_FLAGS=""
comfy_add_flag() {
  COMFY_TUNE_FLAGS="${COMFY_TUNE_FLAGS:+$COMFY_TUNE_FLAGS }$*"
}

COMFY_MANAGER_FLAG=""
if comfy_has_flag --enable-manager 2>/dev/null; then
  COMFY_MANAGER_FLAG=--enable-manager
fi

COMFY_TEMP_FLAG=""
if comfy_has_flag --temp-directory 2>/dev/null; then
  COMFY_TEMP_FLAG="--temp-directory $COMFY_LOCAL_CACHE/temp"
fi

case "$COMFY_CACHE_MODE" in
  ram)
    if comfy_has_flag --cache-ram 2>/dev/null; then
      comfy_add_flag "--cache-ram $COMFY_CACHE_ACTIVE_GB $COMFY_CACHE_INACTIVE_GB"
    fi
    ;;
  classic)
    comfy_has_flag --cache-classic 2>/dev/null && comfy_add_flag --cache-classic
    ;;
  lru)
    comfy_has_flag --cache-lru 2>/dev/null && comfy_add_flag "--cache-lru $COMFY_CACHE_LRU"
    ;;
  none)
    comfy_has_flag --cache-none 2>/dev/null && comfy_add_flag --cache-none
    ;;
esac

if [ "${COMFY_RESERVE_VRAM%%.*}" != "0" ] && comfy_has_flag --reserve-vram 2>/dev/null; then
  comfy_add_flag "--reserve-vram $COMFY_RESERVE_VRAM"
fi

if [ "$COMFY_PREVIEW_METHOD" != "none" ] && comfy_has_flag --preview-method 2>/dev/null; then
  comfy_add_flag "--preview-method $COMFY_PREVIEW_METHOD"
fi

if [ "$COMFY_ENABLE_ASSETS" = "1" ] && comfy_has_flag --enable-assets 2>/dev/null; then
  comfy_add_flag --enable-assets
fi

if [ "$COMFY_DISABLE_API_NODES" = "1" ] && comfy_has_flag --disable-api-nodes 2>/dev/null; then
  comfy_add_flag --disable-api-nodes
fi

install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_PRIMARY_GROUP" \
  "$COMFY_DIR/user" \
  "$COMFY_DIR/user/__manager" \
  "$COMFY_DIR/user/default" \
  "$COMFY_DIR/user/default/ComfyUI-Manager"

for manager_dir in \
    "$COMFY_DIR/user/__manager" \
    "$COMFY_DIR/user/default/ComfyUI-Manager"; do
  if [ ! -f "$manager_dir/config.ini" ]; then
    printf '[default]\nsecurity_level = %s\nnetwork_mode = public\n' \
      "$COMFY_MANAGER_SECURITY" > "$manager_dir/config.ini"
  fi
done
chown -R -h "$TARGET_USER:$TARGET_PRIMARY_GROUP" "$COMFY_DIR/user"

if [ "$IS_PEER" = "1" ]; then
  automount_unit="$(systemd-escape -p --suffix=automount "$COMFY_ROOT" 2>/dev/null || true)"
  [ -n "$automount_unit" ] || automount_unit=remote-fs.target

  cat > /usr/local/bin/comfy-store-wait <<WAIT
#!/usr/bin/env bash
set -u

for _ in \$(seq 1 40); do
  ls "$COMFY_ROOT/" >/dev/null 2>&1 || true
  if findmnt -T "$COMFY_ROOT" -n -o FSTYPE 2>/dev/null | grep nfs >/dev/null; then
    if [ -r "$COMFY_ROOT/.cluster-ids" ]; then
      server_uid="\$(awk -F= '\$1==\"TARGET_UID\"{print \$2}' "$COMFY_ROOT/.cluster-ids")"
      server_gid="\$(awk -F= '\$1==\"SHARE_GID\"{print \$2}' "$COMFY_ROOT/.cluster-ids")"
      if [ -n "\$server_uid" ] && [ "\$server_uid" != "$(id -u "$TARGET_USER")" ]; then
        echo "comfy-store-wait: UID mismatch for $TARGET_USER (local $(id -u "$TARGET_USER"), server \$server_uid)" >&2
        exit 1
      fi
      if [ -n "\$server_gid" ] && [ "\$server_gid" != "$SHARE_GID" ]; then
        echo "comfy-store-wait: GID mismatch for $SHARE_GROUP (local $SHARE_GID, server \$server_gid)" >&2
        exit 1
      fi
    fi
    exit 0
  fi
  sleep 3
done

echo "comfy-store-wait: $COMFY_ROOT is not mounted from $SERVER_HOST" >&2
exit 1
WAIT
  chmod 0755 /usr/local/bin/comfy-store-wait

  SERVICE_MOUNT_DEPENDENCY="After=$automount_unit
Wants=$automount_unit"
  SERVICE_MOUNT_GATE="ExecStartPre=/usr/local/bin/comfy-store-wait"
else
  SERVICE_MOUNT_DEPENDENCY=""
  SERVICE_MOUNT_GATE=""
fi

# =============================================================================
# 4. COMFYUI SERVICE
# =============================================================================
COMFY_ROCM_PATH="$COMFY_DIR/.venv/lib/python$COMFY_PY/site-packages/_rocm_sdk_core"
cat > /etc/systemd/system/comfyui.service <<UNIT
[Unit]
Description=ComfyUI on $MY_HOST
After=network-online.target
Wants=network-online.target
$SERVICE_MOUNT_DEPENDENCY

[Service]
Type=simple
User=$TARGET_USER
Group=$TARGET_PRIMARY_GROUP
SupplementaryGroups=render video $SHARE_GROUP
UMask=0002
Environment=HOME=$USER_HOME
Environment=HF_HOME=$COMFY_ROOT/hf
Environment=HF_HUB_CACHE=$COMFY_ROOT/hf/hub
Environment=ROCM_PATH=$COMFY_ROCM_PATH
Environment=HIP_PATH=$COMFY_ROCM_PATH
Environment=PYTORCH_ROCM_ARCH=$ROCM_GFX
WorkingDirectory=$COMFY_DIR
$SERVICE_MOUNT_GATE
ExecStart=$COMFY_DIR/.venv/bin/python $COMFY_DIR/main.py --listen $BIND_ADDR --port $COMFYUI_PORT $COMFY_MANAGER_FLAG $COMFY_TEMP_FLAG $COMFY_TUNE_FLAGS
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
ensure_boot_unit comfyui.service
if [ "$IS_PEER" = "1" ] && ! findmnt -T "$COMFY_ROOT" -n -o FSTYPE 2>/dev/null | grep nfs >/dev/null; then
  systemctl start --no-block comfyui.service >/dev/null 2>&1 || true
  warn "comfyui.service is enabled and waiting for the shared NFS store"
elif systemctl restart comfyui.service >/dev/null 2>&1; then
  ok "comfyui.service running on $BIND_ADDR:$COMFYUI_PORT"
else
  warn "comfyui.service did not start immediately"
  note_action "Inspect it with: systemctl status comfyui.service --no-pager"
fi

# =============================================================================
# 5. FIREWALL AND SUMMARY
# =============================================================================
configure_firewall() {
  [ "$CONFIGURE_FIREWALL" = "1" ] || return 0

  log "Adding ComfyUI and NFS firewall rules"
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true

  local net
  for net in $LAN_NETS; do
    ufw allow from "$net" to any port "$COMFYUI_PORT" proto tcp >/dev/null
  done

  if [ "$IS_SERVER" = "1" ]; then
    ufw allow in on "$CLUSTER_IFACE" from "$PEER_IP" to any port 2049 proto tcp >/dev/null
  fi

  yes | ufw enable >/dev/null 2>&1 || true
  systemctl enable ufw.service >/dev/null 2>&1 || true
  if ufw status 2>/dev/null | grep '^Status: active' >/dev/null; then
    ok "UFW active; ComfyUI is LAN-only and NFS is private-link-only"
    if grep -E '^ENABLED=yes' /etc/ufw/ufw.conf >/dev/null 2>&1; then
      ok "UFW is configured to restore its rules at boot"
    else
      warn "UFW is active now but is not marked enabled for boot"
      note_action "Persist UFW at boot with: sudo ufw enable"
    fi
  else
    warn "UFW is not active"
    note_action "Enable it with: sudo ufw default deny incoming && sudo ufw enable"
  fi
}

configure_firewall

LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
[ -n "$LAN_IP" ] || LAN_IP="$MY_HOST"

echo
echo "${GRN}${BOLD}ComfyUI setup complete on $MY_HOST${RST}"
echo "  Role:          $NODE_ROLE"
echo "  Web service:   http://$LAN_IP:$COMFYUI_PORT"
echo "  Shared store:  $COMFY_ROOT"
if [ "$IS_SERVER" = "1" ]; then
  echo "  NFS export:    $COMFY_ROOT -> $PEER_IP"
else
  echo "  NFS source:    $SERVER_IP:$COMFY_ROOT"
fi
echo "  Local state:   $COMFY_DIR/custom_nodes, $COMFY_DIR/user, $COMFY_LOCAL_CACHE"

if [ "${#ACTIONS[@]}" -gt 0 ]; then
  echo
  echo "${YLW}${BOLD}Action required${RST}"
  for action in "${ACTIONS[@]}"; do
    echo "${YLW}  *${RST} $action"
  done
fi

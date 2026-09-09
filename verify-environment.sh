#!/usr/bin/env bash

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
USB4_ENV="${USB4_ENV:-/etc/default/usb4-cluster}"

if [ -r "$USB4_ENV" ]; then
  # shellcheck disable=SC1090
  . "$USB4_ENV"
fi

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || true)}}"
XFER_ROOT="${XFER_ROOT:-/srv/xfer}"
XFER_SHARE="${XFER_SHARE:-xfer}"
XRDP_PORT="${XRDP_PORT:-3389}"

CLUSTER_ROLE="${CLUSTER_ROLE:-}"
CLUSTER_IFACE="${CLUSTER_IFACE:-usb4llm0}"
CLUSTER_LOCAL_IP="${CLUSTER_LOCAL_IP:-}"
CLUSTER_PEER_IP="${CLUSTER_PEER_IP:-}"
CLUSTER_CIDR="${CLUSTER_CIDR:-30}"
CLUSTER_MTU="${CLUSTER_MTU:-1500}"
RPC_PORT="${RPC_PORT:-50053}"
IPERF_PORT="${IPERF_PORT:-5201}"

IPERF_MODE=auto
IPERF_DURATION="${IPERF_DURATION:-30}"
IPERF_PARALLEL="${IPERF_PARALLEL:-4}"
IPERF_TARGET_GBPS="${IPERF_TARGET_GBPS:-8.0}"

USE_COLOR=1
if [ ! -t 1 ]; then
  USE_COLOR=0
fi

if [ "$USE_COLOR" = "1" ]; then
  BOLD=$'\e[1m'
  RED=$'\e[31m'
  GRN=$'\e[32m'
  YLW=$'\e[33m'
  BLU=$'\e[34m'
  RST=$'\e[0m'
else
  BOLD=""
  RED=""
  GRN=""
  YLW=""
  BLU=""
  RST=""
fi

PASSES=0
WARNINGS=0
FAILURES=0

section() {
  echo
  echo "${BLU}${BOLD}== $* ==${RST}"
}

pass() {
  PASSES=$((PASSES + 1))
  echo "${GRN}PASS${RST}  $*"
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  echo "${YLW}WARN${RST}  $*"
}

fail() {
  FAILURES=$((FAILURES + 1))
  echo "${RED}FAIL${RST}  $*"
}

die() {
  echo "${RED}${BOLD}ERROR:${RST} $*" >&2
  exit 2
}

# =============================================================================
# 1. CONFIGURATION AND ARGUMENTS
# =============================================================================
usage() {
  cat <<USAGE
Usage: sudo bash $SCRIPT_NAME [options]

Validates:
  - USB4 modules, authorization, interface, address, routing, and firewall
  - Journald caps, SMART monitoring, periodic TRIM, and radio hardening
  - The per-node anonymous SMB xfer share
  - XRDP, XFCE session support, clipboard, redirected drives, and firewall
  - UFW state and default incoming policy

Throughput workflow:
  - setup-environment.sh starts a private iperf3 service on the server.
  - Peer setup automatically measures and rates the link.
  - Running this verifier on the peer repeats forward and reverse tests.
  - Running it on the server validates that the benchmark service is ready.

Options:
  --user <name>              Desktop/share account
  --xfer-dir <path>          Expected xfer folder (default: $XFER_ROOT)
  --share-name <name>        Expected SMB share name (default: $XFER_SHARE)
  --rdp-port <port>          Expected XRDP port (default: $XRDP_PORT)
  --skip-throughput          Validate components without running iperf3
  --duration <seconds>       Seconds per direction (default: $IPERF_DURATION)
  --parallel <streams>       Parallel TCP streams (default: $IPERF_PARALLEL)
  --target-gbps <value>      Required minimum in each direction (default: $IPERF_TARGET_GBPS)
  --no-color                 Disable ANSI colors
  -h, --help                 Show this help
USAGE
}

need_arg() {
  [ -n "${2:-}" ] || die "$1 requires a value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user)
      need_arg "$1" "${2:-}"
      TARGET_USER="$2"
      shift
      ;;
    --xfer-dir)
      need_arg "$1" "${2:-}"
      XFER_ROOT="$2"
      shift
      ;;
    --share-name)
      need_arg "$1" "${2:-}"
      XFER_SHARE="$2"
      shift
      ;;
    --rdp-port)
      need_arg "$1" "${2:-}"
      XRDP_PORT="$2"
      shift
      ;;
    --skip-throughput)
      IPERF_MODE=skip
      ;;
    --duration)
      need_arg "$1" "${2:-}"
      IPERF_DURATION="$2"
      shift
      ;;
    --parallel)
      need_arg "$1" "${2:-}"
      IPERF_PARALLEL="$2"
      shift
      ;;
    --target-gbps)
      need_arg "$1" "${2:-}"
      IPERF_TARGET_GBPS="$2"
      shift
      ;;
    --no-color)
      USE_COLOR=0
      BOLD=""
      RED=""
      GRN=""
      YLW=""
      BLU=""
      RST=""
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

[ "$EUID" -eq 0 ] || die "run this verifier with sudo"
[[ "$XRDP_PORT" =~ ^[0-9]+$ ]] || die "RDP port must be numeric"
[[ "$IPERF_DURATION" =~ ^[0-9]+$ ]] \
  && [ "$IPERF_DURATION" -ge 5 ] \
  && [ "$IPERF_DURATION" -le 120 ] \
  || die "iperf duration must be between 5 and 120 seconds"
[[ "$IPERF_PARALLEL" =~ ^[0-9]+$ ]] \
  && [ "$IPERF_PARALLEL" -ge 1 ] \
  && [ "$IPERF_PARALLEL" -le 32 ] \
  || die "parallel stream count must be between 1 and 32"
[[ "$IPERF_TARGET_GBPS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "target throughput must be numeric"

if [ "$IPERF_MODE" = "auto" ]; then
  case "$CLUSTER_ROLE" in
    server) IPERF_MODE=service ;;
    peer) IPERF_MODE=client ;;
    *) IPERF_MODE=skip ;;
  esac
fi

# =============================================================================
# 2. VERIFICATION HELPERS
# =============================================================================
check_command() {
  local command_name="$1"
  if command -v "$command_name" >/dev/null 2>&1; then
    pass "command available: $command_name"
  else
    fail "missing command: $command_name"
  fi
}

check_service_active() {
  local unit="$1"
  if systemctl is-active --quiet "$unit"; then
    pass "$unit is active"
  else
    fail "$unit is not active"
  fi
}

check_service_enabled() {
  local unit="$1"
  local state
  state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  case "$state" in
    enabled|enabled-runtime|static|indirect|generated|alias)
      pass "$unit is boot-persistent ($state)"
      ;;
    *)
      fail "$unit is not boot-persistent (state: ${state:-unknown})"
      ;;
  esac
}

check_file() {
  local path="$1"
  if [ -f "$path" ]; then
    pass "configuration present: $path"
  else
    fail "missing configuration: $path"
  fi
}

# =============================================================================
# 3. HOST MAINTENANCE
# =============================================================================
check_maintenance() {
  section "Host maintenance"

  check_command journalctl
  check_file /etc/systemd/journald.conf.d/10-qwen3d8-cluster.conf
  if grep -Eq '^[[:space:]]*SystemMaxUse=' /etc/systemd/journald.conf.d/10-qwen3d8-cluster.conf 2>/dev/null \
     && grep -Eq '^[[:space:]]*SystemKeepFree=' /etc/systemd/journald.conf.d/10-qwen3d8-cluster.conf 2>/dev/null; then
    pass "journald disk limits are configured"
  else
    fail "journald disk limits are incomplete"
  fi
  check_service_active systemd-journald

  check_command smartctl
  check_file /etc/smartd.conf
  if grep -Eq '^DEVICESCAN[[:space:]]+-a[[:space:]]+-W[[:space:]]' /etc/smartd.conf 2>/dev/null; then
    pass "managed smartd device scan is configured"
  else
    fail "managed smartd device scan is missing"
  fi
  local smart_unit=""
  for unit in smartd.service smartmontools.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      smart_unit="$unit"
      break
    fi
  done
  if [ -n "$smart_unit" ]; then
    check_service_enabled "$smart_unit"
    check_service_active "$smart_unit"
  else
    fail "no smartd service unit was found"
  fi

  check_service_enabled fstrim.timer
  check_service_active fstrim.timer

  if [ -f /etc/modprobe.d/qwen3d8-radios.conf ]; then
    pass "radio module blocks are configured"
  else
    warn "radio module blocks are not configured; Wi-Fi/Bluetooth may remain enabled"
  fi
  if systemctl cat bluetooth.service >/dev/null 2>&1; then
    local bluetooth_state
    bluetooth_state="$(systemctl is-enabled bluetooth.service 2>/dev/null || true)"
    if [ "$bluetooth_state" = "masked" ]; then
      pass "bluetooth.service is masked"
    else
      warn "bluetooth.service is not masked (state: ${bluetooth_state:-unknown})"
    fi
  fi
}

# =============================================================================
# 4. USB4 PRIVATE NETWORK
# =============================================================================
check_usb4() {
  section "USB4 private network"

  if [ -r "$USB4_ENV" ]; then
    pass "USB4 environment present: $USB4_ENV"
  else
    fail "missing $USB4_ENV"
  fi

  check_command ip
  check_command ethtool
  check_command boltctl
  check_command iperf3
  check_command jq
  check_command netplan

  check_file /etc/modules-load.d/qwen3d8-usb4.conf
  check_file /etc/systemd/network/70-qwen3d8-usb4.link
  check_file /etc/netplan/60-qwen3d8-usb4.yaml
  check_file /etc/udev/rules.d/60-qwen3d8-usb4-authorize.rules
  check_file /etc/sysctl.d/80-qwen3d8-usb4.conf
  check_file /usr/local/bin/usb4-cluster-status
  check_file /usr/local/bin/usb4-cluster-wait
  check_file /usr/local/bin/usb4-cluster-benchmark

  local module
  for module in thunderbolt thunderbolt_net; do
    if lsmod 2>/dev/null | awk '{print $1}' | grep -x "$module" >/dev/null \
       || [ -d "/sys/module/$module" ]; then
      pass "kernel module available: $module"
    else
      fail "kernel module unavailable: $module"
    fi
  done

  if [ -d /sys/bus/thunderbolt/devices/domain0 ]; then
    local security
    local iommu
    security="$(cat /sys/bus/thunderbolt/devices/domain0/security 2>/dev/null || echo unknown)"
    iommu="$(cat /sys/bus/thunderbolt/devices/domain0/iommu_dma_protection 2>/dev/null || echo unknown)"
    pass "USB4 domain detected; security=$security"
    if [ "$iommu" = "1" ]; then
      pass "IOMMU DMA protection is active"
    else
      warn "IOMMU DMA protection is not reported active ($iommu)"
    fi
  else
    fail "USB4 domain0 is not present"
  fi

  if [ -z "$CLUSTER_LOCAL_IP" ] || [ -z "$CLUSTER_PEER_IP" ]; then
    fail "cluster addresses are missing from $USB4_ENV"
    return
  fi

  if [ -d "/sys/class/net/$CLUSTER_IFACE" ]; then
    pass "USB4 interface exists: $CLUSTER_IFACE"
  else
    fail "USB4 interface does not exist: $CLUSTER_IFACE"
    return
  fi

  local driver
  driver="$(ethtool -i "$CLUSTER_IFACE" 2>/dev/null | awk -F': ' '$1=="driver"{print $2}')"
  case "$driver" in
    thunderbolt-net|thunderbolt_net)
      pass "$CLUSTER_IFACE uses driver $driver"
      ;;
    *)
      fail "$CLUSTER_IFACE uses unexpected driver '${driver:-unknown}'"
      ;;
  esac

  local operstate
  operstate="$(cat "/sys/class/net/$CLUSTER_IFACE/operstate" 2>/dev/null || echo unknown)"
  case "$operstate" in
    up) pass "$CLUSTER_IFACE carrier is up" ;;
    unknown) warn "$CLUSTER_IFACE reports operstate=unknown" ;;
    *) fail "$CLUSTER_IFACE carrier state is $operstate" ;;
  esac

  local actual_mtu
  actual_mtu="$(cat "/sys/class/net/$CLUSTER_IFACE/mtu" 2>/dev/null || echo 0)"
  if [ "$actual_mtu" = "$CLUSTER_MTU" ]; then
    pass "$CLUSTER_IFACE MTU is $actual_mtu"
  else
    fail "$CLUSTER_IFACE MTU is $actual_mtu; expected $CLUSTER_MTU"
  fi

  if ip -4 -o address show dev "$CLUSTER_IFACE" \
      | awk '{print $4}' \
      | grep -x "$CLUSTER_LOCAL_IP/$CLUSTER_CIDR" >/dev/null; then
    pass "$CLUSTER_IFACE has $CLUSTER_LOCAL_IP/$CLUSTER_CIDR"
  else
    fail "$CLUSTER_IFACE is missing $CLUSTER_LOCAL_IP/$CLUSTER_CIDR"
  fi

  if ip route show default dev "$CLUSTER_IFACE" | grep . >/dev/null; then
    fail "$CLUSTER_IFACE has a default route; the USB4 link must remain private"
  else
    pass "$CLUSTER_IFACE has no default route"
  fi

  local peer_route
  peer_route="$(ip route get "$CLUSTER_PEER_IP" 2>/dev/null || true)"
  if grep -E "dev[[:space:]]+$CLUSTER_IFACE([[:space:]]|$)" <<<"$peer_route" >/dev/null \
     && grep -E "src[[:space:]]+$CLUSTER_LOCAL_IP([[:space:]]|$)" <<<"$peer_route" >/dev/null; then
    pass "traffic to $CLUSTER_PEER_IP uses $CLUSTER_IFACE"
  else
    fail "route to $CLUSTER_PEER_IP is incorrect: ${peer_route:-missing}"
  fi

  if ping -c3 -W2 -n "$CLUSTER_PEER_IP" >/dev/null 2>&1; then
    pass "USB4 peer responds at $CLUSTER_PEER_IP"
  else
    fail "USB4 peer does not respond at $CLUSTER_PEER_IP"
  fi

  if netplan generate >/dev/null 2>&1; then
    pass "netplan configuration validates"
  else
    fail "netplan configuration does not validate"
  fi

  if grep -E "^$CLUSTER_LOCAL_IP[[:space:]]" /etc/hosts >/dev/null \
     && grep -E "^$CLUSTER_PEER_IP[[:space:]]" /etc/hosts >/dev/null; then
    pass "USB4 aliases are present in /etc/hosts"
  else
    fail "USB4 aliases are missing from /etc/hosts"
  fi

  local rmem
  local wmem
  rmem="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
  wmem="$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)"
  if [ "$rmem" -ge 134217728 ] && [ "$wmem" -ge 134217728 ]; then
    pass "USB4 TCP buffer ceilings are active"
  else
    warn "TCP buffer ceilings are lower than configured: rmem=$rmem wmem=$wmem"
  fi

  if [ "$CLUSTER_ROLE" = "server" ]; then
    check_file /etc/systemd/system/usb4-iperf3.service
    check_service_enabled usb4-iperf3.service
    check_service_active usb4-iperf3.service
    if ss -ltn 2>/dev/null | grep -F "$CLUSTER_LOCAL_IP:$IPERF_PORT" >/dev/null; then
      pass "private iperf3 service is listening on $CLUSTER_LOCAL_IP:$IPERF_PORT"
    else
      fail "private iperf3 service is not listening on $CLUSTER_LOCAL_IP:$IPERF_PORT"
    fi
  fi
}

# =============================================================================
# 5. WINDOWS FILE DROP OVER SMB
# =============================================================================
check_samba() {
  section "Windows xfer share"

  check_command testparm
  check_command smbclient
  check_file /etc/samba/smb.conf

  if grep 'qwen3d8-xfer BEGIN' /etc/samba/smb.conf >/dev/null 2>&1; then
    pass "managed xfer share block is present"
  else
    fail "managed xfer share block is missing"
  fi

  if testparm -s /etc/samba/smb.conf >/dev/null 2>&1; then
    pass "Samba configuration validates"
  else
    fail "Samba configuration is invalid"
  fi

  if [ -d "$XFER_ROOT" ]; then
    pass "xfer directory exists: $XFER_ROOT"
    local mode
    mode="$(stat -c '%a' "$XFER_ROOT" 2>/dev/null || echo unknown)"
    case "$mode" in
      2777|2775) pass "$XFER_ROOT mode is $mode" ;;
      *) warn "$XFER_ROOT mode is $mode; expected setgid writable permissions" ;;
    esac
  else
    fail "xfer directory is missing: $XFER_ROOT"
  fi

  local wsdd_unit=""
  for unit in wsdd.service wsdd2.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      wsdd_unit="$unit"
      break
    fi
  done

  check_service_active smbd.service
  check_service_enabled smbd.service
  if systemctl is-active --quiet nmbd.service; then
    pass "nmbd.service is active"
  elif [ -n "$wsdd_unit" ] && systemctl is-active --quiet "$wsdd_unit"; then
    warn "nmbd.service is inactive; $wsdd_unit provides Windows discovery instead"
    { systemctl status nmbd.service --no-pager -n 6 2>&1 || true; } \
      | sed 's/^/       /' | head -10 || true
  else
    fail "nmbd.service is not active and WS-Discovery is unavailable"
    { systemctl status nmbd.service --no-pager -n 6 2>&1 || true; } \
      | sed 's/^/       /' | head -10 || true
  fi
  check_service_enabled nmbd.service

  if ss -ltn 2>/dev/null | grep -E '[:.]445[[:space:]]' >/dev/null; then
    pass "SMB is listening on TCP 445"
  else
    fail "SMB is not listening on TCP 445"
  fi

  if smbclient "//127.0.0.1/$XFER_SHARE" -N -c 'ls' >/dev/null 2>&1; then
    pass "anonymous local access to //$XFER_SHARE succeeds"
  else
    fail "anonymous local access to //$XFER_SHARE failed"
  fi

  if [ -n "$wsdd_unit" ]; then
    if systemctl is-active --quiet "$wsdd_unit"; then
      pass "$wsdd_unit is active"
    else
      warn "$wsdd_unit exists but is not active"
    fi
  else
    warn "WS-Discovery is not installed; direct \\\\hostname\\$XFER_SHARE access can still work"
  fi
}

# =============================================================================
# 6. XRDP REMOTE DESKTOP
# =============================================================================
check_xrdp() {
  section "XRDP remote desktop"

  check_service_active xrdp.service
  check_service_enabled xrdp.service
  check_service_active xrdp-sesman.service
  check_service_enabled xrdp-sesman.service

  if dpkg -s xorgxrdp >/dev/null 2>&1; then
    pass "xorgxrdp package is installed"
  else
    fail "xorgxrdp package is not installed"
  fi

  if [ -x /usr/lib/xrdp/xrdp-chansrv ]; then
    pass "xrdp-chansrv is available"
  else
    fail "xrdp-chansrv is missing"
  fi

  if dpkg -s fuse3 >/dev/null 2>&1 && command -v fusermount3 >/dev/null 2>&1; then
    pass "FUSE 3 and fusermount3 are installed for redirected drives"
  else
    fail "FUSE 3 or fusermount3 is missing; redirected drives cannot mount"
  fi

  if [ -e /dev/fuse ]; then
    pass "/dev/fuse is available"
  else
    fail "/dev/fuse is unavailable; redirected drives cannot mount"
  fi

  if [ -n "$TARGET_USER" ] && id "$TARGET_USER" >/dev/null 2>&1; then
    pass "desktop account exists: $TARGET_USER"
    local user_home
    user_home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    if [ -x "$user_home/.xsession" ]; then
      pass "$TARGET_USER has an executable .xsession"
      if grep -E '^[[:space:]]*unset[[:space:]]+DBUS_SESSION_BUS_ADDRESS[[:space:]]*$' "$user_home/.xsession" >/dev/null \
         && grep -E '^[[:space:]]*dbus-launch[[:space:]]+--exit-with-session[[:space:]]+/usr/bin/startxfce4' "$user_home/.xsession" >/dev/null; then
        if grep -E '^[[:space:]]*unset[[:space:]]+XDG_RUNTIME_DIR[[:space:]]*$' "$user_home/.xsession" >/dev/null; then
          fail "XRDP XFCE session clears XDG_RUNTIME_DIR; rerun setup to preserve systemd user services"
        elif command -v dbus-launch >/dev/null 2>&1; then
          pass "XRDP XFCE session has an isolated D-Bus for local-session concurrency"
        else
          fail "dbus-launch is missing; the managed concurrent XFCE session cannot start"
        fi
      elif grep -E '/usr/bin/(startxfce4|xfce4-session)' "$user_home/.xsession" >/dev/null; then
        warn "XRDP XFCE session shares the user D-Bus; same-user local login may block XRDP"
      else
        warn "XRDP session does not use the managed XFCE D-Bus isolation"
      fi
    else
      fail "$TARGET_USER is missing an executable .xsession"
    fi

    local password_state
    password_state="$(passwd -S "$TARGET_USER" 2>/dev/null | awk '{print $2}')"
    if [ "$password_state" = "L" ]; then
      fail "$TARGET_USER is password-locked and cannot log in through XRDP"
    else
      pass "$TARGET_USER has an XRDP-usable password state"
    fi
  else
    fail "desktop account is missing: ${TARGET_USER:-unset}"
  fi

  if getent group fuse >/dev/null 2>&1; then
    if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -x fuse >/dev/null; then
      pass "$TARGET_USER belongs to fuse for redirected drives"
    else
      fail "$TARGET_USER is not in the fuse group; redirected drives may not mount"
    fi
  else
    warn "the fuse group is not present; redirected drives may not mount"
  fi
  check_file /etc/udev/rules.d/60-qwen3d8-fuse.rules

  if id -nG xrdp 2>/dev/null | tr ' ' '\n' | grep -x ssl-cert >/dev/null; then
    pass "xrdp service account belongs to ssl-cert"
  else
    fail "xrdp service account is not in ssl-cert"
  fi

  if dpkg -s dbus-user-session >/dev/null 2>&1; then
    warn "dbus-user-session is installed; GNOME and systemd user services can still limit same-user graphical sessions"
  else
    pass "dbus-user-session is not installed; per-session D-Bus mode is available"
  fi

  if [ -f /etc/X11/Xwrapper.config ]; then
    if grep -E '^allowed_users=anybody$' /etc/X11/Xwrapper.config >/dev/null \
       && grep -E '^needs_root_rights=no$' /etc/X11/Xwrapper.config >/dev/null; then
      pass "Xorg wrapper permits unprivileged XRDP sessions"
    else
      fail "Xorg wrapper settings are incomplete"
    fi
  else
    warn "Xwrapper.config is absent; this is valid only when xserver-xorg-legacy is not used"
  fi

  if grep -E '^[[:space:]]*allow_channels=true' /etc/xrdp/xrdp.ini >/dev/null \
     && grep -E '^[[:space:]]*rdpdr=true' /etc/xrdp/xrdp.ini >/dev/null \
     && grep -E '^[[:space:]]*cliprdr=true' /etc/xrdp/xrdp.ini >/dev/null; then
    pass "XRDP clipboard and redirected-drive channels are enabled"
  else
    fail "XRDP channel settings are incomplete"
  fi

  if grep -E '^[[:space:]]*RestrictInboundClipboard=none' /etc/xrdp/sesman.ini >/dev/null \
     && grep -E '^[[:space:]]*RestrictOutboundClipboard=none' /etc/xrdp/sesman.ini >/dev/null \
     && grep -E '^[[:space:]]*EnableFuseMount=true' /etc/xrdp/sesman.ini >/dev/null \
     && grep -E '^[[:space:]]*FuseMountName=thinclient_drives' /etc/xrdp/sesman.ini >/dev/null \
     && grep -E '^[[:space:]]*FileUmask=077' /etc/xrdp/sesman.ini >/dev/null; then
    pass "XRDP clipboard policy and drive mount are configured"
  else
    fail "XRDP sesman clipboard/drive settings are incomplete"
  fi

  if [ -f /etc/polkit-1/rules.d/49-xrdp-no-password-prompts.rules ]; then
    pass "XRDP polkit rule is installed"
  else
    fail "XRDP polkit rule is missing"
  fi

  if ss -ltn 2>/dev/null | grep -E "[:.]${XRDP_PORT}[[:space:]]" >/dev/null; then
    pass "XRDP is listening on TCP $XRDP_PORT"
  else
    fail "XRDP is not listening on TCP $XRDP_PORT"
  fi

  local boot_target
  boot_target="$(systemctl get-default 2>/dev/null || echo unknown)"
  case "$boot_target" in
    graphical.target|multi-user.target)
      pass "boot target is $boot_target"
      ;;
    *)
      warn "unexpected default boot target: $boot_target"
      ;;
  esac
}

# =============================================================================
# 7. FIREWALL
# =============================================================================
check_firewall() {
  section "Firewall"

  local ufw_status
  ufw_status="$(ufw status verbose 2>/dev/null || true)"
  if grep '^Status: active' <<<"$ufw_status" >/dev/null; then
    pass "UFW is active"
  else
    fail "UFW is not active"
    return
  fi

  if grep 'deny (incoming)' <<<"$ufw_status" >/dev/null; then
    pass "UFW default incoming policy is deny"
  else
    fail "UFW default incoming policy is not deny"
  fi

  if grep -E '^ENABLED=yes' /etc/ufw/ufw.conf >/dev/null 2>&1; then
    pass "UFW rules are configured to restore at boot"
  else
    fail "UFW is not marked enabled in /etc/ufw/ufw.conf"
  fi

  local rules
  rules="$(ufw status 2>/dev/null || true)"

  if grep -E "${XRDP_PORT}/tcp[[:space:]]+ALLOW([[:space:]]+IN)?[[:space:]]+(Anywhere|[0-9])" <<<"$rules" >/dev/null; then
    pass "UFW permits XRDP"
  else
    fail "UFW has no XRDP rule for TCP $XRDP_PORT"
  fi

  if grep -E '445/tcp[[:space:]]+ALLOW([[:space:]]+IN)?[[:space:]]+(Anywhere|[0-9])' <<<"$rules" >/dev/null; then
    pass "UFW permits SMB TCP 445"
  else
    fail "UFW has no SMB rule for TCP 445"
  fi

  if [ -n "$CLUSTER_PEER_IP" ]; then
    local escaped_peer
    escaped_peer="${CLUSTER_PEER_IP//./\\.}"
    if grep -E "${IPERF_PORT}/tcp on ${CLUSTER_IFACE}[[:space:]]+ALLOW([[:space:]]+IN)?[[:space:]]+${escaped_peer}" <<<"$rules" >/dev/null; then
      pass "UFW permits private iperf3 traffic on $CLUSTER_IFACE"
    else
      fail "UFW is missing the private iperf3 rule on $CLUSTER_IFACE"
    fi

    if [ "$CLUSTER_ROLE" = "peer" ]; then
      if grep -E "${RPC_PORT}/tcp on ${CLUSTER_IFACE}[[:space:]]+ALLOW([[:space:]]+IN)?[[:space:]]+${escaped_peer}" <<<"$rules" >/dev/null; then
        pass "UFW permits private RPC traffic on $CLUSTER_IFACE"
      else
        fail "UFW is missing the private RPC rule on $CLUSTER_IFACE"
      fi
    fi
  fi
}

# =============================================================================
# 8. USB4 THROUGHPUT
# =============================================================================
extract_receiver_bps() {
  local json="$1"

  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
data = json.load(sys.stdin)
value = data.get("end", {}).get("sum_received", {}).get("bits_per_second")
if value is None:
    raise SystemExit(1)
print(float(value))
' <<<"$json" 2>/dev/null
    return
  fi

  awk '
    /"sum_received"[[:space:]]*:/ { in_sum = 1; next }
    in_sum && /"bits_per_second"[[:space:]]*:/ {
      gsub(/[,"]/, "", $2)
      print $2
      exit
    }
    in_sum && /^[[:space:]]*}/ { in_sum = 0 }
  ' <<<"$json"
}

bps_to_gbps() {
  awk -v bps="$1" 'BEGIN { printf "%.3f", bps / 1000000000 }'
}

rate_throughput() {
  local gbps="$1"
  awk -v value="$gbps" -v target="$IPERF_TARGET_GBPS" 'BEGIN {
    if (value >= target) print "EXCELLENT - target met";
    else if (value >= 6.0) print "GOOD - below target";
    else if (value >= 3.0) print "MARGINAL";
    else print "POOR";
  }'
}

throughput_meets_target() {
  awk -v value="$1" -v target="$IPERF_TARGET_GBPS" 'BEGIN { exit !(value >= target) }'
}

run_iperf_direction() {
  local direction="$1"
  local reverse_flag=()
  local label
  local result
  local bps
  local gbps
  local rating

  if [ "$direction" = "reverse" ]; then
    reverse_flag=(-R)
    label="peer -> local"
  else
    label="local -> peer"
  fi

  if ! result="$(timeout $((IPERF_DURATION + 30)) \
      iperf3 \
      -c "$CLUSTER_PEER_IP" \
      -B "$CLUSTER_LOCAL_IP" \
      -p "$IPERF_PORT" \
      -P "$IPERF_PARALLEL" \
      -t "$IPERF_DURATION" \
      "${reverse_flag[@]}" \
      --json 2>&1)"; then
    fail "iperf3 $label test failed"
    printf '%s\n' "$result" | sed 's/^/       /' | head -20 || true
    return 1
  fi

  bps="$(extract_receiver_bps "$result" || true)"
  if [ -z "$bps" ]; then
    fail "could not parse iperf3 $label result"
    return 1
  fi

  gbps="$(bps_to_gbps "$bps")"
  rating="$(rate_throughput "$gbps")"
  echo "${BOLD}$label:${RST} $gbps Gbit/s - $rating"

  if throughput_meets_target "$gbps"; then
    pass "$label throughput meets the ${IPERF_TARGET_GBPS} Gbit/s target"
  else
    fail "$label throughput is below the ${IPERF_TARGET_GBPS} Gbit/s target"
  fi

  IPERF_LAST_GBPS="$gbps"
}

run_iperf_client() {
  section "USB4 throughput rating"

  if ! command -v iperf3 >/dev/null 2>&1; then
    fail "iperf3 is not installed"
    return
  fi
  if [ -z "$CLUSTER_LOCAL_IP" ] || [ -z "$CLUSTER_PEER_IP" ]; then
    fail "USB4 addresses are unavailable"
    return
  fi

  if ! ping -c2 -W2 -n "$CLUSTER_PEER_IP" >/dev/null 2>&1; then
    fail "peer $CLUSTER_PEER_IP is unreachable"
    return
  fi

  local forward_gbps=""
  local reverse_gbps=""

  IPERF_LAST_GBPS=""
  run_iperf_direction forward || true
  forward_gbps="$IPERF_LAST_GBPS"

  IPERF_LAST_GBPS=""
  run_iperf_direction reverse || true
  reverse_gbps="$IPERF_LAST_GBPS"

  if [ -n "$forward_gbps" ] && [ -n "$reverse_gbps" ]; then
    local minimum
    minimum="$(awk -v a="$forward_gbps" -v b="$reverse_gbps" 'BEGIN { print (a < b ? a : b) }')"
    echo
    echo "${BOLD}Overall USB4 rating:${RST} $(rate_throughput "$minimum")"
    echo "  minimum direction: $minimum Gbit/s"
    echo "  plan target:       >= $IPERF_TARGET_GBPS Gbit/s"
  fi
}

# =============================================================================
# 9. RUN CHECKS AND REPORT
# =============================================================================
echo "${BOLD}Environment verification on $(hostname -s 2>/dev/null || hostname)${RST}"
echo "  USB4 role:       ${CLUSTER_ROLE:-unknown}"
echo "  USB4 interface:  $CLUSTER_IFACE"
echo "  USB4 local/peer: ${CLUSTER_LOCAL_IP:-unset} / ${CLUSTER_PEER_IP:-unset}"
echo "  Throughput mode: $IPERF_MODE"

check_maintenance
check_usb4
check_samba
check_xrdp
check_firewall

case "$IPERF_MODE" in
  service)
    section "USB4 throughput rating"
    pass "benchmark service is ready; run this verifier on the peer to rate the link"
    ;;
  client)
    run_iperf_client
    ;;
  skip)
    section "USB4 throughput rating"
    warn "throughput test skipped"
    ;;
esac

echo
echo "${BOLD}Verification summary${RST}"
echo "  passed:   $PASSES"
echo "  warnings: $WARNINGS"
echo "  failed:   $FAILURES"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
exit 0

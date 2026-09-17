#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || true)}}"
TARGET_PASSWORD="${CLUSTER_USER_PASSWORD:-}"
TARGET_PASSWORD_FILE="${TARGET_PASSWORD_FILE:-}"

INSTALL_SAMBA="${INSTALL_SAMBA:-1}"
INSTALL_XRDP="${INSTALL_XRDP:-1}"
INSTALL_SSH="${INSTALL_SSH:-1}"
INSTALL_USB4="${INSTALL_USB4:-1}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-1}"
CONFIGURE_JOURNAL="${CONFIGURE_JOURNAL:-1}"
JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-2G}"
JOURNAL_KEEP_FREE="${JOURNAL_KEEP_FREE:-1G}"
CONFIGURE_DISK_HEALTH="${CONFIGURE_DISK_HEALTH:-1}"
SMART_TEMP_LIMITS="${SMART_TEMP_LIMITS:-4,65,75}"
SMART_ALERT_EMAIL="${SMART_ALERT_EMAIL:-}"
DISABLE_WIFI="${DISABLE_WIFI:-1}"
DISABLE_BLUETOOTH="${DISABLE_BLUETOOTH:-1}"
RADIO_DISABLE_FORCE="${RADIO_DISABLE_FORCE:-0}"
WIFI_BLOCK_MODULES="${WIFI_BLOCK_MODULES:-cfg80211 mac80211}"
BT_BLOCK_MODULES="${BT_BLOCK_MODULES:-bluetooth btusb btintel btmtk btrtl bnep rfcomm}"

NODE_ROLE="${NODE_ROLE:-}"
CLUSTER_IFACE="${CLUSTER_IFACE:-usb4llm0}"
CLUSTER_NET="${CLUSTER_NET:-10.200.0}"
CLUSTER_CIDR=30
CLUSTER_MTU="${CLUSTER_MTU:-1500}"
CLUSTER_AUTO_AUTHORIZE="${CLUSTER_AUTO_AUTHORIZE:-1}"
CLUSTER_TUNE_SYSCTL="${CLUSTER_TUNE_SYSCTL:-1}"
RPC_PORT="${RPC_PORT:-50053}"
IPERF_PORT="${IPERF_PORT:-5201}"

XFER_ROOT="${XFER_ROOT:-/srv/xfer}"
XFER_SHARE="${XFER_SHARE:-xfer}"
XFER_GROUP="${XFER_GROUP:-}"
SAMBA_WORKGROUP="${SAMBA_WORKGROUP:-WORKGROUP}"
SAMBA_DISCOVERY="${SAMBA_DISCOVERY:-1}"

XRDP_PORT="${XRDP_PORT:-3389}"
XRDP_DESKTOP="${XRDP_DESKTOP:-xfce}"
XRDP_ISOLATE_DBUS="${XRDP_ISOLATE_DBUS:-1}"
XRDP_CONCURRENT_LOCAL_ACTIVE=0
DESKTOP_HEADLESS_BOOT="${DESKTOP_HEADLESS_BOOT:-0}"
XFCE_COMPOSITING="${XFCE_COMPOSITING:-0}"

LAN_NETS="${LAN_NETS:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"

BOLD=$'\e[1m'
RED=$'\e[31m'
GRN=$'\e[32m'
YLW=$'\e[33m'
BLU=$'\e[34m'
RST=$'\e[0m'

log()  { echo "${BLU}${BOLD}==>${RST} ${BOLD}$*${RST}"; }
ok()   { echo "${GRN}  ok:${RST} $*"; }
info() { echo "${BLU} info:${RST} $*"; }
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
Usage: sudo bash $SCRIPT_NAME [options]

Installs only:
  - A private USB4 TCP/IP link between the two cluster nodes
  - A per-node Windows file drop at \\\\<host>\\$XFER_SHARE
  - XRDP remote desktop support
  - OpenSSH server for remote administration
  - Interface-scoped firewall rules for USB4, SMB, RDP, and SSH
  - Journald caps, SMART monitoring, and periodic SSD TRIM
  - Software disablement of Wi-Fi and Bluetooth radios

Options:
  --role <server|peer>        This node: server/controller (.1) or peer/worker (.2)
  --cluster-net <a.b.c>       First three octets (default: $CLUSTER_NET)
  --cluster-iface <name>      Stable USB4 interface name (default: $CLUSTER_IFACE)
  --cluster-mtu <bytes>       USB4 MTU on both nodes (default: $CLUSTER_MTU)
  --rpc-port <port>           Private ggml RPC port (default: $RPC_PORT)
  --no-usb4-auto-authorize   Require manual USB4 peer authorization
  --no-usb4-tuning          Do not install private-link TCP tuning
  --user <name>              Desktop/share owner (default: invoking sudo user)
  --password <value>         Create the user or replace its password
  --password-file <path>     Read the password from the first line of a file
  --xfer-dir <path>          Shared folder (default: $XFER_ROOT)
  --share-name <name>        Windows share name (default: $XFER_SHARE)
  --xfer-group <name>        Group assigned to files copied into the share
  --workgroup <name>         SMB workgroup (default: $SAMBA_WORKGROUP)
  --no-samba-discovery       Do not install WS-Discovery support
  --desktop <value>          xfce, auto, or an absolute session path
  --rdp-port <port>          XRDP listen port (default: $XRDP_PORT)
  --no-concurrent-local      Do not isolate XFCE's D-Bus from a local same-user session
  --headless-boot            Boot to text mode; desktop starts only over RDP
  --graphical-boot           Boot to a local graphical login
  --xfce-compositing         Leave the XFCE compositor enabled
  --lan-nets "<cidrs>"       Space-separated networks allowed through UFW
  --journal-max <size>       Persistent journald cap (default: $JOURNAL_MAX_USE)
  --smart-email <address>    Send SMART alerts to this address; requires mail transport
  --keep-radios              Leave Wi-Fi and Bluetooth enabled
  --force-radio-disable      Disable Wi-Fi even if it carries the default route
  --skip <component>         Skip journal, diskhealth, radios, wifi, bluetooth,
                             usb4, samba, xrdp, ssh, or firewall
  -h, --help                 Show this help

Run the server role first. It starts a private iperf3 listener. When the peer
role is installed afterward, it automatically measures and rates USB4 throughput.

All settings can also be supplied through the matching environment variables.
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
    --cluster-net)
      need_arg "$1" "${2:-}"
      CLUSTER_NET="$2"
      shift
      ;;
    --cluster-iface)
      need_arg "$1" "${2:-}"
      CLUSTER_IFACE="$2"
      shift
      ;;
    --cluster-mtu)
      need_arg "$1" "${2:-}"
      CLUSTER_MTU="$2"
      shift
      ;;
    --rpc-port)
      need_arg "$1" "${2:-}"
      RPC_PORT="$2"
      shift
      ;;
    --no-usb4-auto-authorize)
      CLUSTER_AUTO_AUTHORIZE=0
      ;;
    --no-usb4-tuning)
      CLUSTER_TUNE_SYSCTL=0
      ;;
    --user)
      need_arg "$1" "${2:-}"
      TARGET_USER="$2"
      shift
      ;;
    --password)
      need_arg "$1" "${2:-}"
      TARGET_PASSWORD="$2"
      shift
      ;;
    --password-file)
      need_arg "$1" "${2:-}"
      TARGET_PASSWORD_FILE="$2"
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
    --xfer-group)
      need_arg "$1" "${2:-}"
      XFER_GROUP="$2"
      shift
      ;;
    --workgroup)
      need_arg "$1" "${2:-}"
      SAMBA_WORKGROUP="$2"
      shift
      ;;
    --no-samba-discovery)
      SAMBA_DISCOVERY=0
      ;;
    --desktop)
      need_arg "$1" "${2:-}"
      XRDP_DESKTOP="$2"
      shift
      ;;
    --rdp-port)
      need_arg "$1" "${2:-}"
      XRDP_PORT="$2"
      shift
      ;;
    --no-concurrent-local)
      XRDP_ISOLATE_DBUS=0
      ;;
    --headless-boot)
      DESKTOP_HEADLESS_BOOT=1
      ;;
    --graphical-boot)
      DESKTOP_HEADLESS_BOOT=0
      ;;
    --xfce-compositing)
      XFCE_COMPOSITING=1
      ;;
    --lan-nets)
      need_arg "$1" "${2:-}"
      LAN_NETS="$2"
      shift
      ;;
    --journal-max)
      need_arg "$1" "${2:-}"
      JOURNAL_MAX_USE="$2"
      shift
      ;;
    --smart-email)
      need_arg "$1" "${2:-}"
      SMART_ALERT_EMAIL="$2"
      shift
      ;;
    --keep-radios)
      DISABLE_WIFI=0
      DISABLE_BLUETOOTH=0
      ;;
    --force-radio-disable)
      RADIO_DISABLE_FORCE=1
      ;;
    --skip)
      need_arg "$1" "${2:-}"
      case "$2" in
        journal) CONFIGURE_JOURNAL=0 ;;
        diskhealth|smart) CONFIGURE_DISK_HEALTH=0 ;;
        radios) DISABLE_WIFI=0; DISABLE_BLUETOOTH=0 ;;
        wifi) DISABLE_WIFI=0 ;;
        bluetooth) DISABLE_BLUETOOTH=0 ;;
        usb4|cluster) INSTALL_USB4=0 ;;
        samba|smb|xfer) INSTALL_SAMBA=0 ;;
        xrdp|rdp|desktop) INSTALL_XRDP=0 ;;
        ssh|sshd) INSTALL_SSH=0 ;;
        firewall|ufw) CONFIGURE_FIREWALL=0 ;;
        *) die "unknown component for --skip: $2" ;;
      esac
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

[ "$EUID" -eq 0 ] || die "run this script as root, for example: sudo bash $SCRIPT_NAME"
command -v apt-get >/dev/null 2>&1 || die "this installer requires an apt-based Linux distribution"
command -v systemctl >/dev/null 2>&1 || die "this installer requires systemd"
[[ "$JOURNAL_MAX_USE" =~ ^[0-9]+[KMGTkmgt]?$ ]] \
  || die "--journal-max '$JOURNAL_MAX_USE' must be a size like 2G, 512M, or 2048K"
[[ "$JOURNAL_KEEP_FREE" =~ ^[0-9]+[KMGTkmgt]?$ ]] \
  || die "JOURNAL_KEEP_FREE '$JOURNAL_KEEP_FREE' must be a size like 1G"
[[ "$SMART_TEMP_LIMITS" =~ ^[0-9]+,[0-9]+,[0-9]+$ ]] \
  || die "SMART_TEMP_LIMITS must be 'diff,info,crit' in degrees C, for example 4,65,75"
[[ "$SMART_ALERT_EMAIL" =~ ^([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})?$ ]] \
  || die "--smart-email '$SMART_ALERT_EMAIL' does not look like an email address"
for radio_setting in "$DISABLE_WIFI" "$DISABLE_BLUETOOTH" "$RADIO_DISABLE_FORCE"; do
  case "$radio_setting" in
    0|1) ;;
    *) die "radio settings must be 0 or 1" ;;
  esac
done
for radio_module in $WIFI_BLOCK_MODULES $BT_BLOCK_MODULES; do
  [[ "$radio_module" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "invalid radio kernel module name: $radio_module"
done

if [ -n "$TARGET_PASSWORD_FILE" ]; then
  [ -r "$TARGET_PASSWORD_FILE" ] || die "password file '$TARGET_PASSWORD_FILE' is not readable"
  TARGET_PASSWORD="$(head -n1 "$TARGET_PASSWORD_FILE")"
fi

[ -n "$TARGET_USER" ] || die "could not determine the desktop user; pass --user <name>"
[ "$TARGET_USER" != "root" ] || die "--user must name an unprivileged account"
[[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "invalid account name: $TARGET_USER"
[[ "$XFER_SHARE" =~ ^[A-Za-z0-9._-]+$ ]] || die "share name may contain only letters, numbers, '.', '_', and '-'"
[[ "$XRDP_PORT" =~ ^[0-9]+$ ]] || die "RDP port must be numeric"
[ "$XRDP_PORT" -ge 1 ] && [ "$XRDP_PORT" -le 65535 ] || die "RDP port must be between 1 and 65535"
case "$XRDP_ISOLATE_DBUS" in
  0|1) ;;
  *) die "XRDP_ISOLATE_DBUS must be 0 or 1" ;;
esac

if [ "$INSTALL_USB4" = "1" ]; then
  if [ -z "$NODE_ROLE" ] && [ -r /etc/default/usb4-cluster ]; then
    NODE_ROLE="$(awk -F= '$1=="CLUSTER_ROLE"{print $2}' /etc/default/usb4-cluster)"
  fi
  case "$NODE_ROLE" in
    server|controller|head|a) NODE_ROLE=server ;;
    peer|worker|b) NODE_ROLE=peer ;;
    *) die "USB4 setup requires --role server or --role peer" ;;
  esac
  [[ "$CLUSTER_NET" =~ ^([0-9]{1,3}[.]){2}[0-9]{1,3}$ ]] \
    || die "--cluster-net must contain the first three octets, for example 10.200.0"
  [[ "$CLUSTER_IFACE" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]] \
    || die "invalid USB4 interface name: $CLUSTER_IFACE"
  [[ "$CLUSTER_MTU" =~ ^[0-9]+$ ]] \
    && [ "$CLUSTER_MTU" -ge 1280 ] \
    && [ "$CLUSTER_MTU" -le 65520 ] \
    || die "USB4 MTU must be between 1280 and 65520"
  for port in "$RPC_PORT" "$IPERF_PORT"; do
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
      || die "invalid USB4 service port: $port"
  done
  case "$CLUSTER_AUTO_AUTHORIZE:$CLUSTER_TUNE_SYSCTL" in
    0:0|0:1|1:0|1:1) ;;
    *) die "USB4 authorization and tuning settings must be 0 or 1" ;;
  esac

  CLUSTER_SERVER_IP="${CLUSTER_NET}.1"
  CLUSTER_WORKER_IP="${CLUSTER_NET}.2"
  if [ "$NODE_ROLE" = "server" ]; then
    CLUSTER_LOCAL_IP="$CLUSTER_SERVER_IP"
    CLUSTER_PEER_IP="$CLUSTER_WORKER_IP"
  else
    CLUSTER_LOCAL_IP="$CLUSTER_WORKER_IP"
    CLUSTER_PEER_IP="$CLUSTER_SERVER_IP"
  fi
fi

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  [ -n "$TARGET_PASSWORD" ] || die "user '$TARGET_USER' does not exist; create it first or supply --password/--password-file"
  adduser --disabled-password --gecos "" "$TARGET_USER" >/dev/null 2>&1 \
    || useradd -m -s /bin/bash "$TARGET_USER" \
    || die "could not create account '$TARGET_USER'"
  printf '%s:%s\n' "$TARGET_USER" "$TARGET_PASSWORD" | chpasswd
  usermod -aG sudo "$TARGET_USER" >/dev/null 2>&1 || true
  ok "created account '$TARGET_USER' with a login password"
elif [ -n "$TARGET_PASSWORD" ]; then
  printf '%s:%s\n' "$TARGET_USER" "$TARGET_PASSWORD" | chpasswd
  ok "updated the login password for '$TARGET_USER'"
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$USER_HOME" ] && [ -d "$USER_HOME" ] || die "home directory for '$TARGET_USER' was not found"

if [ -z "$XFER_GROUP" ]; then
  XFER_GROUP="$(id -gn "$TARGET_USER")"
elif ! getent group "$XFER_GROUP" >/dev/null 2>&1; then
  groupadd "$XFER_GROUP"
  ok "created xfer group '$XFER_GROUP'"
fi
usermod -aG "$XFER_GROUP" "$TARGET_USER" >/dev/null 2>&1 || true

MY_HOST="$(hostname -s 2>/dev/null || hostname)"
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
[ -n "$LAN_IP" ] || LAN_IP="$MY_HOST"

if passwd_status="$(passwd -S "$TARGET_USER" 2>/dev/null)" && [[ "$passwd_status" =~ ^[^[:space:]]+[[:space:]]+L ]]; then
  warn "account '$TARGET_USER' is password-locked; XRDP login requires a password"
  note_action "Set an XRDP login password for '$TARGET_USER': sudo passwd $TARGET_USER"
fi

# =============================================================================
# 2. HOST MAINTENANCE AND HARDENING
# =============================================================================
# =============================================================================
# 2a. CAP SYSTEMD-JOURNALD DISK USAGE
# =============================================================================
configure_journal() {
  log "Capping systemd-journald disk usage at $JOURNAL_MAX_USE"

  local journal_conf=/etc/systemd/journald.conf.d/10-qwen3d8-cluster.conf
  local journal_tmp
  local journal_usage

  install -d -m 0755 "$(dirname "$journal_conf")"
  journal_tmp="$(mktemp)"
  cat > "$journal_tmp" <<JOURNAL
# Managed by $SCRIPT_NAME
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=$JOURNAL_MAX_USE
SystemKeepFree=$JOURNAL_KEEP_FREE
RuntimeMaxUse=256M
JOURNAL

  if [ -f "$journal_conf" ] && cmp -s "$journal_tmp" "$journal_conf"; then
    ok "$journal_conf already up to date"
  elif install -m 0644 "$journal_tmp" "$journal_conf"; then
    ok "$journal_conf written (SystemMaxUse=$JOURNAL_MAX_USE, SystemKeepFree=$JOURNAL_KEEP_FREE)"
    if systemctl restart systemd-journald >/dev/null 2>&1; then
      ok "systemd-journald restarted"
    else
      warn "could not restart systemd-journald; the cap applies from the next boot"
      note_action "Restart journald with: sudo systemctl restart systemd-journald"
    fi
  else
    warn "could not write $journal_conf - the journal is still uncapped"
    note_action "Could not write $journal_conf. Journald has no size limit on this node."
  fi
  rm -f "$journal_tmp"

  if command -v journalctl >/dev/null 2>&1; then
    if journalctl --vacuum-size="$JOURNAL_MAX_USE" >/dev/null 2>&1; then
      journal_usage="$(journalctl --disk-usage 2>/dev/null \
        | grep -oE '[0-9]+([.][0-9]+)?[KMGTP]' | head -n1 || true)"
      [ -n "$journal_usage" ] && ok "journal currently occupies ${journal_usage}B"
    else
      warn "could not vacuum existing journal entries"
      note_action "Trim current logs with: sudo journalctl --vacuum-size=$JOURNAL_MAX_USE"
    fi
  else
    warn "journalctl is unavailable; existing journal entries were not vacuumed"
    note_action "Install systemd journal tools and run: sudo journalctl --vacuum-size=$JOURNAL_MAX_USE"
  fi
}

# =============================================================================
# 2b. SMART MONITORING AND PERIODIC TRIM
# =============================================================================
configure_disk_health() {
  log "Enabling SMART monitoring and periodic TRIM"

  if ! apt-get install -y smartmontools >/dev/null 2>&1; then
    warn "could not install smartmontools - drive failures will go unnoticed"
    note_action "Install SMART monitoring with: sudo apt-get install smartmontools"
    return 0
  fi
  ok "smartmontools installed"

  local smart_conf=/etc/smartd.conf
  local smart_backup=/etc/smartd.conf.qwen3d8-cluster-orig
  local smart_tmp
  local smart_mail=""
  local smartd_unit=""
  local smartd_state=""
  local unit

  if [ -f "$smart_conf" ] && [ ! -f "$smart_backup" ]; then
    cp -a "$smart_conf" "$smart_backup" \
      || die "could not preserve the packaged SMART configuration at $smart_backup"
  fi

  if [ -n "$SMART_ALERT_EMAIL" ]; then
    smart_mail=" -m $SMART_ALERT_EMAIL -M exec /usr/share/smartmontools/smartd-runner"
  fi

  smart_tmp="$(mktemp)"
  cat > "$smart_tmp" <<SMART
# Managed by $SCRIPT_NAME
# The packaged original is kept at $smart_backup when one exists.
#
# DEVICESCAN includes NVMe and SATA devices added later.
# -a monitors health, error logs, and self-test logs.
# -W diff,info,crit reports temperature changes and thresholds.
# Alerts are sent to the journal${SMART_ALERT_EMAIL:+ and $SMART_ALERT_EMAIL}.
DEVICESCAN -a -W $SMART_TEMP_LIMITS$smart_mail
SMART

  # smartd -q onecheck performs live device checks, so a warm or unsupported
  # drive would look like a configuration error. Service startup below validates
  # the installed configuration and restores the packaged file if it fails.
  if [ -f "$smart_conf" ] && cmp -s "$smart_tmp" "$smart_conf"; then
    ok "$smart_conf already up to date"
  elif install -m 0644 "$smart_tmp" "$smart_conf"; then
    ok "$smart_conf written (temperature limits $SMART_TEMP_LIMITS C)"
  else
    warn "could not write $smart_conf; smartd keeps its packaged configuration"
    note_action "Could not write $smart_conf. Inspect permissions and rerun the installer."
    rm -f "$smart_tmp"
    return 0
  fi
  rm -f "$smart_tmp"

  for unit in smartd.service smartmontools.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      smartd_unit="$unit"
      break
    fi
  done

  if [ -n "$smartd_unit" ]; then
    smartd_state="$(systemctl is-enabled "$smartd_unit" 2>/dev/null || true)"
    case "$smartd_state" in
      enabled|enabled-runtime|static|indirect|generated|alias)
        ok "$smartd_unit is boot-persistent ($smartd_state)"
        ;;
      *)
        if systemctl enable "$smartd_unit" >/dev/null 2>&1 \
           && smartd_state="$(systemctl is-enabled "$smartd_unit" 2>/dev/null || true)" \
           && [[ "$smartd_state" =~ ^(enabled|enabled-runtime|static|indirect|generated|alias)$ ]]; then
          ok "$smartd_unit is boot-persistent ($smartd_state)"
        else
          warn "$smartd_unit could not be configured for boot (state: ${smartd_state:-unknown})"
          note_action "Configure SMART monitoring for boot with: sudo systemctl enable $smartd_unit"
        fi
        ;;
    esac

    if systemctl restart "$smartd_unit" >/dev/null 2>&1 \
       && systemctl is-active --quiet "$smartd_unit"; then
      ok "$smartd_unit active - supported drives are monitored continuously"
    else
      warn "$smartd_unit did not start with the generated configuration"
      if [ -f "$smart_backup" ]; then
        install -m 0644 "$smart_backup" "$smart_conf"
        if systemctl restart "$smartd_unit" >/dev/null 2>&1 \
           && systemctl is-active --quiet "$smartd_unit"; then
          warn "restored the packaged SMART configuration"
        fi
      fi
      note_action "Inspect SMART monitoring with: sudo journalctl -u $smartd_unit -n 50"
    fi
  else
    warn "no smartd service unit was found"
    note_action "Inspect the installed smartmontools package before enabling SMART monitoring."
  fi

  local device
  local smart_transport
  local smart_removable
  local smart_output
  local smart_used
  local smart_temp
  local disk_count=0

  if command -v lsblk >/dev/null 2>&1 && command -v smartctl >/dev/null 2>&1; then
    while IFS= read -r device; do
      [ -n "$device" ] || continue
      disk_count=$((disk_count + 1))
      smart_transport="$(lsblk -dno TRAN "$device" 2>/dev/null | tr -d '[:space:]' || true)"
      smart_removable="$(lsblk -dno RM "$device" 2>/dev/null | tr -d '[:space:]' || true)"

      if [ "$smart_transport" = "usb" ] || [ "$smart_removable" = "1" ]; then
        info "skipping $device (${smart_transport:-removable} media - SMART is not exposed reliably)"
        continue
      fi

      smart_output="$(smartctl -H -A "$device" 2>/dev/null || true)"
      if [ -z "$smart_output" ]; then
        info "$device did not return SMART data"
        continue
      fi

      if grep -Ei 'overall-health.*PASSED|SMART Health Status: *OK' <<<"$smart_output" >/dev/null; then
        smart_used="$(awk -F: '/Percentage Used/{gsub(/[^0-9]/,"",$2); print $2; exit}' <<<"$smart_output")"
        smart_temp="$(awk -F: '/^Temperature:/{gsub(/[^0-9]/,"",$2); print $2; exit}' <<<"$smart_output")"
        ok "SMART OK: $device${smart_used:+  ${smart_used}% of rated endurance used}${smart_temp:+  ${smart_temp} C}"
      elif grep -Ei 'SMART support is: *(Unavailable|Disabled)|does not support SMART|Unknown USB bridge|Operation not supported|Unable to detect device type' \
             <<<"$smart_output" >/dev/null; then
        info "$device does not expose SMART - nothing to monitor on it"
      else
        warn "$device did not report a healthy SMART status - inspect it with smartctl"
        note_action "SMART health for $device is not 'PASSED'. Run: sudo smartctl -a $device"
      fi
    done < <(lsblk -dno NAME,TYPE 2>/dev/null \
      | awk '$2=="disk"{print "/dev/"$1}' || true)
  else
    warn "lsblk or smartctl is unavailable; immediate SMART health checks were skipped"
    note_action "Install disk tools with: sudo apt-get install smartmontools util-linux"
  fi

  [ "$disk_count" -gt 0 ] || info "no block disks were found for an immediate SMART health readout"

  # Use the weekly timer rather than continuous discard, which adds latency to deletes.
  local trim_description
  if systemctl enable --now fstrim.timer >/dev/null 2>&1 \
     && systemctl is-enabled fstrim.timer >/dev/null 2>&1; then
    trim_description="$(systemctl show -p Description --value fstrim.timer 2>/dev/null || true)"
    [ -n "$trim_description" ] || trim_description="periodic TRIM"
    ok "fstrim.timer enabled ($trim_description)"
  else
    warn "could not enable fstrim.timer - SSD write performance may decay over time"
    note_action "Enable periodic TRIM with: sudo systemctl enable --now fstrim.timer"
  fi
}

# =============================================================================
# 2c. DISABLE WI-FI AND BLUETOOTH CONTROLLERS
# =============================================================================
configure_radios() {
  [ "$DISABLE_WIFI" = "1" ] || [ "$DISABLE_BLUETOOTH" = "1" ] || return 0

  log "Disabling Wi-Fi and Bluetooth controllers"

  local default_if
  local radio_conf=/etc/modprobe.d/qwen3d8-radios.conf
  local radio_tmp
  local radio_module
  local radio_module_list=()
  local radio_modules=()
  local wifi_left=0
  local bluetooth_left=0
  local path
  local i
  local disabled_radio_summary=""

  default_if="$(ip -4 route show default 2>/dev/null \
    | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' || true)"
  if [ "$DISABLE_WIFI" = "1" ] \
     && [ -n "$default_if" ] \
     && { [ -e "/sys/class/net/$default_if/phy80211" ] \
          || [ -d "/sys/class/net/$default_if/wireless" ]; } \
     && [ "$RADIO_DISABLE_FORCE" != "1" ]; then
    warn "this node's default route runs over wireless interface '$default_if'"
    warn "Wi-Fi will remain enabled to avoid stranding the installation"
    warn "Move to Ethernet and rerun, or use --force-radio-disable"
    note_action "Wi-Fi was not disabled because '$default_if' is the active default route"
    DISABLE_WIFI=0
  fi

  if [ "$DISABLE_WIFI" = "1" ]; then
    read -r -a radio_module_list <<< "$WIFI_BLOCK_MODULES"
    radio_modules+=("${radio_module_list[@]}")
  fi
  if [ "$DISABLE_BLUETOOTH" = "1" ]; then
    read -r -a radio_module_list <<< "$BT_BLOCK_MODULES"
    radio_modules+=("${radio_module_list[@]}")
  fi

  if [ "${#radio_modules[@]}" -eq 0 ]; then
    info "no radio modules selected for disablement"
    return 0
  fi

  if [ "${#radio_modules[@]}" -gt 0 ]; then
    if ! apt-get install -y kmod rfkill >/dev/null 2>&1; then
      warn "could not install kmod/rfkill; persistent module rules will still be attempted"
      note_action "Install radio controls with: sudo apt-get install kmod rfkill"
    fi

    install -d -m 0755 /etc/modprobe.d
    radio_tmp="$(mktemp)"
    {
      echo "# Managed by $SCRIPT_NAME"
      echo "# Wi-Fi and Bluetooth are disabled for this wired/USB4 cluster."
      echo "# Remove this file and run 'sudo update-initramfs -u' to restore loading."
      for radio_module in "${radio_modules[@]}"; do
        echo "install $radio_module /bin/false"
      done
    } > "$radio_tmp"

    if [ -f "$radio_conf" ] && cmp -s "$radio_tmp" "$radio_conf"; then
      ok "$radio_conf already up to date"
    elif install -m 0644 "$radio_tmp" "$radio_conf"; then
      ok "$radio_conf written: ${radio_modules[*]}"
      if command -v update-initramfs >/dev/null 2>&1; then
        if update-initramfs -u >/dev/null 2>&1; then
          ok "initramfs rebuilt with radio module blocks"
        else
          warn "update-initramfs failed; radio modules may still load early at boot"
          note_action "Rebuild the initramfs with: sudo update-initramfs -u"
        fi
      else
        warn "update-initramfs is unavailable; radio module blocks apply on the next module load"
        note_action "Install initramfs tools and run: sudo update-initramfs -u"
      fi
    else
      warn "could not write $radio_conf; radio modules remain loadable"
      note_action "Could not write $radio_conf. Inspect permissions and rerun the installer."
    fi
    rm -f "$radio_tmp"
  fi

  if [ "$DISABLE_BLUETOOTH" = "1" ] \
     && systemctl cat bluetooth.service >/dev/null 2>&1; then
    if systemctl disable --now bluetooth.service >/dev/null 2>&1; then
      ok "bluetooth.service disabled"
    else
      warn "bluetooth.service could not be stopped and disabled"
      note_action "Disable Bluetooth with: sudo systemctl disable --now bluetooth.service"
    fi
    if systemctl mask bluetooth.service >/dev/null 2>&1; then
      ok "bluetooth.service masked"
    else
      warn "bluetooth.service could not be masked"
      note_action "Mask Bluetooth with: sudo systemctl mask bluetooth.service"
    fi
  elif [ "$DISABLE_BLUETOOTH" = "1" ]; then
    info "bluetooth.service is not installed"
  fi

  if [ "$DISABLE_WIFI" = "1" ] \
     && systemctl is-active --quiet NetworkManager 2>/dev/null \
     && command -v nmcli >/dev/null 2>&1; then
    if nmcli radio wifi off >/dev/null 2>&1; then
      ok "NetworkManager Wi-Fi radio disabled"
    else
      warn "NetworkManager could not disable the Wi-Fi radio"
      note_action "Disable Wi-Fi with: sudo nmcli radio wifi off"
    fi
  fi

  if command -v rfkill >/dev/null 2>&1; then
    if [ "$DISABLE_WIFI" = "1" ]; then
      if rfkill block wifi >/dev/null 2>&1; then
        ok "Wi-Fi blocked with rfkill"
      else
        warn "rfkill could not block Wi-Fi"
        note_action "Block Wi-Fi with: sudo rfkill block wifi"
      fi
    fi
    if [ "$DISABLE_BLUETOOTH" = "1" ]; then
      if rfkill block bluetooth >/dev/null 2>&1; then
        ok "Bluetooth blocked with rfkill"
      else
        warn "rfkill could not block Bluetooth"
        note_action "Block Bluetooth with: sudo rfkill block bluetooth"
      fi
    fi
  fi

  if command -v lsmod >/dev/null 2>&1 && command -v modprobe >/dev/null 2>&1; then
    for ((i=${#radio_modules[@]} - 1; i>=0; i--)); do
      radio_module="${radio_modules[$i]}"
      if lsmod 2>/dev/null | awk '{print $1}' | grep -x "$radio_module" >/dev/null; then
        modprobe -r "$radio_module" >/dev/null 2>&1 || true
      fi
    done
  fi

  for path in /sys/class/net/*; do
    [ -e "$path/phy80211" ] && wifi_left=1
  done
  for path in /sys/class/bluetooth/hci*; do
    [ -e "$path" ] && bluetooth_left=1
  done

  if [ "$DISABLE_WIFI" = "1" ]; then
    if [ "$wifi_left" = "0" ]; then
      ok "no 802.11 interface is present"
    else
      warn "a Wi-Fi interface is still present; it should disappear after reboot"
    fi
  fi
  if [ "$DISABLE_BLUETOOTH" = "1" ]; then
    if [ "$bluetooth_left" = "0" ]; then
      ok "no Bluetooth controller is present"
    else
      warn "a Bluetooth controller is still registered; it should disappear after reboot"
    fi
  fi
  [ "$DISABLE_WIFI" = "1" ] && disabled_radio_summary="Wi-Fi"
  if [ "$DISABLE_BLUETOOTH" = "1" ]; then
    [ -n "$disabled_radio_summary" ] && disabled_radio_summary="$disabled_radio_summary, "
    disabled_radio_summary="${disabled_radio_summary}Bluetooth"
  fi
  note_action "$disabled_radio_summary are disabled in software; disable WLAN and Bluetooth in BIOS if permanent hardware-level disablement is required"
}

export DEBIAN_FRONTEND=noninteractive
if [ "$CONFIGURE_JOURNAL" = "1" ]; then
  configure_journal
  echo
fi
log "Refreshing apt package metadata"
apt-get update -y

if [ "$CONFIGURE_DISK_HEALTH" = "1" ]; then
  configure_disk_health
  echo
fi

if [ "$DISABLE_WIFI" = "1" ] || [ "$DISABLE_BLUETOOTH" = "1" ]; then
  configure_radios
  echo
fi

# =============================================================================
# 3. USB4 PRIVATE NETWORK
# =============================================================================
configure_usb4() {
  log "Configuring USB4 private TCP/IP: $CLUSTER_LOCAL_IP/$CLUSTER_CIDR on $CLUSTER_IFACE"

  apt-get install -y \
    bolt ethtool iperf3 iproute2 jq kmod netplan.io udev \
    || die "failed to install USB4 networking prerequisites"

  if command -v boltctl >/dev/null 2>&1; then
    if systemctl cat bolt.service >/dev/null 2>&1; then
      ensure_boot_unit bolt.service
      systemctl start bolt.service >/dev/null 2>&1 || true
    fi
    ok "bolt and boltctl installed for USB4 authorization"
  else
    warn "boltctl is unavailable; non-XDomain USB4 peers may require manual authorization"
  fi

  cat > /etc/modules-load.d/qwen3d8-usb4.conf <<MODULES
# Managed by $SCRIPT_NAME
thunderbolt
thunderbolt_net
MODULES

  modprobe thunderbolt >/dev/null 2>&1 || true
  if modprobe thunderbolt_net >/dev/null 2>&1 || [ -d /sys/module/thunderbolt_net ]; then
    ok "thunderbolt_net loaded and configured for boot"
  else
    warn "thunderbolt_net could not be loaded; verify the current kernel provides it"
    note_action "After updating the kernel if needed, run: sudo modprobe thunderbolt_net"
  fi

  install -d -m 0755 /etc/systemd/network
  cat > /etc/systemd/network/70-qwen3d8-usb4.link <<LINK
# Managed by $SCRIPT_NAME
[Match]
Driver=thunderbolt-net thunderbolt_net

[Link]
Name=$CLUSTER_IFACE
LINK
  udevadm control --reload-rules >/dev/null 2>&1 || true
  ok "USB4 Ethernet interface will use the stable name '$CLUSTER_IFACE'"

  find_usb4_iface() {
    local path
    local driver
    for path in /sys/class/net/*; do
      [ -e "$path" ] || continue
      driver="$(basename "$(readlink -f "$path/device/driver" 2>/dev/null)" 2>/dev/null || true)"
      case "$driver" in
        thunderbolt-net|thunderbolt_net)
          basename "$path"
          return 0
          ;;
      esac
    done
    return 1
  }

  local current_iface=""
  current_iface="$(find_usb4_iface || true)"
  if [ -n "$current_iface" ] && [ "$current_iface" != "$CLUSTER_IFACE" ]; then
    ip link set "$current_iface" down >/dev/null 2>&1 || true
    if ip link set "$current_iface" name "$CLUSTER_IFACE" >/dev/null 2>&1; then
      current_iface="$CLUSTER_IFACE"
      ok "renamed the live USB4 interface to $CLUSTER_IFACE"
    else
      warn "the live interface could not be renamed; the stable name applies after reboot"
    fi
  elif [ "$current_iface" = "$CLUSTER_IFACE" ]; then
    ok "USB4 interface is already named $CLUSTER_IFACE"
  else
    warn "no thunderbolt-net interface is present yet; connect and power both nodes"
  fi

  local security_level
  local iommu_protection
  security_level="$(cat /sys/bus/thunderbolt/devices/domain0/security 2>/dev/null || true)"
  iommu_protection="$(cat /sys/bus/thunderbolt/devices/domain0/iommu_dma_protection 2>/dev/null || true)"
  if [ -n "$security_level" ]; then
    ok "USB4 security level: $security_level; IOMMU DMA protection: ${iommu_protection:-unknown}"
  else
    warn "the USB4 host controller is not visible under /sys/bus/thunderbolt"
    note_action "Check firmware and BIOS USB4 support with: dmesg | grep -iE 'thunderbolt|ucsi'"
  fi

  if [ "$CLUSTER_AUTO_AUTHORIZE" = "1" ]; then
    cat > /etc/udev/rules.d/60-qwen3d8-usb4-authorize.rules <<UDEV
# Managed by $SCRIPT_NAME
# Authorize peers automatically only when the kernel reports IOMMU DMA protection.
ACTION=="add", SUBSYSTEM=="thunderbolt", ATTRS{iommu_dma_protection}=="1", ATTR{authorized}=="0", ATTR{authorized}="1"
UDEV
    udevadm control --reload-rules >/dev/null 2>&1 || true
    ok "persistent USB4 authorization enabled when IOMMU DMA protection is active"

    local device
    local uuid
    local authorized
    local seen=0
    local trusted=0
    local xdomain=0
    shopt -s nullglob
    for device in /sys/bus/thunderbolt/devices/[0-9]*-[0-9]*; do
      [ -d "$device" ] || continue
      case "${device##*/}" in
        *-0) continue ;;
      esac

      uuid="$(cat "$device/unique_id" 2>/dev/null || true)"
      [ -n "$uuid" ] || continue

      if [ ! -e "$device/authorized" ]; then
        xdomain=$((xdomain + 1))
        continue
      fi

      seen=$((seen + 1))
      authorized="$(cat "$device/authorized" 2>/dev/null || true)"
      if [ "$authorized" = "0" ]; then
        echo 1 > "$device/authorized" 2>/dev/null || true
        authorized="$(cat "$device/authorized" 2>/dev/null || true)"
      fi

      if command -v boltctl >/dev/null 2>&1 \
         && boltctl enroll --policy auto "$uuid" >/dev/null 2>&1; then
        trusted=$((trusted + 1))
      elif [ "$authorized" = "1" ]; then
        trusted=$((trusted + 1))
      fi
    done
    shopt -u nullglob

    if [ "$xdomain" -gt 0 ]; then
      ok "$xdomain USB4 host-to-host XDomain link(s) detected"
    fi
    if [ "$seen" -gt 0 ] && [ "$trusted" -eq "$seen" ]; then
      ok "$trusted USB4 peer device(s) authorized"
    elif [ "$seen" -gt 0 ]; then
      warn "only $trusted of $seen USB4 peer devices could be authorized"
      note_action "Inspect authorization with: sudo boltctl list"
    fi
  else
    warn "automatic USB4 authorization is disabled"
  fi

  install -d -m 0755 /etc/netplan
  local renderer=networkd
  if systemctl is-active --quiet NetworkManager 2>/dev/null \
     && ! systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    renderer=NetworkManager
  fi
  if [ "$renderer" = "NetworkManager" ]; then
    ensure_boot_unit NetworkManager.service
  else
    ensure_boot_unit systemd-networkd.service
    systemctl start systemd-networkd.service >/dev/null 2>&1 || true
  fi

  local netplan_file=/etc/netplan/60-qwen3d8-usb4.yaml
  local netplan_backup=""
  local netplan_temp
  if [ -f "$netplan_file" ]; then
    netplan_backup="$(mktemp)"
    cp -a "$netplan_file" "$netplan_backup"
  fi
  netplan_temp="$(mktemp /etc/netplan/.qwen3d8-usb4.XXXXXX)"

  cat > "$netplan_temp" <<NETPLAN
# Managed by $SCRIPT_NAME
# Private point-to-point link: no gateway, DNS, DHCP, RA, or link-local address.
network:
  version: 2
  ethernets:
    $CLUSTER_IFACE:
      renderer: $renderer
      match:
        name: $CLUSTER_IFACE
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
      optional: true
      mtu: $CLUSTER_MTU
      addresses:
        - $CLUSTER_LOCAL_IP/$CLUSTER_CIDR
NETPLAN
  chmod 0600 "$netplan_temp"
  mv -f "$netplan_temp" "$netplan_file"

  if netplan generate >/dev/null 2>&1; then
    if [ "$renderer" = "NetworkManager" ]; then
      nmcli connection reload >/dev/null 2>&1 || true
    else
      networkctl reload >/dev/null 2>&1 \
        || systemctl reload systemd-networkd >/dev/null 2>&1 \
        || true
    fi
    ok "netplan configured $CLUSTER_LOCAL_IP/$CLUSTER_CIDR without a default route"
  else
    warn "netplan rejected $netplan_file; restoring the previous configuration"
    netplan generate 2>&1 | sed 's/^/       /' || true
    if [ -n "$netplan_backup" ]; then
      cp -a "$netplan_backup" "$netplan_file"
    else
      rm -f "$netplan_file"
    fi
    rm -f "$netplan_backup"
    netplan generate >/dev/null 2>&1 || true
    die "USB4 netplan configuration was not installed"
  fi
  [ -n "$netplan_backup" ] && rm -f "$netplan_backup"

  current_iface="$(find_usb4_iface || true)"
  if [ -n "$current_iface" ]; then
    if [ "$current_iface" != "$CLUSTER_IFACE" ]; then
      warn "the interface is still named '$current_iface'; reboot to apply '$CLUSTER_IFACE'"
    else
      ip link set "$CLUSTER_IFACE" down >/dev/null 2>&1 || true
      ip -4 address flush dev "$CLUSTER_IFACE" scope global >/dev/null 2>&1 || true
      ip link set "$CLUSTER_IFACE" mtu "$CLUSTER_MTU"
      ip address add "$CLUSTER_LOCAL_IP/$CLUSTER_CIDR" dev "$CLUSTER_IFACE"
      ip link set "$CLUSTER_IFACE" up
      ok "live USB4 address applied to $CLUSTER_IFACE"
    fi
  fi

  sed -i '/^# >>> qwen3d8-usb4/,/^# <<< qwen3d8-usb4/d' /etc/hosts
  cat >> /etc/hosts <<HOSTS
# >>> qwen3d8-usb4 (managed by $SCRIPT_NAME) >>>
$CLUSTER_SERVER_IP   usb4-controller usb4-server
$CLUSTER_WORKER_IP   usb4-worker usb4-peer
# <<< qwen3d8-usb4 <<<
HOSTS

  if [ "$CLUSTER_TUNE_SYSCTL" = "1" ]; then
    cat > /etc/sysctl.d/80-qwen3d8-usb4.conf <<SYSCTL
# Managed by $SCRIPT_NAME
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 131072 134217728
net.ipv4.tcp_wmem = 4096 131072 134217728
net.core.netdev_max_backlog = 16384
net.core.default_qdisc = fq
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
SYSCTL
    sysctl -p /etc/sysctl.d/80-qwen3d8-usb4.conf >/dev/null 2>&1 \
      && ok "TCP buffer and queue limits tuned for USB4" \
      || warn "USB4 TCP tuning will apply after reboot"
  fi

  cat > /etc/default/usb4-cluster <<USB4ENV
# Managed by $SCRIPT_NAME
CLUSTER_ROLE=$NODE_ROLE
CLUSTER_IFACE=$CLUSTER_IFACE
CLUSTER_LOCAL_IP=$CLUSTER_LOCAL_IP
CLUSTER_PEER_IP=$CLUSTER_PEER_IP
CLUSTER_SERVER_IP=$CLUSTER_SERVER_IP
CLUSTER_WORKER_IP=$CLUSTER_WORKER_IP
CLUSTER_CIDR=$CLUSTER_CIDR
CLUSTER_MTU=$CLUSTER_MTU
RPC_PORT=$RPC_PORT
IPERF_PORT=$IPERF_PORT
USB4ENV
  chmod 0644 /etc/default/usb4-cluster

  cat > /usr/local/bin/usb4-cluster-status <<'STATUS'
#!/usr/bin/env bash
set -uo pipefail

[ -r /etc/default/usb4-cluster ] && . /etc/default/usb4-cluster
IFACE="${CLUSTER_IFACE:-usb4llm0}"

echo "== role and addresses =="
echo "  role=${CLUSTER_ROLE:-?} local=${CLUSTER_LOCAL_IP:-?} peer=${CLUSTER_PEER_IP:-?}"

echo "== modules =="
for module in thunderbolt thunderbolt_net; do
  if lsmod 2>/dev/null | awk '{print $1}' | grep -x "$module" >/dev/null; then
    echo "  loaded: $module"
  elif [ -d "/sys/module/$module" ]; then
    echo "  builtin: $module"
  else
    echo "  missing: $module"
  fi
done

echo "== USB4 domains =="
shopt -s nullglob
for domain in /sys/bus/thunderbolt/devices/domain*; do
  echo "  $(basename "$domain"): security=$(cat "$domain/security" 2>/dev/null || echo ?)" \
       "iommu=$(cat "$domain/iommu_dma_protection" 2>/dev/null || echo ?)"
done

echo "== interface =="
real_iface=""
for path in /sys/class/net/*; do
  driver="$(basename "$(readlink -f "$path/device/driver" 2>/dev/null)" 2>/dev/null || true)"
  case "$driver" in
    thunderbolt-net|thunderbolt_net) real_iface="$(basename "$path")" ;;
  esac
done
if [ -n "$real_iface" ]; then
  ip -br address show "$real_iface" 2>/dev/null | sed 's/^/  /'
  echo "  mtu=$(cat "/sys/class/net/$real_iface/mtu" 2>/dev/null || echo ?)"
  [ "$real_iface" = "$IFACE" ] || echo "  expected interface name: $IFACE"
else
  echo "  no thunderbolt-net interface"
fi

echo "== peer =="
if ping -c2 -W2 -n "${CLUSTER_PEER_IP:-}" >/dev/null 2>&1; then
  echo "  reachable: $CLUSTER_PEER_IP"
  if [ "${CLUSTER_ROLE:-}" = "peer" ]; then
    echo "  benchmark: sudo usb4-cluster-benchmark"
  else
    echo "  benchmark service: ${CLUSTER_SERVER_IP:-?}:${IPERF_PORT:-5201}"
    echo "  run usb4-cluster-benchmark on the peer"
  fi
else
  echo "  unreachable: ${CLUSTER_PEER_IP:-unset}"
fi
STATUS
  chmod 0755 /usr/local/bin/usb4-cluster-status

  cat > /usr/local/bin/usb4-cluster-wait <<'WAIT'
#!/usr/bin/env bash
set -uo pipefail

[ -r /etc/default/usb4-cluster ] && . /etc/default/usb4-cluster
TARGET="${1:-${CLUSTER_PEER_IP:-}}"
TIMEOUT="${2:-120}"
[ -n "$TARGET" ] || exit 0

end=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$end" ]; do
  if ping -c1 -W1 -n "$TARGET" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 2
done
exit 0
WAIT
  chmod 0755 /usr/local/bin/usb4-cluster-wait

  cat > /usr/local/bin/usb4-cluster-benchmark <<'BENCHMARK'
#!/usr/bin/env bash
set -uo pipefail

[ -r /etc/default/usb4-cluster ] && . /etc/default/usb4-cluster

TARGET="${1:-}"
DURATION="${2:-30}"
STREAMS="${3:-4}"
TARGET_GBPS="${4:-8.0}"

[ -n "${CLUSTER_LOCAL_IP:-}" ] || { echo "USB4 local address is not configured" >&2; exit 2; }
[ -n "$TARGET" ] || {
  if [ "${CLUSTER_ROLE:-}" = "peer" ]; then
    TARGET="${CLUSTER_SERVER_IP:-}"
  else
    echo "Run this benchmark on the peer, or pass an explicit remote iperf3 server address." >&2
    exit 2
  fi
}
[ -n "$TARGET" ] || { echo "USB4 benchmark target is not configured" >&2; exit 2; }
command -v iperf3 >/dev/null 2>&1 || { echo "iperf3 is not installed" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is not installed" >&2; exit 2; }

result=""
for attempt in $(seq 1 15); do
  if result="$(timeout $((DURATION + 30)) iperf3 \
      -c "$TARGET" \
      -B "$CLUSTER_LOCAL_IP" \
      -p "${IPERF_PORT:-5201}" \
      -P "$STREAMS" \
      -t "$DURATION" \
      --json 2>&1)"; then
    break
  fi
  result=""
  sleep 2
done

if [ -z "$result" ]; then
  echo "USB4 benchmark could not connect to $TARGET:${IPERF_PORT:-5201}" >&2
  exit 2
fi

bps="$(jq -er '.end.sum_received.bits_per_second' <<<"$result" 2>/dev/null || true)"
if [ -z "$bps" ] || [ "$bps" = "null" ]; then
  echo "USB4 benchmark could not parse the iperf3 result" >&2
  exit 2
fi

gbps="$(awk -v bps="$bps" 'BEGIN { printf "%.3f", bps / 1000000000 }')"
rating="$(awk -v value="$gbps" -v target="$TARGET_GBPS" 'BEGIN {
  if (value >= target) print "EXCELLENT - target met";
  else if (value >= 6.0) print "GOOD - below target";
  else if (value >= 3.0) print "MARGINAL";
  else print "POOR";
}')"

echo "USB4 throughput: $gbps Gbit/s"
echo "Rating:          $rating"
echo "Target:          >= $TARGET_GBPS Gbit/s"

awk -v value="$gbps" -v target="$TARGET_GBPS" 'BEGIN { exit !(value >= target) }'
BENCHMARK
  chmod 0755 /usr/local/bin/usb4-cluster-benchmark

  systemctl disable --now iperf3.service >/dev/null 2>&1 || true
  if [ "$NODE_ROLE" = "server" ]; then
    cat > /etc/systemd/system/usb4-iperf3.service <<IPERFUNIT
[Unit]
Description=USB4 private-link iperf3 benchmark server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/iperf3 -s -B $CLUSTER_SERVER_IP -p $IPERF_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
IPERFUNIT
    systemctl daemon-reload
    ensure_boot_unit usb4-iperf3.service
    systemctl restart usb4-iperf3.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet usb4-iperf3.service; then
      ok "private iperf3 benchmark service is ready on $CLUSTER_SERVER_IP:$IPERF_PORT"
    else
      warn "iperf3 benchmark service is waiting for the USB4 address to become available"
    fi
  else
    systemctl disable --now usb4-iperf3.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/usb4-iperf3.service
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  if ping -c2 -W2 -n "$CLUSTER_PEER_IP" >/dev/null 2>&1; then
    ok "USB4 peer $CLUSTER_PEER_IP is reachable"
    if [ "$NODE_ROLE" = "peer" ]; then
      log "Measuring USB4 throughput against $CLUSTER_SERVER_IP"
      if /usr/local/bin/usb4-cluster-benchmark "$CLUSTER_SERVER_IP" 30 4 8.0; then
        ok "USB4 throughput meets the plan target"
      else
        warn "USB4 throughput is below target or the server benchmark service is unavailable"
        note_action "Re-run the timing test with: sudo usb4-cluster-benchmark $CLUSTER_SERVER_IP"
      fi
    fi
  else
    warn "USB4 peer $CLUSTER_PEER_IP is not reachable yet"
    warn "USB4 link validation will complete automatically when the peer is configured and connected"
  fi
}

# =============================================================================
# 4. WINDOWS FILE DROP OVER SMB  (\\this-node\xfer)
# =============================================================================
SAMBA_DISCOVERY_ON=0

configure_samba() {
  # This is a per-node maintenance drop for Windows clients. Keep it separate
  # from model and ComfyUI/NFS storage so an SMB client cannot modify shared
  # inference data by accident.
  log "Setting up the '$XFER_SHARE' Windows file share at $XFER_ROOT"

  apt-get install -y samba samba-common-bin smbclient \
    || die "failed to install Samba; use --skip samba to leave the share out"
  ok "Samba $(dpkg-query -W -f='${Version}' samba 2>/dev/null) installed"

  install -d -m 2777 "$XFER_ROOT"
  chown "$TARGET_USER:$XFER_GROUP" "$XFER_ROOT"
  chmod 2777 "$XFER_ROOT"
  ok "$XFER_ROOT ready as $TARGET_USER:$XFER_GROUP"

  xfer_free="$(df -h --output=avail "$XFER_ROOT" 2>/dev/null | tail -n1 | tr -d ' ' || true)"
  xfer_fs="$(findmnt -no TARGET -T "$XFER_ROOT" 2>/dev/null || echo /)"
  if [ -n "$xfer_free" ]; then
    log "  $XFER_ROOT is on $xfer_fs with $xfer_free available (transfer folder, not model storage)"
  fi

  local smb_conf=/etc/samba/smb.conf
  local smb_tmp
  install -d -m 0755 "$(dirname "$smb_conf")"
  [ -f "$smb_conf" ] || printf '[global]\n' > "$smb_conf"
  [ -f "${smb_conf}.qwen3d8-cluster-orig" ] || cp -a "$smb_conf" "${smb_conf}.qwen3d8-cluster-orig"

  smb_tmp="$(mktemp)"
  sed '/qwen3d8-xfer BEGIN/,/qwen3d8-xfer END/d' "$smb_conf" > "$smb_tmp"
  {
    echo
    echo "# ==== qwen3d8-xfer BEGIN - managed by $SCRIPT_NAME, edits here are lost ===="
    cat <<SMBCONF
[global]
   workgroup = $SAMBA_WORKGROUP
   server string = $MY_HOST (Qwen3.8 cluster node)
   server min protocol = SMB2
   client min protocol = SMB2
   map to guest = Bad User
   guest account = $TARGET_USER
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes

[$XFER_SHARE]
   comment = Maintenance file drop on $MY_HOST (Windows <-> Linux)
   path = $XFER_ROOT
   browseable = yes
   read only = no
   guest ok = yes
   guest only = yes
   force user = $TARGET_USER
   force group = $XFER_GROUP
   create mask = 0664
   force create mode = 0664
   directory mask = 2775
   force directory mode = 2775
SMBCONF
    echo "# ==== qwen3d8-xfer END ===="
  } >> "$smb_tmp"

  if testparm -s "$smb_tmp" >/dev/null 2>&1; then
    install -m 0644 "$smb_tmp" "$smb_conf"
    ok "validated [$XFER_SHARE] -> $XFER_ROOT in $smb_conf"
  else
    warn "generated Samba configuration failed validation; $smb_conf was not changed"
    { testparm -s "$smb_tmp" 2>&1 || true; } | sed 's/^/       /' | head -20 || true
    rm -f "$smb_tmp"
    return 1
  fi
  rm -f "$smb_tmp"

  ensure_boot_unit smbd.service
  ensure_boot_unit nmbd.service
  if systemctl restart smbd.service >/dev/null 2>&1; then
    ok "smbd running"
  else
    warn "smbd did not start; recent service output:"
    { systemctl status smbd.service --no-pager -n 8 2>&1 || true; } \
      | sed 's/^/       /' | head -12 || true
    die "smbd did not start; inspect: systemctl status smbd"
  fi

  if systemctl restart nmbd.service >/dev/null 2>&1; then
    ok "nmbd running; \\\\$MY_HOST resolves through NetBIOS"
  else
    warn "nmbd did not start; use \\\\$LAN_IP\\$XFER_SHARE from Windows"
    { systemctl status nmbd.service --no-pager -n 6 2>&1 || true; } \
      | sed 's/^/       /' | head -10 || true
    note_action "Investigate NetBIOS name service: systemctl status nmbd"
  fi

  if [ "$SAMBA_DISCOVERY" = "1" ]; then
    configure_wsdd
  fi

  if smb_probe="$(smbclient "//127.0.0.1/$XFER_SHARE" -N -c 'ls' 2>&1)"; then
    ok "local anonymous SMB self-test passed"
  else
    warn "the share failed its local anonymous self-test:"
    printf '%s\n' "$smb_probe" | sed 's/^/       /' | head -8 || true
    note_action "Check the share with: sudo smbclient //127.0.0.1/$XFER_SHARE -N"
  fi
}

configure_wsdd() {
  if ! apt-get install -y wsdd >/dev/null 2>&1; then
    warn "wsdd is unavailable; the share still works by hostname or IP"
    return 0
  fi

  local wsdd_unit=""
  local wsdd_cands
  local wsdd_c
  local wsdd_bin=""
  local wsdd_b
  local wsdd_p

  wsdd_cands="$({ dpkg -L wsdd wsdd2 2>/dev/null || true; } \
    | grep -E '/systemd/system/[^/]+\.service$' || true)"
  wsdd_cands="$wsdd_cands
$({ systemctl list-unit-files 'wsdd*.service' --no-legend 2>/dev/null || true; } | awk '{print $1}')"

  for wsdd_c in $wsdd_cands wsdd.service wsdd2.service; do
    wsdd_c="${wsdd_c##*/}"
    if systemctl cat "$wsdd_c" >/dev/null 2>&1; then
      wsdd_unit="$wsdd_c"
      break
    fi
  done

  if [ -z "$wsdd_unit" ]; then
    for wsdd_b in wsdd wsdd2 /usr/sbin/wsdd /usr/sbin/wsdd2; do
      wsdd_p="$(command -v "$wsdd_b" 2>/dev/null || true)"
      if [ -n "$wsdd_p" ] && [ -x "$wsdd_p" ]; then
        wsdd_bin="$wsdd_p"
        break
      fi
    done

    if [ -n "$wsdd_bin" ] && { "$wsdd_bin" --help 2>&1 || true; } | grep -- '--shortlog' >/dev/null; then
      cat > /etc/systemd/system/wsdd.service <<UNIT
[Unit]
Description=Web Services Dynamic Discovery host daemon
Documentation=https://github.com/christgau/wsdd
After=network-online.target smbd.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/wsdd
ExecStart=${wsdd_bin} --shortlog \$WSDD_PARAMS
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload
      wsdd_unit=wsdd.service
      ok "created a wsdd systemd unit because the package did not provide one"
    fi
  fi

  if [ -z "$wsdd_unit" ]; then
    warn "wsdd has no usable systemd unit; \\\\$MY_HOST\\$XFER_SHARE still works directly"
    return 0
  fi

  if ! systemctl enable "$wsdd_unit" >/dev/null 2>&1; then
    warn "$wsdd_unit could not be enabled for boot"
    note_action "Enable Windows network discovery with: sudo systemctl enable $wsdd_unit"
  fi
  systemctl restart "$wsdd_unit" >/dev/null 2>&1 || true
  if systemctl is-active "$wsdd_unit" >/dev/null 2>&1; then
    SAMBA_DISCOVERY_ON=1
    ok "$wsdd_unit running; $MY_HOST can appear under Network in Windows Explorer"
  else
    warn "$wsdd_unit is installed but not running"
    { systemctl status "$wsdd_unit" --no-pager -n 6 2>&1 || true; } \
      | sed 's/^/       /' | head -10 || true
    note_action "Investigate Windows network discovery: systemctl status $wsdd_unit"
  fi
}

set_ini_value() {
  local file="$1"
  local section="$2"
  local key="$3"
  local value="$4"

  [ -f "$file" ] || return 1

  if grep -qE "^[[:space:]]*${key}=" "$file"; then
    sed -i -E "0,/^[[:space:]]*${key}=.*/s|^[[:space:]]*${key}=.*|${key}=${value}|" "$file"
  elif grep -qE "^\[${section}\]" "$file"; then
    sed -i -E "0,/^\[${section}\]/s|^\[${section}\]|[${section}]\\n${key}=${value}|" "$file"
  else
    printf '\n[%s]\n%s=%s\n' "$section" "$key" "$value" >> "$file"
  fi
}

# =============================================================================
# 5. XRDP REMOTE DESKTOP
# =============================================================================
configure_xrdp() {
  log "Installing XRDP remote desktop on port $XRDP_PORT"

  local xrdp_session_bin=""
  local xrdp_xsession
  local xsession_name=""
  local dm_unit=""
  local dm_unit_path=""
  local as_file
  local current_target
  local user_xfwm
  local chansrv_expected=/usr/lib/xrdp/xrdp-chansrv
  local chansrv_source=""
  local chansrv
  local session_file

  case "$XRDP_DESKTOP" in
    auto)
      for session_file in \
          /usr/bin/xfce4-session \
          /usr/bin/gnome-session \
          /usr/bin/startplasma-x11 \
          /usr/bin/mate-session \
          /usr/bin/cinnamon-session \
          /usr/bin/lxqt-session; do
        if [ -x "$session_file" ]; then
          xrdp_session_bin="$session_file"
          break
        fi
      done
      ;;
    xfce|xfce4)
      ;;
    /*)
      xrdp_session_bin="$XRDP_DESKTOP"
      ;;
    *)
      die "XRDP_DESKTOP must be 'auto', 'xfce', or an absolute session path"
      ;;
  esac

  if [ -z "$xrdp_session_bin" ] || [ ! -x "$xrdp_session_bin" ]; then
    apt-get install -y xfce4 xfce4-terminal dbus-x11 x11-xserver-utils \
      || die "failed to install XFCE"
    xrdp_session_bin=/usr/bin/xfce4-session
    ok "XFCE desktop installed"
  else
    ok "reusing desktop session $xrdp_session_bin"
  fi

  apt-get install -y xrdp xorgxrdp fuse3 libfuse2t64 dbus-x11 polkitd pkexec accountsservice \
    || die "failed to install XRDP"
  ok "XRDP $(dpkg-query -W -f='${Version}' xrdp 2>/dev/null) installed"

  if ! getent group fuse >/dev/null 2>&1; then
    groupadd --system fuse || die "could not create the fuse group"
    ok "created the fuse group"
  fi
  usermod -aG fuse "$TARGET_USER" \
    || die "could not add $TARGET_USER to the fuse group"
  ok "$TARGET_USER added to fuse for XRDP drive and file redirection"

  install -d -m 0755 /etc/udev/rules.d
  cat > /etc/udev/rules.d/60-qwen3d8-fuse.rules <<FUSE
# Managed by $SCRIPT_NAME
KERNEL=="fuse", GROUP="fuse", MODE="0660"
FUSE
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules >/dev/null 2>&1 || true
    udevadm trigger --sysname-match=fuse >/dev/null 2>&1 || true
  fi
  if [ -e /dev/fuse ]; then
    chgrp fuse /dev/fuse
    chmod 0660 /dev/fuse
    ok "/dev/fuse is available to the fuse group"
  else
    modprobe fuse >/dev/null 2>&1 || true
    if [ -e /dev/fuse ]; then
      chgrp fuse /dev/fuse
      chmod 0660 /dev/fuse
      ok "/dev/fuse loaded and is available to the fuse group"
    else
      die "/dev/fuse is unavailable; XRDP drive and file redirection cannot work"
    fi
  fi

  for chansrv in \
      "$chansrv_expected" \
      /usr/libexec/xrdp/xrdp-chansrv \
      /usr/local/sbin/xrdp-chansrv \
      /usr/sbin/xrdp-chansrv \
      /sbin/xrdp-chansrv; do
    if [ -x "$chansrv" ]; then
      chansrv_source="$chansrv"
      break
    fi
  done

  if [ -z "$chansrv_source" ]; then
    while IFS= read -r chansrv; do
      [ -x "$chansrv" ] || continue
      chansrv_source="$chansrv"
      break
    done < <(find /usr/lib /usr/libexec /usr/local/lib /usr/local/sbin \
      /usr/sbin /sbin -type f -name xrdp-chansrv -perm /111 2>/dev/null)
  fi

  if [ -n "$chansrv_source" ]; then
    if [ "$chansrv_source" != "$chansrv_expected" ]; then
      install -d -m 0755 "$(dirname "$chansrv_expected")"
      ln -sfn "$chansrv_source" "$chansrv_expected"
      ok "linked xrdp-chansrv into $chansrv_expected"
    else
      ok "xrdp-chansrv found"
    fi
  else
    die "xrdp-chansrv was not found; reinstall xrdp before continuing because clipboard and drive redirection cannot work"
  fi

  if [ "$XRDP_PORT" = "3389" ] \
     && systemctl list-unit-files --no-legend 2>/dev/null | grep '^gnome-remote-desktop\.service' >/dev/null; then
    if systemctl is-enabled gnome-remote-desktop.service >/dev/null 2>&1 \
       || systemctl is-active gnome-remote-desktop.service >/dev/null 2>&1; then
      systemctl disable --now gnome-remote-desktop.service >/dev/null 2>&1 || true
      warn "disabled gnome-remote-desktop.service because it also uses port 3389"
    fi
  fi

  if getent group ssl-cert >/dev/null 2>&1 && id xrdp >/dev/null 2>&1; then
    usermod -aG ssl-cert xrdp
    ok "xrdp service account can read the TLS key"
  fi

  if dpkg -s xserver-xorg-legacy >/dev/null 2>&1 || [ -f /etc/X11/Xwrapper.config ]; then
    install -d -m 0755 /etc/X11
    cat > /etc/X11/Xwrapper.config <<XWRAP
# Managed by $SCRIPT_NAME
allowed_users=anybody
needs_root_rights=no
XWRAP
    ok "Xorg permits non-console XRDP sessions"
  fi

  case "$xrdp_session_bin" in
    */gnome-session)
      XRDP_CONCURRENT_LOCAL_ACTIVE=0
      if [ "$XRDP_ISOLATE_DBUS" = "1" ]; then
        warn "GNOME does not reliably support same-user local and XRDP sessions; use XFCE or a separate account"
        note_action "Use --desktop xfce for concurrent local and XRDP access"
      fi
      xrdp_xsession=$'export XDG_CURRENT_DESKTOP=ubuntu:GNOME\nexport GNOME_SHELL_SESSION_MODE=ubuntu\nexec /usr/bin/gnome-session'
      ;;
    */xfce4-session)
      if [ "$XRDP_ISOLATE_DBUS" = "1" ]; then
        command -v dbus-launch >/dev/null 2>&1 \
          || die "dbus-launch is required for concurrent local and XRDP XFCE sessions"
        XRDP_CONCURRENT_LOCAL_ACTIVE=1
        xrdp_xsession=$'unset DBUS_SESSION_BUS_ADDRESS\nexec dbus-launch --exit-with-session /usr/bin/startxfce4'
      else
        XRDP_CONCURRENT_LOCAL_ACTIVE=0
        xrdp_xsession='exec /usr/bin/startxfce4'
      fi
      ;;
    *)
      XRDP_CONCURRENT_LOCAL_ACTIVE=0
      xrdp_xsession="exec $xrdp_session_bin"
      ;;
  esac

  printf '#!/bin/sh\n# Managed by %s\n%s\n' "$SCRIPT_NAME" "$xrdp_xsession" > "$USER_HOME/.xsession"
  chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$USER_HOME/.xsession"
  chmod 0755 "$USER_HOME/.xsession"

  if [ -f /etc/X11/Xsession.options ] \
     && ! grep -qE '^[[:space:]]*allow-user-xsession[[:space:]]*$' /etc/X11/Xsession.options; then
    echo allow-user-xsession >> /etc/X11/Xsession.options
    ok "enabled per-user X sessions"
  fi

  update-alternatives --set x-session-manager "$xrdp_session_bin" >/dev/null 2>&1 || true
  ok "XRDP sessions for $TARGET_USER launch $(basename "$xrdp_session_bin")"

  for session_file in /usr/share/xsessions/*.desktop; do
    [ -f "$session_file" ] || continue
    case "$(basename "$session_file" .desktop)" in
      xfce|xfce4|xubuntu)
        xsession_name="$(basename "$session_file" .desktop)"
        break
        ;;
    esac
  done

  case "$xrdp_session_bin" in
    */xfce4-session)
      [ -n "$xsession_name" ] || xsession_name=xfce
      ;;
    *)
      xsession_name=""
      ;;
  esac

  if [ -n "$xsession_name" ]; then
    install -d -m 0755 /var/lib/AccountsService/users
    as_file="/var/lib/AccountsService/users/$TARGET_USER"
    if [ ! -f "$as_file" ]; then
      printf '[User]\nSession=%s\nXSession=%s\n' "$xsession_name" "$xsession_name" > "$as_file"
    else
      grep -qE '^\[User\]' "$as_file" || printf '[User]\n' >> "$as_file"
      set_ini_value "$as_file" User Session "$xsession_name"
      set_ini_value "$as_file" User XSession "$xsession_name"
    fi
    chmod 0600 "$as_file"
    ok "$TARGET_USER defaults to the '$xsession_name' desktop"
  fi

  if [ "$XFCE_COMPOSITING" != "1" ]; then
    install -d -m 0755 /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
    cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<XFWM
<?xml version="1.0" encoding="UTF-8"?>
<!-- Managed by $SCRIPT_NAME -->
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
XFWM
    chmod 0644 /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml
    ok "XFCE compositing disabled by default"

    user_xfwm="$USER_HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
    if [ -f "$user_xfwm" ] && grep -E 'use_compositing.*value="true"' "$user_xfwm" >/dev/null 2>&1; then
      warn "$TARGET_USER has a per-user XFCE setting that re-enables compositing"
      note_action "Disable it after login: xfconf-query -c xfwm4 -p /general/use_compositing -s false"
    fi
  fi

  if [ -f /etc/xrdp/xrdp.ini ]; then
    set_ini_value /etc/xrdp/xrdp.ini Globals allow_channels true \
      || die "could not enable XRDP virtual channels"
    set_ini_value /etc/xrdp/xrdp.ini Channels rdpdr true \
      || die "could not enable XRDP drive redirection"
    set_ini_value /etc/xrdp/xrdp.ini Channels cliprdr true \
      || die "could not enable XRDP clipboard redirection"
    set_ini_value /etc/xrdp/xrdp.ini Globals port "$XRDP_PORT" \
      || die "could not configure XRDP port $XRDP_PORT"
    ok "XRDP clipboard, redirected drives, and port configured"
  else
    die "/etc/xrdp/xrdp.ini is missing"
  fi

  if [ -f /etc/xrdp/sesman.ini ]; then
    set_ini_value /etc/xrdp/sesman.ini Security RestrictInboundClipboard none \
      || die "could not allow clipboard data from the Windows client"
    set_ini_value /etc/xrdp/sesman.ini Security RestrictOutboundClipboard none \
      || die "could not allow clipboard data to the Windows client"
    set_ini_value /etc/xrdp/sesman.ini Chansrv FuseMountName thinclient_drives \
      || die "could not configure the XRDP redirected-drive mount path"
    set_ini_value /etc/xrdp/sesman.ini Chansrv FileUmask 077 \
      || die "could not configure XRDP redirected-drive permissions"
    set_ini_value /etc/xrdp/sesman.ini Chansrv EnableFuseMount true \
      || die "could not enable XRDP FUSE drive redirection"
    ok "redirected drives mount at ~/thinclient_drives"
  else
    die "/etc/xrdp/sesman.ini is missing"
  fi

  if [ -L /etc/systemd/system/display-manager.service ]; then
    dm_unit="$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" 2>/dev/null)"
  fi

  if [ "$DESKTOP_HEADLESS_BOOT" = "1" ]; then
    current_target="$(systemctl get-default 2>/dev/null || echo unknown)"
    if [ "$current_target" = "multi-user.target" ]; then
      ok "the machine already boots to text mode"
    else
      systemctl set-default multi-user.target >/dev/null
      ok "default boot target set to multi-user.target"
      warn "the current session is unchanged; this takes effect after reboot"
    fi
  else
    if [ -z "$dm_unit" ]; then
      if command -v debconf-set-selections >/dev/null 2>&1; then
        echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections || true
      fi
      if apt-get install -y lightdm lightdm-gtk-greeter >/dev/null 2>&1; then
        dm_unit=lightdm.service
        ok "LightDM installed for the local console"
      else
        warn "LightDM could not be installed; the local console will remain text-only"
        note_action "Install LightDM and set graphical.target if a local desktop is required"
      fi
    else
      ok "reusing display manager ${dm_unit%.service}"
    fi

    if [ -n "$dm_unit" ]; then
      if [ "$dm_unit" = "lightdm.service" ]; then
        echo /usr/sbin/lightdm > /etc/X11/default-display-manager
        if [ -n "$xsession_name" ]; then
          install -d -m 0755 /etc/lightdm/lightdm.conf.d
          cat > /etc/lightdm/lightdm.conf.d/60-qwen3d8-cluster-session.conf <<LIGHTDM
# Managed by $SCRIPT_NAME
[Seat:*]
user-session=$xsession_name
LIGHTDM
          chmod 0644 /etc/lightdm/lightdm.conf.d/60-qwen3d8-cluster-session.conf
        fi
      fi

      # GDM is commonly a static unit whose only install alias is
      # display-manager.service. Enabling gdm.service directly can therefore
      # fail even though graphical.target will start it correctly.
      systemctl enable "$dm_unit" >/dev/null 2>&1 || true
      if [ ! -L /etc/systemd/system/display-manager.service ]; then
        dm_unit_path="$(systemctl show -p FragmentPath --value "$dm_unit" 2>/dev/null || true)"
        [ -n "$dm_unit_path" ] || dm_unit_path="/lib/systemd/system/$dm_unit"
        ln -sfn "$dm_unit_path" /etc/systemd/system/display-manager.service 2>/dev/null || true
      fi
      if [ -L /etc/systemd/system/display-manager.service ]; then
        ok "display-manager.service points at ${dm_unit%.service}"
      else
        warn "display-manager.service symlink is missing"
        note_action "Restore the display manager link before rebooting: sudo ln -sfn /lib/systemd/system/$dm_unit /etc/systemd/system/display-manager.service"
      fi

      current_target="$(systemctl get-default 2>/dev/null || echo unknown)"
      if [ "$current_target" != "graphical.target" ]; then
        systemctl set-default graphical.target >/dev/null
        ok "default boot target set to graphical.target"
        warn "the current session is unchanged; this takes effect after reboot"
      else
        ok "the machine already boots to a graphical login"
      fi
    fi
  fi

  install -d -m 0755 /etc/polkit-1/rules.d
  cat > /etc/polkit-1/rules.d/49-xrdp-no-password-prompts.rules <<POLKIT
// Managed by $SCRIPT_NAME
polkit.addRule(function(action, subject) {
    switch (action.id) {
        case "org.freedesktop.color-manager.create-device":
        case "org.freedesktop.color-manager.create-profile":
        case "org.freedesktop.color-manager.delete-device":
        case "org.freedesktop.color-manager.delete-profile":
        case "org.freedesktop.color-manager.modify-device":
        case "org.freedesktop.color-manager.modify-profile":
            return polkit.Result.YES;
    }
});
POLKIT
  chmod 0644 /etc/polkit-1/rules.d/49-xrdp-no-password-prompts.rules
  systemctl restart polkit >/dev/null 2>&1 || true

  ensure_boot_unit xrdp.service
  ensure_boot_unit xrdp-sesman.service
  systemctl restart xrdp-sesman.service
  systemctl restart xrdp.service

  if systemctl is-active --quiet xrdp.service; then
    ok "XRDP running on port $XRDP_PORT"
  else
    die "XRDP is not active; inspect systemctl status xrdp and /var/log/xrdp.log"
  fi
}

# =============================================================================
# 6. SSH REMOTE ACCESS
# =============================================================================
configure_ssh() {
  log "Installing OpenSSH server for remote administration"

  apt-get install -y openssh-server >/dev/null 2>&1 || die "failed to install openssh-server"

  ensure_boot_unit ssh.service
  systemctl restart ssh.service

  if systemctl is-active --quiet ssh.service; then
    ok "SSH running on port 22"
  else
    die "SSH is not active; inspect systemctl status ssh"
  fi
}

# =============================================================================
# 7. FIREWALL
# =============================================================================
configure_firewall() {
  log "Configuring LAN and private USB4 UFW rules"

  apt-get install -y ufw >/dev/null 2>&1 || die "failed to install UFW"
  if [ "$INSTALL_SSH" = "1" ]; then
    ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
  fi

  local net
  for net in $LAN_NETS; do
    if [ "$INSTALL_XRDP" = "1" ]; then
      ufw allow from "$net" to any port "$XRDP_PORT" proto tcp >/dev/null
    fi
    if [ "$INSTALL_SAMBA" = "1" ]; then
      ufw allow from "$net" to any port 445 proto tcp >/dev/null
      ufw allow from "$net" to any port 139 proto tcp >/dev/null
      ufw allow from "$net" to any port 137 proto udp >/dev/null
      ufw allow from "$net" to any port 138 proto udp >/dev/null
      if [ "$SAMBA_DISCOVERY_ON" = "1" ]; then
        ufw allow from "$net" to any port 5357 proto tcp >/dev/null
        ufw allow from "$net" to any port 3702 proto udp >/dev/null
      fi
    fi
  done

  if [ "$INSTALL_USB4" = "1" ]; then
    ufw allow in on "$CLUSTER_IFACE" from "$CLUSTER_PEER_IP" \
      to "$CLUSTER_LOCAL_IP" port "$IPERF_PORT" proto tcp >/dev/null
    if [ "$NODE_ROLE" = "peer" ]; then
      ufw allow in on "$CLUSTER_IFACE" from "$CLUSTER_PEER_IP" \
        to "$CLUSTER_LOCAL_IP" port "$RPC_PORT" proto tcp >/dev/null
    fi
  fi

  yes | ufw enable >/dev/null 2>&1 || true
  systemctl enable ufw.service >/dev/null 2>&1 || true

  local fw_state
  fw_state="$(ufw status verbose 2>/dev/null || true)"
  if grep '^Status: active' <<<"$fw_state" >/dev/null; then
    ok "UFW active; SMB/RDP are LAN-scoped and USB4 services are interface-scoped"
    if grep -E '^ENABLED=yes' /etc/ufw/ufw.conf >/dev/null 2>&1; then
      ok "UFW is configured to restore its rules at boot"
    else
      warn "UFW is active now but /etc/ufw/ufw.conf does not contain ENABLED=yes"
      note_action "Persist UFW at boot with: sudo ufw enable"
    fi
    if ! grep 'deny (incoming)' <<<"$fw_state" >/dev/null; then
      warn "UFW's default incoming policy is not deny"
      note_action "Set it with: sudo ufw default deny incoming && sudo ufw reload"
    fi
  else
    warn "UFW is not active"
    note_action "Enable it with: sudo ufw default deny incoming && sudo ufw enable"
  fi
}

# =============================================================================
# 8. APPLY SELECTED COMPONENTS AND REPORT
# =============================================================================
if [ "$INSTALL_USB4" = "1" ]; then
  configure_usb4
  echo
fi

if [ "$INSTALL_SAMBA" = "1" ]; then
  configure_samba
  echo
fi

if [ "$INSTALL_XRDP" = "1" ]; then
  configure_xrdp
  echo
fi

if [ "$INSTALL_SSH" = "1" ]; then
  configure_ssh
  echo
fi

if [ "$CONFIGURE_FIREWALL" = "1" ]; then
  configure_firewall
  echo
fi

echo "${GRN}${BOLD}Environment setup complete on $MY_HOST${RST}"
[ "$INSTALL_USB4" = "1" ] && echo "  USB4 private link:    $CLUSTER_IFACE  $CLUSTER_LOCAL_IP/$CLUSTER_CIDR -> $CLUSTER_PEER_IP"
[ "$INSTALL_USB4" = "1" ] && echo "  USB4 status helper:   /usr/local/bin/usb4-cluster-status (optional)"
if [ "$INSTALL_USB4" = "1" ]; then
  if [ "$NODE_ROLE" = "peer" ]; then
    echo "  USB4 benchmark helper: /usr/local/bin/usb4-cluster-benchmark (optional)"
  else
    echo "  USB4 benchmark service: $CLUSTER_SERVER_IP:$IPERF_PORT"
  fi
fi
[ "$INSTALL_SAMBA" = "1" ] && echo "  Windows file share:  \\\\$LAN_IP\\$XFER_SHARE  ->  $XFER_ROOT"
[ "$INSTALL_XRDP" = "1" ] && echo "  Remote desktop:      $LAN_IP:$XRDP_PORT"
[ "$INSTALL_XRDP" = "1" ] && echo "  Redirected drives:   ~/thinclient_drives"
[ "$INSTALL_XRDP" = "1" ] && [ "$XRDP_CONCURRENT_LOCAL_ACTIVE" = "1" ] \
  && echo "  Concurrent local/RDP: XFCE uses a private D-Bus session"
[ "$INSTALL_SSH" = "1" ] && echo "  SSH remote access:   $LAN_IP:22"
[ "$CONFIGURE_JOURNAL" = "1" ] && echo "  Journal disk cap:    $JOURNAL_MAX_USE (keep free $JOURNAL_KEEP_FREE)"
[ "$CONFIGURE_DISK_HEALTH" = "1" ] && echo "  Disk maintenance:    smartd monitoring + fstrim.timer"
if [ "$DISABLE_WIFI" = "1" ] || [ "$DISABLE_BLUETOOTH" = "1" ]; then
  radio_summary=""
  [ "$DISABLE_WIFI" = "1" ] && radio_summary="Wi-Fi"
  if [ "$DISABLE_BLUETOOTH" = "1" ]; then
    [ -n "$radio_summary" ] && radio_summary="$radio_summary, "
    radio_summary="${radio_summary}Bluetooth"
  fi
  echo "  Radios:              $radio_summary software disabled"
fi

if [ "${#ACTIONS[@]}" -gt 0 ]; then
  echo
  echo "${YLW}${BOLD}Action required${RST}"
  for action in "${ACTIONS[@]}"; do
    echo "${YLW}  *${RST} $action"
  done
fi

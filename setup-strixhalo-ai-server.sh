#!/usr/bin/env bash
#  setup-strixhalo-ai-server.sh
#
#  Provision ONE node of a two-node AMD "Strix Halo" LLM cluster
#  (BOSGAME M5 / Ryzen AI Max+ 395, Radeon 8060S iGPU = gfx1151, 128 GB unified
#  memory each) running a fresh Ubuntu 26.04.1 LTS install.
#
#  Run the SAME command line on BOTH machines. The script works out which node
#  it is from its own hostname and installs the matching half of the cluster:
#
#     SERVER node (the "head")            PEER node (the "worker")
#     ------------------------            ------------------------
#     ROCm + RCCL                         ROCm + RCCL
#     USB4NET point-to-point link         USB4NET point-to-point link
#     NFS server  (/srv/models ro,        NFS client (/srv/models  read-only,
#                  /srv/comfyui rw)                   /srv/comfyui read-write)
#     Ray head                            Ray worker
#     vLLM runtime + model units          vLLM runtime + model units
#     residencyd   (root, UDS only)       residency-agent (USB4 only)
#     llm-gateway  :8000  (LAN)           -
#     Open WebUI   :3000  (LAN)           -
#     ComfyUI      :8188  (LAN)           ComfyUI :8188 (LAN)
#     XRDP         :3389  (LAN)           XRDP    :3389 (LAN)
#
#  To every Windows client on the house LAN the pair behaves as ONE AI service:
#  a single OpenAI-compatible endpoint (llm-gateway) with a single stable model
#  catalog. Whether a model is resident on the server, on the peer, or split
#  across both with tensor parallelism is hidden behind the gateway.
#
#  USAGE (run ON EACH UBUNTU MACHINE, not from Windows):
#      chmod +x setup-strixhalo-ai-server.sh
#      sudo ./setup-strixhalo-ai-server.sh --server m5-a --peer m5-b
#
#  Nothing is hard-coded: the two hostnames, the service user, the ports, the
#  cluster subnet and the data disks are all parameters. See --help.
#
#  Re-running is safe (idempotent). Individual sections can be skipped with the
#  INSTALL_* environment variables documented in --help.
#
#  If you copied this file from Windows and bash complains about '\r', run:
#      sed -i 's/\r$//' setup-strixhalo-ai-server.sh
#
#  The gateway install needs gateway/app.py and dashboard/dashboard.py, the
#  residency install needs residency/residencyd.py and
#  residency/residency-agent.py, and the profiler install needs
#  llmprofile/llm-profile.py. After provisioning, use the update helper in
#  each component directory to deploy source edits and restart or update only
#  that component.
#
#  REFERENCE: StrixHalo_Cluster_plan.md (the canonical architecture document
#  this script implements).
# =============================================================================

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_SOURCE="$SCRIPT_DIR/dashboard/dashboard.py"
GATEWAY_SOURCE="$SCRIPT_DIR/gateway/app.py"
RESIDENCY_SOURCE_DIR="$SCRIPT_DIR/residency"
LLM_PROFILE_SOURCE="$SCRIPT_DIR/llmprofile/llm-profile.py"

# ============================== CONFIGURATION ================================
# Every value below can be overridden by an environment variable of the same
# name; the most important ones also have a command-line flag (see --help).

# --- cluster identity (REQUIRED, no defaults on purpose) ---------------------
SERVER_HOST="${SERVER_HOST:-}"      # hostname of the head/server node
PEER_HOST="${PEER_HOST:-}"          # hostname of the worker/peer node
NODE_ROLE="${NODE_ROLE:-auto}"      # auto | server | peer
SET_HOSTNAME="${SET_HOSTNAME:-0}"   # 1 = hostnamectl set-hostname to match --role

# --- the unprivileged account the desktop + user-facing services run as ------
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || true)}}"
TARGET_PASSWORD="${CLUSTER_USER_PASSWORD:-}"   # only used to CREATE/repair the account
TARGET_PASSWORD_FILE="${TARGET_PASSWORD_FILE:-}"
SSH_TRUST="${SSH_TRUST:-0}"         # 1 = exchange SSH keys with the other node

# --- which components to install (1/0) --------------------------------------
INSTALL_BASE="${INSTALL_BASE:-1}"           # apt packages, groups, udev, tuning
INSTALL_ROCM="${INSTALL_ROCM:-1}"           # ROCm runtime + RCCL for gfx1151
CONFIGURE_MEMORY="${CONFIGURE_MEMORY:-1}"   # amd-ttm shared GPU memory limit
INSTALL_STORAGE="${INSTALL_STORAGE:-1}"     # data disks + /srv layout
INSTALL_CLUSTER="${INSTALL_CLUSTER:-1}"     # USB4NET link
INSTALL_NFS="${INSTALL_NFS:-1}"             # shared /srv/models + /srv/comfyui
INSTALL_VLLM="${INSTALL_VLLM:-1}"           # vLLM runtime + Ray + model units
INSTALL_RESIDENCY="${INSTALL_RESIDENCY:-1}" # residencyd / residency-agent
INSTALL_GATEWAY="${INSTALL_GATEWAY:-1}"     # llm-gateway   (server only)
INSTALL_WEBUI="${INSTALL_WEBUI:-1}"         # Open WebUI    (server only)
INSTALL_COMFYUI="${INSTALL_COMFYUI:-1}"     # ComfyUI       (both nodes)
INSTALL_XRDP="${INSTALL_XRDP:-1}"           # remote desktop from Windows
INSTALL_SAMBA="${INSTALL_SAMBA:-1}"         # \\node\xfer file drop for Windows
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-1}"

# Which source networks count as "the house LAN". Every LAN-facing rule - ufw
# and Samba's own hosts allow - is derived from this one list, so restricting
# the cluster to a single subnet is a one-line change rather than a hunt.
LAN_NETS="${LAN_NETS:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"

# --- 24/7 host maintenance + hardening (1/0) ---------------------------------
# These boxes run headless for months at a time, so the things that quietly kill
# an unattended server get handled explicitly rather than left to chance.
CONFIGURE_UPDATES="${CONFIGURE_UPDATES:-1}"        # unattended SECURITY updates
CONFIGURE_JOURNAL="${CONFIGURE_JOURNAL:-1}"        # hard cap on journald's disk use
CONFIGURE_DISK_HEALTH="${CONFIGURE_DISK_HEALTH:-1}" # smartd + fstrim.timer
DISABLE_WIFI="${DISABLE_WIFI:-1}"                  # block every 802.11 driver
DISABLE_BLUETOOTH="${DISABLE_BLUETOOTH:-1}"        # block the whole BT stack
RADIO_DISABLE_FORCE="${RADIO_DISABLE_FORCE:-0}"    # 1 = kill Wi-Fi even if it is the only route

# Packages unattended-upgrades must NEVER touch. A background kernel bump takes
# the amdttm module parameters and the gfx1151 KFD fixes with it, and a ROCm
# minor upgrade routinely changes what vLLM will build against - both turn a
# working cluster into a broken one with nobody watching. Entries are matched as
# regular expressions against the package NAME, unanchored, so "linux-image"
# covers every linux-image-* flavour.
UNATTENDED_HOLD="${UNATTENDED_HOLD:-linux-image linux-headers linux-modules linux-generic rocm amdgpu}"

# journald: without a cap, a service that logs a line per token will fill the
# root filesystem long before anyone notices, and a full / breaks everything.
JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-2G}"
JOURNAL_KEEP_FREE="${JOURNAL_KEEP_FREE:-1G}"

# smartd: -W <diff>,<info>,<crit> in degrees C. NVMe under sustained model I/O
# runs hot, and a drive that is cooking is the earliest warning you get.
SMART_TEMP_LIMITS="${SMART_TEMP_LIMITS:-4,65,75}"
SMART_ALERT_EMAIL="${SMART_ALERT_EMAIL:-}"  # empty = journal only (no MTA needed)

# Radio modules blocked with 'install <mod> /bin/false'. cfg80211 is the wedge:
# every in-tree 802.11 driver depends on it, so blocking it disables Wi-Fi on
# any hardware without having to know which vendor's card this box shipped with.
WIFI_BLOCK_MODULES="${WIFI_BLOCK_MODULES:-cfg80211 mac80211}"
BT_BLOCK_MODULES="${BT_BLOCK_MODULES:-bluetooth btusb btintel btmtk btrtl bnep rfcomm}"

# --- LAN-facing ports --------------------------------------------------------
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"           # 0.0.0.0 = reachable from the LAN
GATEWAY_PORT="${GATEWAY_PORT:-8000}"        # llm-gateway, OpenAI-compatible
WEBUI_PORT="${WEBUI_PORT:-3000}"            # Open WebUI
COMFYUI_PORT="${COMFYUI_PORT:-8188}"        # ComfyUI (runs on BOTH nodes)
XRDP_PORT="${XRDP_PORT:-3389}"

# --- cluster-internal ports (USB4 link / loopback only, never the LAN) -------
RAY_PORT="${RAY_PORT:-6379}"                # Ray GCS
RAY_WORKER_PORT_MIN="${RAY_WORKER_PORT_MIN:-20000}"
RAY_WORKER_PORT_MAX="${RAY_WORKER_PORT_MAX:-20100}"
RAY_DASHBOARD_PORT="${RAY_DASHBOARD_PORT:-8265}"
AGENT_PORT="${AGENT_PORT:-8099}"            # residency-agent on the peer
RESIDENCY_LIB="${RESIDENCY_LIB:-/usr/local/lib/llm-cluster}"
VLLM_PORT_BASE="${VLLM_PORT_BASE:-18000}"   # per-model vLLM ports: base+1, +2 ...

# --- USB4NET point-to-point link --------------------------------------------
# The two boxes are cabled USB4-port-to-USB4-port and get a private /30 of their
# own, completely separate from the house LAN. Server = .1, peer = .2.
CLUSTER_IFACE="${CLUSTER_IFACE:-usb4llm0}"  # stable name we rename the link to
CLUSTER_NET="${CLUSTER_NET:-10.44.0}"       # first three octets
CLUSTER_CIDR="${CLUSTER_CIDR:-30}"
# The plan says: keep MTU at 1500 until the whole cluster is stable, and only
# then experiment with jumbo frames. thunderbolt_net accepts up to 65522
# (SZ_64K - ETH_HLEN); 65520 is what every other OS uses and is the value to
# try later -- but BOTH nodes must agree or you get fragmentation, not speed.
CLUSTER_MTU="${CLUSTER_MTU:-1500}"
CLUSTER_AUTO_AUTHORIZE="${CLUSTER_AUTO_AUTHORIZE:-1}"
CLUSTER_TUNE_SYSCTL="${CLUSTER_TUNE_SYSCTL:-1}"

# --- shared storage ----------------------------------------------------------
# Canonical paths, identical on BOTH machines (the plan depends on this):
#   /srv/models   authoritative LLM/vLLM repository  - owned by the server,
#                 exported READ-ONLY to the peer.
#   /srv/comfyui  shared ComfyUI store (models, input, output, workflows) -
#                 exported READ-WRITE so either node can download once and both
#                 see it. ComfyUI itself is NOT clustered: each node runs its
#                 own instance for parallel workloads over one file store.
LLM_ROOT="${LLM_ROOT:-/srv/models}"
COMFY_ROOT="${COMFY_ROOT:-/srv/comfyui}"
# Optional dedicated SSDs. NOTHING is ever formatted unless --format-data-disks
# is given as well; without these flags both trees simply live on the root disk.
LLM_DISK="${LLM_DISK:-}"            # e.g. /dev/nvme0n1 - holds vLLM/LLM content
COMFY_DISK="${COMFY_DISK:-}"        # e.g. /dev/nvme1n1 - holds ComfyUI content
FORMAT_DATA_DISKS="${FORMAT_DATA_DISKS:-0}"
DATA_FS="${DATA_FS:-ext4}"
# On the PEER both trees are NFS mounts, so its own SSDs are used for fast local
# scratch instead: Ray object spill, torch/vLLM compile caches, NFS FS-Cache.
LLM_LOCAL_CACHE="${LLM_LOCAL_CACHE:-/var/lib/llm-cache}"
COMFY_LOCAL_CACHE="${COMFY_LOCAL_CACHE:-/var/lib/comfyui-local}"
NFS_FSCACHE="${NFS_FSCACHE:-1}"     # cachefilesd-backed read cache on the peer

# --- Windows maintenance drop folder (Samba/SMB) -----------------------------
# Deliberately NOT under $LLM_ROOT or $COMFY_ROOT: those have specific NFS
# read-only/read-write semantics between the two nodes, and an SMB client
# writing into them would quietly break that contract. Each node serves its own
# copy of this folder, because the point is getting a file onto ONE named box.
XFER_ROOT="${XFER_ROOT:-/srv/xfer}"
XFER_SHARE="${XFER_SHARE:-xfer}"              # the name Windows sees: \\host\xfer
SAMBA_WORKGROUP="${SAMBA_WORKGROUP:-WORKGROUP}"
SAMBA_DISCOVERY="${SAMBA_DISCOVERY:-1}"       # wsdd, so the node shows under "Network"

# Service account that owns /srv/models, and the shared group both it and the
# desktop user belong to. Fixed IDs so ownership matches across both machines
# (NFS maps by NUMERIC id -- mismatched uids are the classic shared-storage bug).
LLM_USER="${LLM_USER:-llm}"
LLM_UID="${LLM_UID:-970}"
SHARE_GROUP="${SHARE_GROUP:-aimodels}"
SHARE_GID="${SHARE_GID:-971}"
GATEWAY_USER="${GATEWAY_USER:-llmgateway}"
GATEWAY_UID="${GATEWAY_UID:-972}"

# --- ROCm --------------------------------------------------------------------
ROCM_GFX="${ROCM_GFX:-gfx1151}"
ROCM_REPO_URL="${ROCM_REPO_URL:-}"          # empty = derive from /etc/os-release
ROCM_GPG_URL="${ROCM_GPG_URL:-https://stable.repo.amd.com/rocm/gpg/packages.gpg}"
ROCM_PKG="${ROCM_PKG:-}"                    # empty = newest amdrocm<ver>-gfx1151
ROCM_INSTALL_OPENCL="${ROCM_INSTALL_OPENCL:-1}"

# --- GPU-addressable unified memory -----------------------------------------
# Strix Halo shares one physical pool. Raise the TTM page limit so the iGPU can
# map nearly all 128 GB; the plan asks for ~120 GiB on a 128 GB box.
GTT_GIB="${GTT_GIB:-}"                      # empty = MemTotal - OS_RESERVE_GIB
OS_RESERVE_GIB="${OS_RESERVE_GIB:-8}"

# --- OS-level OOM guardrails (defence in depth under residencyd's gate) ------
# On this shared-memory APU a runaway allocation can exhaust RAM faster than the
# kernel can reclaim, hard-freezing the whole box (exactly how mighty-ai1 locked
# up). Two OS backstops sit BELOW residencyd's admission gate:
#   * systemd-oomd watches memory-pressure (PSI) on llm.slice and, once it stays
#     above OOMD_PRESSURE_LIMIT for OOMD_PRESSURE_DURATION, kills the single
#     worst model server -- one bad load costs one model, not the machine.
#   * a small zram swap gives the kernel a compressed relief valve (GPU GTT
#     pages are pinned and never swap, but page cache / desktop / Python heaps
#     do), so pressure builds gradually and measurably instead of wedging.
CONFIGURE_OOM_GUARD="${CONFIGURE_OOM_GUARD:-1}"
OOMD_PRESSURE_LIMIT="${OOMD_PRESSURE_LIMIT:-60%}"        # llm.slice PSI kill threshold
OOMD_PRESSURE_DURATION="${OOMD_PRESSURE_DURATION:-20s}"  # sustained-for before a kill
ZRAM_ENABLE="${ZRAM_ENABLE:-1}"
ZRAM_SIZE_SPEC="${ZRAM_SIZE_SPEC:-min(ram / 8, 16384)}"  # MiB; zram-generator expression
ZRAM_COMPRESSION="${ZRAM_COMPRESSION:-zstd}"

# --- vLLM / Ray runtime ------------------------------------------------------
# AMD publishes torch/torchvision/torchaudio/triton for gfx1151 at
# repo.amd.com/rocm/whl/gfx1151/, but NO vllm wheel -- so a pip install of vLLM
# would drag in the CUDA build of torch and destroy the ROCm one. AMD's own
# "Clustering Two Ryzen AI Halos with RCCL" playbook therefore runs vLLM from a
# gfx1151-native container, and that is the default here too.
#
# 'container' : the plan's preferred baseline, and the only path with a working
#               gfx1151 vLLM + RCCL today. Pin the SAME image on both nodes.
# 'venv'      : uv virtualenv from AMD's gfx1151 wheel index. Gets you torch and
#               Ray, but only installs vLLM if that index ever publishes one.
VLLM_RUNTIME="${VLLM_RUNTIME:-container}"
VLLM_VENV="${VLLM_VENV:-/opt/vllm}"
VLLM_PY="${VLLM_PY:-3.12}"
# Hugging Face CLI venv. Kept separate from the vLLM runtime because seeding has
# to work before that runtime exists, and a bad model pull must never be able to
# disturb the serving stack. verify-and-seed-strixhalo-ai-server.sh looks here.
HF_TOOLS_VENV="${HF_TOOLS_VENV:-/opt/hf-tools}"

# --- model auto-profiler (llm-model pull) -----------------------------------
# Ceilings the profiler applies when deriving a new model's catalog entry from
# its config.json, so a model advertising a 1M-token context or an unbounded
# batch cannot silently blow the per-node memory budget on its first load. Both
# are overridable per pull (llm-model pull --max-len / --hybrid-max-seqs).
LLM_MAX_LEN_CAP="${LLM_MAX_LEN_CAP:-32768}"       # cap auto-derived --max-model-len
LLM_HYBRID_MAX_SEQS="${LLM_HYBRID_MAX_SEQS:-64}"  # --max-num-seqs cap for Mamba/GDN hybrids

# --- pulled-model garbage collection (on-disk LRU) --------------------------
# Models onboarded with 'llm-model pull' land under ${LLM_ROOT}/pulled and can
# accumulate until the shared volume is full and the NEXT pull fails. 'llm-model
# gc' reclaims the least-recently-used pulled models (weights + catalog entry),
# so any model can be re-fetched on demand later. Only pulled/ is ever touched;
# hand-curated catalog models and the HF cache are left alone. keep-warm and
# currently-loaded models are never evicted. A pull auto-runs gc first, and a
# daily timer prunes anything unused past LLM_GC_MAX_IDLE_DAYS.
CONFIGURE_MODEL_GC="${CONFIGURE_MODEL_GC:-1}"       # install the gc timer/hooks
LLM_GC_MIN_FREE_GIB="${LLM_GC_MIN_FREE_GIB:-150}"   # free-space floor gc keeps clear
LLM_GC_MAX_IDLE_DAYS="${LLM_GC_MAX_IDLE_DAYS:-30}"  # idle age the timer prunes past
VLLM_TORCH_INDEX="${VLLM_TORCH_INDEX:-https://repo.amd.com/rocm/whl/gfx1151/}"
VLLM_PIP_EXTRA_INDEX="${VLLM_PIP_EXTRA_INDEX:-https://pypi.org/simple}"
# The container baseline used by this setup is vLLM 0.22.1. Its Ray executor
# must not float independently: this deployment pins the tested Ray line too.
# Override both values together only with another tested vLLM/Ray pair.
VLLM_EXPECTED_VERSION="${VLLM_EXPECTED_VERSION:-0.22.1}"
RAY_EXPECTED_VERSION="${RAY_EXPECTED_VERSION:-2.48.0}"
VLLM_PKG="${VLLM_PKG:-vllm==${VLLM_EXPECTED_VERSION}}"
RAY_PKG="${RAY_PKG:-ray[default]==${RAY_EXPECTED_VERSION}}"
# AMD's Strix Halo clustering playbook image (gfx1151-native vLLM + RCCL).
# Community alternative, tracks newer vLLM: docker.io/kyuz0/vllm-therock-gfx1151:latest
VLLM_IMAGE="${VLLM_IMAGE:-oci-registry.ryai.dev/ryai-vllm:latest}"
VLLM_CONTAINER="${VLLM_CONTAINER:-llm-runtime}"
VLLM_CONTAINER_PYTHON="${VLLM_CONTAINER_PYTHON:-/opt/vllm/uvenv/bin/python}"
# podman is what AMD's playbook uses and needs no daemon; docker works exactly
# the same way here. 'auto' = whichever is already installed, else podman.
CONTAINER_ENGINE="${CONTAINER_ENGINE:-auto}"

# --- residency / gateway -----------------------------------------------------
LLM_ETC="${LLM_ETC:-/etc/llm}"
RESIDENCY_SOCK="${RESIDENCY_SOCK:-/run/residencyd/control.sock}"
# Per-node memory budget residencyd admits against. Empty = derive from the TTM
# limit configured above, minus a safety margin for the runtime itself.
RESIDENCY_BUDGET_GIB="${RESIDENCY_BUDGET_GIB:-}"
RESIDENCY_MARGIN_GIB="${RESIDENCY_MARGIN_GIB:-8}"
# Live memory-safety gate. residencyd admits a cold load only when the target
# node's REAL free memory (its /proc/meminfo, or the peer agent's /meminfo) can
# hold the model's peak footprint above RESERVE_FLOOR, so the ledger and the
# hardware can never disagree until the box freezes. The reaper additionally
# evicts the LRU idle model on any node that dips below CRITICAL_FLOOR.
RESIDENCY_RESERVE_FLOOR_GIB="${RESIDENCY_RESERVE_FLOOR_GIB:-12}"
RESIDENCY_CRITICAL_FLOOR_GIB="${RESIDENCY_CRITICAL_FLOOR_GIB:-8}"
RESIDENCY_LOAD_PEAK_FACTOR="${RESIDENCY_LOAD_PEAK_FACTOR:-1.10}"
RESIDENCY_MEASURE="${RESIDENCY_MEASURE:-1}"                # 0 = ledger-only
RESIDENCY_MEASURE_STRICT="${RESIDENCY_MEASURE_STRICT:-0}"  # 1 = refuse if unmeasurable
RESIDENCY_IDLE_TIMEOUT="${RESIDENCY_IDLE_TIMEOUT:-1800}"   # seconds; 0 disables
# cold-start budget. This has to cover the very FIRST load of a given model on
# a given node, not just weight loading: vLLM JIT-builds aiter kernels and
# torch.compile's/autotunes the graph on that first run, then caches the
# result (under the model's NFS-shared .cache dir), so every load after the
# first is far quicker. 900s was measured too tight for a real cold compile
# (e.g. gpt-oss-20b's mxfp4/Triton MoE backend) and produced a false
# 'did not become healthy' failure even though the load was still progressing.
RESIDENCY_LOAD_TIMEOUT="${RESIDENCY_LOAD_TIMEOUT:-1800}"
GATEWAY_VENV="${GATEWAY_VENV:-/opt/llm-gateway}"
GATEWAY_PY="${GATEWAY_PY:-3.12}"

# --- Open WebUI --------------------------------------------------------------
WEBUI_VENV="${WEBUI_VENV:-/opt/open-webui}"
WEBUI_PY="${WEBUI_PY:-3.11}"                # Open WebUI supports 3.11/3.12 only
WEBUI_DATA="${WEBUI_DATA:-/var/lib/open-webui}"

# --- ComfyUI -----------------------------------------------------------------
COMFY_PY="${COMFY_PY:-3.13}"
TORCH_INDEX="${TORCH_INDEX:-https://repo.amd.com/rocm/whl/gfx1151/}"
COMFY_MANAGER_SECURITY="${COMFY_MANAGER_SECURITY:-weak}"

# ComfyUI does not get a machine to itself here: it shares one physical pool of
# memory with vLLM and Ray, because on Strix Halo the GPU's "VRAM" is carved out
# of the same DIMMs the OS is using. Upstream's default cache mode is
# --cache-ram, documented as "active 10% of system RAM (min 2GB, max 10GB),
# inactive 100% of system RAM (max 128GB)" -- on a 128 GiB box that inactive
# ceiling is the whole machine. Left at the default ComfyUI keeps growing until
# the kernel reports memory pressure, and by then the OOM killer is as likely to
# choose vLLM (large, older, idle between requests) as ComfyUI. So the cache is
# bounded explicitly, and ComfyUI is told to leave GPU memory for its neighbour.
COMFY_CACHE_MODE="${COMFY_CACHE_MODE:-ram}"           # ram | classic | lru | none
COMFY_CACHE_ACTIVE_GB="${COMFY_CACHE_ACTIVE_GB:-4}"   # --cache-ram hot threshold
COMFY_CACHE_INACTIVE_GB="${COMFY_CACHE_INACTIVE_GB:-32}"  # --cache-ram pin threshold
COMFY_CACHE_LRU="${COMFY_CACHE_LRU:-8}"               # node results, when MODE=lru
COMFY_RESERVE_VRAM="${COMFY_RESERVE_VRAM:-16}"        # GiB kept free for vLLM/OS; 0 = upstream default
COMFY_PREVIEW_METHOD="${COMFY_PREVIEW_METHOD:-auto}"  # none|auto|latent2rgb|taesd
# The asset system adds API routes, database sync and a BACKGROUND SCANNER over
# the model tree. That tree is NFS-shared between the two nodes, so enabling it
# means both machines continuously walk (and with hashing, read in full) the same
# export across the USB4 link. Off unless you ask for it.
COMFY_ENABLE_ASSETS="${COMFY_ENABLE_ASSETS:-0}"
COMFY_DISABLE_API_NODES="${COMFY_DISABLE_API_NODES:-0}"   # 1 = frontend never calls out

# --- XRDP / desktop ----------------------------------------------------------
# XFCE by default, not 'auto'. On a box whose GPU is the product, the desktop is
# overhead: gnome-shell is a compositing GL client, so it holds GTT memory --
# the SAME memory vLLM and ComfyUI allocate from -- and keeps the iGPU busy
# drawing a screen nobody is looking at. XFCE with its compositor off draws
# through Xorg and gives that memory back.
XRDP_DESKTOP="${XRDP_DESKTOP:-xfce}"        # xfce | auto | /abs/path/to/session
# Boot straight into the XFCE desktop on the console. This needs a display
# manager: 'graphical.target' on a server install has nothing to start, so it
# lands on the same text login as multi-user.target. LightDM is installed when
# the box has no display manager of its own -- it is the lightest one that
# still logs into XFCE, and unlike GDM its greeter is not a compositing GL
# client. Set to 1 (--headless-boot) to leave the console at a text login and
# reach the desktop only over RDP, which keeps the iGPU completely idle while
# nobody is connected.
DESKTOP_HEADLESS_BOOT="${DESKTOP_HEADLESS_BOOT:-0}"
XFCE_COMPOSITING="${XFCE_COMPOSITING:-0}"   # 1 = allow the xfwm4 compositor

ASSUME_YES="${ASSUME_YES:-0}"
# =============================================================================

BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
log()  { echo "${BLU}${BOLD}==>${RST} ${BOLD}$*${RST}"; }
ok()   { echo "${GRN}  ok:${RST} $*"; }
warn() { echo "${YLW}  warn:${RST} $*"; }
# Neutral commentary: a normal outcome that is neither a success worth claiming
# nor a problem. Same vocabulary as the verify script. Defining it matters more
# than it looks: without it 'info ...' silently resolves to the GNU texinfo
# reader, which exits non-zero and trips the ERR trap below.
info() { echo "${BLU}  info:${RST} $*"; }
die()  { echo "${RED}${BOLD}ERROR:${RST} $*" >&2; exit 1; }
trap 'die "failed at line $LINENO. See the output above."' ERR

# Collected and replayed at the very end so nothing important scrolls away.
ACTIONS=()
note_action() { ACTIONS+=("$*"); }

usage() {
  cat <<USAGE
${BOLD}$SCRIPT_NAME${RST} - provision one node of a two-node Strix Halo LLM cluster.

${BOLD}Run the identical command on BOTH machines.${RST} The node's own hostname decides
which half of the cluster it installs.

${BOLD}REQUIRED${RST}
  --server <hostname>     hostname of the head/server node   (Ray head, NFS
                          server, residencyd, llm-gateway, Open WebUI)
  --peer   <hostname>     hostname of the worker/peer node

${BOLD}IDENTITY${RST}
  --role server|peer|auto  which node THIS box is (default: auto = match hostname)
  --set-hostname           set this box's hostname to the --role name first
  --user <name>            unprivileged account services + RDP use
                           (default: the user invoking sudo)
  --password <pw>          only used to CREATE the account if it is missing.
                           Prefer --password-file: argv is visible in 'ps'.
  --password-file <path>   read that password from a file (first line)
  --ssh-trust              exchange SSH keys with the other node (needs a password
                           the first time; purely for convenient administration)

${BOLD}STORAGE${RST}   (nothing is formatted unless --format-data-disks is also given)
  --llm-disk <dev>         SSD for LLM/vLLM content   -> $LLM_ROOT (server)
                                                      -> $LLM_LOCAL_CACHE (peer)
  --comfy-disk <dev>       SSD for ComfyUI content    -> $COMFY_ROOT (server)
                                                      -> $COMFY_LOCAL_CACHE (peer)
  --format-data-disks      allow creating a fresh $DATA_FS filesystem on the disks
                           above. Refuses any disk that is mounted, holds the
                           root filesystem, or already contains data.
  --list-disks             show candidate disks and exit

${BOLD}NETWORK${RST}
  --cluster-net <a.b.c>    first three octets of the USB4 /30 (default $CLUSTER_NET)
  --cluster-iface <name>   stable name for the USB4 link (default $CLUSTER_IFACE)
  --cluster-mtu <n>        USB4 MTU (default $CLUSTER_MTU; try 65520 once stable)
  --gateway-port <n>       llm-gateway   (default $GATEWAY_PORT)
  --webui-port <n>         Open WebUI    (default $WEBUI_PORT)
  --comfyui-port <n>       ComfyUI       (default $COMFYUI_PORT)
  --rdp-port <n>           XRDP          (default $XRDP_PORT)

${BOLD}RUNTIME${RST}
  --vllm-runtime venv|container   how to install vLLM+Ray (default $VLLM_RUNTIME).
                                  Only 'container' currently yields a working
                                  gfx1151 vLLM: AMD publishes no vllm wheel.
  --vllm-image <ref>              base container image (default: $VLLM_IMAGE).
                                  Tags are resolved automatically; the generated
                                  runtime is pinned to an immutable local image.
                                  The runtime must report vLLM $VLLM_EXPECTED_VERSION
                                  with Ray $RAY_EXPECTED_VERSION; override both
                                  environment variables only for a tested pair.
  --container-engine podman|docker|auto   (default $CONTAINER_ENGINE)
  --gtt-gib <n>                   GPU-addressable unified memory (default:
                                  MemTotal - ${OS_RESERVE_GIB} GiB)
  --no-oom-guard                  do not install the systemd-oomd + zram OS
                                  backstop that kills within llm.slice under
                                  real memory pressure (residencyd's own
                                  admission gate still applies either way)
  --no-zram                       skip only the zram relief swap (keep oomd)
  --no-model-gc                   do not install the pulled-model LRU garbage
                                  collector (timer + pre-pull space check); you
                                  then reclaim disk yourself with 'llm-model
                                  remove'

${BOLD}COMFYUI${RST}   (it shares this box's memory with vLLM -- see the notes in the script)
  --comfy-cache <mode>     ram | classic | lru | none (default $COMFY_CACHE_MODE).
                           'ram' is upstream's own default, but its documented
                           ceiling is 100% of system RAM, which here is the same
                           memory vLLM is holding weights in. Bounded to
                           ${COMFY_CACHE_ACTIVE_GB}G active / ${COMFY_CACHE_INACTIVE_GB}G inactive unless you change it.
  --comfy-reserve-vram <n> GiB of GPU memory ComfyUI must leave for vLLM and the
                           OS (default $COMFY_RESERVE_VRAM; 0 = upstream default)
  --comfy-preview <m>      none | auto | latent2rgb | taesd (default $COMFY_PREVIEW_METHOD).
                           Upstream defaults to none, i.e. no feedback at all
                           while a long sample runs on a headless machine.
  --comfy-assets           enable the asset DB and its background scanner (off by
                           default: both nodes would scan the shared NFS store)
  --comfy-no-api-nodes     stop the ComfyUI frontend from talking to the internet

${BOLD}DESKTOP${RST}
  --desktop <what>         xfce | auto | /abs/path/to/session (default $XRDP_DESKTOP).
                           XFCE is the default because gnome-shell is a
                           compositing GL client: it holds GTT memory, which is
                           the same memory vLLM and ComfyUI allocate from.
  --graphical-boot         boot into the desktop on the console (the default).
                           Installs LightDM if the box has no display manager,
                           because 'graphical.target' on a server install has
                           nothing to start and lands on a text login anyway.
  --headless-boot          leave the console at a text login instead. The
                           desktop is then started per RDP connection, so
                           nothing holds the iGPU while nobody is connected --
                           worth a few hundred MB of GTT on a busy node.
  --xfce-compositing       allow the xfwm4 compositor (off by default; it is a
                           GL client too, and useless over RDP)

${BOLD}WINDOWS FILE SHARE${RST}   (\\\\<this node>\\$XFER_SHARE -- RDP cannot paste files Windows->Linux)
  --xfer-dir <path>        folder to share (default $XFER_ROOT). Kept separate
                           from the NFS trees on purpose.
  --share-name <name>      name Windows sees (default $XFER_SHARE)
  --workgroup <name>       SMB workgroup (default $SAMBA_WORKGROUP)
  --no-samba-discovery     do not install wsdd (the node then works by
                           \\\\name and \\\\ip, but never appears under "Network")
                           The share is open: no account, no password.

${BOLD}OTHER${RST}
  --skip <component>       skip a section; repeatable. One of:
                           base rocm memory storage cluster nfs vllm residency
                           gateway webui comfyui xrdp samba firewall
                           updates journal diskhealth radios wifi bluetooth
                           ('usb4' is accepted as an alias for 'cluster',
                            'smb'/'xfer' as aliases for 'samba')
  -y, --yes                never prompt
  -h, --help               this help

${BOLD}24/7 MAINTENANCE${RST}   (all on by default; see --skip to turn any of them off)
  --journal-max <size>     cap journald's on-disk logs (default $JOURNAL_MAX_USE)
  --smart-email <addr>     mail SMART alerts here as well as to the journal
  --keep-radios            leave Wi-Fi and Bluetooth enabled
                           Security updates are applied automatically, but the
                           kernel and ROCm are never upgraded unattended:
                             $UNATTENDED_HOLD

${BOLD}EXAMPLES${RST}
  # both machines, fresh 26.04.1 installs named m5-a and m5-b:
  sudo ./$SCRIPT_NAME --server m5-a --peer m5-b

  # name the boxes as part of provisioning, with dedicated SSDs:
  sudo ./$SCRIPT_NAME --server m5-a --peer m5-b --role server --set-hostname \\
       --llm-disk /dev/nvme0n1 --comfy-disk /dev/nvme1n1 --format-data-disks

  # rerun just the gateway + webui on the head node:
  sudo ./$SCRIPT_NAME --server m5-a --peer m5-b \\
       --skip base --skip rocm --skip memory --skip storage --skip cluster \\
       --skip nfs --skip vllm --skip comfyui --skip xrdp
USAGE
}

skip_component() {
  case "$1" in
    base)      INSTALL_BASE=0 ;;
    rocm)      INSTALL_ROCM=0 ;;
    memory)    CONFIGURE_MEMORY=0 ;;
    storage)   INSTALL_STORAGE=0 ;;
    cluster|usb4) INSTALL_CLUSTER=0 ;;
    nfs)       INSTALL_NFS=0 ;;
    vllm)      INSTALL_VLLM=0 ;;
    residency) INSTALL_RESIDENCY=0 ;;
    gateway)   INSTALL_GATEWAY=0 ;;
    webui)     INSTALL_WEBUI=0 ;;
    comfyui)   INSTALL_COMFYUI=0 ;;
    xrdp)      INSTALL_XRDP=0 ;;
    samba|smb|xfer) INSTALL_SAMBA=0 ;;
    firewall)  CONFIGURE_FIREWALL=0 ;;
    updates)   CONFIGURE_UPDATES=0 ;;
    journal)   CONFIGURE_JOURNAL=0 ;;
    diskhealth|smart) CONFIGURE_DISK_HEALTH=0 ;;
    radios)    DISABLE_WIFI=0; DISABLE_BLUETOOTH=0 ;;
    wifi)      DISABLE_WIFI=0 ;;
    bluetooth) DISABLE_BLUETOOTH=0 ;;
    *) die "--skip: unknown component '$1' (see --help)" ;;
  esac
}

list_disks() {
  echo "Block devices on this machine:"
  lsblk -dno NAME,SIZE,MODEL,TYPE 2>/dev/null | sed 's/^/  /'
  echo
  echo "Root filesystem lives on: $(findmnt -no SOURCE / 2>/dev/null || echo '?')"
  echo
  echo "Pass a whole disk (e.g. /dev/nvme1n1) to --llm-disk / --comfy-disk."
}

# --- argument parsing --------------------------------------------------------
need_arg() { [ -n "${2:-}" ] || die "$1 requires a value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --server)          need_arg "$1" "${2:-}"; SERVER_HOST="$2"; shift ;;
    --peer)            need_arg "$1" "${2:-}"; PEER_HOST="$2"; shift ;;
    --role)            need_arg "$1" "${2:-}"; NODE_ROLE="$2"; shift ;;
    --set-hostname)    SET_HOSTNAME=1 ;;
    --user)            need_arg "$1" "${2:-}"; TARGET_USER="$2"; shift ;;
    --password)        need_arg "$1" "${2:-}"; TARGET_PASSWORD="$2"; shift ;;
    --password-file)   need_arg "$1" "${2:-}"; TARGET_PASSWORD_FILE="$2"; shift ;;
    --ssh-trust)       SSH_TRUST=1 ;;
    --llm-disk)        need_arg "$1" "${2:-}"; LLM_DISK="$2"; shift ;;
    --comfy-disk)      need_arg "$1" "${2:-}"; COMFY_DISK="$2"; shift ;;
    --format-data-disks) FORMAT_DATA_DISKS=1 ;;
    --list-disks)      list_disks; exit 0 ;;
    --cluster-net)     need_arg "$1" "${2:-}"; CLUSTER_NET="$2"; shift ;;
    --cluster-iface)   need_arg "$1" "${2:-}"; CLUSTER_IFACE="$2"; shift ;;
    --cluster-mtu)     need_arg "$1" "${2:-}"; CLUSTER_MTU="$2"; shift ;;
    --gateway-port)    need_arg "$1" "${2:-}"; GATEWAY_PORT="$2"; shift ;;
    --webui-port)      need_arg "$1" "${2:-}"; WEBUI_PORT="$2"; shift ;;
    --comfyui-port)    need_arg "$1" "${2:-}"; COMFYUI_PORT="$2"; shift ;;
    --comfy-cache)     need_arg "$1" "${2:-}"; COMFY_CACHE_MODE="$2"; shift ;;
    --comfy-reserve-vram) need_arg "$1" "${2:-}"; COMFY_RESERVE_VRAM="$2"; shift ;;
    --comfy-preview)   need_arg "$1" "${2:-}"; COMFY_PREVIEW_METHOD="$2"; shift ;;
    --comfy-assets)    COMFY_ENABLE_ASSETS=1 ;;
    --comfy-no-api-nodes) COMFY_DISABLE_API_NODES=1 ;;
    --desktop)         need_arg "$1" "${2:-}"; XRDP_DESKTOP="$2"; shift ;;
    --graphical-boot)  DESKTOP_HEADLESS_BOOT=0 ;;
    --headless-boot)   DESKTOP_HEADLESS_BOOT=1 ;;
    --xfce-compositing) XFCE_COMPOSITING=1 ;;
    --xfer-dir)        need_arg "$1" "${2:-}"; XFER_ROOT="$2"; shift ;;
    --share-name)      need_arg "$1" "${2:-}"; XFER_SHARE="$2"; shift ;;
    --workgroup)       need_arg "$1" "${2:-}"; SAMBA_WORKGROUP="$2"; shift ;;
    --no-samba-discovery) SAMBA_DISCOVERY=0 ;;
    --rdp-port)        need_arg "$1" "${2:-}"; XRDP_PORT="$2"; shift ;;
    --vllm-runtime)    need_arg "$1" "${2:-}"; VLLM_RUNTIME="$2"; shift ;;
    --vllm-image)      need_arg "$1" "${2:-}"; VLLM_IMAGE="$2"; shift ;;
    --container-engine) need_arg "$1" "${2:-}"; CONTAINER_ENGINE="$2"; shift ;;
    --gtt-gib)         need_arg "$1" "${2:-}"; GTT_GIB="$2"; shift ;;
    --no-oom-guard)    CONFIGURE_OOM_GUARD=0 ;;
    --no-zram)         ZRAM_ENABLE=0 ;;
    --no-model-gc)     CONFIGURE_MODEL_GC=0 ;;
    --skip)            need_arg "$1" "${2:-}"; skip_component "$2"; shift ;;
    --journal-max)     need_arg "$1" "${2:-}"; JOURNAL_MAX_USE="$2"; shift ;;
    --smart-email)     need_arg "$1" "${2:-}"; SMART_ALERT_EMAIL="$2"; shift ;;
    --keep-radios)     DISABLE_WIFI=0; DISABLE_BLUETOOTH=0 ;;
    -y|--yes)          ASSUME_YES=1 ;;
    -h|--help)         usage; exit 0 ;;
    *) die "unknown option '$1' (try --help)" ;;
  esac
  shift
done

# --- preflight ---------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Please run with sudo:  sudo ./$SCRIPT_NAME --server <a> --peer <b>"

valid_hostname() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }

[ -n "$SERVER_HOST" ] && [ -n "$PEER_HOST" ] || {
  usage >&2
  echo >&2
  die "--server and --peer are required (the two cluster hostnames)."
}
valid_hostname "$SERVER_HOST" || die "--server '$SERVER_HOST' is not a valid hostname label."
valid_hostname "$PEER_HOST"   || die "--peer '$PEER_HOST' is not a valid hostname label."
[ "$SERVER_HOST" != "$PEER_HOST" ] || die "--server and --peer must be DIFFERENT hostnames."

case "$VLLM_RUNTIME" in venv|container) ;; *) die "--vllm-runtime must be 'venv' or 'container'" ;; esac
case "$CONTAINER_ENGINE" in auto|podman|docker) ;; *) die "--container-engine must be 'podman', 'docker' or 'auto'" ;; esac
for _p in "$GATEWAY_PORT" "$WEBUI_PORT" "$COMFYUI_PORT" "$XRDP_PORT" "$RAY_PORT" "$AGENT_PORT" "$VLLM_PORT_BASE"; do
  [[ "$_p" =~ ^[0-9]+$ ]] && [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ] || die "invalid port '$_p'"
done
[[ "$CLUSTER_NET" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || \
  die "--cluster-net must be the first THREE octets of the link subnet, e.g. 10.44.0"
[[ "$CLUSTER_CIDR" =~ ^([89]|1[0-9]|2[0-9]|30)$ ]] || die "CLUSTER_CIDR must be 8-30"
[[ "$CLUSTER_MTU" =~ ^[0-9]+$ ]] && [ "$CLUSTER_MTU" -ge 1280 ] && [ "$CLUSTER_MTU" -le 65520 ] || \
  die "--cluster-mtu must be between 1280 and 65520"
[[ "$CLUSTER_IFACE" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]] || die "--cluster-iface '$CLUSTER_IFACE' is not a valid interface name"

# Everything below is interpolated verbatim into a generated config file, and a
# malformed /etc/apt/apt.conf.d entry breaks EVERY subsequent apt call on the
# box - so these are validated here rather than discovered at runtime.
for _hold in $UNATTENDED_HOLD; do
  [[ "$_hold" =~ ^[A-Za-z0-9._+^$*?()|-]+$ ]] || \
    die "UNATTENDED_HOLD entry '$_hold' contains characters that would corrupt /etc/apt/apt.conf.d"
done
for _mod in $WIFI_BLOCK_MODULES $BT_BLOCK_MODULES; do
  [[ "$_mod" =~ ^[A-Za-z0-9_-]+$ ]] || die "'$_mod' is not a valid kernel module name"
done
[[ "$JOURNAL_MAX_USE"  =~ ^[0-9]+[KMGTkmgt]?$ ]] || die "--journal-max '$JOURNAL_MAX_USE' must be a size like 2G, 512M or 2048K"
[[ "$JOURNAL_KEEP_FREE" =~ ^[0-9]+[KMGTkmgt]?$ ]] || die "JOURNAL_KEEP_FREE '$JOURNAL_KEEP_FREE' must be a size like 1G"
[[ "$SMART_TEMP_LIMITS" =~ ^[0-9]+,[0-9]+,[0-9]+$ ]] || die "SMART_TEMP_LIMITS must be 'diff,info,crit' in degrees C, e.g. 4,65,75"
[[ "$SMART_ALERT_EMAIL" =~ ^([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})?$ ]] || \
  die "--smart-email '$SMART_ALERT_EMAIL' does not look like an email address"

# These end up on ComfyUI's command line. argparse exits 2 on a bad value, and a
# service that dies at startup is a much worse failure than a message here.
case "$COMFY_CACHE_MODE" in
  ram|classic|lru|none) ;;
  *) die "--comfy-cache must be 'ram', 'classic', 'lru' or 'none'" ;;
esac
case "$COMFY_PREVIEW_METHOD" in
  none|auto|latent2rgb|taesd) ;;
  *) die "--comfy-preview must be 'none', 'auto', 'latent2rgb' or 'taesd'" ;;
esac
for _cv in "$COMFY_CACHE_ACTIVE_GB" "$COMFY_CACHE_INACTIVE_GB" "$COMFY_RESERVE_VRAM"; do
  [[ "$_cv" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "ComfyUI memory settings must be numbers in GiB (got '$_cv')"
done
[[ "$COMFY_CACHE_LRU" =~ ^[0-9]+$ ]] || die "COMFY_CACHE_LRU must be a whole number of cached node results"
[ "${COMFY_CACHE_ACTIVE_GB%%.*}" -le "${COMFY_CACHE_INACTIVE_GB%%.*}" ] || \
  die "COMFY_CACHE_ACTIVE_GB ($COMFY_CACHE_ACTIVE_GB) must not exceed COMFY_CACHE_INACTIVE_GB ($COMFY_CACHE_INACTIVE_GB)"

case "$XRDP_DESKTOP" in
  xfce|xfce4|auto|/*) ;;
  *) die "--desktop must be 'xfce', 'auto', or an absolute path to a session binary" ;;
esac
for _b in "$DESKTOP_HEADLESS_BOOT:DESKTOP_HEADLESS_BOOT" "$XFCE_COMPOSITING:XFCE_COMPOSITING"; do
  case "${_b%%:*}" in 0|1) ;; *) die "${_b#*:} must be 0 or 1" ;; esac
done

# --- which node am I? --------------------------------------------------------
THIS_HOST="$(hostname -s 2>/dev/null || true)"
[ -n "$THIS_HOST" ] || THIS_HOST="$(cat /etc/hostname 2>/dev/null | head -n1 || true)"

case "$NODE_ROLE" in
  server|peer) ;;
  auto)
    if [ "$THIS_HOST" = "$SERVER_HOST" ]; then NODE_ROLE=server
    elif [ "$THIS_HOST" = "$PEER_HOST" ]; then NODE_ROLE=peer
    else
      cat >&2 <<EOF
${RED}${BOLD}ERROR:${RST} this machine is called '${THIS_HOST:-<unknown>}', which matches neither
       --server '$SERVER_HOST' nor --peer '$PEER_HOST', so the script cannot tell
       which half of the cluster to install.

Fix it either way round:
  * name the box first, then re-run:
        sudo hostnamectl set-hostname $SERVER_HOST   # (or $PEER_HOST)
        # log out and back in, then re-run this script
  * or let the script name it for you:
        sudo ./$SCRIPT_NAME --server $SERVER_HOST --peer $PEER_HOST \\
             --role server --set-hostname
EOF
      exit 1
    fi
    ;;
  *) die "--role must be 'server', 'peer' or 'auto'" ;;
esac

if [ "$NODE_ROLE" = "server" ]; then
  IS_SERVER=1; IS_PEER=0
  MY_HOST="$SERVER_HOST"; OTHER_HOST="$PEER_HOST"
  CLUSTER_LOCAL_IP="${CLUSTER_NET}.1"; CLUSTER_PEER_IP="${CLUSTER_NET}.2"
else
  IS_SERVER=0; IS_PEER=1
  MY_HOST="$PEER_HOST"; OTHER_HOST="$SERVER_HOST"
  CLUSTER_LOCAL_IP="${CLUSTER_NET}.2"; CLUSTER_PEER_IP="${CLUSTER_NET}.1"
fi
SERVER_IP="${CLUSTER_NET}.1"
PEER_IP="${CLUSTER_NET}.2"
SERVER_USB4_NAME="${SERVER_HOST}-usb4"
PEER_USB4_NAME="${PEER_HOST}-usb4"

if [ "$SET_HOSTNAME" = "1" ] && [ "$THIS_HOST" != "$MY_HOST" ]; then
  hostnamectl set-hostname "$MY_HOST" || die "could not set the hostname to '$MY_HOST'"
  # Keep /etc/hosts consistent so sudo does not stall on an unresolvable name.
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$MY_HOST/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$MY_HOST" >> /etc/hosts
  fi
  ok "hostname changed from '${THIS_HOST:-<unset>}' to '$MY_HOST'"
  THIS_HOST="$MY_HOST"
  note_action "The hostname changed to '$MY_HOST'; open a new login shell (or reboot) so your prompt and \$HOSTNAME catch up."
fi

# --- the unprivileged service/desktop account -------------------------------
if [ -n "$TARGET_PASSWORD_FILE" ]; then
  [ -r "$TARGET_PASSWORD_FILE" ] || die "--password-file '$TARGET_PASSWORD_FILE' is not readable"
  TARGET_PASSWORD="$(head -n1 "$TARGET_PASSWORD_FILE")"
fi
[ -n "$TARGET_USER" ] || die "Could not determine the service user. Pass --user <name>."
[ "$TARGET_USER" != "root" ] || die "--user must be an unprivileged account, not root."
valid_hostname "$TARGET_USER" || die "--user '$TARGET_USER' is not a valid account name."

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  [ -n "$TARGET_PASSWORD" ] || die "user '$TARGET_USER' does not exist. Create it first, or pass --password / --password-file so this script can."
  adduser --disabled-password --gecos "" "$TARGET_USER" >/dev/null 2>&1 \
    || useradd -m -s /bin/bash "$TARGET_USER" \
    || die "could not create the account '$TARGET_USER'"
  printf '%s:%s\n' "$TARGET_USER" "$TARGET_PASSWORD" | chpasswd || die "could not set the password for '$TARGET_USER'"
  usermod -aG sudo "$TARGET_USER" || true
  ok "created account '$TARGET_USER' (sudo group, password set)"
elif [ -n "$TARGET_PASSWORD" ]; then
  printf '%s:%s\n' "$TARGET_USER" "$TARGET_PASSWORD" | chpasswd \
    && ok "password for '$TARGET_USER' set from the supplied value" \
    || warn "could not set the password for '$TARGET_USER'"
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$USER_HOME" ] && [ -d "$USER_HOME" ] || die "Home directory for '$TARGET_USER' not found."
UV_BIN="$USER_HOME/.local/bin/uv"
COMFY_DIR="$USER_HOME/ComfyUI"

as_user() { sudo -u "$TARGET_USER" -H bash -lc "$*"; }
# uv, used for every isolated Python environment on this box, installed once
# system-wide so root-owned service venvs do not depend on a user's home dir.
UV_SYS="/usr/local/bin/uv"

# Where uv is allowed to keep the interpreters it downloads. This is NOT a
# detail: by default uv puts them under $HOME/.local/share/uv/python, and for
# root that is /root/.local/share/uv/python - mode 0700. A venv built there by
# root has bin/python as a symlink into a directory no service account can
# traverse, so every unit that runs as a non-root user dies at exec time with
# 203/EXEC - "Permission denied" if ExecStart is a script whose interpreter is
# unreachable, "No such file or directory" if ExecStart is the symlink itself.
# ComfyUI escapes this only because its venv is built AS the desktop user.
UV_PYTHON_DIR="${UV_PYTHON_DIR:-/opt/uv-python}"
export UV_PYTHON_INSTALL_DIR="$UV_PYTHON_DIR"

# Is this venv's interpreter one a service account can actually execute?
# Echoes the resolved interpreter and returns 0 when it is.
venv_interp_ok() {  # $1 venv-path
  local cur
  [ -e "$1/pyvenv.cfg" ] || return 1
  cur="$(readlink -f "$1/bin/python" 2>/dev/null || echo "")"
  [ -n "$cur" ] && [ -x "$cur" ] || return 1
  case "$cur" in
    "$UV_PYTHON_DIR"/*|/usr/*) printf '%s\n' "$cur"; return 0 ;;
    *) printf '%s\n' "$cur"; return 1 ;;
  esac
}

# Build a root-owned venv that a service account can actually execute.
uv_root_venv() {  # $1 python-version  $2 venv-path
  local pyver="$1" dest="$2" py="" cur=""
  # Refuse to operate on a path that could take the rest of the system with it
  # when this function decides a rebuild is needed.
  case "$dest" in
    /|/usr|/opt|/var|/etc|/srv|"") die "uv_root_venv: refusing to manage '$dest'" ;;
  esac
  install -d -m 0755 "$UV_PYTHON_DIR" 2>/dev/null || true

  # Already healthy? Return without touching it. This is not just an
  # optimisation: uv REFUSES to create a venv over an existing directory (see
  # below), and rebuilding would re-download Open WebUI's whole ML stack on
  # every run.
  if cur="$(venv_interp_ok "$dest")"; then
    chmod -R a+rX "$UV_PYTHON_DIR" 2>/dev/null || true
    chmod a+rX "$dest" 2>/dev/null || true
    return 0
  fi
  if [ -e "$dest/pyvenv.cfg" ]; then
    warn "  rebuilding $dest: its interpreter (${cur:-missing}) is not reachable by a service account"
  fi

  # Fetch the interpreter EXPLICITLY into the directory we control, then hand
  # 'uv venv' that exact path. Exporting UV_PYTHON_INSTALL_DIR is not enough on
  # a box that has run an older version of this script: an interpreter already
  # unpacked under /root/.local/share/uv/python is still a candidate for uv's
  # discovery, and once a venv points at it every non-root unit dies 203/EXEC.
  # </dev/null on every uv call: uv prompts on a terminal, and a prompt inside a
  # provisioning run is an unattended hang.
  "$UV_SYS" python install "$pyver" </dev/null >/dev/null 2>&1 || true
  for _c in "$UV_PYTHON_DIR"/cpython-"$pyver"*/bin/python3 \
            "$UV_PYTHON_DIR"/cpython-"$pyver"*/bin/python; do
    [ -x "$_c" ] && { py="$_c"; break; }
  done

  # uv (0.12) will not create a venv where a directory already exists:
  #   "error: Failed to create virtual environment
  #    Caused by: A directory already exists at: /opt/llm-gateway"
  # and its --clear flag only applies to a directory that IS a virtualenv
  # ("uv will not clear a directory that is not a virtual environment").
  # Clearing it ourselves needs no flags and behaves the same on every uv
  # version. It is safe because both callers keep their application files
  # elsewhere or rewrite them immediately afterwards - note that uv's own
  # --clear would delete those files too.
  rm -rf "$dest" 2>/dev/null || true

  if [ -n "$py" ]; then
    "$UV_SYS" venv --python "$py" "$dest" </dev/null >/dev/null 2>&1 || return 1
  else
    "$UV_SYS" venv --python "$pyver" "$dest" </dev/null >/dev/null 2>&1 || return 1
  fi
  # uv honours root's umask for the interpreters it unpacks, and 'uv venv' does
  # not widen them afterwards. Make the whole chain traversable+readable.
  chmod -R a+rX "$UV_PYTHON_DIR" 2>/dev/null || true
  chmod a+rX "$dest" 2>/dev/null || true
  # Refuse to report success on a venv whose interpreter is somewhere no service
  # account can reach. root can traverse /root, so a bare '[ -x ]' says yes to a
  # file that is unusable for the unit - which is exactly how this shipped.
  if cur="$(venv_interp_ok "$dest")"; then
    return 0
  fi
  warn "  $dest/bin/python resolves to ${cur:-nothing}, outside $UV_PYTHON_DIR"
  return 1
}

# Run a command as another account without a login shell. Returns the command's
# own status, or 126 if the drop-privileges mechanism is unusable here - which
# is NOT the same as "the command failed". Each backend is proved with /bin/true
# first, so a container, a user namespace or a stripped-down sudoers policy
# produces "cannot test" rather than a false accusation.
run_as_svc() {  # $1 user  $2.. command
  local u="$1"; shift
  local g; g="$(id -gn "$u" 2>/dev/null || echo "$u")"
  if command -v setpriv >/dev/null 2>&1 \
     && setpriv --reuid="$u" --regid="$g" --clear-groups /bin/true >/dev/null 2>&1; then
    setpriv --reuid="$u" --regid="$g" --clear-groups "$@" >/dev/null 2>&1
    return $?
  fi
  if command -v runuser >/dev/null 2>&1 && runuser -u "$u" -- /bin/true >/dev/null 2>&1; then
    runuser -u "$u" -- "$@" >/dev/null 2>&1
    return $?
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n -u "$u" /bin/true >/dev/null 2>&1; then
    sudo -n -u "$u" "$@" >/dev/null 2>&1
    return $?
  fi
  return 126
}

# Prove the interpreter runs as the account the unit will use, rather than
# discovering it 179 restarts later in the journal.
venv_execs_as() {  # $1 service-user  $2 venv-path
  local u="$1" dest="$2"
  id "$u" >/dev/null 2>&1 || return 0   # account missing: a different problem
  run_as_svc "$u" "$dest/bin/python" -c 'import sys'
  case $? in
    0|126) return 0 ;;                  # ran, or could not be tested here
    *)     return 1 ;;
  esac
}

# Everything below drops helpers into /usr/local. Ubuntu ships these, but a
# minimal or container-built image may not, and a missing directory turns into
# a confusing "No such file or directory" from a redirect halfway through.
install -d -m 0755 /usr/local/bin /usr/local/lib /usr/local/share

log "Strix Halo cluster node setup"
echo "     role          : ${BOLD}${NODE_ROLE}${RST}  (this box is '$MY_HOST'; the other node is '$OTHER_HOST')"
echo "     cluster       : $SERVER_HOST=$SERVER_IP  <-USB4->  $PEER_HOST=$PEER_IP  (/$CLUSTER_CIDR on $CLUSTER_IFACE, mtu $CLUSTER_MTU)"
echo "     user          : $TARGET_USER ($USER_HOME)"
echo "     LAN ports     : gateway=$GATEWAY_PORT webui=$WEBUI_PORT comfyui=$COMFYUI_PORT rdp=$XRDP_PORT"
echo "     shared stores : $LLM_ROOT (LLM, ro on the peer)   $COMFY_ROOT (ComfyUI, rw on both)"
echo "     vLLM runtime  : $VLLM_RUNTIME$([ "$VLLM_RUNTIME" = container ] && echo " ($VLLM_IMAGE)")"
if command -v lsb_release >/dev/null 2>&1; then
  echo "     ubuntu        : $(lsb_release -ds 2>/dev/null)"
fi
if lspci 2>/dev/null | grep -iE 'AMD.*(Radeon|Strix|VGA|Display)' >/dev/null; then
  ok "AMD GPU detected: $(lspci | grep -iE 'VGA|Display' | head -n1 | cut -d: -f3- | sed 's/^ //')"
else
  warn "No AMD GPU line matched via lspci; continuing anyway."
fi

# gfx1151 needs the recent AMD KFD kernel fixes for full memory access + ROCm.
kmaj="$(uname -r | cut -d. -f1)"; kmin="$(uname -r | cut -d. -f2)"
if [ "${kmaj:-0}" -gt 6 ] || { [ "${kmaj:-0}" -eq 6 ] && [ "${kmin:-0}" -ge 17 ]; }; then
  ok "kernel $(uname -r) includes the gfx1151 KFD/memory fixes"
else
  warn "kernel $(uname -r) may PREDATE the gfx1151 (Strix Halo) KFD fixes."
  warn "  AMD requires Ubuntu 26.04, Ubuntu 24.04 HWE >= 6.17.0-19.19, or >= 6.18.4."
fi
echo

# =============================================================================
# 1.3 UNATTENDED MAINTENANCE AND HOST HARDENING
# =============================================================================
# Four things a headless box that runs for a year needs, and that nothing else
# in this script covers:
#
#   updates      security patches applied on their own -- but NEVER the kernel
#                or ROCm, because an unattended bump there silently breaks
#                gfx1151 and takes the amdttm parameters with it.
#   journal      a hard cap on journald so logs cannot fill the root filesystem.
#   disk health  SMART monitoring and weekly TRIM for the NVMe drives, which do
#                nothing but stream model weights all day.
#   radios       Wi-Fi and Bluetooth removed from the attack surface entirely:
#                this cluster talks over Ethernet and one USB4 cable.
#
# Each section rewrites its config only when the content actually changes, so a
# second run is silent and does not restart services or rebuild the initramfs.

# Writes $2 to $1 only if it differs, creating the parent directory first.
# Returns 0 = written, 1 = already correct, 2 = could not write. Every generated
# file in this section goes through it, which is what makes re-running the
# script cheap instead of disruptive -- and the 2 case matters, because a
# silently unwritten policy file is worse than no policy at all.
write_if_changed() { # $1 dest  $2 src(tmp)  $3 mode
  install -d -m 0755 "$(dirname "$1")" >/dev/null 2>&1 || true
  if [ -f "$1" ] && cmp -s "$1" "$2"; then
    return 1
  fi
  install -m "${3:-0644}" "$2" "$1" >/dev/null 2>&1 || return 2
  return 0
}

# -----------------------------------------------------------------------------
# 1.3.1  Unattended SECURITY updates, with the kernel and ROCm held back
# -----------------------------------------------------------------------------
if [ "$CONFIGURE_UPDATES" = "1" ]; then
  log "Configuring unattended security updates"
  export DEBIAN_FRONTEND=noninteractive
  if apt-get install -y unattended-upgrades >/dev/null 2>&1; then
    ok "unattended-upgrades installed"
  else
    warn "could not install unattended-upgrades - this node will need manual patching"
  fi

  # APT list options APPEND across files, they never replace. Without the
  # '#clear' lines the distro's own Allowed-Origins (and anything an admin added
  # later) survives underneath and this policy would only ever be additive --
  # which is exactly how '-updates' sneaks a new kernel onto the box.
  _uu_conf="/etc/apt/apt.conf.d/52-llm-cluster-unattended"
  _uu_tmp="$(mktemp)"
  {
    cat <<'UUHEAD'
// Managed by setup-strixhalo-ai-server.sh - do not edit by hand.
//
// SECURITY updates only, and never unattended for the kernel or the ROCm
// stack: gfx1151 support is version-sensitive, so those two are upgraded
// deliberately, by a human, who is watching, and who can reboot afterwards.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
#clear Unattended-Upgrade::Package-Blacklist;

Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
UUHEAD
    for _hold in $UNATTENDED_HOLD; do printf '    "%s";\n' "$_hold"; done
    cat <<'UUTAIL'
};

// An inference cluster must never reboot itself out from under a running job.
// Reboots are the operator's call; the flag file below is how you find out one
// is needed.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";

// Kernels are blacklisted above, so letting the autoremover rip kernel packages
// out would leave the box in a half-upgraded state nobody asked for.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";

// Apply one package at a time so an interrupted run leaves dpkg consistent.
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::SyslogEnable "true";

// Mini PCs sometimes expose a CMOS or UPS battery as a power supply, and the
// default behaviour is to skip the run entirely when "on battery".
Unattended-Upgrade::OnlyOnACPower "false";
Unattended-Upgrade::Skip-Updates-On-Metered-Connections "false";

APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
UUTAIL
  } > "$_uu_tmp"

  # Validate BEFORE installing. A syntax error in /etc/apt/apt.conf.d breaks
  # every apt command on the machine, including the ones later in this script,
  # so the generated file is parsed in isolation first.
  if APT_CONFIG="$_uu_tmp" apt-config dump >/dev/null 2>&1; then
    _uu_rc=0; write_if_changed "$_uu_conf" "$_uu_tmp" 0644 || _uu_rc=$?
    case "$_uu_rc" in
      0) ok "$_uu_conf written" ;;
      1) ok "$_uu_conf already up to date" ;;
      *) warn "could not write $_uu_conf"
         note_action "Could not write $_uu_conf. The kernel and ROCm are NOT held back from unattended upgrades." ;;
    esac

    # Report what apt itself resolved, not what we intended to write: this is
    # the only check that proves nothing else in apt.conf.d overrides us.
    _uu_reboot="$(apt-config dump --format '%v%n' Unattended-Upgrade::Automatic-Reboot 2>/dev/null | head -n1)"
    if [ "$_uu_reboot" = "false" ]; then
      ok "automatic reboot is OFF (a pending reboot shows up in /var/run/reboot-required)"
    else
      warn "Unattended-Upgrade::Automatic-Reboot resolves to '${_uu_reboot:-unset}', not 'false'"
      note_action "Another file in /etc/apt/apt.conf.d re-enables automatic reboots. Check: apt-config dump Unattended-Upgrade::Automatic-Reboot"
    fi
    _uu_bl="$(apt-config dump Unattended-Upgrade::Package-Blacklist 2>/dev/null || true)"
    _uu_missing=""
    for _hold in $UNATTENDED_HOLD; do
      grep -F "\"$_hold\"" <<<"$_uu_bl" >/dev/null || _uu_missing="$_uu_missing $_hold"
    done
    if [ -z "$_uu_missing" ]; then
      ok "held back from unattended upgrades: $(echo "$UNATTENDED_HOLD" | tr ' ' ',')"
    else
      warn "these did not make it into the blacklist:$_uu_missing"
    fi
  else
    warn "the generated unattended-upgrades config did not parse - leaving the distro default in place"
    note_action "Could not write $_uu_conf (apt rejected it). The kernel and ROCm are NOT held back from unattended upgrades."
  fi
  rm -f "$_uu_tmp"

  # The timers are what actually run it; the service is oneshot and ordinarily
  # sits inactive between runs, so 'enabled' is the only meaningful state.
  for _t in apt-daily.timer apt-daily-upgrade.timer; do
    systemctl enable "$_t" >/dev/null 2>&1 || true
    systemctl start  "$_t" >/dev/null 2>&1 || true
    if systemctl is-enabled "$_t" >/dev/null 2>&1; then
      ok "$_t enabled"
    else
      warn "$_t is not enabled - updates will never run on their own"
    fi
  done
  systemctl enable unattended-upgrades.service >/dev/null 2>&1 || true
  echo
fi

# -----------------------------------------------------------------------------
# 1.3.2  Cap journald so logs cannot fill the root filesystem
# -----------------------------------------------------------------------------
# vLLM, Ray and residencyd are all chatty, and a full / is the one failure that
# takes down every service at once and leaves you unable to log in to fix it.
if [ "$CONFIGURE_JOURNAL" = "1" ]; then
  log "Capping systemd-journald disk usage at $JOURNAL_MAX_USE"
  install -d -m 0755 /etc/systemd/journald.conf.d
  _jr_conf="/etc/systemd/journald.conf.d/10-llm-cluster.conf"
  _jr_tmp="$(mktemp)"
  cat > "$_jr_tmp" <<EOF
# Managed by setup-strixhalo-ai-server.sh
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=${JOURNAL_MAX_USE}
SystemKeepFree=${JOURNAL_KEEP_FREE}
RuntimeMaxUse=256M
EOF
  _jr_rc=0; write_if_changed "$_jr_conf" "$_jr_tmp" 0644 || _jr_rc=$?
  case "$_jr_rc" in
    0) ok "$_jr_conf written (SystemMaxUse=$JOURNAL_MAX_USE, SystemKeepFree=$JOURNAL_KEEP_FREE)"
       systemctl restart systemd-journald >/dev/null 2>&1 \
         && ok "systemd-journald restarted" \
         || warn "could not restart systemd-journald; the cap applies from the next boot" ;;
    1) ok "$_jr_conf already up to date" ;;
    *) warn "could not write $_jr_conf - the journal is still uncapped"
       note_action "Could not write $_jr_conf. Journald has no size limit on this node." ;;
  esac
  rm -f "$_jr_tmp"

  # The cap only bounds future growth. If this box has been running a while,
  # shrink what is already on disk now.
  journalctl --vacuum-size="$JOURNAL_MAX_USE" >/dev/null 2>&1 || true
  _jr_usage="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?[KMGTP]' | head -n1 || true)"
  [ -n "$_jr_usage" ] && ok "journal currently occupies ${_jr_usage}B"
  echo
fi

# -----------------------------------------------------------------------------
# 1.3.3  Disk health: SMART monitoring + periodic TRIM
# -----------------------------------------------------------------------------
# Four NVMe drives across the pair, all doing sustained sequential reads of
# model weights and constant small writes of KV/compile caches. Wear and heat
# are the realistic failure modes, and both are visible long before the drive
# actually dies -- if something is looking.
if [ "$CONFIGURE_DISK_HEALTH" = "1" ]; then
  log "Enabling SMART monitoring and periodic TRIM"
  if apt-get install -y smartmontools >/dev/null 2>&1; then
    ok "smartmontools installed"

    # Keep the packaged config once, so the generated one can always be undone.
    if [ -f /etc/smartd.conf ] && [ ! -f /etc/smartd.conf.pre-llm-cluster ]; then
      cp -a /etc/smartd.conf /etc/smartd.conf.pre-llm-cluster
    fi
    _sm_mail=""
    [ -n "$SMART_ALERT_EMAIL" ] && _sm_mail=" -m $SMART_ALERT_EMAIL -M exec /usr/share/smartmontools/smartd-runner"
    _sm_tmp="$(mktemp)"
    cat > "$_sm_tmp" <<EOF
# Managed by setup-strixhalo-ai-server.sh
# (the packaged original is kept at /etc/smartd.conf.pre-llm-cluster)
#
# DEVICESCAN picks up every NVMe and SATA device, including ones added later.
# -a       health, error log and self-test log
# -W d,i,c temperature: log a change of d C, info at i C, critical at c C
# Alerts always reach the journal: 'journalctl -u smartd' or -t smartd.
DEVICESCAN -a -W ${SMART_TEMP_LIMITS}${_sm_mail}
EOF
    _sm_rc=0; write_if_changed /etc/smartd.conf "$_sm_tmp" 0644 || _sm_rc=$?
    case "$_sm_rc" in
      0) ok "/etc/smartd.conf written (temperature limits ${SMART_TEMP_LIMITS} C)" ;;
      1) ok "/etc/smartd.conf already up to date" ;;
      *) warn "could not write /etc/smartd.conf; smartd keeps its packaged defaults" ;;
    esac
    rm -f "$_sm_tmp"

    # Debian renamed the unit; both names are in the wild depending on release.
    _sm_unit=""
    for _u in smartd.service smartmontools.service; do
      if systemctl cat "$_u" >/dev/null 2>&1; then _sm_unit="$_u"; break; fi
    done
    if [ -n "$_sm_unit" ]; then
      systemctl enable "$_sm_unit" >/dev/null 2>&1 || true
      systemctl restart "$_sm_unit" >/dev/null 2>&1 || true
      if systemctl is-active --quiet "$_sm_unit"; then
        ok "$_sm_unit active - drives are monitored continuously"
      else
        warn "$_sm_unit did not start with the generated config; restoring the packaged one"
        if [ -f /etc/smartd.conf.pre-llm-cluster ]; then
          cp -a /etc/smartd.conf.pre-llm-cluster /etc/smartd.conf
          systemctl restart "$_sm_unit" >/dev/null 2>&1 || true
        fi
        systemctl is-active --quiet "$_sm_unit" \
          && ok "$_sm_unit active with the packaged config" \
          || note_action "smartd is not running. Check: journalctl -u $_sm_unit -n 50"
      fi
    else
      warn "no smartd/smartmontools service unit found"
    fi

    # An immediate read-out, because "monitoring is on" is worth much less than
    # knowing whether these particular drives are already worn or running hot.
    #
    # Removable and USB-attached devices are skipped on purpose. A USB bridge
    # rarely passes SMART commands through, so smartctl reports no health at
    # all - which the old code announced as "did not report a healthy SMART
    # status", i.e. it called a perfectly good installer stick a failing drive.
    # Each attribute is queried one column at a time: 'lsblk -o NAME,TYPE,TRAN'
    # pads empty columns, so a device with no transport shifts the later fields
    # and the parse silently reads the wrong value.
    for _dev in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print "/dev/"$1}'); do
      _sm_tran="$(lsblk -dno TRAN "$_dev" 2>/dev/null | tr -d '[:space:]' || true)"
      _sm_rm="$(lsblk -dno RM   "$_dev" 2>/dev/null | tr -d '[:space:]' || true)"
      if [ "$_sm_tran" = "usb" ] || [ "$_sm_rm" = "1" ]; then
        info "skipping $_dev (${_sm_tran:-removable} media - SMART is not exposed through it)"
        continue
      fi
      _sm_out="$(smartctl -H -A "$_dev" 2>/dev/null || true)"
      [ -n "$_sm_out" ] || continue
      if grep -Ei 'overall-health.*PASSED|SMART Health Status: *OK' <<<"$_sm_out" >/dev/null; then
        _sm_used="$(awk -F: '/Percentage Used/{gsub(/[^0-9]/,"",$2); print $2; exit}' <<<"$_sm_out")"
        _sm_temp="$(awk -F: '/^Temperature:/{gsub(/[^0-9]/,"",$2); print $2; exit}' <<<"$_sm_out")"
        ok "SMART OK: $_dev${_sm_used:+  ${_sm_used}% of rated endurance used}${_sm_temp:+  ${_sm_temp} C}"
      elif grep -Ei 'SMART support is: *(Unavailable|Disabled)|does not support SMART|Unknown USB bridge|Operation not supported|Unable to detect device type' \
             <<<"$_sm_out" >/dev/null; then
        # No health verdict at all. That is a missing feature, not a bad drive,
        # so it must not raise an action item the operator cannot resolve.
        info "$_dev does not expose SMART - nothing to monitor on it"
      else
        warn "$_dev did not report a healthy SMART status - inspect it: smartctl -a $_dev"
        note_action "SMART health for $_dev is not 'PASSED'. Run: sudo smartctl -a $_dev"
      fi
    done
  else
    warn "could not install smartmontools - drive failures will go unnoticed"
  fi

  # Weekly discard. Deliberately the timer and not the 'discard' mount option:
  # continuous discard adds latency to every delete, which on a box streaming
  # model weights is a real cost for no benefit.
  if systemctl enable --now fstrim.timer >/dev/null 2>&1 && systemctl is-enabled fstrim.timer >/dev/null 2>&1; then
    ok "fstrim.timer enabled ($(systemctl show -p Description --value fstrim.timer 2>/dev/null || echo 'periodic TRIM'))"
  else
    warn "could not enable fstrim.timer - SSD write performance will decay over time"
  fi
  echo
fi

# -----------------------------------------------------------------------------
# 1.3.4  Turn off the Wi-Fi and Bluetooth controllers
# -----------------------------------------------------------------------------
# 'install <mod> /bin/false' rather than 'blacklist <mod>'. blacklist only stops
# udev-driven autoloading: anything that lists the module as a dependency, or
# any explicit modprobe, still pulls it straight back in. 'install' replaces the
# load command itself, so the module genuinely cannot be loaded.
#
# cfg80211 is the wedge. Every in-tree 802.11 driver depends on it, so blocking
# it disables Wi-Fi on whatever card this particular box shipped with -- these
# mini PCs ship MediaTek on some SKUs and Realtek on others -- without having to
# guess the vendor. bluetooth plays the same role for the BT stack.
if [ "$DISABLE_WIFI" = "1" ] || [ "$DISABLE_BLUETOOTH" = "1" ]; then
  log "Disabling the Wi-Fi and Bluetooth controllers"

  # Never cut the branch we are sitting on: if this machine's only route to the
  # world is over Wi-Fi, disabling it mid-install strands the box.
  _rd_if="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [ "$DISABLE_WIFI" = "1" ] && [ -n "$_rd_if" ] \
     && { [ -e "/sys/class/net/$_rd_if/phy80211" ] || [ -d "/sys/class/net/$_rd_if/wireless" ]; } \
     && [ "$RADIO_DISABLE_FORCE" != "1" ]; then
    warn "this node's default route runs over the wireless interface '$_rd_if'."
    warn "  Disabling Wi-Fi would strand the machine, so it is being left alone."
    warn "  Move to Ethernet and re-run, or override with RADIO_DISABLE_FORCE=1."
    note_action "Wi-Fi was NOT disabled: '$_rd_if' is currently this node's only route. Connect Ethernet, then re-run the script."
    DISABLE_WIFI=0
  fi

  _rd_mods=""
  [ "$DISABLE_WIFI" = "1" ]      && _rd_mods="$_rd_mods $WIFI_BLOCK_MODULES"
  [ "$DISABLE_BLUETOOTH" = "1" ] && _rd_mods="$_rd_mods $BT_BLOCK_MODULES"
  _rd_mods="$(echo "$_rd_mods" | xargs 2>/dev/null || echo "$_rd_mods")"

  _rd_conf="/etc/modprobe.d/llm-cluster-radios.conf"
  if [ -n "$_rd_mods" ]; then
    _rd_tmp="$(mktemp)"
    {
      echo "# Managed by setup-strixhalo-ai-server.sh"
      echo "# This cluster uses Ethernet and one USB4 cable. The radios are off."
      echo "# 'install ... /bin/false' makes these modules unloadable, which"
      echo "# 'blacklist' alone does not: a dependency would still drag them in."
      echo "# Undo by deleting this file and running: sudo update-initramfs -u"
      for _m in $_rd_mods; do echo "install $_m /bin/false"; done
    } > "$_rd_tmp"
    _rd_rc=0; write_if_changed "$_rd_conf" "$_rd_tmp" 0644 || _rd_rc=$?
    case "$_rd_rc" in
      0) ok "$_rd_conf written: $_rd_mods"
         # These can be baked into the initramfs, so it has to be rebuilt or the
         # early-boot copy loads them again before the rootfs is even mounted.
         if command -v update-initramfs >/dev/null 2>&1; then
           update-initramfs -u >/dev/null 2>&1 \
             && ok "initramfs rebuilt" \
             || warn "update-initramfs failed; the radios may still load early at boot"
         fi ;;
      1) ok "$_rd_conf already up to date" ;;
      *) warn "could not write $_rd_conf - the radios stay enabled"
         note_action "Could not write $_rd_conf. Wi-Fi and Bluetooth are still active on this node." ;;
    esac
    rm -f "$_rd_tmp"
  fi

  # Stop the userspace half too, or bluetoothd sits there retrying forever and
  # filling the journal we just capped.
  if [ "$DISABLE_BLUETOOTH" = "1" ]; then
    systemctl disable --now bluetooth.service >/dev/null 2>&1 || true
    systemctl mask bluetooth.service >/dev/null 2>&1 || true
    ok "bluetooth.service disabled and masked"
  fi
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    [ "$DISABLE_WIFI" = "1" ]      && { nmcli radio wifi off >/dev/null 2>&1 || true; }
    [ "$DISABLE_BLUETOOTH" = "1" ] && { nmcli radio wwan off >/dev/null 2>&1 || true; }
  fi
  if command -v rfkill >/dev/null 2>&1; then
    [ "$DISABLE_WIFI" = "1" ]      && { rfkill block wifi      >/dev/null 2>&1 || true; }
    [ "$DISABLE_BLUETOOTH" = "1" ] && { rfkill block bluetooth >/dev/null 2>&1 || true; }
  fi

  # Best-effort unload of what is already running, deepest dependency last. A
  # module that is still in use simply stays until the reboot, which is fine:
  # the modprobe.d rule guarantees it never comes back.
  for _m in $(echo "$_rd_mods" | tr ' ' '\n' | tac | tr '\n' ' '); do
    lsmod 2>/dev/null | awk '{print $1}' | grep -x "$_m" >/dev/null || continue
    modprobe -r "$_m" >/dev/null 2>&1 || true
  done

  # Report the state that actually matters: is there still a radio interface?
  _rd_wifi_left=0
  for _n in /sys/class/net/*; do
    [ -e "$_n/phy80211" ] && _rd_wifi_left=1
  done
  _rd_bt_left=0
  for _n in /sys/class/bluetooth/hci*; do
    [ -e "$_n" ] && _rd_bt_left=1
  done
  if [ "$DISABLE_WIFI" = "1" ]; then
    if [ "$_rd_wifi_left" = "0" ]; then ok "no 802.11 interface is present"
    else warn "a Wi-Fi interface is still up; it disappears on the next reboot"; fi
  fi
  if [ "$DISABLE_BLUETOOTH" = "1" ]; then
    if [ "$_rd_bt_left" = "0" ]; then ok "no Bluetooth controller is present"
    else warn "a Bluetooth controller is still registered; it disappears on the next reboot"; fi
  fi
  note_action "Wi-Fi/Bluetooth are disabled in software. Turn the WLAN+BT module OFF in the BIOS as well so the hardware never enumerates at all."
  echo
fi

# =============================================================================
# 1. BASE PACKAGES, ACCOUNTS AND GROUPS
# =============================================================================
# Package list follows the plan (section 5) plus the handful of extras the rest
# of this script genuinely needs: ethtool (USB4 link inspection), cachefilesd
# (peer-side NFS read cache), rsync, and the Vulkan/radeontop diagnostics that
# make the iGPU observable from a desktop session.
if [ "$INSTALL_BASE" = "1" ]; then
  log "Installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    build-essential cmake ninja-build git curl wget ca-certificates gnupg jq \
    pciutils software-properties-common rsync unzip \
    python3 python3-pip python3-venv pipx \
    openssh-server nfs-common iperf3 bolt fwupd ethtool \
    mesa-vulkan-drivers vulkan-tools radeontop libfuse2t64
  ok "base packages installed"

  if [ "$IS_SERVER" = "1" ] && [ "$INSTALL_NFS" = "1" ]; then
    apt-get install -y nfs-kernel-server && ok "nfs-kernel-server installed (this node exports the shared stores)"
  fi

  systemctl enable --now ssh >/dev/null 2>&1 \
    && ok "OpenSSH server enabled" \
    || warn "could not enable the ssh service"

  # uv provisions every isolated Python environment on this box (vLLM, gateway,
  # Open WebUI, ComfyUI) without ever touching Ubuntu's system interpreter.
  # Installed system-wide because most of those venvs are root-owned services.
  if [ ! -x "$UV_SYS" ]; then
    if curl -LsSf --max-time 120 https://astral.sh/uv/install.sh \
         | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh >/dev/null 2>&1; then
      ok "uv installed to $UV_SYS"
    else
      warn "could not install uv system-wide; per-user installs are attempted later"
    fi
  else
    ok "uv already present at $UV_SYS ($("$UV_SYS" --version 2>/dev/null || echo 'version unknown'))"
  fi

  # --- model-hub CLIs (Hugging Face + ModelScope) ---------------------------
  # verify-and-seed-strixhalo-ai-server.sh AND 'llm-model pull' download models
  # through this venv. It lives outside the vLLM runtime on purpose: onboarding
  # has to work before the container/venv exists, and a broken model download
  # must never be able to disturb the serving stack. hf_transfer is the Rust
  # accelerator - without it a 60 GB repo pull is bounded by python, not by the
  # network. modelscope-hub is the current lightweight CLI package; the legacy
  # modelscope package remains a fallback for older package indexes.
  _modelscope_cli_available() {
    [ -x "$HF_TOOLS_VENV/bin/modelscope" ] || [ -x "$HF_TOOLS_VENV/bin/ms" ]
  }
  _install_modelscope_cli() {
    local _python="$HF_TOOLS_VENV/bin/python"
    if [ -x "$UV_SYS" ] && [ -x "$_python" ]; then
      "$UV_SYS" pip install --quiet --python "$_python" modelscope-hub >/dev/null 2>&1 \
        || "$UV_SYS" pip install --quiet --python "$_python" modelscope >/dev/null 2>&1 \
        || return 1
      _modelscope_cli_available || \
        "$UV_SYS" pip install --quiet --python "$_python" modelscope >/dev/null 2>&1
    elif [ -x "$HF_TOOLS_VENV/bin/pip" ]; then
      "$HF_TOOLS_VENV/bin/pip" install --quiet modelscope-hub >/dev/null 2>&1 \
        || "$HF_TOOLS_VENV/bin/pip" install --quiet modelscope >/dev/null 2>&1 \
        || return 1
      _modelscope_cli_available || \
        "$HF_TOOLS_VENV/bin/pip" install --quiet modelscope >/dev/null 2>&1
    else
      return 1
    fi
    _modelscope_cli_available
  }
  if [ ! -x "$HF_TOOLS_VENV/bin/hf" ] && [ ! -x "$HF_TOOLS_VENV/bin/huggingface-cli" ]; then
    hf_built=0
    if [ -x "$UV_SYS" ]; then
      uv_root_venv 3.12 "$HF_TOOLS_VENV" \
        && "$UV_SYS" pip install --quiet --python "$HF_TOOLS_VENV/bin/python" \
             "huggingface_hub[cli,hf_transfer]" >/dev/null 2>&1 \
        && _install_modelscope_cli \
        && hf_built=1
    fi
    if [ "$hf_built" != "1" ]; then
      python3 -m venv "$HF_TOOLS_VENV" >/dev/null 2>&1 \
        && "$HF_TOOLS_VENV/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 \
        && "$HF_TOOLS_VENV/bin/pip" install --quiet "huggingface_hub[cli,hf_transfer]" >/dev/null 2>&1 \
        && _install_modelscope_cli \
        && hf_built=1
    fi
    if [ "$hf_built" = "1" ]; then
      ok "model-hub CLIs installed to $HF_TOOLS_VENV (Hugging Face + ModelScope)"
    else
      warn "could not install the model-hub CLIs to $HF_TOOLS_VENV"
      note_action "The model-hub CLIs are missing, so model seeding / 'llm-model pull' cannot run. Install ModelScope with: sudo $UV_SYS pip install --python $HF_TOOLS_VENV/bin/python modelscope-hub (or use $HF_TOOLS_VENV/bin/pip if uv is unavailable)"
    fi
  else
    # hf is present; make sure a usable ModelScope CLI is too. uv-created
    # virtualenvs intentionally do not need a pip executable, so use uv's
    # explicit --python form before falling back to a traditional pip.
    if _modelscope_cli_available; then
      ok "model-hub CLIs already present in $HF_TOOLS_VENV"
    elif _install_modelscope_cli; then
      ok "added ModelScope CLI to the existing $HF_TOOLS_VENV"
    else
      warn "could not add ModelScope CLI to $HF_TOOLS_VENV ('llm-model pull ms:' will not work)"
      note_action "Install it with: sudo $UV_SYS pip install --python $HF_TOOLS_VENV/bin/python modelscope-hub (or use $HF_TOOLS_VENV/bin/pip if uv is unavailable)"
    fi
  fi

  # --- accounts + groups ----------------------------------------------------
  # Numeric ids are pinned so BOTH machines agree. NFS maps ownership by NUMBER,
  # not by name: if 'llm' is 970 here and 981 over there, the shared trees show
  # up with the wrong owner on one node and writes start failing in ways that
  # look like random permission bugs.
  ensure_group() {  # $1 name  $2 preferred gid
    if getent group "$1" >/dev/null 2>&1; then
      ok "group '$1' exists (gid $(getent group "$1" | cut -d: -f3))"
    elif getent group "$2" >/dev/null 2>&1; then
      groupadd "$1" && warn "gid $2 was already taken; group '$1' created with gid $(getent group "$1" | cut -d: -f3) - make the OTHER node match"
    else
      groupadd -g "$2" "$1" && ok "group '$1' created with gid $2"
    fi
  }
  ensure_sysuser() { # $1 name  $2 preferred uid  $3 primary group  $4 home
    if id "$1" >/dev/null 2>&1; then
      ok "system account '$1' exists (uid $(id -u "$1"))"
      return 0
    fi
    if getent passwd "$2" >/dev/null 2>&1; then
      useradd --system --gid "$3" --home-dir "$4" --create-home --shell /usr/sbin/nologin "$1" \
        && warn "uid $2 was already taken; '$1' created as uid $(id -u "$1") - make the OTHER node match"
    else
      useradd --system --uid "$2" --gid "$3" --home-dir "$4" --create-home --shell /usr/sbin/nologin "$1" \
        && ok "system account '$1' created with uid $2"
    fi
  }

  ensure_group "$SHARE_GROUP" "$SHARE_GID"
  ensure_group "$LLM_USER" "$LLM_UID"
  ensure_sysuser "$LLM_USER" "$LLM_UID" "$LLM_USER" "/var/lib/$LLM_USER"
  usermod -aG "$SHARE_GROUP" "$LLM_USER" || true
  usermod -aG "$SHARE_GROUP" "$TARGET_USER" || true

  if [ "$IS_SERVER" = "1" ]; then
    ensure_group "$GATEWAY_USER" "$GATEWAY_UID"
    ensure_sysuser "$GATEWAY_USER" "$GATEWAY_UID" "$GATEWAY_USER" "/var/lib/$GATEWAY_USER"
  fi

  # GPU compute access for the humans and the services.
  usermod -aG render,video "$TARGET_USER"
  usermod -aG render,video "$LLM_USER" || true
  ok "$TARGET_USER and $LLM_USER added to render,video (effective after reboot/re-login)"

  # Ubuntu normally ships these rules, but some images omit them and the symptom
  # is an obscure ROCm HSA_STATUS_ERROR_OUT_OF_RESOURCES rather than EACCES.
  # Keep MODE 0660 (group-only), never world-writable 0666.
  cat > /etc/udev/rules.d/70-amdgpu-compute.rules <<'UDEV'
# Managed by setup-strixhalo-ai-server.sh
KERNEL=="kfd", GROUP="render", MODE="0660"
SUBSYSTEM=="drm", KERNEL=="renderD[0-9]*", GROUP="render", MODE="0660"
UDEV
  udevadm control --reload-rules >/dev/null 2>&1 || true
  udevadm trigger >/dev/null 2>&1 || true
  ok "udev rules set for /dev/kfd + /dev/dri/renderD* (render group)"

  # AMD's Strix Halo guidance reports a few percent more prompt-processing
  # throughput under tuned's accelerator-performance profile. Best effort only.
  if apt-get install -y tuned >/dev/null 2>&1; then
    systemctl enable --now tuned >/dev/null 2>&1 || true
    if tuned-adm list 2>/dev/null | grep 'accelerator-performance' >/dev/null; then
      tuned-adm profile accelerator-performance >/dev/null 2>&1 \
        && ok "tuned profile 'accelerator-performance' active" \
        || warn "tuned present but could not select accelerator-performance"
    else
      tuned-adm profile throughput-performance >/dev/null 2>&1 || true
      warn "tuned lacks 'accelerator-performance'; selected throughput-performance"
    fi
  else
    warn "tuned unavailable; skipped the optional performance profile"
  fi
  echo
fi

# =============================================================================
# 1.2 DATA STORAGE  (make the two SSDs in each box earn their keep)
# =============================================================================
# Layout, identical canonical paths on both machines exactly as the plan
# requires, but with very different backing storage per role:
#
#   SERVER            $LLM_ROOT     <- optional dedicated SSD (--llm-disk)
#                     $COMFY_ROOT   <- optional dedicated SSD (--comfy-disk)
#                     both are exported over NFS on the USB4 link.
#
#   PEER              $LLM_ROOT     <- NFS mount, read-only
#                     $COMFY_ROOT   <- NFS mount, read-write
#                     $LLM_LOCAL_CACHE   <- optional SSD (--llm-disk): Ray object
#                        spill, torch/vLLM compile caches, NFS FS-Cache. All of
#                        those are hot, rewritten constantly, and must NEVER
#                        cross the USB4 link -- so the peer's own SSD is exactly
#                        the right home for them.
#                     $COMFY_LOCAL_CACHE <- optional SSD (--comfy-disk): ComfyUI
#                        temp/scratch and its per-node user settings.
#
# NOTHING is formatted unless --format-data-disks was passed AND the disk passes
# every safety check below.
if [ "$INSTALL_STORAGE" = "1" ]; then
  log "Preparing data storage"

  # Resolve where each disk should end up for THIS role.
  if [ "$IS_SERVER" = "1" ]; then
    LLM_MOUNT="$LLM_ROOT";   COMFY_MOUNT="$COMFY_ROOT"
  else
    LLM_MOUNT="$LLM_LOCAL_CACHE"; COMFY_MOUNT="$COMFY_LOCAL_CACHE"
  fi

  disk_is_safe() { # $1 = whole-disk device. Echoes a reason and returns 1 if not.
    local dev="$1" root_src root_disk part
    [ -b "$dev" ] || { echo "'$dev' is not a block device"; return 1; }
    case "$(lsblk -dno TYPE "$dev" 2>/dev/null)" in
      disk) ;;
      *) echo "'$dev' is not a whole disk (pass e.g. /dev/nvme1n1, not a partition)"; return 1 ;;
    esac
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    root_disk="$(lsblk -npo PKNAME "$root_src" 2>/dev/null | head -n1 || true)"
    [ -n "$root_disk" ] && [ "/dev/${root_disk#/dev/}" = "$dev" ] && { echo "'$dev' holds the ROOT filesystem"; return 1; }
    if lsblk -nro MOUNTPOINT "$dev" 2>/dev/null | grep '[^[:space:]]' >/dev/null; then
      echo "'$dev' (or one of its partitions) is currently mounted"; return 1
    fi
    for part in $(lsblk -nro NAME "$dev" 2>/dev/null | tail -n +2); do
      if swapon --show=NAME --noheadings 2>/dev/null | grep -x "/dev/$part" >/dev/null; then
        echo "'/dev/$part' is an active swap device"; return 1
      fi
    done
    return 0
  }

  disk_has_data() { # 0 = something already lives on it
    local dev="$1"
    [ -n "$(lsblk -nro FSTYPE,PARTUUID "$dev" 2>/dev/null | tr -d ' \n')" ] && return 0
    blkid "$dev" >/dev/null 2>&1 && return 0
    return 1
  }

  # Format + mount one disk. Never called unless FORMAT_DATA_DISKS=1.
  prepare_disk() { # $1 dev  $2 mountpoint  $3 label
    local dev="$1" mnt="$2" label="$3" part uuid reason
    if ! reason="$(disk_is_safe "$dev")"; then
      warn "refusing to touch $dev: $reason"
      return 1
    fi
    if [ "$FORMAT_DATA_DISKS" != "1" ]; then
      warn "$dev was given but --format-data-disks was not, so it is left alone."
      warn "  Mount it at $mnt yourself, or re-run with --format-data-disks."
      return 1
    fi
    if disk_has_data "$dev"; then
      warn "$dev already contains partitions or a filesystem - NOT reformatting it."
      warn "  Wipe it deliberately first if that is really what you want:"
      warn "     sudo wipefs -a $dev && sudo sgdisk --zap-all $dev"
      return 1
    fi
    log "  formatting $dev -> $mnt (label $label)"
    apt-get install -y gdisk >/dev/null 2>&1 || true
    sgdisk --zap-all "$dev" >/dev/null 2>&1 || true
    sgdisk -n 1:0:0 -t 1:8300 -c "1:$label" "$dev" >/dev/null 2>&1 || { warn "partitioning $dev failed"; return 1; }
    partprobe "$dev" >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true
    part="$(lsblk -nro NAME "$dev" 2>/dev/null | sed -n '2p')"
    [ -n "$part" ] || { warn "no partition appeared on $dev"; return 1; }
    part="/dev/$part"
    case "$DATA_FS" in
      ext4) mkfs.ext4 -q -L "$label" -m 0 "$part" || { warn "mkfs.ext4 on $part failed"; return 1; } ;;
      xfs)  apt-get install -y xfsprogs >/dev/null 2>&1 || true
            mkfs.xfs -q -L "$label" "$part" || { warn "mkfs.xfs on $part failed"; return 1; } ;;
      *) warn "unsupported DATA_FS='$DATA_FS'"; return 1 ;;
    esac
    uuid="$(blkid -s UUID -o value "$part")"
    [ -n "$uuid" ] || { warn "could not read the UUID of $part"; return 1; }
    install -d -m 0755 "$mnt"
    # By UUID, and 'nofail' so a pulled drive can never leave this headless box
    # sitting at an emergency prompt with nobody able to log in.
    sed -i "\#[[:space:]]${mnt}[[:space:]]#d" /etc/fstab
    printf 'UUID=%s  %s  %s  defaults,noatime,nofail,x-systemd.device-timeout=15  0  2\n' \
      "$uuid" "$mnt" "$DATA_FS" >> /etc/fstab
    systemctl daemon-reload >/dev/null 2>&1 || true
    mount "$mnt" 2>/dev/null || mount -a >/dev/null 2>&1 || true
    if mountpoint -q "$mnt"; then
      ok "$dev -> $mnt ($DATA_FS, $(lsblk -dno SIZE "$dev" 2>/dev/null | tr -d ' '))"
      return 0
    fi
    warn "$mnt did not mount; check 'journalctl -u ${mnt//\//-}.mount'"
    return 1
  }

  if [ -n "$LLM_DISK" ]; then
    if mountpoint -q "$LLM_MOUNT"; then
      ok "$LLM_MOUNT is already a mount point ($(findmnt -no SOURCE "$LLM_MOUNT" 2>/dev/null)) - leaving $LLM_DISK alone"
    else
      prepare_disk "$LLM_DISK" "$LLM_MOUNT" "llmdata" || true
    fi
  fi
  if [ -n "$COMFY_DISK" ]; then
    if mountpoint -q "$COMFY_MOUNT"; then
      ok "$COMFY_MOUNT is already a mount point ($(findmnt -no SOURCE "$COMFY_MOUNT" 2>/dev/null)) - leaving $COMFY_DISK alone"
    else
      prepare_disk "$COMFY_DISK" "$COMFY_MOUNT" "comfydata" || true
    fi
  fi
  if [ -z "$LLM_DISK" ] && [ -z "$COMFY_DISK" ]; then
    ok "no --llm-disk/--comfy-disk given; the shared trees live on the root filesystem"
    # Only offer disks that could actually be dedicated: not the one carrying /,
    # and not removable/USB media (an installer stick is not a model store).
    # Root is matched by walking each disk's whole child tree rather than by
    # PKNAME, because on an LVM or btrfs layout the parent of the root device is
    # a partition or a dm node, not the disk we need to exclude.
    # Every probe below is guarded: these tools can be absent or fail on exotic
    # roots, and an unguarded $( ) assignment is fatal under 'set -e'.
    _rootsrc="$(findmnt -no SOURCE / 2>/dev/null || true)"
    _rootsrc="${_rootsrc%%[*}"                      # strip a btrfs [/@subvol]
    _rootkname=""
    if [ -n "$_rootsrc" ]; then
      _rootkname="$(lsblk -no KNAME "$_rootsrc" 2>/dev/null | head -n1 || true)"
    fi
    _spare=""
    for _d in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' || true); do
      if [ -n "$_rootkname" ] \
         && lsblk -nro KNAME "/dev/$_d" 2>/dev/null | grep -Fx "$_rootkname" >/dev/null; then
        continue
      fi
      [ "$(lsblk -dno TRAN "/dev/$_d" 2>/dev/null | tr -d '[:space:]' || true)" = "usb" ] && continue
      [ "$(lsblk -dno RM   "/dev/$_d" 2>/dev/null | tr -d '[:space:]' || true)" = "1" ]   && continue
      _spare="$_spare /dev/$_d ($(lsblk -dno SIZE "/dev/$_d" 2>/dev/null | tr -d '[:space:]' || true))"
    done
    if [ -n "$_spare" ]; then
      warn "unused disks:$_spare  (see --list-disks to dedicate one per workload)"
    fi
  fi

  # --- directory skeleton ----------------------------------------------------
  # setgid (2775) + the shared group means anything either service writes stays
  # group-writable, which is what makes "download once, use from both" work.
  install -d -m 0755 "$LLM_ETC"
  if [ "$IS_SERVER" = "1" ]; then
    install -d -m 2775 -o "$LLM_USER" -g "$SHARE_GROUP" "$LLM_ROOT"
    install -d -m 2775 -o "$LLM_USER" -g "$SHARE_GROUP" "$LLM_ROOT/hub" "$LLM_ROOT/catalog"
    install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" "$COMFY_ROOT"
    for d in models input output workflows hf; do
      install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" "$COMFY_ROOT/$d"
    done
    # ComfyUI's scratch is per-node even on the server: it is churn, not content,
    # and putting it on the shared tree would make both nodes fight over it.
    install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" \
      "$COMFY_LOCAL_CACHE" "$COMFY_LOCAL_CACHE/temp"
    ok "server stores ready: $LLM_ROOT (owner $LLM_USER) and $COMFY_ROOT (owner $TARGET_USER), group $SHARE_GROUP"
  else
    # Mount points only - section 4 mounts the real trees over them via NFS.
    # 'install -d' re-applies mode and ownership even when the directory already
    # exists, so on a RE-RUN - once these are live NFS mounts - that chmod lands
    # on the server's filesystem, where $LLM_ROOT is exported read-only (EROFS)
    # and $COMFY_ROOT is root_squashed (EPERM). Only touch them while they are
    # still plain local directories.
    for _mp in "$LLM_ROOT" "$COMFY_ROOT"; do
      if mountpoint -q "$_mp" 2>/dev/null; then
        ok "$_mp is already mounted from $OTHER_HOST - left as it is"
      else
        install -d -m 0755 "$_mp"
      fi
    done
    install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" "$LLM_LOCAL_CACHE" "$COMFY_LOCAL_CACHE"
    install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" \
      "$LLM_LOCAL_CACHE/ray-spill" "$LLM_LOCAL_CACHE/compile" "$LLM_LOCAL_CACHE/hub" \
      "$COMFY_LOCAL_CACHE/temp" "$COMFY_LOCAL_CACHE/user"
    ok "peer local scratch ready: $LLM_LOCAL_CACHE (ray spill + compile cache), $COMFY_LOCAL_CACHE"
  fi
  echo
fi

# =============================================================================
# 2. ROCm + RCCL  (the gfx1151 compute stack)
# =============================================================================
# Strix Halo (Ryzen AI Max+ 395 / Radeon 8060S = gfx1151) has two legitimate
# sources of ROCm on Ubuntu 26.04, and this section tries both, in order:
#   1. AMD's CDN, https://stable.repo.amd.com/, a deb822 '.sources' repository
#      of per-GPU-target metapackages: 'amdrocm<M.m>-gfx1151' pulls a runtime
#      (HIP, rocBLAS/rocFFT/rocSOLVER/rocSPARSE, rocDNN, RCCL, amd-smi,
#      rocminfo) built for exactly this ISA. Refreshed far more often.
#   2. Canonical's own archive -- Ubuntu 26.04 ships ROCm in main, so a plain
#      'apt install rocm' pulls the whole stack, RCCL included. Older, but
#      signed and SRU-updated by Ubuntu.
# Note what is NOT here: repo.radeon.com/rocm/apt. That tree stops at 7.2.4 and
# publishes no 26.04 suite, which is why every pre-2026 HOWTO 404s.
# NO amdgpu-dkms (AMD requires the inbox 26.04 kernel driver on Ryzen APUs) and
# NO HSA_OVERRIDE_GFX_VERSION (gfx1151 is a first-class target; the old
# '=11.0.0' community hack makes ROCm load the wrong kernels).
# RCCL matters here specifically: it is what carries the tensor-parallel
# collectives between the two nodes over the USB4 link.
if [ "$INSTALL_ROCM" = "1" ]; then
  log "Installing the AMD ROCm compute stack (+ RCCL) for $ROCM_GFX"
  export DEBIAN_FRONTEND=noninteractive
  rocm_ready=0
  command -v curl >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1 \
    || apt-get install -y curl ca-certificates gnupg >/dev/null 2>&1 || true

  if [ -z "$ROCM_REPO_URL" ]; then
    _ubu_ver="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-26.04}")"
    ROCM_REPO_URL="https://stable.repo.amd.com/rocm/core/packages/ubuntu$(echo "$_ubu_ver" | tr -d '.')/"
  fi

  # Probe before touching apt: if AMD does not publish for this release, adding
  # the source would break every later 'apt-get update' in this script.
  if ! curl -fsSL --max-time 25 -o /dev/null "${ROCM_REPO_URL}dists/stable/Release" 2>/dev/null; then
    warn "AMD publishes no ROCm repository for this Ubuntu release at:"
    warn "  $ROCM_REPO_URL"
    warn "  Falling back to Ubuntu's own 'rocm' package. See"
    warn "  https://stable.repo.amd.com/rocm/core/packages/ for what AMD publishes."
  else
    ok "ROCm repository: $ROCM_REPO_URL"
    rocm_ready=1
    # AMD serves the key ASCII-armoured, so it must be dearmoured for Signed-By.
    # Stage + validate before touching the live keyring so a truncated download
    # can never replace a working key.
    install -d -m 0755 /etc/apt/keyrings
    _keytmp="$(mktemp -d)"
    if curl -fsSL --max-time 60 "$ROCM_GPG_URL" | gpg --batch --dearmor -o "$_keytmp/amdrocm.gpg" 2>/dev/null \
       && gpg --batch --show-keys "$_keytmp/amdrocm.gpg" >/dev/null 2>&1; then
      install -m 0644 "$_keytmp/amdrocm.gpg" /etc/apt/keyrings/amdrocm.gpg
      ok "ROCm signing key installed at /etc/apt/keyrings/amdrocm.gpg"
    else
      warn "could not download or verify the ROCm signing key from $ROCM_GPG_URL"
      rocm_ready=0
    fi
    rm -rf "$_keytmp"
  fi

  if [ "${rocm_ready:-0}" = "1" ]; then
    cat > /etc/apt/sources.list.d/amdrocm-stable.sources <<EOF
# Managed by setup-strixhalo-ai-server.sh -- AMD ROCm (TheRock packaging)
X-Repo-Id: amdrocm-stable
Types: deb
URIs: $ROCM_REPO_URL
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/amdrocm.gpg
Enabled: yes
EOF
    # Retire legacy repo.radeon.com entries: ROCm <= 7.2.4 with no 26.04 suite,
    # so leaving them enabled makes every later 'apt-get update' fail hard.
    for _old in /etc/apt/sources.list.d/rocm.list /etc/apt/sources.list.d/amdgpu.list; do
      if [ -f "$_old" ]; then
        mv "$_old" "$_old.disabled-by-setup"
        warn "disabled stale repo $_old (superseded by stable.repo.amd.com)"
      fi
    done
    [ -f /etc/apt/preferences.d/rocm-pin-600 ] && \
      mv /etc/apt/preferences.d/rocm-pin-600 /etc/apt/preferences.d/rocm-pin-600.disabled-by-setup || true

    # Activate transactionally: if apt cannot validate the new source, roll it
    # back at once, otherwise EVERY later apt call on this machine fails.
    if ! apt-get update -y; then
      rm -f /etc/apt/sources.list.d/amdrocm-stable.sources
      apt-get update -y >/dev/null 2>&1 || true
      warn "apt rejected the ROCm repository; the source has been removed again."
      rocm_ready=0
    fi
  fi

  # Ubuntu 26.04 ALSO ships ROCm in Canonical's own archive ('apt install rocm'),
  # so there are two legitimate sources. Prefer AMD's per-GPU-target metapackage
  # when the CDN offers one -- it is built for exactly this ISA and refreshed far
  # more often -- and fall back to the distro package otherwise. That way this
  # section keeps working whichever way AMD happens to be publishing.
  rocm_installed=0
  if [ "${rocm_ready:-0}" = "1" ]; then
    if [ -z "$ROCM_PKG" ]; then
      ROCM_PKG="$(apt-cache pkgnames amdrocm 2>/dev/null \
        | grep -E "^amdrocm[0-9]+\.[0-9]+-${ROCM_GFX}\$" | sort -V | tail -n1)" || ROCM_PKG=""
    fi
    if [ -n "$ROCM_PKG" ]; then
      if apt-get install -y "$ROCM_PKG"; then
        rocm_installed=1
        ok "installed $ROCM_PKG (AMD ROCm runtime + math libraries for $ROCM_GFX)"
        if [ "$ROCM_INSTALL_OPENCL" = "1" ]; then
          _ocl="$(apt-cache pkgnames amdrocm-opencl 2>/dev/null \
            | grep -E '^amdrocm-opencl[0-9]+\.[0-9]+$' | sort -V | tail -n1)" || _ocl=""
          if [ -n "$_ocl" ] && apt-get install -y "$_ocl" >/dev/null 2>&1; then
            ok "installed $_ocl (OpenCL runtime)"
          fi
        fi
      else
        warn "'$ROCM_PKG' failed to install; falling back to Ubuntu's ROCm packages"
      fi
    else
      warn "AMD's repository publishes no 'amdrocm<ver>-${ROCM_GFX}' metapackage right now;"
      warn "  using Ubuntu's own ROCm packages instead."
    fi
  fi

  if [ "$rocm_installed" != "1" ]; then
    # Canonical ships the whole stack, RCCL included, as the 'rocm' metapackage
    # in the Ubuntu 26.04 archive. It lags AMD's CDN but it is signed, supported
    # and updated through the usual SRU process.
    if apt-get install -y rocm; then
      rocm_installed=1
      ok "installed Ubuntu's 'rocm' metapackage ($(dpkg-query -W -f='${Version}' rocm 2>/dev/null || echo 'version unknown'))"
    else
      warn "ROCm could not be installed from AMD's repository OR the Ubuntu archive."
      warn "  vLLM and RCCL cannot work without it. Try 'sudo apt install rocm' by hand."
      note_action "ROCm is NOT installed on this node - no model will run until it is."
    fi
  fi

  if [ "$rocm_installed" = "1" ]; then
    usermod -aG render,video "$TARGET_USER" || true

    cat > /etc/profile.d/rocm.sh <<'PROF'
# Managed by setup-strixhalo-ai-server.sh
if [ -d /opt/rocm/bin ]; then
  case ":$PATH:" in
    *":/opt/rocm/bin:"*) ;;
    *) PATH="$PATH:/opt/rocm/bin"; export PATH ;;
  esac
fi
PROF
    chmod 0644 /etc/profile.d/rocm.sh
    # NB: 'grep >/dev/null' rather than 'grep -q'. Under 'set -o pipefail'
    # grep -q exits at the first match, the producer takes SIGPIPE, and the
    # whole pipeline reports failure even though the match succeeded.
    if ldconfig -p 2>/dev/null | grep 'libamdhip64\.so' >/dev/null; then
      ok "/opt/rocm on PATH; ROCm libraries already registered with ldconfig"
    else
      : > /etc/ld.so.conf.d/rocm.conf
      for _d in /opt/rocm/lib /opt/rocm/lib64; do
        if [ -d "$_d" ]; then echo "$_d" >> /etc/ld.so.conf.d/rocm.conf; fi
      done
      if [ -s /etc/ld.so.conf.d/rocm.conf ]; then
        ldconfig || warn "ldconfig returned non-zero"
        ok "/opt/rocm on PATH and registered with ldconfig"
      else
        rm -f /etc/ld.so.conf.d/rocm.conf
        warn "/opt/rocm/lib not found after install - check 'dpkg -L' for the ROCm package"
      fi
    fi

    # --- RCCL ----------------------------------------------------------------
    # RCCL is what carries the tensor-parallel collectives between the two nodes,
    # so it gets an explicit check instead of being assumed part of the stack.
    if ldconfig -p 2>/dev/null | grep 'librccl\.so' >/dev/null \
       || ls /opt/rocm/lib/librccl.so* >/dev/null 2>&1; then
      ok "RCCL present (cross-node collectives for tensor parallelism)"
    else
      if apt-get install -y rccl >/dev/null 2>&1; then
        apt-get install -y rccl-dev >/dev/null 2>&1 || true
        ldconfig || true
        ok "installed the 'rccl' package"
      else
        warn "RCCL is not present and could not be installed."
        warn "  TP=2 models spanning both nodes will NOT work until it is."
        warn "  Look for it with:  apt-cache search rccl"
        note_action "RCCL is missing - distributed (TP=2) models will not run on this node."
      fi
    fi

    # $TARGET_USER's /dev/kfd access only takes effect after the reboot, so run
    # the probe as root for an immediate signal.
    _rocminfo=""
    command -v rocminfo >/dev/null 2>&1 && _rocminfo="$(command -v rocminfo)"
    [ -n "$_rocminfo" ] || { [ -x /opt/rocm/bin/rocminfo ] && _rocminfo=/opt/rocm/bin/rocminfo; }
    if [ -n "$_rocminfo" ]; then
      if "$_rocminfo" 2>/dev/null | grep "$ROCM_GFX" >/dev/null; then
        ok "rocminfo reports $ROCM_GFX - ROCm sees the iGPU"
      else
        warn "rocminfo did not report $ROCM_GFX yet (normal before the reboot; re-check after)"
      fi
    fi
    note_action "BIOS: enable 'Above 4G Decoding' (ROCm on Ryzen APUs requires it)."
  fi
  echo
fi

# =============================================================================
# 3. UNIFIED SHARED GPU MEMORY  (TTM/GTT)
# =============================================================================
# Strix Halo shares one physical memory pool. AMD's RDNA3.5 guidance and the
# cluster plan (section 7): keep the BIOS "dedicated VRAM" tiny (~0.5 GB) and
# raise the shared TTM page limit so the iGPU can map almost all 128 GB. The
# limit lives at /sys/module/ttm/parameters/pages_limit (4 KiB pages;
# 262144 = 1 GiB) and is made persistent in /etc/modprobe.d/ttm.conf.
# AMD does NOT recommend the old amdgpu.gttsize (deprecated) or amd_iommu=off,
# so only the TTM limit is set here.
if [ "$CONFIGURE_MEMORY" = "1" ]; then
  log "Configuring GPU-addressable unified memory (TTM/GTT)"

  mem_kib="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
  mem_gib=$(( mem_kib / 1024 / 1024 ))
  if [ -n "$GTT_GIB" ]; then
    [[ "$GTT_GIB" =~ ^[0-9]+$ ]] || die "--gtt-gib must be a whole number of GiB"
    gtt_gib="$GTT_GIB"
    [ "$gtt_gib" -lt "$mem_gib" ] || die "--gtt-gib $gtt_gib leaves nothing for the OS (MemTotal is ~${mem_gib} GiB)"
  else
    gtt_gib=$(( mem_gib - OS_RESERVE_GIB ))
  fi
  [ "$gtt_gib" -ge 8 ] || die "Not enough RAM detected (${mem_gib} GiB) to configure TTM/GTT."
  ttm_pages=$(( gtt_gib * 262144 ))
  ok "total RAM ~${mem_gib} GiB -> GPU-usable TTM/GTT ${gtt_gib} GiB (${ttm_pages} pages)"

  # Preferred: AMD's own 'amd-ttm' helper from amd-debug-tools, written by AMD's
  # kernel team. Installed into an isolated venv so system Python is untouched.
  # It writes /etc/modprobe.d/ttm.conf; feed it 'n' to skip its interactive
  # reboot prompt (this script reboots at the very end instead).
  AMDTTM_VENV=/opt/amd-debug-tools
  ttm_tool_ok=0
  if python3 -m venv "$AMDTTM_VENV" >/dev/null 2>&1 \
     && "$AMDTTM_VENV/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 \
     && "$AMDTTM_VENV/bin/pip" install --quiet amd-debug-tools >/dev/null 2>&1 \
     && [ -x "$AMDTTM_VENV/bin/amd-ttm" ]; then
    printf 'n\n' | "$AMDTTM_VENV/bin/amd-ttm" --set "$gtt_gib" >/dev/null 2>&1 || true
    if grep -qs 'pages_limit' /etc/modprobe.d/ttm.conf 2>/dev/null; then
      ttm_tool_ok=1
      ok "configured via AMD 'amd-ttm --set ${gtt_gib}' -> /etc/modprobe.d/ttm.conf"
      ln -sf "$AMDTTM_VENV/bin/amd-ttm" /usr/local/bin/amd-ttm 2>/dev/null || true
    fi
  fi
  if [ "$ttm_tool_ok" != "1" ]; then
    warn "amd-ttm unavailable here; writing /etc/modprobe.d/ttm.conf directly (same effect)."
    printf '# Managed by setup-strixhalo-ai-server.sh (AMD RDNA3.5 TTM/GTT limit)\noptions ttm pages_limit=%s\n' \
      "$ttm_pages" > /etc/modprobe.d/ttm.conf
  fi
  update-initramfs -u >/dev/null 2>&1 || warn "update-initramfs returned non-zero (usually harmless)."

  # residencyd admits models against this number, so record it where every later
  # section (and a re-run) can find it.
  if [ -z "$RESIDENCY_BUDGET_GIB" ]; then
    RESIDENCY_BUDGET_GIB=$(( gtt_gib - RESIDENCY_MARGIN_GIB ))
    [ "$RESIDENCY_BUDGET_GIB" -ge 8 ] || RESIDENCY_BUDGET_GIB=8
  fi

  note_action "BIOS: set the iGPU 'VRAM / UMA Frame Buffer / Dedicated Graphics Memory' to the SMALLEST value (~512 MB) - the TTM limit above then hands the GPU the rest dynamically."
  note_action "BIOS: LEAVE IOMMU ENABLED. It is what makes auto-authorizing the USB4 peer safe; without it the cable must be approved by hand after every cold boot."
  echo
fi
if [ -z "$RESIDENCY_BUDGET_GIB" ]; then
  _memg=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  RESIDENCY_BUDGET_GIB=$(( _memg - OS_RESERVE_GIB - RESIDENCY_MARGIN_GIB ))
  [ "$RESIDENCY_BUDGET_GIB" -ge 8 ] || RESIDENCY_BUDGET_GIB=8
fi

# =============================================================================
# 3b. OS-LEVEL OOM GUARDRAILS  (systemd-oomd + zram)
# =============================================================================
# residencyd's live memory gate (section 6) is the primary defence against
# over-commit, but it can only reason about the loads IT starts. Two OS-level
# backstops sit underneath it so a runaway allocation -- a desktop app, a
# hand-run vllm, a model that balloons past its measured footprint -- degrades
# gracefully instead of hard-freezing the whole unified-memory box (which is how
# mighty-ai1 locked up and had to be power-cycled):
#
#   * zram: a small compressed swap device. GPU GTT pages are pinned and never
#     swap, but everything else (page cache, the desktop, Ray/Python heaps) can,
#     so the kernel gains a relief valve and memory pressure rises gradually and
#     measurably instead of wedging with nowhere to spill.
#   * systemd-oomd: watches memory-pressure (PSI) on llm.slice and, once it
#     stays above the limit for the configured window, kills the single worst
#     model server in that slice. One bad load costs one model, not the box --
#     and residencyd sees the vllm@ unit die and reconciles its ledger.
#
# Defence in depth: with residencyd doing its job these should never fire. They
# exist so the worst case becomes "one model dies" instead of "the machine is
# gone until someone can physically reach it".
if [ "$CONFIGURE_OOM_GUARD" = "1" ]; then
  log "Installing OS memory guardrails (systemd-oomd + zram)"

  # --- zram relief swap ------------------------------------------------------
  if [ "$ZRAM_ENABLE" = "1" ]; then
    if apt-get install -y systemd-zram-generator >/dev/null 2>&1; then
      # zram-size is a MiB expression that may reference 'ram' (total RAM in
      # MiB). min(...) keeps it a modest safety valve, not a way to pretend the
      # box has more memory than it physically does.
      cat > /etc/systemd/zram-generator.conf <<ZRAMCONF
# Managed by setup-strixhalo-ai-server.sh -- compressed relief swap so the
# shared-memory pool degrades under pressure instead of hard-freezing.
[zram0]
zram-size = ${ZRAM_SIZE_SPEC}
compression-algorithm = ${ZRAM_COMPRESSION}
ZRAMCONF
      if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl start systemd-zram-setup@zram0.service >/dev/null 2>&1 || true
      fi
      if swapon --show 2>/dev/null | grep 'zram0' >/dev/null; then
        ok "zram relief swap active (${ZRAM_SIZE_SPEC} MiB, ${ZRAM_COMPRESSION})"
      else
        ok "zram relief swap configured (${ZRAM_SIZE_SPEC} MiB, ${ZRAM_COMPRESSION}); active after reboot"
      fi
    else
      warn "systemd-zram-generator could not be installed; skipping zram (oomd still applies)."
    fi
  fi

  # --- systemd-oomd pressure killer -----------------------------------------
  # oomd acts only on cgroups that opt in; llm.slice carries the ManagedOOM*
  # keys (section 5). Here we install/enable the daemon and set the global
  # pressure window those keys inherit. Ubuntu 22.04+ ships it as its own
  # package; the install is best-effort in case a build folds it into systemd.
  apt-get install -y systemd-oomd >/dev/null 2>&1 || true
  install -d -m 0755 /etc/systemd/oomd.conf.d
  cat > /etc/systemd/oomd.conf.d/10-llm.conf <<OOMDCONF
# Managed by setup-strixhalo-ai-server.sh
# How long a monitored cgroup must stay over its pressure limit before oomd
# acts. Short by design: a load driving the box toward a freeze is stopped in
# seconds, before the desktop and SSH have already gone unresponsive.
[OOM]
DefaultMemoryPressureDurationSec=${OOMD_PRESSURE_DURATION}
OOMDCONF
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl enable --now systemd-oomd.service >/dev/null 2>&1; then
      ok "systemd-oomd enabled; kills within llm.slice past ${OOMD_PRESSURE_LIMIT} pressure held ${OOMD_PRESSURE_DURATION}"
    else
      warn "systemd-oomd could not be enabled here (needs cgroup v2 + PSI); residencyd's gate remains the primary guard."
    fi
  fi
  echo
fi

# =============================================================================
# 4. USB4NET CLUSTER LINK  (direct cable between the two Strix Halo nodes)
# =============================================================================
# The two boxes are cabled USB4-port-to-USB4-port and get a private /30 of their
# own. Everything cluster-internal -- RCCL collectives, Ray, Gloo, NFS and the
# distributed vLLM traffic -- rides that cable; the house LAN only ever carries
# Open WebUI, the gateway API, SSH, RDP and downloads.
#
# What actually has to be true for the link to appear (verified against
# docs.kernel.org/admin-guide/thunderbolt.html and drivers/net/thunderbolt --
# most guides get at least one of these wrong):
#   * AMD USB4 uses the SAME 'thunderbolt' driver as Intel. No separate AMD
#     module, and no out-of-tree driver on a 6.17+ kernel.
#   * The host-to-host Ethernet link comes from the module 'thunderbolt_net'
#     (underscore) which registers a DRIVER called 'thunderbolt-net' (hyphen).
#     Both spellings below are deliberate and are NOT typos.
#   * On a Linux<->Linux cable that module is NOT autoloaded -- the kernel only
#     autoloads it when the peer is Windows or macOS. Both ends must force it.
#   * Linux's software connection manager advertises security level 'user', so
#     the peer host must be AUTHORIZED before any link is created. That is what
#     bolt (boltd/boltctl) is for.
if [ "$INSTALL_CLUSTER" = "1" ]; then
  log "Configuring the USB4NET cluster link ($CLUSTER_LOCAL_IP/$CLUSTER_CIDR on $CLUSTER_IFACE)"

  export DEBIAN_FRONTEND=noninteractive
  if ! (command -v boltctl >/dev/null 2>&1 && command -v ethtool >/dev/null 2>&1); then
    apt-get install -y bolt ethtool >/dev/null 2>&1 \
      || { apt-get update -y >/dev/null 2>&1 || true; apt-get install -y bolt ethtool >/dev/null 2>&1 || true; }
  fi
  command -v boltctl >/dev/null 2>&1 \
    && ok "bolt (boltd/boltctl) + ethtool available" \
    || warn "'bolt' is missing; USB4 peers may need manual authorization"

  # --- 1. modules ------------------------------------------------------------
  cat > /etc/modules-load.d/usb4-cluster.conf <<'MOD'
# Managed by setup-strixhalo-ai-server.sh
# On a Linux<->Linux USB4/Thunderbolt cable the networking module is NOT
# autoloaded -- the kernel only does that for Windows/macOS peers. Load it
# explicitly so the interface appears without anyone logging in.
# See https://docs.kernel.org/admin-guide/thunderbolt.html
#     ("Networking over Thunderbolt cable")
thunderbolt
thunderbolt_net
MOD
  modprobe thunderbolt >/dev/null 2>&1 || true
  if modprobe thunderbolt_net >/dev/null 2>&1; then
    ok "thunderbolt_net loaded (and set to load on every boot)"
  else
    warn "could not load 'thunderbolt_net' now (built-in kernels are fine; recheck after reboot)"
  fi

  # --- 2. a stable interface name -------------------------------------------
  # The kernel calls these thunderbolt0/1/...; the plan wants one predictable
  # name because NCCL_SOCKET_IFNAME, GLOO_SOCKET_IFNAME, the netplan stanza and
  # the firewall rule all key off it.
  #
  # The rename is done with a systemd .link file rather than netplan's
  # 'set-name:' on purpose: .link files are applied by systemd-udevd itself, so
  # the name is correct whether this box renders its network with networkd
  # (Ubuntu Server) or NetworkManager (a desktop image). 'Driver=' takes a
  # space-separated list, which is how both spellings are covered at once.
  rm -f /etc/systemd/network/70-usb4-cluster.link
  install -d -m 0755 /etc/systemd/network
  cat > /etc/systemd/network/70-usb4-cluster.link <<LINK
# Managed by setup-strixhalo-ai-server.sh
# Give the USB4 host-to-host Ethernet link one stable name on both nodes.
# 'thunderbolt-net' is the driver name ethtool reports; 'thunderbolt_net' is the
# module name. Listing both means this matches no matter which the kernel
# exposes. The target name is deliberately NOT a kernel-style name, so there is
# no race with the kernel's own thunderbolt%d allocation.
[Match]
Driver=thunderbolt-net thunderbolt_net

[Link]
Name=$CLUSTER_IFACE
LINK
  ok "USB4 link will be named '$CLUSTER_IFACE' (/etc/systemd/network/70-usb4-cluster.link)"

  # Apply the rename live where possible so this run can finish the job without
  # a reboot. udev will not rename an interface that is UP, so take it down
  # first; it is a point-to-point cable to a box we are not talking to yet.
  cl_kernel_if=""
  for _n in /sys/class/net/*; do
    _drv="$(basename "$(readlink -f "$_n/device/driver" 2>/dev/null)" 2>/dev/null || true)"
    case "$_drv" in thunderbolt-net|thunderbolt_net) cl_kernel_if="$(basename "$_n")" ;; esac
  done
  if [ -n "$cl_kernel_if" ] && [ "$cl_kernel_if" != "$CLUSTER_IFACE" ]; then
    ip link set "$cl_kernel_if" down >/dev/null 2>&1 || true
    udevadm control --reload-rules >/dev/null 2>&1 || true
    udevadm trigger --action=add --subsystem-match=net >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true
    if [ -d "/sys/class/net/$CLUSTER_IFACE" ]; then
      ok "renamed $cl_kernel_if -> $CLUSTER_IFACE"
    else
      ip link set "$cl_kernel_if" name "$CLUSTER_IFACE" >/dev/null 2>&1 \
        && ok "renamed $cl_kernel_if -> $CLUSTER_IFACE" \
        || warn "could not rename '$cl_kernel_if' now; the .link file applies at the next boot"
    fi
  elif [ -n "$cl_kernel_if" ]; then
    ok "USB4 interface already named $CLUSTER_IFACE"
  else
    warn "no thunderbolt-net interface yet (cable unplugged or the peer is off) - the name applies when it appears"
  fi

  # --- 3. peer authorization -------------------------------------------------
  cl_sec="$(cat /sys/bus/thunderbolt/devices/domain0/security 2>/dev/null || true)"
  cl_iommu="$(cat /sys/bus/thunderbolt/devices/domain0/iommu_dma_protection 2>/dev/null || true)"
  if [ -n "$cl_sec" ]; then
    ok "USB4 domain0 security level: $cl_sec (IOMMU DMA protection: ${cl_iommu:-unknown})"
    case "$cl_sec" in
      dponly|usbonly)
        warn "security level '$cl_sec' disables PCIe tunnelling. Host-to-host networking is a"
        warn "  protocol tunnel and often still works, but if the interface never appears set"
        warn "  the BIOS Thunderbolt/USB4 mode to 'user'/'Unique ID' (or Legacy) and retry." ;;
    esac
  else
    warn "no /sys/bus/thunderbolt/devices/domain0 - the USB4 host controller is not enumerated."
    warn "  Check 'dmesg | grep -iE \"thunderbolt|ucsi\"'. Strix Halo boards with an old AGESA"
    warn "  can fail UCSI PPM init and never bring the USB4 ports up; only a BIOS update fixes it."
  fi

  if [ "$CLUSTER_AUTO_AUTHORIZE" = "1" ]; then
    cat > /etc/udev/rules.d/60-usb4-cluster-authorize.rules <<'UDEV'
# Managed by setup-strixhalo-ai-server.sh
# Auto-approve USB4/Thunderbolt peers, but ONLY on platforms that report active
# IOMMU DMA protection -- verbatim from the kernel's own documentation
# (https://docs.kernel.org/admin-guide/thunderbolt.html, "DMA protection
# utilizing IOMMU"). The IOMMU is what stops a hostile cable from reading RAM,
# so this is NOT the blanket "authorize everything" rule found in most guides.
ACTION=="add", SUBSYSTEM=="thunderbolt", ATTRS{iommu_dma_protection}=="1", ATTR{authorized}=="0", ATTR{authorized}="1"
UDEV
    udevadm control --reload-rules >/dev/null 2>&1 || true
    ok "udev rule installed: USB4 peers self-authorize while IOMMU DMA protection is on"
    if [ "$cl_iommu" != "1" ] && [ -n "$cl_sec" ] && [ "$cl_sec" != "none" ]; then
      warn "IOMMU DMA protection is NOT active, so that rule will not fire on this box."
      warn "  The peer is instead enrolled in bolt's database below (also persistent)."
    fi

    # Approve whatever is already on the wire, then record it in bolt's database
    # with policy 'auto' so it is trusted on every future boot. UUIDs come from
    # sysfs rather than from 'boltctl list', whose output is meant for humans and
    # reformats between releases. The [0-9]*-[0-9]* glob skips domainN entries.
    cl_seen=0; cl_trusted=0; cl_failed=""; cl_xdomain=0
    for cl_dev in /sys/bus/thunderbolt/devices/[0-9]*-[0-9]*; do
      [ -d "$cl_dev" ] || continue
      # Route string X-0 is this machine's OWN host router: it is not a peer, it
      # has no meaningful 'authorized' attribute and boltctl cannot enroll it.
      # Counting it made a healthy two-device link report "2 of 3 authorized".
      case "${cl_dev##*/}" in *-0) continue ;; esac
      cl_uuid="$(cat "$cl_dev/unique_id" 2>/dev/null || true)"
      [ -n "$cl_uuid" ] || continue
      # A host-to-host link is an XDomain connection, not a peripheral, and the
      # kernel gives it no 'authorized' attribute at all - there is nothing to
      # trust, because the two host routers negotiated the link between
      # themselves. Treating that as an authorization failure is how mighty-ai1
      # came to report "0 of 1 USB4 peer device(s) could be authorized" while
      # the cable was up and carrying traffic to mighty-ai2.
      if [ ! -e "$cl_dev/authorized" ]; then
        cl_xdomain=$(( cl_xdomain + 1 ))
        continue
      fi
      cl_seen=$(( cl_seen + 1 ))
      cl_auth="$(cat "$cl_dev/authorized" 2>/dev/null || echo "")"
      if [ "$cl_auth" = "0" ]; then
        echo 1 > "$cl_dev/authorized" 2>/dev/null || true
        cl_auth="$(cat "$cl_dev/authorized" 2>/dev/null || echo "")"
      fi
      # 'enroll' fails on an already-enrolled device, so an authorized device
      # counts as trusted rather than being reported as a false failure.
      if command -v boltctl >/dev/null 2>&1 && boltctl enroll --policy auto "$cl_uuid" >/dev/null 2>&1; then
        cl_trusted=$(( cl_trusted + 1 ))
      elif [ "$cl_auth" = "1" ]; then
        cl_trusted=$(( cl_trusted + 1 ))
      else
        cl_failed="$cl_failed ${cl_dev##*/}=$cl_uuid"
      fi
    done
    if [ "$cl_seen" -eq 0 ] && [ "$cl_xdomain" -gt 0 ]; then
      ok "$cl_xdomain USB4 host-to-host link(s) present - an XDomain link needs no authorization"
    elif [ "$cl_seen" -eq 0 ]; then
      warn "no USB4 peer visible yet - plug the cable into BOTH machines, then run 'sudo usb4-cluster-status'."
    elif [ "$cl_trusted" -eq "$cl_seen" ]; then
      ok "$cl_seen USB4 peer device(s) authorized, and trusted again on future boots"
    else
      warn "only $cl_trusted of $cl_seen USB4 peer device(s) could be authorized."
      for cl_f in $cl_failed; do warn "  not authorized: $cl_f"; done
      warn "  Inspect with 'sudo boltctl list', then 'sudo boltctl enroll --policy auto <uuid>'."
    fi
  else
    warn "CLUSTER_AUTO_AUTHORIZE=0: peers stay untrusted, so the link will NOT come up on its own."
  fi

  # --- 4. point-to-point IP configuration ------------------------------------
  cl_renderer="networkd"
  if systemctl is-active --quiet NetworkManager 2>/dev/null && \
     ! systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    cl_renderer="NetworkManager"
  fi
  # Retire the pre-cluster-plan layout if this box was provisioned by an older
  # version of this script, otherwise two netplan files fight over one NIC.
  rm -f /etc/netplan/70-usb4-cluster.yaml
  cl_plan="/etc/netplan/60-usb4-cluster.yaml"
  cl_plan_bak=""
  if [ -f "$cl_plan" ]; then cl_plan_bak="$(mktemp)"; cp -a "$cl_plan" "$cl_plan_bak"; fi
  # Staged in the same directory and moved into place in one step, so a partial
  # write (a full disk, say) can never leave unparsable YAML in /etc/netplan and
  # cost this headless box its networking at the next boot. netplan only reads
  # *.yaml, so the dot-prefixed staging file is invisible to it meanwhile.
  cl_tmp="$(mktemp /etc/netplan/.usb4-cluster.XXXXXX)"
  cat > "$cl_tmp" <<YAML
# Managed by setup-strixhalo-ai-server.sh -- USB4NET cluster link.
# This node: $MY_HOST ($NODE_ROLE). Peer: $OTHER_HOST at $CLUSTER_PEER_IP.
# Point-to-point only: no gateway and no nameservers, so it can never become the
# default route or shadow the real LAN interface. The interface is renamed to
# '$CLUSTER_IFACE' by /etc/systemd/network/70-usb4-cluster.link before this is read.
network:
  version: 2
  ethernets:
    ${CLUSTER_IFACE}:
      renderer: ${cl_renderer}
      match:
        name: ${CLUSTER_IFACE}
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
      # The cable is hot-pluggable and the peer may be powered off, so this must
      # never gate boot -- without 'optional' systemd-networkd-wait-online holds
      # the boot for ~2 minutes whenever the link is down.
      optional: true
      mtu: ${CLUSTER_MTU}
      addresses:
        - ${CLUSTER_LOCAL_IP}/${CLUSTER_CIDR}
YAML
  chmod 0600 "$cl_tmp"          # netplan warns on world-readable configs
  mv -f "$cl_tmp" "$cl_plan"
  # Validate BEFORE activating: a config netplan cannot parse would take the
  # whole machine's networking down at the next boot, and this box is headless.
  if netplan generate >/dev/null 2>&1; then
    # Deliberately NOT 'netplan apply': that reapplies every interface on the
    # box and can drop the very SSH session running this script. A reload only
    # picks up the newly generated unit; anything it cannot do live is handled
    # by the reboot at the end anyway.
    #
    # The reload has to match the renderer chosen above. Ubuntu Desktop runs
    # NetworkManager and leaves systemd-networkd stopped, so 'networkctl reload'
    # there always fails and the old code reported a scary warning for what is
    # simply the wrong tool. netplan writes NM keyfiles under /run, so asking NM
    # to re-read them is the equivalent action.
    cl_reloaded=0
    if [ "$cl_renderer" = "NetworkManager" ]; then
      if nmcli connection reload >/dev/null 2>&1; then cl_reloaded=1; fi
    else
      if networkctl reload >/dev/null 2>&1 || systemctl reload systemd-networkd >/dev/null 2>&1; then
        cl_reloaded=1
      fi
    fi
    if [ "$cl_reloaded" = "1" ]; then
      ok "USB4 link configured via $cl_renderer: $CLUSTER_LOCAL_IP/$CLUSTER_CIDR on $CLUSTER_IFACE (mtu $CLUSTER_MTU), peer $CLUSTER_PEER_IP"
    else
      ok "USB4 link config written and validated: $CLUSTER_LOCAL_IP/$CLUSTER_CIDR on $CLUSTER_IFACE ($cl_renderer)"
      warn "  could not reload $cl_renderer live; it takes effect at the reboot below."
    fi
  else
    warn "netplan rejected $cl_plan - reverting so networking stays intact:"
    netplan generate 2>&1 | sed 's/^/       /' || true
    if [ -n "$cl_plan_bak" ]; then cp -a "$cl_plan_bak" "$cl_plan"; else rm -f "$cl_plan"; fi
    netplan generate >/dev/null 2>&1 \
      && ok "previous network configuration restored and re-validated" \
      || warn "netplan STILL reports errors after the revert - inspect /etc/netplan BEFORE rebooting."
  fi
  rm -f /etc/netplan/.usb4-cluster.* 2>/dev/null || true
  [ -n "$cl_plan_bak" ] && rm -f "$cl_plan_bak" || true

  # --- 5. names for both ends ------------------------------------------------
  # '<hostname>-usb4' as the plan specifies, plus role aliases that stay correct
  # no matter what the machines are called, which is what the systemd units and
  # config files below reference.
  sed -i '/^# >>> usb4-cluster/,/^# <<< usb4-cluster/d' /etc/hosts
  cat >> /etc/hosts <<HOSTS
# >>> usb4-cluster (managed by setup-strixhalo-ai-server.sh) >>>
# Cluster-internal names. The plain LAN hostnames ($SERVER_HOST / $PEER_HOST)
# stay resolvable separately via DNS/mDNS and are NOT overridden here.
${SERVER_IP}   ${SERVER_USB4_NAME} llm-head usb4-server
${PEER_IP}   ${PEER_USB4_NAME} llm-worker usb4-peer
# <<< usb4-cluster <<<
HOSTS
  ok "/etc/hosts: $SERVER_USB4_NAME -> $SERVER_IP, $PEER_USB4_NAME -> $PEER_IP"

  # --- 6. TCP tuning ---------------------------------------------------------
  if [ "$CLUSTER_TUNE_SYSCTL" = "1" ]; then
    cat > /etc/sysctl.d/80-usb4-cluster.conf <<'SYSCTL'
# Managed by setup-strixhalo-ai-server.sh
# Raise the CEILINGS only; the middle value of tcp_rmem/tcp_wmem stays small so
# TCP autotuning still grows buffers on demand instead of every socket on the
# box reserving megabytes it will never use.
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 131072 134217728
net.ipv4.tcp_wmem = 4096 131072 134217728
net.core.netdev_max_backlog = 16384
net.core.default_qdisc = fq
net.ipv4.tcp_window_scaling = 1
# If the USB4 link is later moved to a jumbo MTU while everything else stays at
# 1500, let TCP discover the real path MTU rather than blackholing big segments.
net.ipv4.tcp_mtu_probing = 1
SYSCTL
    sysctl -p /etc/sysctl.d/80-usb4-cluster.conf >/dev/null 2>&1 \
      && ok "TCP buffer/queue limits raised for the high-bandwidth link" \
      || warn "could not apply /etc/sysctl.d/80-usb4-cluster.conf now (applies at reboot)"
  fi

  # --- 7. shared facts + helpers --------------------------------------------
  cat > /etc/default/usb4-cluster <<EOF
# Managed by setup-strixhalo-ai-server.sh
CLUSTER_ROLE=${NODE_ROLE}
CLUSTER_IFACE=${CLUSTER_IFACE}
CLUSTER_LOCAL_IP=${CLUSTER_LOCAL_IP}
CLUSTER_PEER_IP=${CLUSTER_PEER_IP}
CLUSTER_SERVER_IP=${SERVER_IP}
CLUSTER_WORKER_IP=${PEER_IP}
CLUSTER_MTU=${CLUSTER_MTU}
CLUSTER_SERVER_HOST=${SERVER_HOST}
CLUSTER_PEER_HOST=${PEER_HOST}
EOF
  chmod 0644 /etc/default/usb4-cluster

  cat > /usr/local/bin/usb4-cluster-status <<'HELPER'
#!/usr/bin/env bash
# Managed by setup-strixhalo-ai-server.sh -- one-shot health check for the USB4
# host-to-host cluster link. Safe to run repeatedly; changes nothing.
set -uo pipefail
[ -r /etc/default/usb4-cluster ] && . /etc/default/usb4-cluster
IFACE="${CLUSTER_IFACE:-usb4llm0}"

echo "== role =="
echo "  this node: ${CLUSTER_ROLE:-?}  local=${CLUSTER_LOCAL_IP:-?}  peer=${CLUSTER_PEER_IP:-?}"

echo "== modules =="
for m in thunderbolt thunderbolt_net; do
  if lsmod 2>/dev/null | awk '{print $1}' | grep -x "$m" >/dev/null; then
    echo "  loaded : $m"
  elif [ -d "/sys/module/${m}" ]; then
    echo "  builtin: $m"
  else
    echo "  MISSING: $m   (try: sudo modprobe $m)"
  fi
done

echo "== domains =="
shopt -s nullglob
for d in /sys/bus/thunderbolt/devices/domain*; do
  echo "  $(basename "$d"): security=$(cat "$d/security" 2>/dev/null || echo ?)" \
       "iommu_dma_protection=$(cat "$d/iommu_dma_protection" 2>/dev/null || echo ?)"
done

echo "== peers =="
found=0
for d in /sys/bus/thunderbolt/devices/[0-9]*-[0-9]*; do
  [ -d "$d" ] || continue
  found=1
  echo "  $(basename "$d"): $(cat "$d/device_name" 2>/dev/null || echo '?')" \
       "auth=$(cat "$d/authorized" 2>/dev/null || echo n/a)" \
       "uuid=$(cat "$d/unique_id" 2>/dev/null || echo ?)"
done
[ "$found" = "1" ] || echo "  none - is the cable in both machines, and is the other node powered on?"
command -v boltctl >/dev/null 2>&1 && { echo "== boltctl =="; boltctl list 2>/dev/null | sed 's/^/  /'; }

echo "== interface =="
# Found by driver rather than by name, so a failed rename is still spotted.
real=""
for n in /sys/class/net/*; do
  drv="$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)" 2>/dev/null || true)"
  case "$drv" in thunderbolt-net|thunderbolt_net) real="$(basename "$n")" ;; esac
done
if [ -n "$real" ]; then
  [ "$real" = "$IFACE" ] || echo "  NOTE: expected '$IFACE' but the driver bound '$real' (reboot to apply the rename)"
  ip -br addr show "$real" 2>/dev/null | sed 's/^/  /'
  echo "  mtu: $(cat "/sys/class/net/$real/mtu" 2>/dev/null || echo ?) (want ${CLUSTER_MTU:-1500} on BOTH nodes)"
else
  echo "  no thunderbolt-net interface yet"
fi

echo "== peer =="
if [ -n "${CLUSTER_PEER_IP:-}" ]; then
  if ping -c2 -W2 -n "$CLUSTER_PEER_IP" >/dev/null 2>&1; then
    echo "  reachable: $CLUSTER_PEER_IP"
    command -v iperf3 >/dev/null 2>&1 && \
      echo "  benchmark: run 'iperf3 -s' on the peer, then 'iperf3 -c $CLUSTER_PEER_IP -P 4 -t 30' here"
  else
    echo "  UNREACHABLE: $CLUSTER_PEER_IP"
    echo "  Check the far end too: matching MTU, an address on the same subnet,"
    echo "  and that its ufw allows traffic in on the USB4 interface."
  fi
else
  echo "  no peer address configured"
fi
HELPER
  chmod 0755 /usr/local/bin/usb4-cluster-status

  # Used as ExecStartPre by Ray/NFS-dependent units so they do not thrash while
  # the cable is still negotiating after a cold boot.
  cat > /usr/local/bin/usb4-cluster-wait <<'WAITER'
#!/usr/bin/env bash
# Managed by setup-strixhalo-ai-server.sh
# usb4-cluster-wait [ip] [timeout-seconds]
# Blocks until the USB4 peer answers ICMP, or the timeout expires. Always exits
# 0: a missing peer must degrade the cluster, never wedge the boot.
set -uo pipefail
[ -r /etc/default/usb4-cluster ] && . /etc/default/usb4-cluster
TARGET="${1:-${CLUSTER_PEER_IP:-}}"
TIMEOUT="${2:-120}"
[ -n "$TARGET" ] || { echo "usb4-cluster-wait: no peer address configured" >&2; exit 0; }
end=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$end" ]; do
  if ping -c1 -W1 -n "$TARGET" >/dev/null 2>&1; then
    echo "usb4-cluster-wait: $TARGET is up"
    exit 0
  fi
  sleep 2
done
echo "usb4-cluster-wait: $TARGET did not answer within ${TIMEOUT}s - continuing anyway" >&2
exit 0
WAITER
  chmod 0755 /usr/local/bin/usb4-cluster-wait
  ok "helpers installed: usb4-cluster-status, usb4-cluster-wait"
  echo
fi

# =============================================================================
# 5. SHARED STORAGE OVER NFS  (download once, use from either machine)
# =============================================================================
# Two exports, with deliberately different permissions:
#
#   $LLM_ROOT    READ-ONLY on the peer. The server owns the authoritative model
#                repository; only it downloads. vLLM on either node then opens
#                exactly the same absolute path, which is what lets one model
#                definition be scheduled on either machine (or across both).
#
#   $COMFY_ROOT  READ-WRITE on both. ComfyUI cannot be clustered, so each node
#                runs its own instance for parallel workloads -- but they share
#                one file store, so a checkpoint/LoRA pulled on either machine
#                (ComfyUI-Manager, the URL downloader, a manual copy) is
#                immediately visible to the other, and outputs land in one place.
#
# Everything moves over the USB4 cable: the exports name the peer's cluster
# address only, so the LAN cannot reach NFS at all even before the firewall.
if [ "$INSTALL_NFS" = "1" ]; then
  log "Configuring shared storage over NFS"
  export DEBIAN_FRONTEND=noninteractive

  if [ "$IS_SERVER" = "1" ]; then
    # ---------------------------------------------------------------- server
    command -v exportfs >/dev/null 2>&1 || apt-get install -y nfs-kernel-server >/dev/null 2>&1 || true
    if ! command -v exportfs >/dev/null 2>&1; then
      warn "nfs-kernel-server is not installed; the peer will have no shared storage."
    else
      install -d -m 2775 -o "$LLM_USER"    -g "$SHARE_GROUP" "$LLM_ROOT"
      install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" "$COMFY_ROOT"

      # NFSv4 only. v3 needs statd/lockd/mountd on a shifting set of ports;
      # pinning to v4 means the entire protocol is one TCP port (2049), which is
      # what makes the firewall rule below both simple and actually airtight.
      install -d -m 0755 /etc/nfs.conf.d
      cat > /etc/nfs.conf.d/10-llm-cluster.conf <<'NFSCONF'
# Managed by setup-strixhalo-ai-server.sh
# NFSv4-only, TCP-only: one well-known port (2049) instead of the v3 portmapper
# zoo, so the cluster export can be locked to the USB4 peer with one rule.
[nfsd]
vers2 = n
vers3 = n
udp = n
tcp = y
NFSCONF

      # nfs-kernel-server does NOT ship /etc/exports.d - exportfs only reads it
      # if it happens to exist. Creating it is what stops the redirection below
      # from dying with "No such file or directory" on a clean install.
      install -d -m 0755 /etc/exports.d
      cat > /etc/exports.d/llm-cluster.exports <<EOF
# Managed by setup-strixhalo-ai-server.sh
# Exported ONLY to the peer node's USB4 address ($PEER_IP), never to the LAN.
#   $LLM_ROOT  : read-only. The server is the single writer for models.
#   $COMFY_ROOT: read-write, so ComfyUI on either node downloads once.
# root_squash stays on: nothing on the far side needs to write as root, and the
# cable is the only thing standing between the two root filesystems.
${LLM_ROOT}	${PEER_IP}/32(ro,sync,no_subtree_check,root_squash)
${COMFY_ROOT}	${PEER_IP}/32(rw,sync,no_subtree_check,root_squash)
EOF
      chmod 0644 /etc/exports.d/llm-cluster.exports

      # Numeric-id fingerprint the peer can compare itself against after it
      # mounts. NFS maps ownership by NUMBER: if the two machines disagree about
      # what uid 1000 means, shared writes fail in ways that look like random
      # permission bugs, and this is the cheapest possible early warning.
      cat > "$COMFY_ROOT/.cluster-ids" <<EOF
# Written by setup-strixhalo-ai-server.sh on $SERVER_HOST. Do not edit.
SERVER_HOST=${SERVER_HOST}
TARGET_USER=${TARGET_USER}
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_GID=$(id -g "$TARGET_USER")
LLM_USER=${LLM_USER}
LLM_UID=$(id -u "$LLM_USER" 2>/dev/null || echo "?")
SHARE_GROUP=${SHARE_GROUP}
SHARE_GID=$(getent group "$SHARE_GROUP" | cut -d: -f3)
EOF
      chown "$TARGET_USER:$SHARE_GROUP" "$COMFY_ROOT/.cluster-ids" 2>/dev/null || true

      systemctl enable nfs-server >/dev/null 2>&1 || true
      systemctl restart nfs-server >/dev/null 2>&1 || systemctl start nfs-server >/dev/null 2>&1 || true
      if exportfs -rav >/dev/null 2>&1; then
        ok "exported $LLM_ROOT (ro) and $COMFY_ROOT (rw) to $PEER_IP"
        exportfs -s 2>/dev/null | sed 's/^/       /' || true
      else
        warn "'exportfs -rav' failed - check /etc/exports.d/llm-cluster.exports"
        exportfs -rav 2>&1 | sed 's/^/       /' || true
      fi
      systemctl is-active --quiet nfs-server \
        && ok "nfs-server is running" \
        || warn "nfs-server is not active (systemctl status nfs-server)"
    fi

  else
    # ------------------------------------------------------------------ peer
    apt-get install -y nfs-common >/dev/null 2>&1 || true
    # Already-mounted trees are skipped: 'install -d' would chmod them, and the
    # chmod goes to the SERVER's filesystem - read-only for the model tree,
    # root_squashed for the ComfyUI tree. See the same guard in section 1.
    for _mp in "$LLM_ROOT" "$COMFY_ROOT"; do
      mountpoint -q "$_mp" 2>/dev/null || install -d -m 0755 "$_mp"
    done

    # FS-Cache: the model repository is mounted read-only and read over and over
    # (every cold model load streams gigabytes), so caching it on this node's own
    # SSD turns repeat loads into local reads and keeps the USB4 cable free for
    # the collectives that actually need it. Entirely optional - if cachefilesd
    # will not run, the mount is made without 'fsc' and everything still works.
    fsc_opt=""
    if [ "$NFS_FSCACHE" = "1" ]; then
      if apt-get install -y cachefilesd >/dev/null 2>&1; then
        # Keep the cache at the distribution's default path so the shipped
        # AppArmor profile still applies; if a dedicated SSD was set up, put the
        # real storage there and bind-mount it into place.
        install -d -m 0700 /var/cache/fscache
        if mountpoint -q "$LLM_LOCAL_CACHE" && ! mountpoint -q /var/cache/fscache; then
          install -d -m 0700 "$LLM_LOCAL_CACHE/fscache"
          sed -i '\#[[:space:]]/var/cache/fscache[[:space:]]#d' /etc/fstab
          printf '%s  /var/cache/fscache  none  bind,nofail  0  0\n' "$LLM_LOCAL_CACHE/fscache" >> /etc/fstab
          systemctl daemon-reload >/dev/null 2>&1 || true
          mount /var/cache/fscache >/dev/null 2>&1 || true
          mountpoint -q /var/cache/fscache && ok "NFS read cache backed by the local SSD ($LLM_LOCAL_CACHE/fscache)"
        fi
        sed -i 's/^RUN=.*/RUN=yes/' /etc/default/cachefilesd 2>/dev/null || \
          echo 'RUN=yes' > /etc/default/cachefilesd
        systemctl enable cachefilesd >/dev/null 2>&1 || true
        systemctl restart cachefilesd >/dev/null 2>&1 || true
        if systemctl is-active --quiet cachefilesd; then
          fsc_opt=",fsc"
          ok "cachefilesd running - $LLM_ROOT will be cached locally (fsc)"
        else
          warn "cachefilesd would not start; mounting without the local read cache"
        fi
      else
        warn "cachefilesd not available; mounting without the local read cache"
      fi
    fi

    # nconnect spreads the mount over several TCP connections, which is what
    # actually lets a single NFS client saturate a link this fast. nofail +
    # x-systemd.automount mean a powered-off server can never wedge the boot.
    nfs_common_opts="_netdev,noatime,nofail,nconnect=4,x-systemd.automount,x-systemd.mount-timeout=30"
    # Range-delete the whole managed block first, otherwise the marker comments
    # (which match neither mount-path pattern) pile up one pair per run.
    sed -i '\%^# >>> llm-cluster shared storage%,\%^# <<< llm-cluster shared storage%d' /etc/fstab
    sed -i "\#[[:space:]]${LLM_ROOT}[[:space:]]#d"   /etc/fstab
    sed -i "\#[[:space:]]${COMFY_ROOT}[[:space:]]#d" /etc/fstab
    cat >> /etc/fstab <<EOF
# >>> llm-cluster shared storage (managed by setup-strixhalo-ai-server.sh) >>>
${SERVER_IP}:${LLM_ROOT}	${LLM_ROOT}	nfs4	ro,${nfs_common_opts}${fsc_opt}	0	0
${SERVER_IP}:${COMFY_ROOT}	${COMFY_ROOT}	nfs4	rw,${nfs_common_opts}	0	0
# <<< llm-cluster shared storage <<<
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    ok "fstab entries written for $LLM_ROOT (ro) and $COMFY_ROOT (rw) from $SERVER_IP"

    # Try to mount now, but never block: the server may not be provisioned yet.
    nfs_mounted=0
    if ping -c1 -W2 -n "$SERVER_IP" >/dev/null 2>&1; then
      for _m in "$LLM_ROOT" "$COMFY_ROOT"; do
        if mountpoint -q "$_m"; then
          ok "$_m already mounted"
          nfs_mounted=$(( nfs_mounted + 1 ))
        elif timeout 45 mount "$_m" >/dev/null 2>&1; then
          ok "mounted $_m from $SERVER_IP"
          nfs_mounted=$(( nfs_mounted + 1 ))
        else
          warn "could not mount $_m yet (is $SERVER_HOST provisioned and exporting?)"
        fi
      done
    else
      warn "$SERVER_IP does not answer over USB4 yet - the shares mount automatically once it does."
      note_action "Peer: after the server is up, confirm the shares with 'ls $LLM_ROOT $COMFY_ROOT' (they automount on first access)."
    fi

    # Numeric-id sanity check against the fingerprint the server left behind.
    if [ -r "$COMFY_ROOT/.cluster-ids" ]; then
      # shellcheck disable=SC1090
      _srv_uid="$(awk -F= '$1=="TARGET_UID"{print $2}' "$COMFY_ROOT/.cluster-ids")"
      _srv_gid="$(awk -F= '$1=="SHARE_GID"{print $2}' "$COMFY_ROOT/.cluster-ids")"
      _my_uid="$(id -u "$TARGET_USER")"
      _my_gid="$(getent group "$SHARE_GROUP" | cut -d: -f3)"
      if [ -n "$_srv_uid" ] && [ "$_srv_uid" != "$_my_uid" ]; then
        warn "UID MISMATCH: '$TARGET_USER' is $_my_uid here but $_srv_uid on $SERVER_HOST."
        warn "  NFS maps ownership by number, so shared ComfyUI writes will hit permission errors."
        warn "  Fix on ONE box:  sudo usermod -u $_srv_uid $TARGET_USER && sudo chown -R $_srv_uid $USER_HOME"
        note_action "Resolve the '$TARGET_USER' UID mismatch between the two nodes before using the shared ComfyUI store."
      elif [ -n "$_srv_uid" ]; then
        ok "'$TARGET_USER' has the same uid ($_my_uid) on both nodes"
      fi
      if [ -n "$_srv_gid" ] && [ "$_srv_gid" != "$_my_gid" ]; then
        warn "GID MISMATCH: group '$SHARE_GROUP' is $_my_gid here but $_srv_gid on $SERVER_HOST."
        warn "  Fix with:  sudo groupmod -g $_srv_gid $SHARE_GROUP"
      fi
    fi

    # Local scratch that must NOT live on the shared (or read-only) trees.
    install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" \
      "$LLM_LOCAL_CACHE" "$LLM_LOCAL_CACHE/hub" "$LLM_LOCAL_CACHE/compile" "$LLM_LOCAL_CACHE/ray-spill" \
      "$COMFY_LOCAL_CACHE" "$COMFY_LOCAL_CACHE/temp" "$COMFY_LOCAL_CACHE/user" 2>/dev/null || true
  fi
  echo
fi

# =============================================================================
# 6. vLLM RUNTIME, RCCL/RAY NETWORKING AND THE MODEL CATALOG
# =============================================================================
# Both nodes must run byte-identical runtimes -- same ROCm, same RCCL, same Ray,
# same vLLM -- or cross-node tensor parallelism fails in confusing ways. Two
# supported ways to get there:
#
#   venv       an isolated virtualenv built from AMD's gfx1151 wheel index.
#              No Docker daemon, fastest to start, easiest to debug.
#   container  AMD's ROCm vLLM image, which is what the plan prefers. Pin the
#              SAME digest on both nodes (--vllm-image ...@sha256:...).
#
# Either way everything downstream talks to one wrapper, /usr/local/bin/llm-run,
# so the Ray units, the vllm@ template and residencyd never need to care which
# was chosen.
if [ "$INSTALL_VLLM" = "1" ]; then
  log "Installing the vLLM/Ray runtime ($VLLM_RUNTIME)"
  export DEBIAN_FRONTEND=noninteractive
  install -d -m 0755 "$LLM_ETC"

  # --- 6.0 ONE catalog, shared by both nodes --------------------------------
  # The catalog lives inside the shared model repository and /etc/llm/models.d
  # is a symlink to it. 'llm-model add' on the server is therefore instantly
  # visible on the peer, which mounts the same tree read-only. That removes the
  # classic two-node failure mode where the head schedules a model the worker
  # has never heard of.
  CATALOG_SHARED="$LLM_ROOT/catalog"
  [ "$IS_SERVER" = "1" ] && install -d -m 2775 -o "$LLM_USER" -g "$SHARE_GROUP" "$CATALOG_SHARED"
  if [ -d "$LLM_ETC/models.d" ] && [ ! -L "$LLM_ETC/models.d" ]; then
    if [ "$IS_SERVER" = "1" ] && [ -d "$CATALOG_SHARED" ]; then
      for _c in "$LLM_ETC/models.d"/*.conf; do
        [ -e "$_c" ] || continue
        mv -n "$_c" "$CATALOG_SHARED/" && warn "moved $(basename "$_c") into the shared catalog"
      done
    fi
    rmdir "$LLM_ETC/models.d" 2>/dev/null \
      || warn "$LLM_ETC/models.d still has files in it; leaving it as a local directory"
  fi
  if [ ! -e "$LLM_ETC/models.d" ] || [ -L "$LLM_ETC/models.d" ]; then
    ln -sfn "$CATALOG_SHARED" "$LLM_ETC/models.d"
    if [ -d "$LLM_ETC/models.d" ]; then
      ok "model catalog: $LLM_ETC/models.d -> $CATALOG_SHARED (shared by both nodes)"
    else
      warn "model catalog symlink points at $CATALOG_SHARED, which is not mounted yet."
      warn "  It starts working as soon as the NFS share from $SERVER_HOST comes up."
    fi
  fi

  # --- 6.1 cluster-wide environment ------------------------------------------
  # This is what pins the collectives to the USB4 cable instead of the 1 GbE LAN.
  # NOTE: the interface variables take a bare interface NAME. A common transcription
  # error is 'NCCL_SOCKET_IFNAME==usb4llm0' -- the doubled '=' makes NCCL look for
  # an interface literally called '=usb4llm0', fall back to the first interface it
  # can find, and quietly run every collective over the slow LAN instead.
  if [ "$IS_SERVER" = "1" ]; then
    NODE_HF_HOME="$LLM_ROOT"
    NODE_COMPILE_CACHE="$LLM_ROOT/.cache/vllm"
    install -d -m 2775 -o "$LLM_USER" -g "$SHARE_GROUP" "$LLM_ROOT/.cache" "$NODE_COMPILE_CACHE" 2>/dev/null || true
  else
    # $LLM_ROOT is a read-only NFS mount here, so anything that writes -- the HF
    # hub lock files, torch/vLLM's compiled-kernel cache -- must live locally.
    NODE_HF_HOME="$LLM_LOCAL_CACHE/hf"
    NODE_COMPILE_CACHE="$LLM_LOCAL_CACHE/compile"
    install -d -m 2775 -o "$LLM_USER" -g "$SHARE_GROUP" "$LLM_LOCAL_CACHE" "$NODE_HF_HOME" "$NODE_COMPILE_CACHE" 2>/dev/null || true
  fi
  RAY_SPILL_DIR="$([ "$IS_SERVER" = "1" ] && echo "$LLM_ROOT/.cache/ray-spill" || echo "$LLM_LOCAL_CACHE/ray-spill")"
  install -d -m 2775 -o "$LLM_USER" -g "$SHARE_GROUP" "$RAY_SPILL_DIR" 2>/dev/null || true

  cat > "$LLM_ETC/cluster.env" <<EOF
# Managed by setup-strixhalo-ai-server.sh -- cluster-wide runtime environment.
# Read by the Ray units, every vllm@ instance and residencyd.
# Node: $MY_HOST ($NODE_ROLE)   Peer: $OTHER_HOST

# --- pin all collective traffic to the USB4 link ---------------------------
NCCL_SOCKET_IFNAME=${CLUSTER_IFACE}
NCCL_SOCKET_FAMILY=AF_INET
GLOO_SOCKET_IFNAME=${CLUSTER_IFACE}
TP_SOCKET_IFNAME=${CLUSTER_IFACE}
# No InfiniBand and no GPUDirect on this hardware: say so explicitly rather than
# letting RCCL spend its startup probing for transports that cannot exist.
# NCCL_NET_GDR_LEVEL is deliberately NOT set -- an iGPU has no GPUDirect RDMA at
# all, and pinning the level only confuses the transport selection.
NCCL_IB_DISABLE=1
NCCL_SOCKET_NTHREADS=4
NCCL_DEBUG=WARN

# --- addresses -------------------------------------------------------------
VLLM_HOST_IP=${CLUSTER_LOCAL_IP}
# Address each vLLM instance listens on. On the PEER it must be the USB4
# address, because the gateway lives on the head node and has to reach
# peer-resident models across the cable; on the SERVER loopback is enough (and
# is stricter). Either way no vLLM port is ever exposed to the house LAN.
VLLM_BIND_ADDR=$([ "$IS_SERVER" = "1" ] && echo "127.0.0.1" || echo "${CLUSTER_LOCAL_IP}")
RAY_ADDRESS=${SERVER_IP}:${RAY_PORT}
# Ray's memory monitor reads host RAM, but on Strix Halo the "GPU" memory IS
# host RAM -- so a model that is behaving perfectly looks like imminent OOM and
# Ray kills the worker mid-inference. AMD's own clustering playbook disables it.
RAY_memory_monitor_refresh_ms=0
CLUSTER_ROLE=${NODE_ROLE}
CLUSTER_IFACE=${CLUSTER_IFACE}
CLUSTER_LOCAL_IP=${CLUSTER_LOCAL_IP}
CLUSTER_PEER_IP=${CLUSTER_PEER_IP}
CLUSTER_SERVER_IP=${SERVER_IP}
CLUSTER_WORKER_IP=${PEER_IP}

# --- model storage ---------------------------------------------------------
# HF_HOME must be WRITABLE. On the peer $LLM_ROOT is a read-only NFS mount, so
# it points at local scratch there; models are opened by absolute path either way.
HF_HOME=${NODE_HF_HOME}
HF_HUB_CACHE=${NODE_HF_HOME}/hub
LLM_MODELS_DIR=${LLM_ROOT}
VLLM_CACHE_ROOT=${NODE_COMPILE_CACHE}
TRITON_CACHE_DIR=${NODE_COMPILE_CACHE}/triton
OMP_NUM_THREADS=8

# --- ROCm ------------------------------------------------------------------
# gfx1151 is a first-class ROCm target: do NOT set HSA_OVERRIDE_GFX_VERSION.
# The old '=11.0.0' community hack makes ROCm load kernels for the wrong ISA.
ROCM_PATH=/opt/rocm
EOF
  chmod 0644 "$LLM_ETC/cluster.env"
  # Escape hatch for anything hardware- or model-specific that should not be
  # rewritten every time this script runs.
  if [ ! -f "$LLM_ETC/cluster.local.env" ]; then
    cat > "$LLM_ETC/cluster.local.env" <<'EOF'
# Local overrides for the LLM cluster. NOT managed by the setup script: put
# anything you want to survive a re-run here, one KEY=value per line.
# Examples you may need on Strix Halo:
#   VLLM_USE_TRITON_FLASH_ATTN=0
#   PYTORCH_HIP_ALLOC_CONF=expandable_segments:True
#   NCCL_DEBUG=INFO
EOF
    chmod 0644 "$LLM_ETC/cluster.local.env"
  fi
  ok "wrote $LLM_ETC/cluster.env (collectives pinned to $CLUSTER_IFACE, HF_HOME=$NODE_HF_HOME)"

  # --- 6.2 install the runtime ----------------------------------------------
  vllm_ready=0
  if [ "$VLLM_RUNTIME" = "venv" ]; then
    # Does AMD's gfx1151 index actually carry vLLM? If it does, installing
    # everything from the ONE index keeps torch/vllm/triton mutually consistent.
    # If it does not, installing vllm from PyPI would drag in the CUDA build of
    # torch and silently destroy the ROCm one, so we refuse to do that and say
    # exactly why instead of leaving a broken environment behind.
    vllm_index_has_vllm=0
    if curl -fsSL --max-time 25 "$VLLM_TORCH_INDEX" 2>/dev/null | grep -iE '>[[:space:]]*vllm[[:space:]]*<|href="[^"]*vllm' >/dev/null; then
      vllm_index_has_vllm=1
    fi
    if [ ! -x "$UV_SYS" ]; then
      warn "uv is not installed, so the vLLM virtualenv cannot be built (re-run without --skip base)."
    else
      uv_root_venv "$VLLM_PY" "$VLLM_VENV" || \
        warn "could not create the $VLLM_PY virtualenv at $VLLM_VENV"
      if [ -x "$VLLM_VENV/bin/python" ]; then
        log "  installing PyTorch for $ROCM_GFX from $VLLM_TORCH_INDEX"
        if "$UV_SYS" pip install --python "$VLLM_VENV/bin/python" \
             --index-url "$VLLM_TORCH_INDEX" --extra-index-url "$VLLM_PIP_EXTRA_INDEX" \
             torch torchvision torchaudio >/dev/null 2>&1; then
          ok "PyTorch (gfx1151 ROCm build) installed into $VLLM_VENV"
        else
          warn "could not install the gfx1151 PyTorch wheels from $VLLM_TORCH_INDEX"
        fi
        if [ "$vllm_index_has_vllm" = "1" ]; then
          log "  installing vLLM + Ray from the gfx1151 index"
          if "$UV_SYS" pip install --python "$VLLM_VENV/bin/python" \
               --index-url "$VLLM_TORCH_INDEX" --extra-index-url "$VLLM_PIP_EXTRA_INDEX" \
               "$VLLM_PKG" "$RAY_PKG" >/dev/null 2>&1; then
            vllm_ready=1
            ok "vLLM + Ray installed into $VLLM_VENV"
          else
            warn "vLLM/Ray installation from $VLLM_TORCH_INDEX failed"
          fi
        else
          warn "$VLLM_TORCH_INDEX does not publish a 'vllm' wheel for $ROCM_GFX."
          warn "  (It carries torch/torchvision/torchaudio/triton, but not vLLM.)"
          warn "  Installing vLLM from PyPI here would pull the CUDA build of torch and"
          warn "  overwrite the ROCm one, so it is deliberately NOT attempted."
          warn "  Use the container runtime instead (the plan's preferred baseline):"
          warn "     sudo ./$SCRIPT_NAME --server $SERVER_HOST --peer $PEER_HOST \\"
          warn "          --vllm-runtime container --vllm-image oci-registry.ryai.dev/ryai-vllm:latest"
          note_action "vLLM was NOT installed: no gfx1151 wheel is published. Re-run with --vllm-runtime container (identical image on BOTH nodes)."
        fi
        if [ "$vllm_ready" = "1" ]; then
          _venv_versions="$("$VLLM_VENV/bin/python" -c \
            'import ray, vllm; print("vllm=" + str(vllm.__version__)); print("ray=" + str(ray.__version__))' \
            2>/dev/null || true)"
          _actual_vllm="$(printf '%s\n' "$_venv_versions" \
            | awk -F= '/^vllm=/{print $2; exit}')"
          _actual_ray="$(printf '%s\n' "$_venv_versions" \
            | awk -F= '/^ray=/{print $2; exit}')"
          [ "$_actual_vllm" = "$VLLM_EXPECTED_VERSION" ] \
            && [ "$_actual_ray" = "$RAY_EXPECTED_VERSION" ] \
            || die "venv runtime compatibility mismatch: vLLM=$_actual_vllm (expected $VLLM_EXPECTED_VERSION), Ray=$_actual_ray (expected $RAY_EXPECTED_VERSION)"
          ok "venv runtime versions verified: vLLM=$_actual_vllm, Ray=$_actual_ray"
        fi
        # Ray on its own is still worth having: it is what makes 'ray status'
        # able to report the cluster even before a model runtime exists.
        if [ "$vllm_ready" != "1" ] && [ -x "$VLLM_VENV/bin/python" ]; then
          "$UV_SYS" pip install --python "$VLLM_VENV/bin/python" "$RAY_PKG" >/dev/null 2>&1 \
            && ok "Ray installed into $VLLM_VENV (vLLM still missing)" || true
        fi
        # ray-head/ray-worker/vllm@ all run as $LLM_USER, never as root.
        if ! venv_execs_as "$LLM_USER" "$VLLM_VENV"; then
          warn "$VLLM_VENV/bin/python is not executable by '$LLM_USER' - Ray and vLLM would fail 203/EXEC"
          note_action "The vLLM interpreter is unreachable for '$LLM_USER'. Fix with: sudo chmod -R a+rX $UV_PYTHON_DIR $VLLM_VENV"
        fi
      fi
    fi
  else
    # ------------------------------------------------------------- container
    # This is the path AMD's own "Clustering Two Ryzen AI Halos with RCCL"
    # playbook uses, and the only one that currently yields a working gfx1151
    # vLLM: AMD's wheel index publishes torch/triton for this ISA but no vllm.
    # podman is the playbook's engine and needs no daemon; docker behaves
    # identically for every flag used below, so either is accepted.
    CE=""
    case "$CONTAINER_ENGINE" in
      podman) CE=podman ;;
      docker) CE=docker ;;
      auto)   for _e in podman docker; do
                if command -v "$_e" >/dev/null 2>&1; then CE="$_e"; break; fi
              done ;;
    esac
    if [ -z "$CE" ] || ! command -v "$CE" >/dev/null 2>&1; then
      _want="${CE:-podman}"
      log "  installing the $_want container engine"
      case "$_want" in
        podman) apt-get install -y podman >/dev/null 2>&1 || true ;;
        docker) apt-get install -y docker.io >/dev/null 2>&1 || true
                systemctl enable --now docker >/dev/null 2>&1 || true ;;
      esac
      command -v "$_want" >/dev/null 2>&1 && CE="$_want" || CE=""
    fi
    if [ -z "$CE" ]; then
      warn "no container engine could be installed, so the container runtime is unavailable."
      note_action "Install podman (or docker.io) and re-run with --skip base --skip rocm --skip usb4 --skip nfs."
    else
      CE_BIN="$(command -v "$CE")"
      [ "$CE" = "docker" ] && systemctl enable --now docker >/dev/null 2>&1 || true
      ok "container engine: $CE_BIN"
      case "$VLLM_IMAGE" in
        *@sha256:*)
          ok "vLLM image supplied by digest (both nodes will match exactly)" ;;
        *)
          info "vLLM image tag '$VLLM_IMAGE' will be resolved to an immutable digest after pull." ;;
      esac
      log "  pulling $VLLM_IMAGE (this is several GB and can take a while)"
      if "$CE" pull "$VLLM_IMAGE" >/dev/null 2>&1; then
        vllm_ready=1
        _image_digest="$("$CE" image inspect --format '{{index .RepoDigests 0}}' \
          "$VLLM_IMAGE" 2>/dev/null || true)"
        [ -n "$_image_digest" ] \
          || die "could not resolve an immutable digest for vLLM image '$VLLM_IMAGE'"
        VLLM_IMAGE="$_image_digest"
        ok "pulled base vLLM image: $VLLM_IMAGE"

        # The base image owns the Python environment, so RAY_PKG cannot repair
        # a container runtime. Inspect it before creating the services and, when
        # only Ray is wrong, build the compatible overlay automatically. This
        # keeps the setup turnkey while preserving the exact gfx1151 vLLM base.
        _base_versions="$("$CE" run --rm \
          --entrypoint "$VLLM_CONTAINER_PYTHON" "$VLLM_IMAGE" \
          -c 'import ray, vllm; print("vllm=" + str(vllm.__version__)); print("ray=" + str(ray.__version__))' \
          2>/dev/null || true)"
        _base_vllm="$(printf '%s\n' "$_base_versions" \
          | awk -F= '/^vllm=/{print $2; exit}')"
        _base_ray="$(printf '%s\n' "$_base_versions" \
          | awk -F= '/^ray=/{print $2; exit}')"
        [ -n "$_base_vllm" ] && [ -n "$_base_ray" ] \
          || die "could not inspect vLLM/Ray in base image $VLLM_IMAGE (expected Python at $VLLM_CONTAINER_PYTHON)"
        [ "$_base_vllm" = "$VLLM_EXPECTED_VERSION" ] \
          || die "base image vLLM version is $_base_vllm, expected $VLLM_EXPECTED_VERSION for this gfx1151 setup"

        if [ "$_base_ray" != "$RAY_EXPECTED_VERSION" ]; then
          _base_short="${VLLM_IMAGE##*@sha256:}"
          _base_short="${_base_short:0:16}"
          _compat_image="localhost/strixhalo-vllm:vllm-${VLLM_EXPECTED_VERSION}-ray-${RAY_EXPECTED_VERSION}-base-${_base_short}"
          if ! "$CE" image inspect "$_compat_image" >/dev/null 2>&1; then
            log "  building compatible runtime overlay (Ray $_base_ray -> $RAY_EXPECTED_VERSION)"
            _build_dir="$(mktemp -d /tmp/strixhalo-vllm-build.XXXXXX)"
            cat > "$_build_dir/Containerfile" <<'CONTAINERFILE'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG RAY_VERSION
ARG RUNTIME_PYTHON
RUN set -eux; \
    if "$RUNTIME_PYTHON" -m pip --version >/dev/null 2>&1; then \
      "$RUNTIME_PYTHON" -m pip install --no-cache-dir --force-reinstall \
        "ray[default]==$RAY_VERSION"; \
    elif command -v uv >/dev/null 2>&1; then \
      uv pip install --python "$RUNTIME_PYTHON" --reinstall \
        "ray[default]==$RAY_VERSION"; \
    else \
      echo "no pip or uv is available in the vLLM image" >&2; exit 1; \
    fi
CONTAINERFILE
            if ! "$CE" build \
                 --build-arg "BASE_IMAGE=$VLLM_IMAGE" \
                 --build-arg "RAY_VERSION=$RAY_EXPECTED_VERSION" \
                 --build-arg "RUNTIME_PYTHON=$VLLM_CONTAINER_PYTHON" \
                 -t "$_compat_image" "$_build_dir"; then
              rm -rf "$_build_dir"
              die "could not build the automatic Ray $RAY_EXPECTED_VERSION compatibility overlay"
            fi
            rm -rf "$_build_dir"
          fi
          _compat_id="$("$CE" image inspect --format '{{.Id}}' \
            "$_compat_image" 2>/dev/null || true)"
          [ -n "$_compat_id" ] \
            || die "could not resolve the generated compatibility image $_compat_image"
          VLLM_IMAGE="$_compat_id"
          ok "using generated immutable runtime image $VLLM_IMAGE (vLLM $_base_vllm, Ray $RAY_EXPECTED_VERSION)"
        else
          ok "base runtime versions verified: vLLM=$_base_vllm, Ray=$_base_ray"
        fi
      else
        warn "could not pull '$VLLM_IMAGE'. Check the name/tag and that this box can reach the registry."
        warn "  Known-good gfx1151 images:"
        warn "     oci-registry.ryai.dev/ryai-vllm:latest        (AMD's clustering playbook)"
        warn "     docker.io/kyuz0/vllm-therock-gfx1151:latest   (community, tracks newer vLLM)"
        note_action "vLLM image '$VLLM_IMAGE' could not be pulled - fix it, then re-run with --skip base --skip rocm --skip usb4 --skip nfs."
      fi
    fi
  fi

  # --- 6.3 one wrapper the rest of the system uses --------------------------
  # Everything downstream (Ray units, vllm@ instances, residencyd, the admin
  # helpers) invokes the runtime through this, so switching venv <-> container
  # is a single-file change instead of a rewrite.
  cat > "$LLM_ETC/runtime.env" <<EOF
# Managed by setup-strixhalo-ai-server.sh
VLLM_RUNTIME=${VLLM_RUNTIME}
VLLM_VENV=${VLLM_VENV}
VLLM_IMAGE=${VLLM_IMAGE}
VLLM_CONTAINER=${VLLM_CONTAINER}
VLLM_CONTAINER_PYTHON=${VLLM_CONTAINER_PYTHON}
VLLM_EXPECTED_VERSION=${VLLM_EXPECTED_VERSION}
RAY_EXPECTED_VERSION=${RAY_EXPECTED_VERSION}
CONTAINER_ENGINE=${CE:-}
CE_BIN=${CE_BIN:-}
LLM_ROOT=${LLM_ROOT}
LLM_ETC=${LLM_ETC}
LLM_USER=${LLM_USER}
SHARE_GROUP=${SHARE_GROUP}
RAY_SPILL_DIR=${RAY_SPILL_DIR}
RAY_PORT=${RAY_PORT}
RAY_DASHBOARD_PORT=${RAY_DASHBOARD_PORT}
RAY_WORKER_PORT_MIN=${RAY_WORKER_PORT_MIN}
RAY_WORKER_PORT_MAX=${RAY_WORKER_PORT_MAX}
VLLM_PORT_BASE=${VLLM_PORT_BASE}
AGENT_PORT=${AGENT_PORT}
GATEWAY_PORT=${GATEWAY_PORT}
RESIDENCY_SOCK=${RESIDENCY_SOCK}
RESIDENCY_BUDGET_GIB=${RESIDENCY_BUDGET_GIB}
RESIDENCY_MARGIN_GIB=${RESIDENCY_MARGIN_GIB}
RESIDENCY_IDLE_TIMEOUT=${RESIDENCY_IDLE_TIMEOUT}
RESIDENCY_LOAD_TIMEOUT=${RESIDENCY_LOAD_TIMEOUT}
RESIDENCY_RESERVE_FLOOR_GIB=${RESIDENCY_RESERVE_FLOOR_GIB}
RESIDENCY_CRITICAL_FLOOR_GIB=${RESIDENCY_CRITICAL_FLOOR_GIB}
RESIDENCY_LOAD_PEAK_FACTOR=${RESIDENCY_LOAD_PEAK_FACTOR}
RESIDENCY_MEASURE=${RESIDENCY_MEASURE}
RESIDENCY_MEASURE_STRICT=${RESIDENCY_MEASURE_STRICT}
HF_TOOLS_VENV=${HF_TOOLS_VENV}
LLM_MAX_LEN_CAP=${LLM_MAX_LEN_CAP}
LLM_HYBRID_MAX_SEQS=${LLM_HYBRID_MAX_SEQS}
LLM_GC_MIN_FREE_GIB=${LLM_GC_MIN_FREE_GIB}
LLM_GC_MAX_IDLE_DAYS=${LLM_GC_MAX_IDLE_DAYS}
CONFIGURE_MODEL_GC=${CONFIGURE_MODEL_GC}
EOF
  chmod 0644 "$LLM_ETC/runtime.env"

  cat > /usr/local/bin/llm-run <<'RUNNER'
#!/usr/bin/env bash
# Managed by setup-strixhalo-ai-server.sh
# llm-run <command> [args...]   -- run a command inside the cluster's vLLM/Ray
# runtime, whichever kind was installed. Examples:
#     llm-run ray status
#     llm-run vllm serve /srv/models/foo --port 18001
#     llm-run python -c 'import torch; print(torch.cuda.is_available())'
set -Eeuo pipefail
. /etc/llm/runtime.env
[ $# -ge 1 ] || { echo "usage: llm-run <command> [args...]" >&2; exit 2; }

if [ "${VLLM_RUNTIME:-venv}" = "container" ]; then
  # The long-lived runtime container is started by llm-runtime.service; exec
  # into it so every process shares one ROCm/Ray installation.
  CE="${CE_BIN:-${CONTAINER_ENGINE:-podman}}"
  command -v "$CE" >/dev/null 2>&1 || { echo "llm-run: container engine '$CE' not found" >&2; exit 1; }
  if ! "$CE" inspect -f '{{.State.Running}}' "$VLLM_CONTAINER" 2>/dev/null | grep true >/dev/null; then
    echo "llm-run: container '$VLLM_CONTAINER' is not running (systemctl start llm-runtime)" >&2
    exit 1
  fi
  exec "$CE" exec -i \
    --env-file /etc/llm/cluster.env \
    "$VLLM_CONTAINER" "$@"
fi

cmd="$1"; shift
if [ -x "$VLLM_VENV/bin/$cmd" ]; then
  exec "$VLLM_VENV/bin/$cmd" "$@"
fi
# Fall back to running it through the venv's interpreter so 'llm-run python ...'
# and module entry points keep working even when there is no console script.
exec "$VLLM_VENV/bin/python" -m "$cmd" "$@"
RUNNER
  chmod 0755 /usr/local/bin/llm-run
  ok "wrote /usr/local/bin/llm-run (runtime abstraction for Ray, vLLM and diagnostics)"

  # --- 6.4 the long-lived runtime container (container mode only) -----------
  if [ "$VLLM_RUNTIME" = "container" ] && [ -n "${CE_BIN:-}" ]; then
    _models_mode="ro"; [ "$IS_SERVER" = "1" ] && _models_mode="rw"
    # Only docker has a daemon to order against; podman is daemonless.
    _ce_dep=""
    [ "$CE" = "docker" ] && _ce_dep=$'After=docker.service\nRequires=docker.service'
    # SELinux-labelling volume suffix: harmless on Ubuntu, required if anyone
    # ever runs this on an enforcing distro. podman honours it, docker ignores it.
    _vsfx=""; [ "$CE" = "podman" ] && _vsfx=",z"
    # --group-add takes a group name and podman resolves it in the CONTAINER's
    # /etc/group, not the host's. The ROCm image has no 'render' entry, so
    # '--group-add render' aborts the container before it starts:
    #   "unable to find group render: no matching entries in group file"
    # What actually governs access to /dev/kfd and /dev/dri is the NUMERIC gid,
    # which is identical on both sides of the namespace, so pass the numbers.
    _grp_args=""
    for _g in video render; do
      _gid="$(getent group "$_g" 2>/dev/null | cut -d: -f3)"
      if [ -n "$_gid" ]; then
        _grp_args="$_grp_args --group-add $_gid"
      else
        warn "no '$_g' group on this host; the container may not reach the GPU"
      fi
    done
    _grp_args="${_grp_args# }"
    # Build the volume list with the destination de-duplicated. On the SERVER
    # NODE_HF_HOME is $LLM_ROOT, so the literal list emitted the same
    # destination twice and podman aborts with "duplicate mount destination".
    # The mode is always spelled out because the SELinux suffix is part of the
    # OPTION field: '/x:/x,z' has only two colon-separated fields, which makes
    # podman read the destination as the literal path '/x,z'.
    _vols=""; _seen=" "
    for _spec in "$LLM_ETC|ro" "$LLM_ROOT|$_models_mode" "$NODE_HF_HOME|rw" \
                 "$NODE_COMPILE_CACHE|rw" "$RAY_SPILL_DIR|rw"; do
      _vp="${_spec%|*}"; _vm="${_spec##*|}"
      [ -n "$_vp" ] || continue
      case "$_seen" in *" $_vp "*) continue ;; esac
      _seen="$_seen$_vp "
      _vols="${_vols}  -v ${_vp}:${_vp}:${_vm}${_vsfx} \\
"
    done
    # With --ipc host the container shares the HOST's /dev/shm, so the size is
    # governed there. Written as a helper rather than inline shell because
    # systemd expands $VAR in Exec= lines even inside single quotes.
    cat > /usr/local/bin/llm-shm-check <<'SHMCHK'
#!/usr/bin/env bash
# Warn (never fail) if the host's shared-memory pool is too small for torch.
# vLLM's shared-memory tensors are far larger than a default container /dev/shm;
# too little here surfaces as an unexplained "Bus error" deep inside torch.
avail="$(df -B1G --output=avail /dev/shm 2>/dev/null | tail -n1 | tr -dc '0-9')"
if [ -n "$avail" ] && [ "$avail" -lt 8 ]; then
  echo "llm-runtime: /dev/shm has only ${avail} GiB free - large torch tensors" \
       "may fail with a bus error. systemd sizes it at 50% of RAM by default." >&2
fi
exit 0
SHMCHK
    chmod 0755 /usr/local/bin/llm-shm-check
    # Nothing that runs 'llm-run' may assume the container is usable just
    # because llm-runtime.service is active. That unit is Type=exec, so systemd
    # calls it active the instant 'podman run' execs - well before the container
    # is accepting 'podman exec'. On mighty-ai2 the Ray worker won that race and
    # died on its first command with "container 'llm-runtime' is not running";
    # because a BindsTo= device job happened to be pending, systemd then skipped
    # the automatic restart and the node stayed out of the cluster.
    cat > /usr/local/bin/llm-runtime-wait <<RTWAIT
#!/usr/bin/env bash
# Block until the runtime container is really running. \$1 = seconds (default 180).
deadline=\$(( \$(date +%s) + \${1:-180} ))
while [ "\$(date +%s)" -lt "\$deadline" ]; do
  case "\$(${CE_BIN} inspect -f '{{.State.Running}}' ${VLLM_CONTAINER} 2>/dev/null)" in
    true) exit 0 ;;
  esac
  sleep 3
done
echo "llm-runtime-wait: container '${VLLM_CONTAINER}' was not running after \${1:-180}s" >&2
echo "  check: systemctl status llm-runtime; ${CE_BIN} logs ${VLLM_CONTAINER}" >&2
exit 1
RTWAIT
    chmod 0755 /usr/local/bin/llm-runtime-wait
    cat > /etc/systemd/system/llm-runtime.service <<UNIT
[Unit]
Description=LLM cluster runtime container (ROCm + vLLM + Ray)
After=network-online.target
Wants=network-online.target
# Give up eventually. Restart=always with no limit turns a permanent config
# error into a unit that reports 'activating' forever, which reads as "still
# coming up" when it is really "broken 60 times in a row".
StartLimitIntervalSec=1800
StartLimitBurst=20
${_ce_dep}

[Service]
Type=exec
Restart=always
RestartSec=10
TimeoutStartSec=900
ExecStartPre=-${CE_BIN} rm -f ${VLLM_CONTAINER}
# --network host: Ray and RCCL both need to bind the real USB4 address, and NAT
#   would hide it from the other node.
# --ipc host: torch's shared-memory tensors are far bigger than the 64 MB
#   container default and fail with cryptic bus errors without it. Note there is
#   deliberately NO --shm-size here: podman REFUSES the combination outright --
#     "invalid config provided: cannot set shmsize when running in the
#      {host } IPC Namespace"   (exit 125, the container never starts)
#   -- and it is right to, because with --ipc host the container uses the HOST's
#   /dev/shm and a container-scoped size is meaningless. docker merely ignores
#   it. Sizing the pool on the host is also what we want on a unified-memory
#   box: ONE shm pool that shows up in 'free', not a second one the residency
#   budget cannot see. systemd's default is 50% of RAM (~61 GiB here).
ExecStartPre=/usr/local/bin/llm-shm-check
# /dev/kfd + /dev/dri with the video/render groups is the documented ROCm
#   container recipe; without them the GPU simply is not visible inside. The
#   groups are given as NUMERIC gids because podman looks group NAMES up in the
#   container's /etc/group, where 'render' does not exist.
# --pids-limit=-1: vLLM plus Ray plus RCCL spawn well past the default cap.
# --entrypoint sleep: this container only ever needs to sit idle so 'podman
#   exec' (see llm-run) can jump in and run 'vllm'/'ray' directly - it bypasses
#   ENTRYPOINT/CMD entirely, so overriding it here has no effect on real work.
#   It is REQUIRED, though: the ryai-vllm image's default ENTRYPOINT is the
#   'vllm' CLI itself, so 'podman run ... IMAGE sleep infinity' was handed to
#   THAT as 'vllm sleep infinity', which vllm rejects as an invalid subcommand
#   (exit 2) - an instant, permanent crash loop with no GPU work ever attempted.
ExecStart=${CE_BIN} run --rm --name ${VLLM_CONTAINER} \\
  --network host --ipc host --pids-limit=-1 \\
  --device /dev/kfd --device /dev/dri \\
  ${_grp_args} \\
  --cap-add SYS_PTRACE --security-opt seccomp=unconfined \\
  --env-file ${LLM_ETC}/cluster.env \\
  --env-file ${LLM_ETC}/cluster.local.env \\
${_vols}  --entrypoint sleep ${VLLM_IMAGE} infinity
ExecStop=${CE_BIN} stop -t 30 ${VLLM_CONTAINER}

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable llm-runtime.service >/dev/null 2>&1 || true
    if [ "$vllm_ready" = "1" ]; then
      systemctl restart llm-runtime.service >/dev/null 2>&1 || true
      _runtime_versions=""
      for _i in $(seq 1 60); do
        _runtime_versions="$("$CE" exec "$VLLM_CONTAINER" "$VLLM_CONTAINER_PYTHON" \
          -c 'import ray, vllm; print("vllm=" + str(vllm.__version__)); print("ray=" + str(ray.__version__))' \
          2>/dev/null || true)"
        [ -n "$_runtime_versions" ] && break
        sleep 2
      done
      [ -n "$_runtime_versions" ] \
        || die "runtime container '$VLLM_CONTAINER' did not expose its vLLM/Ray versions"
      _actual_vllm="$(printf '%s\n' "$_runtime_versions" \
        | awk -F= '/^vllm=/{print $2; exit}')"
      _actual_ray="$(printf '%s\n' "$_runtime_versions" \
        | awk -F= '/^ray=/{print $2; exit}')"
      [ "$_actual_vllm" = "$VLLM_EXPECTED_VERSION" ] \
        && [ "$_actual_ray" = "$RAY_EXPECTED_VERSION" ] \
        || die "runtime compatibility mismatch in $VLLM_IMAGE: vLLM=$_actual_vllm (expected $VLLM_EXPECTED_VERSION), Ray=$_actual_ray (expected $RAY_EXPECTED_VERSION). Supply a tested image or override both expected versions together."
      ok "runtime versions verified: vLLM=$_actual_vllm, Ray=$_actual_ray"
    fi
    ok "llm-runtime.service created (persistent ROCm/vLLM container via $CE)"
  else
    # Switching back from container mode should not leave a stale unit behind.
    if [ -f /etc/systemd/system/llm-runtime.service ] && [ "$VLLM_RUNTIME" != "container" ]; then
      systemctl disable --now llm-runtime.service >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/llm-runtime.service
      systemctl daemon-reload
    fi
  fi

  # --- 6.5 Ray ---------------------------------------------------------------
  # Ray is what places the second half of a TP=2 model on the other machine.
  # Both units bind explicitly to this node's USB4 address: left to itself Ray
  # picks whatever the default route says, which here is the 1 GbE LAN.
  # When the cluster half is deliberately skipped there is no USB4 interface to
  # follow, so fall back to the ordinary boot target - Ray is still useful for a
  # single-node scheduler even though nothing needs the second machine.
  if [ "${CONFIGURE_CLUSTER:-1}" = "1" ]; then
    _dev_unit="sys-subsystem-net-devices-${CLUSTER_IFACE}.device"
    _dev_dep="BindsTo=${_dev_unit}
After=${_dev_unit}"
  else
    _dev_unit="multi-user.target"
    _dev_dep="# no USB4 interface on this node; started at boot like anything else"
  fi
  # In container mode every 'llm-run' is a 'podman exec', so the container has to
  # be up first. 'After=llm-runtime.service' only orders against systemd's idea
  # of active, which arrives too early - hence the explicit wait. 'Wants=' (not
  # 'Requires=') so a runtime that is temporarily down leaves Ray retrying under
  # Restart=always instead of being torn down with it.
  _rt_dep=""; _rt_wait=""
  if [ "$VLLM_RUNTIME" = "container" ] && [ -n "${CE_BIN:-}" ]; then
    _rt_dep="Wants=llm-runtime.service"
    _rt_wait="ExecStartPre=/usr/local/bin/llm-runtime-wait 180"
  fi
  # Which account the units run AS, and why it differs by runtime.
  #
  # In container mode these units are not the workload - they are a podman
  # CLIENT. Ray and vLLM themselves run inside the container, as whatever user
  # the image uses. Running the client under an unprivileged account therefore
  # contains nothing; it merely points the client at the WRONG podman. podman is
  # rootless for every user except root, so 'llm' gets its own empty container
  # store, cannot see the root-owned llm-runtime container that
  # llm-runtime.service created, and every single llm-run ends in
  #     llm-run: container 'llm-runtime' is not running
  # which is exactly what ray-worker logged on mighty-ai2 while root's own
  # verification pass reported the same container as running. (With a system
  # account it is usually worse than a lookup miss: no subuid/subgid range and
  # no writable HOME means rootless podman cannot even initialise its store.)
  #
  # In venv mode the unit really does execute the workload, so there it keeps
  # its own account and the GPU groups it needs.
  if [ "$VLLM_RUNTIME" = "container" ] && [ -n "${CE_BIN:-}" ]; then
    _svc_user="# Runs as root on purpose: this unit is only the podman client (see llm-run).
# podman is rootless for anyone but root, and the runtime container belongs to
# root, so an unprivileged client would look in an empty store and never find
# it. Confinement here is the container's job, not this account's."
  else
    _svc_user="User=${LLM_USER}
Group=${LLM_USER}
SupplementaryGroups=render video ${SHARE_GROUP}"
  fi
  # Both units are wanted by the interface device AND by multi-user.target. The
  # device symlink is what makes them follow the cable; the target symlink is
  # what guarantees a fresh attempt on every boot, so a start job lost to a
  # shutdown cannot strand the node out of the cluster.
  if [ "$_dev_unit" = "multi-user.target" ]; then
    _install_wants="WantedBy=multi-user.target"
  else
    _install_wants="WantedBy=${_dev_unit}
WantedBy=multi-user.target"
  fi
  # systemd derives a mount unit name from the path; ask it rather than guessing.
  _mnt_dep="# (no mount unit derived for ${LLM_ROOT})"
  if command -v systemd-escape >/dev/null 2>&1; then
    _mnt_unit="$(systemd-escape -p --suffix=mount "$LLM_ROOT" 2>/dev/null || true)"
    [ -n "$_mnt_unit" ] && _mnt_dep="After=${_mnt_unit}"
  fi
  ray_common="--num-gpus=1 --min-worker-port=${RAY_WORKER_PORT_MIN} --max-worker-port=${RAY_WORKER_PORT_MAX} --disable-usage-stats"
  if [ "$IS_SERVER" = "1" ]; then
    rm -f /etc/systemd/system/ray-worker.service
    cat > /etc/systemd/system/ray-head.service <<UNIT
[Unit]
Description=Ray head node (LLM cluster)
Documentation=https://docs.ray.io/
After=network-online.target llm-runtime.service
Wants=network-online.target
${_rt_dep}
# Ray's head binds to the USB4 address, which only exists while the cable is up
# and the other machine is powered on. Binding the unit to the interface device
# means: no cable, no crash loop - it simply is not started, and it starts by
# itself the moment the link appears. Single-node models never need Ray, so the
# head node stays fully usable meanwhile.
${_dev_dep}

[Service]
Type=simple
EnvironmentFile=${LLM_ETC}/cluster.env
EnvironmentFile=-${LLM_ETC}/cluster.local.env
Environment=RAY_TMPDIR=${RAY_SPILL_DIR}
${_svc_user}
UMask=0002

WorkingDirectory=${LLM_ROOT}
# Wait for the cable, but never block the boot on it.
ExecStartPre=/usr/local/bin/usb4-cluster-wait ${CLUSTER_LOCAL_IP} 60
${_rt_wait}
ExecStartPre=-/usr/local/bin/llm-run ray stop --force
ExecStart=/usr/local/bin/llm-run ray start --head --block \\
  --node-ip-address=${SERVER_IP} --port=${RAY_PORT} \\
  --dashboard-host=127.0.0.1 --dashboard-port=${RAY_DASHBOARD_PORT} \\
  ${ray_common}
ExecStop=-/usr/local/bin/llm-run ray stop --force
Restart=always
RestartSec=10
# The ExecStartPre chain can legitimately spend 60s waiting for the cable and
# another 180s waiting for the runtime container; the limit has to clear both
# with room for Ray's own startup, or systemd kills the unit mid-wait.
TimeoutStartSec=900

[Install]
# Primarily the unit follows the cable: it starts when ${CLUSTER_IFACE} appears
# (at boot or when the peer is switched on) and stops cleanly when it goes away.
# multi-user.target is listed as well so that EVERY boot queues a start attempt.
# Without it, a single dropped start job - the shutdown that SIGTERMs an
# ExecStartPre still in flight, say - leaves the unit inactive until someone
# physically re-plugs the cable, because nothing else ever triggers it again.
${_install_wants}
UNIT
    ok "ray-head.service created (GCS on ${SERVER_IP}:${RAY_PORT}, dashboard on loopback only)"
  else
    rm -f /etc/systemd/system/ray-head.service
    cat > /etc/systemd/system/ray-worker.service <<UNIT
[Unit]
Description=Ray worker node (LLM cluster)
Documentation=https://docs.ray.io/
After=network-online.target llm-runtime.service
Wants=network-online.target
${_rt_dep}
# Ordered after the shared model tree, but deliberately NOT requiring it.
# RequiresMountsFor= is Requires= plus After=, and on this node ${LLM_ROOT} is an
# NFS mount served by the OTHER machine. If that box is still booting the mount
# unit fails, and a Requires= turns that into "Dependency failed" - a start job
# that is dropped, never retried, and leaves the worker inactive indefinitely.
# That is exactly how mighty-ai2 came up with ray-worker dead. The ExecStartPre
# chain below already waits for the server, which is the honest way to say it.
${_mnt_dep}
# Same reasoning as the head: no cable, no worker, and no crash loop either.
${_dev_dep}

[Service]
Type=simple
EnvironmentFile=${LLM_ETC}/cluster.env
EnvironmentFile=-${LLM_ETC}/cluster.local.env
Environment=RAY_TMPDIR=${RAY_SPILL_DIR}
${_svc_user}
UMask=0002

WorkingDirectory=${LLM_LOCAL_CACHE}
# The head may still be booting, so wait for it rather than crash-looping.
ExecStartPre=/usr/local/bin/usb4-cluster-wait ${SERVER_IP} 180
${_rt_wait}
ExecStartPre=-/usr/local/bin/llm-run ray stop --force
ExecStart=/usr/local/bin/llm-run ray start --block \\
  --address=${SERVER_IP}:${RAY_PORT} --node-ip-address=${PEER_IP} \\
  ${ray_common}
ExecStop=-/usr/local/bin/llm-run ray stop --force
Restart=always
RestartSec=15
# 180s waiting for the head plus 180s waiting for the runtime container already
# exceeds the old 300s limit, which would have killed the unit mid-wait.
TimeoutStartSec=900

[Install]
# Follows the cable, plus a start attempt on every boot - see ray-head.service.
${_install_wants}
UNIT
    ok "ray-worker.service created (joins ${SERVER_IP}:${RAY_PORT} as ${PEER_IP})"
  fi
  systemctl daemon-reload
  # Re-enable so both WantedBy symlinks land: one in the .device.wants directory
  # (follow the cable) and one in multi-user.target.wants (try on every boot).
  # The 'disable' first clears whatever an earlier run of this script left
  # behind, so the set of symlinks always matches the unit as written now.
  _ray_unit="$([ "$IS_SERVER" = "1" ] && echo ray-head.service || echo ray-worker.service)"
  systemctl disable "$_ray_unit" >/dev/null 2>&1 || true
  if systemctl enable "$_ray_unit" >/dev/null 2>&1; then
    ok "$_ray_unit starts when ${CLUSTER_IFACE} appears, and is retried on every boot"
  else
    warn "could not enable $_ray_unit; start it by hand once the cable is up"
  fi

  # --- 6.6 the per-model systemd template -----------------------------------
  # One instance per catalogued model. residencyd owns their lifecycle; nobody
  # is expected to start or stop these by hand.
  cat > /usr/local/bin/vllm-serve <<'SERVE'
#!/usr/bin/env bash
# Managed by setup-strixhalo-ai-server.sh
# vllm-serve <model-name>  -- launch the catalogued model <model-name>, reading
# its fixed settings from /etc/llm/models.d/<model-name>.conf. Invoked by
# vllm@<model-name>.service; residencyd starts and stops that unit.
set -Eeuo pipefail
NAME="${1:?usage: vllm-serve <model-name>}"
CONF="/etc/llm/models.d/${NAME}.conf"
[ -r "$CONF" ] || { echo "vllm-serve: no such model in the catalog: $CONF" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF"
. /etc/llm/runtime.env
# systemd already injects these through EnvironmentFile=; re-read them so the
# script also behaves correctly when a human runs it directly for debugging.
set -a
# shellcheck disable=SC1091
[ -r /etc/llm/cluster.env ] && . /etc/llm/cluster.env
# shellcheck disable=SC1091
[ -r /etc/llm/cluster.local.env ] && . /etc/llm/cluster.local.env
set +a

: "${MODEL_PATH:?$CONF must set MODEL_PATH}"
: "${PORT:?$CONF must set PORT}"
SERVED_NAME="${SERVED_NAME:-$NAME}"
TENSOR_PARALLEL="${TENSOR_PARALLEL:-1}"
PIPELINE_PARALLEL="${PIPELINE_PARALLEL:-1}"
PLACEMENT="${PLACEMENT:-auto}"

if [ ! -e "$MODEL_PATH" ]; then
  echo "vllm-serve: model path '$MODEL_PATH' does not exist." >&2
  echo "vllm-serve: on the peer this usually means the NFS share is not mounted yet." >&2
  exit 3
fi

args=( serve "$MODEL_PATH"
       --served-model-name "$SERVED_NAME"
       --host "${VLLM_BIND_ADDR:-127.0.0.1}" --port "$PORT"
       --tensor-parallel-size "$TENSOR_PARALLEL"
       --pipeline-parallel-size "$PIPELINE_PARALLEL" )

# Ray is only needed when the model is genuinely split across both machines --
# either tensor-parallel WITHIN a node or pipeline-parallel ACROSS the two.
# For a single-node model it adds a scheduler hop and a failure mode for nothing.
if [ "$PLACEMENT" = "distributed" ] || [ "${TENSOR_PARALLEL}" -gt 1 ] || [ "${PIPELINE_PARALLEL}" -gt 1 ]; then
  args+=( --distributed-executor-backend ray )
fi
[ -n "${MAX_MODEL_LEN:-}" ]           && args+=( --max-model-len "$MAX_MODEL_LEN" )

# --- per-model share of the device, not a flat fraction of the whole thing --
# vLLM's --gpu-memory-utilization claims a fraction of the ENTIRE GPU-usable
# pool for this one process, no matter how big the model actually is. Passing
# the same flat value (e.g. 0.90) for every catalogued model means whichever
# one starts first grabs that whole fraction for itself, leaving nothing for
# a second model on the same node -- this is exactly how gpt-oss-20b and
# qwen3.6-35b-a3b collided during dual-residency testing: both asked vLLM for
# 90% of the same 114 GiB pool. residencyd already refuses to keep multiple
# models resident on one node once their MEM_BUDGET_GIB values sum past
# RESIDENCY_BUDGET_GIB, so giving each model exactly its own declared share of
# the real total keeps every simultaneously-resident set within the real
# device budget too, automatically, with no per-model hand-tuning needed.
# A catalog entry that sets GPU_MEMORY_UTILIZATION explicitly (llm-model add
# --gpu-util) still wins outright -- this is only the default.
if [ -n "${GPU_MEMORY_UTILIZATION:-}" ]; then
  gpu_util="$GPU_MEMORY_UTILIZATION"
else
  node_total_gib=$(( ${RESIDENCY_BUDGET_GIB:-100} + ${RESIDENCY_MARGIN_GIB:-8} ))
  gpu_util="$(awk -v b="${MEM_BUDGET_GIB:-16}" -v t="$node_total_gib" \
    'BEGIN{ f = t > 0 ? b/t : 0.90; if (f < 0.10) f = 0.10; if (f > 0.95) f = 0.95; printf "%.2f", f }')"
  echo "vllm-serve: auto gpu-memory-utilization=$gpu_util (budget ${MEM_BUDGET_GIB:-?} GiB of node's ${node_total_gib} GiB) -- set GPU_MEMORY_UTILIZATION in $CONF to override" >&2
fi
args+=( --gpu-memory-utilization "$gpu_util" )
[ -n "${QUANTIZATION:-}" ]            && args+=( --quantization "$QUANTIZATION" )
[ -n "${TOOL_CALL_PARSER:-}" ]        && args+=( --enable-auto-tool-choice --tool-call-parser "$TOOL_CALL_PARSER" )
[ -n "${REASONING_PARSER:-}" ]        && args+=( --reasoning-parser "$REASONING_PARSER" )
[ "${ENFORCE_EAGER:-0}" = "1" ]       && args+=( --enforce-eager )
# EXTRA_ARGS is deliberately word-split: it is a free-form flag string.
# shellcheck disable=SC2206
[ -n "${EXTRA_ARGS:-}" ]              && args+=( ${EXTRA_ARGS} )

echo "vllm-serve: $NAME -> $MODEL_PATH (tp=$TENSOR_PARALLEL, pp=$PIPELINE_PARALLEL, placement=$PLACEMENT, port=$PORT)" >&2
# Log the full argument vector. A wrong --tool-call-parser / --reasoning-parser
# name (they are specific to the installed vLLM build) makes vLLM exit during
# startup, and all residencyd can report upstream is "model failed". Seeing the
# exact flags in 'journalctl -u vllm@<name>' turns that into a one-line fix.
echo "vllm-serve: args: ${args[*]}" >&2
exec /usr/local/bin/llm-run vllm "${args[@]}"
SERVE
  chmod 0755 /usr/local/bin/vllm-serve

  # Every vLLM model server runs inside llm.slice so its memory is accounted and
  # bounded as one group, independently of the OS and the desktop. residencyd's
  # live memory gate is the primary guard against over-commit; this slice is
  # defence in depth and, when systemd-oomd is enabled, the scope it kills
  # within under real pressure (so a bad load costs one model, not the box).
  _slice_high=$(( ${RESIDENCY_BUDGET_GIB:-100} + ${RESIDENCY_MARGIN_GIB:-8} ))
  cat > /etc/systemd/system/llm.slice <<SLICE
[Unit]
Description=vLLM model servers (memory-accounted, bounded as a group)
Before=slices.target

[Slice]
MemoryAccounting=yes
# Soft cap: past this the kernel reclaims/throttles THIS slice rather than the
# whole system. Deliberately not a hard MemoryMax kill, which could abort a
# model mid-generation -- residencyd refuses over-budget loads up front instead.
MemoryHigh=${_slice_high}G
# systemd-oomd opt-in: when sustained memory-pressure (PSI) on THIS slice crosses
# the limit, oomd kills its worst-offending model server rather than letting the
# whole unified-memory box freeze. The daemon, the pressure window and the zram
# relief swap are set up in section 2 (CONFIGURE_OOM_GUARD); these two keys are
# inert unless systemd-oomd is running, so they are safe to always emit.
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=${OOMD_PRESSURE_LIMIT}
SLICE

  cat > /etc/systemd/system/vllm@.service <<UNIT
[Unit]
Description=vLLM model server: %i
After=network-online.target llm-runtime.service ray-head.service ray-worker.service
Wants=network-online.target
${_rt_dep}
# Not WantedBy anything: models are never started merely because the box booted.
# residencyd decides what should be resident.
# Give up after three failures in five minutes so a genuinely broken model
# cannot restart-loop forever holding VRAM.
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
Slice=llm.slice
EnvironmentFile=${LLM_ETC}/cluster.env
EnvironmentFile=-${LLM_ETC}/cluster.local.env
EnvironmentFile=-${LLM_ETC}/models.d/%i.conf
${_svc_user}
UMask=0002

WorkingDirectory=${LLM_ROOT}
${_rt_wait}
ExecStart=/usr/local/bin/vllm-serve %i
# residencyd owns the lifecycle, but a worker that dies mid-flight would
# otherwise stay 'ready' in the catalog with nothing behind the port. One
# restart attempt costs a cold start; never restarting costs every request.
Restart=on-failure
RestartSec=10
TimeoutStartSec=${RESIDENCY_LOAD_TIMEOUT}
TimeoutStopSec=120
KillSignal=SIGINT
UNIT
  systemctl daemon-reload
  ok "vllm@.service template + /usr/local/bin/vllm-serve installed"

  # --- 6.7 model auto-profiler ----------------------------------------------
  # Derives a safe vLLM catalog entry (budget / max-model-len / distributed
  # split / hybrid batch cap / parser guess) from a downloaded model's
  # config.json, so 'llm-model pull' can onboard an arbitrary repo with no
  # hand-authored .conf. Conservative on purpose: on a shared-memory APU a
  # too-optimistic budget or an uncapped context window is what freezes the box.
  # llmprofile/llm-profile.py is the canonical source installed below.
  if [ ! -f "$LLM_PROFILE_SOURCE" ]; then
    die "llm-profile source is missing: $LLM_PROFILE_SOURCE (transfer it with the setup script)"
  fi
  install -m 0755 "$LLM_PROFILE_SOURCE" /usr/local/bin/llm-profile \
    || die "could not install llm-profile source at /usr/local/bin/llm-profile"
  ok "wrote /usr/local/bin/llm-profile (auto-derives a catalog entry from a model's config.json)"

  # --- 6.8 catalog management helper ----------------------------------------
  cat > /usr/local/bin/llm-model <<'MODELCLI'
#!/usr/bin/env bash
# Managed by setup-strixhalo-ai-server.sh
# Manage the cluster model catalog. Every model configured here appears in
# llm-gateway's /v1/models whether or not it is currently loaded.
#
#   llm-model list
#   llm-model add  --name qwen-coder --path /srv/models/Qwen3-Coder-30B \
#                  [--served-name qwen-coder] [--placement auto|server|peer|distributed] \
#                  [--tp 1] [--pp 1] [--budget-gib 40] [--max-len 32768] [--port 18001] \
#                  [--gpu-util 0.90] [--tool-parser qwen3_coder] [--reasoning-parser qwen3] \
#                  [--extra "--enable-prefix-caching"] [--enforce-eager] [--keep-warm]
#   llm-model pull hf:<repo> | ms:<repo>  [--name n] [--placement auto|...] \
#                  [--max-len 32768] [--revision main] [--no-parser] [--keep-warm]
#                  # download from Hugging Face (hf:) or ModelScope (ms:), then
#                  # auto-profile config.json and add it -- no hand-written .conf.
#   llm-model set <name> [--path p] [--served-name n] [--placement ...] [--tp n] \
#                  [--pp n] [--budget-gib n] [--max-len n] [--port n] [--gpu-util f] \
#                  [--quantization q] [--tool-parser p] [--reasoning-parser p] \
#                  [--extra "..."] [--enforce-eager|--no-enforce-eager] \
#                  [--keep-warm|--no-keep-warm] [--enable|--disable]
#                  # edit an existing catalog entry in place. Any flag you omit
#                  # keeps its current value; this runs the SAME validation and
#                  # auto-distribute self-heal 'add' does, so an edit that pushes
#                  # a model past this node's budget is upgraded to distributed
#                  # placement exactly like a hand-added model would be.
#   llm-model show <name>
#   llm-model remove <name>
#   llm-model gc  [--ensure <gib>] [--target-free-gib <n>] [--max-idle-days <n>] \
#                 [--keep <n>] [--dry-run]
#                 # reclaim disk by evicting least-recently-used PULLED models
#                 # (weights + catalog entry); re-pull on demand later.
#   llm-model parsers           # parser names the installed vLLM accepts
#   llm-model reload            # tell residencyd to re-read the catalog
#
# 'pull' is the zero-friction path: it fetches the weights (safetensors only;
# GGUF is skipped -- vLLM cannot serve it), reads the model's own config.json to
# pick a memory budget, a capped context length, a Mamba/GDN batch cap and, for
# a model too big for one node, a pipeline-parallel split across both, then hands
# all of that to 'add'. You only ever type the repo id.
# --tool-parser is what makes OpenAI-style function calling work, which every
# agentic IDE client (Cline, Copilot Chat agent mode) depends on. Without it
# vLLM never emits tool_calls and the client silently does nothing useful.
# --keep-warm exempts a model from idle eviction: use it for the model your
# editor talks to, so a coding session does not start with a cold load.
# --placement defaults to auto: residencyd picks whichever node (server or
# peer) currently has room for this model's budget at load time, evicting
# idle models there if needed, and tries the other node if the first can't
# fit even after evicting. You never have to decide server-vs-peer yourself.
# Pass --placement server or --placement peer to pin a model to one node
# always (e.g. one that must stay put for some other reason); --placement
# distributed still means "split across both nodes with Ray" for one model.
# --gpu-util is normally left unset: vllm-serve then derives it automatically
# from --budget-gib against the node's real GPU-usable memory, so two models
# on the same node each get their own share instead of both claiming the same
# fixed fraction of the whole device (which is what let a second same-node
# model collide with one already resident). Pass --gpu-util to pin an exact
# fraction yourself instead of the automatic one.
set -Eeuo pipefail
. /etc/llm/runtime.env
DIR="${LLM_ETC:-/etc/llm}/models.d"

die(){ echo "llm-model: $*" >&2; exit 1; }

# /etc/llm/models.d is a symlink into the shared model repository, so on the
# peer it only resolves once the NFS mount is up. Say that plainly instead of
# failing later with a confusing "no such file".
[ -d "$DIR" ] || die "catalog directory $DIR is unavailable (is ${LLM_ROOT:-/srv/models} mounted?)"

next_port() {
  local base="${VLLM_PORT_BASE:-18000}" p used
  used="$(cat "$DIR"/*.conf 2>/dev/null | awk -F= '$1=="PORT"{print $2}')"
  for p in $(seq $((base+1)) $((base+199))); do
    grep -qx "$p" <<<"$used" || { echo "$p"; return 0; }
  done
  die "no free port in ${base}..$((base+199))"
}

# Shared by 'add' and 'set': validate the placement/tp/pp combination (self-
# healing to 'distributed' exactly as residencyd's own _autofix_placement
# mirrors for values it discovers directly in a .conf file), fill in a
# BUDGET/PORT default when one is not already set, round BUDGET up to a whole
# GiB, auto-upgrade to distributed placement when a single node cannot fit it,
# then write (or overwrite) $DIR/$NAME.conf. Every variable this function reads
# is set by the caller beforehand -- it is not an ordinary argument list
# because 'add' and 'set' each already juggle about fifteen of these across
# their own option-parsing loops, and passing them all positionally would be
# far easier to get wrong than sharing the same names both callers already use.
write_model_conf() {
  [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--name must be alphanumeric/._-"
  case "$PLACEMENT" in auto|server|peer|distributed) ;; *) die "--placement must be auto, server, peer or distributed" ;; esac
  # Distributed means "one model split across both nodes". That needs at least
  # one axis of parallelism spanning the cluster; if the caller gave neither,
  # default to pipeline-parallel PP=2. Over the USB4 link PP beats TP: it ships
  # only stage-boundary activations, where TP all-reduces every single layer.
  if [ "$PLACEMENT" = "distributed" ] && [ "$TP" -lt 2 ] && [ "$PP" -lt 2 ]; then PP=2; fi
  # The inverse case: tp/pp >= 2 already means this model spans BOTH physical
  # nodes -- vllm-serve wires up the Ray backend for ANY tp/pp > 1 regardless
  # of PLACEMENT (this cluster has exactly one GPU per node, so there is no
  # such thing as multi-GPU parallelism confined to a single box). A
  # placement other than 'distributed' here would make residencyd's ledger
  # account for this model on only ONE node while it actually consumes
  # memory on both -- self-heal the contradiction rather than let the ledger
  # and reality disagree.
  if { [ "$TP" -ge 2 ] || [ "$PP" -ge 2 ]; } && [ "$PLACEMENT" != "distributed" ]; then
    echo "llm-model: tp=$TP/pp=$PP already spans both nodes; forcing --placement distributed (was '$PLACEMENT')" >&2
    PLACEMENT=distributed
  fi
  [ -e "$MPATH" ] || echo "llm-model: warning - '$MPATH' does not exist yet" >&2
  [ -n "$PORT" ]  || PORT="$(next_port)"
  [ -n "$SERVED" ] || SERVED="$NAME"
  if [ -z "$BUDGET" ]; then
    # Rough but useful default: the on-disk weights size plus headroom for
    # KV cache/CUDA-graph/activation memory (35%, floor 8 GiB). This budget
    # is also what vllm-serve auto-derives --gpu-util from when --gpu-util
    # is not given, so it has to cover the model's real working set, not
    # just its weights -- a too-thin default here would starve the KV cache
    # the same way a flat --gpu-util 0.90 used to starve every OTHER model
    # sharing the node. Override with --budget-gib for a model that needs
    # more (or less) headroom than this estimate.
    if [ -e "$MPATH" ]; then
      BUDGET="$(du -sBG --apparent-size "$MPATH" 2>/dev/null | awk '
        {gsub("G","",$1); w=$1; extra=w*0.35; if (extra<8) extra=8; printf "%d", w+extra}')"
    fi
    [ -n "$BUDGET" ] || BUDGET=16
  fi
  # Round up to the next whole GiB. --budget-gib accepts anything a caller
  # (an operator over SSH, or the dashboard's Add/Edit forms) types, and
  # fractional GiB is precision residencyd never needed -- it only clutters
  # .conf files and the dashboard with values like 25.303897857666016 instead
  # of 26.
  BUDGET="$(awk -v b="$BUDGET" 'BEGIN{printf "%d", (b==int(b)?b:int(b)+1)}')"
  # If this model needs more memory than a single node provides, it must be
  # split across both -- an 'auto' (or explicitly pinned 'server'/'peer')
  # placement can NEVER admit a model bigger than one node's budget;
  # residencyd would just refuse every load attempt forever (409
  # model_capacity_unavailable) instead of the model ever coming up. Applies
  # the SAME halving shape llm-profile uses for 'llm-model pull' (half the
  # budget, plus 30% of that half or 6 GiB, whichever is larger, per node),
  # applied to the budget already established here (declared via
  # --budget-gib, or derived above from the weights on disk) rather than raw
  # weights -- so a hand-added model is sized identically to a pulled one
  # without needing config.json (which a hand-added model may not have).
  NODE_BUDGET_GIB="${RESIDENCY_BUDGET_GIB:-100}"
  if [ "$PLACEMENT" != "distributed" ] \
     && awk -v a="$BUDGET" -v b="$NODE_BUDGET_GIB" 'BEGIN{exit !(a>b)}'; then
    if [ "$PLACEMENT" != "auto" ]; then
      die "'$NAME' needs ~${BUDGET} GiB but --placement $PLACEMENT pins it to a single node (this node's budget is ${NODE_BUDGET_GIB} GiB, which it can never fit in); use --placement distributed instead (or --placement auto to have this computed automatically)"
    fi
    NEWBUDGET="$(awk -v b="$BUDGET" \
      'BEGIN{h=b/2; m=h*0.30; if(m<6) m=6; v=h+m; printf "%d", (v==int(v)?v:int(v)+1)}')"
    echo "llm-model: ${NAME}'s ${BUDGET} GiB budget exceeds this node's ${NODE_BUDGET_GIB} GiB -- auto-upgrading to distributed placement (pp=2, ~${NEWBUDGET} GiB/node)" >&2
    if [ "$NEWBUDGET" -gt "$NODE_BUDGET_GIB" ]; then
      echo "llm-model: WARNING even a 2-way split needs ~${NEWBUDGET} GiB/node but this node only has ${NODE_BUDGET_GIB} GiB" >&2
    fi
    PLACEMENT=distributed; PP=2; BUDGET="$NEWBUDGET"
  fi
  umask 022
  cat > "$DIR/$NAME.conf" <<EOF
# Model '$NAME' - read by vllm@$NAME.service and by residencyd.
MODEL_PATH="$MPATH"
SERVED_NAME="$SERVED"
PORT=$PORT
# auto | server | peer | distributed (auto = residencyd picks whichever node
# has room at load time; distributed = split across both nodes with Ray)
PLACEMENT=$PLACEMENT
TENSOR_PARALLEL=$TP
# Pipeline-parallel stages across the two nodes. Distributed placement over the
# USB4 link prefers PP=2 to TP=2: PP ships only stage-boundary activations,
# where TP all-reduces every layer -- brutal on a ~13 Gbit/s link.
PIPELINE_PARALLEL=$PP
# GiB residencyd reserves for this model when deciding what fits. vllm-serve
# also auto-derives --gpu-util from this against the node's real GPU-usable
# memory when GPU_MEMORY_UTILIZATION below is left blank.
MEM_BUDGET_GIB=$BUDGET
MAX_MODEL_LEN=$MAXLEN
# Leave blank for vllm-serve to auto-compute this model's own share of the
# node's GPU memory from MEM_BUDGET_GIB above. Set explicitly to pin an exact
# fraction instead (0.0-1.0) -- e.g. for a model you know always runs alone.
GPU_MEMORY_UTILIZATION=$GPUUTIL
QUANTIZATION=$QUANT
TOOL_CALL_PARSER=$TOOLP
REASONING_PARSER=$REASONP
ENFORCE_EAGER=$EAGER
# 1 = exempt from idle eviction. Still evictable under memory pressure, but
# only after every other resident model on the node has been considered.
KEEP_WARM=$KEEPWARM
EXTRA_ARGS="$EXTRA"
ENABLED=$ENABLEDVAL
EOF
}

cmd="${1:-list}"; shift || true
case "$cmd" in
  list)
    printf '%-24s %-12s %-4s %-8s %-6s %s\n' NAME PLACEMENT TP BUDGET PORT PATH
    for f in "$DIR"/*.conf; do
      [ -e "$f" ] || { echo "(catalog is empty - add one with 'llm-model add --help')"; break; }
      ( . "$f"; printf '%-24s %-12s %-4s %-8s %-6s %s\n' \
        "$(basename "$f" .conf)$([ "${KEEP_WARM:-0}" = 1 ] && echo '*')" \
        "${PLACEMENT:-auto}" "${TENSOR_PARALLEL:-1}" \
        "${MEM_BUDGET_GIB:-?}" "${PORT:-?}" "${MODEL_PATH:-?}" )
    done
    echo "(* = keep-warm: exempt from idle eviction)"
    ;;
  show)
    n="${1:?llm-model show <name>}"; [ -r "$DIR/$n.conf" ] || die "no such model: $n"
    cat "$DIR/$n.conf" ;;
  remove)
    n="${1:?llm-model remove <name>}"; [ -e "$DIR/$n.conf" ] || die "no such model: $n"
    systemctl stop "vllm@$n.service" 2>/dev/null || true
    rm -f "$DIR/$n.conf"
    echo "removed $n"
    systemctl reload residencyd.service 2>/dev/null || true ;;
  reload)
    systemctl reload residencyd.service 2>/dev/null \
      && echo "residencyd reloaded" \
      || echo "residencyd is not running here (that is normal on the peer node)" ;;
  gc)
    # On-disk LRU for pulled models. Downloads under $LLM_ROOT/pulled accumulate
    # until the shared volume is full and the next pull fails; gc reclaims the
    # least-recently-used ones (weights + catalog entry) so any of them can be
    # re-fetched on demand later. Only pulled/ is ever touched -- hand-curated
    # catalog models and the HF cache are off-limits. keep-warm, currently-active
    # and just-used models are never evicted.
    ENSURE=""; TARGET=""; MAXIDLE=""; KEEP=0; DRY=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --ensure) ENSURE="$2"; shift ;;
        --target-free-gib) TARGET="$2"; shift ;;
        --max-idle-days) MAXIDLE="$2"; shift ;;
        --keep) KEEP="$2"; shift ;;
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown gc option '$1'" ;;
      esac
      shift
    done
    ROOT="${LLM_ROOT:-/srv/models}"
    PULLED="$ROOT/pulled"
    if [ ! -d "$PULLED" ]; then echo "no pulled models yet (nothing to gc)"; exit 0; fi
    [ -w "$ROOT" ] || die "gc must run on the head node: $ROOT is read-only here"
    need_free="${ENSURE:-${TARGET:-${LLM_GC_MIN_FREE_GIB:-150}}}"
    grace="${LLM_GC_ACTIVE_GRACE:-600}"
    now="$(date +%s)"
    free_gib() { df -PB1 "$ROOT" 2>/dev/null | awk 'NR==2{printf "%d", $4/1073741824}'; }

    # Rank pulled dirs oldest-first by their .last_used stamp (residencyd bumps
    # it on every use), falling back to the directory's own mtime when a model
    # has never been served since the marker was introduced.
    ranked="$(
      for d in "$PULLED"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        if [ -f "$d/.last_used" ]; then m="$(stat -c %Y "$d/.last_used" 2>/dev/null)"
        else m="$(stat -c %Y "$d" 2>/dev/null)"; fi
        printf '%s\t%s\n' "${m:-0}" "$name"
      done | sort -n
    )"
    [ -n "$ranked" ] || { echo "no pulled models to consider"; exit 0; }

    total="$(printf '%s\n' "$ranked" | grep -c . || true)"
    protect_from=$((total - KEEP))   # indices >= this are the KEEP newest

    evicted=0; reclaimed_gib=0; idx=0
    while IFS=$'\t' read -r mtime name; do
      idx=$((idx+1))
      dir="$PULLED/$name"; conf="$DIR/$name.conf"
      cur_free="$(free_gib)"
      age=$((now - mtime))
      too_old=0
      if [ -n "$MAXIDLE" ] && [ "$age" -gt $((MAXIDLE * 86400)) ]; then too_old=1; fi
      # Space is satisfied and this (hence every newer) model is within the age
      # limit: nothing left to reclaim.
      if [ "$cur_free" -ge "$need_free" ] && [ "$too_old" = 0 ]; then break; fi

      # Never evict the KEEP most-recently-used, keep-warm, actively-serving, or
      # just-used models -- skip and try the next-oldest instead.
      if [ "$KEEP" -gt 0 ] && [ "$idx" -gt "$protect_from" ]; then continue; fi
      if [ -f "$conf" ] && [ "$(. "$conf"; echo "${KEEP_WARM:-0}")" = 1 ]; then continue; fi
      if systemctl is-active --quiet "vllm@$name.service" 2>/dev/null; then continue; fi
      if [ "$age" -lt "$grace" ]; then continue; fi
      # A same-named catalog entry that points somewhere other than this pulled
      # dir is not ours to remove; leave the whole model alone.
      if [ -f "$conf" ]; then
        mp="$(. "$conf"; echo "${MODEL_PATH:-}")"
        case "$mp" in "$dir"|"$dir"/*) ;; *) continue ;; esac
      fi

      size_gib="$(du -sB1 "$dir" 2>/dev/null | awk '{printf "%d", $1/1073741824}')"
      if [ "$DRY" = 1 ]; then
        printf 'would evict %-28s (~%sGiB, idle %sd)\n' "$name" "${size_gib:-0}" "$((age/86400))"
      else
        systemctl stop "vllm@$name.service" 2>/dev/null || true
        rm -f "$conf"
        rm -rf "$dir"
        printf 'evicted %-28s (~%sGiB, idle %sd)\n' "$name" "${size_gib:-0}" "$((age/86400))"
      fi
      evicted=$((evicted+1))
      reclaimed_gib=$((reclaimed_gib + ${size_gib:-0}))
    done < <(printf '%s\n' "$ranked")

    if [ "$DRY" != 1 ] && [ "$evicted" -gt 0 ]; then
      systemctl reload residencyd.service 2>/dev/null || true
    fi
    if [ "$evicted" = 0 ]; then
      echo "gc: nothing to evict; free ${free_before:-$(free_gib)}GiB, floor ${need_free}GiB"
    elif [ "$DRY" = 1 ]; then
      echo "gc: --dry-run, would reclaim ~${reclaimed_gib}GiB across ${evicted} model(s)"
    else
      echo "gc: reclaimed ~${reclaimed_gib}GiB across ${evicted} model(s); free now $(free_gib)GiB (floor ${need_free}GiB)"
    fi ;;
  pull)
    # Zero-friction onboarding: fetch a repo, read its config.json, and let
    # llm-profile choose a budget / context cap / distributed split / parser,
    # then hand all of that to 'add'. The user only types the repo id.
    REF="${1:-}"
    [ -n "$REF" ] || die "pull needs a repo, e.g. 'llm-model pull hf:Qwen/Qwen3-8B'"
    shift || true
    SRC=hf; repo="$REF"
    case "$REF" in
      hf:*)            SRC=hf; repo="${REF#hf:}" ;;
      ms:*|modelscope:*) SRC=ms; repo="${REF#*:}" ;;
      http*://*)       die "pull takes a repo id like owner/name, not a URL" ;;
    esac
    [ -n "$repo" ] || die "empty repo id in '$REF'"
    NAME=""; PLACEMENT_OVERRIDE=""; MAXLEN=""; REV=""; NOPARSER=0; KEEPWARM=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) NAME="$2"; shift ;;
        --placement) PLACEMENT_OVERRIDE="$2"; shift ;;
        --max-len) MAXLEN="$2"; shift ;;
        --revision) REV="$2"; shift ;;
        --no-parser) NOPARSER=1 ;;
        --keep-warm) KEEPWARM=1 ;;
        -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown pull option '$1'" ;;
      esac
      shift
    done
    [ -z "$NAME" ] && NAME="$(basename "$repo")" || true
    NAME="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '-')"
    [[ "$NAME" =~ ^[A-Za-z0-9] ]] || die "could not derive a valid name from '$repo'; pass --name"
    # Downloading and writing the catalog both touch the shared volume, which is
    # only read-write on the head node; say so plainly instead of failing deep in
    # the download with a permission error.
    ROOT="${LLM_ROOT:-/srv/models}"
    [ -w "$ROOT" ] || die "pull must run on the head node: $ROOT is read-only here (the peer mounts it ro)"
    [ -n "${HF_TOOLS_VENV:-}" ] && [ -d "$HF_TOOLS_VENV" ] || die "the model-hub tools venv is missing (rerun setup); cannot download"
    DEST="$ROOT/pulled/$NAME"
    HFHOME="$ROOT/hub"

    # Reclaim space from stale pulled models before fetching, so an
    # accumulation of old downloads cannot make this pull fail on a full volume.
    # Best-effort and LRU-safe: it never touches keep-warm, active or recent
    # models. Skipped if the operator disabled gc at setup time.
    if [ "${CONFIGURE_MODEL_GC:-1}" = 1 ]; then
      "$0" gc --target-free-gib "${LLM_GC_MIN_FREE_GIB:-150}" || true
    fi
    mkdir -p "$DEST" "$HFHOME"

    if [ "$SRC" = hf ]; then
      HFBIN=""
      for _c in hf huggingface-cli; do
        [ -x "$HF_TOOLS_VENV/bin/$_c" ] && { HFBIN="$HF_TOOLS_VENV/bin/$_c"; break; } || true
      done
      [ -n "$HFBIN" ] || die "no hf/huggingface-cli in $HF_TOOLS_VENV (rerun setup)"
      # Skip formats vLLM cannot load (GGUF/pth/onnx) and the duplicate
      # original/ tree some repos ship, so we don't waste the link on them.
      # The current 'hf' CLI's --exclude only takes ONE glob per occurrence;
      # a single '--exclude a b c' only binds 'a' to --exclude and silently
      # treats 'b'/'c' as positional filenames (of all things, as *allow*
      # patterns to snapshot_download) instead of exclude patterns -- the
      # inverse of what was intended, and exactly why a real pull once fetched
      # only 74 bytes and never got a config.json. Repeat the flag instead.
      hfargs=(download "$repo" --local-dir "$DEST"
              --exclude "*.gguf" --exclude "*.pth" --exclude "*.onnx" --exclude "original/*")
      [ -n "$REV" ] && hfargs+=(--revision "$REV") || true
      echo "Downloading $repo from Hugging Face into $DEST ..."
      # hf_transfer is much faster but flaky on some networks; fall back to the
      # plain downloader rather than failing the whole pull.
      if ! HF_HOME="$HFHOME" HF_HUB_ENABLE_HF_TRANSFER=1 "$HFBIN" "${hfargs[@]}"; then
        echo "llm-model: fast download failed; retrying without hf_transfer..." >&2
        HF_HOME="$HFHOME" HF_HUB_ENABLE_HF_TRANSFER=0 "$HFBIN" "${hfargs[@]}"
      fi
    else
      MSBIN=""
      for _c in modelscope ms; do
        [ -x "$HF_TOOLS_VENV/bin/$_c" ] && { MSBIN="$HF_TOOLS_VENV/bin/$_c"; break; } || true
      done
      [ -n "$MSBIN" ] || die "ModelScope CLI missing in $HF_TOOLS_VENV (rerun setup)"
      msargs=(download --model "$repo" --local_dir "$DEST")
      [ -n "$REV" ] && msargs+=(--revision "$REV") || true
      echo "Downloading $repo from ModelScope into $DEST ..."
      "$MSBIN" "${msargs[@]}"
      # ModelScope has no server-side exclude, so prune the unservable formats
      # after the fact.
      find "$DEST" -type f \( -iname '*.gguf' -o -iname '*.pth' -o -iname '*.onnx' \) -delete 2>/dev/null || true
    fi

    echo "Profiling $DEST ..."
    prof="$(/usr/local/bin/llm-profile "$DEST" --name "$NAME" \
              --node-budget-gib "${RESIDENCY_BUDGET_GIB:-100}" \
              --max-len-cap "${MAXLEN:-${LLM_MAX_LEN_CAP:-32768}}" \
              --hybrid-max-seqs "${LLM_HYBRID_MAX_SEQS:-64}")"
    eval "$prof"

    PLACE="${PLACEMENT_OVERRIDE:-$P_PLACEMENT}"
    case "$PLACE" in auto|server|peer|distributed) ;; *) die "--placement must be auto, server, peer or distributed" ;; esac

    # A parser name is only valid for the specific vLLM build installed here;
    # the profiler only GUESSES from the model family, so validate each guess
    # against what this build actually accepts and silently drop a bad one --
    # an invalid --tool-call-parser makes vLLM exit at startup.
    TOOLP=""; REASONP=""
    if [ "$NOPARSER" != 1 ] && { [ -n "$P_TOOL_PARSER" ] || [ -n "$P_REASONING_PARSER" ]; }; then
      _help="$(llm-run vllm serve --help 2>/dev/null || true)"
      if [ -n "$_help" ]; then
        _accepts() {
          printf '%s\n' "$_help" | grep -A6 -e "--$1" \
            | tr ',' '\n' | tr -d '{}' \
            | grep -oE '[A-Za-z][A-Za-z0-9_]{2,}' \
            | grep -vxE 'possible|choices|default|None|str|Name|of|the|parser' | sort -u
        }
        if [ -n "$P_TOOL_PARSER" ]; then
          if _accepts tool-call-parser | grep -qx "$P_TOOL_PARSER"; then TOOLP="$P_TOOL_PARSER"
          else echo "llm-model: guessed tool parser '$P_TOOL_PARSER' not accepted by this vLLM; leaving it unset" >&2; fi
        fi
        if [ -n "$P_REASONING_PARSER" ]; then
          if _accepts reasoning-parser | grep -qx "$P_REASONING_PARSER"; then REASONP="$P_REASONING_PARSER"
          else echo "llm-model: guessed reasoning parser '$P_REASONING_PARSER' not accepted by this vLLM; leaving it unset" >&2; fi
        fi
      else
        echo "llm-model: could not query vLLM for parser names; leaving parsers unset (set later with 'llm-model add')" >&2
      fi
    fi

    echo
    echo "Profile for $NAME: weights ~${P_WEIGHTS_GIB}GiB  budget ${P_BUDGET_GIB}GiB  placement ${PLACE} (tp=$P_TP pp=$P_PP)  max-len ${P_MAX_MODEL_LEN:-model-default}"
    if [ -n "$P_NOTES" ]; then echo "  notes: $P_NOTES"; fi

    add=(add --name "$NAME" --path "$DEST" --placement "$PLACE" --tp "$P_TP" --pp "$P_PP" --budget-gib "$P_BUDGET_GIB")
    if [ -n "$P_MAX_MODEL_LEN" ]; then add+=(--max-len "$P_MAX_MODEL_LEN"); fi
    if [ -n "$P_EXTRA_ARGS" ];    then add+=(--extra "$P_EXTRA_ARGS"); fi
    if [ -n "$TOOLP" ];           then add+=(--tool-parser "$TOOLP"); fi
    if [ -n "$REASONP" ];         then add+=(--reasoning-parser "$REASONP"); fi
    if [ "$KEEPWARM" = 1 ];       then add+=(--keep-warm); fi
    exec "$0" "${add[@]}" ;;
  add)
    NAME=""; MPATH=""; SERVED=""; PLACEMENT="auto"; TP=1; BUDGET=""; MAXLEN=""
    PORT=""; GPUUTIL=""; TOOLP=""; REASONP=""; EXTRA=""; EAGER=0; QUANT=""
    KEEPWARM=0; PP=1
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) NAME="$2"; shift ;;
        --path) MPATH="$2"; shift ;;
        --served-name) SERVED="$2"; shift ;;
        --placement) PLACEMENT="$2"; shift ;;
        --tp) TP="$2"; shift ;;
        --pp) PP="$2"; shift ;;
        --budget-gib) BUDGET="$2"; shift ;;
        --max-len) MAXLEN="$2"; shift ;;
        --port) PORT="$2"; shift ;;
        --gpu-util) GPUUTIL="$2"; shift ;;
        --quantization) QUANT="$2"; shift ;;
        --tool-parser) TOOLP="$2"; shift ;;
        --reasoning-parser) REASONP="$2"; shift ;;
        --extra) EXTRA="$2"; shift ;;
        --enforce-eager) EAGER=1 ;;
        --keep-warm) KEEPWARM=1 ;;
        -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option '$1'" ;;
      esac
      shift
    done
    [ -n "$NAME" ]  || die "--name is required"
    [ -n "$MPATH" ] || die "--path is required"
    [ -e "$DIR/$NAME.conf" ] && die "a model named '$NAME' already exists (use 'llm-model set $NAME ...' to edit it)"
    ENABLEDVAL=1
    write_model_conf
    echo "added $NAME (placement=$PLACEMENT tp=$TP$([ "$PP" -gt 1 ] && echo " pp=$PP") port=$PORT budget=${BUDGET}GiB${TOOLP:+ tools=$TOOLP}$([ "$KEEPWARM" = 1 ] && echo ' keep-warm'))"
    echo "The catalog lives on the shared NFS volume, so the other node sees this immediately."
    if [ -n "$TOOLP" ] || [ -n "$REASONP" ]; then
      echo "Parser names are specific to the installed vLLM build. If this model"
      echo "fails to start, check 'llm-model parsers' and 'journalctl -u vllm@$NAME'."
    fi
    systemctl reload residencyd.service 2>/dev/null || true ;;
  set)
    # Edit an existing catalog entry in place -- the dashboard's per-model
    # Save button, and the same thing 'llm-model pull' uses internally to
    # apply any dashboard-supplied overrides (tp/pp/budget/port/etc.) on top
    # of the profiler's own guess after a download finishes. Every current
    # field becomes this edit's default; only the flags you actually pass
    # change anything.
    NAME="${1:?llm-model set <name> [--flags]}"; shift || true
    [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--name must be alphanumeric/._-"
    CONF="$DIR/$NAME.conf"
    [ -e "$CONF" ] || die "no such model: $NAME (use 'llm-model add' to create it)"
    MODEL_PATH=""; SERVED_NAME=""; PORT=""; PLACEMENT="auto"; TENSOR_PARALLEL=1
    PIPELINE_PARALLEL=1; MEM_BUDGET_GIB=""; MAX_MODEL_LEN=""; GPU_MEMORY_UTILIZATION=""
    QUANTIZATION=""; TOOL_CALL_PARSER=""; REASONING_PARSER=""; ENFORCE_EAGER=0
    KEEP_WARM=0; EXTRA_ARGS=""; ENABLED=1
    . "$CONF"
    MPATH="$MODEL_PATH"; SERVED="$SERVED_NAME"; TP="$TENSOR_PARALLEL"; PP="$PIPELINE_PARALLEL"
    BUDGET="$MEM_BUDGET_GIB"; MAXLEN="$MAX_MODEL_LEN"; GPUUTIL="$GPU_MEMORY_UTILIZATION"
    QUANT="$QUANTIZATION"; TOOLP="$TOOL_CALL_PARSER"; REASONP="$REASONING_PARSER"
    EAGER="$ENFORCE_EAGER"; KEEPWARM="$KEEP_WARM"; EXTRA="$EXTRA_ARGS"; ENABLEDVAL="$ENABLED"
    while [ $# -gt 0 ]; do
      case "$1" in
        --path) MPATH="$2"; shift ;;
        --served-name) SERVED="$2"; shift ;;
        --placement) PLACEMENT="$2"; shift ;;
        --tp) TP="$2"; shift ;;
        --pp) PP="$2"; shift ;;
        --budget-gib) BUDGET="$2"; shift ;;
        --max-len) MAXLEN="$2"; shift ;;
        --port) PORT="$2"; shift ;;
        --gpu-util) GPUUTIL="$2"; shift ;;
        --quantization) QUANT="$2"; shift ;;
        --tool-parser) TOOLP="$2"; shift ;;
        --reasoning-parser) REASONP="$2"; shift ;;
        --extra) EXTRA="$2"; shift ;;
        --enforce-eager) EAGER=1 ;;
        --no-enforce-eager) EAGER=0 ;;
        --keep-warm) KEEPWARM=1 ;;
        --no-keep-warm) KEEPWARM=0 ;;
        --enable) ENABLEDVAL=1 ;;
        --disable) ENABLEDVAL=0 ;;
        -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option '$1'" ;;
      esac
      shift
    done
    write_model_conf
    echo "updated $NAME (placement=$PLACEMENT tp=$TP$([ "$PP" -gt 1 ] && echo " pp=$PP") port=$PORT budget=${BUDGET}GiB${TOOLP:+ tools=$TOOLP}$([ "$KEEPWARM" = 1 ] && echo ' keep-warm')$([ "$ENABLEDVAL" = 0 ] && echo ' DISABLED'))"
    systemctl reload residencyd.service 2>/dev/null || true ;;
  parsers)
    # An invalid --tool-call-parser makes vLLM exit during startup, which
    # residencyd can only report as a failed model. The valid names are a
    # property of the installed build, not of any documentation, so ask it.
    echo "Querying the installed vLLM for the parser names it accepts..."
    echo "(this starts the runtime briefly; it can take a few seconds)"
    echo
    _help="$(llm-run vllm serve --help 2>/dev/null || true)"
    if [ -z "$_help" ]; then
      die "could not run 'llm-run vllm serve --help' (is llm-runtime.service up?)"
    fi
    for _opt in tool-call-parser reasoning-parser; do
      echo "--$_opt:"
      printf '%s\n' "$_help" \
        | grep -A6 -e "--$_opt" \
        | tr ',' '\n' | tr -d '{}' \
        | grep -oE '[A-Za-z][A-Za-z0-9_]{2,}' \
        | grep -vxE 'possible|choices|default|None|str|Name|of|the|parser' \
        | sort -u | sed 's/^/  /'
      echo
    done
    echo "Set one with: llm-model add ... --tool-parser <name> --reasoning-parser <name>" ;;
  -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  *) die "unknown command '$cmd' (try --help)" ;;
esac
MODELCLI
  chmod 0755 /usr/local/bin/llm-model
  ok "wrote /usr/local/bin/llm-model (add/list/remove models in the cluster catalog)"
  echo
fi

# =============================================================================
# 7. RESIDENCY CONTROL PLANE
# =============================================================================
# residencyd (server node, root, reachable ONLY through a unix socket) decides
# which models are loaded, admits requests against a memory budget, protects
# models that are actively serving, and evicts idle ones least-recently-used
# first. The peer runs a small companion agent so the head node can start and
# stop peer-resident models over the USB4 link without root SSH between boxes.
if [ "$INSTALL_RESIDENCY" = "1" ]; then
  log "Installing the residency control plane ($([ "$IS_SERVER" = 1 ] && echo residencyd || echo residency-agent))"
  install -d -m 0755 "$RESIDENCY_LIB" \
    || die "could not create residency library directory: $RESIDENCY_LIB"

  # ---------------------------------------------------------------- residency sources
  for _src in residencyd.py residency-agent.py; do
    if [ ! -f "$RESIDENCY_SOURCE_DIR/$_src" ]; then
      die "residency source is missing: $RESIDENCY_SOURCE_DIR/$_src (transfer it with the setup script)"
    fi
  done
  install -m 0755 "$RESIDENCY_SOURCE_DIR/residencyd.py" "$RESIDENCY_LIB/residencyd.py" \
    || die "could not install residencyd source at $RESIDENCY_LIB/residencyd.py"
  install -m 0755 "$RESIDENCY_SOURCE_DIR/residency-agent.py" "$RESIDENCY_LIB/residency-agent.py" \
    || die "could not install residency-agent source at $RESIDENCY_LIB/residency-agent.py"
  # ------------------------------------------------------------------- units
  if [ "$IS_SERVER" = "1" ]; then
    rm -f /etc/systemd/system/residency-agent.service
    # The socket directory is created by tmpfiles, NOT by RuntimeDirectory=.
    # RuntimeDirectory deletes and recreates the directory on every restart,
    # which (a) makes the gateway's ReadWritePaths= reference a path that may
    # not exist yet, and (b) leaves the gateway's bind mount pinned to the old,
    # unlinked inode after a residencyd restart - so it would never see the new
    # socket. A tmpfiles-owned directory has a stable lifetime and inode.
    cat > /etc/tmpfiles.d/residencyd.conf <<TMPFILES
# Managed by setup-strixhalo-ai-server.sh
d /run/residencyd 0755 root root -
TMPFILES
    systemd-tmpfiles --create /etc/tmpfiles.d/residencyd.conf >/dev/null 2>&1 \
      || install -d -m 0755 /run/residencyd

    cat > /etc/systemd/system/residencyd.service <<UNIT
[Unit]
Description=residencyd - LLM model residency manager
# Ray is only needed by models with tensor_parallel > 1. Single-node models are
# served by a plain vllm process, so the control plane must NOT be coupled to
# Ray: a peer that is switched off must never take the head node's API down.
After=network-online.target ray-head.service
Wants=network-online.target

[Service]
Type=simple
# Root, but reachable ONLY through the unix socket below - never the LAN.
User=root
Group=root
RuntimeDirectory=residencyd
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
# Persistent state (learned per-model footprints) survives reboots here.
StateDirectory=residencyd
StateDirectoryMode=0700
EnvironmentFile=${LLM_ETC}/cluster.env
EnvironmentFile=-${LLM_ETC}/cluster.local.env
ExecStart=/usr/bin/python3 ${RESIDENCY_LIB}/residencyd.py
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable residencyd.service >/dev/null 2>&1 || true
    ok "residencyd.service installed (unix socket $RESIDENCY_SOCK, group $GATEWAY_USER)"

    # --- pulled-model disk GC (server only) -----------------------------------
    # A daily LRU sweep of $LLM_ROOT/pulled so downloaded weights cannot silently
    # fill the shared volume. This reclaims DISK, not RAM: residencyd already
    # evicts idle models from unified memory. The two are independent.
    if [ "${CONFIGURE_MODEL_GC:-1}" = "1" ]; then
      cat > /etc/systemd/system/llm-model-gc.service <<UNIT
[Unit]
Description=Reclaim disk from least-recently-used pulled LLM models
ConditionPathExists=${LLM_ROOT}/pulled

[Service]
Type=oneshot
EnvironmentFile=${LLM_ETC}/runtime.env
# --max-idle-days is substituted by systemd from the EnvironmentFile above at
# run time, so editing runtime.env changes the policy without a re-install.
ExecStart=/usr/local/bin/llm-model gc --max-idle-days \${LLM_GC_MAX_IDLE_DAYS}
UNIT
      cat > /etc/systemd/system/llm-model-gc.timer <<UNIT
[Unit]
Description=Daily LRU cleanup of pulled LLM models

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
UNIT
      systemctl daemon-reload
      systemctl enable llm-model-gc.timer >/dev/null 2>&1 || true
      ok "llm-model-gc.timer installed (daily LRU cleanup of $LLM_ROOT/pulled)"
    else
      systemctl disable llm-model-gc.timer >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/llm-model-gc.timer /etc/systemd/system/llm-model-gc.service
      warn "pulled-model gc disabled (--no-model-gc): reclaim disk yourself with 'llm-model remove'"
    fi
  else
    rm -f /etc/systemd/system/residencyd.service
    # Disk GC runs on the head node only (it owns $LLM_ROOT/pulled); a peer must
    # never sweep the shared volume out from under the head.
    systemctl disable llm-model-gc.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/llm-model-gc.timer /etc/systemd/system/llm-model-gc.service
    # Same reasoning as the Ray units: the agent binds an address that only
    # exists while the cable is up, so it follows the interface rather than the
    # boot target. Without a cluster there is no agent worth starting at all.
    if [ "${CONFIGURE_CLUSTER:-1}" = "1" ]; then
      _dev_unit="sys-subsystem-net-devices-${CLUSTER_IFACE}.device"
      _dev_dep="BindsTo=${_dev_unit}
After=${_dev_unit}"
    else
      _dev_unit="multi-user.target"
      _dev_dep="# no USB4 interface on this node"
    fi
    cat > /etc/systemd/system/residency-agent.service <<UNIT
[Unit]
Description=residency-agent - peer-side model lifecycle helper
After=network-online.target ray-worker.service
Wants=network-online.target
${_dev_dep}


[Service]
Type=simple
User=root
Group=root
EnvironmentFile=${LLM_ETC}/cluster.env
EnvironmentFile=-${LLM_ETC}/cluster.local.env
# Bind waits for the USB4 address to exist; without this the service crash-loops
# through a cold boot until the cable finishes negotiating.
ExecStartPre=/usr/local/bin/usb4-cluster-wait ${CLUSTER_LOCAL_IP} 120
ExecStart=/usr/bin/python3 ${RESIDENCY_LIB}/residency-agent.py
Restart=always
RestartSec=10

[Install]
WantedBy=${_dev_unit}
UNIT
    systemctl daemon-reload
    systemctl disable residency-agent.service >/dev/null 2>&1 || true
    systemctl enable residency-agent.service >/dev/null 2>&1 || true
    ok "residency-agent.service installed (listens on ${CLUSTER_LOCAL_IP}:${AGENT_PORT} only)"
  fi
  echo
fi

# =============================================================================
# 8. llm-gateway  (server only)  -- the single OpenAI-compatible front door
# =============================================================================
# Everything that talks to the cluster -- Open WebUI, Continue/Cline, curl, your
# own code -- points at exactly one URL: http://<server>:8000/v1. The gateway
# does three things and nothing else:
#   1. advertises the WHOLE catalog in /v1/models, loaded or not, so a client
#      can pick a model that is currently cold;
#   2. asks residencyd for a lease on the requested model, which is what
#      triggers the load, the eviction, or the 409 refusal;
#   3. streams the request through to whichever vLLM instance ended up holding
#      it -- on this box over loopback, or on the peer over the USB4 cable.
# It deliberately holds no model state of its own. residencyd is the only thing
# that decides what is resident, and the gateway runs unprivileged as
# $GATEWAY_USER with no systemd rights at all: its only channel to residencyd is
# the root-owned unix socket, group-readable by $GATEWAY_USER.
if [ "$INSTALL_GATEWAY" = "1" ] && [ "$IS_SERVER" = "1" ]; then
  log "Installing llm-gateway (OpenAI-compatible front door on port $GATEWAY_PORT)"
  export DEBIAN_FRONTEND=noninteractive

  gateway_ready=0
  if [ ! -x "$UV_SYS" ]; then
    warn "uv is not installed, so the gateway virtualenv cannot be built (re-run without --skip base)."
  else
    # Gate on uv_root_venv's own result, NOT on '[ -x $GATEWAY_VENV/bin/python ]'.
    # root can traverse /root, so that test passes for a stale venv whose
    # interpreter no service account can reach - which is how a broken gateway
    # survived several re-runs of this script.
    if uv_root_venv "$GATEWAY_PY" "$GATEWAY_VENV"; then
      if "$UV_SYS" pip install --python "$GATEWAY_VENV/bin/python" \
           fastapi "uvicorn[standard]" httpx gradio >/dev/null 2>&1; then
        gateway_ready=1
        ok "gateway dependencies installed (fastapi + uvicorn + httpx + gradio)"
      else
        warn "could not install the gateway's Python dependencies"
      fi
      # The gateway runs as $GATEWAY_USER, so root being able to run this
      # interpreter proves nothing. Check the account that will actually use it.
      if ! venv_execs_as "$GATEWAY_USER" "$GATEWAY_VENV"; then
        gateway_ready=0
        warn "$GATEWAY_VENV/bin/python is not executable by '$GATEWAY_USER'"
        warn "  the unit would fail at exec with status=203/EXEC"
        note_action "llm-gateway's interpreter is unreachable for '$GATEWAY_USER'. Fix with: sudo chmod -R a+rX $UV_PYTHON_DIR $GATEWAY_VENV && sudo systemctl restart llm-gateway"
      fi
    else
      warn "could not build a usable gateway virtualenv at $GATEWAY_VENV"
      note_action "llm-gateway has no working virtualenv. Rebuild it: sudo rm -rf $GATEWAY_VENV && sudo $0 --skip base --skip rocm"
    fi
  fi

  install -d -m 0755 "$GATEWAY_VENV"
  if [ ! -f "$DASHBOARD_SOURCE" ]; then
    die "dashboard source is missing: $DASHBOARD_SOURCE (transfer it with the setup script)"
  fi
  install -m 0644 "$DASHBOARD_SOURCE" "$GATEWAY_VENV/dashboard.py" \
    || die "could not install dashboard source at $GATEWAY_VENV/dashboard.py"
  if [ ! -f "$GATEWAY_SOURCE" ]; then
    die "gateway source is missing: $GATEWAY_SOURCE (transfer it with the setup script)"
  fi
  install -m 0644 "$GATEWAY_SOURCE" "$GATEWAY_VENV/app.py" \
    || die "could not install gateway source at $GATEWAY_VENV/app.py"

  cat > /etc/systemd/system/llm-gateway.service <<UNIT
[Unit]
Description=LLM gateway (OpenAI-compatible front door)
Documentation=https://platform.openai.com/docs/api-reference
# Without residencyd the gateway can answer /health and nothing else, so it
# starts after it -- but deliberately NOT Requires=, so restarting the control
# plane does not take the front door down with it.
After=network-online.target residencyd.service
Wants=network-online.target

[Service]
Type=simple
User=${GATEWAY_USER}
Group=${GATEWAY_USER}
Environment=RESIDENCY_SOCK=${RESIDENCY_SOCK}
Environment=RESIDENCY_LOAD_TIMEOUT=${RESIDENCY_LOAD_TIMEOUT}
Environment=PYTHONUNBUFFERED=1
# The dashboard (mounted at /dashboard) is Gradio; keep it fully offline --
# no telemetry ping, no check for a public sharing tunnel.
Environment=GRADIO_ANALYTICS_ENABLED=False
WorkingDirectory=${GATEWAY_VENV}
ExecStart=${GATEWAY_VENV}/bin/python -m uvicorn app:app \\
  --host ${BIND_ADDR} --port ${GATEWAY_PORT} \\
  --no-access-log --timeout-keep-alive 75
Restart=always
RestartSec=5
# It proxies HTTP and talks to exactly one socket. It needs nothing else.
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
# ProtectSystem=strict makes the whole tree read-only; connecting to a unix
# socket needs write access to its inode, so punch through for just that dir.
ReadWritePaths=-$(dirname "$RESIDENCY_SOCK")
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable llm-gateway.service >/dev/null 2>&1 || true
  if [ "$gateway_ready" = "1" ]; then
    systemctl restart llm-gateway.service >/dev/null 2>&1 || true
    ok "llm-gateway.service enabled on ${BIND_ADDR}:${GATEWAY_PORT}"
  else
    warn "llm-gateway.service was written but its dependencies are missing; it will not start yet."
    note_action "llm-gateway dependencies failed to install. Fix networking, then: sudo $UV_SYS pip install --python $GATEWAY_VENV/bin/python fastapi 'uvicorn[standard]' httpx gradio && sudo systemctl restart llm-gateway"
  fi
  echo
elif [ "$INSTALL_GATEWAY" = "1" ]; then
  # Peer node: make sure a previous run as 'server' did not leave one behind.
  if [ -f /etc/systemd/system/llm-gateway.service ]; then
    systemctl disable --now llm-gateway.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/llm-gateway.service
    systemctl daemon-reload
    warn "removed llm-gateway.service (it belongs on $SERVER_HOST, not this node)"
  fi
fi

# =============================================================================
# 9. Open WebUI  (server only)  -- the browser chat client
# =============================================================================
# Open WebUI talks to ONE endpoint: the gateway on loopback. It never sees a
# vLLM instance directly, which is what makes model switching in the UI work --
# picking a cold model from the dropdown makes the gateway ask residencyd to
# load it, and the browser just waits.
# Two Open WebUI details bite people and are handled explicitly below:
#   * it wants CPython 3.11/3.12 -- it does not install on 3.13+;
#   * it snapshots its config into its own database on first launch, so
#     environment variables set later are IGNORED unless persistent config is
#     turned off. That is why ENABLE_PERSISTENT_CONFIG=false is set here.
if [ "$INSTALL_WEBUI" = "1" ] && [ "$IS_SERVER" = "1" ]; then
  log "Installing Open WebUI (browser chat client on port $WEBUI_PORT)"
  export DEBIAN_FRONTEND=noninteractive

  if ! id -u openwebui >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$WEBUI_DATA" \
            --shell /usr/sbin/nologin openwebui \
      || warn "could not create the 'openwebui' service account"
  fi
  install -d -m 0750 -o openwebui -g openwebui "$WEBUI_DATA" "$WEBUI_DATA/hf" 2>/dev/null || true

  webui_ready=0
  if [ ! -x "$UV_SYS" ]; then
    warn "uv is not installed, so Open WebUI cannot be built (re-run without --skip base)."
  else
    # uv fetches the interpreter itself, so this works even though Ubuntu 26.04
    # ships a newer Python than Open WebUI supports. It has to land somewhere
    # the 'openwebui' account can read, which is what uv_root_venv guarantees.
    if uv_root_venv "$WEBUI_PY" "$WEBUI_VENV"; then
      log "  installing open-webui (large download: it pulls its own ML stack)"
      if "$UV_SYS" pip install --python "$WEBUI_VENV/bin/python" open-webui >/dev/null 2>&1; then
        webui_ready=1
        ok "Open WebUI installed into $WEBUI_VENV (Python $WEBUI_PY)"
      else
        warn "open-webui failed to install."
        warn "  It is the only optional piece here - the gateway API works without it."
        note_action "Open WebUI did not install. Retry: sudo $UV_SYS pip install --python $WEBUI_VENV/bin/python open-webui"
      fi
    else
      warn "could not create a Python $WEBUI_PY virtualenv for Open WebUI"
      note_action "Open WebUI has no usable virtualenv, so its unit will fail. Retry with: sudo rm -rf $WEBUI_VENV && sudo $UV_SYS venv --python $WEBUI_PY $WEBUI_VENV"
    fi
  fi
  chown -R openwebui:openwebui "$WEBUI_VENV" 2>/dev/null || true
  # ExecStart is bin/open-webui, a script - so exec() succeeds on the script and
  # then fails on its interpreter. That surfaces as a bare "Permission denied"
  # with no hint about which file is actually at fault.
  if [ "$webui_ready" = "1" ] && ! venv_execs_as openwebui "$WEBUI_VENV"; then
    webui_ready=0
    warn "$WEBUI_VENV/bin/python is not executable by 'openwebui' - the unit would fail 203/EXEC"
    note_action "Open WebUI's interpreter is unreachable for 'openwebui'. Fix with: sudo chmod -R a+rX $UV_PYTHON_DIR $WEBUI_VENV && sudo systemctl restart open-webui"
  fi

  cat > /etc/systemd/system/open-webui.service <<UNIT
[Unit]
Description=Open WebUI (chat front end for the LLM cluster)
Documentation=https://docs.openwebui.com/
After=network-online.target llm-gateway.service
Wants=network-online.target llm-gateway.service

[Service]
Type=simple
User=openwebui
Group=openwebui
WorkingDirectory=${WEBUI_DATA}
Environment=DATA_DIR=${WEBUI_DATA}
Environment=HF_HOME=${WEBUI_DATA}/hf
Environment=HOST=${BIND_ADDR}
Environment=PORT=${WEBUI_PORT}
Environment=PYTHONUNBUFFERED=1
# One backend: the gateway. Open WebUI accepts a ';'-separated list here, but
# pointing it straight at a vLLM port would bypass residencyd and break model
# switching, so there is deliberately only one entry.
Environment=OPENAI_API_BASE_URLS=http://127.0.0.1:${GATEWAY_PORT}/v1
Environment=OPENAI_API_BASE_URL=http://127.0.0.1:${GATEWAY_PORT}/v1
# The gateway does not check keys, but Open WebUI insists on a non-empty value.
Environment=OPENAI_API_KEYS=cluster
Environment=OPENAI_API_KEY=cluster
Environment=ENABLE_OLLAMA_API=false
# Without this, the values above are only read on the VERY first start and any
# later change here is silently ignored in favour of the saved copy in the DB.
Environment=ENABLE_PERSISTENT_CONFIG=false
ExecStart=${WEBUI_VENV}/bin/open-webui serve --port ${WEBUI_PORT}
Restart=always
RestartSec=10
# Cold start pulls embedding models on first run.
TimeoutStartSec=600
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
ReadWritePaths=${WEBUI_DATA}

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable open-webui.service >/dev/null 2>&1 || true
  if [ "$webui_ready" = "1" ]; then
    systemctl restart open-webui.service >/dev/null 2>&1 || true
    ok "open-webui.service enabled on ${BIND_ADDR}:${WEBUI_PORT}"
    note_action "Open WebUI: browse to http://${MY_HOST}:${WEBUI_PORT}/ and create the admin account. The FIRST account registered becomes the administrator."
  else
    warn "open-webui.service was written but the package is missing; it will not start yet."
  fi
  echo
elif [ "$INSTALL_WEBUI" = "1" ]; then
  if [ -f /etc/systemd/system/open-webui.service ]; then
    systemctl disable --now open-webui.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/open-webui.service
    systemctl daemon-reload
    warn "removed open-webui.service (it belongs on $SERVER_HOST, not this node)"
  fi
fi

# =============================================================================
# 10. ComfyUI  (BOTH nodes, one shared file store)
# =============================================================================
# ComfyUI cannot be clustered: there is no equivalent of Ray placement for a
# diffusion graph, and two processes cannot share one iGPU's memory usefully.
# So each node runs its OWN ComfyUI and you point your browser at whichever one
# is free -- two independent render workers, twice the throughput.
#
# What IS shared is the expensive part: the files. checkpoints, LoRAs, VAEs,
# ControlNets, inputs, outputs and workflows all live in $COMFY_ROOT, which the
# server exports read-WRITE over NFS. Download a 12 GB checkpoint through
# ComfyUI-Manager on either machine and it is immediately usable on both.
#
# The sharing is done with SYMLINKS from the checkout into $COMFY_ROOT, not with
# extra_model_paths.yaml or --base-directory. That is deliberate:
#   * symlinks are invisible to every part of ComfyUI -- folder_paths, the
#     Manager, custom nodes and the URL downloader all just see normal dirs;
#   * extra_model_paths.yaml only adds SEARCH paths, so downloads still land in
#     the local tree, which is exactly the wrong half of the behaviour;
#   * --base-directory would also move user/ and custom_nodes/, which must stay
#     per-node (see below), and its semantics vary between releases.
#
# What stays LOCAL on each node, and why:
#   custom_nodes/  their Python dependencies are installed into that node's
#                  venv, so a shared copy would load nodes whose imports are
#                  missing on the other machine.
#   user/          ComfyUI rewrites user/default/comfy.settings.json on every
#                  settings change with no locking; two nodes sharing it would
#                  clobber each other. Only user/default/workflows is shared,
#                  because that is the part you actually want on both.
#   temp/          pure churn, and it belongs on local SSD.
if [ "$INSTALL_COMFYUI" = "1" ]; then
  log "Installing ComfyUI (this node) against the shared store at $COMFY_ROOT"

  if [ ! -x "$UV_BIN" ]; then
    as_user "curl -LsSf https://astral.sh/uv/install.sh | sh" || true
  fi
  if [ ! -x "$UV_BIN" ] && [ -x "$UV_SYS" ]; then UV_BIN="$UV_SYS"; fi
  [ -x "$UV_BIN" ] || die "uv is required for ComfyUI but is not installed (expected $UV_BIN)"
  ok "uv present at $UV_BIN"

  if [ -d "$COMFY_DIR/.git" ]; then
    as_user "cd '$COMFY_DIR' && git pull --ff-only || true"
  else
    as_user "git clone https://github.com/comfyanonymous/ComfyUI '$COMFY_DIR'"
  fi

  # --- 10.1 wire the checkout into the shared store --------------------------
  # Runs before the venv build so a fresh clone never gets a chance to fill the
  # local models/ directory first.
  comfy_share_ready=0
  if [ -d "$COMFY_ROOT/models" ]; then
    comfy_share_ready=1
  else
    warn "$COMFY_ROOT/models is not available yet."
    if [ "$IS_PEER" = "1" ]; then
      warn "  On this node it is an NFS mount from $SERVER_HOST, so it appears once"
      warn "  that box is up and section 5 has mounted it. ComfyUI will use local"
      warn "  directories until then; re-run this script afterwards to link them."
    fi
  fi

  if [ "$comfy_share_ready" = "1" ]; then
    # link_shared <subdir-in-checkout> <target-in-COMFY_ROOT>
    # Replaces a real directory with a symlink, but only after moving anything
    # already inside it into the shared tree -- so a second run, or a machine
    # that was set up standalone first, never silently loses files.
    link_shared() {
      local rel="$1" target="$2" src="$COMFY_DIR/$1"
      install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" "$target" 2>/dev/null || true
      if [ -L "$src" ]; then
        [ "$(readlink -f "$src")" = "$(readlink -f "$target")" ] && return 0
        rm -f "$src"
      elif [ -d "$src" ]; then
        # cp -a then rm: a plain mv across the NFS boundary is not atomic anyway,
        # and copying first means an interrupted run loses nothing.
        if [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
          log "  migrating existing $rel into the shared store (this may take a while)"
          local cperr="" cpok=0
          if cperr="$(cp -a "$src/." "$target/" 2>&1)"; then
            cpok=1
          elif cperr="$(as_user "cp -a '$src/.' '$target/'" 2>&1)"; then
            # As root this fails on the peer and only on the peer: /srv/comfyui
            # is an NFS mount exported with root_squash, so root arrives as
            # 'nobody', while the shared directories are 2775 $TARGET_USER:
            # $SHARE_GROUP - group-writable, not world-writable. The owner can
            # write them, and is the same uid on both nodes, so retry as them.
            cpok=1
          fi
          if [ "$cpok" = "0" ]; then
            # A fresh ComfyUI checkout ships an empty skeleton here: directories
            # holding nothing but 'put_*_here' placeholders. Refusing to link
            # because THAT could not be copied would leave the node permanently
            # unshared for no reason, so only real content blocks the link.
            if [ -n "$(find "$src" -type f ! -name '.gitkeep' ! -name 'put_*' -print -quit 2>/dev/null)" ]; then
              warn "could not copy $src into $target; leaving it local"
              [ -n "$cperr" ] && warn "  ${cperr%%$'\n'*}"
              return 1
            fi
            log "  $rel held only the upstream placeholder skeleton; linking without copying"
          fi
        fi
        rm -rf "$src"
      fi
      ln -sfn "$target" "$src"
      chown -h "$TARGET_USER:$TARGET_USER" "$src" 2>/dev/null || true
      return 0
    }
    for pair in "models:$COMFY_ROOT/models" "input:$COMFY_ROOT/input" "output:$COMFY_ROOT/output"; do
      link_shared "${pair%%:*}" "${pair#*:}" && ok "  ComfyUI/${pair%%:*} -> ${pair#*:}"
    done
    # Workflows are the one thing under user/ worth sharing. Only created when
    # missing: on the peer this lives on the NFS mount, where re-applying mode
    # and ownership as root is refused by root_squash even though the directory
    # is already exactly right.
    if [ ! -d "$COMFY_ROOT/workflows" ]; then
      install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" "$COMFY_ROOT/workflows" 2>/dev/null \
        || warn "could not create $COMFY_ROOT/workflows (the shared tree is not writable from here)"
    fi
    install -d -m 0755 "$COMFY_DIR/user" "$COMFY_DIR/user/default"
    link_shared "user/default/workflows" "$COMFY_ROOT/workflows" \
      && ok "  ComfyUI/user/default/workflows -> $COMFY_ROOT/workflows"
    ok "ComfyUI file store shared with $OTHER_HOST via $COMFY_ROOT"
  fi

  # --- 10.2 Python environment ----------------------------------------------
  # torch/torchvision/torchaudio come ONLY from AMD's gfx1151 index; the rest of
  # ComfyUI's requirements come from PyPI with the torch lines stripped, so a
  # transitive dependency can never replace the ROCm build with a CPU one.
  cat > "$USER_HOME/.comfyui_provision.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
# Nothing in a provisioning run may ever ask a question: the prompt is invisible
# when the run is logged to a file, and it blocks forever when it is not
# watched. uv prompts before replacing a virtualenv and git prompts for
# credentials on a private URL; both read stdin, so close it once here.
exec </dev/null
export GIT_TERMINAL_PROMPT=0
cd "$COMFY_DIR"
# uv 0.12 refuses to create a venv where a directory already exists:
#   "? A virtual environment already exists at `.venv`. Do you want to replace
#    it? [y/n]"   (on a terminal)
#   "error: Failed to create virtual environment ... A directory already exists"
# Decide here instead of asking. A working .venv is left alone - it holds
# several GB of ROCm torch - and a broken one is removed outright, which needs
# no uv flags and behaves the same on every uv version. Note that uv's own
# --clear deletes the WHOLE directory, not just the virtualenv parts.
if [ -x .venv/bin/python ] && .venv/bin/python -c '' >/dev/null 2>&1; then
  echo "  reusing the existing ComfyUI virtualenv at $COMFY_DIR/.venv"
else
  if [ -e .venv ]; then echo "  rebuilding $COMFY_DIR/.venv (no usable interpreter in it)"; fi
  rm -rf .venv
  "$UV_BIN" venv --python "$COMFY_PY" .venv
fi
"$UV_BIN" pip install --python .venv/bin/python --index-url "$TORCH_INDEX" \
    torch torchvision torchaudio
grep -viE '^(torch|torchvision|torchaudio)([[:space:]<>=!~;]|$)' requirements.txt \
    > .reqs-notorch.txt || cp requirements.txt .reqs-notorch.txt
"$UV_BIN" pip install --python .venv/bin/python -r .reqs-notorch.txt
# ComfyUI-Manager: modern ComfyUI core bundles it as the 'comfyui_manager' PyPI
# package (pinned in manager_requirements.txt) and activates it at launch with
# --enable-manager. Install it unconditionally, stripping any torch pins so the
# ROCm build is never replaced. If this checkout predates the bundled package,
# fall back to the classic method: clone ComfyUI-Manager into custom_nodes/ where
# ComfyUI auto-loads it as a normal custom node (no launch flag needed). Manager
# failures here are non-fatal so they never abort the whole ComfyUI provision.
mgr_ok=0
if [ -f manager_requirements.txt ]; then
  grep -viE '^(torch|torchvision|torchaudio)([[:space:]<>=!~;]|$)' manager_requirements.txt \
      > .mgr-reqs.txt || cp manager_requirements.txt .mgr-reqs.txt
  if "$UV_BIN" pip install --python .venv/bin/python -r .mgr-reqs.txt; then mgr_ok=1; fi
fi
if [ "$mgr_ok" != "1" ] || ! .venv/bin/python -c 'import comfyui_manager' 2>/dev/null; then
  echo "[provision] bundled comfyui_manager unavailable; cloning ComfyUI-Manager into custom_nodes/"
  mkdir -p custom_nodes
  if [ -d custom_nodes/comfyui-manager/.git ]; then
    git -C custom_nodes/comfyui-manager pull --ff-only || true
  else
    git clone https://github.com/Comfy-Org/ComfyUI-Manager custom_nodes/comfyui-manager || true
  fi
  if [ -f custom_nodes/comfyui-manager/requirements.txt ]; then
    grep -viE '^(torch|torchvision|torchaudio)([[:space:]<>=!~;]|$)' custom_nodes/comfyui-manager/requirements.txt \
        > .mgr-cn-reqs.txt || cp custom_nodes/comfyui-manager/requirements.txt .mgr-cn-reqs.txt
    "$UV_BIN" pip install --python .venv/bin/python -r .mgr-cn-reqs.txt || true
  fi
fi
# ComfyUI URL Downloader: download models SERVER-SIDE from HuggingFace/CivitAI
# into ComfyUI/models/<type>/ (which is now the SHARED store, so one download
# serves both nodes) and intercept the new UI's missing-model button, which
# otherwise saves to the client browser's Downloads folder -- useless for a
# headless LAN server. Pure-Python with its JS bundled in-repo, so there is no
# release asset to 404 on. Non-fatal.
mkdir -p custom_nodes
if [ -d custom_nodes/comfyui-url-downloader/.git ]; then
  git -C custom_nodes/comfyui-url-downloader pull --ff-only || true
else
  git clone https://github.com/mighty-bean/comfyui-url-downloader custom_nodes/comfyui-url-downloader || true
fi
EOS
  chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/.comfyui_provision.sh"
  if as_user "COMFY_DIR='$COMFY_DIR' UV_BIN='$UV_BIN' COMFY_PY='$COMFY_PY' TORCH_INDEX='$TORCH_INDEX' bash '$USER_HOME/.comfyui_provision.sh'"; then
    ok "ComfyUI Python environment ready"
  else
    warn "the ComfyUI provisioning step reported an error; the service may not start."
    note_action "ComfyUI provisioning failed on $MY_HOST. Re-run: sudo -u $TARGET_USER bash $USER_HOME/.comfyui_provision.sh"
  fi

  # --- 10.3 Manager flag + config -------------------------------------------
  # Every optional flag below is probed against this checkout's cli_args.py
  # before it is used. The clone is whatever master gave us today, argparse
  # exits 2 on an unknown argument, and a service that will not start is a far
  # worse outcome than running without a tuning flag.
  comfy_has_flag() { as_user "grep -q -- '$1' '$COMFY_DIR/comfy/cli_args.py'"; }
  COMFY_TUNE_FLAGS=""
  comfy_add_flag() { COMFY_TUNE_FLAGS="${COMFY_TUNE_FLAGS:+$COMFY_TUNE_FLAGS }$*"; }

  # ComfyUI activates the bundled Manager only when launched with
  # --enable-manager, and only if comfyui_manager is importable (otherwise it
  # logs a warning and disables itself -- it never crashes, so passing the flag
  # is safe).
  COMFY_MGR_FLAG=""
  if comfy_has_flag --enable-manager 2>/dev/null; then
    COMFY_MGR_FLAG="--enable-manager"
    ok "ComfyUI supports --enable-manager; launch parameter will be included"
  else
    warn "This ComfyUI build has no --enable-manager flag; using the custom_nodes Manager clone (auto-loaded, no flag)."
  fi
  COMFY_TEMP_FLAG=""
  if comfy_has_flag --temp-directory 2>/dev/null; then
    COMFY_TEMP_FLAG="--temp-directory ${COMFY_LOCAL_CACHE}/temp"
  fi

  # --- 10.3a memory behaviour on a shared box --------------------------------
  # See the CONFIGURATION block for why the cache is bounded rather than left at
  # upstream's default.
  case "$COMFY_CACHE_MODE" in
    ram)
      if comfy_has_flag --cache-ram 2>/dev/null; then
        comfy_add_flag "--cache-ram $COMFY_CACHE_ACTIVE_GB $COMFY_CACHE_INACTIVE_GB"
        ok "ComfyUI cache bounded to ${COMFY_CACHE_ACTIVE_GB}G active / ${COMFY_CACHE_INACTIVE_GB}G inactive"
      else
        warn "this ComfyUI has no --cache-ram; the cache keeps its built-in default,"
        warn "  which on this machine can grow into the memory vLLM is using."
      fi
      ;;
    classic)
      if comfy_has_flag --cache-classic 2>/dev/null; then
        comfy_add_flag "--cache-classic"
        ok "ComfyUI using classic (aggressive) caching"
      fi
      ;;
    lru)
      if comfy_has_flag --cache-lru 2>/dev/null; then
        comfy_add_flag "--cache-lru $COMFY_CACHE_LRU"
        ok "ComfyUI using LRU caching, $COMFY_CACHE_LRU node results"
      fi
      ;;
    none)
      if comfy_has_flag --cache-none 2>/dev/null; then
        comfy_add_flag "--cache-none"
        ok "ComfyUI node-result caching disabled"
      fi
      ;;
  esac

  if [ "${COMFY_RESERVE_VRAM%%.*}" != "0" ]; then
    if comfy_has_flag --reserve-vram 2>/dev/null; then
      comfy_add_flag "--reserve-vram $COMFY_RESERVE_VRAM"
      ok "ComfyUI will leave ${COMFY_RESERVE_VRAM} GiB of GPU memory for vLLM and the OS"
    else
      warn "this ComfyUI has no --reserve-vram; it may claim GPU memory vLLM needs"
    fi
  fi

  if [ "$COMFY_PREVIEW_METHOD" != "none" ] && comfy_has_flag --preview-method 2>/dev/null; then
    comfy_add_flag "--preview-method $COMFY_PREVIEW_METHOD"
  fi

  # Deliberate: the asset scanner would walk (and optionally hash) the shared
  # NFS model store from BOTH nodes, continuously, over the USB4 link.
  if [ "$COMFY_ENABLE_ASSETS" = "1" ]; then
    if comfy_has_flag --enable-assets 2>/dev/null; then
      comfy_add_flag "--enable-assets"
      warn "ComfyUI asset scanning is ENABLED; it will index $COMFY_ROOT continuously"
    fi
  fi
  if [ "$COMFY_DISABLE_API_NODES" = "1" ] && comfy_has_flag --disable-api-nodes 2>/dev/null; then
    comfy_add_flag "--disable-api-nodes"
    ok "ComfyUI API nodes disabled; the frontend will not call out to the internet"
  fi

  # Pre-seed the Manager config so node management works from the LAN on first
  # boot. Seed both the >=3.38 protected path and the legacy path; only the
  # matching one is read by the installed version, and an existing file is never
  # clobbered.
  mkdir -p "$COMFY_DIR/user/__manager" "$COMFY_DIR/user/default/ComfyUI-Manager"
  for mgr_dir in "$COMFY_DIR/user/__manager" "$COMFY_DIR/user/default/ComfyUI-Manager"; do
    if [ ! -f "$mgr_dir/config.ini" ]; then
      printf '[default]\nsecurity_level = %s\nnetwork_mode = public\n' \
        "$COMFY_MANAGER_SECURITY" > "$mgr_dir/config.ini"
    fi
  done
  # CRITICAL: own the ENTIRE user tree as the service user. Creating those dirs
  # as root leaves the auto-made parents root-owned (mkdir only sets attributes
  # on the final component), and ComfyUI then fails to write
  # user/default/comfy.settings.json with a PermissionError that breaks the web
  # UI menu, so the Manager button never initialises. The recursive chown also
  # repairs that state on a re-run. -h keeps it from following the workflows
  # symlink out onto the shared NFS tree.
  chown -R -h "$TARGET_USER:$TARGET_USER" "$COMFY_DIR/user"
  ok "ComfyUI-Manager config seeded (security_level=${COMFY_MANAGER_SECURITY})"

  # --- 10.4 service ----------------------------------------------------------
  install -d -m 2775 -o "$TARGET_USER" -g "$SHARE_GROUP" \
    "$COMFY_LOCAL_CACHE" "$COMFY_LOCAL_CACHE/temp" 2>/dev/null || true
  # HF_HOME points at the SHARED tree on both nodes: unlike $LLM_ROOT, the
  # ComfyUI export is read-write, so text encoders, tokenizers and anything else
  # pulled through huggingface_hub / diffusers / transformers by a custom node
  # is downloaded once and reused by the other machine.
  _comfy_mount=""; _comfy_gate=""
  if [ "$IS_PEER" = "1" ]; then
    # RequiresMountsFor= is a HARD Requires= on the mount unit. If the USB4 link
    # is not up when ComfyUI is first pulled in at boot, the mount attempt fails
    # and systemd refuses the service with "Dependency failed" - and because a
    # dependency failure is NOT a service failure, Restart=on-failure never
    # retries it. The node then sits with the share happily mounted and ComfyUI
    # permanently dead. Order against the automount with a SOFT Wants= instead,
    # and gate the real start on the share genuinely being there, which is a
    # service failure and therefore does get retried.
    _comfy_au="$(systemd-escape -p --suffix=automount "$COMFY_ROOT" 2>/dev/null || true)"
    [ -n "$_comfy_au" ] || _comfy_au="remote-fs.target"
    _comfy_mount="After=${_comfy_au}
Wants=${_comfy_au}"
    _comfy_gate="ExecStartPre=/usr/local/bin/comfy-store-wait"
    # Never start on the bare local mountpoint: ComfyUI would write models and
    # outputs into a directory that the automount shadows the moment it fires,
    # and they would appear to vanish.
    cat > /usr/local/bin/comfy-store-wait <<WAITC
#!/usr/bin/env bash
# Block until ${COMFY_ROOT} is really the NFS share from ${SERVER_HOST}.
# Exits non-zero if it never arrives, so systemd retries the service.
/usr/local/bin/usb4-cluster-wait "${SERVER_IP}" 120 || true
for _ in \$(seq 1 20); do
  # Touching the path is what triggers the autofs mount in the first place.
  ls "${COMFY_ROOT}/" >/dev/null 2>&1
  if findmnt -T "${COMFY_ROOT}" -n -o FSTYPE 2>/dev/null | grep nfs >/dev/null; then
    exit 0
  fi
  sleep 3
done
echo "comfy-store-wait: ${COMFY_ROOT} is not mounted from ${SERVER_HOST}; refusing to start on the empty local mountpoint" >&2
exit 1
WAITC
    chmod 0755 /usr/local/bin/comfy-store-wait
  fi
  cat > /etc/systemd/system/comfyui.service <<UNIT
[Unit]
Description=ComfyUI (PyTorch ROCm ${ROCM_GFX}, Strix Halo ${NODE_ROLE} node)
After=network-online.target
Wants=network-online.target
# Let systemd work out the mount/automount unit name itself rather than
# hand-mangling the path into one.
${_comfy_mount}

[Service]
Type=simple
User=${TARGET_USER}
Group=${TARGET_USER}
SupplementaryGroups=render video ${SHARE_GROUP}
# setgid dirs plus this umask are what keep everything written to the shared
# store group-writable, so the other node can overwrite and delete it too.
UMask=0002
Environment=HOME=${USER_HOME}
Environment=HF_HOME=${COMFY_ROOT}/hf
Environment=HF_HUB_CACHE=${COMFY_ROOT}/hf/hub
Environment=ROCM_PATH=/opt/rocm
WorkingDirectory=${COMFY_DIR}
${_comfy_gate}
ExecStart=${COMFY_DIR}/.venv/bin/python ${COMFY_DIR}/main.py \\
  --listen ${BIND_ADDR} --port ${COMFYUI_PORT} ${COMFY_MGR_FLAG} ${COMFY_TEMP_FLAG} ${COMFY_TUNE_FLAGS}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable comfyui.service >/dev/null 2>&1 || true
  ok "comfyui.service enabled on ${BIND_ADDR}:${COMFYUI_PORT} (this node only)"
  [ -n "$COMFY_TUNE_FLAGS" ] && ok "  memory/UI tuning: $COMFY_TUNE_FLAGS"
  echo
fi

# =============================================================================
# 11a. WINDOWS FILE DROP OVER SMB  (\\this-node\xfer)
# =============================================================================
# This exists for one concrete reason: RDP clipboard file transfer only works
# reliably Linux -> Windows. Copying a file Windows -> Linux over the RDP
# clipboard silently does nothing, which makes routine maintenance (dropping a
# config, a wheel, a workflow JSON, a LoRA) far harder than it should be.
# A plain SMB share fixes that in both directions and needs nothing installed
# on the Windows side - Explorer speaks SMB natively.
#
# Trusted private LAN, so the share is open: no accounts, no passwords, no
# encryption. It is deliberately kept separate from $LLM_ROOT and $COMFY_ROOT,
# which are NFS-exported between the nodes with specific read-only/read-write
# semantics that an SMB client has no business changing. Each node serves its
# own $XFER_SHARE, so \\node1\xfer and \\node2\xfer are different folders on
# different machines - which is what you want when the whole point is getting a
# file onto one specific box.
if [ "$INSTALL_SAMBA" = "1" ]; then
  log "Setting up the '$XFER_SHARE' file share for Windows ($XFER_ROOT)"
  export DEBIAN_FRONTEND=noninteractive

  # smbclient is not required to SERVE a share; it is installed so this script
  # can prove the share actually works before claiming success, and so the
  # admin can test from the Linux side later.
  apt-get install -y samba samba-common-bin smbclient \
    || die "failed to install samba (needed for the '$XFER_SHARE' share; use --skip samba to leave it out)"
  ok "samba $(dpkg-query -W -f='${Version}' samba 2>/dev/null) installed"

  # --- 1. the folder itself --------------------------------------------------
  # setgid (2xxx) on the directory means every file dropped from Windows keeps
  # the share group, so the services on this box can read what was just copied
  # in without anyone having to chown it afterwards.
  XFER_GROUP="$SHARE_GROUP"
  getent group "$XFER_GROUP" >/dev/null 2>&1 || XFER_GROUP="$(id -gn "$TARGET_USER")"
  install -d -m 2777 "$XFER_ROOT"
  chown "$TARGET_USER:$XFER_GROUP" "$XFER_ROOT" 2>/dev/null || true
  chmod 2777 "$XFER_ROOT"
  ok "$XFER_ROOT ready (owner $TARGET_USER, group $XFER_GROUP, setgid, world-writable)"

  # $XFER_ROOT normally lives on the root filesystem, and a 60 GB model dropped
  # into it fills the same disk that holds / and the journal. Say so once, with
  # the number, rather than letting it be discovered later.
  XFER_FREE="$(df -h --output=avail "$XFER_ROOT" 2>/dev/null | tail -n1 | tr -d ' ')" || XFER_FREE=""
  XFER_FS="$(findmnt -no TARGET -T "$XFER_ROOT" 2>/dev/null || echo /)"
  [ -n "$XFER_FREE" ] && log "  $XFER_ROOT is on $XFER_FS with $XFER_FREE free - it is a transfer folder, not storage"

  # --- 2. smb.conf -----------------------------------------------------------
  # The share is written as a marked block appended to the packaged smb.conf.
  # Samba merges repeated [global] sections and the last value wins, so a
  # trailing [global] is legal and lets the whole managed region be replaced by
  # a single range delete on re-run. The packaged file is left otherwise
  # untouched, so an apt upgrade of samba never fights with this script.
  SMB_CONF="/etc/samba/smb.conf"
  install -d -m 0755 "$(dirname "$SMB_CONF")"
  [ -f "$SMB_CONF" ] || printf '[global]\n' > "$SMB_CONF"
  [ -f "${SMB_CONF}.strixhalo-orig" ] || cp -a "$SMB_CONF" "${SMB_CONF}.strixhalo-orig"

  smb_tmp="$(mktemp)"
  # Range-delete first, so this is idempotent and a changed share name or path
  # does not leave the previous definition behind.
  sed '/strixhalo-xfer BEGIN/,/strixhalo-xfer END/d' "$SMB_CONF" > "$smb_tmp"
  {
    echo ""
    echo "# ==== strixhalo-xfer BEGIN - managed by $SCRIPT_NAME, edits here are lost ===="
    cat <<SMBCONF
[global]
   workgroup = $SAMBA_WORKGROUP
   server string = $MY_HOST (Strix Halo AI node)
   # SMB1 is not a hardening choice: Windows 10/11 no longer install it, so a
   # share that only speaks SMB1 cannot be opened from a stock Windows client.
   server min protocol = SMB2
   client min protocol = SMB2
   # Open share on a trusted LAN: an unknown user becomes the guest account
   # instead of being rejected.
   map to guest = Bad User
   guest account = $TARGET_USER
   # Nothing on these boxes is a print server.
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
   # Everything written through this share lands as $TARGET_USER:$XFER_GROUP,
   # so a file copied in from Windows is immediately usable on the Linux side
   # without a chown chasing it.
   force user = $TARGET_USER
   force group = $XFER_GROUP
   create mask = 0664
   force create mode = 0664
   directory mask = 2775
   force directory mode = 2775
SMBCONF
    echo "# ==== strixhalo-xfer END ===="
  } >> "$smb_tmp"

  # Never install a config that samba itself rejects: a syntax error in
  # smb.conf takes smbd down completely, including any share that was working
  # before this script ran.
  if testparm -s "$smb_tmp" >/dev/null 2>&1; then
    install -m 0644 "$smb_tmp" "$SMB_CONF"
    ok "share [$XFER_SHARE] -> $XFER_ROOT written to $SMB_CONF (validated with testparm)"
  else
    warn "the generated smb.conf did not pass testparm - $SMB_CONF was left alone:"
    { testparm -s "$smb_tmp" 2>&1 || true; } | sed 's/^/       /' | head -20 || true
    note_action "The Samba share could not be configured: the generated smb.conf failed testparm. $SMB_CONF is unchanged."
  fi
  rm -f "$smb_tmp"

  # --- 3. services -----------------------------------------------------------
  # nmbd answers NetBIOS name lookups, which is what makes \\$MY_HOST\\$XFER_SHARE
  # resolve from Windows without a DNS entry or a hosts file edit.
  systemctl enable smbd.service >/dev/null 2>&1 || true
  systemctl enable nmbd.service >/dev/null 2>&1 || true
  systemctl restart smbd.service >/dev/null 2>&1 \
    && ok "smbd running" \
    || warn "smbd did not start (check: systemctl status smbd)"
  # nmbd answers the NetBIOS name lookup that makes \\hostname work without a
  # DNS entry. Its failure was previously swallowed, which left the operator
  # with a share reachable only by IP and no clue why.
  if systemctl restart nmbd.service >/dev/null 2>&1; then
    ok "nmbd running - \\\\$MY_HOST resolves from Windows without a DNS entry"
  else
    warn "nmbd did not start - reach the share as \\\\$LAN_IP instead of \\\\$MY_HOST:"
    { systemctl status nmbd.service --no-pager -n 6 2>&1 || true; } \
      | sed 's/^/       /' | head -10 || true
    note_action "nmbd is not running on $MY_HOST, so \\\\$MY_HOST will not resolve from Windows. Use \\\\$LAN_IP\\$XFER_SHARE, or investigate: systemctl status nmbd"
  fi

  # --- 4. discovery in Windows Explorer --------------------------------------
  # Windows 10/11 stopped browsing the network over NetBIOS and use WS-Discovery
  # instead, so without wsdd the box works by \\name and \\ip but never appears
  # under "Network". Nice-to-have, never fatal: it is universe-only on some
  # releases, and typing the path always works.
  SAMBA_DISCOVERY_ON=0
  if [ "$SAMBA_DISCOVERY" = "1" ]; then
    if apt-get install -y wsdd >/dev/null 2>&1; then
      # The unit name is not the same everywhere: the Python implementation ships
      # wsdd.service, the C rewrite is packaged as wsdd2.service, 'wsdd' can be a
      # virtual package satisfied by either, and on mighty-ai1 the install
      # succeeded while systemd reported "Unit wsdd.service could not be found"
      # and dpkg listed no unit at all. So: ask what was really installed, then
      # fall back to the usual names, and if there is a daemon but nobody
      # shipped a unit for it, write one - this is a five-line service.
      wsdd_unit=""
      wsdd_cands="$({ dpkg -L wsdd wsdd2 2>/dev/null || true; } \
                    | grep -E '/systemd/system/[^/]+\.service$' || true)"
      wsdd_cands="$wsdd_cands
$({ systemctl list-unit-files 'wsdd*.service' --no-legend 2>/dev/null || true; } | awk '{print $1}')"
      for wsdd_c in $wsdd_cands wsdd.service wsdd2.service; do
        wsdd_c="${wsdd_c##*/}"
        if systemctl cat "$wsdd_c" >/dev/null 2>&1; then wsdd_unit="$wsdd_c"; break; fi
      done
      if [ -z "$wsdd_unit" ]; then
        wsdd_bin=""
        for wsdd_b in wsdd wsdd2 /usr/sbin/wsdd /usr/sbin/wsdd2; do
          wsdd_p="$(command -v "$wsdd_b" 2>/dev/null || true)"
          if [ -n "$wsdd_p" ] && [ -x "$wsdd_p" ]; then wsdd_bin="$wsdd_p"; break; fi
        done
        # Only the Python implementation is safe to write a unit for unseen: it
        # stays in the foreground, which is what Type=simple needs. The C daemon
        # forks by default and would need Type=forking plus its own options, so
        # if that is what turned up, say so rather than ship a broken unit.
        if [ -n "$wsdd_bin" ] && { "$wsdd_bin" --help 2>&1 || true; } | grep -- '--shortlog' >/dev/null; then
          cat > /etc/systemd/system/wsdd.service <<UNIT
[Unit]
Description=Web Services Dynamic Discovery host daemon
Documentation=https://github.com/christgau/wsdd
# Managed by setup-strixhalo-ai-server.sh: the packaged unit was missing.
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
          wsdd_unit="wsdd.service"
          ok "the wsdd package shipped no unit; wrote /etc/systemd/system/wsdd.service"
        fi
      fi
      if [ -z "$wsdd_unit" ]; then
        warn "wsdd is installed but has no usable systemd unit - $MY_HOST will not"
        warn "  appear under 'Network' in Windows Explorer. \\\\$MY_HOST\\$XFER_SHARE still works."
        { dpkg -l 2>/dev/null | grep -i wsdd || true; } | sed 's/^/       /' | head -4 || true
      else
        systemctl enable --now "$wsdd_unit" >/dev/null 2>&1 || true
        if systemctl is-active "$wsdd_unit" >/dev/null 2>&1; then
          SAMBA_DISCOVERY_ON=1
          ok "$wsdd_unit running - $MY_HOST appears under 'Network' in Windows Explorer"
        else
          warn "wsdd is installed but not running - use \\\\$MY_HOST\\$XFER_SHARE directly"
          { systemctl status "$wsdd_unit" --no-pager -n 6 2>&1 || true; } \
            | sed 's/^/       /' | head -10 || true
        fi
      fi
    else
      warn "the 'wsdd' package is not available - $MY_HOST will not appear under 'Network'"
      warn "  in Windows Explorer. Typing \\\\$MY_HOST\\$XFER_SHARE still works."
    fi
  fi

  # --- 5. prove it actually serves -------------------------------------------
  # testparm only says the config parses. This says the share can be opened
  # anonymously, which is the difference between "configured" and "working".
  if command -v smbclient >/dev/null 2>&1 && systemctl is-active smbd.service >/dev/null 2>&1; then
    if smb_probe="$(smbclient "//127.0.0.1/$XFER_SHARE" -N -c 'ls' 2>&1)"; then
      ok "self-test passed: //127.0.0.1/$XFER_SHARE opened anonymously and listed"
    else
      warn "the share did not open locally - it will not open from Windows either:"
      printf '%s\n' "$smb_probe" | sed 's/^/       /' | head -5 || true
      note_action "The '$XFER_SHARE' SMB share failed a local self-test. Check: sudo smbclient //127.0.0.1/$XFER_SHARE -N"
    fi
  fi
  echo
fi

# =============================================================================
# 11. XRDP REMOTE DESKTOP  (Windows "Remote Desktop Connection" -> this node)
# =============================================================================
# RDP on a *server* install is not a one-liner: xrdp only brokers a session, it
# does not provide one. On a headless Ubuntu there is no desktop, no X server
# allowed to start outside the console, and polkit treats an RDP login as
# non-local. Each of those produces the classic "connects, flashes, drops"
# symptom, so this section handles all four:
#   1. ensure a desktop exists (XFCE if none) - still NO display manager, so the
#      box stays headless and nothing holds the iGPU when nobody is connected;
#   2. install xrdp + xorgxrdp and let it read the TLS key (ssl-cert group);
#   3. tell Xorg's setuid wrapper that non-console users may start an X server;
#   4. pick the session to launch and silence the colord polkit prompt.
if [ "$INSTALL_XRDP" = "1" ]; then
  log "Installing XRDP remote desktop (RDP on port $XRDP_PORT)"
  export DEBIAN_FRONTEND=noninteractive

  # --- 1. a desktop session for xrdp to serve --------------------------------
  # XFCE is installed unconditionally when it is the chosen desktop, even if
  # GNOME is already present from an Ubuntu Desktop install. 'auto' remains for
  # anyone who would rather keep whatever the box already has.
  XRDP_SESSION_BIN=""
  case "$XRDP_DESKTOP" in
    auto)
      for c in /usr/bin/xfce4-session /usr/bin/gnome-session /usr/bin/startplasma-x11 \
               /usr/bin/mate-session /usr/bin/cinnamon-session /usr/bin/lxqt-session; do
        if [ -x "$c" ]; then XRDP_SESSION_BIN="$c"; break; fi
      done
      ;;
    xfce|xfce4) XRDP_SESSION_BIN="" ;;          # force the XFCE branch below
    /*)         XRDP_SESSION_BIN="$XRDP_DESKTOP" ;;
    *)          die "XRDP_DESKTOP must be 'auto', 'xfce', or an absolute path to a session binary" ;;
  esac

  if [ -z "$XRDP_SESSION_BIN" ] || [ ! -x "$XRDP_SESSION_BIN" ]; then
    if [ -x /usr/bin/xfce4-session ]; then
      log "  ensuring the XFCE desktop is complete"
    else
      log "  installing XFCE (the lightest session that still gives a usable desktop)"
    fi
    # Deliberately NOT 'task-xfce-desktop'/'xfce4-goodies': those drag in a
    # display manager (lightdm) plus hundreds of MB of extras. dbus-x11 and
    # x11-xserver-utils are genuinely required for a working XFCE-over-xrdp
    # session (Ubuntu's Xsession only launches dbus when dbus-x11 is present).
    apt-get install -y xfce4 xfce4-terminal dbus-x11 x11-xserver-utils \
      || die "failed to install the XFCE desktop (required for XRDP)"
    XRDP_SESSION_BIN=/usr/bin/xfce4-session
    ok "XFCE present (installing it does not pull in a display manager)"
  else
    ok "reusing the desktop already installed: $XRDP_SESSION_BIN"
  fi

  # --- 2. xrdp itself --------------------------------------------------------
  # xorgxrdp is the Xorg driver set xrdp drives; installing it explicitly means
  # we do not depend on apt Recommends being enabled.
  apt-get install -y xrdp xorgxrdp || die "failed to install xrdp"
  ok "xrdp $(dpkg-query -W -f='${Version}' xrdp 2>/dev/null) installed"

  # GNOME ships its own RDP server on modern Ubuntu. It binds 3389, so it only
  # conflicts when we are using the default port - do not disturb it otherwise.
  # ('grep >/dev/null', not 'grep -q': under pipefail a -q early exit SIGPIPEs
  # systemctl and the pipeline would report "not found" for a unit that exists.)
  if [ "$XRDP_PORT" = "3389" ] \
     && systemctl list-unit-files --no-legend 2>/dev/null | grep '^gnome-remote-desktop\.service' >/dev/null; then
    if systemctl is-enabled gnome-remote-desktop.service >/dev/null 2>&1 \
       || systemctl is-active gnome-remote-desktop.service >/dev/null 2>&1; then
      systemctl disable --now gnome-remote-desktop.service >/dev/null 2>&1 || true
      warn "disabled gnome-remote-desktop.service (it also listens on 3389)"
    fi
  fi

  # xrdp's TLS layer reads /etc/ssl/private/ssl-cert-snakeoil.key, which is
  # root:ssl-cert 0640. Without this you get "Error, checking certificate" in
  # /var/log/xrdp.log and the negotiation drops.
  if getent group ssl-cert >/dev/null 2>&1 && id xrdp >/dev/null 2>&1; then
    usermod -aG ssl-cert xrdp
    ok "'xrdp' service account added to the ssl-cert group"
  fi

  # --- 3. let a non-console user start Xorg ----------------------------------
  # When xserver-xorg-legacy is installed (XFCE/GNOME pull it in), /usr/bin/Xorg
  # is the setuid wrapper Xorg.wrap, which honours Xwrapper.config and defaults
  # to allowed_users=console. An RDP login is not a console seat, so sesman dies
  # with "Only console users are allowed to run the X server".
  # needs_root_rights=no is correct AND safer here: xorgxrdp renders to a virtual
  # framebuffer and never touches the real display hardware.
  if dpkg -s xserver-xorg-legacy >/dev/null 2>&1 || [ -f /etc/X11/Xwrapper.config ]; then
    install -d -m 0755 /etc/X11
    cat > /etc/X11/Xwrapper.config <<'XWRAP'
# Managed by setup-strixhalo-ai-server.sh
# Remote (xrdp) logins are not console seats; allow them to start an X server.
allowed_users=anybody
needs_root_rights=no
XWRAP
    ok "Xorg wrapper now allows non-console (RDP) sessions to start an X server"
  fi

  # --- 4. which desktop xrdp starts ------------------------------------------
  # /etc/xrdp/startwm.sh runs /etc/X11/Xsession, which prefers the user's
  # ~/.xsession and otherwise falls back to the 'x-session-manager' alternative.
  # Set BOTH: ~/.xsession for $TARGET_USER, the alternative for everyone else.
  case "$XRDP_SESSION_BIN" in
    */gnome-session)
      XRDP_XSESSION=$'export XDG_CURRENT_DESKTOP=ubuntu:GNOME\nexport GNOME_SHELL_SESSION_MODE=ubuntu\nexec /usr/bin/gnome-session' ;;
    */xfce4-session)   XRDP_XSESSION='exec /usr/bin/startxfce4' ;;
    *)                 XRDP_XSESSION="exec $XRDP_SESSION_BIN" ;;
  esac
  printf '#!/bin/sh\n# Managed by setup-strixhalo-ai-server.sh - desktop launched for XRDP sessions\n%s\n' \
    "$XRDP_XSESSION" > "$USER_HOME/.xsession"
  chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$USER_HOME/.xsession"
  # Xsession runs ~/.xsession directly when executable and via $SHELL otherwise;
  # 0755 + the shebang is the unambiguous form.
  chmod 0755 "$USER_HOME/.xsession"
  # ...but Xsession only looks at ~/.xsession when 'allow-user-xsession' is set
  # in Xsession.options (it is by default on Ubuntu; restore it if someone
  # hardened it away, otherwise the file is silently ignored).
  if [ -f /etc/X11/Xsession.options ] && ! grep -qE '^[[:space:]]*allow-user-xsession[[:space:]]*$' /etc/X11/Xsession.options; then
    echo 'allow-user-xsession' >> /etc/X11/Xsession.options
    warn "re-enabled 'allow-user-xsession' in /etc/X11/Xsession.options"
  fi
  update-alternatives --set x-session-manager "$XRDP_SESSION_BIN" >/dev/null 2>&1 || true
  ok "RDP sessions will launch: $(basename "$XRDP_SESSION_BIN") (for $TARGET_USER and, by default, everyone)"

  # --- 4a. make it the default everywhere, not just for xrdp -----------------
  # A display manager does not consult x-session-manager; it reads the user's
  # AccountsService record. Set that too, so if anyone ever boots this box to a
  # graphical target they still land in XFCE rather than GNOME.
  XSESSION_NAME=""
  for _s in /usr/share/xsessions/*.desktop; do
    [ -f "$_s" ] || continue
    case "$(basename "$_s" .desktop)" in
      xfce|xfce4|xubuntu) XSESSION_NAME="$(basename "$_s" .desktop)"; break ;;
    esac
  done
  case "$XRDP_SESSION_BIN" in
    */xfce4-session) : ;;
    *) XSESSION_NAME="" ;;      # only claim the default for the desktop we chose
  esac
  # xfce4-session ships /usr/share/xsessions/xfce.desktop, but do not depend on
  # having found it: if that file is missing the display manager would be left
  # with no session default at all and would start whatever sorts first, which
  # on a box that also has GNOME is not XFCE. A name a DM cannot resolve is
  # ignored, so guessing here is strictly better than leaving it empty.
  if [ -z "$XSESSION_NAME" ]; then
    case "$XRDP_SESSION_BIN" in */xfce4-session) XSESSION_NAME="xfce" ;; esac
  fi
  if [ -n "$XSESSION_NAME" ]; then
    install -d -m 0755 /var/lib/AccountsService/users
    AS_FILE="/var/lib/AccountsService/users/$TARGET_USER"
    if [ ! -f "$AS_FILE" ]; then
      printf '[User]\nSession=%s\nXSession=%s\n' "$XSESSION_NAME" "$XSESSION_NAME" > "$AS_FILE"
      chmod 0600 "$AS_FILE"
    else
      grep -qE '^\[User\]' "$AS_FILE" || printf '[User]\n' >> "$AS_FILE"
      for _k in Session XSession; do
        if grep -qE "^${_k}=" "$AS_FILE"; then
          sed -i -E "s|^${_k}=.*|${_k}=${XSESSION_NAME}|" "$AS_FILE"
        else
          printf '%s=%s\n' "$_k" "$XSESSION_NAME" >> "$AS_FILE"
        fi
      done
    fi
    ok "$TARGET_USER's default session is '$XSESSION_NAME' (AccountsService)"
  fi

  # --- 4b. no desktop compositor ---------------------------------------------
  # xfwm4's compositor is an OpenGL client. On Strix Halo that means it takes a
  # slice of the same GTT memory vLLM allocates from, to composite a screen that
  # is being scraped and sent over RDP anyway. Written as an xfconf channel
  # default, which applies to users who have no xfwm4.xml of their own yet.
  if [ "$XFCE_COMPOSITING" != "1" ]; then
    install -d -m 0755 /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
    cat > /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml <<'XFWM'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Managed by setup-strixhalo-ai-server.sh -->
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
XFWM
    chmod 0644 /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml
    ok "XFCE compositing disabled by default (the desktop stops being a GL client)"
    _user_xfwm="$USER_HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
    if [ -f "$_user_xfwm" ] && grep -E 'use_compositing.*value="true"' "$_user_xfwm" >/dev/null 2>&1; then
      warn "$TARGET_USER already has compositing ON in their own xfwm4.xml; that file wins."
      note_action "Turn XFCE compositing off for $TARGET_USER on $MY_HOST: xfconf-query -c xfwm4 -p /general/use_compositing -s false"
    fi
  fi

  # --- 4c. what the console does at boot -------------------------------------
  # 'graphical.target' by itself is NOT enough. It only means "start whatever
  # display-manager.service points at", and a server install has no display
  # manager at all - so the box boots to the exact text login the operator was
  # trying to get away from. A DM therefore has to exist before the target is
  # switched, and the switch only happens once that is true.
  DM_UNIT=""
  if [ -L /etc/systemd/system/display-manager.service ]; then
    DM_UNIT="$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" 2>/dev/null)"
  fi

  if [ "$DESKTOP_HEADLESS_BOOT" = "1" ]; then
    # Headless: the desktop exists only while an RDP session does, so nothing
    # holds GTT memory - the same memory vLLM and ComfyUI allocate from - while
    # nobody is connected. Deliberately NOT applied with --now: the operator may
    # be running this script from a terminal inside that very session.
    _cur_target="$(systemctl get-default 2>/dev/null || echo unknown)"
    if [ "$_cur_target" = "multi-user.target" ]; then
      ok "already boots to a text login (multi-user.target)"
    elif systemctl set-default multi-user.target >/dev/null 2>&1; then
      ok "default boot target is now multi-user.target (was $_cur_target)"
      [ -n "$DM_UNIT" ] && ok "  ${DM_UNIT%.service} will no longer start at boot; connect over RDP instead"
      warn "  this takes effect at the next reboot; the current session is untouched"
      warn "  to get the local desktop back: sudo systemctl set-default graphical.target"
    else
      warn "could not change the default boot target; a desktop may keep running on the console"
    fi
  else
    # Graphical: give the console a real login screen that lands in XFCE.
    if [ -z "$DM_UNIT" ]; then
      log "  no display manager installed - adding LightDM so the console can show a desktop"
      # LightDM, not GDM: the GDM greeter is a full compositing GL client and
      # would sit on iGPU memory at the login screen, before anyone logs in.
      # Preseed the "which display manager?" debconf prompt, which is the one
      # question in this whole script that can otherwise block on a tty.
      if command -v debconf-set-selections >/dev/null 2>&1; then
        echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections || true
      fi
      if apt-get install -y lightdm lightdm-gtk-greeter >/dev/null 2>&1; then
        DM_UNIT="lightdm.service"
        ok "lightdm $(dpkg-query -W -f='${Version}' lightdm 2>/dev/null) installed"
      else
        warn "could not install lightdm - the console will stay at a text login"
        note_action "Install a display manager on $MY_HOST so it boots to the desktop: sudo apt-get install -y lightdm lightdm-gtk-greeter && sudo systemctl set-default graphical.target"
      fi
    else
      ok "reusing the display manager already installed: ${DM_UNIT%.service}"
    fi

    if [ -n "$DM_UNIT" ]; then
      # Both of these matter. /etc/X11/default-display-manager is what the
      # postinst reads on every DM package upgrade; the systemd symlink is what
      # graphical.target actually follows. A mismatch means an apt upgrade
      # silently swaps the DM back.
      if [ "$DM_UNIT" = "lightdm.service" ]; then
        echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
        # LightDM picks the session from AccountsService (set in 4a) and falls
        # back to this when a user has no record yet - e.g. any account created
        # after this script ran.
        if [ -n "$XSESSION_NAME" ]; then
          install -d -m 0755 /etc/lightdm/lightdm.conf.d
          cat > /etc/lightdm/lightdm.conf.d/60-strixhalo-session.conf <<LIGHTDM
# Managed by $SCRIPT_NAME - log into XFCE, not whatever sorts first
[Seat:*]
user-session=$XSESSION_NAME
LIGHTDM
          chmod 0644 /etc/lightdm/lightdm.conf.d/60-strixhalo-session.conf
          ok "lightdm will start the '$XSESSION_NAME' session"
        fi
      fi
      systemctl enable "$DM_UNIT" >/dev/null 2>&1 || true
      # graphical.target starts display-manager.service, so that symlink is
      # what actually decides whether a desktop appears. Debian packages create
      # it in their postinst; create it ourselves if it is somehow missing,
      # because 'systemctl enable gdm' does NOT do it (gdm's only [Install]
      # directive is Alias=, which is exactly this symlink).
      if [ ! -L /etc/systemd/system/display-manager.service ]; then
        ln -sfn "/lib/systemd/system/$DM_UNIT" /etc/systemd/system/display-manager.service 2>/dev/null || true
        [ -L /etc/systemd/system/display-manager.service ] \
          && ok "  display-manager.service now points at ${DM_UNIT%.service}"
      fi

      _cur_target="$(systemctl get-default 2>/dev/null || echo unknown)"
      if [ "$_cur_target" = "graphical.target" ]; then
        ok "already boots to the desktop (graphical.target -> ${DM_UNIT%.service})"
      elif systemctl set-default graphical.target >/dev/null 2>&1; then
        ok "default boot target is now graphical.target (was $_cur_target)"
        ok "  ${DM_UNIT%.service} will show a login screen on the console at boot"
      else
        warn "could not change the default boot target; the console will stay at a text login"
        note_action "Set $MY_HOST to boot into the desktop: sudo systemctl set-default graphical.target"
      fi
      # Not started with --now on purpose: switching to graphical.target right
      # now would take over the tty this script is probably running on.
      warn "  this takes effect at the next reboot; the current session is untouched"
      warn "  a desktop on the console holds iGPU memory that vLLM could use;"
      warn "  re-run with --headless-boot to give that back"
    fi
  fi

  # --- 5. no password pop-ups on every RDP login -----------------------------
  # colord asks to "create a colour managed device" for every non-local session.
  # Ubuntu 26.04 ships polkit >= 123, which reads JavaScript rules from
  # /etc/polkit-1/rules.d and IGNORES the old .pkla files most guides still show.
  install -d -m 0755 /etc/polkit-1/rules.d
  cat > /etc/polkit-1/rules.d/49-xrdp-no-password-prompts.rules <<'POLKIT'
// Managed by setup-strixhalo-ai-server.sh
// An xrdp session is not a local seat, so polkit downgrades it to "inactive"
// and colord prompts for a password on every single login. Allow exactly the
// six colour-management actions that cause it; nothing else is relaxed, and
// future colord actions are NOT covered by this rule on purpose.
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
  ok "polkit rule installed (no colord password prompt on RDP login)"

  # --- 6. listen port + auto-start on boot -----------------------------------
  # Always rewrite the port (not just when it differs from 3389) so re-running
  # with a changed - or restored - XRDP_PORT actually converges.
  if [ -f /etc/xrdp/xrdp.ini ]; then
    if grep -qE '^port=' /etc/xrdp/xrdp.ini; then
      sed -i -E "0,/^port=.*/s//port=$XRDP_PORT/" /etc/xrdp/xrdp.ini
    else
      sed -i -E "0,/^\[Globals\]/s//[Globals]\nport=$XRDP_PORT/" /etc/xrdp/xrdp.ini
    fi
    ok "xrdp.ini listen port set to $XRDP_PORT"
  fi
  systemctl enable xrdp.service xrdp-sesman.service >/dev/null 2>&1 \
    && ok "xrdp + xrdp-sesman enabled (auto-start on boot)" \
    || warn "could not enable the xrdp units - check 'systemctl status xrdp'"
  systemctl restart xrdp-sesman.service >/dev/null 2>&1 || true
  systemctl restart xrdp.service >/dev/null 2>&1 || true
  if systemctl is-active --quiet xrdp.service; then
    ok "xrdp is running and listening on $XRDP_PORT"
  else
    warn "xrdp is not active yet - see 'systemctl status xrdp' and /var/log/xrdp.log"
  fi
  echo
fi

# =============================================================================
# 12. SSH TRUST BETWEEN THE NODES  (optional, --ssh-trust)
# =============================================================================
# Not required by anything above: Ray, NFS and residencyd all talk over their
# own protocols. It exists because operating a two-box cluster without
# passwordless 'ssh peer' is tedious, and because the verify script can then
# check the far side for you.
if [ "$SSH_TRUST" = "1" ]; then
  log "Setting up SSH trust with $OTHER_HOST ($CLUSTER_PEER_IP)"
  _sshdir="$USER_HOME/.ssh"
  install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_USER" "$_sshdir"
  if [ ! -f "$_sshdir/id_ed25519" ]; then
    as_user "ssh-keygen -t ed25519 -N '' -C '${TARGET_USER}@${MY_HOST}-cluster' -f '$_sshdir/id_ed25519'" \
      && ok "generated $_sshdir/id_ed25519" \
      || warn "ssh-keygen failed"
  else
    ok "$_sshdir/id_ed25519 already exists"
  fi
  # Pre-trust the peer's host key over the USB4 address so the first automated
  # ssh does not stop on an interactive fingerprint prompt. This is a private
  # point-to-point cable with exactly one machine on the far end, so TOFU here
  # is not the risk it would be on a routed network.
  if [ -f "$_sshdir/id_ed25519.pub" ]; then
    touch "$_sshdir/known_hosts"; chown "$TARGET_USER:$TARGET_USER" "$_sshdir/known_hosts"
    chmod 0600 "$_sshdir/known_hosts"
    if ssh-keyscan -T 5 -H "$CLUSTER_PEER_IP" 2>/dev/null | grep . >> "$_sshdir/known_hosts"; then
      sort -u -o "$_sshdir/known_hosts" "$_sshdir/known_hosts"
      chown "$TARGET_USER:$TARGET_USER" "$_sshdir/known_hosts"
      ok "recorded $OTHER_HOST's host key ($CLUSTER_PEER_IP)"
    else
      warn "$OTHER_HOST is not reachable at $CLUSTER_PEER_IP yet - skipping its host key"
    fi
    note_action "SSH trust: run this ONCE, from either node, to finish the exchange in both directions:  ssh-copy-id -i $_sshdir/id_ed25519.pub ${TARGET_USER}@${OTHER_HOST}"
  fi
  echo
fi

# =============================================================================
# 13. FIREWALL  (LAN gets the front doors; the USB4 cable gets everything else)
# =============================================================================
# The split matters. Ray's GCS, the per-model vLLM ports, NFS and the residency
# agent are all UNAUTHENTICATED -- they assume a trusted wire. That wire is the
# USB4 cable, so they are reachable ONLY on $CLUSTER_IFACE, from exactly one
# address. The house LAN sees only the deliberate front doors:
#     ssh, RDP, ComfyUI          on both nodes
#     llm-gateway, Open WebUI    on the server
# Note that ufw rules are scoped by INTERFACE as well as source address, so an
# attacker spoofing 10.44.0.2 from the LAN side still gets dropped.
if [ "$CONFIGURE_FIREWALL" = "1" ]; then
  log "Configuring the ufw firewall"
  apt-get install -y ufw >/dev/null 2>&1 || true
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true

  # Ports this node offers to the house LAN.
  FW_PORTS=""
  FW_UDP_PORTS=""
  [ "$INSTALL_COMFYUI" = "1" ] && FW_PORTS="$FW_PORTS $COMFYUI_PORT"
  [ "$INSTALL_XRDP"    = "1" ] && FW_PORTS="$FW_PORTS $XRDP_PORT"
  if [ "$INSTALL_SAMBA" = "1" ]; then
    # 445 is SMB itself. 139+137/138 are NetBIOS, which is what makes
    # \\hostname resolve from Windows without a DNS record or a hosts entry -
    # on a maintenance share that is the difference between usable and not.
    FW_PORTS="$FW_PORTS 445 139"
    FW_UDP_PORTS="$FW_UDP_PORTS 137 138"
    # WS-Discovery: only opened when wsdd is actually running, so a node that
    # could not install it does not carry two pointless open ports.
    if [ "${SAMBA_DISCOVERY_ON:-0}" = "1" ]; then
      FW_PORTS="$FW_PORTS 5357"
      FW_UDP_PORTS="$FW_UDP_PORTS 3702"
    fi
  fi
  if [ "$IS_SERVER" = "1" ]; then
    [ "$INSTALL_GATEWAY" = "1" ] && FW_PORTS="$FW_PORTS $GATEWAY_PORT"
    [ "$INSTALL_WEBUI"   = "1" ] && FW_PORTS="$FW_PORTS $WEBUI_PORT"
  fi
  FW_PORTS="$(echo "$FW_PORTS" | xargs 2>/dev/null || echo "$FW_PORTS")"
  FW_UDP_PORTS="$(echo "$FW_UDP_PORTS" | xargs 2>/dev/null || echo "$FW_UDP_PORTS")"
  for net in $LAN_NETS; do
    for port in $FW_PORTS; do
      ufw allow from "$net" to any port "$port" proto tcp >/dev/null 2>&1 || true
    done
    for port in $FW_UDP_PORTS; do
      ufw allow from "$net" to any port "$port" proto udp >/dev/null 2>&1 || true
    done
  done

  # One rule covers the entire cluster-internal surface: Ray GCS + worker ports,
  # every vLLM instance, NFSv4, the residency agent. Adding services later needs
  # no firewall change, and nothing here is ever exposed to the LAN.
  if [ "$INSTALL_CLUSTER" = "1" ] && [ -n "${CLUSTER_PEER_IP:-}" ]; then
    ufw allow in on "$CLUSTER_IFACE" from "$CLUSTER_PEER_IP" >/dev/null 2>&1 \
      && ok "ufw: $OTHER_HOST ($CLUSTER_PEER_IP) allowed in on $CLUSTER_IFACE only" \
      || warn "could not add the ufw rule for the cluster interface '$CLUSTER_IFACE'"
  fi

  yes | ufw enable >/dev/null 2>&1 || true
  # Never report success blindly: RDP is a full login shell and the gateway
  # front-ends every model on the cluster. If ufw is not actually active, or
  # still defaults to allowing incoming traffic, the operator has to know.
  fw_state="$(ufw status verbose 2>/dev/null || true)"
  if grep '^Status: active' <<<"$fw_state" >/dev/null; then
    ok "ufw active: ssh + ports $(echo "$FW_PORTS" | tr ' ' '/') from private LAN ranges"
    if ! grep 'deny (incoming)' <<<"$fw_state" >/dev/null; then
      warn "ufw's default incoming policy is NOT 'deny' - the rules above restrict nothing."
      warn "  Fix with:  sudo ufw default deny incoming && sudo ufw reload"
      note_action "ufw default incoming policy is not 'deny'. Run: sudo ufw default deny incoming && sudo ufw reload"
    fi
    if [ "$INSTALL_XRDP" = "1" ] && ! grep -E "(^|[[:space:]])${XRDP_PORT}/tcp[[:space:]]+ALLOW IN" <<<"$fw_state" >/dev/null; then
      warn "no ufw ALLOW rule for RDP port $XRDP_PORT - remote desktop will be unreachable from the LAN"
    fi
    if [ "$INSTALL_SAMBA" = "1" ] && ! grep -E "(^|[[:space:]])445/tcp[[:space:]]+ALLOW IN" <<<"$fw_state" >/dev/null; then
      warn "no ufw ALLOW rule for SMB port 445 - the '$XFER_SHARE' share will be unreachable from Windows"
    fi
    if [ "$IS_SERVER" = "1" ] && [ "$INSTALL_GATEWAY" = "1" ] \
       && ! grep -E "(^|[[:space:]])${GATEWAY_PORT}/tcp[[:space:]]+ALLOW IN" <<<"$fw_state" >/dev/null; then
      warn "no ufw ALLOW rule for gateway port $GATEWAY_PORT - the API will be unreachable from the LAN"
    fi
  else
    warn "ufw is NOT active: every port above is reachable from anywhere this host is routable."
    warn "  Enable it with:  sudo ufw default deny incoming && sudo ufw enable"
    note_action "ufw is not active. Run: sudo ufw default deny incoming && sudo ufw enable"
  fi
  echo
fi

# =============================================================================
# 14. START SERVICES, THEN SUMMARY
# =============================================================================
# Order matters and mirrors the boot dependency chain: the cable first, then the
# shared storage, then Ray, then the control plane, then the front doors. Every
# start is non-fatal -- a service that needs the reboot (ROCm's new TTM limit,
# the render group on $TARGET_USER) is expected to fail here and come up clean
# afterwards, and that is not a reason to abort a successful install.
log "Starting services"

# Record what this run actually installed. Without this the verifier cannot tell
# "XRDP is broken" from "XRDP was never asked for", and reports a wall of
# failures for components the operator deliberately skipped.
install -d -m 0755 "$LLM_ETC"
cat > "$LLM_ETC/components.env" <<EOF
# Managed by setup-strixhalo-ai-server.sh -- what this node was provisioned with.
# Read by verify-and-seed-strixhalo-ai-server.sh so skipped sections are
# reported as SKIP rather than FAIL.
# The desktop/service account this node was provisioned for. Recorded so the
# verify script never has to guess it from logname/id, which returns something
# useless in a non-login shell and then silently checks '/home//...'.
TARGET_USER=${TARGET_USER}
HF_TOOLS_VENV=${HF_TOOLS_VENV}
GATEWAY_VENV=${GATEWAY_VENV}
GATEWAY_USER=${GATEWAY_USER}
WEBUI_VENV=${WEBUI_VENV}
UV_PYTHON_DIR=${UV_PYTHON_DIR}
INSTALL_BASE=${INSTALL_BASE}
INSTALL_ROCM=${INSTALL_ROCM}
CONFIGURE_MEMORY=${CONFIGURE_MEMORY}
CONFIGURE_OOM_GUARD=${CONFIGURE_OOM_GUARD}
CONFIGURE_MODEL_GC=${CONFIGURE_MODEL_GC}
INSTALL_STORAGE=${INSTALL_STORAGE}
INSTALL_CLUSTER=${INSTALL_CLUSTER}
INSTALL_NFS=${INSTALL_NFS}
INSTALL_VLLM=${INSTALL_VLLM}
INSTALL_RESIDENCY=${INSTALL_RESIDENCY}
INSTALL_GATEWAY=${INSTALL_GATEWAY}
INSTALL_WEBUI=${INSTALL_WEBUI}
INSTALL_COMFYUI=${INSTALL_COMFYUI}
INSTALL_XRDP=${INSTALL_XRDP}
INSTALL_SAMBA=${INSTALL_SAMBA}
XFER_ROOT=${XFER_ROOT}
XFER_SHARE=${XFER_SHARE}
CONFIGURE_FIREWALL=${CONFIGURE_FIREWALL}
CONFIGURE_UPDATES=${CONFIGURE_UPDATES}
CONFIGURE_JOURNAL=${CONFIGURE_JOURNAL}
CONFIGURE_DISK_HEALTH=${CONFIGURE_DISK_HEALTH}
DISABLE_WIFI=${DISABLE_WIFI}
DISABLE_BLUETOOTH=${DISABLE_BLUETOOTH}
JOURNAL_MAX_USE=${JOURNAL_MAX_USE}
COMFY_CACHE_MODE=${COMFY_CACHE_MODE}
COMFY_RESERVE_VRAM=${COMFY_RESERVE_VRAM}
COMFY_ENABLE_ASSETS=${COMFY_ENABLE_ASSETS}
XRDP_DESKTOP=${XRDP_DESKTOP}
DESKTOP_HEADLESS_BOOT=${DESKTOP_HEADLESS_BOOT}
XFCE_COMPOSITING=${XFCE_COMPOSITING}
EOF
chmod 0644 "$LLM_ETC/components.env"

start_svc() {
  local unit="$1" label="${2:-$1}"
  if [ ! -f "/etc/systemd/system/$unit" ] && ! systemctl list-unit-files "$unit" >/dev/null 2>&1; then
    return 0
  fi
  # --no-block matters more than it looks. A plain 'systemctl start' waits for
  # the whole job to finish, and several of these units deliberately wait on
  # things that take minutes: llm-runtime may still be pulling a multi-gigabyte
  # ROCm image (TimeoutStartSec=900), and ray-head/ray-worker then wait for that
  # container and for the USB4 peer. Blocking on that makes the script sit
  # silently for a quarter of an hour, which is indistinguishable from a hang.
  # Queue the job, watch it briefly, and report what it is actually doing.
  if systemctl start --no-block "$unit" >/dev/null 2>&1; then
    # 'systemctl start' also returns as soon as the unit is forked for a
    # Type=simple service, so it says "started" for a unit whose process died on
    # the first instruction. Look again before claiming success: reporting six
    # healthy services when two of them are dead is worse than saying nothing.
    local _i=0 _st
    while [ "$_i" -lt 10 ]; do
      _st="$(systemctl is-active "$unit" 2>/dev/null || echo unknown)"
      case "$_st" in active|failed) break ;; esac
      sleep 1; _i=$((_i+1))
    done
    case "$_st" in
      failed)
        warn "$label failed immediately after starting:"
        { systemctl status "$unit" --no-pager -n 6 2>&1 || true; } \
          | sed 's/^/       /' | head -10 || true
        note_action "$label ($unit) is not running on $MY_HOST. Check: systemctl status $unit" ;;
      activating)
        ok "$label starting (still coming up)" ;;
      inactive|unknown)
        # Either the job is still queued behind a dependency that is itself
        # starting, or the job was dropped (a BindsTo= device that is not there,
        # for instance). Those need different words, so ask which it is.
        if { systemctl list-jobs "$unit" 2>/dev/null || true; } | grep "$unit" >/dev/null; then
          ok "$label queued (waiting on a dependency that is still starting)"
        else
          warn "$label did not start (check: systemctl status $unit)"
          note_action "$label ($unit) is not running on $MY_HOST. Check: systemctl status $unit"
        fi ;;
      *)
        ok "$label started" ;;
    esac
  else
    warn "$label did not start yet (usually fine before the reboot; check: systemctl status $unit)"
  fi
}

if [ "$IS_SERVER" = "1" ]; then
  [ "$INSTALL_NFS"       = "1" ] && start_svc nfs-server.service        "NFS server"      || true
  # Explicitly, and before Ray: on a first run this is the step that pulls the
  # image, and it is far better to see it named than to watch Ray sit "queued".
  [ "$INSTALL_VLLM"      = "1" ] && start_svc llm-runtime.service       "runtime container" || true
  [ "$INSTALL_VLLM"      = "1" ] && start_svc ray-head.service          "Ray head"        || true
  [ "$INSTALL_RESIDENCY" = "1" ] && start_svc residencyd.service        "residencyd"      || true
  [ "$INSTALL_GATEWAY"   = "1" ] && start_svc llm-gateway.service       "llm-gateway"     || true
  [ "$INSTALL_WEBUI"     = "1" ] && start_svc open-webui.service        "Open WebUI"      || true
else
  [ "$INSTALL_VLLM"      = "1" ] && start_svc llm-runtime.service       "runtime container" || true
  [ "$INSTALL_VLLM"      = "1" ] && start_svc ray-worker.service        "Ray worker"      || true
  [ "$INSTALL_RESIDENCY" = "1" ] && start_svc residency-agent.service   "residency-agent" || true
fi
[ "$INSTALL_COMFYUI" = "1" ] && start_svc comfyui.service "ComfyUI" || true
echo

# =============================================================================
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
[ -n "$LAN_IP" ] || LAN_IP="$MY_HOST"

echo "${GRN}${BOLD}=============================================================${RST}"
echo "${GRN}${BOLD}  ${MY_HOST} is provisioned as the ${NODE_ROLE^^} node${RST}"
echo "${GRN}${BOLD}=============================================================${RST}"
echo
echo "${BOLD}This node${RST}"
echo "  hostname / role : $MY_HOST  ($NODE_ROLE)"
echo "  cluster peer    : $OTHER_HOST at $CLUSTER_PEER_IP"
echo "  USB4 link       : $CLUSTER_IFACE  $CLUSTER_LOCAL_IP/$CLUSTER_CIDR  (mtu $CLUSTER_MTU)"
echo "  LAN address     : $LAN_IP"
echo "  desktop user    : $TARGET_USER"
echo
echo "${BOLD}Use it from anywhere on the LAN${RST}"
if [ "$IS_SERVER" = "1" ]; then
  if [ "$INSTALL_GATEWAY" = "1" ]; then
    echo "  LLM API (all models, both nodes)  http://$LAN_IP:$GATEWAY_PORT/v1"
  fi
  if [ "$INSTALL_WEBUI" = "1" ]; then
    echo "  Open WebUI  (chat in a browser)   http://$LAN_IP:$WEBUI_PORT/"
  fi
else
  echo "  LLM API is served by $SERVER_HOST, not this node:"
  echo "                                    http://$SERVER_HOST:$GATEWAY_PORT/v1"
fi
if [ "$INSTALL_COMFYUI" = "1" ]; then
  echo "  ComfyUI (this node)               http://$LAN_IP:$COMFYUI_PORT/"
  if [ "$COMFY_CACHE_MODE" = "ram" ]; then
    echo "                                    cache bounded to ${COMFY_CACHE_ACTIVE_GB}G/${COMFY_CACHE_INACTIVE_GB}G so it cannot"
    echo "                                    grow into the memory vLLM is using"
  fi
fi
if [ "$INSTALL_XRDP" = "1" ]; then
  echo "  Remote desktop (RDP)              $LAN_IP:$XRDP_PORT"
  if [ "$DESKTOP_HEADLESS_BOOT" = "1" ]; then
    echo "                                    XFCE, started per connection - no desktop"
    echo "                                    runs on the console, so none of the iGPU's"
    echo "                                    memory is held while nobody is connected"
  else
    echo "                                    XFCE; the console also boots to a login"
    echo "                                    screen after the next reboot. --headless-boot"
    echo "                                    gives that iGPU memory back to vLLM."
  fi
fi
if [ "$INSTALL_SAMBA" = "1" ]; then
  echo "  File drop (Windows Explorer)      \\\\$LAN_IP\\$XFER_SHARE   ->  $XFER_ROOT"
  echo "                                    or \\\\$MY_HOST\\$XFER_SHARE - no sign-in"
  echo "                                    use this instead of the RDP clipboard, which"
  echo "                                    cannot copy files Windows -> Linux"
fi
echo
echo "${BOLD}Shared storage${RST}"
if [ "$IS_SERVER" = "1" ]; then
  echo "  $LLM_ROOT     authoritative LLM repository, exported read-only to $PEER_HOST"
  echo "  $COMFY_ROOT    shared ComfyUI store, exported read-write to $PEER_HOST"
  echo "                    (models, input, output, workflows, hf - download once, use on both)"
else
  echo "  $LLM_ROOT     read-only NFS mount from $SERVER_HOST"
  echo "  $COMFY_ROOT    read-write NFS mount from $SERVER_HOST"
  echo "  $LLM_LOCAL_CACHE  local scratch: Ray spill, compile cache, HF hub"
fi
[ "$INSTALL_SAMBA" = "1" ] && echo "  $XFER_ROOT        maintenance drop folder, shared to Windows as '$XFER_SHARE'"
echo
echo "${BOLD}Unattended maintenance${RST}"
if [ "$CONFIGURE_UPDATES" = "1" ]; then
  echo "  security updates  applied automatically; kernel + ROCm are held back"
  echo "                    (never reboots itself - watch /var/run/reboot-required)"
fi
[ "$CONFIGURE_JOURNAL"     = "1" ] && echo "  logs              capped at $JOURNAL_MAX_USE  (journalctl --disk-usage)"
[ "$CONFIGURE_DISK_HEALTH" = "1" ] && echo "  disks             smartd monitoring + weekly fstrim.timer"
if [ "$DISABLE_WIFI" = "1" ] || [ "$DISABLE_BLUETOOTH" = "1" ]; then
  echo "  radios            Wi-Fi/Bluetooth blocked in /etc/modprobe.d - turn the"
  echo "                    WLAN+BT module off in the BIOS too"
fi
echo
echo "${BOLD}Day-to-day commands${RST}"
echo "  usb4-cluster-status              is the cable up, and is the peer reachable?"
echo "  llm-model list                   what is in the model catalog"
echo "  llm-model add --name X --path /srv/models/X [--placement auto|server|peer|distributed]"
echo "  llm-run ray status               both nodes should appear here"
echo "  systemctl status residencyd      what is resident, and why"
if [ "$IS_SERVER" = "1" ] && [ "$INSTALL_GATEWAY" = "1" ]; then
  echo "  curl -s localhost:$GATEWAY_PORT/cluster/catalog | python3 -m json.tool"
  echo "  http://$SERVER_HOST:$GATEWAY_PORT/dashboard    browser dashboard (monitor + unload/reload/add/delete)"
fi
echo
echo "${BOLD}How a request flows${RST}"
echo "  client -> llm-gateway:$GATEWAY_PORT -> residencyd -> vLLM (this box, the peer,"
echo "  or split across both). Nothing is loaded until something asks for it, and"
echo "  a model that will not fit is REFUSED with HTTP 409 rather than left hanging."
echo

if [ "${#ACTIONS[@]}" -gt 0 ]; then
  echo "${YLW}${BOLD}ACTION REQUIRED${RST}"
  for a in "${ACTIONS[@]}"; do
    echo "${YLW}  * ${RST}$a"
  done
  echo
fi

echo "${BOLD}Next steps${RST}"
echo "  1. Reboot. The TTM memory limit, the render/video group membership and the"
echo "     USB4 interface rename ALL need it - nothing works properly until you do."
if [ "$IS_SERVER" = "1" ]; then
  echo "  2. Run this same script on $PEER_HOST with the SAME arguments:"
  echo "        sudo ./$SCRIPT_NAME --server $SERVER_HOST --peer $PEER_HOST"
  echo "     It detects from its own hostname that it is the peer."
else
  echo "  2. Make sure $SERVER_HOST has been set up and rebooted too."
fi
echo "  3. Connect the USB4 cable between the two boxes (certified 40 Gbps"
echo "     USB4 / Thunderbolt 4 - a charging cable will NOT enumerate)."
echo "  4. Verify both nodes:"
echo "        sudo ./verify-and-seed-strixhalo-ai-server.sh --server $SERVER_HOST --peer $PEER_HOST"
echo "  5. Add a model on $SERVER_HOST and ask for it through the gateway."
echo

# systemd refuses a reboot while any session holds a delay/block inhibitor, and
# a desktop session always holds one ("user session inhibited"). It also refuses
# while another user is logged in on another tty. Both are true on a freshly
# installed box that the operator is sitting in front of, so a plain
# 'systemctl reboot' fails here on the very first run.
#
# That refusal is not a provisioning failure: everything above already
# succeeded, and the operator has explicitly asked for the reboot. Letting the
# ERR trap fire on it turns a complete, successful run into "ERROR: failed at
# line ...", which is exactly what it must not do.
do_reboot() {
  if systemctl reboot; then
    return 0
  fi
  echo
  warn "systemd refused the reboot. What is holding it:"
  systemd-inhibit --list 2>/dev/null | sed 's/^/       /' || true
  who 2>/dev/null | sed 's/^/       /' || true
  warn "overriding, because the reboot was explicitly requested."
  if systemctl reboot -i; then
    return 0
  fi
  echo
  warn "systemd still refused to reboot."
  warn "Provisioning itself finished; only the reboot did not happen."
  warn "Reboot by hand before expecting any of this to work:"
  warn "    sudo systemctl reboot -i"
  return 0
}

if [ "$ASSUME_YES" = "1" ]; then
  log "Rebooting now (--yes)"
  sleep 3
  do_reboot
else
  printf '%s' "Reboot now? [y/N] "
  read -r _ans || _ans=""
  case "$_ans" in
    [yY]|[yY][eE][sS]) log "Rebooting"; sleep 2; do_reboot ;;
    *) echo "Not rebooting. Remember: 'sudo reboot' before expecting any of this to work." ;;
  esac
fi

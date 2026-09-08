#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESIDENCY_LIB="${RESIDENCY_LIB:-/usr/local/lib/llm-cluster}"
SOURCE_DIR="${1:-$SCRIPT_DIR}"

usage() {
  cat <<'EOF'
Usage: sudo bash ./restart-residency.sh [source-directory]

Install residencyd.py and residency-agent.py into RESIDENCY_LIB and restart
the installed residency service(s) only. The optional source-directory argument
is only needed when the two Python files are stored somewhere other than this
script's directory. RESIDENCY_LIB defaults to /usr/local/lib/llm-cluster.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "error: run this helper with sudo" >&2
  exit 1
fi
if [ ! -d "$SOURCE_DIR" ]; then
  echo "error: residency source directory does not exist: $SOURCE_DIR" >&2
  exit 1
fi

units=()
for unit in residencyd.service residency-agent.service; do
  fragment="$(systemctl show -p FragmentPath --value "$unit" 2>/dev/null || true)"
  if [ -n "$fragment" ] && [ "$fragment" != "/dev/null" ] && [ -f "$fragment" ]; then
    units+=("$unit")
  fi
done
if [ "${#units[@]}" -eq 0 ]; then
  echo "error: no installed residencyd.service or residency-agent.service unit was found" >&2
  exit 1
fi

if ! systemctl daemon-reload; then
  echo "error: systemd could not reload unit files; residency services were not restarted" >&2
  exit 1
fi

for source in residencyd.py residency-agent.py; do
  if [ ! -f "$SOURCE_DIR/$source" ]; then
    echo "error: residency source is missing: $SOURCE_DIR/$source" >&2
    exit 1
  fi
done
if ! install -d -m 0755 "$RESIDENCY_LIB"; then
  echo "error: could not create residency library directory: $RESIDENCY_LIB" >&2
  exit 1
fi

tmpdir="$(mktemp -d "$RESIDENCY_LIB/.residency-restart.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

for source in residencyd.py residency-agent.py; do
  if ! install -m 0755 "$SOURCE_DIR/$source" "$tmpdir/$source"; then
    echo "error: could not stage $SOURCE_DIR/$source" >&2
    exit 1
  fi
done
for source in residencyd.py residency-agent.py; do
  if ! mv -f "$tmpdir/$source" "$RESIDENCY_LIB/$source"; then
    echo "error: could not atomically install $RESIDENCY_LIB/$source" >&2
    exit 1
  fi
done

failed=0
for unit in "${units[@]}"; do
  if ! systemctl restart "$unit"; then
    echo "error: $unit failed to restart" >&2
    systemctl --no-pager --full status "$unit" || true
    failed=1
    continue
  fi
  if ! systemctl is-active --quiet "$unit"; then
    echo "error: $unit is not active after restart" >&2
    systemctl --no-pager --full status "$unit" || true
    failed=1
    continue
  fi
  echo "$unit restarted successfully (source installed in $RESIDENCY_LIB)"
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi

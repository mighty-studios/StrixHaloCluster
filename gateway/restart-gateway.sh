#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_VENV="${GATEWAY_VENV:-/opt/llm-gateway}"
SOURCE="${GATEWAY_SOURCE:-$SCRIPT_DIR/app.py}"

usage() {
  cat <<'EOF'
Usage: sudo bash ./restart-gateway.sh [app.py]

Install an updated app.py into the llm-gateway virtualenv and restart only
llm-gateway.service. GATEWAY_VENV defaults to /opt/llm-gateway.
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
if [ "$#" -eq 1 ]; then
  SOURCE="$1"
fi
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "error: run this helper with sudo" >&2
  exit 1
fi
if [ ! -f "$SOURCE" ]; then
  echo "error: gateway source does not exist: $SOURCE" >&2
  exit 1
fi
if [ ! -d "$GATEWAY_VENV" ]; then
  echo "error: gateway virtualenv does not exist: $GATEWAY_VENV" >&2
  exit 1
fi

fragment="$(systemctl show -p FragmentPath --value llm-gateway.service 2>/dev/null || true)"
if [ -z "$fragment" ] || [ "$fragment" = "/dev/null" ] || [ ! -f "$fragment" ]; then
  echo "error: no installed llm-gateway.service unit was found" >&2
  exit 1
fi

DEST="$GATEWAY_VENV/app.py"
tmp="$(mktemp "$GATEWAY_VENV/.app.py.XXXXXX")"
cleanup() {
  rm -f "$tmp"
}
trap cleanup EXIT

if ! install -m 0644 "$SOURCE" "$tmp"; then
  echo "error: could not stage $SOURCE in $GATEWAY_VENV" >&2
  exit 1
fi
if ! mv -f "$tmp" "$DEST"; then
  echo "error: could not install $DEST" >&2
  exit 1
fi
trap - EXIT

if ! systemctl restart llm-gateway.service; then
  echo "error: app.py installed, but llm-gateway.service failed to restart" >&2
  systemctl --no-pager --full status llm-gateway.service || true
  exit 1
fi
if ! systemctl is-active --quiet llm-gateway.service; then
  echo "error: app.py installed, but llm-gateway.service is not active" >&2
  systemctl --no-pager --full status llm-gateway.service || true
  exit 1
fi

echo "gateway app.py installed at $DEST; llm-gateway.service restarted successfully"

#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${LLM_PROFILE_DEST:-/usr/local/bin/llm-profile}"
SOURCE="${LLM_PROFILE_SOURCE:-$SCRIPT_DIR/llm-profile.py}"

usage() {
  cat <<'EOF'
Usage: sudo bash ./update-llm-profile.sh [llm-profile.py]

Install an updated llm-profile.py as /usr/local/bin/llm-profile. The
destination can be overridden with LLM_PROFILE_DEST; no service is restarted.
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
case "$DEST" in
  /*) ;;
  *)
    echo "error: llm-profile destination must be an absolute path: $DEST" >&2
    exit 1
    ;;
esac
if [ ! -f "$SOURCE" ]; then
  echo "error: llm-profile source does not exist: $SOURCE" >&2
  exit 1
fi

dest_dir="$(dirname "$DEST")"
if [ ! -d "$dest_dir" ]; then
  echo "error: llm-profile destination directory does not exist: $dest_dir" >&2
  exit 1
fi

tmp="$(mktemp "$dest_dir/.llm-profile.XXXXXX")"
cleanup() {
  rm -f "$tmp"
}
trap cleanup EXIT

if ! install -m 0755 "$SOURCE" "$tmp"; then
  echo "error: could not stage $SOURCE in $dest_dir" >&2
  exit 1
fi
if ! mv -f "$tmp" "$DEST"; then
  echo "error: could not install $DEST" >&2
  exit 1
fi
trap - EXIT

echo "llm-profile installed at $DEST; no service restart was needed"

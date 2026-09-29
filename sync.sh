#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_dotenv_defaults() {
  local file="$ROOT_DIR/.env" line key value
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(REMOTE_HOST|REMOTE_DIR)[[:space:]]*= ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${line#*=}"
    value="${value##[[:space:]]}"
    value="${value%%[[:space:]]}"
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then value="${value:1:${#value}-2}"; fi
    if [[ "$value" == \'*\' && "$value" == *\' ]]; then value="${value:1:${#value}-2}"; fi
    if [[ "$key" == REMOTE_HOST && -z "${REMOTE_HOST:-}" ]]; then REMOTE_HOST="$value"; fi
    if [[ "$key" == REMOTE_DIR && -z "${REMOTE_DIR:-}" ]]; then REMOTE_DIR="$value"; fi
  done < "$file"
}

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_DIR="${REMOTE_DIR:-}"
load_dotenv_defaults

if [[ -z "$REMOTE_HOST" || -z "$REMOTE_DIR" ]]; then
  printf 'Set REMOTE_HOST and REMOTE_DIR before running sync.sh.\n' >&2
  exit 2
fi
command -v ssh >/dev/null 2>&1 || { printf 'Required command not found: ssh\n' >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { printf 'Required command not found: rsync\n' >&2; exit 1; }

printf '[sync] Preparing %s:%s.\n' "$REMOTE_HOST" "$REMOTE_DIR" >&2
quoted_remote_dir="$(printf '%q' "$REMOTE_DIR")"
# shellcheck disable=SC2029 # %q quotes the path before intentional remote expansion.
ssh "$REMOTE_HOST" "mkdir -p -- $quoted_remote_dir"

printf '[sync] Copying repository files from %s to %s:%s.\n' \
  "$ROOT_DIR" "$REMOTE_HOST" "$REMOTE_DIR" >&2
rsync -a --human-readable --itemize-changes \
  --exclude '/.git/' \
  --exclude '/.env' \
  --exclude '/.env.*' \
  --exclude '*.log' \
  "$ROOT_DIR/" "$REMOTE_HOST:$REMOTE_DIR/"

printf '[sync] Synchronization complete.\n' >&2

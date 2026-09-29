#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/dotenv.sh
source "$ROOT_DIR/scripts/dotenv.sh"

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_DIR="${REMOTE_DIR:-}"
load_dotenv_defaults "$ROOT_DIR/.env"

if [[ -z "$REMOTE_HOST" || -z "$REMOTE_DIR" ]]; then
  printf 'Set REMOTE_HOST and REMOTE_DIR before running sync.sh.\n' >&2
  exit 2
fi
command -v ssh >/dev/null 2>&1 || { printf 'Required command not found: ssh\n' >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { printf 'Required command not found: rsync\n' >&2; exit 1; }

SYNC_STEP="remote directory preparation"
sync_failed() {
  local status=$?
  printf '  ✗ Failed: %s (exit %d)\n' "$SYNC_STEP" "$status" >&2
  return "$status"
}
trap sync_failed ERR
printf '[sync 1/2] Prepare remote directory %s:%s.\n' "$REMOTE_HOST" "$REMOTE_DIR" >&2
printf '  → ssh %s mkdir -p %s\n' "$REMOTE_HOST" "$REMOTE_DIR" >&2
quoted_remote_dir="$(printf '%q' "$REMOTE_DIR")"
# shellcheck disable=SC2029 # %q quotes the path before intentional remote expansion.
ssh "$REMOTE_HOST" "mkdir -p -- $quoted_remote_dir"
printf '  ✓ Remote destination is ready.\n' >&2

SYNC_STEP="repository synchronization"
printf '[sync 2/2] Copy repository files while excluding local state and secrets.\n' >&2
printf '  → rsync repository to %s:%s (excluding .git, .env, dotenv variants, and logs)\n' \
  "$REMOTE_HOST" "$REMOTE_DIR" >&2
rsync -a --human-readable --itemize-changes \
  --exclude '/.git/' \
  --exclude '/.env' \
  --exclude '/.env.*' \
  --exclude '*.log' \
  "$ROOT_DIR/" "$REMOTE_HOST:$REMOTE_DIR/"
printf '  ✓ Repository synchronization complete.\n' >&2

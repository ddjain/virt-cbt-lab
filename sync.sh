#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./sync.sh [--pull-reports]

Without flags: push the repository to REMOTE_HOST:REMOTE_DIR (default).
--pull-reports: pull REMOTE_HOST:REMOTE_DIR/report/ back into ./report/
                (read-only on the remote; never touches REMOTE_DIR).
USAGE
}

MODE=push
case "${1:-}" in
  --pull-reports) MODE=pull-reports ;;
  --help|-h) usage; exit 0 ;;
  '') ;;
  *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

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

if [[ "$MODE" == pull-reports ]]; then
  SYNC_STEP="report pull"
  sync_failed() {
    local status=$?
    printf '  ✗ Failed: %s (exit %d)\n' "$SYNC_STEP" "$status" >&2
    return "$status"
  }
  trap sync_failed ERR
  printf '[sync] Pull %s:%s/report/ into %s/report/.\n' "$REMOTE_HOST" "$REMOTE_DIR" "$ROOT_DIR" >&2
  mkdir -p "$ROOT_DIR/report"
  rsync -a --human-readable --itemize-changes \
    "$REMOTE_HOST:$REMOTE_DIR/report/" "$ROOT_DIR/report/"
  printf '  ✓ Reports pulled to %s/report/.\n' "$ROOT_DIR" >&2
  exit 0
fi

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
printf '[sync 2/2] Copy repository files and Git metadata while excluding local secrets.\n' >&2
printf '  → rsync repository and .git to %s:%s (excluding .env, dotenv variants, and logs)\n' \
  "$REMOTE_HOST" "$REMOTE_DIR" >&2
rsync -a --human-readable --itemize-changes \
  --exclude '/.env' \
  --exclude '/.env.*' \
  --exclude '*.log' \
  "$ROOT_DIR/" "$REMOTE_HOST:$REMOTE_DIR/"
printf '  ✓ Repository synchronization complete.\n' >&2

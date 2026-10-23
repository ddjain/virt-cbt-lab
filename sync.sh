#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./sync.sh [--pull-reports [--scenario ID]]

Without flags: push the repository working tree to REMOTE_HOST:REMOTE_DIR.
The push excludes .env files, local credentials, and generated artifacts.
--pull-reports: pull complete report artifacts and verify every file with SHA-256.
--scenario ID: restrict to one v2 scenario, its diagnostics, referenced lifecycles
               and proposed-scenario documents. Without it, pull all root runs
               and all v2 scenario reports. Local conflicts are backed up;
               the remote is never modified. Pull needs Python3 on both hosts.
USAGE
}

MODE=push
SCENARIO="${SCENARIO:-}"
SCENARIO_OPTION=false
while (($#)); do
  case "$1" in
    --pull-reports) MODE=pull-reports; shift ;;
    --scenario)
      if [[ $# -lt 2 || -z "$2" ]]; then
        printf '%s\n' '--scenario requires a nonempty scenario ID.' >&2
        exit 2
      fi
      SCENARIO="$2"; SCENARIO_OPTION=true; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ "$SCENARIO_OPTION" == true && "$MODE" != pull-reports ]]; then
  printf '%s\n' '--scenario is only valid with --pull-reports.' >&2
  exit 2
fi

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
  command -v python3 >/dev/null 2>&1 || { printf 'Required command not found: python3\n' >&2; exit 1; }
  exec python3 "$ROOT_DIR/scripts/pull-reports.py" \
    --remote-host "$REMOTE_HOST" --remote-dir "$REMOTE_DIR" \
    --local-root "$ROOT_DIR" --scenario "$SCENARIO"
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
printf '[sync 2/2] Copy working files while excluding local credentials, generated data, and tooling state.\n' >&2
printf '  → rsync working files to %s:%s (credentials, environment, caches, and .git excluded)\n' \
  "$REMOTE_HOST" "$REMOTE_DIR" >&2
rsync -a --human-readable --itemize-changes \
  --exclude '/.env' \
  --include '/.env.example' \
  --exclude '/.env.*' \
  --exclude '*.log' \
  --exclude '.windows-admin-password' \
  --exclude 'kubeconfig' \
  --exclude '*.kubeconfig' \
  --exclude '.kube/' \
  --exclude '/.git/' \
  --exclude '/.DS_Store' \
  --exclude '/.idea/' \
  --exclude '/.vscode/' \
  --exclude '/.agents/' \
  --exclude '/.claude/' \
  --exclude '/.pi/' \
  --exclude '/.serena/' \
  --exclude '/.omp/' \
  --exclude '/skills-lock.json' \
  --exclude '/vm-cbt-demo/' \
  --exclude '/cbt-chaos/scenarios/*/runs/' \
  --exclude '/cbt-chaos/scenarios_v2/*/runs/' \
  --exclude '*.pem' \
  --exclude '*.key' \
  --exclude '*.p12' \
  --exclude '*.pfx' \
  --exclude 'id_rsa*' \
  --exclude 'id_ed25519*' \
  --exclude '*.iso' \
  --exclude '/keys/' \
  --exclude '/state/' \
  --exclude '/report/' \
  --exclude '/report-*.tar.gz' \
  --exclude '/logs/' \
  --exclude '/screenshot/' \
  --exclude '/tmp/' \
  --exclude '/runs/' \
  --exclude '/tmp-*/' \
  "$ROOT_DIR/" "$REMOTE_HOST:$REMOTE_DIR/"
printf '  ✓ Repository synchronization complete.\n' >&2

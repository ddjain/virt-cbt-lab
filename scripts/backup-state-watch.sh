#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# This script polls best-effort sources and treats missing objects as
# "not yet"; common.sh's ERR trap (armed at source time) would misreport
# those as workflow failures.
trap - ERR
WORKFLOW_NAME="backup-state-watch"

# Print one line per detected backup checkpoint so other processes can
# react to a backup's progress in near real time.
#
# Usage: backup-state-watch.sh <run-id> [checkpoint-name]
#   <run-id>            existing run whose backups to watch
#   [checkpoint-name]   print only this checkpoint and exit 0 once detected
#                       (default: print every checkpoint of every backup
#                       until all reach a terminal state)
#
# Only the source modules that can emit the requested checkpoint(s) are
# activated: full mode starts all five, one-shot mode starts just those
# covering the requested checkpoint.
#
# Checkpoints and their source module (scripts/backup-state-watch/):
#   vmbackup.sh:  BACKUP_INITIALIZING VOLUME_ATTACHING COPY_IN_PROGRESS
#                 CHECKPOINT_RECORDED BACKUP_COMPLETED BACKUP_FAILED
#                 BACKUP_TARGET_DETACHING
#   pvc.sh:       PVC_BOUND
#   events.sh:    HOTPLUG_POD_CREATED HOTPLUG_POD_DELETED VOLUME_MOUNTED
#                 VOLUME_UNMOUNTED
#   launcher.sh:  BACKUP_REQUESTED GUEST_FROZEN COPY_STARTED COPY_FINISHED_LOCAL
#   tracker.sh:   TRACKER_ADVANCED
#
# Environment:
#   WATCH_TIMEOUT_SECONDS   stop after N seconds (default 1800; 0 = unbounded)
#   WATCH_POLL_SECONDS      stream-scan interval (default 0.1)
#   WATCH_RAW_DIR           keep raw per-source stream records in this dir
#
# Detection is event-driven: oc watch streams write to local files and the
# poll loop only scans new lines, so checkpoint latency is bounded by
# WATCH_POLL_SECONDS plus watch delivery, not by sequential API round trips.
# Exit: 0 every watched backup reached a terminal state (or the requested
#         checkpoint fired); 1 bad usage or unreadable run state; 2 timeout.
usage() {
  printf 'Usage: %s <run-id> [checkpoint-name]\n' "$(basename "$0")" >&2
  printf 'Examples:\n' >&2
  printf '  %s 20261015-demo                      # print every checkpoint\n' "$(basename "$0")" >&2
  printf '  %s 20261015-demo COPY_IN_PROGRESS     # one-shot wait for one checkpoint\n' "$(basename "$0")" >&2
  printf '  WATCH_RAW_DIR=/tmp/w %s <run-id>      # keep raw stream records\n' "$(basename "$0")" >&2
  printf 'Checkpoints:\n' >&2
  printf '  BACKUP_REQUESTED PVC_BOUND HOTPLUG_POD_CREATED BACKUP_INITIALIZING\n' >&2
  printf '  VOLUME_ATTACHING VOLUME_MOUNTED GUEST_FROZEN COPY_STARTED\n' >&2
  printf '  COPY_IN_PROGRESS CHECKPOINT_RECORDED COPY_FINISHED_LOCAL\n' >&2
  printf '  BACKUP_COMPLETED BACKUP_FAILED BACKUP_TARGET_DETACHING\n' >&2
  printf '  VOLUME_UNMOUNTED HOTPLUG_POD_DELETED TRACKER_ADVANCED\n' >&2
  printf 'Full reference (source, trigger, timing): docs/vm-cbt-workflow.md\n' >&2
}

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup-state-watch"

if (($# < 1 || $# > 2)) || [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
  exit 1
fi

RUN_ID="$1"
WANT_CHECKPOINT="${2:-}"
if ! valid_run_id "$RUN_ID"; then
  printf 'Run ID %s does not match the expected pattern.\n' "$RUN_ID" >&2
  exit 1
fi

WATCH_TIMEOUT_SECONDS="${WATCH_TIMEOUT_SECONDS:-1800}"
WATCH_POLL_SECONDS="${WATCH_POLL_SECONDS:-0.1}"
WATCH_RAW_DIR="${WATCH_RAW_DIR:-}"
if ! [[ "$WATCH_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  printf 'WATCH_POLL_SECONDS must be a number.\n' >&2
  exit 1
fi

vm_info_path="$(vm_info_path "$RUN_ID")"
if [[ ! -r "$vm_info_path" ]]; then
  printf 'No lifecycle state for run %s at %s; run a backup stage first.\n' "$RUN_ID" "$vm_info_path" >&2
  exit 1
fi
NAMESPACE="$(jq -r '.namespace' "$vm_info_path")"
VM_NAME="$(jq -r '.vm_name' "$vm_info_path")"
set_resource_names

# --- Watch streams: every source is read-only and writes to local files. ---
STREAM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/backup-state-watch.XXXXXX")"
if [[ -n "$WATCH_RAW_DIR" ]]; then
  mkdir -p "$WATCH_RAW_DIR"
  STREAM_DIR="$WATCH_RAW_DIR"
fi
source "$MODULE_DIR/lib.sh"
trap cleanup_streams EXIT INT TERM
# Expected backup names are derived from the run identity, so passes added
# later by TYPE=extend are matched without re-reading run.json: the full
# backup plus every incremental pass this run can ever create.
watch_backup_prefix="vm-incremental-${RUN_ID}-p"


# --- Module activation ------------------------------------------------------
# Full mode activates every source; one-shot mode only the sources that can
# emit the requested checkpoint.
activate_module() {
  # activate_module <source-name> <checkpoint...>
  local name="$1"; shift
  if [[ -z "$WANT_CHECKPOINT" ]]; then
    source "$MODULE_DIR/$name.sh"
    "${name}_start"
    return 0
  fi
  local c
  for c in "$@"; do
    if [[ "$c" == "$WANT_CHECKPOINT" ]]; then
      source "$MODULE_DIR/$name.sh"
      "${name}_start"
      return 0
    fi
  done
  return 0
}

activate_module vmbackup BACKUP_INITIALIZING VOLUME_ATTACHING COPY_IN_PROGRESS \
  CHECKPOINT_RECORDED BACKUP_COMPLETED BACKUP_FAILED BACKUP_TARGET_DETACHING
activate_module pvc PVC_BOUND
activate_module events HOTPLUG_POD_CREATED HOTPLUG_POD_DELETED VOLUME_MOUNTED \
  VOLUME_UNMOUNTED
activate_module launcher BACKUP_REQUESTED GUEST_FROZEN COPY_STARTED \
  COPY_FINISHED_LOCAL
activate_module tracker TRACKER_ADVANCED

if [[ -n "$WANT_CHECKPOINT" ]] && ((${#streams_pids[@]} == 0)); then
  printf 'Unknown checkpoint %s; run with --help for the list.\n' "$WANT_CHECKPOINT" >&2
  exit 1
fi

[[ -n "$WATCH_RAW_DIR" ]] && printf 'Raw stream records in %s\n' "$WATCH_RAW_DIR" >&2
printf '[%s] watching backups for run %s in %s (%s + %spNN pattern)\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$RUN_ID" "$NAMESPACE" "$FULL_BACKUP_NAME" "$watch_backup_prefix" >&2

# Terminal only when the vmbackup module is active and every backup object
# actually seen in the stream has reached Done=True; one-shot mode never
# exits this way (its checkpoint may belong to a backup created later, e.g.
# TYPE=extend after the watcher started).
all_terminal() {
  local b
  [[ -n "${terminal[$FULL_BACKUP_NAME]:-}" ]] || return 1
  for b in "${!terminal[@]}"; do
    [[ -n "${terminal[$b]:-}" ]] || return 1
  done
  return 0
}

drain_streams() {
  command -v vmbackup_scan >/dev/null && vmbackup_scan || true
  command -v pvc_scan >/dev/null && pvc_scan || true
  command -v events_scan >/dev/null && events_scan || true
  command -v launcher_scan >/dev/null && launcher_scan || true
  command -v tracker_scan >/dev/null && tracker_scan || true
}

deadline=$((SECONDS + WATCH_TIMEOUT_SECONDS))
while :; do
  drain_streams

  if [[ -z "$WANT_CHECKPOINT" ]] && all_terminal; then
    # Detach/unmount/tracker events land right after Done; drain once more.
    sleep 3
    drain_streams
    exit 0
  fi
  if ((WATCH_TIMEOUT_SECONDS > 0 && SECONDS >= deadline)); then
    printf 'Timeout after %ss with backups still pending.\n' "$WATCH_TIMEOUT_SECONDS" >&2
    exit 2
  fi
  sleep "$WATCH_POLL_SECONDS"
done

#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="monitor"

usage() {
  printf 'Usage: %s <vm_name>\n' "$(basename "$0")" >&2
  printf 'Read-only: watches the full and incremental vmbackup for the run that owns <vm_name>\n' >&2
  printf 'and prints when each one starts, finishes, and how long it took.\n' >&2
  printf 'Run it alongside `make e2e` (in another terminal, or backgrounded) for the same run.\n' >&2
}

if (($# != 1)) || [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit "$([[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && echo 0 || echo 1)"
fi

vm_name="$1"
if [[ "$vm_name" != vm-* ]]; then
  printf '%s does not look like a run VM name (expected vm-<run-id>).\n' "$vm_name" >&2
  exit 1
fi
RUN_ID="${vm_name#vm-}"
set_resource_names

POLL_INTERVAL_SECONDS="${MONITOR_POLL_INTERVAL_SECONDS:-2}"

# Backups this run creates, in the order the pipeline creates them.
backup_names=("$FULL_BACKUP_NAME" "$INCREMENTAL_BACKUP_NAME")
declare -A backup_label=(
  ["$FULL_BACKUP_NAME"]="full backup"
  ["$INCREMENTAL_BACKUP_NAME"]="incremental backup"
)
declare -A reported_created=()
declare -A reported_done=()

workflow_step "Watching $NAMESPACE for run $RUN_ID"
workflow_action "Tracking ${backup_label[$FULL_BACKUP_NAME]} ($FULL_BACKUP_NAME) and ${backup_label[$INCREMENTAL_BACKUP_NAME]} ($INCREMENTAL_BACKUP_NAME)"

# Prints "<label> <name> started at <ts>" once creationTimestamp is first seen,
# then "<label> <name> done in <duration>s (reason: <reason>)" once the Done
# condition appears; returns 0 once both have been reported.
#
# The duration is a real measurement, not an estimate: it is
# status.conditions[Done].lastTransitionTime minus metadata.creationTimestamp,
# both read directly from the vmbackup object as recorded by the Kubernetes
# API server/KubeVirt controller. It does not depend on this script's poll
# interval. The one caveat: Kubernetes timestamps have whole-second
# resolution, so the true wall-clock duration can be off by up to ~1s from
# rounding at each end.
poll_backup() {
  local backup_name="$1" label="${backup_label[$1]}"
  local backup_json created done_status done_reason done_time

  if [[ -n "${reported_done[$backup_name]:-}" ]]; then
    return 0
  fi

  if ! backup_json="$(oc_cmd get vmbackup "$backup_name" -n "$NAMESPACE" -o json 2>/dev/null)"; then
    return 1
  fi

  created="$(jq -r '.metadata.creationTimestamp // empty' <<<"$backup_json")"
  if [[ -z "$created" ]]; then
    return 1
  fi
  if [[ -z "${reported_created[$backup_name]:-}" ]]; then
    reported_created[$backup_name]="$created"
    workflow_success "$label ($backup_name) started at $created"
  fi

  done_status="$(jq -r '.status.conditions[]? | select(.type=="Done") | .status // empty' <<<"$backup_json")"
  if [[ "$done_status" != "True" ]]; then
    return 1
  fi
  done_reason="$(jq -r '.status.conditions[]? | select(.type=="Done") | .reason // empty' <<<"$backup_json")"
  done_time="$(jq -r '.status.conditions[]? | select(.type=="Done") | .lastTransitionTime // empty' <<<"$backup_json")"

  local duration_seconds=""
  if [[ -n "$done_time" ]]; then
    duration_seconds="$(( $(date -u -d "$done_time" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$done_time" +%s) \
      - $(date -u -d "$created" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$created" +%s) ))"
  fi

  reported_done[$backup_name]="$done_time"
  if backup_done_reason_is_failure "$done_reason"; then
    printf '  ✗ %s (%s) failed after %ss [measured: lastTransitionTime %s - creationTimestamp %s] (reason: %s)\n' \
      "$label" "$backup_name" "$duration_seconds" "$done_time" "$created" "$done_reason" >&2
  else
    workflow_success "$label ($backup_name) done in ${duration_seconds}s [measured: lastTransitionTime $done_time - creationTimestamp $created] (reason: $done_reason)"
  fi
  return 0
}

while :; do
  all_done=1
  for backup_name in "${backup_names[@]}"; do
    if [[ -z "${reported_done[$backup_name]:-}" ]]; then
      poll_backup "$backup_name" || true
      [[ -n "${reported_done[$backup_name]:-}" ]] || all_done=0
    fi
  done
  if ((all_done)); then
    break
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done

workflow_success "Both backups reached Done=True for run $RUN_ID"

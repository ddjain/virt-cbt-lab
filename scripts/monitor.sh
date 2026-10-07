#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="monitor"

usage() {
  printf 'Usage: %s <vm_name>\n' "$(basename "$0")" >&2
  printf 'Read-only: watches the full backup and all incremental passes in the saved VM lifecycle plan.\n' >&2
  printf 'Prints API creation/Done timestamps, duration, and terminal reason for each planned backup.\n' >&2
  printf 'Run after vm-info.json exists; backup objects are watched even before lifecycle records are written.\n' >&2
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
backup_names=()
declare -A backup_label=()
if [[ ! -r "$VM_INFO_PATH" ]]; then
  printf 'No VM lifecycle state found for VM %s at %s.\n' "$vm_name" "$VM_INFO_PATH" >&2
  exit 1
fi
vm_info_load "$RUN_ID"
NAMESPACE="$(jq -r '.namespace' "$VM_INFO_PATH")"
full_name="$(jq -r '.backups.full.name // empty' "$VM_INFO_PATH")"
if [[ -z "$full_name" ]]; then
  full_name="$FULL_BACKUP_NAME"
fi
backup_names+=("$full_name")
backup_label["$full_name"]="full backup"

pass_total="$(jq -r '.incremental_passes_total // ((.backups.incrementals // []) | length)' "$VM_INFO_PATH")"
if ! [[ "$pass_total" =~ ^[0-9]+$ ]] || ((pass_total > 99)); then
  printf 'Invalid planned incremental pass total for VM %s: %s\n' "$vm_name" "$pass_total" >&2
  exit 1
fi
for ((pass = 1; pass <= pass_total; pass++)); do
  backup_name="$(jq -r --argjson pass "$pass" \
    '[.backups.incrementals[]? | select(.pass == $pass) | .name] | last // empty' "$VM_INFO_PATH")"
  if [[ -z "$backup_name" ]]; then
    backup_name="$(incremental_backup_name_for_pass "$pass")"
  fi
  backup_names+=("$backup_name")
  printf -v pass_label '%02d' "$pass"
  backup_label["$backup_name"]="incremental pass $pass_label"
done
if ((${#backup_names[@]} == 0)); then
  printf 'No planned backup objects are available for VM %s.\n' "$vm_name" >&2
  exit 1
fi

POLL_INTERVAL_SECONDS="${MONITOR_POLL_INTERVAL_SECONDS:-2}"

declare -A reported_created=()
declare -A reported_done=()
failed_backup=0

workflow_step "Watching $NAMESPACE for run $RUN_ID"
workflow_action "Tracking ${#backup_names[@]} backup object(s): ${backup_names[*]}"

# Prints "<label> <name> started at <ts>" once creationTimestamp is first seen,
# then "<label> <name> done in <duration>s (reason: <reason>)" once the Done
# condition appears; returns 0 once every recorded backup has been reported.
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
    failed_backup=1
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
      if ((failed_backup)); then
        break
      fi
      [[ -n "${reported_done[$backup_name]:-}" ]] || all_done=0
    fi
  done
  if ((failed_backup || all_done)); then
    break
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done

if ((failed_backup)); then
  printf 'One or more backups reached Done=True with a terminal failure reason; see the lines above.\n' >&2
  exit 1
fi

workflow_success "All ${#backup_names[@]} backups reached Done=True for run $RUN_ID"

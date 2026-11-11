#!/usr/bin/env bash
# Source module: VirtualMachineBackupTracker latestCheckpoint transitions.
# Emits: TRACKER_ADVANCED.
# Requires from main: NAMESPACE, TRACKER_NAME, watch_backup_prefix.
# Requires lib.sh.

tracker_start() {
  start_stream tracker.txt get vmbackuptracker -n "$NAMESPACE" -w -o \
    jsonpath='{.metadata.name}{"|"}{.status.latestCheckpoint.name}{"\n"}'
}

tracker_scan() {
  while IFS= read -r line; do handle_tracker_line "$line"; done < <(new_lines tracker.txt)
}

handle_tracker_line() {
  local tracker latest owner
  tracker="${1%%|*}"
  latest="${1##*|}"
  [[ "$tracker" == "$TRACKER_NAME" && -n "$latest" ]] || return 0
  [[ "${tracker_latest:-}" == "$latest" ]] && return 0
  tracker_latest="$latest"
  # Checkpoint names are "<backup-name>-YYYY-MM-DD_HH-MM-SS"; strip the
  # date-time suffix (its last 5 dash segments).
  owner="$latest"
  for _ in 1 2 3 4 5; do owner="${owner%-*}"; done
  is_watched_backup "$owner" || owner="${watch_backup_prefix}unknown"
  print_checkpoint "$owner" TRACKER_ADVANCED "latestCheckpoint=$latest"
}

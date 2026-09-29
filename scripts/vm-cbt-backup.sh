#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_command ssh

wait_for_full_checkpoint_in_tracker() {
  local expected_checkpoint="$1" tracker_checkpoint=
  printf '[vm-cbt-backup] Waiting for tracker %s to record full checkpoint %s.\n' "$TRACKER_NAME" "$expected_checkpoint" >&2
  for ((attempt = 1; attempt <= 20; attempt++)); do
    tracker_checkpoint="$(get_tracker_checkpoint)"
    if [[ -n "$expected_checkpoint" && "$tracker_checkpoint" == "$expected_checkpoint" ]]; then
      return 0
    fi
    if (( attempt % 5 == 0 )); then
      printf '[vm-cbt-backup] Tracker update pending (attempt %d/20).\n' "$attempt" >&2
    fi
    sleep 1
  done
  printf 'Backup tracker did not advance to the full checkpoint (expected %s, got %s).\n' \
    "$expected_checkpoint" "$tracker_checkpoint" >&2
  return 1
}

printf '[vm-cbt-backup] Checking that the full backup is complete.\n' >&2
wait_for_backup_done "$FULL_BACKUP_NAME"
full_backup_type="$(get_backup_type "$FULL_BACKUP_NAME")"
if [[ "$full_backup_type" != Full ]]; then
  printf 'Run make vm-backup first; %s is not a completed full backup.\n' "$FULL_BACKUP_NAME" >&2
  exit 1
fi
if oc_cmd get vmbackup "$INCREMENTAL_BACKUP_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf '%s already exists; start a fresh demo namespace before rerunning this step.\n' "$INCREMENTAL_BACKUP_NAME" >&2
  exit 1
fi

full_checkpoint="$(get_backup_checkpoint "$FULL_BACKUP_NAME")"
wait_for_full_checkpoint_in_tracker "$full_checkpoint"

guest_mutation_command='
if ! grep -Fqx "This line was added after the full backup." ~/hello.txt; then
  printf "%s\n" "This line was added after the full backup." >> ~/hello.txt
fi
sha256sum ~/hello.txt
'
guest_ssh "$guest_mutation_command"
printf '[vm-cbt-backup] Creating the incremental backup request.\n' >&2
oc_cmd apply -f - < "$ROOT_DIR/manifests/incremental-backup.yaml"
printf '[vm-cbt-backup] Waiting for the incremental backup to complete.\n' >&2
wait_for_backup_done "$INCREMENTAL_BACKUP_NAME"

incremental_backup_type="$(get_backup_type "$INCREMENTAL_BACKUP_NAME")"
if [[ "$incremental_backup_type" != Incremental ]]; then
  printf 'Expected an Incremental backup; got %s.\n' "$incremental_backup_type" >&2
  exit 1
fi
incremental_checkpoint="$(get_backup_checkpoint "$INCREMENTAL_BACKUP_NAME")"
printf 'Incremental backup complete: %s (checkpoint %s)\n' "$INCREMENTAL_BACKUP_NAME" "$incremental_checkpoint"

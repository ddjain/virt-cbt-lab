#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_command ssh

printf '[vm-cbt-backup] Checking that the full backup is complete.\n' >&2
oc_cmd wait "vmbackup/$FULL_BACKUP_NAME" -n "$NAMESPACE" --for=condition=Done --timeout=20m
full_type="$(oc_cmd get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.type}')"
if [[ "$full_type" != Full ]]; then
  printf 'Run make vm-backup first; %s is not a completed full backup.\n' "$FULL_BACKUP_NAME" >&2
  exit 1
fi
if oc_cmd get vmbackup "$INCREMENTAL_BACKUP_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf '%s already exists; start a fresh demo namespace before rerunning this step.\n' "$INCREMENTAL_BACKUP_NAME" >&2
  exit 1
fi

full_checkpoint="$(oc_cmd get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.checkpointName}')"
printf '[vm-cbt-backup] Waiting for tracker %s to record full checkpoint %s.\n' "$TRACKER_NAME" "$full_checkpoint" >&2
tracker_checkpoint=
for ((attempt = 1; attempt <= 20; attempt++)); do
  tracker_checkpoint="$(oc_cmd get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.latestCheckpoint.name}')"
  if [[ -n "$full_checkpoint" && "$tracker_checkpoint" == "$full_checkpoint" ]]; then
    break
  fi
  if (( attempt % 5 == 0 )); then
    printf '[vm-cbt-backup] Tracker update pending (attempt %d/20).\n' "$attempt" >&2
  fi
  sleep 1
done
if [[ "$tracker_checkpoint" != "$full_checkpoint" ]]; then
  printf 'Backup tracker did not advance to the full checkpoint (expected %s, got %s).\n' "$full_checkpoint" "$tracker_checkpoint" >&2
  exit 1
fi

printf '[vm-cbt-backup] Appending text to hello.txt and printing the new SHA-256.\n' >&2
guest_ssh 'if ! grep -Fqx "This line was added after the full backup." ~/hello.txt; then printf "%s\n" "This line was added after the full backup." >> ~/hello.txt; fi; sha256sum ~/hello.txt'
printf '[vm-cbt-backup] Creating the incremental backup request.\n' >&2
oc_cmd apply -f - < "$ROOT_DIR/manifests/incremental-backup.yaml"
printf '[vm-cbt-backup] Waiting for the incremental backup to complete.\n' >&2
oc_cmd wait "vmbackup/$INCREMENTAL_BACKUP_NAME" -n "$NAMESPACE" --for=condition=Done --timeout=20m

backup_type="$(oc_cmd get vmbackup "$INCREMENTAL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.type}')"
if [[ "$backup_type" != Incremental ]]; then
  printf 'Expected an Incremental backup; got %s.\n' "$backup_type" >&2
  exit 1
fi
checkpoint="$(oc_cmd get vmbackup "$INCREMENTAL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.checkpointName}')"
printf 'Incremental backup complete: %s (checkpoint %s)\n' "$INCREMENTAL_BACKUP_NAME" "$checkpoint"

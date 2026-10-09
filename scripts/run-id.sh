#!/usr/bin/env bash
set -euo pipefail
# Shared run ID generation for Make and the Bash workflow scripts.
RUN_ID_ADJECTIVES=(dark silent brave calm fuzzy happy wild gentle bright swift)
RUN_ID_NOUNS=(forest river wolf meadow penguin mountain falcon ocean tiger valley)
valid_run_id() {
  [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] && ((${#1} <= 40))
}
# Derive every per-run resource name from the current $RUN_ID, so a run's VM,
# disk, backups, and tracker always reference each other and never collide
# with another run's resources in the same namespace. Each resource type
# keeps its own fixed prefix ahead of the shared run ID.
incremental_backup_name_for_pass() {
  printf 'vm-incremental-%s-p%02d' "$RUN_ID" "$1"
}

incremental_backup_pvc_name_for_pass() {
  printf 'vm-incremental-pvc-%s-p%02d' "$RUN_ID" "$1"
}

vm_info_path() {
  printf '%s/%s/run.json' "$RUNS_ROOT_DIR" "$1"
}

set_resource_names() {
  # shellcheck disable=SC2034
  VM_NAME="vm-${RUN_ID}"
  # shellcheck disable=SC2034
  DV_NAME="vm-disk-${RUN_ID}"
  # shellcheck disable=SC2034
  SSH_SERVICE="vm-ssh-${RUN_ID}"
  # shellcheck disable=SC2034
  TRACKER_NAME="vm-tracker-${RUN_ID}"
  # shellcheck disable=SC2034
  FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
  # shellcheck disable=SC2034
  FULL_BACKUP_PVC_NAME="vm-backup-pvc-${RUN_ID}"
  # shellcheck disable=SC2034
  INCREMENTAL_BACKUP_NAME="$(incremental_backup_name_for_pass 1)"
  # shellcheck disable=SC2034
  INCREMENTAL_BACKUP_PVC_NAME="$(incremental_backup_pvc_name_for_pass 1)"
  # shellcheck disable=SC2034
  RESTORE_POD_NAME="vm-restore-verify-${RUN_ID}"
  RUN_DIR="$RUNS_ROOT_DIR/$RUN_ID"
  VM_INFO_PATH="$RUN_DIR/run.json"
  REPORT_DIR="$RUN_DIR"
}


generate_run_id() {
  local adjective noun tag timestamp
  adjective="${RUN_ID_ADJECTIVES[RANDOM % ${#RUN_ID_ADJECTIVES[@]}]}"
  noun="${RUN_ID_NOUNS[RANDOM % ${#RUN_ID_NOUNS[@]}]}"
  # Avoid `head -c`: its upstream may SIGPIPE under `set -o pipefail`.
  tag="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  timestamp="$(date -u +%Y%m%d%H%M%S)"
  printf '%s-%s-%s-%s' "$timestamp" "$adjective" "$noun" "$tag"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  generate_run_id
  printf '\n'
fi

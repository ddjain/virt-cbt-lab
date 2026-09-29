#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

printf '[vm-backup] Creating the backup PVC, tracker, and full backup request.\n' >&2
oc_cmd apply -f - < "$ROOT_DIR/manifests/full-backup.yaml"
wait_for_backup_done "$FULL_BACKUP_NAME"

full_backup_type="$(get_backup_type "$FULL_BACKUP_NAME")"
if [[ "$full_backup_type" != Full ]]; then
  printf 'Expected a Full backup; got %s.\n' "$full_backup_type" >&2
  exit 1
fi

full_backup_checkpoint="$(get_backup_checkpoint "$FULL_BACKUP_NAME")"
printf 'Full backup complete: %s (checkpoint %s)\n' "$FULL_BACKUP_NAME" "$full_backup_checkpoint"

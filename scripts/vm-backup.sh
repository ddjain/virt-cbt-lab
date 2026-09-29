#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

printf '[vm-backup] Creating the backup PVC, tracker, and full backup request.\n' >&2
oc_cmd apply -f - < "$ROOT_DIR/manifests/full-backup.yaml"
printf '[vm-backup] Waiting for the full backup to complete.\n' >&2
oc_cmd wait "vmbackup/$FULL_BACKUP_NAME" -n "$NAMESPACE" --for=condition=Done --timeout=20m

backup_type="$(oc_cmd get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.type}')"
if [[ "$backup_type" != Full ]]; then
  printf 'Expected a Full backup; got %s.\n' "$backup_type" >&2
  exit 1
fi
checkpoint="$(oc_cmd get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.checkpointName}')"
printf 'Full backup complete: %s (checkpoint %s)\n' "$FULL_BACKUP_NAME" "$checkpoint"

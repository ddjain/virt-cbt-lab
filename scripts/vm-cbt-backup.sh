#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="vm-cbt-backup"
if [[ "$VM_OS" == debian ]]; then
  require_command ssh
fi
load_run_id
load_report_id

wait_for_full_checkpoint_in_tracker() {
  local expected_checkpoint="$1" tracker_checkpoint=
  for ((attempt = 1; attempt <= 20; attempt++)); do
    tracker_checkpoint="$(get_tracker_checkpoint)"
    if [[ -n "$expected_checkpoint" && "$tracker_checkpoint" == "$expected_checkpoint" ]]; then
      return 0
    fi
    if (( attempt % 5 == 0 )); then
      workflow_action "Tracker $TRACKER_NAME still pending (attempt $attempt/20; expected checkpoint $expected_checkpoint)"
    fi
    sleep 1
  done
  printf 'Backup tracker did not advance to the full checkpoint (expected %s, got %s).\n' \
    "$expected_checkpoint" "$tracker_checkpoint" >&2
  return 1
}

workflow_step "1/5 Confirm the full-backup checkpoint"
workflow_action "oc wait vmbackup/$FULL_BACKUP_NAME -n $NAMESPACE --for=condition=Done --timeout=20m"
wait_for_backup_done "$FULL_BACKUP_NAME"
full_backup_done_reason="$(get_backup_done_reason "$FULL_BACKUP_NAME")"
if backup_done_reason_is_failure "$full_backup_done_reason"; then
  printf '%s reached Done=True but the backup actually failed: %s\n' \
    "$FULL_BACKUP_NAME" "$full_backup_done_reason" >&2
  exit 1
fi
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
workflow_action "Wait for tracker $TRACKER_NAME to record checkpoint $full_checkpoint"
wait_for_full_checkpoint_in_tracker "$full_checkpoint"
workflow_success "Full backup $FULL_BACKUP_NAME is complete as $full_backup_type; tracker checkpoint recorded"

workflow_step "2/5 Modify guest data after the full checkpoint"
if [[ "$VM_OS" == windows ]]; then
  # shellcheck source=scripts/windows-guest-agent.sh
  source "$ROOT_DIR/scripts/windows-guest-agent.sh"
  workflow_action "QEMU Guest Agent PowerShell: append ${GUEST_INCREMENTAL_DATA_SIZE_MB}MiB and the idempotent marker to C:\\cbt-data\\hello.txt"
  windows_mutation_command="\$ErrorActionPreference = 'Stop'
\$path = 'C:\cbt-data\hello.txt'
\$marker = '$CBT_INCREMENTAL_MARKER_LINE'
if (-not (Select-String -LiteralPath \$path -SimpleMatch -Pattern \$marker -Quiet)) {
  \$stream = [System.IO.File]::Open(\$path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
  \$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    [long]\$remaining = [long]${GUEST_INCREMENTAL_DATA_SIZE_MB} * 1048576
    [byte[]]\$buffer = New-Object byte[] 786432
    while (\$remaining -gt 0) {
      \$count = [int][Math]::Min(\$buffer.Length, \$remaining)
      \$rng.GetBytes(\$buffer)
      \$line = [System.Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String(\$buffer, 0, \$count) + [Environment]::NewLine)
      \$stream.Write(\$line, 0, \$line.Length)
      \$remaining -= \$count
    }
    \$markerBytes = [System.Text.Encoding]::ASCII.GetBytes([Environment]::NewLine + \$marker + [Environment]::NewLine)
    \$stream.Write(\$markerBytes, 0, \$markerBytes.Length)
    \$stream.Flush(\$true)
  } finally {
    \$rng.Dispose()
    \$stream.Dispose()
  }
}
\$hash = (Get-FileHash -LiteralPath \$path -Algorithm SHA256).Hash.ToLowerInvariant()
\$size = (Get-Item -LiteralPath \$path).Length
Write-Output ('SHA256=' + \$hash)
Write-Output ('SIZE_BYTES=' + \$size)"
  guest_output="$(guest_exec "$VM_NAME" "$NAMESPACE" "$windows_mutation_command")"
  guest_hash="$(sed -n 's/^SHA256=//p' <<<"$guest_output" | tr -d '\r' | tail -n1 | tr '[:upper:]' '[:lower:]')"
  guest_size_bytes="$(sed -n 's/^SIZE_BYTES=//p' <<<"$guest_output" | tr -d '\r' | tail -n1)"
  if ! [[ "$guest_hash" =~ ^[[:xdigit:]]{64}$ && "$guest_size_bytes" =~ ^[0-9]+$ ]]; then
    printf 'QEMU Guest Agent did not return a valid Windows guest file hash and size.\n' >&2
    exit 1
  fi
else
  workflow_action "Port-forward service $SSH_SERVICE and append a ${GUEST_INCREMENTAL_DATA_SIZE_MB}MiB payload plus the idempotent CBT test line to ~/hello.txt"
  # `sync` before the incremental backup runs: without it, the appended data
  # can still be sitting in the guest's page cache when the external snapshot
  # is taken, so the incremental backup misses part of the delta.
  guest_mutation_command="
if ! grep -Fqx \"$CBT_INCREMENTAL_MARKER_LINE\" ~/hello.txt; then
  head -c ${GUEST_INCREMENTAL_DATA_SIZE_MB}M /dev/urandom | base64 >> ~/hello.txt
  printf '\\n' >> ~/hello.txt
  printf '%s\\n' \"$CBT_INCREMENTAL_MARKER_LINE\" >> ~/hello.txt
fi
sync
sha256sum ~/hello.txt
stat -c 'SIZE_BYTES=%s' ~/hello.txt
"
  guest_output="$(guest_ssh "$guest_mutation_command")"
  guest_hash_line="$(printf '%s\n' "$guest_output" | grep -v '^SIZE_BYTES=')"
  guest_size_bytes="$(printf '%s\n' "$guest_output" | sed -n 's/^SIZE_BYTES=//p')"
  guest_hash="$(printf '%s' "$guest_hash_line" | extract_sha256)"
fi
printf '%s\n' "$guest_output"
write_state_file "incremental-backup.sha256" "$guest_hash"
guest_captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
workflow_success "Guest data changed after checkpoint $full_checkpoint; expected incremental-backup hash recorded in $STATE_DIR"

workflow_step "3/5 Create the incremental backup request"
workflow_action "oc apply -f manifests/incremental-backup.yaml (PVC $INCREMENTAL_BACKUP_PVC_NAME and backup $INCREMENTAL_BACKUP_NAME)"
sed \
  -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__TRACKER_NAME__|$TRACKER_NAME|g" \
  -e "s|__INCREMENTAL_BACKUP_NAME__|$INCREMENTAL_BACKUP_NAME|g" \
  -e "s|__INCREMENTAL_BACKUP_PVC__|$INCREMENTAL_BACKUP_PVC_NAME|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
  -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
  -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
  "$(manifest_path incremental-backup)" | oc_cmd apply -f -
workflow_success "Incremental backup request $INCREMENTAL_BACKUP_NAME submitted from tracker $TRACKER_NAME"

workflow_step "4/5 Wait for incremental backup completion"
workflow_action "oc wait vmbackup/$INCREMENTAL_BACKUP_NAME -n $NAMESPACE --for=condition=Done --timeout=20m"
wait_for_backup_done "$INCREMENTAL_BACKUP_NAME"
incremental_backup_done_reason="$(get_backup_done_reason "$INCREMENTAL_BACKUP_NAME")"
workflow_success "$INCREMENTAL_BACKUP_NAME reports Done=True (reason: $incremental_backup_done_reason)"
if backup_done_reason_is_failure "$incremental_backup_done_reason"; then
  printf '%s reached Done=True but the backup actually failed: %s\n' \
    "$INCREMENTAL_BACKUP_NAME" "$incremental_backup_done_reason" >&2
  exit 1
fi

workflow_step "5/5 Validate incremental type and checkpoint"
incremental_backup_type="$(get_backup_type "$INCREMENTAL_BACKUP_NAME")"
if [[ "$incremental_backup_type" != Incremental ]]; then
  printf 'Expected an Incremental backup; got %s.\n' "$incremental_backup_type" >&2
  exit 1
fi
incremental_checkpoint="$(get_backup_checkpoint "$INCREMENTAL_BACKUP_NAME")"
workflow_success "$INCREMENTAL_BACKUP_NAME is $incremental_backup_type (checkpoint $incremental_checkpoint)"

workflow_action "Recording incremental backup PVC size and VM backup status for the run report"
incremental_backup_status="$(get_vm_backup_status)"
if [[ "$(jq -r '.backupName // empty' <<<"$incremental_backup_status")" != "$INCREMENTAL_BACKUP_NAME" ]]; then
  incremental_backup_status='{}'
fi
write_report_fragment "incremental-backup" "$(jq -n \
  --arg sha256 "$guest_hash" \
  --argjson size_bytes "$guest_size_bytes" \
  --arg captured_at "$guest_captured_at" \
  --arg name "$INCREMENTAL_BACKUP_NAME" \
  --arg type "$incremental_backup_type" \
  --arg checkpoint_name "$incremental_checkpoint" \
  --arg done_reason "$incremental_backup_done_reason" \
  --arg pvc_name "$INCREMENTAL_BACKUP_PVC_NAME" \
  --arg pvc_requested "$(get_pvc_requested "$INCREMENTAL_BACKUP_PVC_NAME")" \
  --arg pvc_capacity "$(get_pvc_capacity "$INCREMENTAL_BACKUP_PVC_NAME")" \
  --argjson backup_status "$incremental_backup_status" \
  '{guest: {incremental_backup: {size_bytes: $size_bytes, size_mb: (($size_bytes / 1048576 * 100 | round) / 100), sha256: $sha256, captured_at: $captured_at}},
    backups: {incremental: ({name: $name, type: $type, checkpoint_name: $checkpoint_name, done_reason: $done_reason,
                              pvc_name: $pvc_name, pvc_requested: $pvc_requested, pvc_capacity: $pvc_capacity} + $backup_status)}}')"

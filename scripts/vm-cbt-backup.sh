#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/workload-manifest.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workload-manifest.sh"
WORKFLOW_NAME="vm-cbt-backup"
if [[ "$VM_OS" != windows ]]; then
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

workflow_step "2/5 Add files after the full checkpoint"
manifest_path="$(workload_manifest_path)"
if [[ ! -r "$manifest_path" ]]; then
  printf 'Missing workload manifest %s; run vm-setup before the backup stages.\n' "$manifest_path" >&2
  exit 1
fi
workload_manifest_validate "$manifest_path" false
manifest_min_mib="$(jq -r '.size_range_mib.min_inclusive' "$manifest_path")"
manifest_max_mib="$(jq -r '.size_range_mib.max_inclusive' "$manifest_path")"
if [[ "$manifest_min_mib" != "$GUEST_FILE_SIZE_MIN_MIB" ||
      "$manifest_max_mib" != "$GUEST_FILE_SIZE_MAX_MIB" ]]; then
  printf 'Configured workload size range (%s-%s MiB) does not match the setup manifest range (%s-%s MiB).\n' \
    "$GUEST_FILE_SIZE_MIN_MIB" "$GUEST_FILE_SIZE_MAX_MIB" "$manifest_min_mib" "$manifest_max_mib" >&2
  exit 1
fi

baseline_expected="$(jq -c '.baseline.files' "$manifest_path")"
baseline_expected_count="$(jq -r '.baseline.file_count' "$manifest_path")"
baseline_expected_hash="$(jq -r '.baseline.manifest_sha256' "$manifest_path")"
if [[ "$baseline_expected_count" != "$GUEST_BASE_FILE_COUNT" ]]; then
  printf 'Workload manifest baseline count %s does not match configured count %s.\n' \
    "$baseline_expected_count" "$GUEST_BASE_FILE_COUNT" >&2
  exit 1
fi

if [[ "$VM_OS" == windows ]]; then
  # shellcheck source=scripts/windows-guest-agent.sh
  source "$ROOT_DIR/scripts/windows-guest-agent.sh"
  windows_inventory_command="\$ErrorActionPreference = 'Stop'
\$directory = 'C:\\cbt-data\\workload'
if (-not (Test-Path -LiteralPath \$directory -PathType Container)) {
  throw \"Workload directory is missing: \$directory\"
}
Get-ChildItem -LiteralPath \$directory -Filter '.cbt-workload-incremental-*.tmp' -Force -ErrorAction SilentlyContinue | Remove-Item -Force
foreach (\$entry in Get-ChildItem -LiteralPath \$directory -Force) {
  if (\$entry.PSIsContainer -or \$entry.Name -notmatch '^(base|incremental)-[0-9]{6}[.]dat$') {
    throw ('Unexpected workload directory entry: ' + \$entry.Name)
  }
  \$sha256 = (Get-FileHash -LiteralPath \$entry.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-Output ('FILE_RECORD=' + \$entry.Name + '|' + \$entry.Length + '|' + \$sha256)
}"
  workflow_action "Read the mounted Windows guest workload and confirm its baseline manifest before changing it"
  before_guest_output="$(guest_exec "$VM_NAME" "$NAMESPACE" "$windows_inventory_command")"
else
  workflow_action "Read the Linux guest workload and confirm its baseline manifest before changing it"
  linux_inventory_command="
set -euo pipefail
workload_dir='$LINUX_GUEST_WORKLOAD_DIR'
rm -f \"\$workload_dir\"/.cbt-workload-incremental-*.tmp
if [[ ! -d \"\$workload_dir\" ]]; then
  printf 'Workload directory is missing: %s\\n' \"\$workload_dir\" >&2
  exit 1
fi
entries=\"\$(find \"\$workload_dir\" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)\"
while IFS= read -r workload_file; do
  [[ -n \"\$workload_file\" ]] || continue
  if [[ ! -f \"\$workload_file\" ]]; then
    printf 'Unexpected workload directory entry: %s\\n' \"\$workload_file\" >&2
    exit 1
  fi
  name=\"\${workload_file##*/}\"
  if [[ ! \"\$name\" =~ ^(base|incremental)-[0-9]{6}[.]dat\$ ]]; then
    printf 'Unexpected workload filename: %s\\n' \"\$name\" >&2
    exit 1
  fi
  size_bytes=\"\$(stat -c '%s' \"\$workload_file\")\"
  sha256=\"\$(sha256sum \"\$workload_file\" | awk '{print \$1}')\"
  printf 'FILE_RECORD=%s|%s|%s\\n' \"\$name\" \"\$size_bytes\" \"\$sha256\"
done <<< \"\$entries\"
"
  before_guest_output="$(guest_ssh "$linux_inventory_command")"
fi
before_records="$(workload_records_from_output "$before_guest_output")"
before_baseline="$(workload_records_for_phase "$before_records" baseline)"
workload_manifest_verify_inventory "$before_baseline" "$baseline_expected" "Baseline"
previous_incremental_expected="$(jq -c '.incremental.files // []' "$manifest_path")"
if [[ "$(workload_records_count "$previous_incremental_expected")" -gt 0 ]]; then
  before_incremental="$(workload_records_for_phase "$before_records" incremental)"
  workload_manifest_verify_inventory "$before_incremental" "$previous_incremental_expected" "Previously recorded incremental"
fi
workflow_success "Baseline file set matches manifest $baseline_expected_hash"

incremental_plan="$(workload_file_plan incremental "$GUEST_INCREMENTAL_FILE_COUNT")"
if [[ "$VM_OS" == windows ]]; then
  windows_incremental_items=""
  while IFS='|' read -r workload_name workload_size_bytes; do
    [[ -n "$workload_name" ]] || continue
    windows_incremental_items="${windows_incremental_items}  [pscustomobject]@{ Name = '${workload_name}'; SizeBytes = [long]${workload_size_bytes} }"$'\n'
  done <<< "$incremental_plan"
  workflow_action "Use QEMU Guest Agent to add $GUEST_INCREMENTAL_FILE_COUNT files under $WINDOWS_GUEST_WORKLOAD_DIR"
  windows_mutation_command="\$ErrorActionPreference = 'Stop'
\$directory = 'C:\\cbt-data\\workload'
[System.IO.Directory]::CreateDirectory(\$directory) | Out-Null
\$filePlan = @(
${windows_incremental_items})
Get-ChildItem -LiteralPath \$directory -Filter '.cbt-workload-incremental-*.tmp' -Force -ErrorAction SilentlyContinue | Remove-Item -Force
foreach (\$item in \$filePlan) {
  \$target = Join-Path \$directory \$item.Name
  \$temporary = Join-Path \$directory ('.cbt-workload-' + \$item.Name + '.tmp')
  \$pattern = [System.Text.Encoding]::ASCII.GetBytes(('CBT-WORKLOAD-V1:' + \$item.Name + \"\`n\"))
  \$chunkSize = [int]([Math]::Ceiling(65536.0 / \$pattern.Length) * \$pattern.Length)
  \$buffer = New-Object byte[] \$chunkSize
  for (\$index = 0; \$index -lt \$buffer.Length; \$index++) {
    \$buffer[\$index] = \$pattern[\$index % \$pattern.Length]
  }
  \$stream = [System.IO.File]::Open(\$temporary, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  try {
    [long]\$remaining = \$item.SizeBytes
    while (\$remaining -gt 0) {
      \$count = [int][Math]::Min(\$buffer.Length, \$remaining)
      \$stream.Write(\$buffer, 0, \$count)
      \$remaining -= \$count
    }
    \$stream.Flush(\$true)
  } finally {
    \$stream.Dispose()
  }
  if (Test-Path -LiteralPath \$target) {
    if (-not (Test-Path -LiteralPath \$target -PathType Leaf)) {
      throw ('Expected a file at ' + \$target)
    }
    \$actualSize = (Get-Item -LiteralPath \$target).Length
    \$actualHash = (Get-FileHash -LiteralPath \$target -Algorithm SHA256).Hash
    \$expectedHash = (Get-FileHash -LiteralPath \$temporary -Algorithm SHA256).Hash
    if (\$actualSize -ne \$item.SizeBytes -or \$actualHash -ne \$expectedHash) {
      throw ('Existing workload file differs from its deterministic content: ' + \$target)
    }
    Remove-Item -LiteralPath \$temporary -Force
  } else {
    Move-Item -LiteralPath \$temporary -Destination \$target
  }
}
foreach (\$entry in Get-ChildItem -LiteralPath \$directory -Force) {
  if (\$entry.PSIsContainer -or \$entry.Name -notmatch '^(base|incremental)-[0-9]{6}[.]dat$') {
    throw ('Unexpected workload directory entry: ' + \$entry.Name)
  }
  \$sha256 = (Get-FileHash -LiteralPath \$entry.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-Output ('FILE_RECORD=' + \$entry.Name + '|' + \$entry.Length + '|' + \$sha256)
}"
  guest_output="$(guest_exec "$VM_NAME" "$NAMESPACE" "$windows_mutation_command")"
else
  incremental_items=""
  while IFS='|' read -r workload_name workload_size_bytes; do
    [[ -n "$workload_name" ]] || continue
    incremental_items="${incremental_items} '${workload_name}|${workload_size_bytes}'"
  done <<< "$incremental_plan"
  workflow_action "Port-forward service $SSH_SERVICE and add $GUEST_INCREMENTAL_FILE_COUNT files under $LINUX_GUEST_WORKLOAD_DIR"
  guest_mutation_command="
set -euo pipefail
workload_dir='$LINUX_GUEST_WORKLOAD_DIR'
mkdir -p \"\$workload_dir\"
trap 'rm -f \"\$workload_dir\"/.cbt-workload-*.tmp' EXIT
for workload_spec in ${incremental_items}; do
  IFS='|' read -r name size_bytes <<< \"\$workload_spec\"
  target=\"\$workload_dir/\$name\"
  tmp_path=\"\$workload_dir/.cbt-workload-\${name}.tmp\"
  set +o pipefail
  yes \"CBT-WORKLOAD-V1:\${name}\" | head -c \"\$size_bytes\" > \"\$tmp_path\"
  set -o pipefail
  actual_size=\"\$(stat -c '%s' \"\$tmp_path\")\"
  expected_hash=\"\$(sha256sum \"\$tmp_path\" | awk '{print \$1}')\"
  if [[ \"\$actual_size\" != \"\$size_bytes\" ]]; then
    printf 'Generated file %s has size %s; expected %s bytes.\\n' \"\$name\" \"\$actual_size\" \"\$size_bytes\" >&2
    exit 1
  fi
  if [[ -e \"\$target\" ]]; then
    if [[ ! -f \"\$target\" ]]; then
      printf 'Expected a file at %s.\\n' \"\$target\" >&2
      exit 1
    fi
    actual_size=\"\$(stat -c '%s' \"\$target\")\"
    actual_hash=\"\$(sha256sum \"\$target\" | awk '{print \$1}')\"
    if [[ \"\$actual_size\" != \"\$size_bytes\" || \"\$actual_hash\" != \"\$expected_hash\" ]]; then
      printf 'Existing workload file differs from its deterministic content: %s\\n' \"\$target\" >&2
      exit 1
    fi
    rm -f \"\$tmp_path\"
  else
    mv \"\$tmp_path\" \"\$target\"
  fi
done
sync
entries=\"\$(find \"\$workload_dir\" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)\"
while IFS= read -r workload_file; do
  [[ -n \"\$workload_file\" ]] || continue
  if [[ ! -f \"\$workload_file\" ]]; then
    printf 'Unexpected workload directory entry: %s\\n' \"\$workload_file\" >&2
    exit 1
  fi
  name=\"\${workload_file##*/}\"
  if [[ ! \"\$name\" =~ ^(base|incremental)-[0-9]{6}[.]dat\$ ]]; then
    printf 'Unexpected workload filename: %s\\n' \"\$name\" >&2
    exit 1
  fi
  size_bytes=\"\$(stat -c '%s' \"\$workload_file\")\"
  sha256=\"\$(sha256sum \"\$workload_file\" | awk '{print \$1}')\"
  printf 'FILE_RECORD=%s|%s|%s\\n' \"\$name\" \"\$size_bytes\" \"\$sha256\"
done <<< \"\$entries\"
"
  guest_output="$(guest_ssh "$guest_mutation_command")"
fi
printf '%s\n' "$guest_output"
all_guest_records="$(workload_records_from_output "$guest_output")"
guest_baseline_records="$(workload_records_for_phase "$all_guest_records" baseline)"
guest_incremental_records="$(workload_records_for_phase "$all_guest_records" incremental)"
workload_manifest_verify_inventory "$guest_baseline_records" "$baseline_expected" "Baseline after mutation"
workload_validate_plan "$all_guest_records" incremental "$GUEST_INCREMENTAL_FILE_COUNT"
workload_manifest_append_incremental "$guest_incremental_records"
expected_combined_records="$(jq -cn --argjson baseline "$(jq -c '.baseline.files' "$manifest_path")" \
  --argjson incremental "$(jq -c '.incremental.files' "$manifest_path")" '$baseline + $incremental')"
workload_manifest_verify_inventory "$all_guest_records" "$expected_combined_records" "Combined guest"
incremental_file_count="$(jq -r '.incremental.files_added' "$manifest_path")"
incremental_added_bytes="$(jq -r '.incremental.added_payload_bytes' "$manifest_path")"
combined_file_count="$(jq -r '.incremental.total_file_count' "$manifest_path")"
combined_total_bytes="$(jq -r '.incremental.total_payload_bytes' "$manifest_path")"
combined_manifest_sha256="$(jq -r '.incremental.manifest_sha256' "$manifest_path")"
incremental_added_manifest_sha256="$(jq -r '.incremental.added_manifest_sha256' "$manifest_path")"
guest_captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
workflow_success "Incremental workload payload: ${incremental_file_count} files, ${incremental_added_bytes} bytes ($((incremental_added_bytes / 1048576)) MiB) added"
workflow_action "Combined workload: ${combined_file_count} files, ${combined_total_bytes} bytes ($((combined_total_bytes / 1048576)) MiB); manifest SHA-256: $combined_manifest_sha256"

workflow_step "3/5 Create the incremental backup request"
workflow_action "oc apply -f $(manifest_path incremental-backup) (PVC $INCREMENTAL_BACKUP_PVC_NAME and backup $INCREMENTAL_BACKUP_NAME)"
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

incremental_pvc_requested="$(get_pvc_requested "$INCREMENTAL_BACKUP_PVC_NAME")"
incremental_pvc_capacity="$(get_pvc_capacity "$INCREMENTAL_BACKUP_PVC_NAME")"
workflow_action "Incremental backup output PVC: ${incremental_pvc_requested} requested, ${incremental_pvc_capacity} capacity"
incremental_backup_status="$(get_vm_backup_status)"
if [[ "$(jq -r '.backupName // empty' <<<"$incremental_backup_status")" != "$INCREMENTAL_BACKUP_NAME" ]]; then
  incremental_backup_status='{}'
fi
write_report_fragment "incremental-backup" "$(jq -n \
  --arg manifest_path "$WORKLOAD_MANIFEST_NAME" \
  --arg added_manifest_sha256 "$incremental_added_manifest_sha256" \
  --arg manifest_sha256 "$combined_manifest_sha256" \
  --arg captured_at "$guest_captured_at" \
  --arg name "$INCREMENTAL_BACKUP_NAME" \
  --arg type "$incremental_backup_type" \
  --arg checkpoint_name "$incremental_checkpoint" \
  --arg done_reason "$incremental_backup_done_reason" \
  --arg pvc_name "$INCREMENTAL_BACKUP_PVC_NAME" \
  --arg pvc_requested "$incremental_pvc_requested" \
  --arg pvc_capacity "$incremental_pvc_capacity" \
  --argjson files_added "$incremental_file_count" \
  --argjson added_payload_bytes "$incremental_added_bytes" \
  --argjson total_file_count "$combined_file_count" \
  --argjson total_payload_bytes "$combined_total_bytes" \
  --argjson backup_status "$incremental_backup_status" \
  '{guest: {workload: {manifest_path: $manifest_path,
                       incremental: {files_added: $files_added, added_payload_bytes: $added_payload_bytes,
                                     added_manifest_sha256: $added_manifest_sha256,
                                     total_file_count: $total_file_count, total_payload_bytes: $total_payload_bytes,
                                     manifest_sha256: $manifest_sha256, captured_at: $captured_at}}},
    backups: {incremental: ({name: $name, type: $type, checkpoint_name: $checkpoint_name, done_reason: $done_reason,
                              pvc_name: $pvc_name, pvc_requested: $pvc_requested, pvc_capacity: $pvc_capacity} + $backup_status)}}')"

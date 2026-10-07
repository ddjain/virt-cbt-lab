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
vm_info_load "$RUN_ID"
stored_passes_total="$(jq -r '.incremental_passes_total' "$VM_INFO_PATH")"
completed_passes="$(jq -r '.incremental_passes_completed' "$VM_INFO_PATH")"
vm_lifecycle_status="$(jq -r '.status' "$VM_INFO_PATH")"
next_incremental_pass="$(jq -r '.next_incremental_pass // empty' "$VM_INFO_PATH")"
if [[ "$vm_lifecycle_status" == complete &&
      "$completed_passes" == "$stored_passes_total" &&
      -z "$next_incremental_pass" ]]; then
  next_total=$((stored_passes_total + 1))
  printf 'VM %s has completed all %s planned incremental passes. To add one pass, run `make e2e TYPE=extend VM=%s EXTEND_TO_PASS=%s`.\n' \
    "$VM_NAME" "$stored_passes_total" "$VM_NAME" "$next_total" >&2
  exit 1
fi
if [[ "$stored_passes_total" != "$GUEST_INCREMENTAL_PASSES" ]]; then
  printf 'Configured GUEST_INCREMENTAL_PASSES=%s does not match VM %s state (%s).\n' \
    "$GUEST_INCREMENTAL_PASSES" "$VM_NAME" "$stored_passes_total" >&2
  exit 1
fi
incremental_pass="$(vm_info_next_pass)"
printf -v pass_suffix '%02d' "$incremental_pass"
INCREMENTAL_BACKUP_NAME="$(incremental_backup_name_for_pass "$incremental_pass")"
INCREMENTAL_BACKUP_PVC_NAME="$(incremental_backup_pvc_name_for_pass "$incremental_pass")"

if [[ "$(jq -r '.status' "$VM_INFO_PATH")" != incremental_ready ]]; then
  printf 'VM %s is not ready for an incremental pass (state: %s).\n' \
    "$VM_NAME" "$(jq -r '.status' "$VM_INFO_PATH")" >&2
  exit 1
fi

previous_checkpoint="$(vm_info_previous_checkpoint)"
if [[ -z "$previous_checkpoint" ]]; then
  printf 'VM %s has no completed full-backup checkpoint in its lifecycle state.\n' "$VM_NAME" >&2
  exit 1
fi

wait_for_checkpoint_in_tracker() {
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
  printf 'Backup tracker did not match the prior checkpoint (expected %s, got %s).\n' \
    "$expected_checkpoint" "$tracker_checkpoint" >&2
  return 1
}

workflow_step "1/5 Confirm checkpoint before incremental pass $incremental_pass/$stored_passes_total"
workflow_action "oc wait vmbackup/$FULL_BACKUP_NAME -n $NAMESPACE --for=condition=Done --timeout=20m"
wait_for_backup_done "$FULL_BACKUP_NAME" "$FULL_BACKUP_PVC_NAME" Full
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
if ((completed_passes > 0)); then
  previous_backup_name="$(jq -r '.backups.incrementals[-1].name' "$VM_INFO_PATH")"
  previous_backup_type="$(get_backup_type "$previous_backup_name")"
  previous_backup_done="$(get_backup_done_status "$previous_backup_name")"
  previous_backup_reason="$(get_backup_done_reason "$previous_backup_name")"
  previous_backup_checkpoint="$(get_backup_checkpoint "$previous_backup_name")"
  if [[ "$previous_backup_type" != Incremental || "$previous_backup_done" != True ||
        "$previous_backup_checkpoint" != "$previous_checkpoint" ]] ||
     backup_done_reason_is_failure "$previous_backup_reason"; then
    printf 'Previous incremental backup %s is not a successful recorded checkpoint.\n' \
      "$previous_backup_name" >&2
    exit 1
  fi
fi
if oc_cmd get vmbackup "$INCREMENTAL_BACKUP_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf '%s already exists for pass %s; inspect the pass state before retrying.\n' \
    "$INCREMENTAL_BACKUP_NAME" "$incremental_pass" >&2
  exit 1
fi
workflow_action "Wait for tracker $TRACKER_NAME to retain prior checkpoint $previous_checkpoint"
wait_for_checkpoint_in_tracker "$previous_checkpoint"
workflow_success "Tracker is at the prior checkpoint for pass $incremental_pass"

vm_info_update \
  '.status = "incremental_running" |
   .current_incremental_pass = {pass: $pass, backup_name: $backup_name,
                                pvc_name: $pvc_name, status: "running",
                                started_at: $updated_at}' \
  --argjson pass "$incremental_pass" \
  --arg backup_name "$INCREMENTAL_BACKUP_NAME" \
  --arg pvc_name "$INCREMENTAL_BACKUP_PVC_NAME"

workflow_step "2/5 Add files for incremental pass $incremental_pass/$stored_passes_total"
manifest_path="$(workload_manifest_path)"
if [[ ! -r "$manifest_path" ]]; then
  printf 'Missing workload manifest %s; run vm-setup before the backup stages.\n' "$manifest_path" >&2
  exit 1
fi
workload_manifest_validate "$manifest_path" false
manifest_passes_total="$(jq -r '.incremental_passes_total' "$manifest_path")"
manifest_passes_completed="$(jq -r '.incrementals | length' "$manifest_path")"
if [[ "$manifest_passes_total" != "$stored_passes_total" ||
      "$manifest_passes_completed" != "$completed_passes" ]]; then
  printf 'VM state and workload manifest disagree on incremental pass progress (%s/%s versus %s/%s).\n' \
    "$completed_passes" "$stored_passes_total" "$manifest_passes_completed" "$manifest_passes_total" >&2
  exit 1
fi
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
  if (\$entry.PSIsContainer -or \$entry.Name -notmatch '^(base-[0-9]{6}|incremental-[0-9]{2}-[0-9]{6})[.]dat$') {
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
  if [[ ! "\$name" =~ ^(base-[0-9]{6}|incremental-[0-9]{2}-[0-9]{6})[.]dat\$ ]]; then
    printf 'Unexpected workload filename: %s\\n' "\$name" >&2
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
previous_incremental_expected="$(jq -c '[.incrementals[]?.files[]?]' "$manifest_path")"
if [[ "$(workload_records_count "$previous_incremental_expected")" -gt 0 ]]; then
  before_incremental="$(workload_records_for_phase "$before_records" incremental)"
  workload_manifest_verify_inventory "$before_incremental" "$previous_incremental_expected" "Previously recorded incremental passes"
fi
workflow_success "Baseline and $manifest_passes_completed prior incremental pass(es) match the manifest"

incremental_plan="$(workload_file_plan incremental "$GUEST_INCREMENTAL_FILE_COUNT" "$incremental_pass")"
if [[ "$VM_OS" == windows ]]; then
  windows_incremental_items=""
  while IFS='|' read -r workload_name workload_size_bytes; do
    [[ -n "$workload_name" ]] || continue
    windows_incremental_items="${windows_incremental_items}  [pscustomobject]@{ Name = '${workload_name}'; SizeBytes = [long]${workload_size_bytes} }"$'\n'
  done <<< "$incremental_plan"
  workflow_action "Use QEMU Guest Agent to add $GUEST_INCREMENTAL_FILE_COUNT files for pass $incremental_pass/$stored_passes_total under $WINDOWS_GUEST_WORKLOAD_DIR"
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
  if (\$entry.PSIsContainer -or \$entry.Name -notmatch '^(base-[0-9]{6}|incremental-[0-9]{2}-[0-9]{6})[.]dat$') {
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
  workflow_action "Port-forward service $SSH_SERVICE and add $GUEST_INCREMENTAL_FILE_COUNT files for pass $incremental_pass/$stored_passes_total under $LINUX_GUEST_WORKLOAD_DIR"
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
  if [[ ! "\$name" =~ ^(base-[0-9]{6}|incremental-[0-9]{2}-[0-9]{6})[.]dat\$ ]]; then
    printf 'Unexpected workload filename: %s\\n' "\$name" >&2
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
workload_manifest_verify_inventory "$guest_baseline_records" "$baseline_expected" "Baseline after pass $incremental_pass mutation"
workload_validate_plan "$all_guest_records" incremental "$GUEST_INCREMENTAL_FILE_COUNT" "$incremental_pass"
current_incremental_records="$(workload_records_for_phase "$all_guest_records" incremental "$incremental_pass")"
previous_incremental_expected="$(jq -c '[.incrementals[]?.files[]?]' "$manifest_path")"
expected_before_records="$(workload_records_concat "$baseline_expected" "$previous_incremental_expected")"
expected_combined_records="$(workload_records_concat "$expected_before_records" "$current_incremental_records")"
workload_manifest_verify_inventory "$all_guest_records" "$expected_combined_records" "Combined guest after pass $incremental_pass"
incremental_file_count="$(workload_records_count "$current_incremental_records")"
incremental_added_bytes="$(workload_records_bytes "$current_incremental_records")"
incremental_added_manifest_sha256="$(workload_records_digest "$current_incremental_records")"
combined_file_count="$(workload_records_count "$expected_combined_records")"
combined_total_bytes="$(workload_records_bytes "$expected_combined_records")"
combined_manifest_sha256="$(workload_records_digest "$expected_combined_records")"
guest_captured_at="$(workflow_timestamp)"
workflow_success "Incremental pass $incremental_pass payload: ${incremental_file_count} files, ${incremental_added_bytes} bytes ($((incremental_added_bytes / 1048576)) MiB) added"
workflow_action "Combined workload after pass $incremental_pass: ${combined_file_count} files, ${combined_total_bytes} bytes ($((combined_total_bytes / 1048576)) MiB); manifest SHA-256: $combined_manifest_sha256"

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
workflow_step "4/5 Wait for incremental pass $incremental_pass completion"
workflow_action "oc wait vmbackup/$INCREMENTAL_BACKUP_NAME -n $NAMESPACE --for=condition=Done --timeout=20m"
wait_for_backup_done "$INCREMENTAL_BACKUP_NAME" "$INCREMENTAL_BACKUP_PVC_NAME" Incremental "$previous_checkpoint"
incremental_backup_done_reason="$(get_backup_done_reason "$INCREMENTAL_BACKUP_NAME")"
workflow_success "$INCREMENTAL_BACKUP_NAME reports Done=True (reason: $incremental_backup_done_reason)"
if backup_done_reason_is_failure "$incremental_backup_done_reason"; then
  printf '%s reached Done=True but the backup actually failed: %s\n' \
    "$INCREMENTAL_BACKUP_NAME" "$incremental_backup_done_reason" >&2
  exit 1
fi

workflow_step "5/5 Validate incremental pass $incremental_pass checkpoint"
incremental_backup_type="$(get_backup_type "$INCREMENTAL_BACKUP_NAME")"
if [[ "$incremental_backup_type" != Incremental ]]; then
  printf 'Expected an Incremental backup; got %s.\n' "$incremental_backup_type" >&2
  exit 1
fi
incremental_checkpoint="$(get_backup_checkpoint "$INCREMENTAL_BACKUP_NAME")"
if [[ -z "$incremental_checkpoint" || "$incremental_checkpoint" == "$previous_checkpoint" ]]; then
  printf 'Incremental pass %s must record a distinct checkpoint (previous %s, current %s).\n' \
    "$incremental_pass" "$previous_checkpoint" "$incremental_checkpoint" >&2
  exit 1
fi
workflow_action "Wait for tracker $TRACKER_NAME to advance to pass $incremental_pass checkpoint $incremental_checkpoint"
wait_for_checkpoint_in_tracker "$incremental_checkpoint"
workflow_success "$INCREMENTAL_BACKUP_NAME is $incremental_backup_type at a distinct tracker checkpoint"

incremental_pvc_requested="$(get_pvc_requested "$INCREMENTAL_BACKUP_PVC_NAME")"
incremental_pvc_capacity="$(get_pvc_capacity "$INCREMENTAL_BACKUP_PVC_NAME")"
workflow_action "Incremental pass $incremental_pass PVC: ${incremental_pvc_requested} requested, ${incremental_pvc_capacity} capacity"
incremental_backup_status="$(get_vm_backup_status)"
if [[ "$(jq -r '.backupName // empty' <<<"$incremental_backup_status")" != "$INCREMENTAL_BACKUP_NAME" ]]; then
  incremental_backup_status='{}'
fi

workload_manifest_append_incremental "$incremental_pass" "$current_incremental_records" "$guest_captured_at"
incremental_record="$(jq -n \
  --argjson pass "$incremental_pass" \
  --arg name "$INCREMENTAL_BACKUP_NAME" \
  --arg type "$incremental_backup_type" \
  --arg checkpoint_name "$incremental_checkpoint" \
  --arg done_reason "$incremental_backup_done_reason" \
  --arg pvc_name "$INCREMENTAL_BACKUP_PVC_NAME" \
  --arg pvc_requested "$incremental_pvc_requested" \
  --arg pvc_capacity "$incremental_pvc_capacity" \
  --argjson files_added "$incremental_file_count" \
  --argjson added_payload_bytes "$incremental_added_bytes" \
  --arg added_manifest_sha256 "$incremental_added_manifest_sha256" \
  --argjson total_file_count "$combined_file_count" \
  --argjson total_payload_bytes "$combined_total_bytes" \
  --arg manifest_sha256 "$combined_manifest_sha256" \
  --arg captured_at "$guest_captured_at" \
  --argjson backup_status "$incremental_backup_status" \
  '{pass: $pass, name: $name, type: $type, checkpoint_name: $checkpoint_name,
    done_reason: $done_reason, pvc_name: $pvc_name, pvc_requested: $pvc_requested,
    pvc_capacity: $pvc_capacity, files_added: $files_added,
    added_payload_bytes: $added_payload_bytes, added_manifest_sha256: $added_manifest_sha256,
    total_file_count: $total_file_count, total_payload_bytes: $total_payload_bytes,
    manifest_sha256: $manifest_sha256, captured_at: $captured_at} + $backup_status')"
vm_info_update \
  '.backups.incrementals += [$record] |
   .incremental_passes_completed = $pass |
   .next_incremental_pass = (if $pass == $total then null else ($pass + 1) end) |
   .status = (if $pass == $total then "verification_pending" else "incremental_ready" end) |
   del(.current_incremental_pass)' \
  --argjson pass "$incremental_pass" \
  --argjson total "$stored_passes_total" \
  --argjson record "$incremental_record"
write_report_fragment "incremental-pass-$pass_suffix" "$(jq -n \
  --arg manifest_path "$WORKLOAD_MANIFEST_NAME" \
  --argjson record "$incremental_record" \
  '{guest: {workload: {manifest_path: $manifest_path,
                       incrementals: [{pass: $record.pass, files_added: $record.files_added,
                                       added_payload_bytes: $record.added_payload_bytes,
                                       added_manifest_sha256: $record.added_manifest_sha256,
                                       total_file_count: $record.total_file_count,
                                       total_payload_bytes: $record.total_payload_bytes,
                                       manifest_sha256: $record.manifest_sha256,
                                       captured_at: $record.captured_at}],
                       combined: {total_file_count: $record.total_file_count,
                                  total_payload_bytes: $record.total_payload_bytes,
                                  manifest_sha256: $record.manifest_sha256}}},
    backups: {incrementals: [$record]}}')"
workflow_success "Incremental pass $incremental_pass/$stored_passes_total recorded at checkpoint $incremental_checkpoint"

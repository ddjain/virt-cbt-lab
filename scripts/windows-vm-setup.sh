#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/workload-manifest.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workload-manifest.sh"
WORKFLOW_NAME="windows-vm-setup"
require_command python3

WINDOWS_IMAGES_NAMESPACE="vm-cbt-images"
WINDOWS_ADMIN_PASSWORD_FILE="${WINDOWS_ADMIN_PASSWORD_FILE:-}"
if [[ -z "$WINDOWS_ADMIN_PASSWORD_FILE" || ! -r "$WINDOWS_ADMIN_PASSWORD_FILE" ]]; then
  printf 'Set WINDOWS_ADMIN_PASSWORD_FILE to a readable local password file (see .env.example).\n' >&2
  exit 1
fi

new_run_id
new_report_id

workflow_step "1/5 Prepare the cached Windows golden image"
if ! oc_cmd get datasource windows-server-2022 -n "$WINDOWS_IMAGES_NAMESPACE" >/dev/null 2>&1; then
  workflow_action "Windows DataSource is absent; running the one-time ISO install and sysprep workflow"
  "$ROOT_DIR/scripts/windows-golden-image-setup.sh"
fi
oc_cmd wait dv/windows-golden -n "$WINDOWS_IMAGES_NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m >/dev/null
workflow_success "Windows DataSource $WINDOWS_IMAGES_NAMESPACE/windows-server-2022 is ready"

workflow_step "2/5 Generate the run-scoped OOBE secret"
OOBE_SECRET="windows-oobe-${RUN_ID}"
TMP_OOBE_FILE="$(mktemp)"
chmod 600 "$TMP_OOBE_FILE"
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  [[ -z "${TMP_OOBE_FILE:-}" || ! -f "$TMP_OOBE_FILE" ]] || rm -f "$TMP_OOBE_FILE"
  exit "$status"
}
trap cleanup EXIT INT TERM
python3 - "$WINDOWS_ADMIN_PASSWORD_FILE" "$ROOT_DIR/scripts/windows-oobe.xml.tmpl" "$TMP_OOBE_FILE" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

password_path, template_path, output_path = map(pathlib.Path, sys.argv[1:])
password = password_path.read_text(encoding="utf-8")
if password.endswith("\n"):
    password = password[:-1]
if password.endswith("\r"):
    password = password[:-1]
if not password or "\n" in password or "\r" in password:
    raise SystemExit("WINDOWS_ADMIN_PASSWORD_FILE must contain one non-empty password line")
template = template_path.read_text(encoding="utf-8")
if template.count("__ADMIN_PASSWORD__") != 1:
    raise SystemExit("Windows OOBE template must contain exactly one password placeholder")
rendered = template.replace("__ADMIN_PASSWORD__", escape(password))
ET.fromstring(rendered)
output_path.write_text(rendered, encoding="utf-8")
PY
workflow_action "Create run-labeled Secret $OOBE_SECRET with key unattend.xml (password never logged)"
oc_cmd delete secret "$OOBE_SECRET" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true
oc_cmd create secret generic "$OOBE_SECRET" -n "$NAMESPACE" \
  --from-file=unattend.xml="$TMP_OOBE_FILE" \
  --dry-run=client -o json |
  jq --arg managed_key "$RUN_LABEL_MANAGED_BY_KEY" \
     --arg managed_value "$RUN_LABEL_MANAGED_BY_VALUE" \
     --arg run_key "$RUN_LABEL_RUN_ID_KEY" \
     --arg run_id "$RUN_ID" \
     '.metadata.labels = {($managed_key): $managed_value, ($run_key): $run_id}' |
  oc_cmd apply -f - >/dev/null
rm -f "$TMP_OOBE_FILE"
TMP_OOBE_FILE=
workflow_success "Run-scoped Windows OOBE Secret is ready"

workflow_step "3/5 Create the CBT-enabled Windows VM"
workflow_action "Ensure namespace $NAMESPACE exists"
oc_cmd create namespace "$NAMESPACE" --dry-run=client -o yaml | oc_cmd apply -f - >/dev/null
workflow_action "Apply Windows VM $VM_NAME with cloned 40Gi root disk and OOBE Secret $OOBE_SECRET"
sed \
  -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__VM_NAME__|$VM_NAME|g" \
  -e "s|__DV_NAME__|$DV_NAME|g" \
  -e "s|__OOBE_SECRET__|$OOBE_SECRET|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
  "$ROOT_DIR/manifests/windows-vm.yaml" | oc_cmd apply -f -
workflow_success "Windows VM resources applied in namespace $NAMESPACE"

# shellcheck source=scripts/windows-guest-agent.sh
source "$ROOT_DIR/scripts/windows-guest-agent.sh"
workflow_step "4/5 Wait for Windows readiness and confirm CBT and Guest Agent"
workflow_action "Wait up to 60m for VM/$VM_NAME to reach Ready after OOBE"
oc_cmd wait "vm/$VM_NAME" -n "$NAMESPACE" --for=jsonpath='{.status.ready}'=true --timeout=60m >/dev/null
cbt_state="$(oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.changedBlockTracking.state}')"
if [[ "$cbt_state" != Enabled ]]; then
  printf 'CBT is not enabled for %s (state: %s). Check the IncrementalBackup feature gate and cbt-demo label selector.\n' \
    "$VM_NAME" "${cbt_state:-unknown}" >&2
  exit 1
fi
workflow_action "Wait for VMI/$VM_NAME QEMU Guest Agent connection"
oc_cmd wait "vmi/$VM_NAME" -n "$NAMESPACE" --for=condition=AgentConnected --timeout=15m >/dev/null
workflow_action "Probe the QEMU Guest Agent socket before guest operations"
wait_for_guest_agent "$VM_NAME" "$NAMESPACE"
workflow_success "Windows VM is Ready; CBT state is $cbt_state and QEMU Guest Agent is connected"

workflow_step "5/5 Verify startup workloads and initialize the baseline file workload"
workflow_action "Verify Python 3.12.4, file/SQLite writes, HTTP 8080, and the SYSTEM startup task on this clone"
if ! guest_exec_script "$VM_NAME" "$NAMESPACE" \
  "$ROOT_DIR/scripts/windows-workload-verify.ps1" \
  'C:\Windows\Temp\cbt-workload-verify.ps1'; then
  workflow_action "Retry workload verification after the transient Windows guest-agent failure"
  wait_for_guest_agent "$VM_NAME" "$NAMESPACE"
  guest_exec_script "$VM_NAME" "$NAMESPACE" \
    "$ROOT_DIR/scripts/windows-workload-verify.ps1" \
    'C:\Windows\Temp\cbt-workload-verify.ps1'
fi

workflow_action "Probe the QEMU Guest Agent socket before guest-file initialization"
wait_for_guest_agent "$VM_NAME" "$NAMESPACE"
workflow_action "Create $GUEST_BASE_FILE_COUNT deterministic files in $WINDOWS_GUEST_WORKLOAD_DIR with sizes from ${GUEST_FILE_SIZE_MIN_MIB}-${GUEST_FILE_SIZE_MAX_MIB}MiB"
baseline_plan="$(workload_file_plan baseline "$GUEST_BASE_FILE_COUNT")"
windows_baseline_items=""
while IFS='|' read -r workload_name workload_size_bytes; do
  [[ -n "$workload_name" ]] || continue
  windows_baseline_items="${windows_baseline_items}  [pscustomobject]@{ Name = '${workload_name}'; SizeBytes = [long]${workload_size_bytes} }"$'\n'
done <<< "$baseline_plan"
windows_setup_command="\$ErrorActionPreference = 'Stop'
\$workloadDirectory = 'C:\\cbt-data\\workload'
[System.IO.Directory]::CreateDirectory(\$workloadDirectory) | Out-Null
if (@(Get-ChildItem -LiteralPath \$workloadDirectory -Force).Count -gt 0) {
  throw \"Workload directory is not empty: \$workloadDirectory\"
}
\$filePlan = @(
${windows_baseline_items})
foreach (\$item in \$filePlan) {
  \$target = Join-Path \$workloadDirectory \$item.Name
  \$temporary = Join-Path \$workloadDirectory ('.cbt-workload-' + \$item.Name + '.tmp')
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
  Move-Item -LiteralPath \$temporary -Destination \$target
  \$actualSize = (Get-Item -LiteralPath \$target).Length
  if (\$actualSize -ne \$item.SizeBytes) {
    throw ('Generated file ' + \$target + ' has size ' + \$actualSize + '; expected ' + \$item.SizeBytes + ' bytes.')
  }
  \$sha256 = (Get-FileHash -LiteralPath \$target -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-Output ('FILE_RECORD=' + \$item.Name + '|' + \$actualSize + '|' + \$sha256)
}
"
guest_output="$(guest_exec "$VM_NAME" "$NAMESPACE" "$windows_setup_command")"
printf '%s\n' "$guest_output"
baseline_records="$(workload_records_from_output "$guest_output")"
workload_manifest_initialize "$baseline_records"
baseline_file_count="$(jq -r '.baseline.file_count' "$(workload_manifest_path)")"
baseline_total_bytes="$(jq -r '.baseline.total_payload_bytes' "$(workload_manifest_path)")"
baseline_total_mib=$((baseline_total_bytes / 1048576))
baseline_manifest_sha256="$(jq -r '.baseline.manifest_sha256' "$(workload_manifest_path)")"
captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_report_fragment "setup" "$(jq -n \
  --arg namespace "$NAMESPACE" \
  --arg vm_name "$VM_NAME" \
  --arg os_profile "$VM_OS" \
  --arg guest_directory "$GUEST_WORKLOAD_DIR" \
  --arg manifest_path "$WORKLOAD_MANIFEST_NAME" \
  --arg manifest_sha256 "$baseline_manifest_sha256" \
  --arg captured_at "$captured_at" \
  --argjson file_count "$baseline_file_count" \
  --argjson total_payload_bytes "$baseline_total_bytes" \
  --argjson min_mib "$GUEST_FILE_SIZE_MIN_MIB" \
  --argjson max_mib "$GUEST_FILE_SIZE_MAX_MIB" \
  '{namespace: $namespace, vm_name: $vm_name, os_profile: $os_profile,
    guest: {workload: {directory: $guest_directory, manifest_path: $manifest_path,
                       size_range_mib: {min_inclusive: $min_mib, max_inclusive: $max_mib},
                       baseline: {file_count: $file_count, total_payload_bytes: $total_payload_bytes,
                                  manifest_sha256: $manifest_sha256, captured_at: $captured_at}}}}')"
workflow_success "Baseline payload: $baseline_file_count files, $baseline_total_bytes bytes (${baseline_total_mib} MiB); manifest at $(workload_manifest_path)"

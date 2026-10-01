#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
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

workflow_step "5/5 Verify startup workloads and initialize C:\\cbt-data\\hello.txt"
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

workflow_action "Use QEMU Guest Agent PowerShell to write a ${GUEST_DATA_SIZE_MB}MiB bounded random payload and flush it to disk"
windows_setup_command="\$ErrorActionPreference = 'Stop'
\$path = 'C:\\cbt-data\\hello.txt'
\$payloadMiB = ${GUEST_DATA_SIZE_MB}
\$encoding = [System.Text.UTF8Encoding]::new(\$false)
[System.IO.Directory]::CreateDirectory('C:\\cbt-data') | Out-Null
[System.IO.File]::WriteAllText(\$path, 'Hello from the Windows VM CBT demo.' + [Environment]::NewLine, \$encoding)
\$stream = [System.IO.File]::Open(\$path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
\$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
  [long]\$remaining = [long]\$payloadMiB * 1048576
  [byte[]]\$buffer = New-Object byte[] 786432
  while (\$remaining -gt 0) {
    \$count = [int][Math]::Min(\$buffer.Length, \$remaining)
    \$rng.GetBytes(\$buffer)
    \$line = [System.Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String(\$buffer, 0, \$count) + [Environment]::NewLine)
    \$stream.Write(\$line, 0, \$line.Length)
    \$remaining -= \$count
  }
  \$stream.Flush(\$true)
} finally {
  \$rng.Dispose()
  \$stream.Dispose()
}
\$hash = (Get-FileHash -LiteralPath \$path -Algorithm SHA256).Hash.ToLowerInvariant()
\$size = (Get-Item -LiteralPath \$path).Length
Write-Output ('SHA256=' + \$hash)
Write-Output ('SIZE_BYTES=' + \$size)"
guest_output="$(guest_exec "$VM_NAME" "$NAMESPACE" "$windows_setup_command")"
printf '%s\n' "$guest_output"
guest_hash="$(sed -n 's/^SHA256=//p' <<<"$guest_output" | tr -d '\r' | tail -n1 | tr '[:upper:]' '[:lower:]')"
guest_size_bytes="$(sed -n 's/^SIZE_BYTES=//p' <<<"$guest_output" | tr -d '\r' | tail -n1)"
if ! [[ "$guest_hash" =~ ^[[:xdigit:]]{64}$ && "$guest_size_bytes" =~ ^[0-9]+$ ]]; then
  printf 'QEMU Guest Agent did not return a valid Windows guest file hash and size.\n' >&2
  exit 1
fi
write_state_file "full-backup.sha256" "$guest_hash"
captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_report_fragment "setup" "$(jq -n \
  --arg namespace "$NAMESPACE" \
  --arg vm_name "$VM_NAME" \
  --arg os_profile "$VM_OS" \
  --arg hello_file_path "$WINDOWS_GUEST_HELLO_FILE" \
  --arg sha256 "$guest_hash" \
  --argjson size_bytes "$guest_size_bytes" \
  --arg captured_at "$captured_at" \
  '{namespace: $namespace, vm_name: $vm_name, os_profile: $os_profile,
    guest: {hello_file_path: $hello_file_path,
            full_backup: {size_bytes: $size_bytes, size_mb: (($size_bytes / 1048576 * 100 | round) / 100), sha256: $sha256, captured_at: $captured_at}}}')"
workflow_success "Windows guest setup is complete; expected full-backup hash recorded in $STATE_DIR"

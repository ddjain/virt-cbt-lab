#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="vm-setup"
require_command ssh
require_command ssh-keygen

new_run_id
new_report_id

workflow_step "1/5 Prepare the Debian golden image"
workflow_action "oc apply -f manifests/debian-image.yaml (namespace vm-cbt-images, DataVolume debian-golden)"
sed "s|__NAMESPACE__|$NAMESPACE|g" "$ROOT_DIR/manifests/debian-image.yaml" | oc_cmd apply -f - >/dev/null
workflow_action "oc wait dv/debian-golden -n vm-cbt-images --for=jsonpath={.status.phase}=Succeeded --timeout=20m"
oc_cmd wait dv/debian-golden -n vm-cbt-images --for=jsonpath='{.status.phase}'=Succeeded --timeout=20m >/dev/null
workflow_success "Debian golden image is ready (downloaded once, reused on subsequent runs)"

workflow_step "2/5 Prepare guest SSH access"
workflow_action "Generate or reuse the guest key at $GUEST_KEY (private key stays local)"
public_key="$(ensure_guest_key)"
workflow_success "Guest key is ready for user $GUEST_USER"

workflow_step "3/5 Create the VM, root disk, namespace, and SSH service"
workflow_action "oc apply -f manifests/vm.yaml (VM $VM_NAME, DataVolume $DV_NAME, service $SSH_SERVICE)"
# Inject only the public key; the private key stays outside the manifest.
sed \
  -e "s|__SSH_PUBLIC_KEY__|$public_key|g" \
  -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__VM_NAME__|$VM_NAME|g" \
  -e "s|__DV_NAME__|$DV_NAME|g" \
  -e "s|__SSH_SERVICE__|$SSH_SERVICE|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
  -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
  -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
  "$ROOT_DIR/manifests/vm.yaml" | oc_cmd apply -f -
workflow_success "VM resources applied in namespace $NAMESPACE"

workflow_step "4/5 Wait for VM readiness and confirm CBT"
workflow_action "oc wait vm/$VM_NAME -n $NAMESPACE --for=jsonpath=.status.ready=true --timeout=20m"
oc_cmd wait "vm/$VM_NAME" -n "$NAMESPACE" --for=jsonpath='{.status.ready}'=true --timeout=20m
cbt_state="$(oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.changedBlockTracking.state}')"
if [[ "$cbt_state" != Enabled ]]; then
  printf 'CBT is not enabled for %s (state: %s). Check the cluster CBT feature gate and VM label selector.\n' "$VM_NAME" "$cbt_state" >&2
  exit 1
fi
workflow_success "VM $VM_NAME is ready; CBT state is $cbt_state"

workflow_step "5/5 Initialize and validate guest data"
workflow_action "Port-forward service $SSH_SERVICE and write ~/hello.txt (${GUEST_DATA_SIZE_MB}MiB payload) as $GUEST_USER"
workflow_action "Print the guest file SHA-256 and size, and record them as the expected full-backup content"
# `sync` before the backup runs: without it, the write can still be sitting
# in the guest's page cache when the external snapshot is taken, so the full
# backup captures an empty/stale hello.txt.
guest_setup_command="
printf '%s\n' \"Hello from the VM CBT demo.\" > ~/hello.txt
head -c ${GUEST_DATA_SIZE_MB}M /dev/urandom | base64 -w0 >> ~/hello.txt
printf '\n' >> ~/hello.txt
sync
sha256sum ~/hello.txt
stat -c 'SIZE_BYTES=%s' ~/hello.txt
"
guest_output="$(guest_ssh "$guest_setup_command")"
printf '%s\n' "$guest_output"
guest_hash_line="$(printf '%s\n' "$guest_output" | grep -v '^SIZE_BYTES=')"
guest_size_bytes="$(printf '%s\n' "$guest_output" | sed -n 's/^SIZE_BYTES=//p')"
guest_hash="$(printf '%s' "$guest_hash_line" | extract_sha256)"
write_state_file "full-backup.sha256" "$guest_hash"
captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_report_fragment "setup" "$(jq -n \
  --arg namespace "$NAMESPACE" \
  --arg vm_name "$VM_NAME" \
  --arg hello_file_path "$GUEST_HELLO_FILE" \
  --arg sha256 "$guest_hash" \
  --argjson size_bytes "$guest_size_bytes" \
  --arg captured_at "$captured_at" \
  '{namespace: $namespace, vm_name: $vm_name,
    guest: {hello_file_path: $hello_file_path,
            full_backup: {size_bytes: $size_bytes, size_mb: (($size_bytes / 1048576 * 100 | round) / 100), sha256: $sha256, captured_at: $captured_at}}}')"
workflow_success "Guest setup is complete; expected full-backup hash recorded in $STATE_DIR"

#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="vm-setup"
require_command ssh
require_command ssh-keygen

workflow_step "1/5 Prepare the Debian golden image"
workflow_action "oc apply -f manifests/debian-image.yaml (namespace vm-cbt-images, DataVolume debian-golden)"
oc_cmd apply -f "$ROOT_DIR/manifests/debian-image.yaml" >/dev/null
workflow_action "oc wait dv/debian-golden -n vm-cbt-images --for=jsonpath={.status.phase}=Succeeded --timeout=20m"
oc_cmd wait dv/debian-golden -n vm-cbt-images --for=jsonpath='{.status.phase}'=Succeeded --timeout=20m >/dev/null
workflow_success "Debian golden image is ready (downloaded once, reused on subsequent runs)"

workflow_step "2/5 Prepare guest SSH access"
workflow_action "Generate or reuse the guest key at $GUEST_KEY (private key stays local)"
public_key="$(ensure_guest_key)"
workflow_success "Guest key is ready for user $GUEST_USER"

workflow_step "3/5 Create the VM, root disk, namespace, and SSH service"
workflow_action "oc apply -f manifests/vm.yaml (VM $VM_NAME, DataVolume vm-cbt-root, service $SSH_SERVICE)"
# Inject only the public key; the private key stays outside the manifest.
sed "s|__SSH_PUBLIC_KEY__|$public_key|g" "$ROOT_DIR/manifests/vm.yaml" | oc_cmd apply -f -
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
workflow_action "Print the guest file SHA-256 and record it as the expected full-backup content"
guest_setup_command="
printf '%s\n' \"Hello from the VM CBT demo.\" > ~/hello.txt
head -c ${GUEST_DATA_SIZE_MB}M /dev/urandom | base64 -w0 >> ~/hello.txt
printf '\n' >> ~/hello.txt
sha256sum ~/hello.txt
"
guest_hash_line="$(guest_ssh "$guest_setup_command")"
printf '%s\n' "$guest_hash_line"
write_state_file "full-backup.sha256" "$(printf '%s' "$guest_hash_line" | extract_sha256)"
workflow_success "Guest setup is complete; expected full-backup hash recorded in $STATE_DIR"

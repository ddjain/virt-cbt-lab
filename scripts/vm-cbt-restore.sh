#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="vm-cbt-restore"
require_command ssh
require_command sed

workflow_step "1/5 Validate the completed single-root backup chain"
workflow_action "Read backup types, Done conditions, and included volumes"
full_type="$(get_backup_type "$FULL_BACKUP_NAME")"
full_done="$(get_backup_done_status "$FULL_BACKUP_NAME")"
full_volumes="$(oc_cmd get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={range .status.includedVolumes[*]}{.volumeName}{"\n"}{end}')"
incremental_type="$(get_backup_type "$INCREMENTAL_BACKUP_NAME")"
incremental_done="$(get_backup_done_status "$INCREMENTAL_BACKUP_NAME")"
incremental_volumes="$(oc_cmd get vmbackup "$INCREMENTAL_BACKUP_NAME" -n "$NAMESPACE" -o 'jsonpath={range .status.includedVolumes[*]}{.volumeName}{"\n"}{end}')"
if [[ "$full_type" != Full || "$full_done" != True || "$full_volumes" != rootdisk ||
      "$incremental_type" != Incremental || "$incremental_done" != True ||
      "$incremental_volumes" != rootdisk ]]; then
  printf 'Restore requires Full/Done=True and Incremental/Done=True with exactly rootdisk included. Full=%s/%s volumes=%s; Incremental=%s/%s volumes=%s\n' \
    "$full_type" "$full_done" "${full_volumes//$'\n'/,}" "$incremental_type" "$incremental_done" "${incremental_volumes//$'\n'/,}" >&2
  exit 1
fi
workflow_success "Backup chain is complete and contains only rootdisk"

workflow_step "2/5 Create the restore conversion resources"
for resource in "vm/$RESTORED_VM_NAME" "pvc/$RESTORED_ROOT_PVC" "job/$RESTORE_JOB_NAME"; do
  if oc_cmd get "$resource" -n "$NAMESPACE" >/dev/null 2>&1; then
    printf '%s already exists in namespace %s; run make clean-all before rerunning the restore.\n' "$resource" "$NAMESPACE" >&2
    exit 1
  fi
done
launcher_pods="$(oc_cmd get pods -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM_NAME" \
  --field-selector=status.phase=Running -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}')"
launcher_count="$(printf '%s\n' "$launcher_pods" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$launcher_count" != 1 ]]; then
  printf 'Expected exactly one running source launcher pod; found %s.\n' "$launcher_count" >&2
  exit 1
fi
launcher_pod="${launcher_pods//$'\n'/}"
compute_image="$(oc_cmd get pod "$launcher_pod" -n "$NAMESPACE" -o 'jsonpath={.spec.containers[?(@.name=="compute")].image}')"
if [[ -z "$compute_image" ]]; then
  printf 'Could not find the compute container image on source launcher pod %s.\n' "$launcher_pod" >&2
  exit 1
fi
workflow_action "Apply restore PVC and Job using source compute image $compute_image"
sed "s|__RESTORE_IMAGE__|$compute_image|g" "$ROOT_DIR/manifests/restore-storage.yaml" | oc_cmd apply -f -
workflow_success "Restore conversion Job $RESTORE_JOB_NAME submitted"

workflow_step "3/5 Reconstruct the post-incremental root image"
workflow_action "Wait up to 20 minutes for Job $RESTORE_JOB_NAME"
if ! oc_cmd wait "job/$RESTORE_JOB_NAME" -n "$NAMESPACE" --for=condition=Complete --timeout=20m; then
  printf 'Restore Job failed or timed out; logs follow:\n' >&2
  oc_cmd logs "job/$RESTORE_JOB_NAME" -n "$NAMESPACE" >&2 || true
  exit 1
fi
oc_cmd logs "job/$RESTORE_JOB_NAME" -n "$NAMESPACE"
workflow_success "Restore Job completed with a flattened disk.img"

workflow_step "4/5 Boot the restored VM"
public_key="$(ensure_guest_key)"
workflow_action "Apply restored VM $RESTORED_VM_NAME and SSH service $RESTORE_SSH_SERVICE"
sed "s|__SSH_PUBLIC_KEY__|$public_key|g" "$ROOT_DIR/manifests/restored-vm.yaml" | oc_cmd apply -f -
workflow_action "oc wait vm/$RESTORED_VM_NAME -n $NAMESPACE --for=jsonpath=.status.ready=true --timeout=20m"
oc_cmd wait "vm/$RESTORED_VM_NAME" -n "$NAMESPACE" --for=jsonpath='{.status.ready}'=true --timeout=20m
workflow_success "Restored VM $RESTORED_VM_NAME is ready"

workflow_step "5/5 Verify the restored guest file"
workflow_action "Read /home/cbt-demo/hello.txt through service $RESTORE_SSH_SERVICE"
restored_check='set -e
expected="Hello from the VM CBT demo.
This line was added after the full backup."
actual="$(cat /home/cbt-demo/hello.txt)"
[ "$actual" = "$expected" ]
sha256sum /home/cbt-demo/hello.txt
'
guest_ssh_to "$RESTORE_SSH_SERVICE" "$restored_check"
workflow_success "Restored guest file contains both exact lines"

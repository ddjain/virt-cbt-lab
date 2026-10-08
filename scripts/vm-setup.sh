#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/workload-manifest.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workload-manifest.sh"
WORKFLOW_NAME="vm-setup"
require_command ssh
require_command ssh-keygen
new_run_id

workflow_step "1/5 Prepare the $VM_OS image source"
case "$VM_OS" in
  debian)
    workflow_action "oc apply -f manifests/debian-image.yaml (namespace vm-cbt-images, DataVolume debian-golden)"
    sed "s|__NAMESPACE__|$NAMESPACE|g" "$ROOT_DIR/manifests/debian-image.yaml" | oc_cmd apply -f - >/dev/null
    workflow_action "oc wait dv/debian-golden -n vm-cbt-images --for=jsonpath={.status.phase}=Succeeded --timeout=20m"
    oc_cmd wait dv/debian-golden -n vm-cbt-images --for=jsonpath='{.status.phase}'=Succeeded --timeout=20m >/dev/null
    workflow_status "Debian golden image is ready (downloaded once, reused on subsequent runs)"
    workflow_success "Debian image source is ready"
    ;;
  rhel9)
    workflow_action "Read DataSource $VM_DATA_SOURCE_NAME in namespace $VM_DATA_SOURCE_NAMESPACE"
    if ! source_pvc_name="$(oc_cmd get datasource "$VM_DATA_SOURCE_NAME" -n "$VM_DATA_SOURCE_NAMESPACE" -o 'jsonpath={.spec.source.pvc.name}')"; then
      printf 'Unable to read RHEL 9 DataSource %s in namespace %s.\n' "$VM_DATA_SOURCE_NAME" "$VM_DATA_SOURCE_NAMESPACE" >&2
      exit 1
    fi
    if [[ -z "$source_pvc_name" ]]; then
      printf 'RHEL 9 DataSource %s does not reference a source PVC.\n' "$VM_DATA_SOURCE_NAME" >&2
      exit 1
    fi
    workflow_action "oc wait pvc/$source_pvc_name -n $VM_DATA_SOURCE_NAMESPACE --for=jsonpath={.status.phase}=Bound --timeout=20m"
    oc_cmd wait "pvc/$source_pvc_name" -n "$VM_DATA_SOURCE_NAMESPACE" --for=jsonpath='{.status.phase}'=Bound --timeout=20m >/dev/null
    workflow_status "RHEL 9 DataSource $VM_DATA_SOURCE_NAME is ready"
    workflow_success "RHEL 9 DataSource is ready"
    ;;
  *)
    printf 'scripts/vm-setup.sh requires VM_OS=debian or rhel9 (got %s).\n' "$VM_OS" >&2
    exit 2
    ;;
esac

workflow_step "2/5 Prepare guest SSH access"
workflow_action "Generate or reuse the guest key at $GUEST_KEY (private key stays local)"
public_key="$(ensure_guest_key)"
workflow_success "Guest key is ready for user $GUEST_USER"

workflow_step "3/5 Create the VM, root disk, namespace, and SSH service"
workflow_action "oc apply -f $(manifest_path vm) (VM $VM_NAME, DataVolume $DV_NAME, service $SSH_SERVICE)"
# Inject only the public key; the private key stays outside the manifest.
sed \
  -e "s|__SSH_PUBLIC_KEY__|$public_key|g" \
  -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__VM_NAME__|$VM_NAME|g" \
  -e "s|__DV_NAME__|$DV_NAME|g" \
  -e "s|__SSH_SERVICE__|$SSH_SERVICE|g" \
  -e "s|__DATA_SOURCE_NAME__|$VM_DATA_SOURCE_NAME|g" \
  -e "s|__DATA_SOURCE_NAMESPACE__|$VM_DATA_SOURCE_NAMESPACE|g" \
  -e "s|__LARGE_DISK_SIZE__|$LARGE_MANIFEST_DISK_SIZE|g" \
  -e "s|__GUEST_LINUX_GROUP__|$GUEST_LINUX_GROUP|g" \
  -e "s|__GUEST_SSHD_SERVICE__|$GUEST_SSHD_SERVICE|g" \
  -e "s|__GUEST_CLOUD_INIT_PACKAGE_UPDATE__|$GUEST_CLOUD_INIT_PACKAGE_UPDATE|g" \
  -e "s|__GUEST_CLOUD_INIT_PACKAGES__|$GUEST_CLOUD_INIT_PACKAGES|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
  -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
  -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
  "$(manifest_path vm)" | oc_cmd apply -f - >/dev/null
workflow_progress "VM resources applied in namespace $NAMESPACE"
workflow_success "VM resources created"

workflow_step "4/5 Wait for VM readiness and confirm CBT"
workflow_action "oc wait vm/$VM_NAME -n $NAMESPACE --for=jsonpath=.status.ready=true --timeout=20m"
oc_cmd wait "vm/$VM_NAME" -n "$NAMESPACE" --for=jsonpath='{.status.ready}'=true --timeout=20m >/dev/null
vm_json="$(oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o json)"
cbt_state="$(jq -r '.status.changedBlockTracking.state // empty' <<< "$vm_json")"
vm_uid="$(jq -r '.metadata.uid // empty' <<< "$vm_json")"
if [[ -z "$vm_uid" ]]; then
  printf 'Could not read Kubernetes UID for VM %s.\n' "$VM_NAME" >&2
  exit 1
fi
if [[ "$cbt_state" != Enabled ]]; then
  printf '        ✗ VM is ready but CBT is not enabled\n' >&2
  printf 'CBT is not enabled for %s (state: %s). Check the cluster CBT feature gate and VM label selector.\n' "$VM_NAME" "$cbt_state" >&2
  exit 1
fi
workflow_progress "VM $VM_NAME is ready; CBT state is $cbt_state"
workflow_success "VM ready · CBT $cbt_state"

workflow_step "5/5 Initialize and validate the baseline file workload"
workflow_action "Create $GUEST_BASE_FILE_COUNT deterministic files in $LINUX_GUEST_WORKLOAD_DIR with sizes from ${GUEST_FILE_SIZE_MIN_MIB}-${GUEST_FILE_SIZE_MAX_MIB}MiB"
baseline_plan="$(workload_file_plan baseline "$GUEST_BASE_FILE_COUNT")"
baseline_items=""
while IFS='|' read -r workload_name workload_size_bytes; do
  [[ -n "$workload_name" ]] || continue
  baseline_items="${baseline_items} '${workload_name}|${workload_size_bytes}'"
done <<< "$baseline_plan"
guest_setup_command="
set -euo pipefail
workload_dir='$LINUX_GUEST_WORKLOAD_DIR'
mkdir -p \"\$workload_dir\"
if [[ -n \"\$(find \"\$workload_dir\" -mindepth 1 -maxdepth 1 -print -quit)\" ]]; then
  printf 'Workload directory is not empty: %s\\n' \"\$workload_dir\" >&2
  exit 1
fi
trap 'rm -f \"\$workload_dir\"/.cbt-workload-*.tmp' EXIT
for workload_spec in ${baseline_items}; do
  IFS='|' read -r name size_bytes <<< \"\$workload_spec\"
  tmp_path=\"\$workload_dir/.cbt-workload-\${name}.tmp\"
  set +o pipefail
  yes \"CBT-WORKLOAD-V1:\${name}\" | head -c \"\$size_bytes\" > \"\$tmp_path\"
  set -o pipefail
  actual_size=\"\$(stat -c '%s' \"\$tmp_path\")\"
  if [[ \"\$actual_size\" != \"\$size_bytes\" ]]; then
    printf 'Generated file %s has size %s; expected %s bytes.\\n' \"\$name\" \"\$actual_size\" \"\$size_bytes\" >&2
    exit 1
  fi
  mv \"\$tmp_path\" \"\$workload_dir/\$name\"
done
sync
for workload_file in \"\$workload_dir\"/base-*.dat; do
  [[ -f \"\$workload_file\" ]] || continue
  name=\"\${workload_file##*/}\"
  size_bytes=\"\$(stat -c '%s' \"\$workload_file\")\"
  sha256=\"\$(sha256sum \"\$workload_file\" | awk '{print \$1}')\"
  printf 'FILE_RECORD=%s|%s|%s\\n' \"\$name\" \"\$size_bytes\" \"\$sha256\"
done
"
guest_output="$(guest_ssh "$guest_setup_command")"
baseline_records="$(workload_records_from_output "$guest_output")"
workload_manifest_initialize "$baseline_records"
vm_info_initialize "$vm_uid"
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
  --argjson incremental_passes_total "$GUEST_INCREMENTAL_PASSES" \
  '{namespace: $namespace, vm_name: $vm_name, os_profile: $os_profile,
    guest: {workload: {directory: $guest_directory, manifest_path: $manifest_path,
                       size_range_mib: {min_inclusive: $min_mib, max_inclusive: $max_mib},
                       incremental_passes_total: $incremental_passes_total,
                       baseline: {file_count: $file_count, total_payload_bytes: $total_payload_bytes,
                                  manifest_sha256: $manifest_sha256, captured_at: $captured_at}}}}')"
workflow_progress "Baseline payload: $baseline_file_count files, $baseline_total_bytes bytes (${baseline_total_mib} MiB); manifest at $(workload_manifest_path)"
workflow_success "Baseline workload · $baseline_file_count files · ${baseline_total_mib} MiB"

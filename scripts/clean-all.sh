#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="clean-all"
if [[ -r "$STATE_DIR/e2e.lock/pid" ]]; then
  e2e_pid="$(cat "$STATE_DIR/e2e.lock/pid")"
  if [[ "$e2e_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$e2e_pid" 2>/dev/null; then
    printf '[clean-all] Refusing cleanup while E2E process %s holds the checkout lock.\n' "$e2e_pid" >&2
    exit 1
  fi
fi

# Every resource kind an E2E run can create directly (VM/DataVolume owned
# child resources like the root PVC cascade-delete with the VM).
MANAGED_RESOURCE_KINDS=(vm dv vmbackup vmbackuptracker pod pvc service secret)

workflow_step "1/3 Delete virt-cbt-lab managed resources in namespace $NAMESPACE"
workflow_action "Recording PVCs labeled $RUN_LABEL_SELECTOR before deletion (for PV reclamation tracking)"
managed_pvc_names=()
while IFS= read -r pvc_name; do
  [[ -n "$pvc_name" ]] && managed_pvc_names+=("$pvc_name")
done < <(
  oc_cmd get pvc -n "$NAMESPACE" -l "$RUN_LABEL_SELECTOR" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
)

for kind in "${MANAGED_RESOURCE_KINDS[@]}"; do
  workflow_action "oc delete $kind -n $NAMESPACE -l $RUN_LABEL_SELECTOR --ignore-not-found=true --wait=true --timeout=10m"
  oc_cmd delete "$kind" -n "$NAMESPACE" -l "$RUN_LABEL_SELECTOR" --ignore-not-found=true --wait=true --timeout=10m
done
workflow_success "All virt-cbt-lab managed resources deleted from namespace $NAMESPACE (unrelated namespace resources preserved)"

workflow_step "2/3 Wait for managed persistent volumes to be reclaimed"
if ((${#managed_pvc_names[@]} == 0)); then
  workflow_success "No managed PVCs were present; nothing to reclaim"
else
  workflow_action "Poll PV claim references for ${#managed_pvc_names[@]} managed PVC(s) (up to 2 minutes)"
  remaining_pv_names=
  for ((attempt = 1; attempt <= 60; attempt++)); do
    remaining_pv_names=""
    for pvc_name in "${managed_pvc_names[@]}"; do
      match="$(oc_cmd get pv -o "jsonpath={range .items[?(@.spec.claimRef.name==\"$pvc_name\")]}{.metadata.name}{\",\"}{end}" 2>/dev/null || true)"
      remaining_pv_names+="$match"
    done
    if [[ -z "$remaining_pv_names" ]]; then
      break
    fi
    if (( attempt == 1 || attempt % 10 == 0 )); then
      workflow_action "PV reclamation pending: ${remaining_pv_names//$'\n'/, } (poll $attempt/60)"
    fi
    sleep 2
  done
  if [[ -n "$remaining_pv_names" ]]; then
    printf '[clean-all] Persistent volumes are not reclaimed yet: %s\n' "${remaining_pv_names//$'\n'/, }" >&2
    exit 1
  fi
  workflow_success "All managed PVs are reclaimed"
fi

workflow_step "3/3 Remove only the workflow-managed guest key and transient lock"
workflow_action "Check ownership marker $GUEST_KEY.vm-cbt-managed before deleting key files"
marker="$GUEST_KEY.vm-cbt-managed"
if [[ -f "$marker" ]]; then
  # The marker prevents cleanup from deleting a key supplied by the user.
  rm -f "$GUEST_KEY" "$GUEST_KEY.pub" "$marker"
  rmdir "$(dirname "$GUEST_KEY")" 2>/dev/null || true
  workflow_success "Removed workflow-managed guest key"
else
  workflow_success "No workflow-managed key found; existing key files preserved"
fi
workflow_action "Mark VM lifecycle records cleaned while preserving per-run report history"
cleaned_at="$(workflow_timestamp)"
for vm_info in "$RUNS_ROOT_DIR"/*/run.json; do
  [[ -f "$vm_info" ]] || continue
  if jq -e --arg namespace "$NAMESPACE" \
      '.namespace == $namespace and .status != "cleaned"' "$vm_info" >/dev/null; then
    tmp_path="${vm_info}.tmp.$$"
    jq --arg cleaned_at "$cleaned_at" \
      'if .current_incremental_pass.status == "running" then
         .current_incremental_pass.status = "interrupted_by_cleanup"
       else . end |
       .status = "cleaned" | .cleaned_at = $cleaned_at | .updated_at = $cleaned_at' \
      "$vm_info" > "$tmp_path"
    mv -f "$tmp_path" "$vm_info"
  fi
done
workflow_success "VM lifecycle records retained with cleaned status"
workflow_action "Removing checkout-local E2E lock state from $STATE_DIR"
rm -rf "$STATE_DIR"
# runs/ is intentionally retained: it holds lifecycle state, reports, and
# restore-test logs for post-run debugging.
printf '[clean-all] Demo cleanup complete; namespace %s and shared KubeVirt/storage resources were left intact.\n' "$NAMESPACE" >&2

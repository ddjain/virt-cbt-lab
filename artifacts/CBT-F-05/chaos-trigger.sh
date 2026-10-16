#!/usr/bin/env bash
# The exact handler node is created during setup; inject via scoped oc at the copy signal.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"

: "${RUN_ID:?Set a unique RUN_ID for this full-backup lifecycle}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved execution-host kubeconfig path}"
if ! valid_run_id "$RUN_ID"; then
  printf 'RUN_ID is not a valid workflow run ID: %s\n' "$RUN_ID" >&2
  exit 2
fi
for command in oc jq make tee grep timeout; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"

VM_NAME="vm-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="${VM_OS:-rhel9}"
MANIFEST_VARIANT="${MANIFEST_VARIANT:-large-odf}"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-8}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-4}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-1024}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-1024}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-F-05/runs/$RUN_ID"
export NAMESPACE

if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s already exists locally; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
fi
# Allow only this run's pre-armed read-only observer directory; any other
# pre-existing content under the evidence dir means the ID is not fresh.
if [[ -d "$EVIDENCE_DIR" ]]; then
  existing_evidence="$(find "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 \
    ! -name observer -print -quit)"
  if [[ -n "$existing_evidence" ]] || [[ ! -d "$EVIDENCE_DIR/observer" ]]; then
    printf 'Run ID %s already has evidence; refusing to reuse it.\n' "$RUN_ID" >&2
    exit 1
  fi
  unexpected_observer_content="$(find "$EVIDENCE_DIR/observer" -mindepth 1 \
    \( -name trigger.log -o -name summary.json \) -print -quit)"
  if [[ -n "$unexpected_observer_content" ]]; then
    printf 'Run ID %s observer already contains run artifacts; refusing to reuse it.\n' "$RUN_ID" >&2
    exit 1
  fi
elif [[ -e "$EVIDENCE_DIR" ]]; then
  printf 'Run ID %s evidence path is not a directory; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Resources for run ID %s already exist in %s; refusing to target them.\n' \
    "$RUN_ID" "$NAMESPACE" >&2
  exit 1
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1

SIGNAL_FILE="$(mktemp)"
observer_pid=
cleanup_observer() {
  if [[ -n "$observer_pid" ]] && kill -0 "$observer_pid" 2>/dev/null; then
    kill "$observer_pid" 2>/dev/null || true
    wait "$observer_pid" 2>/dev/null || true
  fi
  rm -f "$SIGNAL_FILE"
}
trap cleanup_observer EXIT INT TERM

observe_copy_then_disrupt() {
  local deadline=$((SECONDS + 3600)) pod pod_uid node handler handler_uid baseline_tree signal_timestamp
  local baseline_tracker tracker_output signal_line backup_json handler_ds_json handler_now_json ds_desired ds_ready
  while ((SECONDS < deadline)); do
    pod="$(oc get pods -n "$NAMESPACE" \
      -l "vm.kubevirt.io/name=${VM_NAME}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$pod" ]]; then
      if baseline_tree="$(oc exec -n "$NAMESPACE" "$pod" -c compute -- \
        virsh checkpoint-list "${NAMESPACE}_${VM_NAME}" --tree 2>/dev/null)"; then
        baseline_tracker="$(oc get vmbackuptracker "vm-tracker-${RUN_ID}" \
          -n "$NAMESPACE" --ignore-not-found -o name)"
        tracker_output="$(oc get vmbackuptracker "vm-tracker-${RUN_ID}" \
          -n "$NAMESPACE" --ignore-not-found -o yaml 2>/dev/null || true)"
        printf 'Pre-copy launcher=%s\nPre-copy tracker=%s\nPre-copy tracker state:\n%s\nPre-copy checkpoint tree:\n%s\n' \
          "$pod" "${baseline_tracker:-absent}" "$tracker_output" "$baseline_tree" >&2
        if signal_line="$(
          set +o pipefail
          remaining=$((deadline - SECONDS))
          ((remaining > 0)) || exit 1
          timeout "$remaining" oc logs --since-time="$WATCH_START_TIME" --timestamps --follow \
            -n "$NAMESPACE" "$pod" -c compute 2>/dev/null |
            grep -E -m1 "\"backupName\":\"${FULL_BACKUP_NAME}\".*\"msg\":\"Backup started\""
        )"; then
          backup_json="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
            -o json --ignore-not-found 2>/dev/null || true)"
          if [[ -z "$backup_json" ]] || ! jq -e '
            all((.status.conditions // [])[]?; .type != "Done" or .status != "True")
          ' <<<"$backup_json" >/dev/null; then
            printf 'Full backup is terminal or unavailable; refusing late injection.\n' >&2
            return 5
          fi
          signal_timestamp="${signal_line%% *}"
          pod_uid="$(oc get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
          node="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}')"
          [[ -n "$node" ]] || { printf 'VMI node is unavailable after copy signal.\n' >&2; return 1; }
          handler="$(oc get pods -n openshift-cnv \
            -l kubevirt.io=virt-handler \
            --field-selector "spec.nodeName=${node}" \
            -o jsonpath='{.items[0].metadata.name}')"
          [[ -n "$handler" ]] || { printf 'No virt-handler pod found on node %s.\n' "$node" >&2; return 1; }
          handler_uid="$(oc get pod "$handler" -n openshift-cnv -o jsonpath='{.metadata.uid}')"
          printf 'Active-copy signal=%s from launcher %s (UID %s); target virt-handler %s (UID %s) on node %s.\n' \
            "$signal_timestamp" "$pod" "$pod_uid" "$handler" "$handler_uid" "$node" >&2
          oc get pod "$handler" -n openshift-cnv -o json | jq -e \
            --arg node "$node" \
            '.metadata.labels["kubevirt.io"] == "virt-handler" and .spec.nodeName == $node and
             .status.phase == "Running" and
             any(.status.conditions[]?; .type == "Ready" and .status == "True")' >/dev/null
          handler_ds_json="$(oc get ds virt-handler -n openshift-cnv -o json)"
          ds_desired="$(jq -r '.status.desiredNumberScheduled' <<<"$handler_ds_json")"
          ds_ready="$(jq -r '.status.numberReady' <<<"$handler_ds_json")"
          [[ "$ds_desired" =~ ^[1-9][0-9]*$ && "$ds_ready" == "$ds_desired" ]] || {
            printf 'virt-handler DaemonSet is not fully ready before injection (%s/%s).\n' \
              "$ds_ready" "$ds_desired" >&2
            return 1
          }
          printf '%s\t%s\t%s\t%s\n' "$handler" "$handler_uid" "$node" "$ds_desired" > "$SIGNAL_FILE"
          backup_json="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
            -o json --ignore-not-found 2>/dev/null || true)"
          handler_now_json="$(oc get pod "$handler" -n openshift-cnv \
            -o json --ignore-not-found 2>/dev/null || true)"
          if [[ -z "$backup_json" ]] ||
             ! jq -e 'all((.status.conditions // [])[]?; .type != "Done" or .status != "True")' \
               <<<"$backup_json" >/dev/null ||
             ! jq -e --arg uid "$handler_uid" --arg node "$node" '
               .metadata.uid == $uid and .spec.nodeName == $node and .status.phase == "Running" and
               any(.status.conditions[]?; .type == "Ready" and .status == "True")
             ' <<<"$handler_now_json" >/dev/null; then
            printf 'Target or backup changed after the copy signal; refusing pod deletion.\n' >&2
            return 1
          fi
          printf 'Deleting exact virt-handler target with oc: %s uid=%s node=%s\n' \
            "$handler" "$handler_uid" "$node" >&2
          oc delete pod "$handler" -n openshift-cnv --wait=false
          return
        fi
      fi
    fi
    sleep 1
  done
  printf 'Timed out waiting for the launcher and exact Backup started signal.\n' >&2
  return 1
}
 

WATCH_START_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
observe_copy_then_disrupt &
observer_pid=$!

if make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" \
  MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  e2e_status=0
else
  e2e_status=$?
fi

if [[ -s "$SIGNAL_FILE" ]]; then
  signal_observed=true
else
  signal_observed=false
  kill "$observer_pid" 2>/dev/null || true
fi
if wait "$observer_pid"; then
  observer_status=0
else
  observer_status=$?
fi
injection_status=$observer_status
observer_pid=

printf 'E2E exit status: %d; event observer/oc injection status: %d\n' \
  "$e2e_status" "$observer_status" >&2
if [[ "$signal_observed" != true ]]; then
  if ((observer_status != 0)); then exit "$observer_status"; fi
  exit 1
fi
IFS=$'\t' read -r handler_before handler_uid_before node_before desired_before < "$SIGNAL_FILE"
recovery_deadline=$((SECONDS + 120))
recovery_verified=false
while ((SECONDS < recovery_deadline)); do
  old_handler_json="$(oc get pod "$handler_before" -n openshift-cnv \
    -o json --ignore-not-found 2>/dev/null || true)"
  handler_pods_json="$(oc get pods -n openshift-cnv -l kubevirt.io=virt-handler \
    --field-selector "spec.nodeName=$node_before" -o json)"
  handler_ds_json="$(oc get ds virt-handler -n openshift-cnv -o json)"
  replacement_ready="$(jq -e --arg old_uid "$handler_uid_before" --arg node "$node_before" '
    [.items[] | select(.spec.nodeName == $node and .metadata.uid != $old_uid and
      .status.phase == "Running" and
      any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length == 1
  ' <<<"$handler_pods_json" >/dev/null && printf true || printf false)"
  if { [[ -z "$old_handler_json" ]] ||
       [[ "$(jq -r '.metadata.uid // empty' <<<"$old_handler_json")" != "$handler_uid_before" ]]; } &&
     [[ "$replacement_ready" == true ]] &&
     jq -e --arg desired "$desired_before" \
       '.status.desiredNumberScheduled == ($desired|tonumber) and
        .status.numberReady == .status.desiredNumberScheduled' \
       <<<"$handler_ds_json" >/dev/null; then
    recovery_verified=true
    break
  fi
  sleep 1
done
if [[ "$recovery_verified" == true ]]; then
  printf 'virt-handler recovery verified on node %s; replacement pod is Ready; oc injection status=%d\n' \
    "$node_before" "$injection_status" >&2
  observer_status=0
else
  printf 'virt-handler recovery was not verified within 120s; refusing post-chaos backup.\n' >&2
  if ((observer_status != 0)); then exit "$observer_status"; fi
  exit 1
fi
if ((e2e_status != 0)); then
  if make e2e TYPE=recover VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    recovery_status=0
  else
    recovery_status=$?
  fi
  printf 'Full-stage exit status: %d; same-VM recovery status: %d; oc injection status: %d\n' \
    "$e2e_status" "$recovery_status" "$injection_status" >&2
  if ((recovery_status != 0)); then exit "$recovery_status"; fi
  if ((injection_status != 0)); then exit "$injection_status"; fi
  exit 0
fi
planned_passes="$(jq -r '.incremental_passes_total' "$ROOT_DIR/runs/$RUN_ID/run.json")"
if [[ ! "$planned_passes" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Managed run has invalid incremental pass count: %s\n' "$planned_passes" >&2
  exit 2
fi
followup_status=0
for ((pass = 1; pass <= planned_passes; pass++)); do
  if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    :
  else
    followup_status=$?
    break
  fi
done
if ((followup_status != 0)); then exit "$followup_status"; fi
if ((injection_status != 0)); then
  printf 'Harness warning: oc returned %d despite API-confirmed handler recovery.\n' \
    "$injection_status" >&2
  exit "$injection_status"
fi

#!/usr/bin/env bash
# CBT-I-05 r02b: CONTINUATION of run 20261013-cbti05-r02 after the r02
# trigger's harness bug (the PVC-doc extraction dropped the apiVersion
# header → NotFound on apply; full stage had already succeeded and its VM,
# full backup, tracker, and run.json are intact and healthy).
#
# This script performs EXACTLY the stages after the fix point of
# chaos-trigger.sh (r02, md5 0eb8a2a0…): pre-create the p01 destination PVC
# from the stage template, fill it to ~97%, release it, run
# `make e2e TYPE=incremental` against the pre-filled destination, then the
# verdict/recovery logic — identical semantics, identical evidence files.
# Run it with RUN_ID=20261013-cbti05-r02 KUBECONFIG_PATH=…
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set RUN_ID (continuation expects 20261013-cbti05-r02)}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved execution-host kubeconfig path}"
for command in oc jq make tee kubectl; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
MANIFEST_VARIANT="odf"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
FILLER_IMAGE="registry.redhat.io/rhel9/toolbox:latest"
FILLER_POD_NAME="filler-${RUN_ID}"
FILL_SIZE="29G"
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
INCR_BACKUP_NAME="vm-incremental-${RUN_ID}-p01"
INCR_PVC_NAME="vm-incremental-pvc-${RUN_ID}-p01"
RETRY_BACKUP_NAME="vm-incremental-${RUN_ID}-p02"
RETRY_PVC_NAME="vm-incremental-pvc-${RUN_ID}-p02"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-I-05/runs/$RUN_ID"
# Continuation preconditions: run dir + run.json exist (full stage done), VM
# Running, tracker on the full checkpoint, p01 objects ABSENT.
[[ -f "$ROOT_DIR/runs/$RUN_ID/run.json" ]] || { printf 'Missing runs/%s/run.json — not a continuation state.\n' "$RUN_ID" >&2; exit 2; }
[[ -d "$EVIDENCE_DIR" ]] || { printf 'Missing evidence dir %s.\n' "$EVIDENCE_DIR" >&2; exit 2; }
oc get vmi "$VM_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || { printf 'VMI %s not Running.\n' "$VM_NAME" >&2; exit 2; }
if oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf 'p01 vmbackup already exists — refusing to continue.\n' >&2
  exit 2
fi
if oc get pvc "$INCR_PVC_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  printf 'p01 PVC already exists — refusing to continue.\n' >&2
  exit 2
fi
full_checkpoint="$(jq -r '.backups.full.checkpoint_name' "$ROOT_DIR/runs/$RUN_ID/run.json")"
printf 'Continuation: full checkpoint %s; pre-filling the incremental destination.\n' "$full_checkpoint" >&2
exec >>"$EVIDENCE_DIR/trigger.log" 2>&1

# --- Stage 2a: pre-create the p01 destination PVC (exact stage template) ----
printf '%s\n' "$INCR_PVC_NAME" >"$EVIDENCE_DIR/precreated-pvc.txt"
sed \
  -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__INCREMENTAL_BACKUP_NAME__|$INCR_BACKUP_NAME|g" \
  -e "s|__INCREMENTAL_BACKUP_PVC__|$INCR_PVC_NAME|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_KEY__|app.kubernetes.io/managed-by|g" \
  -e "s|__MANAGED_BY_VALUE__|virt-cbt-lab|g" \
  -e "s|__RUN_ID_LABEL_KEY__|virt-cbt-lab/run-id|g" \
  "$(manifest_path incremental-backup)" >"$EVIDENCE_DIR/incremental-backup-p01-prefill.yaml"
# Split off ONLY the PVC document (the vmbackup must NOT be created yet).
# Record-separator split keeps the apiVersion header with the kind (a
# "kind-only" extraction produced resource-less YAML → NotFound on apply).
awk -v RS='---' '/PersistentVolumeClaim/{print; exit}' \
  "$EVIDENCE_DIR/incremental-backup-p01-prefill.yaml" \
  | oc apply -f - >/dev/null
printf 'Pre-created destination PVC %s (from the stage template).\n' "$INCR_PVC_NAME" >&2
if ! oc wait "pvc/$INCR_PVC_NAME" -n "$NAMESPACE" \
    --for=jsonpath='{.status.phase}'=Bound --timeout=300s 2>/dev/null; then
  printf 'Pre-created PVC did not become Bound in 5m — aborting.\n' >&2
  exit 2
fi

# --- Stage 2b: fill the destination PVC to ~97% ------------------------------
kubectl run "$FILLER_POD_NAME" \
  --namespace "$NAMESPACE" \
  --restart=Never \
  --image="$FILLER_IMAGE" \
  --overrides "{\"spec\":{\"containers\":[{\"name\":\"filler\",\"image\":\"${FILLER_IMAGE}\",\"command\":[\"sh\",\"-c\",\"df -B1 /data | tail -1 > /fill-report.txt; fallocate -l ${FILL_SIZE} /data/.cbt-filler && df -B1 /data | tail -1 >> /fill-report.txt; sync; cat /fill-report.txt; echo FILLER_DONE\"],\"securityContext\":{\"privileged\":true},\"volumeMounts\":[{\"name\":\"v\",\"mountPath\":\"/data\"}]}],\"volumes\":[{\"name\":\"v\",\"persistentVolumeClaim\":{\"claimName\":\"${INCR_PVC_NAME}\"}}]}}" \
  >/dev/null
injection_requested_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' "$injection_requested_utc" >"$EVIDENCE_DIR/injection-requested-utc.txt"
printf 'UTC action request: create %s mounting %s at %s (pre-fill before backup creation).\n' \
  "$FILLER_POD_NAME" "$INCR_PVC_NAME" "$injection_requested_utc" >&2
filler_phase="unknown"
for ((i = 0; i < 60; i++)); do
  filler_phase="$(oc get pod "$FILLER_POD_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)"
  [[ "$filler_phase" == Succeeded || "$filler_phase" == Failed ]] && break
  sleep 5
done
printf 'Filler pod phase: %s\n' "$filler_phase" >&2
oc logs "$FILLER_POD_NAME" -n "$NAMESPACE" >"$EVIDENCE_DIR/filler-pod.log" 2>/dev/null || true
oc get pod "$FILLER_POD_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/filler-pod.yaml" 2>/dev/null || true
if [[ "$filler_phase" != Succeeded ]]; then
  printf 'Filler did not Succeed (phase=%s) — aborting before backup creation.\n' "$filler_phase" >&2
  exit 2
fi
if ! grep -q FILLER_DONE "$EVIDENCE_DIR/filler-pod.log" 2>/dev/null; then
  printf 'Filler log lacks FILLER_DONE marker — fill result uncertain; aborting.\n' >&2
  exit 2
fi
printf 'Destination pre-filled (df before/after in filler-pod.log).\n' >&2
kubectl delete "pod/$FILLER_POD_NAME" -n "$NAMESPACE" --wait=true >/dev/null 2>&1 || true
pods_mounting=""
for ((i = 0; i < 60; i++)); do
  pods_mounting="$(oc get pods -n "$NAMESPACE" -o json 2>/dev/null | jq -r \
    --arg pvc "$INCR_PVC_NAME" \
    '.items[] | select(.spec.volumes[]? | (.persistentVolumeClaim.claimName // "") == $pvc) | .metadata.name' | grep -v "^$" || true)"
  [[ -z "$pods_mounting" ]] && break
  sleep 2
done
printf 'Volume release check: pods still mounting PVC: [%s]\n' "${pods_mounting:-none}" >&2
if [[ -n "${pods_mounting:-}" ]]; then
  printf 'PVC still mounted by [%s] after 2m — aborting.\n' "$pods_mounting" >&2
  exit 2
fi

# --- Stage 3: incremental pass against the pre-filled destination ------------
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  incr_status=0
else
  incr_status=$?
fi
printf 'Incremental stage exit status: %d (expected: nonzero — destination exhaustion).\n' "$incr_status" >&2

# --- Evidence: p01 terminal state, tracker -----------------------------------
oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/incremental-backup-p01.yaml" 2>/dev/null || true
p01_done="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
p01_reason="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
p01_message="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].message}' 2>/dev/null || true)"
p01_cp="$(oc get vmbackup "$INCR_BACKUP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.checkpointName}' 2>/dev/null || true)"
printf 'P01 TERMINAL STATE: Done=%s reason=%s message=%s checkpoint=%s\n' \
  "${p01_done:-unknown}" "${p01_reason:-unknown}" "${p01_message:-none}" "${p01_cp:-none}" >&2

# --- Stage 4: tracker poll for 2 minutes -------------------------------------
tracker_observations="$EVIDENCE_DIR/tracker-observations.txt"
: >"$tracker_observations"
for ((i = 0; i <= 24; i++)); do
  cp_now="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || true)"
  printf '%s tracker.latestCheckpoint=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${cp_now:-<empty>}" | tee -a "$tracker_observations" >&2
  ((i < 24)) && sleep 5
done
tracker_final="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml)" || tracker_final=""
printf '%s\n' "$tracker_final" >"$EVIDENCE_DIR/tracker-final.yaml"
tracker_final_cp="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || true)"

# --- Verify the Jira expectations -------------------------------------------
verdict_notes=()
# (a) clean failure
if [[ "$p01_done" == "True" && "$p01_reason" != "Successfully completed VirtualMachineBackup" && -n "$p01_reason" ]]; then
  clean_failure="PASS (Done=True reason=$p01_reason)"
elif [[ "$p01_done" == "True" && "$p01_reason" == "Successfully completed VirtualMachineBackup" ]]; then
  clean_failure="UNEXPECTED-SUCCESS (p01 Done=True success against pre-filled destination; investigate: fill erased OR copy smaller than slack)"
  printf '%s\n' "UNEXPECTED-SUCCESS: p01 succeeded against the pre-filled destination. Capturing post-backup df for diagnosis." >&2
  kubectl run "postbackup-df-${RUN_ID}" --namespace "$NAMESPACE" --restart=Never \
    --image="$FILLER_IMAGE" \
    --overrides "{\"spec\":{\"containers\":[{\"name\":\"df\",\"image\":\"${FILLER_IMAGE}\",\"command\":[\"sh\",\"-c\",\"df -B1 /data; ls -la /data | head -20\"],\"securityContext\":{\"privileged\":true},\"volumeMounts\":[{\"name\":\"v\",\"mountPath\":\"/data\"}]}],\"volumes\":[{\"name\":\"v\",\"persistentVolumeClaim\":{\"claimName\":\"${INCR_PVC_NAME}\"}}]}}" \
    >/dev/null 2>&1 || true
  for ((i = 0; i < 36; i++)); do
    ph="$(oc get pod "postbackup-df-${RUN_ID}" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)"
    [[ "$ph" == Succeeded || "$ph" == Failed ]] && break
    sleep 5
  done
  oc logs "postbackup-df-${RUN_ID}" -n "$NAMESPACE" >"$EVIDENCE_DIR/postbackup-df.log" 2>/dev/null || true
  if grep -q ".cbt-filler" "$EVIDENCE_DIR/postbackup-df.log" 2>/dev/null; then
    clean_failure="UNEXPECTED-SUCCESS (fill FILE SURVIVED — backup wrote around/into remaining space; see postbackup-df.log)"
  elif grep -q "Filesystem" "$EVIDENCE_DIR/postbackup-df.log" 2>/dev/null; then
    clean_failure="UNEXPECTED-SUCCESS (fill file GONE — controller erased/reformatted the destination; see postbackup-df.log)"
  fi
  kubectl delete "pod/postbackup-df-${RUN_ID}" -n "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
else
  clean_failure="FAIL (p01 never reached a terminal Done state: Done=${p01_done:-absent})"
fi
printf 'CHECK clean-failure: %s\n' "$clean_failure" >&2
verdict_notes+=("clean-failure:$clean_failure")

# (b) tracker keeps the FULL checkpoint
if [[ "$tracker_final_cp" == "$full_checkpoint" ]]; then
  tracker_keeps="PASS (tracker holds FULL checkpoint $full_checkpoint through the 2-min poll)"
elif [[ -z "$tracker_final_cp" ]]; then
  tracker_keeps="FAIL-CLEARED (tracker.latestCheckpoint became EMPTY — the I-02 clearing semantic fired with the VMI alive)"
else
  tracker_keeps="FAIL (tracker moved to unexpected checkpoint: $tracker_final_cp)"
fi
printf 'CHECK tracker-keeps-full: %s\n' "$tracker_keeps" >&2
verdict_notes+=("tracker-keeps-full:$tracker_keeps")

# (c) full-only restore: workflow restore-test refuses failed pass plans (I-02 gap)
if ((incr_status == 0)); then
  full_only_result="skipped (stage succeeded — its own verification ran)"
else
  full_only_result="not-run (workflow restore-test refuses a failed pass plan — I-02-class gap)"
fi
printf 'CHECK full-artifact-restorable: %s\n' "$full_only_result" >&2
verdict_notes+=("full-artifact-restorable:$full_only_result")

# (d) Jira recovery: fresh destination PVC (p02) at the API level.
recovery_result="not-run"
if [[ "$tracker_final_cp" == "$full_checkpoint" ]]; then
  printf 'Recovery: applying fresh destination %s + backup %s (ODF template, pass-02 names).\n' \
    "$RETRY_PVC_NAME" "$RETRY_BACKUP_NAME" >&2
  sed \
    -e "s|__NAMESPACE__|$NAMESPACE|g" \
    -e "s|__TRACKER_NAME__|$TRACKER_NAME|g" \
    -e "s|__INCREMENTAL_BACKUP_NAME__|$RETRY_BACKUP_NAME|g" \
    -e "s|__INCREMENTAL_BACKUP_PVC__|$RETRY_PVC_NAME|g" \
    -e "s|__RUN_ID__|$RUN_ID|g" \
    -e "s|__MANAGED_BY_KEY__|app.kubernetes.io/managed-by|g" \
    -e "s|__MANAGED_BY_VALUE__|virt-cbt-lab|g" \
    -e "s|__RUN_ID_LABEL_KEY__|virt-cbt-lab/run-id|g" \
    "$(manifest_path incremental-backup)" | oc apply -f - >/dev/null
  recovery_result="applied"
  if oc wait "vmbackup/$RETRY_BACKUP_NAME" -n "$NAMESPACE" \
      --for=condition=Done --timeout=20m 2>/dev/null; then
    retry_done="$(oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Done")].status}')"
    retry_type="$(oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.type}')"
    retry_cp="$(oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.checkpointName}')"
    if [[ "$retry_done" == "True" && "$retry_type" == "Incremental" ]]; then
      recovery_result="PASS (p02 Incremental, checkpoint ${retry_cp:-?})"
    else
      recovery_result="FAIL (Done=$retry_done type=$retry_type)"
    fi
    oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
      >"$EVIDENCE_DIR/incremental-backup-p02.yaml" 2>/dev/null || true
  else
    recovery_result="FAIL (p02 did not reach Done in 20m)"
    oc get vmbackup "$RETRY_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
      >"$EVIDENCE_DIR/incremental-backup-p02.yaml" 2>/dev/null || true
  fi
  tracker_post_retry="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || true)"
  printf 'Tracker after recovery: %s\n' "${tracker_post_retry:-<empty>}" >&2
fi
printf 'CHECK recovery-fresh-pvc: %s\n' "$recovery_result" >&2
verdict_notes+=("recovery-fresh-pvc:$recovery_result")

# --- Summary ----------------------------------------------------------------
printf 'I05 VERDICT NOTES: %s\n' "${verdict_notes[*]}" >&2
printf 'Scenario complete: destination-exhaustion evidence collected (p01 reason, tracker, recovery path above).\n' >&2
exit 0

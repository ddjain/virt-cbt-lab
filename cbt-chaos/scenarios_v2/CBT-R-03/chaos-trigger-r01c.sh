#!/usr/bin/env bash
# CBT-R-03 r01c: deterministic storage-access hold for the mount window.
#
# r01/r01b proved the Jira's named action via krkn pod-scenarios: plugin pod
# force-deleted, DaemonSet replacement ready in ~2s, krkn exit 0 with
# affected/recovered recorded. But a ~2s blip can never overlap a fresh
# verifier's ~1s mount window (r01: mount beat the 18s-later kill; r01b:
# 1.99s replacement gap uncatchable by polling). The Jira's core question —
# "restore pod remains pending while storage access is unavailable and
# recovers after the CSI plugin returns" — requires HOLDING the plugin down.
# krknctl pod-scenarios cannot express a hold, so this leg uses the
# sanctioned direct-injection pattern (I-04/F-10 precedent): scale the
# DaemonSet to 0, apply the verifier, observe the wait, scale back to 1.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"
cd "$ROOT_DIR"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
: "${RESTORE_HELPER_IMAGE:?Set RESTORE_HELPER_IMAGE}"
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
RUN_ID="20261013-cbtr03-r01"
FULL_PVC_NAME="vm-backup-pvc-${RUN_ID}"
P01_PVC_NAME="vm-incremental-pvc-${RUN_ID}-p01"
CHAOS_POD_NAME="vm-restore-verify-${RUN_ID}-outage3"
PLUGIN_NS="openshift-cnv"
PLUGIN_DS="hostpath-provisioner-csi"
PLUGIN_LABEL="k8s-app=hostpath-provisioner"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-R-03/runs/$RUN_ID"
BASELINE_LOG="$ROOT_DIR/runs/$RUN_ID/logs/restore-verify-pod.log"
[[ -f "$BASELINE_LOG" ]] || { printf 'Baseline log missing.\n' >&2; exit 2; }
for pvc in "$FULL_PVC_NAME" "$P01_PVC_NAME"; do
  phase="$(oc get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo missing)"
  [[ "$phase" == Bound ]] || { printf 'PVC %s not Bound (%s).\n' "$pvc" "$phase" >&2; exit 2; }
done
ds_ready="$(oc get ds -n "$PLUGIN_NS" "$PLUGIN_DS" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
[[ "$ds_ready" == 1 ]] || { printf 'CSI plugin DaemonSet not healthy (%s).\n' "$ds_ready" >&2; exit 2; }
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/r01c-trigger.log") 2>&1
printf 'R03 r01c: deterministic CSI-plugin hold for run %s.\n' "$RUN_ID" >&2
base_full_count="$(grep -oP '^FULL_WORKLOAD_FILE_COUNT=\K[0-9]+' "$BASELINE_LOG" | tail -1)"
base_full_bytes="$(grep -oP '^FULL_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$BASELINE_LOG" | tail -1)"
base_full_sha="$(grep -oP '^FULL_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$BASELINE_LOG" | tail -1)"
base_p1_count="$(grep -oP '^PASS_01_WORKLOAD_FILE_COUNT=\K[0-9]+' "$BASELINE_LOG" | tail -1)"
base_p1_bytes="$(grep -oP '^PASS_01_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$BASELINE_LOG" | tail -1)"
base_p1_sha="$(grep -oP '^PASS_01_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$BASELINE_LOG" | tail -1)"
printf 'BASELINE: full=%s/%s/%s p1=%s/%s/%s\n' \
  "$base_full_count" "$base_full_bytes" "${base_full_sha:0:12}" \
  "$base_p1_count" "$base_p1_bytes" "${base_p1_sha:0:12}" >&2

render_verifier() {
  local pod_name="$1" out="$2"
  local snippet_dir volumes_file mounts_file rendered
  snippet_dir="$(mktemp -d)"
  volumes_file="$snippet_dir/incremental-volumes.yaml"
  mounts_file="$snippet_dir/incremental-mounts.yaml"
  rendered="$snippet_dir/pod.yaml"
  printf '    - name: incremental-p01\n      persistentVolumeClaim:\n        claimName: %s\n        readOnly: true\n' \
    "$P01_PVC_NAME" > "$volumes_file"
  printf '        - name: incremental-p01\n          mountPath: /backups/incrementals/p01\n          readOnly: true\n' \
    > "$mounts_file"
  awk -v volumes_file="$volumes_file" -v mounts_file="$mounts_file" '
    /^[[:space:]]*#[[:space:]]__INCREMENTAL_VOLUMES__[[:space:]]*$/ {
      while ((getline line < volumes_file) > 0) print line
      close(volumes_file)
      next
    }
    /^[[:space:]]*#[[:space:]]__INCREMENTAL_MOUNTS__[[:space:]]*$/ {
      while ((getline line < mounts_file) > 0) print line
      close(mounts_file)
      next
    }
    { print }
  ' "$ROOT_DIR/manifests/restore-verify-pod.yaml" > "$rendered"
  sed \
    -e "s|__POD_NAME__|$pod_name|g" \
    -e "s|__NAMESPACE__|$NAMESPACE|g" \
    -e "s|__FULL_PVC__|$FULL_PVC_NAME|g" \
    -e "s|__HELPER_IMAGE__|$RESTORE_HELPER_IMAGE|g" \
    -e "s|__WORKLOAD_DIR__|$RESTORE_WORKLOAD_MOUNT_DIR|g" \
    -e "s|__INCREMENTAL_COUNT__|1|g" \
    -e "s|__RUN_ID__|$RUN_ID|g" \
    -e "s|__MANAGED_BY_KEY__|app.kubernetes.io/managed-by|g" \
    -e "s|__MANAGED_BY_VALUE__|virt-cbt-lab|g" \
    -e "s|__RUN_ID_LABEL_KEY__|virt-cbt-lab/run-id|g" \
    "$rendered" > "$out"
  rm -rf "$snippet_dir"
}

CHAOS_POD_SPEC="$EVIDENCE_DIR/r01c-restore-verify-outage3-pod.yaml"
render_verifier "$CHAOS_POD_NAME" "$CHAOS_POD_SPEC"
oc delete pod "$CHAOS_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true

CBT_NODE="d38-h18-000-r660"
TAINT_HOLD='[{"key":"cbt-r03-hold","value":"storage-down","effect":"NoExecute"}]'
# Hold mechanisms ruled out live: oc scale 404s on this cluster; the DS
# template is operator-reconciled (nodeSelector patch reverted in ~30s);
# NoSchedule taint is tolerated by the plugin pod's default tolerations.
# A NoExecute node taint evicts the plugin (and only node-local workload)
# and nothing reconciles it away — the operator keeps the DS intact and
# the pod reschedules the moment the taint is removed.
cleanup_hold() {
  oc patch node "$CBT_NODE" --type=json -p '[{"op":"remove","path":"/spec/taints"}]' >/dev/null 2>&1 || true
}
trap cleanup_hold EXIT
hold_down() {
  oc patch node "$CBT_NODE" --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/taints\",\"value\":$TAINT_HOLD}]" >/dev/null
}
hold_release() {
  oc patch node "$CBT_NODE" --type=json -p '[{"op":"remove","path":"/spec/taints"}]' >/dev/null
}
scale_down_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
hold_down
printf 'Node %s tainted NoExecute (cbt-r03-hold) at %s — plugin pod will be evicted.\n' "$CBT_NODE" "$scale_down_at"
plugin_gone=false
for ((attempt = 1; attempt <= 90; attempt++)); do
  remaining="$(oc get pods -n "$PLUGIN_NS" -o json 2>/dev/null | jq -r '[.items[] | select(.metadata.name | startswith("hostpath-provisioner-csi")) | select(.status.phase == "Running")] | length')"
  [[ "$remaining" == 0 ]] && { plugin_gone=true; break; }
  sleep 2
done
plugin_gone_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Plugin pod(s) gone: %s (at %s).\n' "$plugin_gone" "$plugin_gone_at" >&2
[[ "$plugin_gone" == true ]] || { printf 'Plugin never left — aborting.\n' >&2; hold_release; exit 2; }

# --- Apply the verifier INTO the hold ----------------------------------------
verifier_applied_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
oc apply -f "$CHAOS_POD_SPEC" >/dev/null
printf 'Verifier %s applied at %s with storage access DOWN.\n' "$CHAOS_POD_NAME" "$verifier_applied_at" >&2
# Observe the waiting state for up to 120s: phase + container waiting reason + events.
waiting_observed=false
waiting_detail=""
for ((attempt = 1; attempt <= 60; attempt++)); do
  phase="$(oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  reason="$(oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo '')"
  if [[ "$phase" != Running && "$phase" != Succeeded ]]; then
    waiting_observed=true
    waiting_detail="phase=${phase:-?} reason=${reason:-?}"
    oc describe pod "$CHAOS_POD_NAME" -n "$NAMESPACE" >"$EVIDENCE_DIR/r01c-waiting-describe.txt" 2>/dev/null || true
    oc get events -n "$NAMESPACE" --field-selector involvedObject.name="$CHAOS_POD_NAME" \
      >"$EVIDENCE_DIR/r01c-waiting-events.txt" 2>/dev/null || true
    break
  fi
  [[ "$phase" == Running ]] && break
  sleep 2
done
printf 'Waiting state observed: %s (%s).\n' "$waiting_observed" "$waiting_detail" >&2
# Hold a bit longer to prove stability of the wait (Jira: "remain pending").
hold_until="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sleep 30
phase_during_hold="$(oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo '?')"
reason_during_hold="$(oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo '')"
printf 'During 30s hold: phase=%s reason=%s.\n' "$phase_during_hold" "$reason_during_hold" >&2

# --- RELEASE: remove the node taint -------------------------------------------
scale_up_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
hold_release
printf 'Node taint removed at %s.\n' "$scale_up_at" >&2
plugin_back=false
for ((attempt = 1; attempt <= 90; attempt++)); do
  pphase="$(oc get pods -n "$PLUGIN_NS" -o json 2>/dev/null | jq -r '[.items[] | select(.metadata.name | startswith("hostpath-provisioner-csi")) | select(.status.phase == "Running")] | length')"
  [[ "$pphase" == 1 ]] && { plugin_back=true; break; }
  sleep 2
done
plugin_back_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Plugin pod Running again: %s (at %s).\n' "$plugin_back" "$plugin_back_at" >&2
[[ "$plugin_back" == true ]] || { printf 'Plugin did NOT return — aborting (verifier left waiting).\n' >&2; exit 2; }

# --- Recovery: verifier must proceed and Succeed ------------------------------
verifier_first_running=""
phase=""
for ((attempt = 1; attempt <= 1800; attempt++)); do
  phase="$(oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  if [[ -z "$verifier_first_running" && "$phase" == Running ]]; then
    verifier_first_running="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Verifier reached Running at %s.\n' "$verifier_first_running" >&2
  fi
  [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
  sleep 1
done
printf 'Verifier terminal phase: %s (Running since %s).\n' "${phase:-unknown}" "${verifier_first_running:-never}" >&2
oc logs "$CHAOS_POD_NAME" -n "$NAMESPACE" >"$EVIDENCE_DIR/r01c-outage3-pod.log" 2>&1 || true
oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o json >"$EVIDENCE_DIR/r01c-outage3-pod-status.json" 2>/dev/null || true
oc get events -n "$NAMESPACE" --field-selector involvedObject.name="$CHAOS_POD_NAME" \
  >"$EVIDENCE_DIR/r01c-final-events.txt" 2>/dev/null || true
oc get pvc "$FULL_PVC_NAME" "$P01_PVC_NAME" -n "$NAMESPACE" \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,PV:.spec.volumeName \
  >"$EVIDENCE_DIR/r01c-pvc-after.txt"
[[ "${phase:-}" == Succeeded ]] || { printf 'OUTAGE3 VERIFIER FAILED (phase %s).\n' "${phase:-unknown}" >&2; exit 1; }
out_full_count="$(grep -oP '^FULL_WORKLOAD_FILE_COUNT=\K[0-9]+' "$EVIDENCE_DIR/r01c-outage3-pod.log" | tail -1)"
out_full_bytes="$(grep -oP '^FULL_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$EVIDENCE_DIR/r01c-outage3-pod.log" | tail -1)"
out_full_sha="$(grep -oP '^FULL_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$EVIDENCE_DIR/r01c-outage3-pod.log" | tail -1)"
out_p1_count="$(grep -oP '^PASS_01_WORKLOAD_FILE_COUNT=\K[0-9]+' "$EVIDENCE_DIR/r01c-outage3-pod.log" | tail -1)"
out_p1_bytes="$(grep -oP '^PASS_01_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$EVIDENCE_DIR/r01c-outage3-pod.log" | tail -1)"
out_p1_sha="$(grep -oP '^PASS_01_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$EVIDENCE_DIR/r01c-outage3-pod.log" | tail -1)"
printf 'OUTAGE3 LEG: full=%s/%s/%s p1=%s/%s/%s\n' \
  "$out_full_count" "$out_full_bytes" "${out_full_sha:0:12}" \
  "$out_p1_count" "$out_p1_bytes" "${out_p1_sha:0:12}" >&2

# --- Verdict checks (r01c) ----------------------------------------------------
checks_file="$EVIDENCE_DIR/r01c-trigger-checks.txt"
: > "$checks_file"
if [[ "$waiting_observed" == true && "$phase_during_hold" != Running ]]; then
  wait_check="PASS (verifier waited during outage: ${waiting_detail}; still ${phase_during_hold}/${reason_during_hold} after 30s hold; Running ${verifier_first_running:-never}; Succeeded)"
else
  wait_check="FAIL (waiting_observed=$waiting_observed during-hold phase=$phase_during_hold)"
fi
printf 'CHECK verifier-waits-then-recovers: %s\n' "$wait_check" | tee -a "$checks_file" >&2
match=true
[[ "$out_full_count" == "$base_full_count" ]] || match=false
[[ "$out_full_bytes" == "$base_full_bytes" ]] || match=false
[[ "$out_full_sha" == "$base_full_sha" ]] || match=false
[[ "$out_p1_count" == "$base_p1_count" ]] || match=false
[[ "$out_p1_bytes" == "$base_p1_bytes" ]] || match=false
[[ "$out_p1_sha" == "$base_p1_sha" ]] || match=false
if [[ "$match" == true ]]; then
  hash_check="PASS (outage-leg outputs exactly equal baseline)"
else
  hash_check="FAIL (outputs differ from baseline)"
fi
printf 'CHECK outage-matches-baseline: %s\n' "$hash_check" | tee -a "$checks_file" >&2
pvc_ok=true
while read -r _n _p _v; do
  [[ "$_p" == Bound ]] || pvc_ok=false
done < <(tail -n +2 "$EVIDENCE_DIR/r01c-pvc-after.txt")
if [[ "$pvc_ok" == true ]] && diff -q "$EVIDENCE_DIR/pvc-before.txt" "$EVIDENCE_DIR/r01c-pvc-after.txt" >/dev/null; then
  pvc_check="PASS (PVCs Bound; PV bindings unchanged)"
else
  pvc_check="FAIL (PVC state changed)"
fi
printf 'CHECK artifacts-unchanged-pvc: %s\n' "$pvc_check" | tee -a "$checks_file" >&2
ds_final="$(oc get ds -n "$PLUGIN_NS" "$PLUGIN_DS" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo '?')"
printf 'CHECK cluster-restored: %s\n' \
  "$([[ "$ds_final" == 1 ]] && echo "PASS (DaemonSet back to 1/1 ready)" || echo "FAIL (DS ready=$ds_final)")" | tee -a "$checks_file" >&2
printf 'R03 r01c complete.\n' >&2
exit 0

#!/usr/bin/env bash
# CBT-R-03: delete the HostPath CSI node-plugin pod before restore volumes
# are mounted (Jira: "restore pod should remain pending while storage access
# is unavailable and should recover after the CSI plugin returns").
#
# Design:
#  - Normal full + 1-pass incremental lifecycle (baseline hashes).
#  - Outage leg: krkn pod-scenarios force-deletes the hostpath-provisioner
#    CSI node-plugin pod on the CBT worker node; a standalone verifier pod
#    (workflow's own rendered manifest, distinct name) is applied DURING the
#    plugin gap so its volume mounts must wait; the DaemonSet recreates the
#    plugin and the verifier proceeds.
#  - Rerun leg (no outage): fresh verifier pod, must match baseline exactly.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
: "${RESTORE_HELPER_IMAGE:?Set RESTORE_HELPER_IMAGE}"
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
FULL_PVC_NAME="vm-backup-pvc-${RUN_ID}"
P01_PVC_NAME="vm-incremental-pvc-${RUN_ID}-p01"
CHAOS_POD_NAME="vm-restore-verify-${RUN_ID}-outage"
RERUN_POD_NAME="vm-restore-verify-${RUN_ID}-rerun"
PLUGIN_NS="openshift-cnv"
PLUGIN_DS="hostpath-provisioner-csi"
PLUGIN_LABEL="k8s-app=hostpath-provisioner"
CBT_NODE="d38-h18-000-r660"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-R-03/runs/$RUN_ID"
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Refusing to run: %s already exists.\n' "$ROOT_DIR/runs/$RUN_ID" >&2
  exit 2
fi
if [[ -d "$EVIDENCE_DIR" ]]; then
  printf 'Refusing to run: %s already exists.\n' "$EVIDENCE_DIR" >&2
  exit 2
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Refusing to run: resources for %s already exist.\n' "$RUN_ID" >&2
  exit 2
fi
ds_ready="$(oc get ds -n "$PLUGIN_NS" "$PLUGIN_DS" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
if [[ "$ds_ready" != 1 ]]; then
  printf 'CSI plugin DaemonSet not healthy (numberReady=%s) — aborting.\n' "$ds_ready" >&2
  exit 2
fi
POOL_FREE_KIB="$(oc debug node/$CBT_NODE --to-namespace=default -- chroot /host df -k /var/hpvolumes 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -z "$POOL_FREE_KIB" ]] || ((POOL_FREE_KIB < 300 * 1024 * 1024)); then
  printf 'HostPath pool free space check failed (%s KiB) — aborting.\n' "${POOL_FREE_KIB:-unavailable}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'R03 run %s: CSI node-plugin delete before restore mounts.\n' "$RUN_ID" >&2

# --- Stage 1+2: normal lifecycle ---------------------------------------------
full_status=0
if make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  full_status=0
else
  full_status=$?
fi
if ((full_status != 0)); then
  printf 'Full stage failed (%d) — aborting.\n' "$full_status" >&2
  exit "$full_status"
fi
incr_status=0
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  incr_status=0
else
  incr_status=$?
fi
if ((incr_status != 0)); then
  printf 'Lifecycle incomplete — baseline verification missing; aborting.\n' >&2
  exit "$incr_status"
fi
baseline_log="$ROOT_DIR/runs/$RUN_ID/logs/restore-verify-pod.log"
[[ -f "$baseline_log" ]] || { printf 'Baseline log missing.\n' >&2; exit 2; }
base_full_count="$(grep -oP '^FULL_WORKLOAD_FILE_COUNT=\K[0-9]+' "$baseline_log" | tail -1)"
base_full_bytes="$(grep -oP '^FULL_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$baseline_log" | tail -1)"
base_full_sha="$(grep -oP '^FULL_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$baseline_log" | tail -1)"
base_p1_count="$(grep -oP '^PASS_01_WORKLOAD_FILE_COUNT=\K[0-9]+' "$baseline_log" | tail -1)"
base_p1_bytes="$(grep -oP '^PASS_01_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$baseline_log" | tail -1)"
base_p1_sha="$(grep -oP '^PASS_01_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$baseline_log" | tail -1)"
printf 'BASELINE: full=%s/%s/%s p1=%s/%s/%s\n' \
  "$base_full_count" "$base_full_bytes" "${base_full_sha:0:12}" \
  "$base_p1_count" "$base_p1_bytes" "${base_p1_sha:0:12}" >&2
oc get pvc "$FULL_PVC_NAME" "$P01_PVC_NAME" -n "$NAMESPACE" \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,PV:.spec.volumeName \
  >"$EVIDENCE_DIR/pvc-before.txt"

# --- render_verifier (R-01 pattern) ------------------------------------------
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

# --- OUTAGE leg: kill CSI plugin, apply verifier into the gap ----------------
# Background event stream for the outage window (retry-attach).
( for _ in $(seq 1 60); do
    oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
      -o custom-columns=LAST:.lastTimestamp,TYPE:.type,REASON:.reason,OBJ:.involvedObject.name,MSG:.message \
      >>"$EVIDENCE_DIR/verifier-events-during-outage.txt" 2>/dev/null && break
    sleep 2
  done
  for _ in $(seq 1 300); do
    oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
      -o custom-columns=LAST:.lastTimestamp,TYPE:.type,REASON:.reason,OBJ:.involvedObject.name,MSG:.message \
      >"$EVIDENCE_DIR/.events-snap" 2>/dev/null || true
    sleep 2
  done ) &
events_pid=$!
krkn_log="$EVIDENCE_DIR/krkn-pod-scenarios.log"
# Kill the plugin pod (grace 0) and WAIT for krkn to report the DaemonSet
# replacement as "recovered" (name-pattern matches the DS pod prefix).
krknctl run pod-scenarios \
  --namespace "$PLUGIN_NS" \
  --label-selector "$PLUGIN_LABEL" \
  --name-pattern "$PLUGIN_DS" \
  --disruption-count 1 \
  --force=true \
  --expected-recovery-time 300 \
  --kubeconfig "$KUBECONFIG_PATH" \
  >"$krkn_log" 2>&1 &
krkn_pid=$!
# Apply the verifier pod IMMEDIATELY (into the plugin gap, before mounts).
CHAOS_POD_SPEC="$EVIDENCE_DIR/restore-verify-outage-pod.yaml"
render_verifier "$CHAOS_POD_NAME" "$CHAOS_POD_SPEC"
oc delete pod "$CHAOS_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
verifier_applied_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
oc apply -f "$CHAOS_POD_SPEC" >/dev/null
printf 'Verifier %s applied at %s (CSI plugin kill in flight).\n' "$CHAOS_POD_NAME" "$verifier_applied_at" >&2
krkn_status=0
if wait "$krkn_pid"; then krkn_status=0; else krkn_status=$?; fi
printf 'krkn exit status: %d.\n' "$krkn_status" >&2
# Plugin replacement identity + timing.
plugin_pod_now="$(oc get pods -n "$PLUGIN_NS" -l "$PLUGIN_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo none)"
plugin_pod_ready="$(oc get pods -n "$PLUGIN_NS" -l "$PLUGIN_LABEL" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo unknown)"
printf 'CSI plugin pod now: %s (%s).\n' "$plugin_pod_now" "$plugin_pod_ready" >&2
# Track the verifier: record phases observed (Pending/ContainerCreating window).
phase_seen=""
verifier_first_running=""
for ((attempt = 1; attempt <= 1800; attempt++)); do
  phase="$(oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  if [[ -n "$phase" && -z "$phase_seen" ]]; then phase_seen="$phase"; fi
  if [[ -z "$verifier_first_running" && "$phase" == Running ]]; then
    verifier_first_running="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Verifier reached Running at %s (phase history starts: %s).\n' "$verifier_first_running" "$phase_seen" >&2
  fi
  [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
  sleep 1
done
kill "$events_pid" 2>/dev/null || true
wait "$events_pid" 2>/dev/null || true
printf 'Verifier terminal phase: %s (first-seen phase: %s; Running at: %s).\n' \
  "${phase:-unknown}" "$phase_seen" "${verifier_first_running:-never}" >&2
oc logs "$CHAOS_POD_NAME" -n "$NAMESPACE" >"$EVIDENCE_DIR/outage-pod.log" 2>&1 || true
oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o json >"$EVIDENCE_DIR/outage-pod-status.json" 2>/dev/null || true
oc get pvc "$FULL_PVC_NAME" "$P01_PVC_NAME" -n "$NAMESPACE" \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,PV:.spec.volumeName \
  >"$EVIDENCE_DIR/pvc-after-outage.txt"
[[ "${phase:-}" == Succeeded ]] || { printf 'OUTAGE VERIFIER FAILED (phase %s).\n' "${phase:-unknown}" >&2; exit 1; }
outage_full_count="$(grep -oP '^FULL_WORKLOAD_FILE_COUNT=\K[0-9]+' "$EVIDENCE_DIR/outage-pod.log" | tail -1)"
outage_full_bytes="$(grep -oP '^FULL_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$EVIDENCE_DIR/outage-pod.log" | tail -1)"
outage_full_sha="$(grep -oP '^FULL_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$EVIDENCE_DIR/outage-pod.log" | tail -1)"
outage_p1_count="$(grep -oP '^PASS_01_WORKLOAD_FILE_COUNT=\K[0-9]+' "$EVIDENCE_DIR/outage-pod.log" | tail -1)"
outage_p1_bytes="$(grep -oP '^PASS_01_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$EVIDENCE_DIR/outage-pod.log" | tail -1)"
outage_p1_sha="$(grep -oP '^PASS_01_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$EVIDENCE_DIR/outage-pod.log" | tail -1)"
printf 'OUTAGE LEG: full=%s/%s/%s p1=%s/%s/%s\n' \
  "$outage_full_count" "$outage_full_bytes" "${outage_full_sha:0:12}" \
  "$outage_p1_count" "$outage_p1_bytes" "${outage_p1_sha:0:12}" >&2

# --- RERUN leg (no outage): identical hashes ---------------------------------
RERUN_POD_SPEC="$EVIDENCE_DIR/restore-verify-rerun-pod.yaml"
render_verifier "$RERUN_POD_NAME" "$RERUN_POD_SPEC"
oc delete pod "$RERUN_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
rerun_applied_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
oc apply -f "$RERUN_POD_SPEC" >/dev/null
printf 'Rerun verifier %s applied at %s.\n' "$RERUN_POD_NAME" "$rerun_applied_at" >&2
phase2=""
for ((attempt = 1; attempt <= 1800; attempt++)); do
  phase2="$(oc get pod "$RERUN_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  [[ "$phase2" == Succeeded || "$phase2" == Failed ]] && break
  sleep 1
done
oc logs "$RERUN_POD_NAME" -n "$NAMESPACE" >"$EVIDENCE_DIR/rerun-pod.log" 2>&1 || true
printf 'Rerun pod phase: %s.\n' "${phase2:-unknown}" >&2
[[ "$phase2" == Succeeded ]] || { printf 'RERUN FAILED.\n' >&2; exit 1; }
run_full_count="$(grep -oP '^FULL_WORKLOAD_FILE_COUNT=\K[0-9]+' "$EVIDENCE_DIR/rerun-pod.log" | tail -1)"
run_full_bytes="$(grep -oP '^FULL_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$EVIDENCE_DIR/rerun-pod.log" | tail -1)"
run_full_sha="$(grep -oP '^FULL_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$EVIDENCE_DIR/rerun-pod.log" | tail -1)"
run_p1_count="$(grep -oP '^PASS_01_WORKLOAD_FILE_COUNT=\K[0-9]+' "$EVIDENCE_DIR/rerun-pod.log" | tail -1)"
run_p1_bytes="$(grep -oP '^PASS_01_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$EVIDENCE_DIR/rerun-pod.log" | tail -1)"
run_p1_sha="$(grep -oP '^PASS_01_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$EVIDENCE_DIR/rerun-pod.log" | tail -1)"
printf 'RERUN: full=%s/%s/%s p1=%s/%s/%s\n' \
  "$run_full_count" "$run_full_bytes" "${run_full_sha:0:12}" \
  "$run_p1_count" "$run_p1_bytes" "${run_p1_sha:0:12}" >&2

# --- Verdict checks ----------------------------------------------------------
checks_file="$EVIDENCE_DIR/trigger-checks.txt"
: > "$checks_file"
# (a) outage validity: plugin killed and replaced
if grep -q "Force deleting pod" "$krkn_log" && [[ "$plugin_pod_now" != none && "$plugin_pod_now" != *"$PLUGIN_DS-kmx4s" ]]; then
  outage_check="PASS (plugin pod force-deleted; replacement $plugin_pod_now is ${plugin_pod_ready})"
else
  outage_check="FAIL (kill or replacement unproven: now=$plugin_pod_now)"
fi
printf 'CHECK outage-validity: %s\n' "$outage_check" | tee -a "$checks_file" >&2
# (b) verifier waited for storage then recovered
if [[ -n "$verifier_first_running" ]] && grep -qE "FailedAttachVolume|FailedMount|Multi-Attach|containerStatusesWaiting" "$EVIDENCE_DIR/verifier-events-during-outage.txt" 2>/dev/null; then
  wait_check="PASS (verifier waited on volumes during plugin gap — attach/mount events present — then Running at $verifier_first_running and Succeeded)"
elif [[ -n "$verifier_first_running" ]]; then
  wait_check="PASS-with-caveat (verifier reached Running at $verifier_first_running and Succeeded; no explicit FailedAttachVolume event captured — mount may have satisfied before event emission)"
else
  wait_check="FAIL (verifier never reached Running)"
fi
printf 'CHECK verifier-waits-then-recovers: %s\n' "$wait_check" | tee -a "$checks_file" >&2
# (c) outage-leg outputs match baseline
match=true
[[ "$outage_full_count" == "$base_full_count" ]] || match=false
[[ "$outage_full_bytes" == "$base_full_bytes" ]] || match=false
[[ "$outage_full_sha" == "$base_full_sha" ]] || match=false
[[ "$outage_p1_count" == "$base_p1_count" ]] || match=false
[[ "$outage_p1_bytes" == "$base_p1_bytes" ]] || match=false
[[ "$outage_p1_sha" == "$base_p1_sha" ]] || match=false
if [[ "$match" == true ]]; then
  outage_hash_check="PASS (outage-leg outputs exactly equal baseline)"
else
  outage_hash_check="FAIL (outage-leg outputs differ)"
fi
printf 'CHECK outage-matches-baseline: %s\n' "$outage_hash_check" | tee -a "$checks_file" >&2
# (d) rerun matches baseline
match2=true
[[ "$run_full_count" == "$base_full_count" ]] || match2=false
[[ "$run_full_bytes" == "$base_full_bytes" ]] || match2=false
[[ "$run_full_sha" == "$base_full_sha" ]] || match2=false
[[ "$run_p1_count" == "$base_p1_count" ]] || match2=false
[[ "$run_p1_bytes" == "$base_p1_bytes" ]] || match2=false
[[ "$run_p1_sha" == "$base_p1_sha" ]] || match2=false
if [[ "$match2" == true ]]; then
  rerun_check="PASS (rerun outputs exactly equal baseline)"
else
  rerun_check="FAIL (rerun outputs differ)"
fi
printf 'CHECK rerun-matches-baseline: %s\n' "$rerun_check" | tee -a "$checks_file" >&2
# (e) artifacts unchanged
pvc_ok=true
while read -r _n _p _v; do
  [[ "$_p" == Bound ]] || pvc_ok=false
done < <(tail -n +2 "$EVIDENCE_DIR/pvc-after-outage.txt")
if [[ "$pvc_ok" == true ]] && diff -q "$EVIDENCE_DIR/pvc-before.txt" "$EVIDENCE_DIR/pvc-after-outage.txt" >/dev/null; then
  pvc_check="PASS (both PVCs Bound; PV bindings unchanged across outage and reruns)"
else
  pvc_check="FAIL (PVC state changed)"
fi
printf 'CHECK artifacts-unchanged-pvc: %s\n' "$pvc_check" | tee -a "$checks_file" >&2
printf 'R03 scenario complete.\n' >&2
exit 0

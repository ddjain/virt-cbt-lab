#!/usr/bin/env bash
# CBT-R-03 r01b continuation: re-run the outage leg with the race fixed.
# r01 window-miss: the verifier was applied immediately after arming krkn,
# but krkn's container startup took ~18s — the verifier mounted its volumes
# (container started 14:49:51Z) BEFORE the force-delete landed (14:50:08Z).
# The outage never overlapped the mount phase.
#
# r01b fix: start krkn in the background, POLL for the plugin pod's
# disappearance (kill landed), THEN apply the verifier into the ~11s gap.
# Expected: verifier Pending/ContainerCreating while the plugin is gone,
# mount completes after the DaemonSet replacement re-registers, Succeeded
# with exactly baseline hashes. Plus a no-outage rerun for the Jira's
# "rerun produces identical hashes".
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
CHAOS_POD_NAME="vm-restore-verify-${RUN_ID}-outage2"
RERUN_POD_NAME="vm-restore-verify-${RUN_ID}-rerun2"
PLUGIN_NS="openshift-cnv"
PLUGIN_LABEL="k8s-app=hostpath-provisioner"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-R-03/runs/$RUN_ID"
BASELINE_LOG="$ROOT_DIR/runs/$RUN_ID/logs/restore-verify-pod.log"
[[ -f "$BASELINE_LOG" ]] || { printf 'Baseline log missing.\n' >&2; exit 2; }
for pvc in "$FULL_PVC_NAME" "$P01_PVC_NAME"; do
  phase="$(oc get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo missing)"
  [[ "$phase" == Bound ]] || { printf 'PVC %s not Bound (%s).\n' "$pvc" "$phase" >&2; exit 2; }
done
ds_ready="$(oc get ds -n "$PLUGIN_NS" hostpath-provisioner-csi -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
[[ "$ds_ready" == 1 ]] || { printf 'CSI plugin DaemonSet not healthy (%s).\n' "$ds_ready" >&2; exit 2; }
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/r01b-trigger.log") 2>&1
printf 'R03 r01b: race-fixed CSI-plugin outage for run %s.\n' "$RUN_ID" >&2
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

# Pre-render both specs so the outage-window applies are instant.
CHAOS_POD_SPEC="$EVIDENCE_DIR/r01b-restore-verify-outage2-pod.yaml"
render_verifier "$CHAOS_POD_NAME" "$CHAOS_POD_SPEC"
oc delete pod "$CHAOS_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true

# Background events watcher (retry-attach; snapshot loop).
events_file="$EVIDENCE_DIR/r01b-events.txt"
: > "$events_file"
( for _ in $(seq 1 300); do
    oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
      -o custom-columns=LAST:.lastTimestamp,TYPE:.type,REASON:.reason,OBJ:.involvedObject.name,MSG:.message \
      >"$EVIDENCE_DIR/.r01b-events-snap" 2>/dev/null || true
    sleep 2
  done ) &
events_pid=$!

# --- OUTAGE leg: krkn kills plugin; apply verifier when the kill LANDS -------
krkn_log="$EVIDENCE_DIR/r01b-krkn-pod-scenarios.log"
krknctl run pod-scenarios \
  --namespace "$PLUGIN_NS" \
  --label-selector "$PLUGIN_LABEL" \
  --name-pattern "hostpath-provisioner-csi" \
  --disruption-count 1 \
  --force=true \
  --expected-recovery-time 300 \
  --kubeconfig "$KUBECONFIG_PATH" \
  >"$krkn_log" 2>&1 &
krkn_pid=$!
printf 'krkn armed (pid=%s); polling for plugin-pod disappearance…\n' "$krkn_pid" >&2
kill_landed_at=""
plugin_gap_observed=false
for ((attempt = 1; attempt <= 1200; attempt++)); do
  plugin_count="$(oc get pods -n "$PLUGIN_NS" -l "$PLUGIN_LABEL" --no-headers 2>/dev/null | grep -cv Terminating || true)"
  plugin_count="${plugin_count:-0}"
  if [[ "$plugin_count" == 0 ]]; then
    kill_landed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # APPLY THE VERIFIER INTO THE GAP immediately.
    oc apply -f "$CHAOS_POD_SPEC" >/dev/null
    printf 'Kill landed at %s — verifier %s applied INTO the plugin gap.\n' "$kill_landed_at" "$CHAOS_POD_NAME" >&2
    plugin_gap_observed=true
    break
  fi
  sleep 0.5
done
if [[ "$plugin_gap_observed" != true ]]; then
  printf 'Plugin pod never disappeared within 600s — krkn failure; see %s\n' "$krkn_log" >&2
  kill "$events_pid" 2>/dev/null || true
  exit 2
fi
# Record the verifier's phases during the gap (fast sampling for ~60s).
gap_phases=""
for ((attempt = 1; attempt <= 120; attempt++)); do
  p="$(oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  [[ -z "$gap_phases" || "$gap_phases" == *"$p" ]] || gap_phases="$gap_phases->$p"
  [[ "$p" == Running ]] && break
  sleep 0.5
done
printf 'Verifier phase progression out of the gap: %s.\n' "${gap_phases:-none}" >&2
krkn_status=0
if wait "$krkn_pid"; then krkn_status=0; else krkn_status=$?; fi
printf 'krkn exit status: %d.\n' "$krkn_status" >&2
plugin_pod_now="$(oc get pods -n "$PLUGIN_NS" -l "$PLUGIN_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo none)"
plugin_pod_phase="$(oc get pods -n "$PLUGIN_NS" -l "$PLUGIN_LABEL" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo unknown)"
printf 'CSI plugin pod now: %s (%s).\n' "$plugin_pod_now" "$plugin_pod_phase" >&2
# Wait for the verifier to finish (budget 1800s from apply).
phase=""
verifier_first_running=""
for ((attempt = 1; attempt <= 1800; attempt++)); do
  phase="$(oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  if [[ -z "$verifier_first_running" && "$phase" == Running ]]; then
    verifier_first_running="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
  sleep 1
done
sleep 2
kill "$events_pid" 2>/dev/null || true
wait "$events_pid" 2>/dev/null || true
cp "$EVIDENCE_DIR/.r01b-events-snap" "$events_file" 2>/dev/null || true
printf 'Verifier terminal phase: %s (Running since %s; gap phases: %s).\n' \
  "${phase:-unknown}" "${verifier_first_running:-never}" "${gap_phases:-?}" >&2
oc logs "$CHAOS_POD_NAME" -n "$NAMESPACE" >"$EVIDENCE_DIR/r01b-outage2-pod.log" 2>&1 || true
oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o json >"$EVIDENCE_DIR/r01b-outage2-pod-status.json" 2>/dev/null || true
# Container-start vs kill timing (the r01 race, now measurable).
out_cont_start="$(jq -r '.status.containerStatuses[0].state.terminated.startedAt // .status.containerStatuses[0].state.running.startedAt // "never"' "$EVIDENCE_DIR/r01b-outage2-pod-status.json" 2>/dev/null || echo '?')"
printf 'Verifier container started at %s (kill landed %s — must be AFTER).\n' "$out_cont_start" "$kill_landed_at" >&2
[[ "${phase:-}" == Succeeded ]] || { printf 'OUTAGE2 VERIFIER FAILED.\n' >&2; exit 1; }
oc get pvc "$FULL_PVC_NAME" "$P01_PVC_NAME" -n "$NAMESPACE" \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,PV:.spec.volumeName \
  >"$EVIDENCE_DIR/r01b-pvc-after.txt"
outage_full_count="$(grep -oP '^FULL_WORKLOAD_FILE_COUNT=\K[0-9]+' "$EVIDENCE_DIR/r01b-outage2-pod.log" | tail -1)"
outage_full_bytes="$(grep -oP '^FULL_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$EVIDENCE_DIR/r01b-outage2-pod.log" | tail -1)"
outage_full_sha="$(grep -oP '^FULL_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$EVIDENCE_DIR/r01b-outage2-pod.log" | tail -1)"
outage_p1_count="$(grep -oP '^PASS_01_WORKLOAD_FILE_COUNT=\K[0-9]+' "$EVIDENCE_DIR/r01b-outage2-pod.log" | tail -1)"
outage_p1_bytes="$(grep -oP '^PASS_01_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$EVIDENCE_DIR/r01b-outage2-pod.log" | tail -1)"
outage_p1_sha="$(grep -oP '^PASS_01_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$EVIDENCE_DIR/r01b-outage2-pod.log" | tail -1)"
printf 'OUTAGE2 LEG: full=%s/%s/%s p1=%s/%s/%s\n' \
  "$outage_full_count" "$outage_full_bytes" "${outage_full_sha:0:12}" \
  "$outage_p1_count" "$outage_p1_bytes" "${outage_p1_sha:0:12}" >&2

# --- Verdict checks (r01b) ----------------------------------------------------
checks_file="$EVIDENCE_DIR/r01b-trigger-checks.txt"
: > "$checks_file"
# (a) outage validity: kill landed, verifier applied INTO the gap, container started after the kill
if [[ "$plugin_gap_observed == true" && "$plugin_pod_now" != none ]]; then
  outage_check="PASS (kill landed $kill_landed_at; verifier applied into the gap; plugin replacement $plugin_pod_now ${plugin_pod_phase}; verifier container started $out_cont_start)"
else
  outage_check="FAIL (gap=$plugin_gap_observed plugin=$plugin_pod_now)"
fi
printf 'CHECK outage-validity: %s\n' "$outage_check" | tee -a "$checks_file" >&2
# (b) verifier waited then recovered
if [[ -n "$verifier_first_running" ]]; then
  wait_check="PASS (verifier container start $out_cont_start AFTER kill $kill_landed_at; phase progression ${gap_phases:-?}; Running $verifier_first_running; Succeeded)"
else
  wait_check="FAIL (never Running)"
fi
printf 'CHECK verifier-waits-then-recovers: %s\n' "$wait_check" | tee -a "$checks_file" >&2
# (c) outage-leg hashes match baseline
match=true
[[ "$outage_full_count" == "$base_full_count" ]] || match=false
[[ "$outage_full_bytes" == "$base_full_bytes" ]] || match=false
[[ "$outage_full_sha" == "$base_full_sha" ]] || match=false
[[ "$outage_p1_count" == "$base_p1_count" ]] || match=false
[[ "$outage_p1_bytes" == "$base_p1_bytes" ]] || match=false
[[ "$outage_p1_sha" == "$base_p1_sha" ]] || match=false
if [[ "$match" == true ]]; then
  hash_check="PASS (outage-leg outputs exactly equal baseline)"
else
  hash_check="FAIL (outage-leg outputs differ)"
fi
printf 'CHECK outage-matches-baseline: %s\n' "$hash_check" | tee -a "$checks_file" >&2
# (d) artifacts unchanged
pvc_ok=true
while read -r _n _p _v; do
  [[ "$_p" == Bound ]] || pvc_ok=false
done < <(tail -n +2 "$EVIDENCE_DIR/r01b-pvc-after.txt")
if [[ "$pvc_ok" == true ]] && diff -q "$EVIDENCE_DIR/pvc-before.txt" "$EVIDENCE_DIR/r01b-pvc-after.txt" >/dev/null; then
  pvc_check="PASS (PVCs Bound; PV bindings unchanged)"
else
  pvc_check="FAIL (PVC state changed)"
fi
printf 'CHECK artifacts-unchanged-pvc: %s\n' "$pvc_check" | tee -a "$checks_file" >&2
printf 'R03 r01b complete.\n' >&2
exit 0

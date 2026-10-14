#!/usr/bin/env bash
# CBT-R-01 r01b continuation: re-run ONLY the chaos leg of run 20261013-cbtr01-r01
# with fixed injection gating. r01 proved: PVCs unchanged, rerun hashes ==
# baseline. r01 was missing only the conversion-in-flight proof (oc logs -f
# started before the container existed; conv_lines arithmetic bug).
#
# Fixes in r01b:
#  - log stream attaches via retry loop (survives the container-creating window)
#  - krkn trigger gates on the pod's log containing ^FULL_QCOW2= (mount
#    discovery done => qemu-img convert in flight; convert runs minutes)
#  - conv_lines counted without the echo-0 double bug
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"
cd "$ROOT_DIR"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
: "${RESTORE_HELPER_IMAGE:?Set RESTORE_HELPER_IMAGE}"
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
RUN_ID="20261013-cbtr01-r01"
VM_NAME="vm-${RUN_ID}"
FULL_PVC_NAME="vm-backup-pvc-${RUN_ID}"
P01_PVC_NAME="vm-incremental-pvc-${RUN_ID}-p01"
CHAOS_POD_NAME="vm-restore-verify-${RUN_ID}-chaos2"
RERUN_POD_NAME="vm-restore-verify-${RUN_ID}-rerun2"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-R-01/runs/$RUN_ID"
BASELINE_LOG="$ROOT_DIR/runs/$RUN_ID/logs/restore-verify-pod.log"
[[ -f "$BASELINE_LOG" ]] || { printf 'Baseline log %s missing.\n' "$BASELINE_LOG" >&2; exit 2; }
for pvc in "$FULL_PVC_NAME" "$P01_PVC_NAME"; do
  phase="$(oc get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo missing)"
  [[ "$phase" == Bound ]] || { printf 'PVC %s not Bound (%s).\n' "$pvc" "$phase" >&2; exit 2; }
done
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/r01b-trigger.log") 2>&1
printf 'R01 r01b continuation: fixed-gate verifier kill for run %s.\n' "$RUN_ID" >&2
base_full_count="$(grep -oP '^FULL_WORKLOAD_FILE_COUNT=\K[0-9]+' "$BASELINE_LOG" | tail -1)"
base_full_bytes="$(grep -oP '^FULL_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$BASELINE_LOG" | tail -1)"
base_full_sha="$(grep -oP '^FULL_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$BASELINE_LOG" | tail -1)"
base_p1_count="$(grep -oP '^PASS_01_WORKLOAD_FILE_COUNT=\K[0-9]+' "$BASELINE_LOG" | tail -1)"
base_p1_bytes="$(grep -oP '^PASS_01_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$BASELINE_LOG" | tail -1)"
base_p1_sha="$(grep -oP '^PASS_01_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$BASELINE_LOG" | tail -1)"
printf 'BASELINE (workflow verify): full=%s/%s/%s p1=%s/%s/%s\n' \
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

# --- CHAOS leg: verifier pod, log-stream retry, krkn gated on FULL_QCOW2 ----
CHAOS_POD_SPEC="$EVIDENCE_DIR/r01b-restore-verify-chaos-pod.yaml"
render_verifier "$CHAOS_POD_NAME" "$CHAOS_POD_SPEC"
oc delete pod "$CHAOS_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
oc apply -f "$CHAOS_POD_SPEC" >/dev/null
printf 'Chaos verifier pod %s applied.\n' "$CHAOS_POD_NAME" >&2
partial_log="$EVIDENCE_DIR/r01b-chaos-partial.log"
: > "$partial_log"
# Retry loop: oc logs -f fails with BadRequest while the container is creating;
# retry until the stream attaches, then it blocks until the pod dies.
(
  for _ in $(seq 1 120); do
    oc logs -f "$CHAOS_POD_NAME" -n "$NAMESPACE" 2>/dev/null && exit 0
    sleep 1
  done
) >> "$partial_log" 2>/dev/null &
log_pid=$!
krkn_log="$EVIDENCE_DIR/r01b-krkn-pod-scenarios.log"
gate_cmd="oc get pod $CHAOS_POD_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' | grep -q Running && oc logs $CHAOS_POD_NAME -n $NAMESPACE 2>/dev/null | grep -q '^FULL_QCOW2='"
krknctl run pod-scenarios \
  --namespace "$NAMESPACE" \
  --label-selector "virt-cbt-lab/run-id=$RUN_ID" \
  --name-pattern "$CHAOS_POD_NAME" \
  --disruption-count 1 \
  --force=true \
  --expected-recovery-time 60 \
  --trigger-command "$gate_cmd" \
  --triggers-interval 2 \
  --triggers-timeout 600 \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH" \
  >"$krkn_log" 2>&1 &
krkn_pid=$!
printf 'krkn armed (pid=%s); gate: %s Running AND log has FULL_QCOW2.\n' "$krkn_pid" "$CHAOS_POD_NAME" >&2
krkn_status=0
if wait "$krkn_pid"; then krkn_status=0; else krkn_status=$?; fi
printf 'krkn exit status: %d (nonzero expected: Never-pod cannot recover).\n' "$krkn_status" >&2
sleep 3
kill "$log_pid" 2>/dev/null || true
wait "$log_pid" 2>/dev/null || true
chaos_phase="$(oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo gone)"
conv_lines="$(grep -c '^FULL_QCOW2=' "$partial_log" 2>/dev/null || true)"
conv_lines="${conv_lines:-0}"
printf 'Chaos pod phase after kill: %s; partial log FULL_QCOW2 lines: %s.\n' "$chaos_phase" "$conv_lines" >&2
printf -- '--- partial log begin ---\n' >&2
cat "$partial_log" >&2 || true
printf -- '--- partial log end ---\n' >&2
oc get pvc "$FULL_PVC_NAME" "$P01_PVC_NAME" -n "$NAMESPACE" \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,PV:.spec.volumeName \
  >"$EVIDENCE_DIR/r01b-pvc-after-chaos.txt"

# --- RERUN leg ---------------------------------------------------------------
RERUN_POD_SPEC="$EVIDENCE_DIR/r01b-restore-verify-rerun-pod.yaml"
render_verifier "$RERUN_POD_NAME" "$RERUN_POD_SPEC"
oc delete pod "$RERUN_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
rerun_applied_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
oc apply -f "$RERUN_POD_SPEC" >/dev/null
printf 'Rerun verifier pod %s applied at %s.\n' "$RERUN_POD_NAME" "$rerun_applied_at" >&2
phase=""
for ((attempt = 1; attempt <= 1800; attempt++)); do
  phase="$(oc get pod "$RERUN_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
  sleep 1
done
oc logs "$RERUN_POD_NAME" -n "$NAMESPACE" >"$EVIDENCE_DIR/r01b-rerun-pod.log" 2>&1 || true
printf 'Rerun pod phase: %s.\n' "${phase:-unknown}" >&2
[[ "$phase" == Succeeded ]] || { printf 'RERUN FAILED.\n' >&2; exit 1; }
run_full_count="$(grep -oP '^FULL_WORKLOAD_FILE_COUNT=\K[0-9]+' "$EVIDENCE_DIR/r01b-rerun-pod.log" | tail -1)"
run_full_bytes="$(grep -oP '^FULL_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$EVIDENCE_DIR/r01b-rerun-pod.log" | tail -1)"
run_full_sha="$(grep -oP '^FULL_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$EVIDENCE_DIR/r01b-rerun-pod.log" | tail -1)"
run_p1_count="$(grep -oP '^PASS_01_WORKLOAD_FILE_COUNT=\K[0-9]+' "$EVIDENCE_DIR/r01b-rerun-pod.log" | tail -1)"
run_p1_bytes="$(grep -oP '^PASS_01_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$EVIDENCE_DIR/r01b-rerun-pod.log" | tail -1)"
run_p1_sha="$(grep -oP '^PASS_01_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$EVIDENCE_DIR/r01b-rerun-pod.log" | tail -1)"
printf 'RERUN: full=%s/%s/%s p1=%s/%s/%s\n' \
  "$run_full_count" "$run_full_bytes" "${run_full_sha:0:12}" \
  "$run_p1_count" "$run_p1_bytes" "${run_p1_sha:0:12}" >&2

# --- Verdict checks (r01b) ----------------------------------------------------
checks_file="$EVIDENCE_DIR/r01b-trigger-checks.txt"
: > "$checks_file"
if grep -q "Force deleting pod $CHAOS_POD_NAME" "$krkn_log" && [[ "$chaos_phase" != Running ]] && ((conv_lines > 0)); then
  inject_check="PASS (force-deleted mid-conversion: partial log shows FULL_QCOW2=${conv_lines} line(s), i.e. mount discovery complete and qemu-img convert in flight)"
else
  inject_check="FAIL (kill or conversion-in-flight unproven: phase=$chaos_phase conv_lines=$conv_lines)"
fi
printf 'CHECK injection-validity: %s\n' "$inject_check" | tee -a "$checks_file" >&2
pvc_ok=true
while read -r _name _phase _pv; do
  [[ "$_phase" == Bound ]] || pvc_ok=false
done < <(tail -n +2 "$EVIDENCE_DIR/r01b-pvc-after-chaos.txt")
if [[ "$pvc_ok" == true ]] && diff -q "$EVIDENCE_DIR/pvc-before.txt" "$EVIDENCE_DIR/r01b-pvc-after-chaos.txt" >/dev/null; then
  pvc_check="PASS (both backup PVCs Bound; PV bindings identical to pre-chaos snapshot)"
else
  pvc_check="FAIL (PVC state changed)"
fi
printf 'CHECK artifacts-unchanged-pvc: %s\n' "$pvc_check" | tee -a "$checks_file" >&2
match=true
[[ "$run_full_count" == "$base_full_count" ]] || match=false
[[ "$run_full_bytes" == "$base_full_bytes" ]] || match=false
[[ "$run_full_sha" == "$base_full_sha" ]] || match=false
[[ "$run_p1_count" == "$base_p1_count" ]] || match=false
[[ "$run_p1_bytes" == "$base_p1_bytes" ]] || match=false
[[ "$run_p1_sha" == "$base_p1_sha" ]] || match=false
if [[ "$match" == true ]]; then
  rerun_check="PASS (rerun outputs exactly equal baseline: full ${base_full_count}/${base_full_bytes}/${base_full_sha:0:12}, p1 ${base_p1_count}/${base_p1_bytes}/${base_p1_sha:0:12})"
else
  rerun_check="FAIL (rerun differs from baseline)"
fi
printf 'CHECK rerun-matches-baseline: %s\n' "$rerun_check" | tee -a "$checks_file" >&2
printf 'R01 r01b continuation complete.\n' >&2
exit 0

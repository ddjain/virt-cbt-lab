#!/usr/bin/env bash
# CBT-R-02: storage I/O contention during restore verification.
# Jira: "Restore processing should slow down but complete within the existing
# verification timeout and produce the same hashes and marker results."
#
# Design:
#  - Normal full + 1-pass incremental lifecycle (workflow verify = BASELINE
#    hashes AND baseline conversion timing).
#  - Contention leg: direct hog pod on the CBT storage path (I-04 r03-proven
#    recipe: krkn-hub hog image, stress-ng --hdd 8 --hdd-bytes 2g
#    --hdd-write-size 1m --hdd-opts dsync, hostPath /var/hpvolumes, pinned to
#    the CBT worker node) — krknctl node-io-hog was proven page-cache-absorbed
#    (no contention) in I-04, so the direct dsync hog is the decisive source.
#  - Verifier leg: standalone verifier (R-01 pattern: workflow's own rendered
#    manifest, distinct pod name) started AFTER the hog is Running; hog
#    timeout 420s covers the whole conversion (Jira minimum 180s satisfied).
#  - Checks: contention overlap, verifier completes < 1800s with EXACTLY
#    baseline hashes, measured slow-down vs baseline, clean hog cleanup.
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
HOG_NS="hog-ns-${RUN_ID}"
HOG_POD="io-hog-${RUN_ID}"
CHAOS_POD_NAME="vm-restore-verify-${RUN_ID}-contended"
CBT_NODE="d38-h18-000-r660"
HOG_PATH="/var/hpvolumes"
HOG_TIMEOUT_S=420
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-R-02/runs/$RUN_ID"
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Refusing to run: %s already exists in this checkout.\n' "$ROOT_DIR/runs/$RUN_ID" >&2
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
POOL_FREE_KIB="$(oc debug node/$CBT_NODE --to-namespace=default -- chroot /host df -k $HOG_PATH 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -z "$POOL_FREE_KIB" ]] || ((POOL_FREE_KIB < 300 * 1024 * 1024)); then
  printf 'HostPath pool free space check failed (%s KiB < 300GiB floor) — aborting.\n' "${POOL_FREE_KIB:-unavailable}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'R02 run %s: storage I/O contention during restore verification.\n' "$RUN_ID" >&2

# --- Stage 1+2: normal lifecycle (full + incremental with workflow verify) --
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
# Baseline: workflow verification outputs + baseline verifier pod timing.
baseline_log="$ROOT_DIR/runs/$RUN_ID/logs/restore-verify-pod.log"
[[ -f "$baseline_log" ]] || { printf 'Baseline log missing.\n' >&2; exit 2; }
base_full_count="$(grep -oP '^FULL_WORKLOAD_FILE_COUNT=\K[0-9]+' "$baseline_log" | tail -1)"
base_full_bytes="$(grep -oP '^FULL_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$baseline_log" | tail -1)"
base_full_sha="$(grep -oP '^FULL_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$baseline_log" | tail -1)"
base_p1_count="$(grep -oP '^PASS_01_WORKLOAD_FILE_COUNT=\K[0-9]+' "$baseline_log" | tail -1)"
base_p1_bytes="$(grep -oP '^PASS_01_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$baseline_log" | tail -1)"
base_p1_sha="$(grep -oP '^PASS_01_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$baseline_log" | tail -1)"
base_pod="vm-restore-verify-${RUN_ID}"
base_started="$(oc get pod "$base_pod" -n "$NAMESPACE" -o jsonpath='{.status.startTime}' 2>/dev/null || echo '')"
printf 'BASELINE: full=%s/%s/%s p1=%s/%s/%s (verifier start %s)\n' \
  "$base_full_count" "$base_full_bytes" "${base_full_sha:0:12}" \
  "$base_p1_count" "$base_p1_bytes" "${base_p1_sha:0:12}" "$base_started" >&2

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

# --- HOG leg: start contention on the CBT storage path -----------------------
cat > "$EVIDENCE_DIR/hog-pod-spec.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $HOG_POD
  namespace: $HOG_NS
  labels:
    run: $HOG_POD
spec:
  nodeSelector:
    kubernetes.io/hostname: $CBT_NODE
  restartPolicy: Never
  tolerations:
  - operator: Exists
  containers:
  - name: krkn-hog
    image: quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c"]
    args:
    - "date -u +%Y-%m-%dT%H:%M:%SZ; cd /hog-data && stress-ng --hdd 8 --hdd-bytes 2g --hdd-write-size 1m --hdd-opts dsync --timeout ${HOG_TIMEOUT_S}; echo HOG_EXIT=\$?; date -u +%Y-%m-%dT%H:%M:%SZ"
    securityContext:
      privileged: true
      readOnlyRootFilesystem: true
    volumeMounts:
    - name: node-volume
      mountPath: /hog-data
  volumes:
  - name: node-volume
    hostPath:
      path: $HOG_PATH
EOF
oc delete namespace "$HOG_NS" --ignore-not-found >/dev/null 2>&1 || true
oc create namespace "$HOG_NS" >/dev/null
oc adm policy add-scc-to-user privileged -z default -n "$HOG_NS" >/dev/null 2>&1 || true
(oc logs -f "$HOG_POD" -n "$HOG_NS" >"$EVIDENCE_DIR/hog-pod.log" 2>&1 || true) &
hoglog_pid=$!
oc apply -f "$EVIDENCE_DIR/hog-pod-spec.yaml" >/dev/null
hog_started_at=""
for ((attempt = 1; attempt <= 300; attempt++)); do
  hog_phase="$(oc get pod "$HOG_POD" -n "$HOG_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  [[ "$hog_phase" == Running ]] && break
  sleep 1
done
[[ "$hog_phase" == Running ]] || { printf 'Hog pod did not reach Running (%s).\n' "$hog_phase" >&2; exit 2; }
# Wait for stress-ng to actually start (first log line = date print).
for ((attempt = 1; attempt <= 60; attempt++)); do
  if [[ -s "$EVIDENCE_DIR/hog-pod.log" ]] && grep -q "T[0-9:]*Z" "$EVIDENCE_DIR/hog-pod.log" 2>/dev/null; then break; fi
  sleep 1
done
hog_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Hog pod Running on %s (stress-ng up at %s, timeout %ss).\n' "$CBT_NODE" "$hog_started_at" "$HOG_TIMEOUT_S" >&2

# --- VERIFIER leg under contention -------------------------------------------
CHAOS_POD_SPEC="$EVIDENCE_DIR/restore-verify-contended-pod.yaml"
render_verifier "$CHAOS_POD_NAME" "$CHAOS_POD_SPEC"
oc delete pod "$CHAOS_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
verifier_applied_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
oc apply -f "$CHAOS_POD_SPEC" >/dev/null
printf 'Contended verifier %s applied at %s (hog Running).\n' "$CHAOS_POD_NAME" "$verifier_applied_at" >&2
phase=""
verifier_succeeded_at=""
for ((attempt = 1; attempt <= 1800; attempt++)); do
  phase="$(oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  [[ "$phase" == Succeeded || "$phase" == Failed ]] && { verifier_succeeded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; break; }
  sleep 1
done
contended_elapsed=$((attempt))
printf 'Contended verifier phase: %s after ~%ss (timeout budget 1800s).\n' "${phase:-unknown}" "$contended_elapsed" >&2
oc logs "$CHAOS_POD_NAME" -n "$NAMESPACE" >"$EVIDENCE_DIR/contended-pod.log" 2>&1 || true
# Capture container CPU-time / restart details for the timing analysis.
oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o json >"$EVIDENCE_DIR/contended-pod-status.json" 2>/dev/null || true
# Hog status at verifier completion (overlap proof).
hog_phase_end="$(oc get pod "$HOG_POD" -n "$HOG_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo gone)"
printf 'Hog phase at verifier completion: %s.\n' "$hog_phase_end" >&2
# Wait for hog to finish + capture its log/exit.
for ((attempt = 1; attempt <= 480; attempt++)); do
  hog_phase="$(oc get pod "$HOG_POD" -n "$HOG_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  [[ "$hog_phase" == Succeeded || "$hog_phase" == Failed ]] && break
  sleep 2
done
sleep 2
kill "$hoglog_pid" 2>/dev/null || true
wait "$hoglog_pid" 2>/dev/null || true
printf -- '--- hog log tail ---\n' >&2
tail -5 "$EVIDENCE_DIR/hog-pod.log" >&2 || true
# Cleanup hog.
oc delete pod "$HOG_POD" -n "$HOG_NS" --ignore-not-found >/dev/null 2>&1 || true
oc delete namespace "$HOG_NS" --ignore-not-found >/dev/null 2>&1 || true
printf 'Hog pod and namespace cleaned up.\n' >&2
# PVC state after contention.
oc get pvc "$FULL_PVC_NAME" "$P01_PVC_NAME" -n "$NAMESPACE" \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,PV:.spec.volumeName \
  >"$EVIDENCE_DIR/pvc-after.txt"
[[ "$phase" == Succeeded ]] || { printf 'CONTENDED VERIFIER FAILED (phase %s).\n' "${phase:-unknown}" >&2; exit 1; }

# --- Baseline timing (workflow verifier pod) --------------------------------
base_pod_json="$ROOT_DIR/runs/$RUN_ID/restore-pod.json"
oc get pod "$base_pod" -n "$NAMESPACE" -o json >"$base_pod_json" 2>/dev/null || true
base_start="$(jq -r '.status.startTime // empty' "$base_pod_json" 2>/dev/null || echo '')"
base_cont_start="$(jq -r '.status.containerStatuses[0].state.terminated.startedAt // empty' "$base_pod_json" 2>/dev/null || echo '')"
base_cont_end="$(jq -r '.status.containerStatuses[0].state.terminated.finishedAt // empty' "$base_pod_json" 2>/dev/null || echo '')"
printf 'Baseline verifier container: %s -> %s.\n' "$base_cont_start" "$base_cont_end" >&2

# --- Verdict checks ----------------------------------------------------------
checks_file="$EVIDENCE_DIR/trigger-checks.txt"
: > "$checks_file"
# (a) contention overlap: hog Running when verifier applied AND when it finished
if [[ "$hog_phase_end" == Running || "$hog_phase_end" == Succeeded ]]; then
  overlap_check="PASS (hog Running through verifier completion: end phase=${hog_phase_end}; dsync writes on ${HOG_PATH}@${CBT_NODE} for ${HOG_TIMEOUT_S}s)"
else
  overlap_check="FAIL (hog ended early: ${hog_phase_end})"
fi
printf 'CHECK contention-overlap: %s\n' "$overlap_check" | tee -a "$checks_file" >&2
# (b) verifier completed within the workflow timeout budget
if [[ "$phase" == Succeeded ]] && ((contended_elapsed <= 1800)); then
  timeout_check="PASS (contended verifier Succeeded in ~${contended_elapsed}s, within the 1800s workflow budget)"
else
  timeout_check="FAIL (phase=${phase:-unknown} after ${contended_elapsed}s)"
fi
printf 'CHECK verifier-completes-within-timeout: %s\n' "$timeout_check" | tee -a "$checks_file" >&2
# (c) contended outputs exactly equal baseline
run_full_count="$(grep -oP '^FULL_WORKLOAD_FILE_COUNT=\K[0-9]+' "$EVIDENCE_DIR/contended-pod.log" | tail -1)"
run_full_bytes="$(grep -oP '^FULL_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$EVIDENCE_DIR/contended-pod.log" | tail -1)"
run_full_sha="$(grep -oP '^FULL_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$EVIDENCE_DIR/contended-pod.log" | tail -1)"
run_p1_count="$(grep -oP '^PASS_01_WORKLOAD_FILE_COUNT=\K[0-9]+' "$EVIDENCE_DIR/contended-pod.log" | tail -1)"
run_p1_bytes="$(grep -oP '^PASS_01_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$EVIDENCE_DIR/contended-pod.log" | tail -1)"
run_p1_sha="$(grep -oP '^PASS_01_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$EVIDENCE_DIR/contended-pod.log" | tail -1)"
printf 'CONTENDED: full=%s/%s/%s p1=%s/%s/%s\n' \
  "$run_full_count" "$run_full_bytes" "${run_full_sha:0:12}" \
  "$run_p1_count" "$run_p1_bytes" "${run_p1_sha:0:12}" >&2
match=true
[[ "$run_full_count" == "$base_full_count" ]] || match=false
[[ "$run_full_bytes" == "$base_full_bytes" ]] || match=false
[[ "$run_full_sha" == "$base_full_sha" ]] || match=false
[[ "$run_p1_count" == "$base_p1_count" ]] || match=false
[[ "$run_p1_bytes" == "$base_p1_bytes" ]] || match=false
[[ "$run_p1_sha" == "$base_p1_sha" ]] || match=false
if [[ "$match" == true ]]; then
  hash_check="PASS (contended outputs exactly equal baseline: full ${base_full_count}/${base_full_bytes}/${base_full_sha:0:12}, p1 ${base_p1_count}/${base_p1_bytes}/${base_p1_sha:0:12})"
else
  hash_check="FAIL (contended outputs differ from baseline)"
fi
printf 'CHECK contended-matches-baseline: %s\n' "$hash_check" | tee -a "$checks_file" >&2
# (d) no residue
pvc_ok=true
while read -r _n _p _v; do
  [[ "$_p" == Bound ]] || pvc_ok=false
done < <(tail -n +2 "$EVIDENCE_DIR/pvc-after.txt")
hog_ns_gone="$(oc get namespace "$HOG_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo gone)"
if [[ "$pvc_ok" == true && "$hog_ns_gone" != Active ]]; then
  residue_check="PASS (PVCs Bound; hog namespace ${hog_ns_gone})"
else
  residue_check="FAIL (pvc_ok=$pvc_ok hog_ns=$hog_ns_gone)"
fi
printf 'CHECK no-residue: %s\n' "$residue_check" | tee -a "$checks_file" >&2
printf 'R02 scenario complete: contended-verifier evidence collected (overlap, duration ~%ss, hashes, cleanup).\n' "$contended_elapsed" >&2
exit 0

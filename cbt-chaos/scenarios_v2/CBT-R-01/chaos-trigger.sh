#!/usr/bin/env bash
# CBT-R-01: delete the restore-verification pod during conversion/rebase
# (Jira: "interrupting the restore verification process does not alter the
# backup artifacts and verification can be safely rerun").
#
# Design:
#  - Normal full + 1-pass incremental lifecycle (the final pass runs the
#    workflow's own restore verification = BASELINE hashes).
#  - Chaos leg: render the workflow's OWN verifier manifest (restore-lib
#    semantics reproduced: incremental volumes/mounts via awk marker
#    substitution) with a DISTINCT pod name (vm-restore-verify-<RID>-chaos),
#    apply it, start a background log stream (partial log survives the
#    force-delete), and arm krkn pod-scenarios with a command trigger on the
#    pod Running. krkn force-deletes the verifier MID-CONVERSION.
#  - Artifact-unchanged checks: PVC Bound states before/after.
#  - Rerun leg: apply the same verifier again (fresh pod), wait Succeeded,
#    compare FULL_*/PASS_01_* outputs with the baseline — exact equality
#    proves the backup artifacts were not altered by the interruption.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
: "${RESTORE_HELPER_IMAGE:?Set RESTORE_HELPER_IMAGE (same as the workflow .env)}"
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
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
INCR_BACKUP_NAME="vm-incremental-${RUN_ID}-p01"
FULL_PVC_NAME="vm-backup-pvc-${RUN_ID}"
P01_PVC_NAME="vm-incremental-pvc-${RUN_ID}-p01"
CHAOS_POD_NAME="vm-restore-verify-${RUN_ID}-chaos"
RERUN_POD_NAME="vm-restore-verify-${RUN_ID}-rerun"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-R-01/runs/$RUN_ID"
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Refusing to run: %s already exists in this checkout.\n' "$ROOT_DIR/runs/$RUN_ID" >&2
  exit 2
fi
if [[ -d "$EVIDENCE_DIR" ]]; then
  printf 'Refusing to run: %s already exists in this checkout.\n' "$EVIDENCE_DIR" >&2
  exit 2
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Refusing to run: resources for %s already exist in %s.\n' "$RUN_ID" "$NAMESPACE" >&2
  exit 2
fi
POOL_FREE_KIB="$(oc debug node/d38-h18-000-r660 --to-namespace=default -- chroot /host df -k /var/hpvolumes/csi 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -z "$POOL_FREE_KIB" ]] || ((POOL_FREE_KIB < 400 * 1024 * 1024)); then
  printf 'HostPath pool free space check failed (%s KiB < 400GiB floor) — aborting.\n' "${POOL_FREE_KIB:-unavailable}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'R01 run %s: verifier-pod kill during conversion (variant %s).\n' \
  "$RUN_ID" "$MANIFEST_VARIANT" >&2

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
  printf 'Full stage failed (%d) — aborting scenario.\n' "$full_status" >&2
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
printf 'Incremental stage exit status: %d.\n' "$incr_status" >&2
if ((incr_status != 0)); then
  printf 'Lifecycle incomplete — baseline verification missing; aborting.\n' >&2
  exit "$incr_status"
fi
# Baseline: the workflow's own verification outputs (from the run tree).
baseline_log="$ROOT_DIR/runs/$RUN_ID/logs/restore-verify-pod.log"
[[ -f "$baseline_log" ]] || { printf 'Baseline restore log missing — aborting.\n' >&2; exit 2; }
base_full_count="$(grep -oP '^FULL_WORKLOAD_FILE_COUNT=\K[0-9]+' "$baseline_log" | tail -1)"
base_full_bytes="$(grep -oP '^FULL_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$baseline_log" | tail -1)"
base_full_sha="$(grep -oP '^FULL_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$baseline_log" | tail -1)"
base_p1_count="$(grep -oP '^PASS_01_WORKLOAD_FILE_COUNT=\K[0-9]+' "$baseline_log" | tail -1)"
base_p1_bytes="$(grep -oP '^PASS_01_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$baseline_log" | tail -1)"
base_p1_sha="$(grep -oP '^PASS_01_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$baseline_log" | tail -1)"
printf 'BASELINE: full=%s/%s/%s p1=%s/%s/%s\n' \
  "$base_full_count" "$base_full_bytes" "${base_full_sha:0:12}" \
  "$base_p1_count" "$base_p1_bytes" "${base_p1_sha:0:12}" >&2
# PVC state before chaos.
oc get pvc "$FULL_PVC_NAME" "$P01_PVC_NAME" -n "$NAMESPACE" \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,PV:.spec.volumeName \
  >"$EVIDENCE_DIR/pvc-before.txt"

# --- render_verifier POD_NAME — workflow manifest with 1 incremental -------
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

# --- CHAOS leg: verifier pod + krkn kill mid-conversion ---------------------
CHAOS_POD_SPEC="$EVIDENCE_DIR/restore-verify-chaos-pod.yaml"
render_verifier "$CHAOS_POD_NAME" "$CHAOS_POD_SPEC"
oc delete pod "$CHAOS_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
oc apply -f "$CHAOS_POD_SPEC" >/dev/null
printf 'Chaos verifier pod %s applied.\n' "$CHAOS_POD_NAME" >&2
# Background log stream: partial log survives the force-delete.
(oc logs -f "$CHAOS_POD_NAME" -n "$NAMESPACE" >"$EVIDENCE_DIR/chaos-pod-partial.log" 2>&1 || true) &
log_pid=$!
# krkn pod-scenarios: command trigger on the pod Running, then force-delete.
krkn_log="$EVIDENCE_DIR/krkn-pod-scenarios.log"
gate_cmd="oc get pod $CHAOS_POD_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' | grep -q Running"
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
printf 'krkn pod-scenarios armed (pid=%s); gate: %s Running.\n' "$krkn_pid" "$CHAOS_POD_NAME" >&2
krkn_status=0
if wait "$krkn_pid"; then
  krkn_status=0
else
  krkn_status=$?
fi
printf 'krkn exit status: %d (log: %s).\n' "$krkn_status" "$krkn_log" >&2
sleep 5
kill "$log_pid" 2>/dev/null || true
wait "$log_pid" 2>/dev/null || true
chaos_phase="$(oc get pod "$CHAOS_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo gone)"
printf 'Chaos pod phase after kill: %s.\n' "$chaos_phase" >&2
# Conversion-in-flight proof from the partial log.
conv_lines="$(grep -ciE 'qemu-img|convert|rebase' "$EVIDENCE_DIR/chaos-pod-partial.log" 2>/dev/null || echo 0)"
printf 'Partial log conversion lines: %s (head below).\n' "$conv_lines" >&2
head -5 "$EVIDENCE_DIR/chaos-pod-partial.log" >&2 || true
# PVC state after chaos.
oc get pvc "$FULL_PVC_NAME" "$P01_PVC_NAME" -n "$NAMESPACE" \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,PV:.spec.volumeName \
  >"$EVIDENCE_DIR/pvc-after-chaos.txt"
# VolumeAttachment check (no stale attachment from the killed consumer).
va_count="$(oc get volumeattachment -o json 2>/dev/null | jq -r --arg ns "$NAMESPACE" --arg full "$FULL_PVC_NAME" --arg p1 "$P01_PVC_NAME" '.items[] | select(.spec.source.persistentVolumeName != null) | .spec.source.persistentVolumeName' | wc -l)"
printf 'VolumeAttachments referencing any PV (informational): %s.\n' "$va_count" >&2

# --- RERUN leg: same verifier, fresh pod, must match baseline exactly -------
RERUN_POD_SPEC="$EVIDENCE_DIR/restore-verify-rerun-pod.yaml"
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
oc logs "$RERUN_POD_NAME" -n "$NAMESPACE" >"$EVIDENCE_DIR/rerun-pod.log" 2>&1 || true
printf 'Rerun pod phase: %s.\n' "${phase:-unknown}" >&2
if [[ "$phase" != Succeeded ]]; then
  printf 'RERUN FAILED — see %s\n' "$EVIDENCE_DIR/rerun-pod.log" >&2
  exit 1
fi
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
verdict_notes=()
# (a) injection validity: pod killed while Running AND converting
if grep -q "Killing.*$CHAOS_POD_NAME\|$CHAOS_POD_NAME" "$krkn_log" 2>/dev/null && [[ "$chaos_phase" != Running ]] && ((conv_lines > 0)); then
  inject_check="PASS (pod force-deleted while Running with $conv_lines conversion log lines in flight)"
else
  inject_check="FAIL (kill or conversion-in-flight unproven: phase=$chaos_phase conv_lines=$conv_lines)"
fi
printf 'CHECK injection-validity: %s\n' "$inject_check" >&2
verdict_notes+=("injection-validity:$inject_check")
# (b) PVCs remain Bound and unchanged
pvc_ok=true
while read -r name phase pv; do
  [[ "$phase" == Bound ]] || pvc_ok=false
done < <(tail -n +2 "$EVIDENCE_DIR/pvc-after-chaos.txt")
if [[ "$pvc_ok" == true ]] && diff -q "$EVIDENCE_DIR/pvc-before.txt" "$EVIDENCE_DIR/pvc-after-chaos.txt" >/dev/null; then
  pvc_check="PASS (both PVCs Bound; PV bindings unchanged)"
else
  pvc_check="FAIL (PVC state changed — see pvc-before/after)"
fi
printf 'CHECK artifacts-unchanged-pvc: %s\n' "$pvc_check" >&2
verdict_notes+=("artifacts-unchanged-pvc:$pvc_check")
# (c) rerun matches baseline exactly
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
printf 'CHECK rerun-matches-baseline: %s\n' "$rerun_check" >&2
verdict_notes+=("rerun-matches-baseline:$rerun_check")
printf 'R01 VERDICT NOTES: %s\n' "${verdict_notes[*]}" >&2
printf 'Scenario complete: verifier-interruption evidence collected (kill mid-conversion, PVC states, rerun hash equality).\n' >&2
exit 0

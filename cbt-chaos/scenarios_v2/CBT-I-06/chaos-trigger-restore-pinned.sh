#!/usr/bin/env bash
# CBT-I-06 r01 pinned restore verification.
#
# The workflow's restore-verify pod could not schedule: the handler kill at
# 10:05:48Z landed mid-hotplug-teardown and leaked a bind mount of the p01
# backup PVC into the replacement handler's mount namespace → krbd unmap
# EBUSY → VolumeAttachment pvc-97a9daab stuck attached on d38-h18-000-r660 →
# the verifier (scheduled on d39-h08) hit Multi-Attach for 30 min.
#
# This script renders the SAME verifier pod (workflow's own
# manifests/restore-verify-pod.yaml, full + p01 mounts) but pins it to
# d38-h18-000-r660 — the node where the volume is stuck attached — so the
# mount succeeds without Multi-Attach. This separates "backup data intact"
# from "leaked attachment blocks cross-node consumers".
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
export NAMESPACE
load_run_id
NODE=d38-h18-000-r660
full_pvc="vm-backup-pvc-${RUN_ID}"
p01_pvc="vm-incremental-pvc-${RUN_ID}-p01"
manifest="$ROOT_DIR/runs/$RUN_ID/workload-manifest.json"
ev_dir="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-I-06/runs/$RUN_ID"
mkdir -p "$ev_dir"
pod_spec="$ev_dir/restore-verify-pinned-pod.yaml"
log="$ev_dir/restore-verify-pinned.log"

vol_snip="$(mktemp)"; mnt_snip="$(mktemp)"
printf '    - name: incremental-p01\n      persistentVolumeClaim:\n        claimName: %s\n        readOnly: true\n' "$p01_pvc" >"$vol_snip"
printf '        - name: incremental-p01\n          mountPath: /backups/incrementals/p01\n          readOnly: true\n' >"$mnt_snip"
sed \
  -e "s|__POD_NAME__|$RESTORE_POD_NAME|g" \
  -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__FULL_PVC__|$full_pvc|g" \
  -e "s|__HELPER_IMAGE__|$RESTORE_HELPER_IMAGE|g" \
  -e "s|__WORKLOAD_DIR__|$RESTORE_WORKLOAD_MOUNT_DIR|g" \
  -e "s|__INCREMENTAL_COUNT__|1|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_KEY__|app.kubernetes.io/managed-by|g" \
  -e "s|__MANAGED_BY_VALUE__|virt-cbt-lab|g" \
  -e "s|__RUN_ID_LABEL_KEY__|virt-cbt-lab/run-id|g" \
  -e "s|^  restartPolicy: Never|  restartPolicy: Never\n  nodeName: $NODE|" \
  "$ROOT_DIR/manifests/restore-verify-pod.yaml" \
  | awk -v v="$vol_snip" -v m="$mnt_snip" '
      /^[[:space:]]*#[[:space:]]__INCREMENTAL_VOLUMES__[[:space:]]*$/ { while ((getline l < v) > 0) print l; close(v); next }
      /^[[:space:]]*#[[:space:]]__INCREMENTAL_MOUNTS__[[:space:]]*$/ { while ((getline l < m) > 0) print l; close(m); next }
      { print }
    ' >"$pod_spec"
printf 'Rendered pinned verifier pod (node %s) -> %s\n' "$NODE" "$pod_spec"

oc delete pod "$RESTORE_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
oc apply -f "$pod_spec" >/dev/null
printf 'Applied %s (full + p01 mounts, pinned to %s).\n' "$RESTORE_POD_NAME" "$NODE"
phase=""
for ((i = 1; i <= 1800; i++)); do
  phase="$(oc get pod "$RESTORE_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
  if ((i % 60 == 0)); then printf 'pod still %s after %ss\n' "${phase:-unknown}" "$i" >&2; fi
  sleep 1
done
oc logs "$RESTORE_POD_NAME" -n "$NAMESPACE" >"$log" 2>&1 || true
printf 'Pod phase: %s (log: %s)\n' "${phase:-unknown}" "$log"
[[ "$phase" == Succeeded ]] || { printf 'Pinned restore pod did not Succeed.\n' >&2; exit 1; }

exp_f_count="$(jq -r '.baseline.file_count' "$manifest")"
exp_f_bytes="$(jq -r '.baseline.total_payload_bytes' "$manifest")"
exp_f_sha="$(jq -r '.baseline.manifest_sha256' "$manifest")"
exp_p_count="$(jq -r '.incrementals[0].total_file_count' "$manifest")"
exp_p_bytes="$(jq -r '.incrementals[0].total_payload_bytes' "$manifest")"
exp_p_sha="$(jq -r '.incrementals[0].manifest_sha256' "$manifest")"
act_f_count="$(grep -oP '^FULL_WORKLOAD_FILE_COUNT=\K[0-9]+' "$log" | tail -1)"
act_f_bytes="$(grep -oP '^FULL_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$log" | tail -1)"
act_f_sha="$(grep -oP '^FULL_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$log" | tail -1)"
act_p_count="$(grep -oP '^PASS_01_WORKLOAD_FILE_COUNT=\K[0-9]+' "$log" | tail -1)"
act_p_bytes="$(grep -oP '^PASS_01_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$log" | tail -1)"
act_p_sha="$(grep -oP '^PASS_01_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$log" | tail -1)"
printf 'FULL  expected: %s / %s / %s\n' "$exp_f_count" "$exp_f_bytes" "$exp_f_sha"
printf 'FULL  actual:   %s / %s / %s\n' "${act_f_count:-?}" "${act_f_bytes:-?}" "${act_f_sha:-?}"
printf 'PASS1 expected: %s / %s / %s\n' "$exp_p_count" "$exp_p_bytes" "$exp_p_sha"
printf 'PASS1 actual:   %s / %s / %s\n' "${act_p_count:-?}" "${act_p_bytes:-?}" "${act_p_sha:-?}"
result=PASS
[[ "$act_f_count" == "$exp_f_count" && "$act_f_bytes" == "$exp_f_bytes" && "$act_f_sha" == "$exp_f_sha" ]] || result=FAIL
[[ "$act_p_count" == "$exp_p_count" && "$act_p_bytes" == "$exp_p_bytes" && "$act_p_sha" == "$exp_p_sha" ]] || result=FAIL
printf 'CHECK pinned-restore-data-correctness: %s\n' "$result"
oc delete pod "$RESTORE_POD_NAME" -n "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
[[ "$result" == PASS ]] || exit 1

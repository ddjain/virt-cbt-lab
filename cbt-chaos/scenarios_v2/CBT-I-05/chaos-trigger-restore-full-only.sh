#!/usr/bin/env bash
# CBT-I-05 r02 full-only restore verification (direct verifier).
#
# The workflow's vm-cbt-restore-test refuses this run's state (planned 1
# incremental pass, 0 completed — the manifest gate requires equality; the
# I-02-class workflow gap). This script reproduces EXACTLY the workflow's
# own verification mechanism for the FULL artifact alone: render
# manifests/restore-verify-pod.yaml with zero incremental mounts (the pod's
# own script then verifies only the full qcow2 — expected_incremental_count
# 0 with no /backups/incrementals mounts is its designed full-only mode),
# run it, and compare the pod's FULL_WORKLOAD_* outputs against the run's
# workload-manifest.json baseline (same three checks the workflow records:
# file_count, payload_bytes, manifest_sha256).
#
# Usage: RUN_ID=20261013-cbti05-r02 KUBECONFIG_PATH=... bash chaos-trigger-restore-full-only.sh
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
load_run_id
manifest_path="$ROOT_DIR/runs/$RUN_ID/workload-manifest.json"
evidence_log="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-I-05/runs/$RUN_ID/restore-test-full-only.log"
pod_spec="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-I-05/runs/$RUN_ID/restore-verify-full-only-pod.yaml"
full_pvc_name="vm-backup-pvc-${RUN_ID}"

expected_full_count="$(jq -r '.baseline.file_count' "$manifest_path")"
expected_full_bytes="$(jq -r '.baseline.total_payload_bytes' "$manifest_path")"
expected_full_manifest="$(jq -r '.baseline.manifest_sha256' "$manifest_path")"

# Render the workflow's own verifier pod: zero incremental volumes/mounts.
mkdir -p "$(dirname "$pod_spec")"
sed \
  -e "s|__POD_NAME__|$RESTORE_POD_NAME|g" \
  -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__FULL_PVC__|$full_pvc_name|g" \
  -e "s|__HELPER_IMAGE__|$RESTORE_HELPER_IMAGE|g" \
  -e "s|__WORKLOAD_DIR__|$RESTORE_WORKLOAD_MOUNT_DIR|g" \
  -e "s|__INCREMENTAL_COUNT__|0|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_KEY__|app.kubernetes.io/managed-by|g" \
  -e "s|__MANAGED_BY_VALUE__|virt-cbt-lab|g" \
  -e "s|__RUN_ID_LABEL_KEY__|virt-cbt-lab/run-id|g" \
  "$ROOT_DIR/manifests/restore-verify-pod.yaml" \
  | awk '
      /^    # __INCREMENTAL_VOLUMES__$/ { next }
      /^        # __INCREMENTAL_MOUNTS__$/ { next }
      { print }
    ' >"$pod_spec"

oc delete pod "$RESTORE_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
oc apply -f "$pod_spec" >/dev/null
printf 'Applied restore-verify pod %s (full PVC only, 0 incremental mounts).\n' "$RESTORE_POD_NAME"

phase=""
for ((attempt = 1; attempt <= 1800; attempt++)); do
  phase="$(oc get pod "$RESTORE_POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
  sleep 1
done
oc logs "$RESTORE_POD_NAME" -n "$NAMESPACE" >"$evidence_log" 2>&1 || true
if [[ "$phase" != Succeeded ]]; then
  printf 'Restore-verify pod phase=%s — see %s\n' "${phase:-unknown}" "$evidence_log" >&2
  exit 1
fi

full_actual_count="$(grep -oP '^FULL_WORKLOAD_FILE_COUNT=\K[0-9]+' "$evidence_log" | tail -1 || true)"
full_actual_bytes="$(grep -oP '^FULL_WORKLOAD_PAYLOAD_BYTES=\K[0-9]+' "$evidence_log" | tail -1 || true)"
full_actual_manifest="$(grep -oP '^FULL_WORKLOAD_MANIFEST_SHA256=\K[0-9a-f]+' "$evidence_log" | tail -1 || true)"

printf 'Expected: count=%s bytes=%s sha=%s\n' "$expected_full_count" "$expected_full_bytes" "$expected_full_manifest"
printf 'Actual:   count=%s bytes=%s sha=%s\n' "${full_actual_count:-?}" "${full_actual_bytes:-?}" "${full_actual_manifest:-?}"
result=PASS
[[ "$full_actual_count" == "$expected_full_count" ]] || result=FAIL
[[ "$full_actual_bytes" == "$expected_full_bytes" ]] || result=FAIL
[[ "$full_actual_manifest" == "$expected_full_manifest" ]] || result=FAIL
printf 'CHECK full-artifact-restorable: %s\n' "$result"
oc delete pod "$RESTORE_POD_NAME" -n "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
[[ "$result" == PASS ]] || exit 1

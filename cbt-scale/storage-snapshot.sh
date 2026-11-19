#!/usr/bin/env bash
# Storage utilization snapshot at each lifecycle point of the 200-VM scale run.
# Usage: storage-snapshot.sh <label>
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG}"
LABEL="${1:?label required}"
TOOL=$(oc get pod -n openshift-storage -l app=rook-ceph-tools -o jsonpath={.items[0].metadata.name})
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCALE_STATE_DIR="${SCALE_STATE_DIR:-$ROOT_DIR/artifacts}"
mkdir -p "$SCALE_STATE_DIR"
OUT="$SCALE_STATE_DIR/storage-200b.csv"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ceph df as JSON: robust parsing
CDF=$(oc rsh -n openshift-storage $TOOL ceph df --format json)
read -r RAW_TOTAL RAW_USED <<<"$(jq -r '.stats.total_bytes as $t | .stats.total_used_raw_bytes as $u | "\($t) \($u)"' <<<"$CDF")"
read -r SP_STORED SP_USED <<<"$(jq -r '.pools[] | select(.name=="cbt-scale-pool") | .stats | "\(.stored) \(.bytes_used)"' <<<"$CDF")"
read -r MP_STORED MP_USED <<<"$(jq -r '.pools[] | select(.name=="ocs-storagecluster-cephblockpool") | .stats | "\(.stored) \(.bytes_used)"' <<<"$CDF")"

# PVC claim sums by class (provisioned view), vm-cbt-demo namespace
read -r SC_N SC_B RB_N RB_B <<<"$(oc get pvc -n vm-cbt-demo -o json | jq -r '
  [.items[] | {sc: .spec.storageClassName, b: (.spec.resources.requests.storage | if test("Gi$") then (rtrimstr("Gi")|tonumber)*1073741824 else tonumber end)}] |
  [ (map(select(.sc=="ocs-storagecluster-ceph-rbd-scale")) | length),
    (map(select(.sc=="ocs-storagecluster-ceph-rbd-scale")) | map(.b) | add // 0),
    (map(select(.sc=="ocs-storagecluster-ceph-rbd")) | length),
    (map(select(.sc=="ocs-storagecluster-ceph-rbd")) | map(.b) | add // 0) ] | @tsv')"

GiB=$((1024*1024*1024))
printf '%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n' "$TS" "$LABEL" \
  "$((RAW_TOTAL/GiB))" "$((RAW_USED/GiB))" \
  "$((SP_STORED/GiB))" "$((SP_USED/GiB))" \
  "$((MP_STORED/GiB))" "$((MP_USED/GiB))" \
  "${SC_N:-0}" "$(( ${SC_B:-0} / GiB ))" "${RB_N:-0}" "$(( ${RB_B:-0} / GiB ))" >> "$OUT"
echo "snapshot[$LABEL] raw_used=$((RAW_USED/GiB))GiB scale_stored=$((SP_STORED/GiB))GiB managed_stored=$((MP_STORED/GiB))GiB scale_claims=${SC_N:-0}PVs/$(( ${SC_B:-0} / GiB ))GiB root_claims=${RB_N:-0}PVs/$(( ${RB_B:-0} / GiB ))GiB"

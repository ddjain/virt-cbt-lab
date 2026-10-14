#!/usr/bin/env bash
# CBT-O-10: in-ceph I/O contention — W writer pods with dedicated RBD PVCs
# running dsync writes during the full backup copy. Direct pods (krkn's io
# hog writes to hostPath; useless for ceph contention).
#
# Usage:
#   RUN_ID=20261014-cbto10-r01 KUBECONFIG_PATH=/root/mno/kubeconfig \
#     [WRITER_COUNT=4] [WRITE_DURATION=120] bash chaos-trigger.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"
: "${RUN_ID:?Set RUN_ID}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="rhel9"
MANIFEST_VARIANT="odf"
VM_DATA_SOURCE_NAME="${VM_DATA_SOURCE_NAME:-rhel9-rbd}"
VM_DATA_SOURCE_NAMESPACE="openshift-virtualization-os-images"
export NAMESPACE VM_DATA_SOURCE_NAME VM_DATA_SOURCE_NAMESPACE
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
WRITER_COUNT="${WRITER_COUNT:-4}"
WRITE_DURATION="${WRITE_DURATION:-120}"
HDD_WORKERS_PER_POD="${HDD_WORKERS_PER_POD:-4}"
WRITER_NS="cbt-o10-writers"
WRITER_IMAGE="quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog"  # has stress-ng
CEPH_NS="openshift-storage"
RBD_SC="ocs-storagecluster-ceph-rbd"
VM_NAME="vm-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-O-10/runs/$RUN_ID"
TOOLBOX_CMD() { oc exec -n "$CEPH_NS" "$(oc get pods -n "$CEPH_NS" -l app=rook-ceph-tools -o name | head -1)" -- "$@"; }

# --- Guards (ODF family) --------------------------------------------------------------
if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Refusing to run: %s already exists.\n' "$ROOT_DIR/runs/$RUN_ID" >&2
  exit 2
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Refusing to run: resources for %s already exist.\n' "$RUN_ID" >&2
  exit 2
fi
ceph_health="$(oc get cephcluster -n "$CEPH_NS" \
  -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || echo '')"
if [[ "$ceph_health" != HEALTH_OK ]]; then
  printf 'Ceph cluster not HEALTH_OK (got: %s) — aborting.\n' "${ceph_health:-unavailable}" >&2
  exit 2
fi
golden_pvc="$(oc get datasource "$VM_DATA_SOURCE_NAME" -n "$VM_DATA_SOURCE_NAMESPACE" \
  -o jsonpath='{.spec.source.pvc.name}' 2>/dev/null || echo '')"
golden_sc="$(oc get pvc "$golden_pvc" -n "$VM_DATA_SOURCE_NAMESPACE" \
  -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo '')"
if [[ "$golden_sc" != "$RBD_SC" ]]; then
  printf 'Golden DataSource %s not on RBD (sc=%s) — run CBT-O-01 first.\n' \
    "$VM_DATA_SOURCE_NAME" "${golden_sc:-unknown}" >&2
  exit 2
fi
# A non-storage worker node for the writer pods (contention target is ceph, not the node).
WRITER_NODE="$(oc get nodes -l '!cluster.ocs.openshift.io/openshift-storage' \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
[[ -n "$WRITER_NODE" ]] || WRITER_NODE="$(oc get nodes -o jsonpath='{.items[0].metadata.name}')"
printf 'Writer pods will run on non-storage node %s.\n' "$WRITER_NODE" >&2
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'O10: in-ceph contention (writers=%s dur=%ss), run %s.\n' \
  "$WRITER_COUNT" "$WRITE_DURATION" "$RUN_ID" >&2

# --- Pre-create writer PVCs + idle writer pods (before the backup) ----------------------
oc get namespace "$WRITER_NS" >/dev/null 2>&1 || oc create namespace "$WRITER_NS" >/dev/null
oc adm policy add-scc-to-user privileged -z default -n "$WRITER_NS" >/dev/null 2>&1 || true
for ((w = 1; w <= WRITER_COUNT; w++)); do
  cat <<-EOF | oc apply -f - >/dev/null
	apiVersion: v1
	kind: PersistentVolumeClaim
	metadata:
	  name: writer-pvc-${RUN_ID}-${w}
	  namespace: ${WRITER_NS}
	spec:
	  accessModes: [ReadWriteOnce]
	  resources:
	    requests:
	      storage: 10Gi
	  storageClassName: ${RBD_SC}
	---
	apiVersion: v1
	kind: Pod
	metadata:
	  name: writer-${RUN_ID}-${w}
	  namespace: ${WRITER_NS}
	spec:
	  nodeSelector:
	    kubernetes.io/hostname: ${WRITER_NODE}
	  restartPolicy: Never
	  tolerations:
	  - operator: Exists
	  containers:
	  - name: writer
	    image: ${WRITER_IMAGE}
	    imagePullPolicy: IfNotPresent
	    command: ["/bin/bash", "-c", "sleep infinity"]
	    securityContext:
	      privileged: true
	    volumeMounts:
	    - name: data
	      mountPath: /hog-data
	  volumes:
	  - name: data
	    persistentVolumeClaim:
	      claimName: writer-pvc-${RUN_ID}-${w}
	EOF
done
printf 'Pre-created %s writer pods (idle). Waiting Ready.\n' "$WRITER_COUNT" >&2
for ((w = 1; w <= WRITER_COUNT; w++)); do
  oc wait "pod/writer-${RUN_ID}-${w}" -n "$WRITER_NS" \
    --for=condition=Ready --timeout=300s >/dev/null 2>&1 || \
    printf 'Writer %s not Ready after 5m — continuing (count evidence in verdict).\n' "$w" >&2
done

# --- Full backup in background; start writers at gate ------------------------------------
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/full-stage.log" 2>&1 &
wf_pid=$!
printf 'Workflow (full) started (pid=%s); polling for %s Progressing.\n' "$wf_pid" "$FULL_BACKUP_NAME" >&2
gate_hit_at=""
copy_start_epoch=$(date +%s)
for ((attempt = 1; attempt <= 450; attempt++)); do
  prog="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo '')"
  if [[ "$prog" == True ]]; then
    gate_hit_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    break
  fi
  sleep 2
done
[[ -n "$gate_hit_at" ]] || { printf 'Gate never hit — aborting.\n' >&2; kill "$wf_pid" 2>/dev/null || true; exit 2; }
printf 'Progressing=True at %s — starting %s dsync writers for %ss.\n' \
  "$gate_hit_at" "$WRITER_COUNT" "$WRITE_DURATION" >&2
for ((w = 1; w <= WRITER_COUNT; w++)); do
  oc exec "writer-${RUN_ID}-${w}" -n "$WRITER_NS" -- bash -c \
    "date -u +WRITER_START_%FT%T; cd /hog-data && rm -rf ./tmp-stress-* && stress-ng --hdd ${HDD_WORKERS_PER_POD} --hdd-bytes 2g --hdd-write-size 1m --hdd-opts dsync --timeout ${WRITE_DURATION}; date -u +WRITER_END_%FT%T" \
    >"$EVIDENCE_DIR/writer-${w}.log" 2>&1 &
done
writers_pids="$!"
# OSD perf sampler during the window.
( for ((i = 1; i <= WRITE_DURATION / 10; i++)); do
    printf '=== %s\n' "$(date -u +%H:%M:%S)"
    TOOLBOX_CMD ceph osd perf 2>/dev/null | head -8 || true
    sleep 10
  done ) >"$EVIDENCE_DIR/ceph-osd-perf-during.txt" 2>/dev/null &
perf_pid=$!
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
copy_end_epoch=$(date +%s)
copy_wall=$((copy_end_epoch - copy_start_epoch))
printf 'Workflow (full) exit status: %d; wall gate-to-finish: %ss.\n' "$wf_status" "$copy_wall" >&2
wait "$writers_pids" 2>/dev/null || true
kill "$perf_pid" 2>/dev/null || true

# --- Cleanup writers + PVCs ---------------------------------------------------------------
for ((w = 1; w <= WRITER_COUNT; w++)); do
  oc delete pod "writer-${RUN_ID}-${w}" -n "$WRITER_NS" --ignore-not-found >/dev/null 2>&1 || true
  oc delete pvc "writer-pvc-${RUN_ID}-${w}" -n "$WRITER_NS" --ignore-not-found >/dev/null 2>&1 || true
done
ceph_health_post="$(oc get cephcluster -n "$CEPH_NS" \
  -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || echo '')"
printf 'Ceph health post-leg: %s.\n' "${ceph_health_post:-unknown}" >&2

# --- Follow-up incremental ------------------------------------------------------------------
incr_status=""
backup_done_status="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo '')"
backup_done_reason="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || echo '')"
if [[ "$backup_done_status" == True && "$backup_done_reason" == Successfully* ]]; then
  if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
    GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
    GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
    GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
    GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH" \
    >"$EVIDENCE_DIR/incr-stage.log" 2>&1; then
    incr_status=0
  else
    incr_status=$?
  fi
fi
tracker_cp="$(oc get vmbackuptracker -n "$NAMESPACE" "$TRACKER_NAME" \
  -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || echo '?')"

# --- Verdict checks ---------------------------------------------------------------------------
checks_file="$EVIDENCE_DIR/trigger-checks.txt"
: > "$checks_file"
writers_started=$(grep -l "WRITER_START" "$EVIDENCE_DIR"/writer-*.log 2>/dev/null | wc -l | tr -d ' ')
printf 'CHECK writers-active: %s/%s\n' "$writers_started" "$WRITER_COUNT" | tee -a "$checks_file" >&2
printf 'CHECK copy-wall-seconds: %s (compare vs O-01 baseline; DEGRADED >= 2x)\n' \
  "$copy_wall" | tee -a "$checks_file" >&2
printf 'CHECK backup-terminal-state: done=%s reason=%s\n' \
  "$backup_done_status" "$backup_done_reason" | tee -a "$checks_file" >&2
printf 'CHECK ceph-health-post: %s\n' "${ceph_health_post:-unknown}" | tee -a "$checks_file" >&2
printf 'CHECK followup-incremental: rc=%s tracker=%s\n' \
  "${incr_status:-skipped}" "$tracker_cp" | tee -a "$checks_file" >&2
printf 'O10 complete.\n' >&2
exit 0

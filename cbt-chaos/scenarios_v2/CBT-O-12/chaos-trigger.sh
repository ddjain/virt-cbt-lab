#!/usr/bin/env bash
# CBT-O-12: combined OSD kills + in-ceph I/O contention during the full
# backup copy (O-06 + O-10 mechanisms fired at the same gate). X-04-style
# combined-failure attribution on ODF.
#
# Usage:
#   RUN_ID=20261014-cbto12-r01 KUBECONFIG_PATH=/root/mno/kubeconfig \
#     [OSD_KILL_COUNT=1] [WRITER_COUNT=4] [WRITE_DURATION=120] bash chaos-trigger.sh
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
OSD_KILL_COUNT="${OSD_KILL_COUNT:-1}"
WRITER_COUNT="${WRITER_COUNT:-4}"
WRITE_DURATION="${WRITE_DURATION:-120}"
HDD_WORKERS_PER_POD="${HDD_WORKERS_PER_POD:-4}"
WRITER_NS="cbt-o12-writers"
WRITER_IMAGE="quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-hog"
CEPH_NS="openshift-storage"
RBD_SC="ocs-storagecluster-ceph-rbd"
VM_NAME="vm-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-O-12/runs/$RUN_ID"
TOOLBOX_CMD() { oc exec -n "$CEPH_NS" "$(oc get pods -n "$CEPH_NS" -l app=rook-ceph-tools -o name | head -1)" -- "$@"; }

# --- Guards (ODF family + active+clean) --------------------------------------------------
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
pg_stat="$(TOOLBOX_CMD ceph pg stat 2>/dev/null || echo '')"
if [[ "$pg_stat" != *"active+clean"* ]]; then
  printf 'PGs not active+clean (got: %s) — aborting.\n' "${pg_stat:-unavailable}" >&2
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
WRITER_NODE="$(oc get nodes -l '!cluster.ocs.openshift.io/openshift-storage' \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
[[ -n "$WRITER_NODE" ]] || WRITER_NODE="$(oc get nodes -o jsonpath='{.items[0].metadata.name}')"
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'O12: combined OSD kill (%s) + writers (%s) during full backup, run %s.\n' \
  "$OSD_KILL_COUNT" "$WRITER_COUNT" "$RUN_ID" >&2

# --- Pre-create writer pods (idle) ----------------------------------------------------------
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
for ((w = 1; w <= WRITER_COUNT; w++)); do
  oc wait "pod/writer-${RUN_ID}-${w}" -n "$WRITER_NS" \
    --for=condition=Ready --timeout=300s >/dev/null 2>&1 || true
done
printf '%s writer pods idle and Ready.\n' "$WRITER_COUNT" >&2

# --- Direct-krkn scaffolding (OSD kills) ------------------------------------------------------
krkn_work="/tmp/o12-krkn-work-${RUN_ID}"
scenario_yaml="$krkn_work/scenario.yml"
rm -rf "$krkn_work"
mkdir -p "$krkn_work"
cat >"$krkn_work/kraken-config.yml" <<EOF
kraken:
    distribution: openshift
    kubeconfig_path: /work/kubeconfig
    exit_on_failure: False
    publish_kraken_status: False
    signal_state: RUN
    signal_address: 0.0.0.0
    port: 8081
    auto_rollback: False
    chaos_scenarios:
        -   pod_disruption_scenarios:
                - /work/scenario.yml
cerberus:
    cerberus_enabled: False
performance_monitoring:
    capture_metrics: False
    check_critical_alerts: False
    enable_alerts: False
    enable_metrics: False
tunings:
    wait_duration: 5
    iterations: 1
    daemon_mode: False
telemetry:
    enabled: False
elastic:
    enable_elastic: False
EOF
cp "$KUBECONFIG_PATH" "$krkn_work/kubeconfig"
chmod 644 "$krkn_work/kubeconfig"
krknctl_log="$EVIDENCE_DIR/krkn.log"

# --- Full backup in background; fire BOTH injections at gate -----------------------------------
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
printf 'Progressing=True at %s — firing writers THEN OSD kills (both in-window).\n' "$gate_hit_at" >&2
# (a) writers first (instant oc exec; no scheduling latency).
for ((w = 1; w <= WRITER_COUNT; w++)); do
  oc exec "writer-${RUN_ID}-${w}" -n "$WRITER_NS" -- bash -c \
    "date -u +WRITER_START_%FT%T; cd /hog-data && rm -rf ./tmp-stress-* && stress-ng --hdd ${HDD_WORKERS_PER_POD} --hdd-bytes 2g --hdd-write-size 1m --hdd-opts dsync --timeout ${WRITE_DURATION}; date -u +WRITER_END_%FT%T" \
    >"$EVIDENCE_DIR/writer-${w}.log" 2>&1 &
done
# (b) OSD kills via direct krkn (deployment latency ~10-30s).
cat >"$scenario_yaml" <<EOF
- config:
    namespace_pattern: "$CEPH_NS"
    label_selector: "app=rook-ceph-osd"
    kill: $OSD_KILL_COUNT
    execution: parallel
    force: false
    krkn_pod_recovery_time: 1800
    timeout: 300
    duration: 30
EOF
cp "$scenario_yaml" "$EVIDENCE_DIR/scenario.yml"
podman run --rm --entrypoint bash \
  -v "$krkn_work":/work:Z \
  quay.io/krkn-chaos/krkn:latest \
  -c "cd /home/krkn/kraken && timeout 2400 python3.11 run_kraken.py -c /work/kraken-config.yml" \
  >"$krknctl_log" 2>&1 &
krkn_pid=$!
( for ((i = 1; i <= 60; i++)); do
    printf '%s ' "$(date -u +%H:%M:%S)"
    TOOLBOX_CMD ceph health 2>/dev/null || echo unreachable
    sleep 5
  done ) >"$EVIDENCE_DIR/ceph-health-during.txt" 2>/dev/null &
health_pid=$!
krkn_rc=0
if wait "$krkn_pid"; then krkn_rc=0; else krkn_rc=$?; fi
printf 'krkn exited rc=%d (non-authoritative for PDB-paced recovery).\n' "$krkn_rc" >&2
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
copy_end_epoch=$(date +%s)
copy_wall=$((copy_end_epoch - copy_start_epoch))
printf 'Workflow (full) exit status: %d; wall gate-to-finish: %ss.\n' "$wf_status" "$copy_wall" >&2
kill "$health_pid" 2>/dev/null || true

# --- Cleanup writers + PVCs ----------------------------------------------------------------------
for ((w = 1; w <= WRITER_COUNT; w++)); do
  oc delete pod "writer-${RUN_ID}-${w}" -n "$WRITER_NS" --ignore-not-found >/dev/null 2>&1 || true
  oc delete pvc "writer-pvc-${RUN_ID}-${w}" -n "$WRITER_NS" --ignore-not-found >/dev/null 2>&1 || true
done
ceph_health_post="$(oc get cephcluster -n "$CEPH_NS" \
  -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || echo '')"

# --- Follow-up incremental --------------------------------------------------------------------------
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

# --- Verdict checks -----------------------------------------------------------------------------------
checks_file="$EVIDENCE_DIR/trigger-checks.txt"
: > "$checks_file"
killed_pods=$(grep -cE "deleting pod|Gracefully deleting pod|Force deleting pod" "$krknctl_log" 2>/dev/null || echo 0)
writers_started=$(grep -l "WRITER_START" "$EVIDENCE_DIR"/writer-*.log 2>/dev/null | wc -l | tr -d ' ')
printf 'CHECK injection-combined: osds-requested=%s osds-evidenced=%s writers=%s/%s\n' \
  "$OSD_KILL_COUNT" "$killed_pods" "$writers_started" "$WRITER_COUNT" | tee -a "$checks_file" >&2
printf 'CHECK copy-wall-seconds: %s (compare vs O-01 baseline; DEGRADED >= 2x)\n' \
  "$copy_wall" | tee -a "$checks_file" >&2
printf 'CHECK backup-terminal-state: done=%s reason=%s (attribution: which cause dominates?)\n' \
  "$backup_done_status" "$backup_done_reason" | tee -a "$checks_file" >&2
printf 'CHECK ceph-health-post: %s\n' "${ceph_health_post:-unknown}" | tee -a "$checks_file" >&2
printf 'CHECK followup-incremental: rc=%s tracker=%s\n' \
  "${incr_status:-skipped}" "$tracker_cp" | tee -a "$checks_file" >&2
printf 'O12 complete. Family rule: verify HEALTH_OK + active+clean before any further O-leg.\n' >&2
exit 0

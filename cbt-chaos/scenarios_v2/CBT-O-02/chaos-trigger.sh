#!/usr/bin/env bash
# CBT-O-02: kill the csi-rbdplugin node-plugin pod on the VM's node during
# the full backup copy (direct-krkn pod_disruption pattern; krknctl cannot
# express name-pattern AND node-names targeting).
#
# Usage:
#   RUN_ID=20261014-cbto02-r01 KUBECONFIG_PATH=/root/mno/kubeconfig \
#     [FORCE_DELETE=false] [KILL_AT_ATTACH=false] bash chaos-trigger.sh
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
FORCE_DELETE="${FORCE_DELETE:-false}"
KILL_AT_ATTACH="${KILL_AT_ATTACH:-false}"   # o02c leg: gate on attach window
CSI_NS="openshift-storage"
NODEPLUGIN_PATTERN='^openshift-storage\.rbd\.csi\.ceph\.com-nodeplugin-'
VM_NAME="vm-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
FULL_BACKUP_PVC_NAME="vm-backup-pvc-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-O-02/runs/$RUN_ID"

# --- Guards (ODF family: ceph health + golden-on-RBD; no HPP pool guard) --------
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
ceph_health="$(oc get cephcluster -n openshift-storage \
  -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || echo '')"
if [[ "$ceph_health" != HEALTH_OK ]]; then
  printf 'Ceph cluster not HEALTH_OK (got: %s) — aborting.\n' "${ceph_health:-unavailable}" >&2
  exit 2
fi
golden_pvc="$(oc get datasource "$VM_DATA_SOURCE_NAME" -n "$VM_DATA_SOURCE_NAMESPACE" \
  -o jsonpath='{.spec.source.pvc.name}' 2>/dev/null || echo '')"
golden_sc="$(oc get pvc "$golden_pvc" -n "$VM_DATA_SOURCE_NAMESPACE" \
  -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo '')"
if [[ "$golden_sc" != "ocs-storagecluster-ceph-rbd" ]]; then
  printf 'Golden DataSource %s not on RBD (sc=%s) — run CBT-O-01 first.\n' \
    "$VM_DATA_SOURCE_NAME" "${golden_sc:-unknown}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'O02: rbd nodeplugin kill during full backup copy, run %s (force=%s attach-window=%s).\n' \
  "$RUN_ID" "$FORCE_DELETE" "$KILL_AT_ATTACH" >&2

# --- Direct-krkn scaffolding (F-12/X-03 validated pattern) ----------------------
krkn_work="/tmp/o02-krkn-work-${RUN_ID}"
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

# --- Full backup in background; kill at gate -------------------------------------
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/full-stage.log" 2>&1 &
wf_pid=$!
printf 'Workflow (full) started (pid=%s); polling for %s gate.\n' "$wf_pid" "$FULL_BACKUP_NAME" >&2
gate_hit_at=""
vm_node=""
for ((attempt = 1; attempt <= 450; attempt++)); do
  if [[ "$KILL_AT_ATTACH" == true ]]; then
    # o02c: fire while the destination PVC is Bound but the copy has not
    # started (attachment/staging window).
    pvc_phase="$(oc get pvc "$FULL_BACKUP_PVC_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
    prog="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo '')"
    if [[ "$pvc_phase" == Bound && "$prog" != True ]]; then
      gate_hit_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      break
    fi
  else
    prog="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo '')"
    if [[ "$prog" == True ]]; then
      gate_hit_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      break
    fi
  fi
  sleep 2
done
[[ -n "$gate_hit_at" ]] || { printf 'Gate never hit — aborting.\n' >&2; kill "$wf_pid" 2>/dev/null || true; exit 2; }
vm_node="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}' 2>/dev/null || echo '')"
[[ -n "$vm_node" ]] || { printf 'No VM node at gate — aborting.\n' >&2; kill "$wf_pid" 2>/dev/null || true; exit 2; }
printf 'Gate at %s; VM node=%s — killing rbd nodeplugin pod there.\n' "$gate_hit_at" "$vm_node" >&2
plugin_pod_before="$(oc get pods -n "$CSI_NS" -l app=openshift-storage.rbd.csi.ceph.com-nodeplugin \
  -o jsonpath="{.items[?(@.spec.nodeName=='$vm_node')].metadata.name}" 2>/dev/null || echo '')"
plugin_uid_before="$(oc get pod "$plugin_pod_before" -n "$CSI_NS" \
  -o jsonpath='{.metadata.uid}' 2>/dev/null || echo '')"
printf 'Nodeplugin pod on VM node: %s (uid=%s).\n' "$plugin_pod_before" "$plugin_uid_before" >&2
oc get pod "$plugin_pod_before" -n "$CSI_NS" -o json >"$EVIDENCE_DIR/plugin-pod-pre.json" 2>/dev/null || true
cat >"$scenario_yaml" <<EOF
- config:
    namespace_pattern: "$CSI_NS"
    name_pattern: "$NODEPLUGIN_PATTERN"
    node_names:
      - "$vm_node"
    kill: 1
    execution: serial
    force: $FORCE_DELETE
    krkn_pod_recovery_time: 600
    timeout: 120
    duration: 10
EOF
cp "$scenario_yaml" "$EVIDENCE_DIR/scenario.yml"
podman run --rm --entrypoint bash \
  -v "$krkn_work":/work:Z \
  quay.io/krkn-chaos/krkn:latest \
  -c "cd /home/krkn/kraken && timeout 900 python3.11 run_kraken.py -c /work/kraken-config.yml" \
  >"$krknctl_log" 2>&1 &
krkn_pid=$!
krkn_rc=0
if wait "$krkn_pid"; then krkn_rc=0; else krkn_rc=$?; fi
printf 'krkn exited rc=%d at %s.\n' "$krkn_rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
# krkn exit is non-authoritative for monitor-only failures (bugs #5/#8 class);
# judge injection from pod identity + events.
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
printf 'Workflow (full) exit status: %d.\n' "$wf_status" >&2

# --- Plugin replacement verification ---------------------------------------------
replacement_check=FAIL
plugin_pod_after="$(oc get pods -n "$CSI_NS" -l app=openshift-storage.rbd.csi.ceph.com-nodeplugin \
  -o jsonpath="{.items[?(@.spec.nodeName=='$vm_node')].metadata.name}" 2>/dev/null || echo '')"
plugin_uid_after="$(oc get pod "$plugin_pod_after" -n "$CSI_NS" \
  -o jsonpath='{.metadata.uid}' 2>/dev/null || echo '')"
if [[ -n "$plugin_uid_after" && "$plugin_uid_after" != "$plugin_uid_before" ]]; then
  for ((i = 0; i < 60; i++)); do
    ready="$(oc get pod "$plugin_pod_after" -n "$CSI_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '')"
    [[ "$ready" == True ]] && break
    sleep 2
  done
  [[ "$ready" == True ]] && replacement_check=PASS
fi
printf 'Nodeplugin replacement: %s (uid %s -> %s, ready=%s).\n' \
  "$replacement_check" "$plugin_uid_before" "$plugin_uid_after" "${ready:-?}" >&2

# --- Follow-up incremental (only if full succeeded) --------------------------------
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

# --- Verdict checks ----------------------------------------------------------------
checks_file="$EVIDENCE_DIR/trigger-checks.txt"
: > "$checks_file"
injected=NO
if [[ -n "$plugin_uid_before" && "$plugin_uid_after" != "$plugin_uid_before" ]]; then
  injected=YES
fi
printf 'CHECK injection-pod-replaced: %s (uid %s -> %s)\n' \
  "$injected" "$plugin_uid_before" "$plugin_uid_after" | tee -a "$checks_file" >&2
printf 'CHECK backup-terminal-state: done=%s reason=%s\n' \
  "$backup_done_status" "$backup_done_reason" | tee -a "$checks_file" >&2
printf 'CHECK plugin-replacement-ready: %s\n' "$replacement_check" | tee -a "$checks_file" >&2
printf 'CHECK followup-incremental: rc=%s tracker=%s\n' \
  "${incr_status:-skipped}" "$tracker_cp" | tee -a "$checks_file" >&2
printf 'CHECK krkn-rc: %s (non-authoritative; see pod-identity evidence)\n' \
  "$krkn_rc" | tee -a "$checks_file" >&2
printf 'O02 complete.\n' >&2
exit 0

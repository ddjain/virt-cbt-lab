#!/usr/bin/env bash
# CBT-O-03: kill the csi-rbdplugin ctrl-plugin (provisioner/attacher) during
# the full backup copy (direct-krkn pod_disruption pattern).
#
# Usage:
#   RUN_ID=20261014-cbto03-r01 KUBECONFIG_PATH=/root/mno/kubeconfig \
#     [KILL_COUNT=1] [KILL_AT_CLEANUP=false] bash chaos-trigger.sh
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
KILL_COUNT="${KILL_COUNT:-1}"               # o03c: 2
KILL_EXECUTION="${KILL_EXECUTION:-serial}"  # o03c: parallel
KILL_AT_CLEANUP="${KILL_AT_CLEANUP:-false}" # o03b leg
CSI_NS="openshift-storage"
CTRLPLUGIN_PATTERN='^openshift-storage\.rbd\.csi\.ceph\.com-ctrlplugin-'
VM_NAME="vm-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
FULL_BACKUP_PVC_NAME="vm-backup-pvc-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-O-03/runs/$RUN_ID"

# --- Guards (ODF family) ----------------------------------------------------------
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
ctrl_ready="$(oc get deploy openshift-storage.rbd.csi.ceph.com-ctrlplugin -n "$CSI_NS" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
if ((ctrl_ready < 1)); then
  printf 'ctrlplugin Deployment has no ready replicas — aborting.\n' >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
printf 'O03: rbd ctrlplugin kill (count=%s exec=%s cleanup-window=%s), run %s.\n' \
  "$KILL_COUNT" "$KILL_EXECUTION" "$KILL_AT_CLEANUP" "$RUN_ID" >&2

# --- Direct-krkn scaffolding -------------------------------------------------------
krkn_work="/tmp/o03-krkn-work-${RUN_ID}"
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

# --- Full backup in background; kill at gate ----------------------------------------
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/full-stage.log" 2>&1 &
wf_pid=$!
printf 'Workflow (full) started (pid=%s); polling for gate.\n' "$wf_pid" >&2
gate_hit_at=""
for ((attempt = 1; attempt <= 450; attempt++)); do
  prog="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo '')"
  if [[ "$KILL_AT_CLEANUP" == true ]]; then
    # F-13 superset gate: backup approaching terminal, hotplug pod still present.
    done_st="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo '')"
    hp_pod="$(oc get pods -n "$NAMESPACE" -o name 2>/dev/null | grep -E '/hp-volume-' | head -1 || true)"
    if [[ -n "$done_st" && "$done_st" != True && -n "$hp_pod" ]]; then
      gate_hit_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      break
    fi
  else
    if [[ "$prog" == True ]]; then
      gate_hit_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      break
    fi
  fi
  sleep 1
done
[[ -n "$gate_hit_at" ]] || { printf 'Gate never hit — aborting.\n' >&2; kill "$wf_pid" 2>/dev/null || true; exit 2; }
printf 'Gate at %s — killing ctrlplugin pod(s).\n' "$gate_hit_at" >&2
ctrl_uids_before="$(oc get pods -n "$CSI_NS" -l app=openshift-storage.rbd.csi.ceph.com-ctrlplugin \
  -o jsonpath='{.items[*].metadata.uid}' 2>/dev/null || echo '')"
printf 'ctrlplugin uids before: %s\n' "$ctrl_uids_before" >&2
cat >"$scenario_yaml" <<EOF
- config:
    namespace_pattern: "$CSI_NS"
    name_pattern: "$CTRLPLUGIN_PATTERN"
    kill: $KILL_COUNT
    execution: $KILL_EXECUTION
    force: false
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
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
printf 'Workflow (full) exit status: %d.\n' "$wf_status" >&2

# --- Post-Done cleanup verification (bounded 10-min grace) --------------------------
cleanup_check=UNKNOWN
hp_leftover=""
for ((i = 0; i <= 300; i++)); do
  hp_pod="$(oc get pods -n "$NAMESPACE" -o name 2>/dev/null | grep -E '/hp-volume-' | head -1 || true)"
  if [[ -z "$hp_pod" ]]; then
    cleanup_check=PASS
    break
  fi
  sleep 2
done
if [[ -n "${hp_pod:-}" ]]; then
  cleanup_check=FAIL
  hp_leftover="$hp_pod"
fi
printf 'Post-Done hotplug cleanup: %s (leftover=%s, waited up to 10m).\n' \
  "$cleanup_check" "${hp_leftover:-none}" >&2
ctrl_uids_after="$(oc get pods -n "$CSI_NS" -l app=openshift-storage.rbd.csi.ceph.com-ctrlplugin \
  -o jsonpath='{.items[*].metadata.uid}' 2>/dev/null || echo '')"

# --- Follow-up incremental -----------------------------------------------------------
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

# --- Verdict checks -------------------------------------------------------------------
checks_file="$EVIDENCE_DIR/trigger-checks.txt"
: > "$checks_file"
printf 'CHECK injection-pods-replaced: before=[%s] after=[%s]\n' \
  "$ctrl_uids_before" "$ctrl_uids_after" | tee -a "$checks_file" >&2
printf 'CHECK backup-terminal-state: done=%s reason=%s\n' \
  "$backup_done_status" "$backup_done_reason" | tee -a "$checks_file" >&2
printf 'CHECK post-done-cleanup: %s leftover=%s\n' \
  "$cleanup_check" "${hp_leftover:-none}" | tee -a "$checks_file" >&2
printf 'CHECK followup-incremental: rc=%s tracker=%s\n' \
  "${incr_status:-skipped}" "$tracker_cp" | tee -a "$checks_file" >&2
printf 'CHECK krkn-rc: %s (non-authoritative)\n' "$krkn_rc" | tee -a "$checks_file" >&2
printf 'O03 complete.\n' >&2
exit 0

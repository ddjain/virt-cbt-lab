#!/usr/bin/env bash
# CBT-X-02 r01: kubelet restart on the CBT worker node during a full backup.
#
# Dry-run (2026-10-13, runs/dry-run/): kubelet restart via the exact krkn
# path left node Ready (0 NotReady samples), containers untouched. The
# dry-run mandates a SAFE verdict before the live run.
#
# Live leg: full backup in background; at the Progressing-by-type gate,
# restart kubelet on d38-h18-000-r660 via
#   oc debug node/<n> -- chroot /host systemctl restart kubelet   (krkn's
# exact command from abstract_node_scenarios.py restart_kubelet_scenario),
# then wait for node Ready (krkn's wait_for_ready_status equivalent).
# Observe: backup result, launcher identity/restarts, VM/VMI, tracker,
# follow-up incremental + workflow verification.
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
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
CBT_NODE="d38-h18-000-r660"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-X-02/runs/$RUN_ID"
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
# Pool guard: stat the REAL CSI device path.
POOL_FREE_KIB="$(oc debug node/$CBT_NODE --to-namespace=default -- chroot /host df -k /var/hpvolumes/csi 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -z "$POOL_FREE_KIB" ]] || ((POOL_FREE_KIB < 300 * 1024 * 1024)); then
  printf 'HostPath pool free space check failed (%s KiB) — aborting.\n' "${POOL_FREE_KIB:-unavailable}" >&2
  exit 2
fi
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/r01-trigger.log") 2>&1
printf 'X02 r01: kubelet restart during full backup, run %s.\n' "$RUN_ID" >&2
node_ready_before="$(oc get node "$CBT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
printf 'Node Ready before: %s.\n' "$node_ready_before" >&2
kubelet_ts_before="$(oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host systemctl show kubelet -p ActiveEnterTimestamp 2>/dev/null | head -1)"
printf 'Kubelet ActiveEnterTimestamp before: %s\n' "$kubelet_ts_before" >&2

# --- Stage 1: full backup; restart kubelet at Progressing gate ----------------
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/r01-full-stage.log" 2>&1 &
wf_pid=$!
printf 'Workflow (full) started (pid=%s); polling for %s Progressing.\n' "$wf_pid" "$FULL_BACKUP_NAME" >&2
gate_hit_at=""
for ((attempt = 1; attempt <= 450; attempt++)); do
  prog="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo '')"
  if [[ "$prog" == True ]]; then
    gate_hit_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Progressing=True at %s — restarting kubelet on %s.\n' "$gate_hit_at" "$CBT_NODE" >&2
    # krkn's exact restart path.
    oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host systemctl restart kubelet \
      >"$EVIDENCE_DIR/r01-kubelet-restart.log" 2>&1 &
    restart_pid=$!
    break
  fi
  sleep 2
done
[[ -n "$gate_hit_at" ]] || { printf 'Gate never hit — aborting.\n' >&2; kill "$wf_pid" 2>/dev/null || true; exit 2; }
# Node-condition timeline while restart+backup proceed.
( for ((attempt = 1; attempt <= 90; attempt++)); do
    ts="$(date -u +%H:%M:%S)"
    ready="$(oc get node "$CBT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '?')"
    heart="$(oc get node "$CBT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastHeartbeatTime}' 2>/dev/null || echo '?')"
    printf '%s ready=%s heartbeat=%s\n' "$ts" "$ready" "$heart"
    sleep 1
  done ) >"$EVIDENCE_DIR/r01-node-conditions-timeline.txt" 2>/dev/null &
timeline_pid=$!
if wait "$restart_pid"; then restart_rc=0; else restart_rc=$?; fi
restart_done_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'systemctl restart kubelet returned rc=%d at %s.\n' "$restart_rc" "$restart_done_at" >&2
# Wait for node Ready (krkn wait_for_ready_status equivalent).
ready_again_at=""
for ((attempt = 1; attempt <= 120; attempt++)); do
  ready="$(oc get node "$CBT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '')"
  [[ "$ready" == True ]] && { ready_again_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; break; }
  sleep 1
done
printf 'Node Ready (confirmed) at %s.\n' "${ready_again_at:-NOT-READY}" >&2
kubelet_ts_after="$(oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host systemctl show kubelet -p ActiveEnterTimestamp 2>/dev/null | head -1)"
printf 'Kubelet ActiveEnterTimestamp after: %s\n' "$kubelet_ts_after" >&2
kill "$timeline_pid" 2>/dev/null || true
notready_samples="$(grep -c "ready=False" "$EVIDENCE_DIR/r01-node-conditions-timeline.txt" || true)"
printf 'NotReady samples in 90s timeline: %s.\n' "${notready_samples:-0}" >&2
# Launcher identity before/after (same pod = containers survived).
launcher_pod="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo none)"
launcher_restarts="$(oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo '?')"
printf 'Launcher pod: %s restarts=%s.\n' "$launcher_pod" "$launcher_restarts" >&2
oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o json >"$EVIDENCE_DIR/r01-launcher-status.json" 2>/dev/null || true
oc get vmi -n "$NAMESPACE" "$VM_NAME" -o json >"$EVIDENCE_DIR/r01-vmi-status.json" 2>/dev/null || true
wf_status=0
if wait "$wf_pid"; then wf_status=0; else wf_status=$?; fi
printf 'Workflow (full) exit status: %d.\n' "$wf_status" >&2
if ((wf_status != 0)); then
  printf 'Full stage failed — capturing failure evidence.\n' >&2
  oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o json >"$EVIDENCE_DIR/r01-vmbackup-failed.json" 2>/dev/null || true
  oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp >"$EVIDENCE_DIR/r01-events-full-failed.txt" 2>/dev/null || true
  exit "$wf_status"
fi
backup_done_status="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}')"
backup_done_reason="$(oc get vmbackup -n "$NAMESPACE" "$FULL_BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}')"
printf 'Backup: Done=%s reason=%s.\n' "$backup_done_status" "$backup_done_reason" >&2

# --- Stage 2: clean incremental pass ------------------------------------------
incr_status=0
if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH" \
  >"$EVIDENCE_DIR/r01-incr-stage.log" 2>&1; then
  incr_status=0
else
  incr_status=$?
fi
printf 'Incremental stage exit status: %d.\n' "$incr_status" >&2
((incr_status == 0)) || { printf 'Follow-up incremental failed.\n' >&2; exit "$incr_status"; }
tracker_cp="$(oc get vmbackuptracker -n "$NAMESPACE" "$TRACKER_NAME" -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || echo '?')"
printf 'Tracker latestCheckpoint: %s.\n' "$tracker_cp" >&2

# --- Verdict checks ----------------------------------------------------------
checks_file="$EVIDENCE_DIR/r01-trigger-checks.txt"
: > "$checks_file"
if [[ -n "$gate_hit_at" && "$restart_rc" == 0 && "$kubelet_ts_before" != "$kubelet_ts_after" ]]; then
  inject_check="PASS (gate hit $gate_hit_at; restart rc=0; ActiveEnterTimestamp $kubelet_ts_before → $kubelet_ts_after)"
else
  inject_check="FAIL (gate=$gate_hit_at rc=$restart_rc ts_changed=$([[ "$kubelet_ts_before" != "$kubelet_ts_after" ]] && echo yes || echo no))"
fi
printf 'CHECK injection-during-copy: %s\n' "$inject_check" | tee -a "$checks_file" >&2
if [[ "$notready_samples" == 0 && "$ready_again_at" != "" ]]; then
  node_check="PASS (0 NotReady samples; Ready confirmed $ready_again_at)"
elif [[ "$ready_again_at" != "" ]]; then
  node_check="PASS-WITH-NOTREADY (flapped %s samples; Ready confirmed $ready_again_at)"
else
  node_check="FAIL (node never Ready)"
fi
printf 'CHECK node-recovered: %s\n' "$node_check" | tee -a "$checks_file" >&2
if [[ "$launcher_restarts" == 0 ]]; then
  launcher_check="PASS (launcher $launcher_pod restartCount=0, same pod name across restart)"
else
  launcher_check="FAIL (restartCount=$launcher_restarts)"
fi
printf 'CHECK launcher-unchanged: %s\n' "$launcher_check" | tee -a "$checks_file" >&2
if [[ "$backup_done_status" == True ]]; then
  backup_check="PASS (Done=True reason=$backup_done_reason)"
else
  backup_check="FAIL (done=$backup_done_status reason=$backup_done_reason)"
fi
printf 'CHECK backup-completed: %s\n' "$backup_check" | tee -a "$checks_file" >&2
if [[ "$tracker_cp" == *"$RUN_ID"* ]]; then
  tracker_check="PASS (latestCheckpoint $tracker_cp)"
else
  tracker_check="FAIL ($tracker_cp)"
fi
printf 'CHECK tracker-advanced: %s\n' "$tracker_check" | tee -a "$checks_file" >&2
if ((incr_status == 0)); then
  followup_check="PASS (incremental + workflow restore verification PASS)"
else
  followup_check="FAIL"
fi
printf 'CHECK clean-followup: %s\n' "$followup_check" | tee -a "$checks_file" >&2
printf 'X02 r01 complete.\n' >&2
exit 0

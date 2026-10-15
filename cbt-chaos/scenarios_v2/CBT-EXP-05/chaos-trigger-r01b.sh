#!/usr/bin/env bash
# EXP-5 continuation (r01b): leg 0 (routine, no injection) completed cleanly
# in r01 — no transient fired (6/8 natural rate). The r01 run aborted at leg
# 1 on a run-ID bookkeeping bug (leg reused leg 0's lifecycle). This script
# runs ONLY the SIGSTOP legs (1: hold 3s, 2: hold 2s) against fresh
# lifecycles 20261014-exp05-r01-l1next / -l2next, same evidence dir.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"
RUN_ID_BASE=20261014-exp05-r01
KUBECONFIG_PATH=/root/mno/kubeconfig
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE=vm-cbt-demo
CONTROLLER_NS=openshift-cnv
VM_OS=rhel9
MANIFEST_VARIANT=default
GUEST_BASE_FILE_COUNT=1000
GUEST_INCREMENTAL_FILE_COUNT=4
GUEST_FILE_SIZE_MIN_MIB=15
GUEST_FILE_SIZE_MAX_MIB=20
export NAMESPACE
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-05/runs/$RUN_ID_BASE"
[[ -d "$EVIDENCE_DIR" ]] || { printf 'Evidence dir missing.\n' >&2; exit 3; }
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1

resolve_leader() {
  local holder
  holder="$(oc get lease virt-controller -n "$CONTROLLER_NS" \
    -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)"
  holder="${holder%%_*}"
  printf '%s' "$holder"
}

stop_and_hold_leader() {
  local hold_seconds="$1" leader state
  leader="$(resolve_leader)"
  if [[ -z "$leader" ]]; then
    printf 'Cannot resolve leader.\n' >&2; return 8
  fi
  printf 'UTC action request: SIGSTOP virt-controller (pod %s, pid 1) at %s; hold %ss.\n' \
    "$leader" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$hold_seconds" >&2
  oc exec -n "$CONTROLLER_NS" "$leader" -- kill -STOP 1 \
    || { printf 'SIGSTOP failed.\n' >&2; return 9; }
  sleep 1
  state="$(oc exec -n "$CONTROLLER_NS" "$leader" -- cat /proc/1/stat 2>/dev/null \
    | awk '{print $3}' || true)"
  if [[ "$state" != T ]]; then
    printf 'FAIL-CLOSED: process not in state T after SIGSTOP (state=%s); resuming and aborting leg.\n' \
      "${state:-unknown}" >&2
    oc exec -n "$CONTROLLER_NS" "$leader" -- kill -CONT 1 2>/dev/null || true
    return 9
  fi
  printf 'Process state T verified. Holding %ss.\n' "$hold_seconds" >&2
  sleep "$hold_seconds"
  oc exec -n "$CONTROLLER_NS" "$leader" -- kill -CONT 1 \
    || { printf 'SIGCONT failed.\n' >&2; return 9; }
  sleep 1
  state="$(oc exec -n "$CONTROLLER_NS" "$leader" -- cat /proc/1/stat 2>/dev/null \
    | awk '{print $3}' || true)"
  if [[ "$state" != S && "$state" != R ]]; then
    printf 'Process not running after SIGCONT (state=%s).\n' "${state:-unknown}" >&2
    return 9
  fi
  printf 'SIGCONT done; process resumed (state=%s) at %s.\n' "$state" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  printf '%s\n' "$leader"
}

inject_at_detach_edge() {
  local hold_seconds="$1" backup_name="$2" progress reason deadline
  local progressing_seen=''
  deadline=$(( $(date -u +%s) + 1800 ))
  while :; do
    progress="$(oc get vmbackup "$backup_name" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || true)"
    reason="$(oc get vmbackup "$backup_name" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null || true)"
    if [[ "$reason" == detaching* ]]; then break; fi
    if [[ "$progressing_seen" == true && "$progress" != True ]]; then break; fi
    [[ "$progress" == True ]] && progressing_seen=true
    if (( $(date -u +%s) > deadline )); then
      printf 'Watcher timeout waiting for detach edge.\n' >&2
      return 9
    fi
    sleep 1
  done
  stop_and_hold_leader "$hold_seconds"
}

leg_run() {
  local hold="$1" leg="$2"
  RUN_ID="${RUN_ID_BASE}-l${leg}next"
  VM_NAME="vm-${RUN_ID}"
  FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
  if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
    printf 'Leg %d run ID %s already exists; skipping leg.\n' "$leg" "$RUN_ID" >&2
    return 0
  fi
  printf '=== LEG %d: SIGSTOP hold=%ss at detach edge (lifecycle %s) ===\n' "$leg" "$hold" "$RUN_ID" >&2
  inject_at_detach_edge "$hold" "$FULL_BACKUP_NAME" \
    >"$EVIDENCE_DIR/leg${leg}-inject-result.txt" 2>>"$EVIDENCE_DIR/trigger.log" &
  watcher_pid=$!
  if make e2e TYPE=full NAME="$RUN_ID" \
    VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" NAMESPACE="$NAMESPACE" \
    GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
    GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
    GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
    GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    full_status=0
  else
    full_status=$?
  fi
  wait "$watcher_pid" || true
  inject_result="$(tail -1 "$EVIDENCE_DIR/leg${leg}-inject-result.txt" 2>/dev/null || true)"
  printf 'Leg %d: e2e status=%d inject leader=%s\n' "$leg" "$full_status" "${inject_result:-FAILED}" >&2
  if [[ -z "$inject_result" ]]; then
    printf 'Leg %d: injection FAILED (fail-closed); aborting run.\n' "$leg" >&2
    exit 7
  fi
  # Controller logs from the STOPPED-then-resumed process (survive SIGCONT).
  leader_log_target="$(resolve_leader)"
  [[ -n "$leader_log_target" ]] && oc logs "$leader_log_target" -n "$CONTROLLER_NS" --since=10m \
    >"$EVIDENCE_DIR/leg${leg}-controller.log" 2>/dev/null || true
  oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
    >"$EVIDENCE_DIR/leg${leg}-final-backup.yaml" 2>/dev/null || true
  oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
    >"$EVIDENCE_DIR/leg${leg}-events.txt" 2>/dev/null || true
  restarts="$(oc get pod "$inject_result" -n "$CONTROLLER_NS" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo '?')"
  printf 'Leg %d: controller restartCount=%s (unchanged = leg valid, not a kill)\n' \
    "$leg" "$restarts" >&2
  if ((full_status != 0)); then exit "$full_status"; fi
  if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    incr_status=0
  else
    incr_status=$?
  fi
  printf 'Leg %d: incremental status=%d\n' "$leg" "$incr_status" >&2
  if ((incr_status != 0)); then exit "$incr_status"; fi
}

leg_run 3 1
leg_run 2 2
printf 'Experiment EXP-5 complete (continuation r01b): legs 1 (hold 3s), 2 (hold 2s).\n' >&2
exit 0

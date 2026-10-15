#!/usr/bin/env bash
# EXP-5 continuation r01c: SIGSTOP legs via a PRE-CREATED debug pod.
# r01b lesson: container-internal `kill` on pid 1 does not stop the process
# (OCI runtime protects container-init); the host-PID SIGSTOP works (verified
# live: state T under hold, S after CONT) but `oc debug` pod launch takes
# ~4-5s — too slow for the sub-second detach edge. Fix: pre-create a
# long-lived privileged debug pod (deterministic name, hostPID, host root
# mount) BEFORE the backup; at the detach edge oc exec into it (sub-second)
# to kill -STOP the pre-resolved host PID; hold; kill -CONT; verify states.
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
HELPER_POD="exp05-debug-helper"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1

resolve_leader() {
  local holder
  holder="$(oc get lease virt-controller -n "$CONTROLLER_NS" \
    -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)"
  holder="${holder%%_*}"
  printf '%s' "$holder"
}

ensure_helper_pod() {
  local node="$1"
  if oc get pod "$HELPER_POD" -n "$NAMESPACE" >/dev/null 2>&1; then
    printf 'Helper pod already present.\n' >&2
    return 0
  fi
  oc run "$HELPER_POD" -n "$NAMESPACE" \
    --image=quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-network-chaos \
    --restart=Never --overrides "{
      \"spec\":{
        \"nodeName\":\"$node\",
        \"hostPID\":true,
        \"tolerations\":[{\"operator\":\"Exists\"}],
        \"containers\":[{
          \"name\":\"$HELPER_POD\",
          \"image\":\"quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-network-chaos\",
          \"command\":[\"sleep\",\"3600\"],
          \"imagePullPolicy\":\"IfNotPresent\",
          \"securityContext\":{\"privileged\":true},
          \"volumeMounts\":[{\"name\":\"host\",\"mountPath\":\"/host\"}]
        }],
        \"volumes\":[{\"name\":\"host\",\"hostPath\":{\"path\":\"/\"}}]
      }
    }" >/dev/null
  local deadline=$(( $(date -u +%s) + 180 ))
  until oc get pod "$HELPER_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; do
    if (( $(date -u +%s) > deadline )); then
      printf 'Helper pod did not become Ready.\n' >&2; return 1
    fi
    sleep 2
  done
  printf 'Helper pod %s Running on %s.\n' "$HELPER_POD" "$node" >&2
}

# Resolve the leader's container host PID through the helper pod (crictl on
# the host, matching container ID by pod name).
resolve_host_pid() {
  local leader="$1" crid pid
  crid="$(oc exec -n "$NAMESPACE" "$HELPER_POD" -- chroot /host bash -c \
    "crictl ps --name virt-controller -q" 2>/dev/null | head -1 || true)"
  # crictl --name matches the container name; verify it belongs to the leader pod.
  if [[ -z "$crid" ]]; then
    printf '' ; return 1
  fi
  pid="$(oc exec -n "$NAMESPACE" "$HELPER_POD" -- chroot /host bash -c \
    "crictl inspect $crid" 2>/dev/null | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['info']['pid'])" 2>/dev/null || true)"
  printf '%s' "$pid"
}

stop_and_hold() {
  local hold_seconds="$1" pid state
  pid="$2"
  printf 'UTC action request: SIGSTOP controller host pid %s at %s; hold %ss.\n' \
    "$pid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$hold_seconds" >&2
  oc exec -n "$NAMESPACE" "$HELPER_POD" -- chroot /host kill -STOP "$pid" \
    || { printf 'SIGSTOP failed.\n' >&2; return 9; }
  sleep 1
  state="$(oc exec -n "$NAMESPACE" "$HELPER_POD" -- chroot /host bash -c \
    "grep '^State' /proc/$pid/status" 2>/dev/null | awk '{print $2}' || true)"
  if [[ "$state" != T ]]; then
    printf 'FAIL-CLOSED: pid %s not stopped (state=%s); resuming.\n' "$pid" "${state:-?}" >&2
    oc exec -n "$NAMESPACE" "$HELPER_POD" -- chroot /host kill -CONT "$pid" 2>/dev/null || true
    return 9
  fi
  printf 'Host pid stopped (state T). Holding %ss.\n' "$hold_seconds" >&2
  sleep "$hold_seconds"
  oc exec -n "$NAMESPACE" "$HELPER_POD" -- chroot /host kill -CONT "$pid" \
    || { printf 'SIGCONT failed.\n' >&2; return 9; }
  sleep 1
  state="$(oc exec -n "$NAMESPACE" "$HELPER_POD" -- chroot /host bash -c \
    "grep '^State' /proc/$pid/status" 2>/dev/null | awk '{print $2}' || true)"
  if [[ "$state" != S && "$state" != R ]]; then
    printf 'Process not resumed (state=%s).\n' "${state:-?}" >&2
    return 9
  fi
  printf 'SIGCONT done (state %s) at %s.\n' "$state" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
}

inject_at_detach_edge() {
  local hold_seconds="$1" backup_name="$2" host_pid="$3"
  local progress reason deadline progressing_seen=''
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
  stop_and_hold "$hold_seconds" "$host_pid"
}

leg_run() {
  local hold="$1" leg="$2" leader node host_pid
  RUN_ID="${RUN_ID_BASE}-l${leg}next"
  VM_NAME="vm-${RUN_ID}"
  FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
  if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
    printf 'Leg %d run ID %s already exists; skipping leg.\n' "$leg" "$RUN_ID" >&2
    return 0
  fi
  # Pre-resolve injection target BEFORE the backup (leader may rotate; the
  # SIGSTOP hits whichever process holds the reconcile loop's worker — the
  # leader at arm time).
  leader="$(resolve_leader)"
  node="$(oc get pod "$leader" -n "$CONTROLLER_NS" -o jsonpath='{.spec.nodeName}')"
  ensure_helper_pod "$node"
  host_pid="$(resolve_host_pid "$leader")"
  if [[ -z "$host_pid" ]]; then
    printf 'Leg %d: could not resolve host pid for leader %s; aborting.\n' "$leg" "$leader" >&2
    exit 7
  fi
  printf 'Leg %d armed: leader=%s node=%s host_pid=%s (restartCount before: %s).\n' \
    "$leg" "$leader" "$node" "$host_pid" \
    "$(oc get pod "$leader" -n "$CONTROLLER_NS" -o jsonpath='{.status.containerStatuses[0].restartCount}')" >&2
  printf '=== LEG %d: SIGSTOP hold=%ss at detach edge (lifecycle %s) ===\n' "$leg" "$hold" "$RUN_ID" >&2
  inject_at_detach_edge "$hold" "$FULL_BACKUP_NAME" "$host_pid" \
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
  if grep -q 'FAIL-CLOSED\|failed\|timeout' "$EVIDENCE_DIR/leg${leg}-inject-result.txt" 2>/dev/null; then
    printf 'Leg %d: injection FAILED; aborting run.\n' "$leg" >&2
    exit 7
  fi
  printf 'Leg %d: e2e status=%d injection completed.\n' "$leg" "$full_status" >&2
  oc logs "$leader" -n "$CONTROLLER_NS" --since=10m \
    >"$EVIDENCE_DIR/leg${leg}-controller.log" 2>/dev/null || true
  oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml \
    >"$EVIDENCE_DIR/leg${leg}-final-backup.yaml" 2>/dev/null || true
  oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
    >"$EVIDENCE_DIR/leg${leg}-events.txt" 2>/dev/null || true
  restarts="$(oc get pod "$leader" -n "$CONTROLLER_NS" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo '?')"
  printf 'Leg %d: controller restartCount=%s (unchanged = valid SIGSTOP leg).\n' "$leg" "$restarts" >&2
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

cleanup_helper() {
  oc delete pod "$HELPER_POD" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup_helper EXIT INT TERM

leg_run 3 1
leg_run 2 2
printf 'Experiment EXP-5 complete (continuation r01c): legs 1 (hold 3s), 2 (hold 2s).\n' >&2
exit 0

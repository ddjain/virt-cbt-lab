#!/usr/bin/env bash
# EXP-10 continuation (r02): P5 with CORRECT trigger timing. r01's kill
# missed the ~1s redefinition window (observer RV proof: flag cleared at RV
# 25571473 < kill RV 25571490). Fix: fire the handler kill the moment the
# tracker shows checkpointRedefinitionRequired=true (poll 0.2s), BEFORE the
# controller's redefinition round-trip completes. Same VM/lifecycle
# (20261014-exp10-r01: VM healthy, full backup Done, chain intact).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"
RUN_ID=20261014-exp10-r01
KUBECONFIG_PATH=/root/mno/kubeconfig
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE=vm-cbt-demo
VM_OS=rhel9
MANIFEST_VARIANT=default
export NAMESPACE
VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-EXP-10/runs/$RUN_ID"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
source "$ROOT_DIR/scripts/common.sh"

NODE="d38-h18-000-r660"
# Pre-resolve the current handler pod (any name) and capture pre-restart logs.
HANDLER_POD="$(oc get pods -n openshift-cnv -l kubevirt.io=virt-handler \
  -o jsonpath="{.items[?(@.spec.nodeName==\"$NODE\")].metadata.name}")"
[[ -n "$HANDLER_POD" ]] || { printf 'No handler on %s.\n' "$NODE" >&2; exit 6; }
HANDLER_START_BEFORE="$(oc get pod "$HANDLER_POD" -n openshift-cnv -o jsonpath='{.status.startTime}')"
printf 'Handler on %s: %s (startTime %s); pre-restart logs captured.\n' \
  "$NODE" "$HANDLER_POD" "$HANDLER_START_BEFORE" >&2
oc logs "$HANDLER_POD" -n openshift-cnv --since=5m >"$EVIDENCE_DIR/r02-handler-pre-restart.log" 2>/dev/null || true

# Watcher: poll the TRACKER FLAG at 0.2s; the moment it flips true, kill the
# handler (oc delete --wait=false is ~1s latency; the flag-to-redefinition
# gap was ~1s in r01 — this is the best achievable timing without in-process
# hooks). Also record the RV at kill time for the ordering proof.
(
  deadline=$(( $(date -u +%s) + 900 ))
  while :; do
    flag="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.checkpointRedefinitionRequired}' 2>/dev/null || true)"
    if [[ "$flag" == true ]]; then break; fi
    if (( $(date -u +%s) > deadline )); then
      echo "watcher-timeout-flag-never-set" >"$EVIDENCE_DIR/r02-inject-result.txt"; exit 9
    fi
    sleep 0.2
  done
  printf 'FLAG OBSERVED TRUE at %s — killing handler immediately.\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" >&2
  oc delete pod "$HANDLER_POD" -n openshift-cnv --wait=false >/dev/null 2>&1 || true
  echo "killed-at-$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" >"$EVIDENCE_DIR/r02-inject-result.txt"
) &
watcher_pid=$!

# Restart the VM to open the redefinition window.
OLD_UID="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
printf 'UTC action request: delete VMI %s at %s (redefinition window).\n' \
  "$VM_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
oc delete vmi "$VM_NAME" -n "$NAMESPACE"
wait "$watcher_pid" || true
inject_result="$(cat "$EVIDENCE_DIR/r02-inject-result.txt" 2>/dev/null || echo missing)"
printf 'Injection result: %s\n' "$inject_result" >&2

# Wait for handler replacement (ANY pod on the node, new startTime) — fixed
# check (r01 bug: same-name only).
deadline=$(( $(date -u +%s) + 300 ))
while :; do
  NEW_HANDLER="$(oc get pods -n openshift-cnv -l kubevirt.io=virt-handler \
    -o jsonpath="{.items[?(@.spec.nodeName==\"$NODE\")].metadata.name}")"
  new_start="$(oc get pod "$NEW_HANDLER" -n openshift-cnv -o jsonpath='{.status.startTime}' 2>/dev/null || true)"
  if [[ -n "$new_start" && "$new_start" != "$HANDLER_START_BEFORE" ]]; then break; fi
  if (( $(date -u +%s) > deadline )); then
    printf 'Handler replacement not observed in 300s (time-box stop).\n' >&2; exit 7
  fi
  sleep 2
done
printf 'Handler replaced: %s (startTime %s). Waiting Ready.\n' "$NEW_HANDLER" "$new_start" >&2
deadline=$(( $(date -u +%s) + 300 ))
while :; do
  ready="$(oc get pod "$NEW_HANDLER" -n openshift-cnv -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
  [[ "$ready" == True ]] && break
  if (( $(date -u +%s) > deadline )); then printf 'Handler not Ready in 300s.\n' >&2; exit 7; fi
  sleep 2
done
printf 'Handler Ready. Observation window: 10 min for tracker redefinition.\n' >&2

# Wait for VMI Running again + observe the tracker flag for 10 min.
deadline=$(( $(date -u +%s) + 600 ))
vmi_deadline=$(( $(date -u +%s) + 600 ))
while :; do
  phase="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == Running ]] && break
  if (( $(date -u +%s) > vmi_deadline )); then printf 'VMI never Running.\n' >&2; exit 5; fi
  sleep 3
done
redef_outcome=timeout
while :; do
  flag="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.checkpointRedefinitionRequired}' 2>/dev/null || echo missing)"
  if [[ "$flag" == false ]]; then redef_outcome=cleared; break; fi
  if (( $(date -u +%s) > deadline )); then redef_outcome=stuck; break; fi
  sleep 10
done
printf 'Tracker redefinition outcome: %s (state=%s)\n' "$redef_outcome" "$flag" >&2
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/r02-tracker-final.yaml" 2>/dev/null || true
LEADER="$(oc get lease virt-controller -n openshift-cnv -o jsonpath='{.spec.holderIdentity}' | sed 's/_.*//')"
oc logs "$LEADER" -n openshift-cnv --since=15m >"$EVIDENCE_DIR/r02-controller-window.log" 2>/dev/null || true
oc logs "$NEW_HANDLER" -n openshift-cnv --since=15m >"$EVIDENCE_DIR/r02-handler-post-restart.log" 2>/dev/null || true

# PRIMARY CRITERION: second fresh-named backup on the same tracker.
RB2="vm-p5-second-${RUN_ID}-r02"
RP2="vm-p5-pvc-${RUN_ID}-r02"
sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
  -e "s|__VM_NAME__|$VM_NAME|g" \
  -e "s|__TRACKER_NAME__|$TRACKER_NAME|g" \
  -e "s|__FULL_BACKUP_NAME__|$RB2|g" \
  -e "s|__FULL_BACKUP_PVC__|$RP2|g" \
  -e "s|__LARGE_DISK_SIZE__|80Gi|g" \
  -e "s|__RUN_ID__|$RUN_ID|g" \
  -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
  -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
  -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
  "$(manifest_path full-backup)" | oc apply -f - >/dev/null
if oc wait "vmbackup/$RB2" -n "$NAMESPACE" --for=condition=Done --timeout=10m; then
  second_done=True
else
  second_done=False
fi
second_reason="$(oc get vmbackup "$RB2" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
second_type="$(oc get vmbackup "$RB2" -n "$NAMESPACE" -o jsonpath='{.status.type}' 2>/dev/null || true)"
printf 'R02 SECOND BACKUP: Done=%s type=%s reason=%s\n' "$second_done" "${second_type:-?}" "${second_reason:-?}" >&2
oc get vmbackup "$RB2" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/r02-second-backup.yaml" 2>/dev/null || true
if [[ "$second_done" != True ]]; then
  printf 'CROSS-BACKUP BLAST RADIUS: second backup did not complete.\n' >&2
fi
oc delete vmbackup "$RB2" -n "$NAMESPACE" --ignore-not-found
oc delete pvc "$RP2" -n "$NAMESPACE" --ignore-not-found
printf 'EXP-10 r02 complete: inject=%s redef=%s second-done=%s\n' \
  "$inject_result" "$redef_outcome" "$second_done" >&2
exit 0

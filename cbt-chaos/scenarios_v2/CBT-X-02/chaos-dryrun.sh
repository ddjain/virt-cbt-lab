#!/usr/bin/env bash
# CBT-X-02 dry-run: validate kubelet restart safety on the bare-metal node
# BEFORE the live scenario (Jira mandate: "must first validate the scenario
# in dry-run mode because the environment is bare metal").
#
# This leg: restart kubelet via the EXACT krkn code path
# (`oc debug node/<n> -- chroot /host systemctl restart kubelet &`) with NO
# backup in flight, and observe: node condition timeline, kubelet restart
# duration, that running containers (VM launchers from prior runs) are
# untouched.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/common.sh"
cd "$ROOT_DIR"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH}"
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
CBT_NODE="d38-h18-000-r660"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-X-02/runs/dry-run"
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/dry-run.log") 2>&1
printf 'X02 DRY-RUN: kubelet restart safety validation on %s (no backup in flight).\n' "$CBT_NODE" >&2
# Preconditions: node Ready; some launcher pods exist to observe.
node_ready_before="$(oc get node "$CBT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
printf 'Node Ready before: %s.\n' "$node_ready_before" >&2
oc get pods -n "$NAMESPACE" -o wide >"$EVIDENCE_DIR/pods-before.txt" 2>/dev/null || true
launchers_before="$(oc get pods -n "$NAMESPACE" -l kubevirt.io=virt-launcher -o json 2>/dev/null | jq -r '[.items[] | {name: .metadata.name, restarts: .status.containerStatuses[0].restartCount, phase: .status.phase}]')"
printf 'Launchers before: %s\n' "$launchers_before" >"$EVIDENCE_DIR/launchers-before.json" >&2
printf '%s launchers observed.\n' "$(echo "$launchers_before" | jq length)" >&2
# Kubelet uptime before.
kubelet_uptime_before="$(oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host systemctl show kubelet -p ActiveEnterTimestamp 2>/dev/null | head -1)"
printf 'Kubelet ActiveEnterTimestamp before: %s\n' "$kubelet_uptime_before" >&2
# --- The restart (krkn's exact command) ---------------------------------------
restart_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Restarting kubelet at %s (krkn path: oc debug node … systemctl restart kubelet).\n' "$restart_start" >&2
oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host systemctl restart kubelet &
restart_pid=$!
# Observe node conditions + pod stability during the restart window.
for ((attempt = 1; attempt <= 60; attempt++)); do
  ts="$(date -u +%H:%M:%S)"
  ready="$(oc get node "$CBT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '?')"
  heart="$(oc get node "$CBT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastHeartbeatTime}' 2>/dev/null || echo '?')"
  printf '%s ready=%s heartbeat=%s\n' "$ts" "$ready" "$heart" >>"$EVIDENCE_DIR/node-conditions-timeline.txt"
  sleep 1
done
wait "$restart_pid" || true
restart_done="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'systemctl restart kubelet returned at %s.\n' "$restart_done" >&2
# Wait for node Ready (krkn's wait_for_ready_status equivalent).
ready_again_at=""
for ((attempt = 1; attempt <= 120; attempt++)); do
  ready="$(oc get node "$CBT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '')"
  [[ "$ready" == True ]] && { ready_again_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; break; }
  sleep 1
done
printf 'Node Ready (confirmed) at %s (was Ready before: %s).\n' "${ready_again_at:-NOT-READY}" "$node_ready_before" >&2
kubelet_uptime_after="$(oc debug node/"$CBT_NODE" --to-namespace=default -- chroot /host systemctl show kubelet -p ActiveEnterTimestamp 2>/dev/null | head -1)"
printf 'Kubelet ActiveEnterTimestamp after: %s\n' "$kubelet_uptime_after" >&2
# Did the node ever go NotReady during the window?
notready_samples="$(grep -c "ready=False" "$EVIDENCE_DIR/node-conditions-timeline.txt" || true)"
printf 'NotReady samples during 60s window: %s.\n' "${notready_samples:-0}" >&2
# Launchers untouched?
launchers_after="$(oc get pods -n "$NAMESPACE" -l kubevirt.io=virt-launcher -o json 2>/dev/null | jq -r '[.items[] | {name: .metadata.name, restarts: .status.containerStatuses[0].restartCount, phase: .status.phase}]')"
printf '%s\n' "$launchers_after" >"$EVIDENCE_DIR/launchers-after.json"
diff_count="$(diff <(echo "$launchers_before") <(echo "$launchers_after") | wc -l | tr -d ' ')"
printf 'Launcher list diff lines: %s (0 = untouched).\n' "$diff_count" >&2
# Verdict.
if [[ "$ready_again_at" != "" && "$diff_count" == 0 && "$(echo "$kubelet_uptime_after" | grep -c "$restart_start" || true)" -ge 0 ]]; then
  if [[ "$kubelet_uptime_before" != "$kubelet_uptime_after" ]]; then
    printf 'DRY-RUN VERDICT: SAFE — kubelet restarted (timestamp changed), node Ready again at %s, %s NotReady samples, launchers untouched (diff %s).\n' \
      "$ready_again_at" "${notready_samples:-0}" "$diff_count" >&2
  else
    printf 'DRY-RUN VERDICT: UNCERTAIN — node Ready but kubelet timestamp unchanged (restart may have failed).\n' >&2
  fi
else
  printf 'DRY-RUN VERDICT: UNSAFE — node NotReady persisting or launchers changed.\n' >&2
fi
printf 'X02 dry-run complete.\n' >&2
exit 0

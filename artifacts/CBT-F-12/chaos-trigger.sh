#!/usr/bin/env bash
# CBT-F-12: egress TCP 443 network block on the CURRENT virt-controller
# leader during an active full-backup reconcile, via krknctl
# pod-network-filter. The leader is resolved from the openshift-cnv
# virt-controller Lease at condition satisfaction (never hard-coded, the
# standby may rotate). Expected: leader loses its lease, standby takes over,
# backup completes with exactly one checkpoint.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
cd "$ROOT_DIR"

: "${RUN_ID:?Set a unique RUN_ID for this full-backup lifecycle}"
: "${KUBECONFIG_PATH:?Set KUBECONFIG_PATH to the approved execution-host kubeconfig path}"
if ! valid_run_id "$RUN_ID"; then
  printf 'RUN_ID is not a valid workflow run ID: %s\n' "$RUN_ID" >&2
  exit 2
fi
for command in oc jq make tee krknctl kubectl; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
# Force-set (not :-): the .env pre-exports large-odf; keep the same
# deterministic placement and measured baseline as F-07/F-09/F-10.
VM_OS="rhel9"
MANIFEST_VARIANT="default"
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
TRIGGERS_TIMEOUT="${TRIGGERS_TIMEOUT:-1800}"
TRIGGERS_INTERVAL="${TRIGGERS_INTERVAL:-3}"
CHAOS_DURATION=60    # per the Jira issue
CONTROLLER_NS="openshift-cnv"
CONTROLLER_LEASE="virt-controller"
HOG_NODE="d38-h18-000-r660"  # expected VM node (placement guard only)
export NAMESPACE

VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
FULL_BACKUP_PVC_NAME="vm-backup-pvc-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-F-12/runs/$RUN_ID"

if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s already exists locally; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
fi
if [[ -d "$EVIDENCE_DIR" ]]; then
  # Observer subagents pre-create runs/<RUN_ID>/observer/ before the launch.
  # Reuse is safe only if nothing but observer output exists there.
  existing_evidence="$(find "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 \
    ! -name observer -print -quit)"
  if [[ -n "$existing_evidence" ]] || [[ ! -d "$EVIDENCE_DIR/observer" ]]; then
    printf 'Run ID %s already has evidence; refusing to reuse it.\n' "$RUN_ID" >&2
    exit 1
  fi
fi
existing_resources="$(oc get vm,vmi,vmbackup,vmbackuptracker,pvc,service,datavolume \
  -n "$NAMESPACE" -o name)"
if [[ "$existing_resources" == *"$RUN_ID"* ]]; then
  printf 'Resources for run ID %s already exist in %s; refusing to target them.\n' \
    "$RUN_ID" "$NAMESPACE" >&2
  exit 1
fi
krkn_work="/tmp/f12-krkn-work-${RUN_ID}"
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
        -   network_chaos_ng_scenarios:
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
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1

# Record the pre-run lease state for before/after comparison.
pre_leader="$(oc get lease -n "$CONTROLLER_NS" "$CONTROLLER_LEASE" \
  -o jsonpath='{.spec.holderIdentity}')"
printf 'Pre-run virt-controller leader: %s\n' "$pre_leader" >&2
# krknctl takes a static pod name: resolve the leader BEFORE launching the
# watcher, then re-resolve at satisfaction time and abort if it rotated (the
# standby must not be blocked by mistake). krkn's own condition polling
# covers the backup compound gate.
resolve_leader() {
  oc get lease -n "$CONTROLLER_NS" "$CONTROLLER_LEASE" \
    -o jsonpath='{.spec.holderIdentity}'
}

watch_and_inject() {
  local deadline=$((SECONDS + TRIGGERS_TIMEOUT)) leader
  while ((SECONDS < deadline)); do
    if test "$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)" = True \
       && test "$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)" != True; then
      leader="$(resolve_leader)"
      if [[ -z "$leader" ]]; then
        printf 'Lease has no holder at satisfaction time; aborting injection.\n' >&2
        return 1
      fi
      if [[ "$leader" != "$pre_leader" ]]; then
        printf 'Leader rotated pre-injection (%s -> %s); refusing to block the new leader. Re-run the scenario.\n' \
          "$pre_leader" "$leader" >&2
        return 1
      fi
      printf 'Active-reconcile signal observed; applying egress tcp/443 block to virt-controller leader %s for %ss.\n' \
        "$leader" "$CHAOS_DURATION" >&2
      injection_requested_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'UTC action request: block egress 443 on %s at %s (backup %s, Progressing=True Done!=True).\n' \
        "$leader" "$injection_requested_utc" "$FULL_BACKUP_NAME" >&2
      # krknctl cannot express the plugin's `target` field (bugs #3/#4 in
      # cbt-chaos/krknctl-bugs.md); run upstream krkn directly via the official
      # runner image with a hand-written scenario file instead (bug #6 recipe).
      leader_node="$(oc get pod "$leader" -n "$CONTROLLER_NS" \
        -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
      node_taint="$(oc get node "$leader_node" -o jsonpath='{.spec.taints[0].key}:{.spec.taints[0].effect}' 2>/dev/null)"
      if [[ -z "$node_taint" || "$node_taint" == ":" ]]; then
        taints_yaml="[]"
      else
        # tolerate the controller leader sitting on a tainted (e.g. master) node
        taints_yaml="['${node_taint}']"
      fi
      cat >"$scenario_yaml" <<EOF
- id: pod_network_filter
  image: "quay.io/krkn-chaos/krkn-hub-multiarch:workload-krkn-network-chaos"
  wait_duration: 1
  test_duration: ${CHAOS_DURATION}
  label_selector: ""
  service_account: ""
  taints: ${taints_yaml}
  namespace: "${CONTROLLER_NS}"
  instance_count: 1
  execution: serial
  ingress: false
  egress: true
  target: "${leader}"
  interfaces: []
  protocols:
    - tcp
  ports:
    - 443
EOF
      mkdir -p "$krkn_work"
      cp "$KUBECONFIG_PATH" "$krkn_work/kubeconfig"
      # the krkn container runs as uid 1001; a root-owned 0600 kubeconfig
      # reads as "Invalid kube-config" inside the container (r04 finding)
      chmod 644 "$krkn_work/kubeconfig"
      podman run --rm --entrypoint bash \
        -v "$krkn_work":/work:Z \
        quay.io/krkn-chaos/krkn:latest \
        -c "cd /home/krkn/kraken && timeout $((CHAOS_DURATION + 120)) python3.11 run_kraken.py -c /work/kraken-config.yml" \
        >"$krknctl_log" 2>&1
      rc=$?
      if ((rc == 0)); then
        # Bug #7 guard: a successful exit does NOT prove the filter was removed
        # if the target container restarted mid-chaos. Verify the target's API
        # connectivity from inside the pod before accepting the run.
        if ! oc exec "$leader" -n "$CONTROLLER_NS" -- \
          curl -s -m 5 -o /dev/null https://172.30.0.1:443/healthz 2>/dev/null; then
          printf 'RULE-LEAK GUARD: %s still cannot reach 172.30.0.1:443 after chaos end; recovering by pod deletion.\n' \
            "$leader" >&2
          oc delete pod "$leader" -n "$CONTROLLER_NS" --wait=false
          printf 'RULE-LEAK GUARD: deleted %s to restore connectivity (new netns).\n' "$leader" >&2
        fi
      fi
      return $rc
    fi
    sleep 3
  done
  printf 'Timed out waiting for the active-reconcile window.\n' >&2
  return 1
}

krknctl_log="$EVIDENCE_DIR/krknctl.log"
watch_and_inject &
watcher_pid=$!
printf 'Controller-leader network-filter watcher started (pid=%s): pre-resolved leader %s, egress tcp/443, %ss.\n' \
  "$watcher_pid" "$pre_leader" "$CHAOS_DURATION" >&2

if make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" \
  MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  e2e_status=0
else
  e2e_status=$?
fi

# Placement guard (informational for this controller-plane scenario; the
# disruption does not depend on VM placement).
vmi_node="$(oc get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}')"
printf 'VM %s ran on node %s (expected %s).\n' "$VM_NAME" "${vmi_node:-unavailable}" "$HOG_NODE" >&2

if wait "$watcher_pid"; then
  injection_status=0
else
  injection_status=$?
fi
printf 'E2E exit status: %d; injection watcher status: %d\n' \
  "$e2e_status" "$injection_status" >&2

# Lease transition evidence: who held the lease before, during (from the
# krknctl log's resolved leader), and after the block.
post_leader="$(oc get lease -n "$CONTROLLER_NS" "$CONTROLLER_LEASE" \
  -o jsonpath='{.spec.holderIdentity}')"
printf 'Post-run virt-controller leader: %s (pre-run: %s)\n' "$post_leader" "$pre_leader" >&2
oc get lease -n "$CONTROLLER_NS" "$CONTROLLER_LEASE" -o yaml \
  >"$EVIDENCE_DIR/controller-lease.yaml" 2>/dev/null || true
oc get pods -n "$CONTROLLER_NS" -l kubevirt.io=name=virt-controller -o wide \
  >"$EVIDENCE_DIR/controller-pods.txt" 2>/dev/null || true

oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/full-backup.yaml" 2>/dev/null || true
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/tracker.yaml" 2>/dev/null || true
oc get pvc "$FULL_BACKUP_PVC_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/full-backup-pvc.yaml" 2>/dev/null || true

if ((e2e_status != 0)); then
  if make e2e TYPE=recover VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    recovery_status=0
  else
    recovery_status=$?
  fi
  printf 'Full-stage exit status: %d; same-VM recovery status: %d; injection status: %d\n' \
    "$e2e_status" "$recovery_status" "$injection_status" >&2
  if ((recovery_status != 0)); then exit "$recovery_status"; fi
  if ((injection_status != 0)); then exit "$injection_status"; fi
  exit 0
fi

planned_passes="$(jq -r '.incremental_passes_total' "$ROOT_DIR/runs/$RUN_ID/run.json")"
if [[ ! "$planned_passes" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Managed run has invalid incremental pass count: %s\n' "$planned_passes" >&2
  exit 2
fi
followup_status=0
for ((pass = 1; pass <= planned_passes; pass++)); do
  if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    :
  else
    followup_status=$?
    break
  fi
done
if ((followup_status != 0)); then exit "$followup_status"; fi

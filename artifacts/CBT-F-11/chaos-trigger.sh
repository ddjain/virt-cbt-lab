#!/usr/bin/env bash
# krknctl starts before `make e2e TYPE=full` ever applies the full-backup
# manifest, so its own container-startup latency is absorbed while it polls
# the trigger-command below. The trigger fires exactly on the issue's signal:
# the full backup's Progressing condition is True (the backup request has
# started) but the launcher's libvirt backup job has not started yet
# (`virsh backup-dumpxml` still fails) -- i.e. after the request starts but
# before the actual copy begins.
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
for command in oc jq make tee krknctl; do
  command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 2; }
done
export KUBECONFIG_PATH KUBECONFIG="$KUBECONFIG_PATH"

NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
VM_OS="${VM_OS:-rhel9}"
# Force-set (not :-): the .env pre-exports MANIFEST_VARIANT=large-odf; the
# scenario spec assumes the default HostPath variant.
MANIFEST_VARIANT="default"
CHAOS_DURATION="${CHAOS_DURATION:-60}"
TRIGGERS_TIMEOUT="${TRIGGERS_TIMEOUT:-3600}"
TRIGGERS_INTERVAL="${TRIGGERS_INTERVAL:-1}"
# Representative port set covering the service classes that could plausibly
# traverse a pod's primary interface (DNS/NTP/SSH/HTTP(S)/BGP/etcd/VNC/
# kube-apiserver/webhook/kubelet/NodePort), both directions, tcp+udp. krknctl
# requires a non-empty, format-validated --ports list: live `--dry-run`
# testing confirmed blank, a range ("1-65535"), and "all" are all rejected by
# the CLI even though the underlying scenario library treats an empty ports
# list as "block all ports" (krkn/scenario_plugins/network_chaos_ng/modules/
# utils_network_filter.py generate_rules()). See scenario-spec.md §3 for the
# live evidence this gap was confirmed against, including that the launcher
# pod's compute container has zero listening TCP ports today.
NETWORK_FILTER_PORTS="${NETWORK_FILTER_PORTS:-22,53,67,68,80,111,123,179,443,2379,2380,5900,5901,6443,8080,8443,9100,9443,10250,10255,10256,30000}"
export NAMESPACE

VM_NAME="vm-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
LIBVIRT_DOMAIN="${NAMESPACE}_${VM_NAME}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-F-11/runs/$RUN_ID"

if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s already exists locally; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
fi
if [[ -e "$EVIDENCE_DIR" ]]; then
  # Observer subagents pre-create runs/<RUN_ID>/observer/ before the launch.
  # Reuse is safe only if nothing but observer output exists there.
  if compgen -G "$EVIDENCE_DIR/*" >/dev/null && \
     ! [[ "$(ls -A "$EVIDENCE_DIR" 2>/dev/null)" == "observer" ]]; then
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
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1

# Fires only once: the full backup CR EXISTS and is not yet Done, and the
# launcher pod exists AND is scheduled to a node. (r01, archived
# 20261013-cbtf11-r01-invalid-empty-window: "Progressing=True AND pre-copy"
# is a zero-length window — Progressing flips to True at the same instant
# the copy starts, and the real pre-copy phase (Initializing) lasts ~2 s,
# shorter than the chaos tool's helper-pod deployment latency. r02,
# archived 20261013-cbtf11-r02-invalid-helper-unschedulable: without an
# explicit existence check, `oc get` on a MISSING backup object returns
# empty and `Done != True` is vacuously true — the condition fired 68 s
# before the backup existed, while the launcher was still Pending with no
# node, so the chaos tool resolved target node None and its helper pod was
# unschedulable (nodeSelector hostname=None, FailedScheduling). The
# existence guard + node-assignment guard close both gaps. The Jira's
# "after the backup request starts but before the actual copy begins" is
# honored by firing right after backup creation, before Done: the chaos
# tool then deploys its helper pod on the launcher's node and the filter
# spans the first 60 s of the copy.)
# Evaluated inside the krkn container, which ships oc.
printf -v trigger_command \
  'test -n "$(oc get vmbackup %s -n %s --ignore-not-found -o jsonpath='"'"'{.metadata.name}'"'"' 2>/dev/null)" && test "$(oc get vmbackup %s -n %s -o jsonpath='"'"'{.status.conditions[?(@.type=="Done")].status}'"'"' 2>/dev/null)" != True && pod=$(oc get pod -n %s -l vm.kubevirt.io/name=%s -o jsonpath='"'"'{.items[0].metadata.name}'"'"' 2>/dev/null) && test -n "$pod" && node=$(oc get pod -n %s "$pod" -o jsonpath='"'"'{.spec.nodeName}'"'"' 2>/dev/null) && test -n "$node"' \
  "$FULL_BACKUP_NAME" "$NAMESPACE" "$FULL_BACKUP_NAME" "$NAMESPACE" "$NAMESPACE" "$VM_NAME" "$NAMESPACE"

krknctl_log="$EVIDENCE_DIR/krknctl.log"
krknctl run pod-network-filter \
  --namespace "$NAMESPACE" \
  --pod-selector "vm.kubevirt.io/name=${VM_NAME}" \
  --ingress=true \
  --egress=true \
  --protocols tcp,udp \
  --ports "$NETWORK_FILTER_PORTS" \
  --chaos-duration "$CHAOS_DURATION" \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0 \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH" \
  >"$krknctl_log" 2>&1 &
krknctl_pid=$!
printf 'krknctl pod-network-filter started (pid=%s), watching for %s Progressing=True + pre-copy signal on %s.\n' \
  "$krknctl_pid" "$FULL_BACKUP_NAME" "$VM_NAME" >&2

if make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" \
  MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  NAMESPACE="$NAMESPACE" \
  GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}" \
  GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-4}" \
  GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}" \
  GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}" \
  GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
  e2e_status=0
else
  e2e_status=$?
fi

if wait "$krknctl_pid"; then
  krknctl_status=0
else
  krknctl_status=$?
fi
printf 'E2E exit status: %d; krknctl trigger/injection status: %d (log: %s)\n' \
  "$e2e_status" "$krknctl_status" "$krknctl_log" >&2

oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/full-backup.yaml" 2>/dev/null || true
oc get vm "$VM_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/vm.yaml" 2>/dev/null || true
launcher_pod="$(oc get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=${VM_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$launcher_pod" ]]; then
  oc get pod "$launcher_pod" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/launcher-pod.yaml" 2>/dev/null || true
  oc logs -n "$NAMESPACE" "$launcher_pod" -c compute >"$EVIDENCE_DIR/launcher-compute.log" 2>/dev/null || true
fi

if ((krknctl_status != 0)); then
  printf 'krknctl trigger/injection did not complete successfully; treat as a harness-side gap, not a product verdict, and inspect %s.\n' \
    "$krknctl_log" >&2
  exit "$krknctl_status"
fi

if ((e2e_status != 0)); then
  printf 'E2E TYPE=full exited nonzero while the network filter was active on the launcher pod. This contradicts the architectural-isolation hypothesis under test (backup copy and handler-to-launcher control path are expected to be node-local, independent of pod IP). Inspect %s/full-backup.yaml and %s/launcher-compute.log before judging this a product failure versus an unrelated harness issue.\n' \
    "$EVIDENCE_DIR" "$EVIDENCE_DIR" >&2
  exit "$e2e_status"
fi

printf 'Full backup succeeded (exit 0) while the launcher pod network was filtered in-window; this is the expected result for CBT-F-11. Verify tracker/checkpoint and restore against %s/full-backup.yaml and the repository restore verifier before closing the scenario.\n' \
  "$EVIDENCE_DIR" >&2

planned_passes="$(jq -r '.incremental_passes_total' "$ROOT_DIR/runs/$RUN_ID/run.json" 2>/dev/null || echo 1)"
if [[ ! "$planned_passes" =~ ^[1-9][0-9]*$ ]]; then
  planned_passes=1
fi
followup_status=0
for ((pass = 1; pass <= planned_passes; pass++)); do
  if make e2e TYPE=incremental VM="vm-${RUN_ID}" NAMESPACE="$NAMESPACE" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    :
  else
    followup_status=$?
    break
  fi
done
exit "$followup_status"

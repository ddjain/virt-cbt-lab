#!/usr/bin/env bash
# Deterministic backup name lets krknctl's native command trigger watch the
# active-copy signature (Progressing=True, Done not yet True) directly, so
# krknctl starts (and absorbs its own startup latency) before `make e2e
# TYPE=full` ever applies the full-backup manifest.
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
# Force-set (not :-): the execution host's .env pre-exports VM_OS=rhel9 and
# MANIFEST_VARIANT=large-odf (Ceph RBD) for the default campaign workload;
# env-conditional defaults never fire once .env exports the variable, and the
# odf variants never exercise the HostPath CSI node plugin this issue targets.
VM_OS="rhel9"
MANIFEST_VARIANT="default"
case "$MANIFEST_VARIANT" in
  default | large) ;;
  *)
    printf 'CBT-F-07 targets the HostPath CSI node plugin; MANIFEST_VARIANT must be "default" or "large" (got: %s)\n' \
      "$MANIFEST_VARIANT" >&2
    exit 2
    ;;
esac
# Keep the .env-default workload sizing (1000 x 15-20MiB): it produces a ~52s
# full-copy window on cbt-demo-hpp (measured on CBT-F-06 r05), comfortably
# longer than the 3s trigger poll interval. Forward explicitly so the printed
# pipeline configuration is authoritative.
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-1000}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-4}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-15}"
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-20}"
TRIGGERS_TIMEOUT="${TRIGGERS_TIMEOUT:-1800}"
CSI_NAMESPACE="openshift-cnv"
# k8s-app=hostpath-provisioner also matches the unrelated hpp-pool-* backing
# storage pod; only the DaemonSet-owned pod name starts with this prefix.
CSI_NAME_PATTERN='^hostpath-provisioner-csi-'
export NAMESPACE

VM_NAME="vm-${RUN_ID}"
TRACKER_NAME="vm-tracker-${RUN_ID}"
FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
FULL_BACKUP_PVC_NAME="vm-backup-pvc-${RUN_ID}"
EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-F-07/runs/$RUN_ID"

if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
  printf 'Run ID %s already exists locally; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
fi
# Allow only this run's pre-armed read-only observer directory; any other
# pre-existing content under the evidence dir means the ID is not fresh.
if [[ -d "$EVIDENCE_DIR" ]]; then
  existing_evidence="$(find "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 \
    ! -name observer -print -quit)"
  if [[ -n "$existing_evidence" ]] || [[ ! -d "$EVIDENCE_DIR/observer" ]]; then
    printf 'Run ID %s already has evidence; refusing to reuse it.\n' "$RUN_ID" >&2
    exit 1
  fi
  unexpected_observer_content="$(find "$EVIDENCE_DIR/observer" -mindepth 1 \
    \( -name trigger.log -o -name krknctl.log \) -print -quit)"
  if [[ -n "$unexpected_observer_content" ]]; then
    printf 'Run ID %s observer already contains run artifacts; refusing to reuse it.\n' "$RUN_ID" >&2
    exit 1
  fi
elif [[ -e "$EVIDENCE_DIR" ]]; then
  printf 'Run ID %s evidence path is not a directory; refusing to reuse it.\n' "$RUN_ID" >&2
  exit 1
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

csi_pod_json="$(oc get pods -n "$CSI_NAMESPACE" -o json | \
  jq --arg pat "$CSI_NAME_PATTERN" '.items |= [.[] | select(.metadata.name | test($pat))]')"
csi_pod_count="$(jq '.items | length' <<<"$csi_pod_json")"
if [[ "$csi_pod_count" != 1 ]]; then
  printf 'Expected exactly one HostPath CSI node plugin pod in %s; found %s. Refusing to proceed.\n' \
    "$CSI_NAMESPACE" "$csi_pod_count" >&2
  exit 1
fi
csi_pod_before="$(jq -r '.items[0].metadata.name' <<<"$csi_pod_json")"
csi_pod_uid_before="$(jq -r '.items[0].metadata.uid' <<<"$csi_pod_json")"
printf 'Baseline HostPath CSI node plugin pod: %s (uid=%s) in %s.\n' \
  "$csi_pod_before" "$csi_pod_uid_before" "$CSI_NAMESPACE" >&2

# Active-copy compound condition: vmbackup Progressing=True AND Done not yet
# True. A command trigger (not --trigger-k8s-*) because the k8s trigger
# resolves a single dot-path and cannot express the two-clause condition.
# Quoting (harness learning 2026-10-13): the JSONPath containing "(" MUST be
# single-quoted inside the command substitution -- an unquoted paren inside
# $(...) is a shell syntax error and the condition can then never evaluate
# true; nested double quotes break it the same way. The exact expanded string
# of this form was validated with bash -c against live objects.
printf -v trigger_command \
  'test "$(oc get vmbackup %s -n %s -o jsonpath='"'"'{.status.conditions[?(@.type=="Progressing")].status}'"'"' 2>/dev/null)" = True && test "$(oc get vmbackup %s -n %s -o jsonpath='"'"'{.status.conditions[?(@.type=="Done")].status}'"'"' 2>/dev/null)" != True' \
  "$FULL_BACKUP_NAME" "$NAMESPACE" "$FULL_BACKUP_NAME" "$NAMESPACE"

krknctl_log="$EVIDENCE_DIR/krknctl.log"
krknctl run pod-scenarios \
  --namespace "$CSI_NAMESPACE" \
  --name-pattern "$CSI_NAME_PATTERN" \
  --disruption-count 1 \
  --trigger-command "$trigger_command" \
  --trigger-expected-rc 0 \
  --triggers-interval 3 \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH" \
  >"$krknctl_log" 2>&1 &
krknctl_pid=$!
printf 'krknctl pod-scenarios started (pid=%s), watching for %s active-copy (Progressing=True, Done not True).\n' \
  "$krknctl_pid" "$FULL_BACKUP_NAME" >&2

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

if wait "$krknctl_pid"; then
  krknctl_status=0
else
  krknctl_status=$?
fi
printf 'E2E exit status: %d; krknctl trigger/injection status: %d (log: %s)\n' \
  "$e2e_status" "$krknctl_status" "$krknctl_log" >&2

recovery_deadline=$((SECONDS + 120))
recovery_verified=false
while ((SECONDS < recovery_deadline)); do
  after_json="$(oc get pods -n "$CSI_NAMESPACE" -o json | \
    jq --arg pat "$CSI_NAME_PATTERN" '.items |= [.[] | select(.metadata.name | test($pat))]')"
  if jq -e --arg before_uid "$csi_pod_uid_before" '
    [.items[] | select(.metadata.uid != $before_uid and .status.phase == "Running" and
      any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length == 1
  ' <<<"$after_json" >/dev/null; then
    recovery_verified=true
    break
  fi
  sleep 2
done
if [[ "$recovery_verified" == true ]]; then
  csi_pod_after="$(oc get pods -n "$CSI_NAMESPACE" -o json | \
    jq -r --arg pat "$CSI_NAME_PATTERN" '[.items[] | select(.metadata.name | test($pat))][0].metadata.name')"
  printf 'HostPath CSI node plugin recovered as %s; krknctl exit status=%d.\n' \
    "$csi_pod_after" "$krknctl_status" >&2
else
  printf 'HostPath CSI node plugin recovery was not verified within 120s after krknctl exited (status=%d).\n' \
    "$krknctl_status" >&2
fi

oc get pvc "$FULL_BACKUP_PVC_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/full-backup-pvc.yaml" 2>/dev/null || true
oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/full-backup.yaml" 2>/dev/null || true
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/tracker.yaml" 2>/dev/null || true

if [[ "$recovery_verified" != true ]]; then
  printf 'Refusing same-VM follow-up because CSI recovery is unverified.\n' >&2
  if ((e2e_status != 0)); then exit "$e2e_status"; fi
  if ((krknctl_status != 0)); then exit "$krknctl_status"; fi
  exit 1
fi

if ((e2e_status != 0)); then
  if make e2e TYPE=recover VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
    KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
    recovery_status=0
  else
    recovery_status=$?
  fi
  printf 'Full-stage exit status: %d; same-VM recovery status: %d; krknctl status: %d\n' \
    "$e2e_status" "$recovery_status" "$krknctl_status" >&2
  if ((recovery_status != 0)); then exit "$recovery_status"; fi
  if ((krknctl_status != 0)); then exit "$krknctl_status"; fi
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
if ((krknctl_status != 0)); then
  printf 'Harness warning: krknctl returned %d despite API-confirmed CSI recovery.\n' "$krknctl_status" >&2
  exit "$krknctl_status"
fi

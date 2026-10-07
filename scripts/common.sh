#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2034
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-}}"
GUEST_KEY="${GUEST_KEY:-$ROOT_DIR/keys/id_ed25519}"
DEBUG="${DEBUG:-false}"
if [[ "$DEBUG" != true && "$DEBUG" != false ]]; then
  printf 'DEBUG must be true or false (got %s).\n' "$DEBUG" >&2
  exit 2
fi
# These constants are consumed by scripts that source this file.
# shellcheck disable=SC2034
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
GUEST_USER="cbt-demo"
# shellcheck disable=SC2034
STATE_DIR="$ROOT_DIR/state"
# shellcheck disable=SC2034
RUN_ID_FILE="$STATE_DIR/run-id"
# shellcheck disable=SC2034
REPORT_ROOT_DIR="$ROOT_DIR/report"
# shellcheck disable=SC2034
REPORT_ID_FILE="$STATE_DIR/report-id"
# Persistent per-VM lifecycle state and per-lifecycle report artifacts.
# `state/` remains transient; per-VM state survives clean-all for history.
VM_INFO_ROOT_DIR="$REPORT_ROOT_DIR/vms"
VM_INFO_PATH=""
# Ownership label applied to every resource created by an E2E run, so
# scripts/clean-all.sh can delete them without deleting the shared namespace.
# shellcheck disable=SC2034
RUN_LABEL_MANAGED_BY_KEY="app.kubernetes.io/managed-by"
# shellcheck disable=SC2034
RUN_LABEL_MANAGED_BY_VALUE="virt-cbt-lab"
# shellcheck disable=SC2034
RUN_LABEL_RUN_ID_KEY="virt-cbt-lab/run-id"
# shellcheck disable=SC2034
RUN_LABEL_SELECTOR="$RUN_LABEL_MANAGED_BY_KEY=$RUN_LABEL_MANAGED_BY_VALUE"
# Workload directories are exclusive to the CBT file-set verification.
# shellcheck disable=SC2034
LINUX_GUEST_WORKLOAD_DIR="/home/$GUEST_USER/cbt-workload"
# shellcheck disable=SC2034
WINDOWS_GUEST_WORKLOAD_DIR='C:\cbt-data\workload'
# Guest setup/mutation file counts and inclusive whole-MiB payload range.
# Default deterministic assignments total 55 MiB baseline and 33 MiB incremental.
# shellcheck disable=SC2034
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-8}"
# shellcheck disable=SC2034
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-4}"
# Number of sequential incremental backups in one lifecycle.
# shellcheck disable=SC2034
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"
# Target pass total for `TYPE=extend`; unset for other run types.
# shellcheck disable=SC2034
EXTEND_TO_PASS="${EXTEND_TO_PASS:-}"
# shellcheck disable=SC2034
GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-4}"
# shellcheck disable=SC2034
GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-12}"

# Guest profile. Debian remains the default for backwards compatibility.
# shellcheck disable=SC2034
VM_OS="${VM_OS:-debian}"
# shellcheck disable=SC2034
case "$VM_OS" in
  debian)
    VM_DATA_SOURCE_NAME=debian
    VM_DATA_SOURCE_NAMESPACE=vm-cbt-images
    GUEST_LINUX_GROUP=sudo
    GUEST_SSHD_SERVICE=ssh
    GUEST_CLOUD_INIT_PACKAGE_UPDATE=true
    GUEST_CLOUD_INIT_PACKAGES='[qemu-guest-agent]'
    ;;
  rhel9)
    VM_DATA_SOURCE_NAME=rhel9
    VM_DATA_SOURCE_NAMESPACE=openshift-virtualization-os-images
    GUEST_LINUX_GROUP=wheel
    GUEST_SSHD_SERVICE=sshd
    GUEST_CLOUD_INIT_PACKAGE_UPDATE=false
    GUEST_CLOUD_INIT_PACKAGES='[]'
    ;;
  windows) ;;
  *)
    printf 'VM_OS must be "debian", "rhel9", or "windows" (got: %s)\n' "$VM_OS" >&2
    exit 1
    ;;
esac
# shellcheck disable=SC2034
if [[ "$VM_OS" == windows ]]; then
  GUEST_WORKLOAD_DIR="$WINDOWS_GUEST_WORKLOAD_DIR"
  RESTORE_WORKLOAD_MOUNT_DIR="/cbt-data/workload"
else
  GUEST_WORKLOAD_DIR="$LINUX_GUEST_WORKLOAD_DIR"
  RESTORE_WORKLOAD_MOUNT_DIR="$LINUX_GUEST_WORKLOAD_DIR"
fi


# Manifest variant to use for the vm/full-backup/incremental-backup
# resources. "odf" (the default) swaps in manifests/vm-odf.yaml,
# manifests/full-backup-odf.yaml, and manifests/incremental-backup-odf.yaml,
# small demo sizing (6Gi/6Gi/4Gi) backed by the ocs-storagecluster-ceph-rbd
# StorageClass (see docs/odf-setup-plan.md); requires ODF/Ceph deployed on
# the cluster. "default" is the small/fast demo sizing (5Gi/5Gi/3Gi) on
# cbt-demo-hpp instead, for clusters without ODF. "large" swaps in
# manifests/vm-large.yaml, manifests/full-backup-large.yaml, and
# manifests/incremental-backup-large.yaml on cbt-demo-hpp, for chaos-testing
# scenarios that need a sustained, disk-bound backup-copy window (see
# cbt-chaos/chaos-plan.md). "large-odf" is the same large sizing (scaled up
# with the same ODF capacity margin) but on ocs-storagecluster-ceph-rbd.
# shellcheck disable=SC2034
MANIFEST_VARIANT="${MANIFEST_VARIANT:-odf}"
case "$MANIFEST_VARIANT" in
  default | large | odf | large-odf) ;;
  *)
    printf 'MANIFEST_VARIANT must be "default", "large", "odf", or "large-odf" (got: %s)\n' "$MANIFEST_VARIANT" >&2
    exit 1
    ;;
esac
# RHEL 9's source requires an 80Gi large disk on either backend. Debian keeps
# its existing large-variant requests: 40Gi on HPP and 48Gi on ODF.
# shellcheck disable=SC2034
case "$VM_OS:$MANIFEST_VARIANT" in
  rhel9:*) LARGE_MANIFEST_DISK_SIZE=80Gi ;;
  *:odf|*:large-odf) LARGE_MANIFEST_DISK_SIZE=48Gi ;;
  *) LARGE_MANIFEST_DISK_SIZE=40Gi ;;
esac

validate_positive_integer() {
  local variable_name="$1" value="$2"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s must be a positive integer (got: %s)\n' "$variable_name" "$value" >&2
    exit 1
  fi
}

if ! [[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || ((${#NAMESPACE} > 63)); then
  printf 'NAMESPACE must be a DNS-1123 namespace name of at most 63 characters (got: %s)\n' "$NAMESPACE" >&2
  exit 1
fi
validate_positive_integer GUEST_BASE_FILE_COUNT "$GUEST_BASE_FILE_COUNT"
validate_positive_integer GUEST_INCREMENTAL_FILE_COUNT "$GUEST_INCREMENTAL_FILE_COUNT"
if ! [[ "$GUEST_INCREMENTAL_PASSES" =~ ^[1-9][0-9]?$ ]]; then
  printf 'GUEST_INCREMENTAL_PASSES must be a positive integer from 1 to 99 (got: %s).\n' \
    "$GUEST_INCREMENTAL_PASSES" >&2
  exit 1
fi
validate_positive_integer GUEST_FILE_SIZE_MIN_MIB "$GUEST_FILE_SIZE_MIN_MIB"
validate_positive_integer GUEST_FILE_SIZE_MAX_MIB "$GUEST_FILE_SIZE_MAX_MIB"
if ((GUEST_FILE_SIZE_MAX_MIB < GUEST_FILE_SIZE_MIN_MIB)); then
  printf 'GUEST_FILE_SIZE_MAX_MIB must be at least GUEST_FILE_SIZE_MIN_MIB (got %s < %s).\n' \
    "$GUEST_FILE_SIZE_MAX_MIB" "$GUEST_FILE_SIZE_MIN_MIB" >&2
  exit 1
fi

# Resolves a manifest base name to the selected guest profile/size variant.
manifest_path() {
  local base_name="$1" variant="$MANIFEST_VARIANT"
  if [[ "$VM_OS" == windows ]]; then
    printf '%s/manifests/windows-%s.yaml' "$ROOT_DIR" "$base_name"
  else
    if [[ "$VM_OS" == rhel9 ]]; then
      case "$variant" in
        default | large) variant=large ;;
        odf | large-odf) variant=large-odf ;;
      esac
    fi
    if [[ "$variant" == "default" ]]; then
      printf '%s/manifests/%s.yaml' "$ROOT_DIR" "$base_name"
    else
      printf '%s/manifests/%s-%s.yaml' "$ROOT_DIR" "$base_name" "$variant"
    fi
  fi
}

if [[ -n "$KUBECONFIG_PATH" ]]; then
  export KUBECONFIG="$KUBECONFIG_PATH"
fi

oc_cmd() {
  oc "$@"
}

set -E
CURRENT_STEP="workflow startup"

# UTC timestamps match the timestamps recorded by the Kubernetes API.
workflow_timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

workflow_step() {
  CURRENT_STEP="$1"
  printf '\n[%s] [%s] %s\n' "$(workflow_timestamp)" "$WORKFLOW_NAME" "$CURRENT_STEP" >&2
}

workflow_action() {
  printf '  [%s] → %s\n' "$(workflow_timestamp)" "$1" >&2
}

workflow_status() {
  printf '  [%s] [status] %s\n' "$(workflow_timestamp)" "$1" >&2
}

workflow_debug() {
  [[ "$DEBUG" == true ]] || return 0
  printf '  [%s] [debug] %s\n' "$(workflow_timestamp)" "$1" >&2
}

workflow_success() {
  printf '  [%s] ✓ %s\n' "$(workflow_timestamp)" "$1" >&2
}

workflow_failed() {
  local status=$? timestamp
  timestamp="$(workflow_timestamp)"
  printf '  [%s] ✗ Failed: %s (exit %d)\n' "$timestamp" "$CURRENT_STEP" "$status" >&2
  return "$status"
}

trap workflow_failed ERR

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command_name" >&2
    return 1
  fi
}

require_command oc
require_command jq
if [[ -n "$KUBECONFIG_PATH" && ! -r "$KUBECONFIG_PATH" ]]; then
  printf 'Kubeconfig is not readable: %s\n' "$KUBECONFIG_PATH" >&2
  exit 1
fi

# Word lists for human-readable run IDs (see new_run_id). Kept short and
# unambiguous; DNS-1123-safe (lowercase letters only).
RUN_ID_ADJECTIVES=(dark silent brave calm fuzzy happy wild gentle bright swift)
RUN_ID_NOUNS=(forest river wolf meadow penguin mountain falcon ocean tiger valley)

# Derive every per-run resource name from the current $RUN_ID, so a run's VM,
# disk, backups, and tracker always reference each other and never collide
# with another run's resources in the same namespace. Each resource type
# keeps its own fixed prefix ahead of the shared run ID.
incremental_backup_name_for_pass() {
  printf 'vm-incremental-%s-p%02d' "$RUN_ID" "$1"
}

incremental_backup_pvc_name_for_pass() {
  printf 'vm-incremental-pvc-%s-p%02d' "$RUN_ID" "$1"
}

vm_info_path() {
  printf '%s/%s/vm-info.json' "$VM_INFO_ROOT_DIR" "$1"
}

set_resource_names() {
  # shellcheck disable=SC2034
  VM_NAME="vm-${RUN_ID}"
  # shellcheck disable=SC2034
  DV_NAME="vm-disk-${RUN_ID}"
  # shellcheck disable=SC2034
  SSH_SERVICE="vm-ssh-${RUN_ID}"
  # shellcheck disable=SC2034
  TRACKER_NAME="vm-tracker-${RUN_ID}"
  # shellcheck disable=SC2034
  FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
  # shellcheck disable=SC2034
  FULL_BACKUP_PVC_NAME="vm-backup-pvc-${RUN_ID}"
  # shellcheck disable=SC2034
  INCREMENTAL_BACKUP_NAME="$(incremental_backup_name_for_pass 1)"
  # shellcheck disable=SC2034
  INCREMENTAL_BACKUP_PVC_NAME="$(incremental_backup_pvc_name_for_pass 1)"
  # shellcheck disable=SC2034
  RESTORE_POD_NAME="vm-restore-verify-${RUN_ID}"
  VM_INFO_PATH="$(vm_info_path "$RUN_ID")"
}

# Generate one new run ID (random adjective-noun pair, plus a short random
# hex tag since the 100 adjective/noun combinations alone collide too often
# across repeated runs) and persist it so every later script invocation in
# the same E2E run reuses it.
new_run_id() {
  mkdir -p "$STATE_DIR"
  if [[ -n "${RUN_ID:-}" ]]; then
    # NAME (passed through `make e2e NAME=foo`) must be DNS-1123-safe since
    # it flows straight into Kubernetes resource names.
    if ! [[ "$RUN_ID" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
       ((${#RUN_ID} > 40)); then
      printf '[vm-cbt] NAME must be lowercase alphanumeric with internal hyphens and at most 40 characters (got: %s).\n' "$RUN_ID" >&2
      exit 1
    fi
    set_resource_names
    VM_INFO_PATH="$(vm_info_path "$RUN_ID")"
    if [[ -e "$VM_INFO_PATH" ]] &&
       [[ "$(jq -r '.status // "unknown"' "$VM_INFO_PATH")" != cleaned ]]; then
      printf '[vm-cbt] Run ID %s still has lifecycle state at %s; choose a new NAME or clean the active run.\n' \
        "$RUN_ID" "$VM_INFO_PATH" >&2
      exit 1
    fi
    local resource kind pass
    local -a resources=(
      "$VM_NAME:vm" "$DV_NAME:dv" "$SSH_SERVICE:service"
      "$TRACKER_NAME:vmbackuptracker" "$FULL_BACKUP_NAME:vmbackup"
      "$FULL_BACKUP_PVC_NAME:pvc"
    )
    for ((pass = 1; pass <= GUEST_INCREMENTAL_PASSES; pass++)); do
      resources+=("$(incremental_backup_name_for_pass "$pass"):vmbackup")
      resources+=("$(incremental_backup_pvc_name_for_pass "$pass"):pvc")
    done
    for resource in "${resources[@]}"; do
      kind="${resource##*:}"
      resource="${resource%:*}"
      if oc_cmd get "$kind" "$resource" -n "$NAMESPACE" >/dev/null 2>&1; then
        printf '[vm-cbt] Run ID %s already owns or conflicts with %s/%s in namespace %s; choose another NAME or clean the existing run.\n' \
          "$RUN_ID" "$kind" "$resource" "$NAMESPACE" >&2
        exit 1
      fi
    done
    printf '[vm-cbt] Using assigned run ID: %s\n' "$RUN_ID" >&2
  else
    local adjective noun tag
    adjective="${RUN_ID_ADJECTIVES[RANDOM % ${#RUN_ID_ADJECTIVES[@]}]}"
    noun="${RUN_ID_NOUNS[RANDOM % ${#RUN_ID_NOUNS[@]}]}"
    # od+tr avoids piping into `head -c`, which would SIGPIPE the upstream
    # reader and trip `set -o pipefail` under the ERR trap.
    tag="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
    RUN_ID="${adjective}-${noun}-${tag}"
    printf '[vm-cbt] New run ID: %s\n' "$RUN_ID" >&2
    set_resource_names
  fi
  printf '%s' "$RUN_ID" > "$RUN_ID_FILE"
}

# Load the run ID persisted by new_run_id (or an explicitly exported RUN_ID)
# for scripts that must operate on an already-created run's resources.
load_run_id() {
  if [[ -z "${RUN_ID:-}" ]]; then
    if [[ -n "${VM:-}" ]]; then
      if [[ "$VM" != vm-* ]]; then
        printf 'VM must be a workflow VM name in the form vm-<run-id> (got: %s).\n' "$VM" >&2
        return 1
      fi
      RUN_ID="${VM#vm-}"
    elif [[ -f "$RUN_ID_FILE" ]]; then
      RUN_ID="$(cat "$RUN_ID_FILE")"
    else
      printf 'No active run ID found in %s. Run `make e2e TYPE=full` first.\n' "$RUN_ID_FILE" >&2
      return 1
    fi
  fi
  set_resource_names
}

# Generate one new report ID (UTC timestamp, with a run-ID suffix only when
# another report started in the same second already exists) and persist it so
# every later script invocation in the same E2E run appends to the same report.
new_report_id() {
  mkdir -p "$STATE_DIR"
  REPORT_ID="run_$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ -e "$REPORT_ROOT_DIR/$REPORT_ID" ]]; then
    REPORT_ID="${REPORT_ID}_${RUN_ID}"
  fi
  printf '%s' "$REPORT_ID" > "$REPORT_ID_FILE"
  REPORT_DIR="$REPORT_ROOT_DIR/$REPORT_ID"
  mkdir -p "$REPORT_DIR/fragments"
  printf '[vm-cbt] New report ID: %s\n' "$REPORT_ID" >&2
}
# to an already-created run's report.
load_report_id() {
  if [[ -z "${REPORT_ID:-}" && -r "$VM_INFO_PATH" ]]; then
    REPORT_ID="$(jq -r '.report_id // empty' "$VM_INFO_PATH")"
  fi
  if [[ -z "${REPORT_ID:-}" ]]; then
    if [[ ! -f "$REPORT_ID_FILE" ]]; then
      printf 'No active report ID found in %s. Run `make e2e TYPE=full` first.\n' "$REPORT_ID_FILE" >&2
      return 1
    fi
    REPORT_ID="$(cat "$REPORT_ID_FILE")"
  fi
  REPORT_DIR="$REPORT_ROOT_DIR/$REPORT_ID"
  mkdir -p "$REPORT_DIR/fragments"
}

# Write one named JSON fragment for the current report; scripts pass already
# well-formed JSON text (usually built with `jq -n`). vm-cbt-verify.sh merges
# every fragment into report/<REPORT_ID>/report.json once the run completes.
write_report_fragment() {
  local fragment_name="$1" json_content="$2"
  mkdir -p "$REPORT_DIR/fragments"
  printf '%s' "$json_content" | jq '.' > "$REPORT_DIR/fragments/$fragment_name.json"
}

vm_info_load() {
  local run_id="$1"
  VM_INFO_PATH="$(vm_info_path "$run_id")"
  if [[ ! -r "$VM_INFO_PATH" ]] ||
     ! jq -e --arg run_id "$run_id" '
       .schema_version == 1 and .run_id == $run_id and
       (.vm_name | type == "string") and (.report_id | type == "string")
     ' "$VM_INFO_PATH" >/dev/null; then
    printf 'Missing or invalid VM lifecycle state for run %s: %s\n' "$run_id" "$VM_INFO_PATH" >&2
    return 1
  fi
}

vm_info_initialize() {
  local manifest tmp_path now
  VM_INFO_PATH="$(vm_info_path "$RUN_ID")"
  manifest="$(workload_manifest_path)"
  tmp_path="${VM_INFO_PATH}.tmp.$$"
  now="$(workflow_timestamp)"
  if [[ -e "$VM_INFO_PATH" ]]; then
    if [[ "$(jq -r '.status // "unknown"' "$VM_INFO_PATH")" != cleaned ]]; then
      printf 'VM lifecycle state is still active: %s\n' "$VM_INFO_PATH" >&2
      return 1
    fi
    local previous_report_id history_dir archived_info
    previous_report_id="$(jq -r '.report_id // empty' "$VM_INFO_PATH")"
    history_dir="$(dirname "$VM_INFO_PATH")/history"
    mkdir -p "$history_dir"
    archived_info="$history_dir/${previous_report_id:-cleaned-$(date -u +%Y%m%dT%H%M%SZ)}.json"
    if [[ -e "$archived_info" ]]; then
      archived_info="${archived_info%.json}-$(date -u +%s).json"
    fi
    mv "$VM_INFO_PATH" "$archived_info"
  fi
  mkdir -p "$(dirname "$VM_INFO_PATH")"
  jq -n \
    --arg run_id "$RUN_ID" \
    --arg vm_name "$VM_NAME" \
    --arg namespace "$NAMESPACE" \
    --arg os_profile "$VM_OS" \
    --arg report_id "$REPORT_ID" \
    --arg manifest_path "$WORKLOAD_MANIFEST_NAME" \
    --arg manifest_variant "$MANIFEST_VARIANT" \
    --arg status "baseline_ready" \
    --arg created_at "$now" \
    --argjson passes_total "$GUEST_INCREMENTAL_PASSES" \
    --argjson incremental_file_count "$GUEST_INCREMENTAL_FILE_COUNT" \
    --argjson baseline_file_count "$(jq -r '.baseline.file_count' "$manifest")" \
    --argjson baseline_payload_bytes "$(jq -r '.baseline.total_payload_bytes' "$manifest")" \
    --arg baseline_manifest_sha256 "$(jq -r '.baseline.manifest_sha256' "$manifest")" \
    --argjson size_range "$(jq -c '.size_range_mib' "$manifest")" \
    '{schema_version: 1, run_id: $run_id, vm_name: $vm_name, namespace: $namespace,
      os_profile: $os_profile, report_id: $report_id, manifest_variant: $manifest_variant,
      status: $status, incremental_passes_total: $passes_total, incremental_passes_completed: 0,
      next_incremental_pass: 1,
      guest: {workload_manifest_path: $manifest_path, size_range_mib: $size_range,
              incremental_file_count_per_pass: $incremental_file_count,
              baseline: {file_count: $baseline_file_count,
                         total_payload_bytes: $baseline_payload_bytes,
                         manifest_sha256: $baseline_manifest_sha256}},
      backups: {full: null, incrementals: []},
      created_at: $created_at, updated_at: $created_at}' > "$tmp_path"
  mv -f "$tmp_path" "$VM_INFO_PATH"
}

vm_info_update() {
  local filter="$1" tmp_path updated_at
  shift
  if [[ ! -r "$VM_INFO_PATH" ]]; then
    printf 'Cannot update missing VM lifecycle state: %s\n' "$VM_INFO_PATH" >&2
    return 1
  fi
  tmp_path="${VM_INFO_PATH}.tmp.$$"
  updated_at="$(workflow_timestamp)"
  jq "$@" --arg updated_at "$updated_at" "$filter | .updated_at = \$updated_at" \
    "$VM_INFO_PATH" > "$tmp_path"
  mv -f "$tmp_path" "$VM_INFO_PATH"
}

vm_info_next_pass() {
  local completed total next
  completed="$(jq -r '.incremental_passes_completed' "$VM_INFO_PATH")"
  total="$(jq -r '.incremental_passes_total' "$VM_INFO_PATH")"
  next="$(jq -r '.next_incremental_pass // empty' "$VM_INFO_PATH")"
  if [[ -z "$next" ]] || ((completed >= total)); then
    printf 'All %s incremental passes are already complete for %s.\n' "$total" "$VM_NAME" >&2
    return 1
  fi
  if ! [[ "$next" =~ ^[1-9][0-9]*$ ]] || ((next != completed + 1 || next > total)); then
    printf 'VM lifecycle pass counter is inconsistent (completed=%s next=%s total=%s).\n' \
      "$completed" "$next" "$total" >&2
    return 1
  fi
  printf '%s' "$next"
}

vm_info_previous_checkpoint() {
  jq -r '.backups.incrementals[-1].checkpoint_name // .backups.full.checkpoint_name // empty' "$VM_INFO_PATH"
}

# Save one run-owned pod's full log to report/<REPORT_ID>/logs/<log_filename>,
# for debugging a run after the fact. Best-effort: a missing pod or `oc logs`
# failure (e.g. the pod was already cleaned up) does not fail the workflow.
collect_pod_log() {
  local pod_name="$1" log_filename="$2"
  mkdir -p "$REPORT_DIR/logs"
  if ! oc_cmd logs "pod/$pod_name" -n "$NAMESPACE" --all-containers=true \
      > "$REPORT_DIR/logs/$log_filename" 2>&1; then
    printf '[vm-cbt] Could not collect logs for pod %s (already gone?); see %s for details.\n' \
      "$pod_name" "$REPORT_DIR/logs/$log_filename" >&2
  fi
}

ensure_guest_key() {
  printf '[vm-cbt] Ensuring the guest SSH key is available at %s.\n' "$GUEST_KEY" >&2
  mkdir -p "$(dirname "$GUEST_KEY")"
  if [[ ! -f "$GUEST_KEY" ]]; then
    rm -f "$GUEST_KEY.pub"
    ssh-keygen -q -t ed25519 -N '' -f "$GUEST_KEY"
    touch "$GUEST_KEY.vm-cbt-managed"
  elif [[ ! -f "$GUEST_KEY.pub" ]]; then
    ssh-keygen -y -f "$GUEST_KEY" > "$GUEST_KEY.pub"
  fi
  chmod 600 "$GUEST_KEY"
  cat "$GUEST_KEY.pub"
}

ssh_guest_command() {
  local port="$1" remote_command="$2"
  # Host-key checking is disabled only for this randomized localhost forward.
  ssh -i "$GUEST_KEY" -p "$port" \
    -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$GUEST_USER@127.0.0.1" "$remote_command"
}

probe_guest_ssh() {
  local port="$1" probe_log="$2"
  if ssh_guest_command "$port" true >/dev/null 2>"$probe_log"; then
    return 0
  fi
  return 1
}

extract_forwarded_port() {
  local forward_log="$1"
  sed -n 's/^Forwarding from 127[.]0[.]0[.]1:\([0-9][0-9]*\) -> 22$/\1/p' "$forward_log" | sed -n '1p'
}

guest_ssh() {
  local guest_command
  if (($# != 1)); then
    printf 'guest_ssh expects exactly one remote command.\n' >&2
    return 2
  fi
  guest_command="$1"

  printf '[guest-ssh] Connecting through local port-forward to %s.\n' "$SSH_SERVICE" >&2
  local forward_log probe_log forward_pid port
  forward_log="$(mktemp)"
  probe_log="$(mktemp)"
  forward_pid=

  stop_forward() {
    if [[ -n "${forward_pid:-}" ]]; then
      kill "$forward_pid" 2>/dev/null || true
      wait "$forward_pid" 2>/dev/null || true
      forward_pid=
    fi
  }
  cleanup() {
    trap - EXIT INT TERM
    stop_forward
    rm -f "$forward_log" "$probe_log"
  }
  trap cleanup EXIT INT TERM

  for ((attempt = 1; attempt <= 30; attempt++)); do
    printf '[guest-ssh] → oc port-forward -n %s service/%s :22 (attempt %d/30).\n' \
      "$NAMESPACE" "$SSH_SERVICE" "$attempt" >&2
    : > "$forward_log"
    oc_cmd port-forward -n "$NAMESPACE" "service/$SSH_SERVICE" :22 >"$forward_log" 2>&1 &
    forward_pid=$!
    port=
    for ((wait_attempt = 1; wait_attempt <= 30; wait_attempt++)); do
      port="$(extract_forwarded_port "$forward_log")"
      if [[ -n "$port" ]]; then
        printf '[guest-ssh] Port-forward ready on 127.0.0.1:%s.\n' "$port" >&2
        break
      fi
      if ! kill -0 "$forward_pid" 2>/dev/null; then
        break
      fi
      sleep 1
    done

    if [[ -n "$port" ]]; then
      printf '[guest-ssh] → ssh %s@127.0.0.1:%s (probe, then guest command).\n' \
        "$GUEST_USER" "$port" >&2
      if probe_guest_ssh "$port" "$probe_log"; then
        if ssh_guest_command "$port" "$guest_command"; then
          cleanup
          return 0
        fi
        cleanup
        return 1
      fi
      printf '[guest-ssh] SSH probe failed; retrying.\n' >&2
      # Authentication failures are terminal; startup failures can recover.
      if grep -q 'Permission denied' "$probe_log"; then
        cat "$probe_log" >&2
        cleanup
        return 1
      fi
    fi

    printf '[guest-ssh] Guest not ready; retrying.\n' >&2
    stop_forward
    sleep 1
  done

  printf '[guest-ssh] Timed out waiting for guest SSH.\n' >&2
  cat "$forward_log" >&2
  cat "$probe_log" >&2
  printf 'Could not connect to the VM guest over SSH.\n' >&2
  cleanup
  return 1
}

watch_backup_status() {
  local backup_name="$1" pvc_name="$2" expected_type="$3" base_checkpoint="$4" owner_pid="$5"
  local start_seconds="$SECONDS" last_heartbeat="$SECONDS" last_signature="" last_api_error=false
  local backup_json vm_json runtime_status conditions done_status initializing_status progressing_status
  local phase status_type checkpoint included_volumes pvc_phase runtime_started runtime_completed
  local runtime_failed runtime_checkpoint runtime_message signature line elapsed

  workflow_status "Backup watcher started: VM=$VM_NAME backup=$backup_name requested_type=$expected_type PVC=${pvc_name:-unknown}"
  if [[ -n "$base_checkpoint" ]]; then
    workflow_status "Backup $backup_name uses base checkpoint $base_checkpoint"
  fi

  while kill -0 "$owner_pid" 2>/dev/null; do
    if ! backup_json="$(oc_cmd get vmbackup "$backup_name" -n "$NAMESPACE" -o json 2>/dev/null)"; then
      if [[ "$DEBUG" == true && "$last_api_error" != true ]]; then
        workflow_debug "Backup $backup_name API status is temporarily unavailable; oc wait remains authoritative"
      fi
      last_api_error=true
      sleep 2
      continue
    fi
    last_api_error=false

    conditions="$(jq -r '
      [.status.conditions[]? |
        ((.type // "unknown") + "=" + (.status // "Unknown") +
         (if (.reason // "") == "" then "" else "(" + (.reason | gsub("[\r\n]"; " ")) + ")" end))]
      | sort | join(",")
    ' <<<"$backup_json")"
    done_status="$(jq -r '[.status.conditions[]? | select(.type=="Done") | .status] | last // empty' <<<"$backup_json")"
    initializing_status="$(jq -r '[.status.conditions[]? | select(.type=="Initializing") | .status] | last // empty' <<<"$backup_json")"
    progressing_status="$(jq -r '[.status.conditions[]? | select(.type=="Progressing") | .status] | last // empty' <<<"$backup_json")"
    status_type="$(jq -r '.status.type // empty' <<<"$backup_json")"
    checkpoint="$(jq -r '.status.checkpointName // empty' <<<"$backup_json")"
    included_volumes="$(jq -r '[.status.includedVolumes[]? | ((.diskTarget // "unknown") + "/" + (.volumeName // "unknown"))] | join(",")' <<<"$backup_json")"

    pvc_phase=unknown
    if [[ -n "$pvc_name" ]]; then
      pvc_phase="$(oc_cmd get pvc "$pvc_name" -n "$NAMESPACE" -o 'jsonpath={.status.phase}' 2>/dev/null || true)"
      [[ -n "$pvc_phase" ]] || pvc_phase=unavailable
    fi

    vm_json="$(oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o json 2>/dev/null || true)"
    runtime_status='{}'
    if [[ -n "$vm_json" ]]; then
      runtime_status="$(jq -c --arg backup_name "$backup_name" '
        (.status.changedBlockTracking.backupStatus // {}) as $backup |
        if $backup.backupName == $backup_name then
          {startTimestamp: ($backup.startTimestamp // null),
           endTimestamp: ($backup.endTimestamp // null),
           completed: ($backup.completed // false),
           failed: ($backup.failed // false),
           checkpointName: ($backup.checkpointName // null),
           backupMsg: ($backup.backupMsg // null)}
        else {} end
      ' <<<"$vm_json" 2>/dev/null || printf '{}')"
    fi
    runtime_started="$(jq -r '.startTimestamp // empty' <<<"$runtime_status")"
    runtime_completed="$(jq -r '.completed // false' <<<"$runtime_status")"
    runtime_failed="$(jq -r '.failed // false' <<<"$runtime_status")"
    runtime_checkpoint="$(jq -r '.checkpointName // empty' <<<"$runtime_status")"
    runtime_message="$(jq -r '(.backupMsg // "") | gsub("[\r\n\t]"; " ")' <<<"$runtime_status")"

    if [[ "$done_status" == True ]]; then
      phase=done
    elif [[ "$initializing_status" == True ]]; then
      phase=initializing
    elif [[ "$progressing_status" == True ]]; then
      phase=progressing
    elif [[ -n "$runtime_started" ]]; then
      phase=runtime-started
    else
      phase=waiting
    fi

    signature="$phase|$conditions|$pvc_phase|$status_type|$checkpoint|$included_volumes|$runtime_started|$runtime_completed|$runtime_failed|$runtime_checkpoint|$runtime_message"
    elapsed=$((SECONDS - start_seconds))
    line="backup=$backup_name requested_type=$expected_type phase=$phase conditions=${conditions:-none} pvc=${pvc_name:-unknown}:$pvc_phase elapsed_since_watch=${elapsed}s"
    if [[ -n "$base_checkpoint" ]]; then line+=" base_checkpoint=$base_checkpoint"; fi
    if [[ -n "$status_type" ]]; then line+=" status_type=$status_type"; fi
    if [[ -n "$checkpoint" ]]; then line+=" checkpoint=$checkpoint"; fi
    if [[ -n "$included_volumes" ]]; then line+=" included_volumes=$included_volumes"; fi
    if [[ -n "$runtime_started" ]]; then line+=" runtime_started_at=$runtime_started"; fi
    if [[ "$runtime_completed" == true ]]; then line+=" runtime_completed=true"; fi
    if [[ "$runtime_failed" == true ]]; then line+=" runtime_failed=true"; fi
    if [[ -n "$runtime_checkpoint" ]]; then line+=" runtime_checkpoint=$runtime_checkpoint"; fi

    if [[ "$signature" != "$last_signature" ]]; then
      workflow_status "$line"
      last_signature="$signature"
      last_heartbeat="$SECONDS"
      if [[ "$DEBUG" == true ]]; then
        workflow_debug "backup=$backup_name conditions=$(jq -c '.status.conditions // []' <<<"$backup_json") vmi_backup_status=$runtime_status"
      fi
    elif ((SECONDS - last_heartbeat >= 30)); then
      workflow_status "Backup heartbeat: $line"
      last_heartbeat="$SECONDS"
      if [[ "$DEBUG" == true ]]; then
        workflow_debug "backup=$backup_name conditions=$(jq -c '.status.conditions // []' <<<"$backup_json") vmi_backup_status=$runtime_status"
      fi
    fi

    if [[ "$done_status" == True ]]; then
      break
    fi
    sleep 2
  done
}

wait_for_backup_done() {
  local backup_name="$1" pvc_name="${2:-}" expected_type="${3:-unknown}" base_checkpoint="${4:-}"
  local done_status watcher_pid wait_status

  done_status="$(get_backup_done_status "$backup_name" 2>/dev/null || true)"
  if [[ "$done_status" == True ]]; then
    oc_cmd wait "vmbackup/$backup_name" -n "$NAMESPACE" --for=condition=Done --timeout=20m
    return
  fi
  if [[ -z "$pvc_name" ]]; then
    pvc_name="$(get_backup_pvc_name "$backup_name" 2>/dev/null || true)"
  fi

  watch_backup_status "$backup_name" "$pvc_name" "$expected_type" "$base_checkpoint" "$$" &
  watcher_pid=$!
  if oc_cmd wait "vmbackup/$backup_name" -n "$NAMESPACE" --for=condition=Done --timeout=20m; then
    wait_status=0
  else
    wait_status=$?
  fi
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  return "$wait_status"
}

get_backup_type() {
  local backup_name="$1"
  oc_cmd get vmbackup "$backup_name" \
    -n "$NAMESPACE" \
    -o 'jsonpath={.status.type}'
}

get_backup_checkpoint() {
  local backup_name="$1"
  oc_cmd get vmbackup "$backup_name" \
    -n "$NAMESPACE" \
    -o 'jsonpath={.status.checkpointName}'
}

get_backup_done_status() {
  local backup_name="$1"
  oc_cmd get vmbackup "$backup_name" \
    -n "$NAMESPACE" \
    -o 'jsonpath={.status.conditions[?(@.type=="Done")].status}'
}

# `Done=True` is set by KubeVirt on both a genuinely completed backup and a
# terminal failure (e.g. "Backup has failed: VMI backup status was lost") —
# the `status` field alone cannot distinguish them, only `reason` can. See
# cbt-chaos/scenarios/01-virt-launcher-pod-kill-during-copy/scenario-spec.md
# §5 for the run that surfaced this.
get_backup_done_reason() {
  local backup_name="$1"
  oc_cmd get vmbackup "$backup_name" \
    -n "$NAMESPACE" \
    -o 'jsonpath={.status.conditions[?(@.type=="Done")].reason}'
}

# Returns 0 (success) unless the Done reason is KubeVirt's own terminal
# failure wording. Benign warnings (e.g. "Completed VirtualMachineBackup,
# warning: Failed freezing guest filesystem: ...") are not failures.
backup_done_reason_is_failure() {
  local reason="$1"
  [[ "$reason" == "Backup has failed"* ]]
}

get_tracker_checkpoint() {
  oc_cmd get vmbackuptracker "$TRACKER_NAME" \
    -n "$NAMESPACE" \
    -o 'jsonpath={.status.latestCheckpoint.name}'
}

get_backup_pvc_name() {
  local backup_name="$1"
  oc_cmd get vmbackup "$backup_name" \
    -n "$NAMESPACE" \
    -o 'jsonpath={.spec.pvcName}'
}

get_pvc_requested() {
  local pvc_name="$1"
  oc_cmd get pvc "$pvc_name" \
    -n "$NAMESPACE" \
    -o 'jsonpath={.spec.resources.requests.storage}' 2>/dev/null
}

get_pvc_capacity() {
  local pvc_name="$1"
  oc_cmd get pvc "$pvc_name" \
    -n "$NAMESPACE" \
    -o 'jsonpath={.status.capacity.storage}' 2>/dev/null
}

# Read the VM's changedBlockTracking.backupStatus as JSON. This field is
# overwritten by every subsequent backup, so callers must read it
# immediately after their own backup reports Done=True and confirm
# .backupName matches before trusting its timestamps.
get_vm_backup_status() {
  oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o json |
    jq -c '.status.changedBlockTracking.backupStatus // {}'
}

# Record a guest-observed value (e.g. a hash captured at backup time) so a
# later step, possibly a separate script invocation, can assert against it.
write_state_file() {
  local state_name="$1" value="$2"
  mkdir -p "$STATE_DIR"
  printf '%s' "$value" > "$STATE_DIR/$state_name"
}

read_state_file() {
  local state_name="$1"
  local state_path="$STATE_DIR/$state_name"
  if [[ ! -f "$state_path" ]]; then
    printf 'Missing state file %s; run the step that records it first.\n' "$state_path" >&2
    return 1
  fi
  cat "$state_path"
}

# Extract the hash from a `sha256sum <file>` line ("<hash>  <file>").
extract_sha256() {
  awk '{print $1; exit}'
}

#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2034
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/run-id.sh"
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
# Transient state contains the checkout-wide operation lock only.
STATE_DIR="$ROOT_DIR/state"
# Each run owns its metadata, workload manifest, reports, and evidence.
RUNS_ROOT_DIR="$ROOT_DIR/runs"
RUN_DIR=""
VM_INFO_PATH=""
REPORT_DIR=""
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

# RHEL 9 is the standard profile; Debian remains an explicit override.
# shellcheck disable=SC2034
VM_OS="${VM_OS:-rhel9}"
# shellcheck disable=SC2034
set_vm_os_profile() {
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
  if [[ "$VM_OS" == windows ]]; then
    GUEST_WORKLOAD_DIR="$WINDOWS_GUEST_WORKLOAD_DIR"
    RESTORE_WORKLOAD_MOUNT_DIR="/cbt-data/workload"
  else
    GUEST_WORKLOAD_DIR="$LINUX_GUEST_WORKLOAD_DIR"
    RESTORE_WORKLOAD_MOUNT_DIR="$LINUX_GUEST_WORKLOAD_DIR"
  fi
}
set_vm_os_profile


# Manifest variant defaults to large-odf for the RHEL 9 profile. On RHEL 9,
# HPP variants map to large and ODF variants map to large-odf; both use an
# 80Gi root/full disk and 25Gi/30Gi incremental PVCs (HPP/ODF).
# For Debian, "odf" is the small 6Gi/6Gi/4Gi ODF profile, "default" is the
# 5Gi/5Gi/3Gi HPP profile, "large" is 40Gi/40Gi/25Gi HPP, and "large-odf"
# is 48Gi/48Gi/30Gi ODF. See docs/odf-setup-plan.md and
# cbt-chaos/chaos-plan.md for backend and sustained-copy profile details.
# shellcheck disable=SC2034
MANIFEST_VARIANT="${MANIFEST_VARIANT:-large-odf}"
set_manifest_variant_settings() {
  case "$MANIFEST_VARIANT" in
    default | large | odf | large-odf) ;;
    *)
      printf 'MANIFEST_VARIANT must be "default", "large", "odf", or "large-odf" (got: %s)\n' "$MANIFEST_VARIANT" >&2
      exit 1
      ;;
  esac
  case "$VM_OS:$MANIFEST_VARIANT" in
    rhel9:*) LARGE_MANIFEST_DISK_SIZE=80Gi ;;
    *:odf|*:large-odf) LARGE_MANIFEST_DISK_SIZE=48Gi ;;
    *) LARGE_MANIFEST_DISK_SIZE=40Gi ;;
  esac
}
set_manifest_variant_settings

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
WORKFLOW_PHASE_PRINTED=false

workflow_timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

workflow_record_log() {
  local level="$1" timestamp="$2" message="$3"
  if [[ -n "${RUN_DIR:-}" && -d "$RUN_DIR/logs" ]]; then
    printf '[%s] [%s] [%s] %s\n' "$timestamp" "${WORKFLOW_NAME:-workflow}" "$level" "$message" \
      >> "$RUN_DIR/logs/workflow.log"
  fi
}

workflow_step() {
  local timestamp phase_label
  CURRENT_STEP="$1"
  timestamp="$(workflow_timestamp)"
  workflow_record_log step "$timestamp" "$CURRENT_STEP"
  if [[ "$DEBUG" == true ]]; then
    printf '\n[%s] [%s] %s\n' "$timestamp" "$WORKFLOW_NAME" "$CURRENT_STEP" >&2
  else
    if [[ "$WORKFLOW_PHASE_PRINTED" != true ]]; then
      case "${WORKFLOW_NAME:-workflow}" in
        vm-setup|windows-vm-setup) phase_label="VM SETUP" ;;
        vm-backup) phase_label="FULL BACKUP" ;;
        vm-cbt-backup) phase_label="INCREMENTAL BACKUP" ;;
        vm-cbt-verify|vm-cbt-restore-test) phase_label="VERIFICATION" ;;
        vm-cbt-extend) phase_label="INCREMENTAL EXTENSION" ;;
        monitor) phase_label="BACKUP TIMINGS" ;;
        clean-all) phase_label="CLEANUP" ;;
        windows-golden-image) phase_label="WINDOWS GOLDEN IMAGE" ;;
        *) phase_label="$(printf '%s' "${WORKFLOW_NAME:-WORKFLOW}" | tr '[:lower:]-' '[:upper:] ')" ;;
      esac
      printf '\n────────────────────────────────────────────────────────\n %s\n────────────────────────────────────────────────────────\n' \
        "$phase_label" >&2
      WORKFLOW_PHASE_PRINTED=true
    fi
    printf '  [%s] %s\n' "$CURRENT_STEP" >&2
  fi
}

workflow_action() {
  local timestamp
  timestamp="$(workflow_timestamp)"
  workflow_record_log action "$timestamp" "$1"
  if [[ "$DEBUG" == true ]]; then
    printf '  [%s] → %s\n' "$timestamp" "$1" >&2
  fi
}

workflow_status() {
  local timestamp
  timestamp="$(workflow_timestamp)"
  workflow_record_log status "$timestamp" "$1"
  if [[ "$DEBUG" == true ]]; then
    printf '  [%s] [status] %s\n' "$timestamp" "$1" >&2
  fi
}

workflow_progress() {
  local timestamp
  timestamp="$(workflow_timestamp)"
  workflow_record_log progress "$timestamp" "$1"
  if [[ "$DEBUG" == true ]]; then
    printf '  [%s] [status] %s\n' "$timestamp" "$1" >&2
  fi
}

workflow_debug() {
  [[ "$DEBUG" == true ]] || return 0
  local timestamp
  timestamp="$(workflow_timestamp)"
  workflow_record_log debug "$timestamp" "$1"
  printf '  [%s] [debug] %s\n' "$timestamp" "$1" >&2
}

workflow_success() {
  local timestamp
  timestamp="$(workflow_timestamp)"
  workflow_record_log success "$timestamp" "$1"
  if [[ "$DEBUG" == true ]]; then
    printf '  [%s] ✓ %s\n' "$timestamp" "$1" >&2
  else
    printf '        ✓ %s\n' "$1" >&2
  fi
}

workflow_warning() {
  local timestamp
  timestamp="$(workflow_timestamp)"
  workflow_record_log warning "$timestamp" "$1"
  if [[ "$DEBUG" == true ]]; then
    printf '  [%s] [warning] %s\n' "$timestamp" "$1" >&2
  else
    printf '        ⚠ %s\n' "$1" >&2
  fi
}

workflow_failed() {
  local status=$? timestamp
  timestamp="$(workflow_timestamp)"
  workflow_record_log failure "$timestamp" "$CURRENT_STEP (exit $status)"
  if [[ "$DEBUG" == true ]]; then
    printf '  [%s] ✗ Failed: %s (exit %d)\n' "$timestamp" "$CURRENT_STEP" "$status" >&2
  else
    printf '        ✗ %s failed (exit %d)\n' "$CURRENT_STEP" "$status" >&2
  fi
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
  printf '%s/%s/run.json' "$RUNS_ROOT_DIR" "$1"
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
  RUN_DIR="$RUNS_ROOT_DIR/$RUN_ID"
  VM_INFO_PATH="$RUN_DIR/run.json"
  REPORT_DIR="$RUN_DIR"
}

initialize_run_directory() {
  if [[ -e "$RUN_DIR" ]]; then
    printf '[vm-cbt] Run ID %s already has artifacts at %s; run IDs are immutable and cannot be reused.\n' \
      "$RUN_ID" "$RUN_DIR" >&2
    return 1
  fi
  mkdir -p "$RUN_DIR/fragments" "$RUN_DIR/logs" "$RUN_DIR/evidence" "$RUN_DIR/restore"
}

# Resolve one immutable run ID and reject accidental resource reuse.
new_run_id() {
  if [[ -n "${RUN_ID:-}" ]]; then
    if ! valid_run_id "$RUN_ID"; then
      printf '[vm-cbt] Run ID must be lowercase alphanumeric with internal hyphens and at most 40 characters (got: %s).\n' "$RUN_ID" >&2
      exit 1
    fi
    set_resource_names
    if [[ -e "$RUN_DIR" ]]; then
      printf '[vm-cbt] Run ID %s already has artifacts at %s; choose a new NAME.\n' \
        "$RUN_ID" "$RUN_DIR" >&2
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
        printf '[vm-cbt] Run ID %s already owns or conflicts with %s/%s in namespace %s; choose another NAME.\n' \
          "$RUN_ID" "$kind" "$resource" "$NAMESPACE" >&2
        exit 1
      fi
    done
  else
    RUN_ID="$(generate_run_id)"
    set_resource_names
    while [[ -e "$RUN_DIR" ]]; do
      RUN_ID="$(generate_run_id)"
      set_resource_names
    done
  fi
  initialize_run_directory
  workflow_action "Using run ID $RUN_ID"
}

# Existing lifecycle commands must name their run explicitly. VM=vm-<run-id>
# is the user-facing selector; RUN_ID is used by the internal Make pipeline.
load_run_id() {
  if [[ -z "${RUN_ID:-}" ]]; then
    if [[ -n "${VM:-}" ]]; then
      if [[ "$VM" != vm-* ]]; then
        printf 'VM must be a workflow VM name in the form vm-<run-id> (got: %s).\n' "$VM" >&2
        return 1
      fi
      RUN_ID="${VM#vm-}"
    else
      printf 'Set VM=vm-<run-id> or RUN_ID=<run-id> to select an existing lifecycle.\n' >&2
      return 1
    fi
  fi
  if ! valid_run_id "$RUN_ID"; then
    printf 'Run ID must be lowercase alphanumeric with internal hyphens and at most 40 characters (got: %s).\n' "$RUN_ID" >&2
    return 1
  fi
  set_resource_names
}


# Write one named JSON fragment for the current run; scripts pass valid JSON.
write_report_fragment() {
  local fragment_name="$1" json_content="$2"
  mkdir -p "$REPORT_DIR/fragments"
  printf '%s' "$json_content" | jq '.' > "$REPORT_DIR/fragments/$fragment_name.json"
}
write_backup_status_evidence() {
  local backup_name="$1" backup_status_json="$2" evidence_path tmp_path
  if ! jq -e --arg backup_name "$backup_name" \
      '.backupName == $backup_name' <<<"$backup_status_json" >/dev/null; then
    printf ''
    return 0
  fi
  evidence_path="evidence/${backup_name}-vm-backup-status.json"
  tmp_path="$RUN_DIR/${evidence_path}.tmp.$$"
  jq '.' <<<"$backup_status_json" > "$tmp_path"
  mv -f "$tmp_path" "$RUN_DIR/$evidence_path"
  printf '%s' "$evidence_path"
}

vm_info_load() {
  local run_id="$1" saved_vm_uid vm_json current_vm_uid
  if ! valid_run_id "$run_id"; then
    printf 'Invalid run ID: %s\n' "$run_id" >&2
    return 1
  fi
  RUN_ID="$run_id"
  set_resource_names
  if [[ ! -r "$VM_INFO_PATH" ]] ||
     ! jq -e --arg run_id "$run_id" '
       .schema_version == 1 and .run_id == $run_id and
       .vm_name == ("vm-" + $run_id) and
       (.namespace | type == "string" and length > 0) and
       (.vm_uid | type == "string" and length > 0) and
       .status != "cleaned"
     ' "$VM_INFO_PATH" >/dev/null; then
    printf 'Missing or invalid run metadata for run %s: %s\n' "$run_id" "$VM_INFO_PATH" >&2
    return 1
  fi
  NAMESPACE="$(jq -r '.namespace' "$VM_INFO_PATH")"
  VM_OS="$(jq -r '.os_profile' "$VM_INFO_PATH")"
  MANIFEST_VARIANT="$(jq -r '.manifest_variant' "$VM_INFO_PATH")"
  set_vm_os_profile
  set_manifest_variant_settings
  GUEST_BASE_FILE_COUNT="$(jq -r '.guest.baseline.file_count' "$VM_INFO_PATH")"
  GUEST_INCREMENTAL_FILE_COUNT="$(jq -r '.guest.incremental_file_count_per_pass' "$VM_INFO_PATH")"
  GUEST_INCREMENTAL_PASSES="$(jq -r '.incremental_passes_total' "$VM_INFO_PATH")"
  GUEST_FILE_SIZE_MIN_MIB="$(jq -r '.guest.size_range_mib.min_inclusive' "$VM_INFO_PATH")"
  GUEST_FILE_SIZE_MAX_MIB="$(jq -r '.guest.size_range_mib.max_inclusive' "$VM_INFO_PATH")"
  if [[ "$VM_OS" == windows ]]; then
    GUEST_WORKLOAD_DIR="$WINDOWS_GUEST_WORKLOAD_DIR"
    RESTORE_WORKLOAD_MOUNT_DIR="/cbt-data/workload"
  else
    GUEST_WORKLOAD_DIR="$LINUX_GUEST_WORKLOAD_DIR"
    RESTORE_WORKLOAD_MOUNT_DIR="$LINUX_GUEST_WORKLOAD_DIR"
  fi
  saved_vm_uid="$(jq -r '.vm_uid' "$VM_INFO_PATH")"
  if ! vm_json="$(oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o json 2>/dev/null)"; then
    printf 'Cannot read VM %s in namespace %s for run %s.\n' "$VM_NAME" "$NAMESPACE" "$run_id" >&2
    return 1
  fi
  current_vm_uid="$(jq -r '.metadata.uid // empty' <<< "$vm_json")"
  if [[ -z "$current_vm_uid" || "$current_vm_uid" != "$saved_vm_uid" ]]; then
    printf 'VM identity mismatch for run %s: saved UID=%s, current UID=%s.\n' \
      "$run_id" "$saved_vm_uid" "${current_vm_uid:-missing}" >&2
    return 1
  fi
}

vm_info_initialize() {
  local vm_uid="$1" manifest tmp_path now
  VM_INFO_PATH="$(vm_info_path "$RUN_ID")"
  manifest="$(workload_manifest_path)"
  tmp_path="${VM_INFO_PATH}.tmp.$$"
  now="$(workflow_timestamp)"
  if [[ -z "$vm_uid" ]]; then
    printf 'Cannot initialize run metadata without a Kubernetes VM UID for %s.\n' "$VM_NAME" >&2
    return 1
  fi
  if [[ -e "$VM_INFO_PATH" ]]; then
    printf 'Run metadata already exists and cannot be replaced: %s\n' "$VM_INFO_PATH" >&2
    return 1
  fi
  jq -n \
    --arg run_id "$RUN_ID" \
    --arg vm_name "$VM_NAME" \
    --arg vm_uid "$vm_uid" \
    --arg namespace "$NAMESPACE" \
    --arg os_profile "$VM_OS" \
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
    '{schema_version: 1, run_id: $run_id, vm_name: $vm_name, vm_uid: $vm_uid,
      namespace: $namespace, os_profile: $os_profile, manifest_variant: $manifest_variant,
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
    printf 'Cannot update missing run metadata: %s\n' "$VM_INFO_PATH" >&2
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
# Save a run-owned pod log to runs/<run-id>/logs/<log_filename>.
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
  workflow_action "Ensuring the guest SSH key is available at $GUEST_KEY"
  mkdir -p "$(dirname "$GUEST_KEY")"
  if [[ ! -f "$GUEST_KEY" ]]; then
    workflow_warning "Guest private key missing; generating a new key at $GUEST_KEY"
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

  workflow_status "Connecting to guest $SSH_SERVICE over a temporary local port-forward"
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
    workflow_action "oc port-forward -n $NAMESPACE service/$SSH_SERVICE :22 (attempt $attempt/30)"
    : > "$forward_log"
    oc_cmd port-forward -n "$NAMESPACE" "service/$SSH_SERVICE" :22 >"$forward_log" 2>&1 &
    forward_pid=$!
    port=
    for ((wait_attempt = 1; wait_attempt <= 30; wait_attempt++)); do
      port="$(extract_forwarded_port "$forward_log")"
      if [[ -n "$port" ]]; then
        workflow_action "Port-forward ready on 127.0.0.1:$port"
        break
      fi
      if ! kill -0 "$forward_pid" 2>/dev/null; then
        break
      fi
      sleep 1
    done

    if [[ -n "$port" ]]; then
      workflow_action "ssh $GUEST_USER@127.0.0.1:$port (probe, then guest command)"
      if probe_guest_ssh "$port" "$probe_log"; then
        workflow_status "Guest SSH is ready after attempt $attempt/30"
        if ssh_guest_command "$port" "$guest_command"; then
          cleanup
          return 0
        fi
        cleanup
        return 1
      fi
      # Authentication failures are terminal; startup failures can recover.
      if grep -q 'Permission denied' "$probe_log"; then
        cat "$probe_log" >&2
        cleanup
        return 1
      fi
      if ((attempt % 5 == 0)); then
        workflow_status "Guest SSH probe failed; retrying (attempt $attempt/30)"
      fi
    elif ((attempt % 5 == 0)); then
      workflow_status "Guest SSH port-forward is not ready (attempt $attempt/30)"
    fi

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

  workflow_action "Backup watcher started: VM=$VM_NAME backup=$backup_name requested_type=$expected_type PVC=${pvc_name:-unknown}"
  if [[ -n "$base_checkpoint" ]]; then
    workflow_action "Backup $backup_name uses base checkpoint $base_checkpoint"
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
      workflow_progress "$line"
      last_signature="$signature"
      last_heartbeat="$SECONDS"
      if [[ "$DEBUG" == true ]]; then
        workflow_debug "backup=$backup_name conditions=$(jq -c '.status.conditions // []' <<<"$backup_json") vmi_backup_status=$runtime_status"
      fi
    elif ((SECONDS - last_heartbeat >= 30)); then
      workflow_progress "Backup heartbeat: $line"
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
    oc_cmd wait "vmbackup/$backup_name" -n "$NAMESPACE" --for=condition=Done --timeout=20m >/dev/null
    return
  fi
  if [[ -z "$pvc_name" ]]; then
    pvc_name="$(get_backup_pvc_name "$backup_name" 2>/dev/null || true)"
  fi

  watch_backup_status "$backup_name" "$pvc_name" "$expected_type" "$base_checkpoint" "$$" &
  watcher_pid=$!
  if oc_cmd wait "vmbackup/$backup_name" -n "$NAMESPACE" --for=condition=Done --timeout=20m >/dev/null; then
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


# Extract the hash from a `sha256sum <file>` line ("<hash>  <file>").
extract_sha256() {
  awk '{print $1; exit}'
}

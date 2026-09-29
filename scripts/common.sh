#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2034
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-}}"
GUEST_KEY="${GUEST_KEY:-$ROOT_DIR/keys/id_ed25519}"
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
# Guest mutation used to prove the incremental backup carries real changes.
# shellcheck disable=SC2034
CBT_INCREMENTAL_MARKER_LINE="This line was added after the full backup."
# shellcheck disable=SC2034
GUEST_HELLO_FILE="/home/$GUEST_USER/hello.txt"
# Sizes (MiB) of the random payload written to the guest file at setup and
# appended before the incremental backup, so CBT tracks a real block delta
# instead of a single text line.
# shellcheck disable=SC2034
GUEST_DATA_SIZE_MB="${GUEST_DATA_SIZE_MB:-64}"
# shellcheck disable=SC2034
GUEST_INCREMENTAL_DATA_SIZE_MB="${GUEST_INCREMENTAL_DATA_SIZE_MB:-32}"

if [[ -n "$KUBECONFIG_PATH" ]]; then
  export KUBECONFIG="$KUBECONFIG_PATH"
fi

oc_cmd() {
  oc "$@"
}

set -E
CURRENT_STEP="workflow startup"

workflow_step() {
  CURRENT_STEP="$1"
  printf '\n[%s] %s\n' "$WORKFLOW_NAME" "$CURRENT_STEP" >&2
}

workflow_action() {
  printf '  → %s\n' "$1" >&2
}

workflow_success() {
  printf '  ✓ %s\n' "$1" >&2
}

workflow_failed() {
  local status=$?
  printf '  ✗ Failed: %s (exit %d)\n' "$CURRENT_STEP" "$status" >&2
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
  INCREMENTAL_BACKUP_NAME="vm-incremental-${RUN_ID}"
  # shellcheck disable=SC2034
  INCREMENTAL_BACKUP_PVC_NAME="vm-incremental-pvc-${RUN_ID}"
  # shellcheck disable=SC2034
  RESTORE_POD_NAME="vm-restore-verify-${RUN_ID}"
}

# Generate one new run ID (random adjective-noun pair, plus a short random
# hex tag since the 100 adjective/noun combinations alone collide too often
# across repeated runs) and persist it so every later script invocation in
# the same E2E run reuses it.
new_run_id() {
  mkdir -p "$STATE_DIR"
  local adjective noun tag
  adjective="${RUN_ID_ADJECTIVES[RANDOM % ${#RUN_ID_ADJECTIVES[@]}]}"
  noun="${RUN_ID_NOUNS[RANDOM % ${#RUN_ID_NOUNS[@]}]}"
  # od+tr avoids piping into `head -c`, which would SIGPIPE the upstream
  # reader and trip `set -o pipefail` under the ERR trap.
  tag="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  RUN_ID="${adjective}-${noun}-${tag}"
  printf '%s' "$RUN_ID" > "$RUN_ID_FILE"
  set_resource_names
  printf '[vm-cbt] New run ID: %s\n' "$RUN_ID" >&2
}

# Load the run ID persisted by new_run_id (or an explicitly exported RUN_ID)
# for scripts that must operate on an already-created run's resources.
load_run_id() {
  if [[ -z "${RUN_ID:-}" ]]; then
    if [[ ! -f "$RUN_ID_FILE" ]]; then
      printf 'No active run ID found in %s. Run `make vm-setup` (or `make e2e`) first.\n' "$RUN_ID_FILE" >&2
      return 1
    fi
    RUN_ID="$(cat "$RUN_ID_FILE")"
  fi
  set_resource_names
}

# Generate one new report ID (UTC timestamp, human-sortable) and persist it
# so every later script invocation in the same E2E run appends to the same
# report/<REPORT_ID>/ directory. Kept separate from RUN_ID so the fixed
# Kubernetes resource-naming contract never changes.
new_report_id() {
  mkdir -p "$STATE_DIR"
  REPORT_ID="run_$(date -u +%Y%m%dT%H%M%SZ)"
  printf '%s' "$REPORT_ID" > "$REPORT_ID_FILE"
  REPORT_DIR="$REPORT_ROOT_DIR/$REPORT_ID"
  mkdir -p "$REPORT_DIR/fragments"
  printf '[vm-cbt] New report ID: %s\n' "$REPORT_ID" >&2
}

# Load the report ID persisted by new_report_id for scripts that must append
# to an already-created run's report.
load_report_id() {
  if [[ -z "${REPORT_ID:-}" ]]; then
    if [[ ! -f "$REPORT_ID_FILE" ]]; then
      printf 'No active report ID found in %s. Run `make vm-setup` (or `make e2e`) first.\n' "$REPORT_ID_FILE" >&2
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

wait_for_backup_done() {
  local backup_name="$1"
  oc_cmd wait "vmbackup/$backup_name" \
    -n "$NAMESPACE" \
    --for=condition=Done \
    --timeout=20m
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

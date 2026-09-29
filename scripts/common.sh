#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2034
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${KUBECONFIG:-}}"
GUEST_KEY="${GUEST_KEY:-${HOME:-$ROOT_DIR}/.local/share/vm-cbt-demo/id_ed25519}"
# These constants are consumed by scripts that source this file.
# shellcheck disable=SC2034
NAMESPACE="vm-cbt-demo"
# shellcheck disable=SC2034
VM_NAME="vm-cbt-demo"
GUEST_USER="cbt-demo"
SSH_SERVICE="vm-cbt-ssh"
# shellcheck disable=SC2034
TRACKER_NAME="hello-tracker"
# shellcheck disable=SC2034
FULL_BACKUP_NAME="hello-full"
# shellcheck disable=SC2034
INCREMENTAL_BACKUP_NAME="hello-incremental"

if [[ -n "$KUBECONFIG_PATH" ]]; then
  export KUBECONFIG="$KUBECONFIG_PATH"
fi

oc_cmd() {
  oc "$@"
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command_name" >&2
    return 1
  fi
}

require_command oc
if [[ -n "$KUBECONFIG_PATH" && ! -r "$KUBECONFIG_PATH" ]]; then
  printf 'Kubeconfig is not readable: %s\n' "$KUBECONFIG_PATH" >&2
  exit 1
fi

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
    printf '[guest-ssh] Starting port-forward attempt %d/30.\n' "$attempt" >&2
    : > "$forward_log"
    oc_cmd port-forward -n "$NAMESPACE" "service/$SSH_SERVICE" :22 >"$forward_log" 2>&1 &
    forward_pid=$!
    port=
    for ((wait_attempt = 1; wait_attempt <= 30; wait_attempt++)); do
      port="$(sed -n 's/^Forwarding from 127[.]0[.]0[.]1:\([0-9][0-9]*\) -> 22$/\1/p' "$forward_log" | sed -n '1p')"
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
      ssh -i "$GUEST_KEY" -p "$port" \
        -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$GUEST_USER@127.0.0.1" true >/dev/null 2>"$probe_log" && {
          if ssh -i "$GUEST_KEY" -p "$port" \
            -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            "$GUEST_USER@127.0.0.1" "$guest_command"; then
            cleanup
            return 0
          fi
          cleanup
          return 1
        }
      printf '[guest-ssh] SSH probe failed; retrying.\n' >&2
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

#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s <namespace|-> <resource> <name|label|field> <selector> <output.jsonl> <ready-file>\n' "$0" >&2
  printf 'Use namespace - for a cluster-scoped resource; name selects metadata.name without requiring the object to exist yet.\n' >&2
  printf 'WATCH_MAX_SECONDS bounds how long the armed watch may run (default 0: no self-termination).\n' >&2
  printf 'Exit: 0 not used as success; 1 watch ended/failed; 2 usage or environment error; 3 WATCH_MAX_SECONDS reached.\n' >&2
}

if (($# != 6)); then usage; exit 2; fi
namespace="$1"
resource="$2"
mode="$3"
selector="$4"
output="$5"
ready="$6"
if [[ -z "$namespace" || -z "$resource" || -z "$selector" || -z "$output" || -z "$ready" ]]; then
  usage
  exit 2
fi
if [[ ! -d "$(dirname "$output")" || ! -d "$(dirname "$ready")" ]]; then
  printf 'Watch output and ready-file parent directories must already exist.\n' >&2
  exit 2
fi
if [[ -e "$output" || -e "$output.baseline.json" || -e "$output.stderr" || -e "$ready" ]]; then
  printf 'Watch output or ready file already exists; use new run-scoped paths.\n' >&2
  exit 2
fi
if ! command -v oc >/dev/null 2>&1; then
  printf 'Required command not found: oc\n' >&2
  exit 127
fi
kubeconfig="${KUBECONFIG_PATH:-${KUBECONFIG:-}}"
if [[ -z "$kubeconfig" || ! -r "$kubeconfig" ]]; then
  printf 'An approved, readable host-local KUBECONFIG_PATH or KUBECONFIG is required.\n' >&2
  exit 2
fi
export KUBECONFIG="$kubeconfig"

WATCH_MAX_SECONDS="${WATCH_MAX_SECONDS:-0}"
if ! [[ "$WATCH_MAX_SECONDS" =~ ^[0-9]+$ ]]; then
  printf 'Invalid WATCH_MAX_SECONDS: %s (expected a non-negative integer of seconds; 0 disables the bound).\n' "$WATCH_MAX_SECONDS" >&2
  exit 2
fi

scope=()
if [[ "$namespace" != - ]]; then scope+=(-n "$namespace"); fi
case "$mode" in
  name) scope+=(--field-selector "metadata.name=$selector") ;;
  label) scope+=(-l "$selector") ;;
  field) scope+=(--field-selector "$selector") ;;
  *) usage; exit 2 ;;
esac

# The same child environment must authenticate before any readiness claim.
if ! oc get "$resource" "${scope[@]}" -o json > "$output.baseline.json" 2> "$output.stderr"; then
  printf 'Scoped API preflight failed; observer is not armed.\n' >&2
  exit 1
fi
auth_scope=()
if [[ "$namespace" != - ]]; then auth_scope=(-n "$namespace"); fi
if ! oc auth can-i watch "$resource" "${auth_scope[@]}" > /dev/null 2>> "$output.stderr"; then
  printf 'Scoped API watch permission check failed; observer is not armed.\n' >&2
  exit 1
fi
: > "$output"
: > "$output.stderr"
watch_pid=''
marker=''
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  rm -f -- "$ready"
  if [[ -n "$marker" ]]; then rm -f -- "$marker"; fi
  if [[ -n "$watch_pid" ]]; then
    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
  fi
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
oc get "$resource" "${scope[@]}" --watch --output-watch-events -o json < /dev/null >> "$output" 2>> "$output.stderr" &
watch_pid=$!

# This is a startup health check, not an injection timer or evidence of an event.
for ((attempt = 0; attempt < 10; attempt++)); do
  sleep 0.1
  if ! kill -0 "$watch_pid" 2>/dev/null || [[ -s "$output.stderr" ]]; then
    printf 'Scoped watch failed before readiness; inspect its stderr file.\n' >&2
    exit 1
  fi
done
marker="$ready.tmp.$$"
printf 'armed_utc=%s\nnamespace=%s\nresource=%s\nselector_mode=%s\nselector=%s\nwatch_pid=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$namespace" "$resource" "$mode" "$selector" "$watch_pid" > "$marker"
mv -- "$marker" "$ready"

# A watch that later exits creates an observation gap; never silently reconnect.
# WATCH_MAX_SECONDS bounds the armed lifetime so a caller that forgets to stop
# the watch cannot leave it polling the API server forever.
if ((WATCH_MAX_SECONDS > 0)); then
  watch_deadline=$((SECONDS + WATCH_MAX_SECONDS))
  while kill -0 "$watch_pid" 2>/dev/null; do
    if ((SECONDS >= watch_deadline)); then
      printf 'Scoped watch reached WATCH_MAX_SECONDS=%s; self-terminating and revoking readiness.\n' "$WATCH_MAX_SECONDS" >&2
      exit 3
    fi
    sleep 1
  done
fi
if wait "$watch_pid"; then
  printf 'Scoped watch ended unexpectedly; readiness revoked.\n' >&2
else
  printf 'Scoped watch failed; readiness revoked.\n' >&2
fi
watch_pid=''
exit 1

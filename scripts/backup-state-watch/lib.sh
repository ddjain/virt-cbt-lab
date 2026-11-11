#!/usr/bin/env bash
# Shared library for backup-state-watch: checkpoint emission, stream
# management, and incremental file scanning. Sourced by the main script and
# the source modules; runs in the main shell so state (fired/terminal maps,
# stream registry) is shared.
#
# Expects from the main script: STREAM_DIR, WANT_CHECKPOINT (may be empty).

declare -A fired=()     # "backup:checkpoint" -> 1 (already printed)
declare -A terminal=()  # backup -> 1 once Done=True observed
streams_pids=()

print_checkpoint() {
  # $1 backup object name, $2 checkpoint, $3 human detail
  local key="$1:$2"
  [[ -n "${fired[$key]:-}" ]] && return 0
  fired[$key]=1
  printf '[%s] %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$1" "$2" "$3"
  if [[ -n "$WANT_CHECKPOINT" && "$2" == "$WANT_CHECKPOINT" ]]; then
    cleanup_streams
    exit 0
  fi
}

start_stream() {
  # start_stream <output-file> <oc args...>
  local out="$1"; shift
  "oc_cmd" "$@" >"$STREAM_DIR/$out" 2>/dev/null &
  streams_pids+=("$!")
}

cleanup_streams() {
  local p
  for p in "${streams_pids[@]:-}"; do
    kill "$p" 2>/dev/null || true
  done
  if [[ -z "${WATCH_RAW_DIR:-}" ]]; then
    rm -rf "$STREAM_DIR"
  fi
}

declare -A offset=()  # stream file -> lines already consumed

new_lines() {
  # new_lines <file>: print lines added since the last call
  local f="$STREAM_DIR/$1" n start
  [[ -r "$f" ]] || return 0
  n="$(grep -c "" "$f" 2>/dev/null || true)"
  n="${n:-0}"
  start=$(( ${offset[$1]:-0} + 1 ))
  offset[$1]="$n"
  ((n >= start)) && sed -n "${start},${n}p" "$f"
  return 0
}

is_watched_backup() {
  # Set by the main script: FULL_BACKUP_NAME, watch_backup_prefix
  [[ "$1" == "$FULL_BACKUP_NAME" || "$1" == "${watch_backup_prefix}"* ]]
}

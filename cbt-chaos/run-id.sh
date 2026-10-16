#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s <vm-name> <note-slug> <iteration>\n' "$0"
  printf 'Print a UTC chaos attempt ID: dd-mm-yyyy-hh-mm-ss-<vm-name>-<note>-iteration-<number>.\n'
  printf 'This is an evidence directory ID, not a Kubernetes lifecycle RUN_ID.\n'
}

if [[ "${1:-}" == --help && $# == 1 ]]; then
  usage
  exit 0
fi
if (($# != 3)); then usage >&2; exit 2; fi
vm_name="$1"
note="$2"
iteration="$3"
if [[ ! "$vm_name" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
  printf 'VM name must be the exact lowercase DNS name, without spaces or path separators.\n' >&2
  exit 2
fi
if [[ ! "$note" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
  printf 'Note must be a nonempty lowercase alphanumeric slug with internal hyphens.\n' >&2
  exit 2
fi
if [[ ! "$iteration" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Iteration must be a positive integer without leading zeros.\n' >&2
  exit 2
fi
run_id="$(date -u +%d-%m-%Y-%H-%M-%S)-${vm_name}-${note}-iteration-${iteration}"
if ((${#run_id} > 255)); then
  printf 'Chaos run ID exceeds the 255-character directory-name limit; shorten the note.\n' >&2
  exit 2
fi
printf '%s\n' "$run_id"

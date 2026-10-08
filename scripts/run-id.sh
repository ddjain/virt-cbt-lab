#!/usr/bin/env bash
set -euo pipefail
# Shared run ID generation for Make and the Bash workflow scripts.
RUN_ID_ADJECTIVES=(dark silent brave calm fuzzy happy wild gentle bright swift)
RUN_ID_NOUNS=(forest river wolf meadow penguin mountain falcon ocean tiger valley)
valid_run_id() {
  [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] && ((${#1} <= 40))
}


generate_run_id() {
  local adjective noun tag
  adjective="${RUN_ID_ADJECTIVES[RANDOM % ${#RUN_ID_ADJECTIVES[@]}]}"
  noun="${RUN_ID_NOUNS[RANDOM % ${#RUN_ID_NOUNS[@]}]}"
  # Avoid `head -c`: its upstream may SIGPIPE under `set -o pipefail`.
  tag="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s-%s-%s' "$adjective" "$noun" "$tag"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  generate_run_id
  printf '\n'
fi

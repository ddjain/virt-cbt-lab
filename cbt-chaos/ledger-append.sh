#!/usr/bin/env bash
# ledger-append.sh — safe single-line JSON event writer for run ledgers.
#
# The Lead is the ONLY writer of ledger.jsonl. This helper guarantees every
# appended line is valid JSON with correctly escaped strings (the r03 run
# produced an invalid line-8 with unescaped quotes; see learnings
# 2026-10-15). It never rewrites or deletes existing lines (append-only).
#
# Usage: ledger-append.sh <ledger.jsonl> <actor> <event> <phase|-> [detail] [ref...]
#   phase "-"  => event carries no phase field (e.g. post-close approvals)
#   detail "-" => omitted
#   refs are optional additional "refs" array entries (paths)
#
# Exit: 0 appended; 1 validation failed; 2 usage.
set -euo pipefail

if [[ $# -lt 4 ]]; then
  printf 'usage: %s <ledger.jsonl> <actor> <event> <phase|-> [detail|-] [ref...]\n' "$0" >&2
  exit 2
fi


LEDGER=$1; ACTOR=$2; EVENT=$3; PHASE=$4
shift 4
DETAIL="-"
refs=()
if [[ $# -gt 0 ]]; then
  DETAIL=$1
  shift
  refs=("$@")
fi

if [[ ! -f "$LEDGER" ]]; then
  printf 'ledger-append: no such ledger: %s\n' "$LEDGER" >&2
  exit 2
fi

# Build the JSON line with jq so all strings are escaped correctly.
# refs are passed as a --jsonarray so they never collide with named args.
line=$(jq -cn \
  --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg actor "$ACTOR" \
  --arg event "$EVENT" \
  --arg phase "$PHASE" \
  --arg detail "$DETAIL" \
  --argjson refs "$(if [[ ${#refs[@]} -gt 0 ]]; then printf '%s\n' "${refs[@]}" | jq -R . | jq -s .; else echo '[]'; fi)" \
  '{utc: $utc, actor: $actor, event: $event}
   + (if $phase != "-" then {phase: $phase} else {} end)
   + (if $detail != "-" then {detail: $detail} else {} end)
   + (if ($refs | length) > 0 then {refs: $refs} else {} end)')

# Verify the line parses before committing (append-only: never rewrite).
if ! jq -e . <<<"$line" >/dev/null 2>&1; then
  printf 'ledger-append: generated line failed JSON validation (bug)\n' >&2
  exit 1
fi
printf '%s\n' "$line" >> "$LEDGER"
printf 'ledger-append: ok\n'

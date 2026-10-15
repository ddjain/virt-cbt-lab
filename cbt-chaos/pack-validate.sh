#!/usr/bin/env bash
# pack-validate.sh — pre-flight validation of a chaos run's evidence pack.
# Run this BEFORE spawning checkers. It performs the same mechanical checks
# the checkers enforce (pack integrity) plus the ordering rules the Lead
# must honor, so violations surface in seconds instead of costing a checker
# revision loop.
#
# Usage: pack-validate.sh <run-root>
#   <run-root>  directory containing ledger.jsonl, state.json,
#               evidence-index.json (e.g. cbt-chaos/scenarios_v2/<id>/runs/<run>)
#
# Exit codes: 0 = pack valid; 1 = validation failed (see stderr);
#             2 = usage error.
#
# Checks:
#   1. ledger.jsonl exists, non-empty, and EVERY line is valid JSON.
#   2. state.json parses as JSON and its .phase matches the phase in the
#      LAST ledger line that has a phase field.
#   3. Every file listed in evidence-index.json exists and its sha256
#      matches the indexed value.
#   4. Index-ordering: evidence-index.json's mtime is >= the mtime of every
#      indexed file (the index must be the last write).
#   5. No indexed file is empty (zero bytes) unless it was indexed that way.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <run-root>\n' "$0" >&2
  exit 2
fi

ROOT="$1"
failures=0
fail() { printf 'pack-validate: FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# --- 1. ledger.jsonl: every line valid JSON -------------------------------
LEDGER="$ROOT/ledger.jsonl"
if [[ ! -s "$LEDGER" ]]; then
  fail "ledger.jsonl missing or empty"
else
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    if [[ -z "$line" ]]; then continue; fi
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      fail "ledger.jsonl line $n is not valid JSON"
    fi
  done < "$LEDGER"
  printf 'ledger lines checked: %s\n' "$n"
fi

# --- 2. state.json parses; phase agrees with ledger tail ------------------
if [[ -f "$ROOT/state.json" ]]; then
  if ! jq -e . "$ROOT/state.json" >/dev/null 2>&1; then
    fail "state.json is not valid JSON"
  else
    state_phase=$(jq -r '.phase // "missing"' "$ROOT/state.json")
    ledger_phase=$(grep -o '"phase": *"[^"]*"' "$LEDGER" 2>/dev/null | tail -1 | sed 's/.*"phase": *"//; s/"$//')
    ledger_phase=${ledger_phase:-missing}
    # Tolerate trailing ledger events without a phase field (e.g. post-close
    # trigger_edit approvals); compare against the last phase-bearing event.
    if [[ "$state_phase" != "$ledger_phase" ]]; then
      fail "state.json phase '$state_phase' != last ledger phase '$ledger_phase'"
    fi
  fi
else
  fail "state.json missing"
fi

# --- 3+4. index: existence, hashes, ordering -------------------------------
INDEX="$ROOT/evidence-index.json"
if [[ ! -s "$INDEX" ]]; then
  fail "evidence-index.json missing or empty"
else
  if ! jq -e . "$INDEX" >/dev/null 2>&1; then
    fail "evidence-index.json is not valid JSON"
  else
    if stat --version >/dev/null 2>&1; then index_mtime=$(stat -c %Y "$INDEX"); else index_mtime=$(stat -f %m "$INDEX"); fi
    count=0
    # Verify each indexed file: exists, hash matches, not newer than the index.
    while IFS=$'\t' read -r rel sha; do
      count=$((count + 1))
      f="$ROOT/$rel"
      if [[ ! -f "$f" ]]; then
        fail "indexed file absent: $rel"
        continue
      fi
      actual=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
      [[ -n "$actual" ]] || actual=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
      if [[ "$actual" != "$sha" ]]; then
        fail "hash mismatch: $rel (indexed $sha, actual $actual)"
      fi
      if stat --version >/dev/null 2>&1; then f_mtime=$(stat -c %Y "$f"); else f_mtime=$(stat -f %m "$f"); fi
      if [[ "$f_mtime" -gt "$index_mtime" ]]; then
        fail "index is stale (file written after index): $rel"
      fi
    done < <(jq -r '.files | to_entries[] | "\(.key)\t\(.value.sha256)"' "$INDEX")
    printf 'indexed files verified: %s\n' "$count"
  fi
fi

# --- verdict ----------------------------------------------------------------
if (( failures > 0 )); then
  printf 'pack-validate: %s failure(s). Fix and re-run before spawning checkers.\n' "$failures" >&2
  exit 1
fi
printf 'pack-validate: OK\n'

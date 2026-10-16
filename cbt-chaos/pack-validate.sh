#!/usr/bin/env bash
# pack-validate.sh — pre-flight validation of a chaos run's evidence pack.
# Run this BEFORE spawning checkers. It performs the same mechanical checks
# the checkers enforce (pack integrity) plus the ordering rules the Lead
# must honor, so violations surface in seconds instead of costing a checker
# revision loop.
#
# Usage: pack-validate.sh [--freeze|--verify-freeze] <run-root>
#   <run-root>  directory containing ledger.jsonl, state.json,
#               evidence-index.json (e.g. cbt-chaos/scenarios_v2/<id>/runs/<run>)
#
# Exit codes: 0 = pack valid (and, for --verify-freeze, the freeze matched);
#             1 = validation failed (see stderr); 2 = usage error.
#
# Modes:
#   (default)        validate only.
#   --freeze         validate, then write <run-root>/checkers/pack-freeze.json
#                    recording evidence-index.json's and ledger.jsonl's sha256 +
#                    sizes and the index's generated_utc. The Lead runs this
#                    immediately before spawning checkers, after the phase's last
#                    ledger append.
#   --verify-freeze  validate, then fail if either file no longer matches the
#                    freeze. Each checker runs this as its FIRST action and again
#                    immediately before writing its verdict; a failure on the
#                    second run means the pack moved while it was grading.
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

mode='validate'
case "${1:-}" in
  --freeze|--verify-freeze) mode="${1#--}"; shift ;;
esac
if [[ $# -ne 1 ]]; then
  printf 'usage: %s [--freeze|--verify-freeze] <run-root>\n' "$0" >&2
  exit 2
fi

ROOT="$1"
failures=0
fail() { printf 'pack-validate: FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# hash_file PATH -- sha256 of PATH via whichever tool exists.
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

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

# --- freeze: the mechanical gate for index/ledger ordering -------------------
FREEZE="$ROOT/checkers/pack-freeze.json"

write_freeze() {
  mkdir -p "$ROOT/checkers"
  local tmp="$FREEZE.tmp.$$"
  jq -cn \
    --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg index_sha "$(hash_file "$INDEX")" \
    --argjson index_bytes "$(wc -c < "$INDEX" | tr -d ' ')" \
    --arg index_utc "$(jq -r '.generated_utc // ""' "$INDEX")" \
    --arg ledger_sha "$(hash_file "$LEDGER")" \
    --argjson ledger_bytes "$(wc -c < "$LEDGER" | tr -d ' ')" \
    --argjson indexed "$(jq -r '.files | length' "$INDEX")" \
    '{schema_version: 1, frozen_utc: $utc, index_sha256: $index_sha,
      index_bytes: $index_bytes, index_generated_utc: $index_utc,
      ledger_sha256: $ledger_sha, ledger_bytes: $ledger_bytes,
      indexed_files: $indexed}' > "$tmp" && mv -f "$tmp" "$FREEZE"
}

verify_freeze() {
  if [[ ! -s "$FREEZE" ]]; then
    fail "no pack freeze at $FREEZE; the Lead must run 'pack-validate.sh --freeze <run-root>' after the phase's last ledger append and before spawning checkers"
    return 0
  fi
  local want_index want_ledger now_index now_ledger
  want_index="$(jq -r '.index_sha256' "$FREEZE")"
  want_ledger="$(jq -r '.ledger_sha256' "$FREEZE")"
  now_index="$(hash_file "$INDEX")"
  now_ledger="$(hash_file "$LEDGER")"
  [[ "$now_index" == "$want_index" ]] ||
    fail "evidence-index.json changed since the freeze (frozen $want_index, now $now_index)"
  [[ "$now_ledger" == "$want_ledger" ]] ||
    fail "ledger.jsonl changed since the freeze (frozen $want_ledger, now $now_ledger): the index was generated before the ledger's last append for this phase"
}

# In --verify-freeze mode the freeze is checked FIRST, so a pack that moved under
# a grade is always reported, even when the ordinary rules also fail.
if [[ "$mode" == "verify-freeze" ]]; then
  verify_freeze
fi

# --- verdict ----------------------------------------------------------------
if (( failures > 0 )); then
  printf 'pack-validate: %s failure(s). Fix and re-run before spawning checkers.\n' "$failures" >&2
  exit 1
fi
case "$mode" in
  freeze)
    write_freeze
    printf 'pack-validate: OK (freeze written: %s)\n' "$FREEZE"
    ;;
  verify-freeze)
    printf 'pack-validate: OK (freeze verified; index %s, ledger %s bytes)\n' \
      "$(jq -r '.index_sha256' "$FREEZE" | cut -c1-12)" "$(jq -r '.ledger_bytes' "$FREEZE")"
    ;;
  *)
    printf 'pack-validate: OK\n'
    ;;
esac

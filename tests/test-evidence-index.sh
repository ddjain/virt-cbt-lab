#!/usr/bin/env bash
set -euo pipefail

# The Lead-owned evidence index is what the checkers grade against, and
# pack-validate.sh requires it to be the last write of the run. This test pins
# the generator's contract: every run-root file is indexed with its real sha256
# and size (the index itself excepted), the index is written atomically, empty
# evidence is indexed but warned about, and the result validates.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$ROOT_DIR/cbt-chaos/evidence-index.sh"
VALIDATOR="$ROOT_DIR/cbt-chaos/pack-validate.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

run="$TEST_TMP/run"
mkdir -p "$run/observer/watches" "$run/trigger"

# A minimal, valid run root: ledger tail phase must agree with state.json.
printf '%s\n' '{"schema_version":1,"run_id":"demo-run","phase":"verdict"}' > "$run/state.json"
printf '%s\n' '{"utc":"2026-01-01T00:00:00Z","actor":"lead","event":"run_resolved","phase":"verdict"}' \
  > "$run/ledger.jsonl"
printf 'confirmed observations\n' > "$run/observer/finding.md"
printf '{"old_pod_gone":true}\n' > "$run/trigger/effect-check.json"
: > "$run/observer/watches/empty.jsonl"

sha_of() { # <file>
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1;
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# 1. Generation.
out="$("$GENERATOR" "$run" 2>&1)" || fail "generator exited non-zero: $out"
[[ -f "$run/evidence-index.json" ]] || fail "no evidence-index.json written"
jq -e '.schema_version == 1 and .run_id == "demo-run" and (.generated_utc | length) > 0' \
  "$run/evidence-index.json" >/dev/null || fail "index header is wrong"
jq -e '
  (.files | keys) == ["ledger.jsonl","observer/finding.md","observer/watches/empty.jsonl","state.json","trigger/effect-check.json"]
' "$run/evidence-index.json" >/dev/null ||
  fail "index does not cover exactly the run-root files (index itself excluded)"
for rel in ledger.jsonl state.json observer/finding.md trigger/effect-check.json; do
  expected="$(sha_of "$run/$rel")"
  actual="$(jq -r --arg r "$rel" '.files[$r].sha256' "$run/evidence-index.json")"
  [[ "$expected" == "$actual" ]] || fail "$rel: indexed sha256 $actual != actual $expected"
  expected_bytes="$(wc -c < "$run/$rel" | tr -d ' ')"
  actual_bytes="$(jq -r --arg r "$rel" '.files[$r].bytes' "$run/evidence-index.json")"
  [[ "$expected_bytes" == "$actual_bytes" ]] || fail "$rel: indexed bytes differ"
done
[[ "$out" == *"empty"* ]] || fail "an empty evidence file must be reported, not silently indexed"

# 2. The index must be the last write, and the pack must validate.
"$VALIDATOR" "$run" >/dev/null 2>&1 || fail "pack-validate rejects the freshly generated index"

# 3. Any later write to an indexed file invalidates the pack (ordering rule).
sleep 1
printf 'more evidence\n' >> "$run/observer/finding.md"
if "$VALIDATOR" "$run" >/dev/null 2>&1; then
  fail "pack-validate accepted a file written after the index"
fi

# 4. Regenerating repairs it atomically (no leftover temp file in the run root).
"$GENERATOR" "$run" >/dev/null 2>&1 || fail "regeneration failed"
"$VALIDATOR" "$run" >/dev/null 2>&1 || fail "pack-validate rejects the regenerated index"
leftovers="$(find "$run" -name 'evidence-index.json.tmp*' | wc -l | tr -d ' ')"
[[ "$leftovers" == "0" ]] || fail "generator left a temp file in the run root"

# 5. Usage and error handling.
"$GENERATOR" >/dev/null 2>&1 && fail "no-argument invocation must fail"
"$GENERATOR" "$TEST_TMP/does-not-exist" >/dev/null 2>&1 && fail "a missing run root must fail"
"$GENERATOR" --help >/dev/null 2>&1 || fail "--help must exit 0"

printf 'PASS: evidence-index.sh indexes every run-root file with real hashes, is the last write, and its output validates.\n'

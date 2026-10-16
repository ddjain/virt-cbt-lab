#!/usr/bin/env bash
# evidence-index.sh — regenerate one chaos run's Lead-owned evidence index.
#
# The index is the manifest checkers grade against: every evidence file under the
# run root with its sha256 and size. It must be the LAST write of the run (see
# cbt-chaos/pack-validate.sh rules 3-4), so run this only after every agent has
# finished writing, and append all ledger lines before it.
#
# Usage: evidence-index.sh <run-root>
#   <run-root>  directory holding ledger.jsonl / state.json, e.g.
#               cbt-chaos/scenarios_v2/<id>/runs/<RUN_ID>
#
# Writes <run-root>/evidence-index.json atomically:
#   {"schema_version":1,"run_id":"...","generated_utc":"...",
#    "files":{"<relative path>":{"sha256":"...","bytes":N}, ...}}
#
# Exit: 0 written; 1 an unreadable/absent run root or a hashing failure;
#       2 usage error; 127 a required command is missing.
set -euo pipefail

usage() {
  printf 'Usage: %s <run-root>\n' "$0" >&2
  printf 'Regenerates <run-root>/evidence-index.json from every file under the run root (excluding the index itself).\n' >&2
  printf 'Run it after all writers have finished: pack-validate.sh requires the index to be the newest file.\n' >&2
}

if (($# != 1)) || [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit "$([[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && echo 0 || echo 2)"
fi

root="$1"
if [[ ! -d "$root" ]]; then
  printf 'Run root is not a directory: %s\n' "$root" >&2
  exit 1
fi
root="$(cd "$root" && pwd)"
for command in jq find; do
  command -v "$command" >/dev/null 2>&1 || { printf 'Required command not found: %s\n' "$command" >&2; exit 127; }
done
if command -v sha256sum >/dev/null 2>&1; then
  hash_file() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  hash_file() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  printf 'Required command not found: sha256sum or shasum\n' >&2
  exit 127
fi

run_id=""
if [[ -r "$root/state.json" ]]; then
  run_id="$(jq -r '.run_id // empty' "$root/state.json" 2>/dev/null || true)"
fi
if [[ -z "$run_id" ]]; then
  run_id="$(basename "$root")"
  printf 'state.json has no run_id; using the directory name (%s).\n' "$run_id" >&2
fi

index="$root/evidence-index.json"
tmp="$index.tmp.$$"
records="$(mktemp "${TMPDIR:-/tmp}/cbt-evidence-index.XXXXXX")"
trap 'rm -f "$tmp" "$records"' EXIT
: > "$records"

count=0
empty_count=0
while IFS= read -r -d '' file; do
  rel="${file#"$root"/}"
  [[ "$rel" == "evidence-index.json" ]] && continue
  if [[ ! -s "$file" ]]; then
    empty_count=$((empty_count + 1))
    printf 'warning: indexing empty evidence file (0 bytes): %s\n' "$rel" >&2
  fi
  digest="$(hash_file "$file")"
  [[ -n "$digest" ]] || { printf 'Could not hash %s\n' "$rel" >&2; exit 1; }
  bytes="$(wc -c < "$file" | tr -d ' ')"
  printf '%s\t%s\t%s\n' "$rel" "$digest" "$bytes" >> "$records"
  count=$((count + 1))
done < <(find "$root" -type f -not -path '*/.git/*' -not -name 'evidence-index.json*' -print0 | LC_ALL=C sort -z)

if ((count == 0)); then
  printf 'No evidence files found under %s; refusing to write an empty index.\n' "$root" >&2
  exit 1
fi

jq -Rn --arg run_id "$run_id" --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  [inputs | split("\t") | {key: .[0], value: {sha256: .[1], bytes: (.[2] | tonumber)}}]
  | from_entries as $files
  | {schema_version: 1, run_id: $run_id, generated_utc: $utc, files: $files}' \
  < "$records" > "$tmp"
mv -f "$tmp" "$index"
trap - EXIT

printf 'Evidence index written: %s (%s files, %s empty)\n' "$index" "$count" "$empty_count"

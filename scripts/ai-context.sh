#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAX_EVENTS=20
CONTEXT_LINES=2
FOCUS_RE=""
SHOW_SNIPPETS=false
RAW_SPEC=""
FILES=()

usage() {
  cat <<'USAGE'
Usage: scripts/ai-context.sh [options]

Read-only, bounded context collection for AI-assisted diagnosis.

Without --file, prints an inventory of logs/ and validation/ only. It never
scans log contents for matches or emits them in that mode. Use --file to select
evidence explicitly.

Options:
  --file PATH              Add a repository-relative evidence file. Repeatable.
  --focus REGEX            Scan only lines matching this extended regex.
  --snippets               Print bounded, redacted matching snippets.
  --max-events N           Maximum matching windows per file (default: 20).
  --context N              Lines before and after each match (default: 2).
  --raw-range PATH:S-E     Print an exact line range; explicit, unredacted.
  --help                   Show this help.

Examples:
  scripts/ai-context.sh
  scripts/ai-context.sh --file logs/run.log --snippets --focus 'backup|checkpoint'
  scripts/ai-context.sh --file validation/summary.md --snippets
  scripts/ai-context.sh --raw-range logs/run.log:120-135

The source files are never modified. The default and --snippets output include
file hashes and line references so omitted content remains recoverable locally.
USAGE
}

die() {
  printf 'ai-context: %s\n' "$1" >&2
  exit 2
}

require_nonnegative_integer() {
  case "$2" in
    ''|*[!0-9]*) die "$1 must be a non-negative integer: $2" ;;
  esac
}

resolve_file() {
  local candidate="$1"
  local path

  if [[ "$candidate" = /* ]]; then
    path="$candidate"
  else
    path="$ROOT_DIR/$candidate"
  fi

  case "$path" in
    "$ROOT_DIR"/*) ;;
    *) die "path must stay inside the repository: $candidate" ;;
  esac
  [[ -f "$path" ]] || die "file not found: ${path#"$ROOT_DIR"/}"
  printf '%s\n' "$path"
}

file_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    printf 'unavailable\n'
  fi
}

file_bytes() {
  wc -c < "$1" | tr -d '[:space:]'
}

file_lines() {
  wc -l < "$1" | tr -d '[:space:]'
}

relative_path() {
  printf '%s\n' "${1#"$ROOT_DIR"/}"
}

print_metadata() {
  local path="$1"
  printf 'file: %s\n' "$(relative_path "$path")"
  printf 'bytes: %s\n' "$(file_bytes "$path")"
  printf 'lines: %s\n' "$(file_lines "$path")"
  printf 'sha256: %s\n' "$(file_hash "$path")"
}

print_inventory() {
  local directory path
  printf 'mode: inventory (read-only; file contents not scanned)\n'
  printf 'repository: .\n'
  for directory in logs validation; do
    if [[ ! -d "$ROOT_DIR/$directory" ]]; then
      continue
    fi
    while IFS= read -r path; do
      print_metadata "$path"
    done < <(find "$ROOT_DIR/$directory" -type f -print | LC_ALL=C sort)
  done
  printf 'next: select a file with --file PATH; add --snippets for bounded redacted evidence.\n'
}

print_snippets() {
  local path="$1"
  local relative
  relative="$(relative_path "$path")"
  printf 'snippets: %s\n' "$relative"
  awk -v context="$CONTEXT_LINES" -v max_events="$MAX_EVENTS" -v focus="$FOCUS_RE" '
    function safe(text) {
      gsub(/[Pp]assword[[:space:]]*[:=][[:space:]]*[^[:space:]]+/, "password=<redacted>", text)
      gsub(/[Tt]oken[[:space:]]*[:=][[:space:]]*[^[:space:]]+/, "token=<redacted>", text)
      gsub(/[Bb]earer[[:space:]]+[^[:space:]]+/, "Bearer <redacted>", text)
      gsub(/[Aa]pi[_ -]?[Kk]ey[[:space:]]*[:=][[:space:]]*[^[:space:]]+/, "api-key=<redacted>", text)
      gsub(/-----BEGIN [^-]+-----/, "<private-key-redacted>", text)
      gsub(/-----END [^-]+-----/, "<private-key-end-redacted>", text)
      return text
    }
    BEGIN {

      expression = focus
      if (expression == "") {
        expression = "error|fail|warn|timeout|denied|forbidden|already exists|not found|cbt|checkpoint|summary:|ready|not ready"
      }
    }
    {
      lines[NR] = $0
      if (tolower($0) ~ tolower(expression)) {
        matches[++match_count] = NR
      }
    }
    END {
      shown = match_count
      if (shown > max_events) {
        shown = max_events
      }
      printf("matches: %d; shown: %d; context: %d lines\n", match_count, shown, context)
      last_end = 0
      for (m = 1; m <= shown; m++) {
        center = matches[m]
        start = center - context
        if (start < 1) {
          start = 1
        }
        end = center + context
        if (end > NR) {
          end = NR
        }
        if (start <= last_end) {
          start = last_end + 1
        }
        if (start <= end) {
          if (last_end > 0) {
            print "--"
          }
          for (line = start; line <= end; line++) {
            printf("%d:%s\n", line, safe(lines[line]))
          }
          last_end = end
        }
      }
      if (match_count > shown) {
        printf("omitted: %d additional matching lines; source file was not changed\n", match_count - shown)
      }
    }
  ' "$path"
}

print_raw_range() {
  local spec="$1"
  local candidate range start end path

  candidate="${spec%%:*}"
  range="${spec#*:}"
  [[ "$candidate" != "$spec" ]] || die "raw range must use PATH:S-E: $spec"
  start="${range%-*}"
  end="${range#*-}"
  require_nonnegative_integer start "$start"
  require_nonnegative_integer end "$end"
  [[ "$start" -gt 0 && "$end" -ge "$start" ]] || die "raw range must be a positive S-E range: $spec"
  path="$(resolve_file "$candidate")"

  printf 'raw-range: %s:%s-%s\n' "$(relative_path "$path")" "$start" "$end"
  awk -v start="$start" -v end="$end" 'NR >= start && NR <= end { printf("%d:%s\n", NR, $0) } NR > end { exit }' "$path"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --file)
      [[ "$#" -ge 2 ]] || die '--file requires a path'
      FILES+=("$(resolve_file "$2")")
      shift 2
      ;;
    --file=*)
      FILES+=("$(resolve_file "${1#*=}")")
      shift
      ;;
    --focus)
      [[ "$#" -ge 2 ]] || die '--focus requires an extended regular expression'
      FOCUS_RE="$2"
      shift 2
      ;;
    --focus=*)
      FOCUS_RE="${1#*=}"
      shift
      ;;
    --snippets)
      SHOW_SNIPPETS=true
      shift
      ;;
    --max-events)
      [[ "$#" -ge 2 ]] || die '--max-events requires a number'
      require_nonnegative_integer max-events "$2"
      MAX_EVENTS="$2"
      shift 2
      ;;
    --context)
      [[ "$#" -ge 2 ]] || die '--context requires a number'
      require_nonnegative_integer context "$2"
      CONTEXT_LINES="$2"
      shift 2
      ;;
    --raw-range)
      [[ "$#" -ge 2 ]] || die '--raw-range requires PATH:S-E'
      RAW_SPEC="$2"
      shift 2
      ;;
    --raw-range=*)
      RAW_SPEC="${1#*=}"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ -n "$RAW_SPEC" ]]; then
  print_raw_range "$RAW_SPEC"
  printf 'warning: raw-range is unredacted; do not send secret-bearing output to an AI service.\n' >&2
  exit 0
fi

if [[ "$SHOW_SNIPPETS" = true && "${#FILES[@]}" -eq 0 ]]; then
  die '--snippets requires at least one --file to avoid scanning all logs'
fi

if [[ "${#FILES[@]}" -eq 0 ]]; then
  print_inventory
  exit 0
fi

printf 'mode: selected evidence (read-only)\n'
for path in "${FILES[@]}"; do
  print_metadata "$path"
  if [[ "$SHOW_SNIPPETS" = true ]]; then
    print_snippets "$path"
  fi
done

#!/usr/bin/env bash
# Helpers for the run-scoped deterministic guest-file workload manifest.
set -euo pipefail

WORKLOAD_MANIFEST_NAME="workload-manifest.json"
WORKLOAD_SIZE_ALGORITHM="sha256-filename-v1"
WORKLOAD_CONTENT_ALGORITHM="repeated-ascii-identity-v1"

workload_manifest_path() {
  printf '%s/%s' "$REPORT_DIR" "$WORKLOAD_MANIFEST_NAME"
}

workload_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    printf 'A SHA-256 utility (shasum or sha256sum) is required to build the workload manifest.\n' >&2
    return 1
  fi
}

# Assign a stable, evenly distributed whole-MiB size from the filename. The
# fixed algorithm keeps every retry and OS profile on the same file plan.
workload_file_size_bytes() {
  local path="$1" digest hash_word value span size_mib
  digest="$(printf 'cbt-workload-size-v1:%s' "$path" | workload_sha256_stdin)"
  hash_word="${digest:0:8}"
  value=$((16#$hash_word))
  span=$((GUEST_FILE_SIZE_MAX_MIB - GUEST_FILE_SIZE_MIN_MIB + 1))
  size_mib=$((GUEST_FILE_SIZE_MIN_MIB + value % span))
  printf '%s' "$((size_mib * 1048576))"
}

workload_file_plan() {
  local phase="$1" count="$2" prefix index path size_bytes
  case "$phase" in
    baseline) prefix=base ;;
    incremental) prefix=incremental ;;
    *) printf 'Unknown workload phase: %s\n' "$phase" >&2; return 2 ;;
  esac
  for ((index = 1; index <= count; index++)); do
    printf -v path '%s-%06d.dat' "$prefix" "$index"
    size_bytes="$(workload_file_size_bytes "$path")"
    printf '%s|%s\n' "$path" "$size_bytes"
  done
}

# Convert guest FILE_RECORD=path|size_bytes|sha256 output into a validated
# JSON array. Filenames are intentionally restricted to the generated set.
workload_records_from_output() {
  local output="$1" line record path size_bytes sha256 extra phase records='[]'
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" == FILE_RECORD=* ]] || continue
    record="${line#FILE_RECORD=}"
    IFS='|' read -r path size_bytes sha256 extra <<< "$record"
    if [[ -n "${extra:-}" || ! "$path" =~ ^(base|incremental)-[0-9]{6}[.]dat$ ||
          ! "$size_bytes" =~ ^[1-9][0-9]*$ || ! "$sha256" =~ ^[[:xdigit:]]{64}$ ]]; then
      printf 'Malformed guest workload record: %s\n' "$line" >&2
      return 1
    fi
    case "$path" in
      base-*) phase=baseline ;;
      incremental-*) phase=incremental ;;
    esac
    sha256="$(printf '%s' "$sha256" | tr '[:upper:]' '[:lower:]')"
    records="$(jq -cn --argjson records "$records" --arg path "$path" \
      --arg phase "$phase" --argjson size_bytes "$size_bytes" --arg sha256 "$sha256" \
      '$records + [{path: $path, phase: $phase, size_bytes: $size_bytes, sha256: $sha256}]')"
  done <<< "$output"
  printf '%s' "$records"
}

workload_records_for_phase() {
  jq -c --arg phase "$2" '[.[] | select(.phase == $phase)]' <<< "$1"
}

workload_records_count() {
  jq -r 'length' <<< "$1"
}

workload_records_bytes() {
  jq -r '[.[].size_bytes] | add // 0' <<< "$1"
}

# Hash sorted canonical rows: relative path, exact byte size, file SHA-256.
workload_records_digest() {
  jq -r 'sort_by(.path)[] | [.path, (.size_bytes | tostring), .sha256] | @tsv' \
    <<< "$1" | workload_sha256_stdin
}

workload_validate_plan() {
  local records="$1" phase="$2" count="$3" prefix index path expected_size actual
  case "$phase" in
    baseline) prefix=base ;;
    incremental) prefix=incremental ;;
    *) printf 'Unknown workload phase: %s\n' "$phase" >&2; return 2 ;;
  esac
  actual="$(workload_records_for_phase "$records" "$phase")"
  if [[ "$(workload_records_count "$actual")" != "$count" ]]; then
    printf 'Expected %s %s files; guest reported %s.\n' "$count" "$phase" "$(workload_records_count "$actual")" >&2
    return 1
  fi
  for ((index = 1; index <= count; index++)); do
    printf -v path '%s-%06d.dat' "$prefix" "$index"
    expected_size="$(workload_file_size_bytes "$path")"
    if ! jq -e --arg path "$path" --arg phase "$phase" --argjson size "$expected_size" \
        'any(.[]; .path == $path and .phase == $phase and .size_bytes == $size)' \
        <<< "$actual" >/dev/null; then
      printf 'Guest workload file %s is absent or has an unexpected size.\n' "$path" >&2
      return 1
    fi
  done
}

workload_manifest_initialize() {
  local baseline_records="$1" manifest tmp_path baseline_bytes baseline_hash
  workload_validate_plan "$baseline_records" baseline "$GUEST_BASE_FILE_COUNT"
  manifest="$(workload_manifest_path)"
  tmp_path="$manifest.tmp"
  baseline_bytes="$(workload_records_bytes "$(workload_records_for_phase "$baseline_records" baseline)")"
  baseline_hash="$(workload_records_digest "$(workload_records_for_phase "$baseline_records" baseline)")"
  jq -n \
    --arg run_id "$RUN_ID" \
    --arg directory "$GUEST_WORKLOAD_DIR" \
    --argjson min_mib "$GUEST_FILE_SIZE_MIN_MIB" \
    --argjson max_mib "$GUEST_FILE_SIZE_MAX_MIB" \
    --arg size_algorithm "$WORKLOAD_SIZE_ALGORITHM" \
    --arg content_algorithm "$WORKLOAD_CONTENT_ALGORITHM" \
    --argjson count "$GUEST_BASE_FILE_COUNT" \
    --argjson total_bytes "$baseline_bytes" \
    --arg manifest_sha256 "$baseline_hash" \
    --argjson files "$(workload_records_for_phase "$baseline_records" baseline)" \
    '{schema_version: 1,
      run_id: $run_id,
      guest_directory: $directory,
      size_range_mib: {min_inclusive: $min_mib, max_inclusive: $max_mib},
      size_assignment_algorithm: $size_algorithm,
      content_algorithm: $content_algorithm,
      baseline: {file_count: $count, total_payload_bytes: $total_bytes,
                 manifest_sha256: $manifest_sha256, files: $files}}' > "$tmp_path"
  jq -e '.schema_version == 1 and (.baseline.files | length) == .baseline.file_count' \
    "$tmp_path" >/dev/null
  mv -f "$tmp_path" "$manifest"
}

workload_manifest_append_incremental() {
  local incremental_records="$1" manifest tmp_path added added_bytes added_hash baseline_files all_files final_count final_bytes final_hash
  manifest="$(workload_manifest_path)"
  if [[ ! -r "$manifest" ]]; then
    printf 'Missing baseline workload manifest: %s\n' "$manifest" >&2
    return 1
  fi
  workload_validate_plan "$incremental_records" incremental "$GUEST_INCREMENTAL_FILE_COUNT"
  added="$(workload_records_for_phase "$incremental_records" incremental)"
  added_bytes="$(workload_records_bytes "$added")"
  added_hash="$(workload_records_digest "$added")"
  baseline_files="$(jq -c '.baseline.files' "$manifest")"
  all_files="$(jq -cn --argjson baseline "$baseline_files" --argjson added "$added" '$baseline + $added')"
  final_count="$(workload_records_count "$all_files")"
  final_bytes="$(workload_records_bytes "$all_files")"
  final_hash="$(workload_records_digest "$all_files")"
  tmp_path="$manifest.tmp"
  jq --argjson added_count "$GUEST_INCREMENTAL_FILE_COUNT" \
     --argjson added_bytes "$added_bytes" --arg added_hash "$added_hash" \
     --argjson total_count "$final_count" --argjson total_bytes "$final_bytes" \
     --arg final_hash "$final_hash" --argjson added_files "$added" \
     '.incremental = {files_added: $added_count,
                      added_payload_bytes: $added_bytes,
                      added_manifest_sha256: $added_hash,
                      total_file_count: $total_count,
                      total_payload_bytes: $total_bytes,
                      manifest_sha256: $final_hash,
                      files: $added_files}' \
     "$manifest" > "$tmp_path"
  jq -e '.schema_version == 1 and
         (.baseline.files | length) == .baseline.file_count and
         (.incremental.files | length) == .incremental.files_added and
         (.incremental.total_file_count == (.baseline.file_count + .incremental.files_added))' \
     "$tmp_path" >/dev/null
  mv -f "$tmp_path" "$manifest"
}

workload_manifest_verify_inventory() {
  local actual_records="$1" expected_records="$2" label="$3"
  local actual_count expected_count actual_hash expected_hash
  actual_count="$(workload_records_count "$actual_records")"
  expected_count="$(workload_records_count "$expected_records")"
  actual_hash="$(workload_records_digest "$actual_records")"
  expected_hash="$(workload_records_digest "$expected_records")"
  if [[ "$actual_count" != "$expected_count" || "$actual_hash" != "$expected_hash" ]]; then
    printf '%s workload inventory mismatch: expected %s files/%s, got %s files/%s.\n' \
      "$label" "$expected_count" "$expected_hash" "$actual_count" "$actual_hash" >&2
    return 1
  fi
}

workload_manifest_validate() {
  local manifest="$1" require_incremental="${2:-false}"
  local baseline_files baseline_digest incremental_files incremental_digest combined_files combined_digest
  if [[ ! -r "$manifest" ]] || ! jq -e \
      --argjson require_incremental "$([[ "$require_incremental" == true ]] && printf true || printf false)" '
        def valid_file($phase; $pattern; $min_bytes; $max_bytes):
          .phase == $phase
          and (.path | test($pattern))
          and (.size_bytes | type == "number")
          and .size_bytes >= $min_bytes
          and .size_bytes <= $max_bytes
          and (.sha256 | test("^[0-9a-f]{64}$"));
        . as $m
        | $m.schema_version == 1
        and ($m.run_id | type == "string" and length > 0)
        and $m.size_assignment_algorithm == "sha256-filename-v1"
        and $m.content_algorithm == "repeated-ascii-identity-v1"
        and ($m.guest_directory | type == "string" and length > 0)
        and ($m.size_range_mib.min_inclusive | type == "number" and . > 0)
        and ($m.size_range_mib.max_inclusive | type == "number")
        and $m.size_range_mib.max_inclusive >= $m.size_range_mib.min_inclusive
        and ($m.baseline.files | type == "array")
        and $m.baseline.file_count == ($m.baseline.files | length)
        and ($m.baseline.file_count | type == "number" and . > 0)
        and ($m.baseline.total_payload_bytes | type == "number" and . > 0)
        and ($m.baseline.manifest_sha256 | test("^[0-9a-f]{64}$"))
        and all($m.baseline.files[];
          valid_file("baseline"; "^base-[0-9]{6}[.]dat$";
            ($m.size_range_mib.min_inclusive * 1048576);
            ($m.size_range_mib.max_inclusive * 1048576)))
        and (if $m.incremental == null then
               $require_incremental == false
             else
               ($m.incremental.files | type == "array")
               and $m.incremental.files_added == ($m.incremental.files | length)
               and ($m.incremental.files_added | type == "number" and . > 0)
               and ($m.incremental.added_payload_bytes | type == "number" and . > 0)
               and ($m.incremental.added_manifest_sha256 | test("^[0-9a-f]{64}$"))
               and $m.incremental.total_file_count ==
                   ($m.baseline.file_count + $m.incremental.files_added)
               and $m.incremental.total_payload_bytes ==
                   ($m.baseline.total_payload_bytes + $m.incremental.added_payload_bytes)
               and ($m.incremental.manifest_sha256 | test("^[0-9a-f]{64}$"))
               and all($m.incremental.files[];
                 valid_file("incremental"; "^incremental-[0-9]{6}[.]dat$";
                   ($m.size_range_mib.min_inclusive * 1048576);
                   ($m.size_range_mib.max_inclusive * 1048576)))
             end)
        and (($m.baseline.files + ($m.incremental.files // []) | map(.path) | unique | length)
             == ($m.baseline.files + ($m.incremental.files // []) | length))
      ' "$manifest" >/dev/null; then
    printf 'Workload manifest is missing or invalid: %s\n' "$manifest" >&2
    return 1
  fi

  baseline_files="$(jq -c '.baseline.files' "$manifest")"
  baseline_digest="$(workload_records_digest "$baseline_files")"
  if [[ "$baseline_digest" != "$(jq -r '.baseline.manifest_sha256' "$manifest")" ||
        "$(workload_records_bytes "$baseline_files")" != "$(jq -r '.baseline.total_payload_bytes' "$manifest")" ]]; then
    printf 'Baseline workload manifest summary does not match its file entries: %s\n' "$manifest" >&2
    return 1
  fi
  if [[ "$(jq -r '.incremental // empty | type' "$manifest")" == object ]]; then
    incremental_files="$(jq -c '.incremental.files' "$manifest")"
    incremental_digest="$(workload_records_digest "$incremental_files")"
    combined_files="$(jq -cn --argjson baseline "$baseline_files" --argjson incremental "$incremental_files" '$baseline + $incremental')"
    combined_digest="$(workload_records_digest "$combined_files")"
    if [[ "$incremental_digest" != "$(jq -r '.incremental.added_manifest_sha256' "$manifest")" ||
          "$(workload_records_bytes "$incremental_files")" != "$(jq -r '.incremental.added_payload_bytes' "$manifest")" ||
          "$(workload_records_count "$combined_files")" != "$(jq -r '.incremental.total_file_count' "$manifest")" ||
          "$(workload_records_bytes "$combined_files")" != "$(jq -r '.incremental.total_payload_bytes' "$manifest")" ||
          "$combined_digest" != "$(jq -r '.incremental.manifest_sha256' "$manifest")" ]]; then
      printf 'Incremental workload manifest summary does not match its file entries: %s\n' "$manifest" >&2
      return 1
    fi
  fi
}

#!/usr/bin/env bash
# Helpers for the run-scoped deterministic guest-file workload manifest.
set -euo pipefail

WORKLOAD_MANIFEST_NAME="workload-manifest.json"
WORKLOAD_SIZE_ALGORITHM="sha256-filename-v1"
WORKLOAD_CONTENT_ALGORITHM="repeated-ascii-identity-v1"
WORKLOAD_MODIFICATION_CONTENT_ALGORITHM="pass-versioned-baseline-v1"

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
  local phase="$1" count="$2" pass="${3:-}" prefix index path size_bytes
  case "$phase" in
    baseline) prefix=base ;;
    incremental)
      if ! [[ "$pass" =~ ^[1-9][0-9]*$ ]] || ((pass > 99)); then
        printf 'Incremental workload planning requires a pass number from 1 to 99 (got: %s).\n' "$pass" >&2
        return 2
      fi
      printf -v prefix 'incremental-%02d' "$pass"
      ;;
    *) printf 'Unknown workload phase: %s\n' "$phase" >&2; return 2 ;;
  esac
  for ((index = 1; index <= count; index++)); do
    printf -v path '%s-%06d.dat' "$prefix" "$index"
    size_bytes="$(workload_file_size_bytes "$path")"
    printf '%s|%s\n' "$path" "$size_bytes"
  done
}

workload_modified_file_plan() {
  local pass="$1" pass_number index path size_bytes
  if ! [[ "$pass" =~ ^[1-9][0-9]*$ ]] || ((pass > 99)); then
    printf 'Workload modification planning requires a pass number from 1 to 99 (got: %s).\n' "$pass" >&2
    return 2
  fi
  if ! [[ "$GUEST_BASE_FILE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    printf 'GUEST_BASE_FILE_COUNT must be positive to choose a modification target.\n' >&2
    return 1
  fi
  pass_number=$((10#$pass))
  index=$(((pass_number - 1) % GUEST_BASE_FILE_COUNT + 1))
  printf -v path 'base-%06d.dat' "$index"
  size_bytes="$(workload_file_size_bytes "$path")"
  printf '%s|%s\n' "$path" "$size_bytes"
}

workload_modified_content_pattern() {
  local path="$1" pass="$2"
  if ! [[ "$pass" =~ ^[1-9][0-9]*$ ]] || ((pass > 99)); then
    printf 'Modified workload content requires a pass number from 1 to 99 (got: %s).\n' "$pass" >&2
    return 2
  fi
  printf 'CBT-WORKLOAD-V1:%s:MODIFIED-PASS-%02d' "$path" "$pass"
}

workload_modified_file_sha256() {
  local path="$1" pass="$2" size_bytes="$3" pattern
  pattern="$(workload_modified_content_pattern "$path" "$pass")"
  (
    set +o pipefail
    yes "$pattern" | head -c "$size_bytes" | workload_sha256_stdin
  )
}

workload_validate_modified_records() {
  local records="$1" pass="$2" plan name size_bytes expected_hash expected actual
  local count
  count="$(workload_records_count "$records")"
  if [[ "$count" != 1 ]]; then
    printf 'Expected exactly one modified baseline file in pass %s; found %s.\n' "$pass" "$count" >&2
    return 1
  fi
  plan="$(workload_modified_file_plan "$pass")"
  IFS='|' read -r name size_bytes <<< "$plan"
  expected_hash="$(workload_modified_file_sha256 "$name" "$pass" "$size_bytes")"
  expected="$(printf '%s\t%s\tbaseline\t0\t%s\n' "$name" "$size_bytes" "$expected_hash")"
  actual="$(jq -r 'sort_by(.path)[] |
    [.path, (.size_bytes | tostring), .phase, (.pass | tostring), .sha256] | @tsv' <<< "$records")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Modified file in pass %s does not match its deterministic target, size, or content.\n' "$pass" >&2
    return 1
  fi
}

# Replace each path with its latest deterministic content record.
workload_records_apply_modifications() {
  local records="$1" modifications="$2"
  jq -cn \
    --slurpfile current <(printf '%s\n' "$records") \
    --slurpfile changes <(printf '%s\n' "$modifications") \
    'reduce $changes[0][] as $change
      ($current[0]; map(if .path == $change.path then $change else . end))'
}

# Rebuild the expected guest inventory at a cumulative checkpoint.
workload_manifest_current_records() {
  local manifest="$1" pass_total="$2" records pass entry modifications added
  if ! [[ "$pass_total" =~ ^[0-9]+$ ]] || ((pass_total > 99)); then
    printf 'Cumulative workload reconstruction requires a pass count from 0 to 99 (got: %s).\n' "$pass_total" >&2
    return 2
  fi
  records="$(jq -c '.baseline.files' "$manifest")"
  for ((pass = 1; pass <= pass_total; pass++)); do
    entry="$(jq -c --argjson pass "$pass" '.incrementals[]? | select(.pass == $pass)' "$manifest")"
    if [[ -z "$entry" ]]; then
      printf 'Workload manifest is missing incremental pass %s.\n' "$pass" >&2
      return 1
    fi
    modifications="$(jq -c '.files_modified // []' <<< "$entry")"
    records="$(workload_records_apply_modifications "$records" "$modifications")"
    added="$(jq -c '.files' <<< "$entry")"
    records="$(workload_records_concat "$records" "$added")"
  done
  printf '%s' "$records"
}

# Convert guest FILE_RECORD=path|size_bytes|sha256 output into a validated
# JSON array. Filenames are intentionally restricted to the generated set.
workload_records_from_output() {
  local output="$1" line record path size_bytes sha256 extra phase pass json_record
  local -a records_jsonl=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" == FILE_RECORD=* ]] || continue
    record="${line#FILE_RECORD=}"
    IFS='|' read -r path size_bytes sha256 extra <<< "$record"
    if [[ -n "${extra:-}" ||
          ! "$size_bytes" =~ ^[1-9][0-9]*$ ||
          ! "$sha256" =~ ^[[:xdigit:]]{64}$ ]]; then
      printf 'Malformed guest workload record: %s\n' "$line" >&2
      return 1
    fi
    if [[ "$path" =~ ^base-[0-9]{6}[.]dat$ ]]; then
      phase=baseline
      pass=0
    elif [[ "$path" =~ ^incremental-([0-9]{2})-[0-9]{6}[.]dat$ ]]; then
      phase=incremental
      pass=$((10#${BASH_REMATCH[1]}))
    else
      printf 'Unexpected guest workload filename: %s\n' "$path" >&2
      return 1
    fi
    printf -v json_record '{"path":"%s","phase":"%s","pass":%s,"size_bytes":%s,"sha256":"%s"}' \
      "$path" "$phase" "$pass" "$size_bytes" "$sha256"
    records_jsonl+=("$json_record")
  done <<< "$output"
  if ((${#records_jsonl[@]} == 0)); then
    printf '[]'
  else
    printf '%s\n' "${records_jsonl[@]}" | jq -cs 'map(.sha256 |= ascii_downcase)'
  fi
}

# Concatenate compact arrays through stdin; large inventories must not be
# passed to jq as command-line arguments (which have a per-argument OS limit).
workload_records_concat() {
  if (($# == 0)); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "$@" | jq -sc 'add'
}

workload_records_for_phase() {
  local records="$1" phase="$2" pass="${3:-}"
  if [[ -n "$pass" ]]; then
    jq -c --arg phase "$phase" --argjson pass "$pass" \
      '[.[] | select(.phase == $phase and .pass == $pass)]' <<< "$records"
  else
    jq -c --arg phase "$phase" '[.[] | select(.phase == $phase)]' <<< "$records"
  fi
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
  local records="$1" phase="$2" count="$3" pass="${4:-0}"
  local actual expected_plan expected_sizes actual_sizes path size_bytes
  local -a expected_rows=()
  case "$phase" in
    baseline) ;;
    incremental)
      if ! [[ "$pass" =~ ^[1-9][0-9]*$ ]] || ((pass > 99)); then
        printf 'Incremental workload validation requires a pass number from 1 to 99 (got: %s).\n' "$pass" >&2
        return 2
      fi
      ;;
    *) printf 'Unknown workload phase: %s\n' "$phase" >&2; return 2 ;;
  esac
  if [[ "$phase" == incremental ]]; then
    actual="$(workload_records_for_phase "$records" "$phase" "$pass")"
  else
    actual="$(workload_records_for_phase "$records" "$phase")"
  fi
  if [[ "$(workload_records_count "$actual")" != "$count" ]]; then
    printf 'Expected %s %s files in pass %s; guest reported %s.\n' \
      "$count" "$phase" "$pass" "$(workload_records_count "$actual")" >&2
    return 1
  fi
  expected_plan="$(workload_file_plan "$phase" "$count" "$pass")"
  while IFS='|' read -r path size_bytes; do
    [[ -n "$path" ]] || continue
    expected_rows+=("$path"$'\t'"$size_bytes"$'\t'"$phase"$'\t'"$pass")
  done <<< "$expected_plan"
  expected_sizes="$(printf '%s\n' "${expected_rows[@]}")"
  actual_sizes="$(jq -r 'sort_by(.path)[] |
    [.path, (.size_bytes | tostring), .phase, (.pass | tostring)] | @tsv' <<< "$actual")"
  if [[ "$actual_sizes" != "$expected_sizes" ]]; then
    printf 'Guest %s file names, sizes, or pass assignments do not match the deterministic plan for pass %s.\n' \
      "$phase" "$pass" >&2
    return 1
  fi
}

workload_manifest_initialize() {
  local baseline_records="$1" manifest tmp_path baseline_bytes baseline_hash baseline_files
  workload_validate_plan "$baseline_records" baseline "$GUEST_BASE_FILE_COUNT"
  manifest="$(workload_manifest_path)"
  tmp_path="$manifest.tmp"
  baseline_files="$(workload_records_for_phase "$baseline_records" baseline)"
  baseline_bytes="$(workload_records_bytes "$baseline_files")"
  baseline_hash="$(workload_records_digest "$baseline_files")"
  # Keep the file list on stdin; a large manifest array exceeds OS argv limits.
  jq -s \
    --arg run_id "$RUN_ID" \
    --arg directory "$GUEST_WORKLOAD_DIR" \
    --argjson min_mib "$GUEST_FILE_SIZE_MIN_MIB" \
    --argjson max_mib "$GUEST_FILE_SIZE_MAX_MIB" \
    --arg size_algorithm "$WORKLOAD_SIZE_ALGORITHM" \
    --arg content_algorithm "$WORKLOAD_CONTENT_ALGORITHM" \
    --arg modification_algorithm "$WORKLOAD_MODIFICATION_CONTENT_ALGORITHM" \
    --argjson count "$GUEST_BASE_FILE_COUNT" \
    --argjson total_bytes "$baseline_bytes" \
    --arg manifest_sha256 "$baseline_hash" \
    --argjson passes_total "$GUEST_INCREMENTAL_PASSES" \
    --argjson files_per_pass "$GUEST_INCREMENTAL_FILE_COUNT" \
    '.[0] as $files |
     {schema_version: 2,
      run_id: $run_id,
      guest_directory: $directory,
      size_range_mib: {min_inclusive: $min_mib, max_inclusive: $max_mib},
      size_assignment_algorithm: $size_algorithm,
      content_algorithm: $content_algorithm,
      modification_content_algorithm: $modification_algorithm,
      incremental_passes_total: $passes_total,
      incremental_file_count_per_pass: $files_per_pass,
      baseline: {file_count: $count, total_payload_bytes: $total_bytes,
                 manifest_sha256: $manifest_sha256, files: $files},
      incrementals: [],
      combined: {total_file_count: $count, total_payload_bytes: $total_bytes,
                 manifest_sha256: $manifest_sha256}}' <<< "$baseline_files" > "$tmp_path"
  jq -e '.schema_version == 2 and (.baseline.files | length) == .baseline.file_count' \
    "$tmp_path" >/dev/null
  mv -f "$tmp_path" "$manifest"
}

workload_manifest_append_incremental() {
  local pass="$1" incremental_records="$2" modified_records="$3" manifest tmp_path
  local added added_bytes added_hash modified_count modified_hash
  local prior_count records_before modifications_applied combined_files total_count total_bytes total_hash
  local captured_at="${4:-}"
  manifest="$(workload_manifest_path)"
  if [[ ! -r "$manifest" ]]; then
    printf 'Missing baseline workload manifest: %s\n' "$manifest" >&2
    return 1
  fi
  workload_validate_plan "$incremental_records" incremental "$GUEST_INCREMENTAL_FILE_COUNT" "$pass"
  prior_count="$(jq -r '.incrementals | length' "$manifest")"
  if ((pass != prior_count + 1 || pass > GUEST_INCREMENTAL_PASSES)); then
    printf 'Incremental pass %s is not the next planned pass (completed %s of %s).\n' \
      "$pass" "$prior_count" "$GUEST_INCREMENTAL_PASSES" >&2
    return 1
  fi
  workload_validate_modified_records "$modified_records" "$pass"
  added="$(workload_records_for_phase "$incremental_records" incremental "$pass")"
  added_bytes="$(workload_records_bytes "$added")"
  added_hash="$(workload_records_digest "$added")"
  modified_count="$(workload_records_count "$modified_records")"
  modified_hash="$(workload_records_digest "$modified_records")"
  records_before="$(workload_manifest_current_records "$manifest" "$prior_count")"
  modifications_applied="$(workload_records_apply_modifications "$records_before" "$modified_records")"
  combined_files="$(workload_records_concat "$modifications_applied" "$added")"
  total_count="$(workload_records_count "$combined_files")"
  total_bytes="$(workload_records_bytes "$combined_files")"
  total_hash="$(workload_records_digest "$combined_files")"
  [[ -n "$captured_at" ]] || captured_at="$(workflow_timestamp)"
  tmp_path="$manifest.tmp"
  jq --argjson pass "$pass" \
     --argjson added_count "$GUEST_INCREMENTAL_FILE_COUNT" \
     --argjson added_bytes "$added_bytes" --arg added_hash "$added_hash" \
     --argjson modified_count "$modified_count" --arg modified_hash "$modified_hash" \
     --argjson total_count "$total_count" --argjson total_bytes "$total_bytes" \
     --arg total_hash "$total_hash" --arg captured_at "$captured_at" \
     --slurpfile added_files <(printf '%s\n' "$added") \
     --slurpfile modified_files <(printf '%s\n' "$modified_records") \
     '.incrementals += [{
        pass: $pass, files_added: $added_count,
        added_payload_bytes: $added_bytes, added_manifest_sha256: $added_hash,
        files_modified: $modified_files[0], modified_file_count: $modified_count,
        modified_manifest_sha256: $modified_hash,
        total_file_count: $total_count, total_payload_bytes: $total_bytes,
        manifest_sha256: $total_hash, files: $added_files[0], captured_at: $captured_at
      }] |
      .combined = {total_file_count: $total_count, total_payload_bytes: $total_bytes,
                   manifest_sha256: $total_hash}' \
     "$manifest" > "$tmp_path"
  jq -e --argjson pass "$pass" \
    '.schema_version == 2 and
     (.baseline.files | length) == .baseline.file_count and
     (.incrementals | length) == $pass and
     .incrementals[-1].pass == $pass' "$tmp_path" >/dev/null
  mv -f "$tmp_path" "$manifest"
}

# Extend a completed manifest by exactly one planned incremental pass. A
# repeated request for the same target is idempotent when the target total is
# already recorded.
workload_manifest_extend_plan() {
  local manifest="$1" from_total="$2" target_total="$3"
  local manifest_total manifest_passes tmp_path
  if ! [[ "$from_total" =~ ^[1-9][0-9]?$ &&
          "$target_total" =~ ^[1-9][0-9]?$ ]] ||
     ((target_total != from_total + 1 || target_total > 99)); then
    printf 'Invalid extension target: expected one pass after %s, got %s.\n' \
      "$from_total" "$target_total" >&2
    return 1
  fi
  if [[ ! -r "$manifest" ]] || ! workload_manifest_validate "$manifest" false; then
    printf 'Cannot extend a missing or invalid workload manifest: %s\n' "$manifest" >&2
    return 1
  fi
  manifest_total="$(jq -r '.incremental_passes_total' "$manifest")"
  manifest_passes="$(jq -r '.incrementals | length' "$manifest")"
  if [[ "$manifest_total" == "$target_total" ]]; then
    if [[ "$manifest_passes" == "$from_total" || "$manifest_passes" == "$target_total" ]]; then
      return 0
    fi
    printf 'Cannot resume extension: manifest total=%s but recorded passes=%s.\n' \
      "$manifest_total" "$manifest_passes" >&2
    return 1
  fi
  if [[ "$manifest_total" != "$from_total" ||
        "$manifest_passes" != "$from_total" ]] ||
     ! workload_manifest_validate "$manifest" true; then
    printf 'Cannot extend manifest: expected %s completed passes; found total=%s completed=%s.\n' \
      "$from_total" "$manifest_total" "$manifest_passes" >&2
    return 1
  fi
  tmp_path="${manifest}.tmp.$$"
  if ! jq --argjson from "$from_total" --argjson target "$target_total" \
      'if .incremental_passes_total == $from and (.incrementals | length) == $from
       then .incremental_passes_total = $target
       else error("manifest pass total changed during extension") end' \
      "$manifest" > "$tmp_path"; then
    rm -f "$tmp_path"
    printf 'Could not update workload manifest pass total from %s to %s.\n' \
      "$from_total" "$target_total" >&2
    return 1
  fi
  if ! workload_manifest_validate "$tmp_path" false; then
    rm -f "$tmp_path"
    return 1
  fi
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
  local baseline_files baseline_digest incrementals_json incremental_files modified_files item
  local all_files unique_count pass pass_count incremental_digest cumulative_files cumulative_digest
  local added_bytes cumulative_bytes cumulative_count modified_count modified_digest
  if [[ ! -r "$manifest" ]] || ! jq -e \
      --argjson require_incremental "$([[ "$require_incremental" == true ]] && printf true || printf false)" '
        def valid_file($phase; $pass; $pattern; $min_bytes; $max_bytes):
          .phase == $phase
          and .pass == $pass
          and (.path | test($pattern))
          and (.size_bytes | type == "number")
          and .size_bytes >= $min_bytes
          and .size_bytes <= $max_bytes
          and (.sha256 | test("^[0-9a-f]{64}$"));
        . as $m
        | $m.schema_version == 2
        and ($m.run_id | type == "string" and length > 0)
        and $m.size_assignment_algorithm == "sha256-filename-v1"
        and $m.content_algorithm == "repeated-ascii-identity-v1"
        and ($m.modification_content_algorithm == null or
             $m.modification_content_algorithm == "pass-versioned-baseline-v1")
        and ($m.guest_directory | type == "string" and length > 0)
        and ($m.size_range_mib.min_inclusive | type == "number" and . > 0)
        and ($m.size_range_mib.max_inclusive | type == "number")
        and $m.size_range_mib.max_inclusive >= $m.size_range_mib.min_inclusive
        and ($m.incremental_passes_total | type == "number" and . >= 1 and . <= 99)
        and ($m.incremental_file_count_per_pass | type == "number" and . > 0)
        and ($m.baseline.files | type == "array")
        and $m.baseline.file_count == ($m.baseline.files | length)
        and ($m.baseline.file_count | type == "number" and . > 0)
        and ($m.baseline.total_payload_bytes | type == "number" and . > 0)
        and ($m.baseline.manifest_sha256 | test("^[0-9a-f]{64}$"))
        and all($m.baseline.files[];
          valid_file("baseline"; 0; "^base-[0-9]{6}[.]dat$";
            ($m.size_range_mib.min_inclusive * 1048576);
            ($m.size_range_mib.max_inclusive * 1048576)))
        and ($m.incrementals | type == "array")
        and ($m.incrementals | length) <= $m.incremental_passes_total
        and (if $require_incremental then
               ($m.incrementals | length) == $m.incremental_passes_total
             else true end)
        and ([$m.incrementals[].pass] == [range(1; ($m.incrementals | length) + 1)])
        and all($m.incrementals[];
          . as $inc |
          ($inc.files | type == "array")
          and $inc.files_added == ($inc.files | length)
          and $inc.files_added == $m.incremental_file_count_per_pass
          and ($inc.added_payload_bytes | type == "number" and . > 0)
          and ($inc.added_manifest_sha256 | test("^[0-9a-f]{64}$"))
          and (($inc.files_modified // []) | type == "array")
          and (($inc.files_modified // []) | length) == ($inc.modified_file_count // 0)
          and ([$inc.files_modified[]?.path] | unique | length) == (($inc.files_modified // []) | length)
          and (if (($inc.files_modified // []) | length) == 0 then true
               else ($inc.modified_manifest_sha256 | test("^[0-9a-f]{64}$")) end)
          and all(($inc.files_modified // [])[];
            valid_file("baseline"; 0; "^base-[0-9]{6}[.]dat$";
              ($m.size_range_mib.min_inclusive * 1048576);
              ($m.size_range_mib.max_inclusive * 1048576)))
          and all($inc.files[];
            valid_file("incremental"; $inc.pass;
              ("^incremental-" + ($inc.pass | tostring | if length == 1 then "0" + . else . end) + "-[0-9]{6}[.]dat$");
              ($m.size_range_mib.min_inclusive * 1048576);
              ($m.size_range_mib.max_inclusive * 1048576)))
          and ($inc.total_file_count | type == "number")
          and ($inc.total_payload_bytes | type == "number")
          and ($inc.manifest_sha256 | test("^[0-9a-f]{64}$")))
        and ($m.combined | type == "object")
        and ($m.combined.total_file_count | type == "number")
        and ($m.combined.total_payload_bytes | type == "number")
        and ($m.combined.manifest_sha256 | test("^[0-9a-f]{64}$"))
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

  incrementals_json="$(jq -c '.incrementals' "$manifest")"
  pass_count="$(workload_records_count "$incrementals_json")"
  cumulative_files="$baseline_files"
  for ((pass = 1; pass <= pass_count; pass++)); do
    item="$(jq -c --argjson pass "$pass" '.incrementals[] | select(.pass == $pass)' "$manifest")"
    incremental_files="$(jq -c '.files' <<< "$item")"
    incremental_digest="$(workload_records_digest "$incremental_files")"
    added_bytes="$(workload_records_bytes "$incremental_files")"
    if [[ "$incremental_digest" != "$(jq -r '.added_manifest_sha256' <<< "$item")" ||
          "$added_bytes" != "$(jq -r '.added_payload_bytes' <<< "$item")" ]]; then
      printf 'Incremental pass %s summary does not match its file entries: %s\n' "$pass" "$manifest" >&2
      return 1
    fi
    modified_files="$(jq -c '.files_modified // []' <<< "$item")"
    modified_count="$(workload_records_count "$modified_files")"
    if [[ "$modified_count" != "$(jq -r '.modified_file_count // 0' <<< "$item")" ]]; then
      printf 'Modified file count for pass %s does not match its records: %s\n' "$pass" "$manifest" >&2
      return 1
    fi
    if ((modified_count > 0)); then
      workload_validate_modified_records "$modified_files" "$pass"
      modified_digest="$(workload_records_digest "$modified_files")"
      if [[ "$modified_digest" != "$(jq -r '.modified_manifest_sha256' <<< "$item")" ]]; then
        printf 'Modified file summary for pass %s does not match its records: %s\n' "$pass" "$manifest" >&2
        return 1
      fi
    fi
    cumulative_files="$(workload_records_apply_modifications "$cumulative_files" "$modified_files")"
    cumulative_files="$(workload_records_concat "$cumulative_files" "$incremental_files")"
    cumulative_count="$(workload_records_count "$cumulative_files")"
    cumulative_bytes="$(workload_records_bytes "$cumulative_files")"
    cumulative_digest="$(workload_records_digest "$cumulative_files")"
    if [[ "$cumulative_count" != "$(jq -r '.total_file_count' <<< "$item")" ||
          "$cumulative_bytes" != "$(jq -r '.total_payload_bytes' <<< "$item")" ||
          "$cumulative_digest" != "$(jq -r '.manifest_sha256' <<< "$item")" ]]; then
      printf 'Cumulative workload summary for pass %s does not match its file entries: %s\n' "$pass" "$manifest" >&2
      return 1
    fi
  done

  all_files="$cumulative_files"
  unique_count="$(jq -r '[.[].path] | unique | length' <<< "$all_files")"
  if [[ "$unique_count" != "$(workload_records_count "$all_files")" ||
        "$(workload_records_count "$all_files")" != "$(jq -r '.combined.total_file_count' "$manifest")" ||
        "$(workload_records_bytes "$all_files")" != "$(jq -r '.combined.total_payload_bytes' "$manifest")" ||
        "$(workload_records_digest "$all_files")" != "$(jq -r '.combined.manifest_sha256' "$manifest")" ]]; then
    printf 'Combined workload manifest summary does not match its file entries: %s\n' "$manifest" >&2
    return 1
  fi
}

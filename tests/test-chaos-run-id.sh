#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$ROOT_DIR/cbt-chaos/run-id.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

run_id="$("$GENERATOR" vm-density-0001 full-copy 12)"
if [[ ! "$run_id" =~ ^[0-9]{2}-[0-9]{2}-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-vm-density-0001-full-copy-iteration-12$ ]]; then
  printf 'FAIL: unexpected chaos ID: %s\n' "$run_id" >&2
  exit 1
fi

expect_invalid() {
  local status=0
  "$GENERATOR" "$@" > "$TEST_TMP/stdout" 2> "$TEST_TMP/stderr" || status=$?
  if [[ "$status" != 2 || -s "$TEST_TMP/stdout" || ! -s "$TEST_TMP/stderr" ]]; then
    printf 'FAIL: invalid input must exit 2 with stderr and no ID: %s\n' "$*" >&2
    exit 1
  fi
}

expect_invalid
expect_invalid vm-demo full-copy
expect_invalid vm-demo full-copy 1 extra
expect_invalid '../vm-demo' full-copy 1
expect_invalid vm-demo '../copy' 1
expect_invalid vm-demo '' 1
expect_invalid vm-demo full-copy 0
expect_invalid vm-demo full-copy -1
expect_invalid vm-demo full-copy 01
expect_invalid vm-demo full-copy one
printf -v long_note '%0230d' 0
expect_invalid vm-demo "$long_note" 1

printf 'PASS: chaos run ID format, exact VM/note/iteration, and unsafe input rejection\n'

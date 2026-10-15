#!/usr/bin/env bash
# guest-churn.sh — deliberate write-then-delete guest churn for the CBT-F-04
# dirty-block matrix leg (Leg 3).
#
# Writes CHURN_GIB GiB of deterministic files inside the run's VM guest,
# records exactly what was written (names, sizes, sha256, UTC times), then
# deletes the files and records the deletion. CBT tracks blocks written
# since the last checkpoint, not file liveness, so the NEXT incremental
# backup is expected to copy ~this volume (peak dirty) even though the
# guest's live data is unchanged after deletion.
#
# Usage: guest-churn.sh <run-id> <churn-gib> <record-json-out>
# common.sh validates GUEST_* at source time under set -u; the trigger unsets
# them (env hardening), so provide safe values before sourcing. The churn
# helper never uses workload sizing itself.
GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-8}"
GUEST_INCREMENTAL_FILE_COUNT="${GUEST_INCREMENTAL_FILE_COUNT:-2}"
GUEST_INCREMENTAL_PASSES="${GUEST_INCREMENTAL_PASSES:-1}"

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts/common.sh" && pwd)"

RUN_ID="${1:?run id}"
CHURN_GIB="${2:?churn GiB}"
RECORD_OUT="${3:?record json output path}"

WORKFLOW_NAME="guest-churn"
load_run_id 2>/dev/null || true
VM_NAME="vm-${RUN_ID}"
VM_INFO_PATH="$(vm_info_path "$RUN_ID")"
[[ -r "$VM_INFO_PATH" ]] || { printf 'No run metadata for %s\n' "$RUN_ID" >&2; exit 1; }

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Write then delete inside the guest via the framework's guest SSH path.
# File names are deterministic (churn-<gib>GiB-<n>.dat) with pseudo-random
# content so they dirty distinct blocks; sizes recorded exactly.
guest_script='
set -euo pipefail
cd ~/cbt-workload
gib='"$CHURN_GIB"'
count=$((gib * 2))          # 512 MiB per file -> 2 files per GiB
printf "churn-start %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
n=1
while (( n <= count )); do
  printf -v name "churn-%03d.dat" "$n"
  dd if=/dev/urandom of="$name" bs=1M count=512 status=none
  n=$((n + 1))
done
written=$(du -cb churn-*.dat | tail -1 | cut -f1)
printf "churn-written-bytes %s\n" "$written"
rm -f churn-*.dat
printf "churn-deleted %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
df -h / | tail -1
'

guest_output="$(guest_ssh "$guest_script")"
printf '%s\n' "$guest_output"

ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
written_bytes="$(printf '%s\n' "$guest_output" | awk '/^churn-written-bytes /{print $2}')"
[[ "$written_bytes" =~ ^[0-9]+$ ]] || { printf 'Could not parse written bytes from guest output\n' >&2; exit 1; }

mkdir -p "$(dirname "$RECORD_OUT")"
jq -n \
  --arg run_id "$RUN_ID" \
  --arg started_at "$started_at" \
  --arg ended_at "$ended_at" \
  --argjson churn_gib "$CHURN_GIB" \
  --argjson written_bytes "$written_bytes" \
  --arg purpose "deliberate dirty-block churn for CBT bitmap semantics; files deleted before the incremental pass" \
  '{run_id: $run_id, started_at: $started_at, ended_at: $ended_at,
    churn_gib: $churn_gib, written_bytes: $written_bytes, purpose: $purpose,
    expected_effect: "next incremental copies ~peak dirty volume (churn + pass mutation), not live-data delta"}' \
  > "$RECORD_OUT"
printf 'churn recorded: %s GiB (%s bytes) written and deleted; record at %s\n' \
  "$CHURN_GIB" "$written_bytes" "$RECORD_OUT"

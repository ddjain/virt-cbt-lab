#!/usr/bin/env bash
set -euo pipefail
# Offline (fake oc, no cluster): fleet group object naming is defined once in
# cbt-scale/lib-naming.sh, fleet-verify.sh finds exactly the objects the driver
# creates, and fleet-e2e.sh reset deletes only the target group's objects
# (regression: reset once ran `oc delete ... -o name | grep`, wiping every
# vmbackup in the namespace).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCALE="$ROOT_DIR/cbt-scale"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

G=rhel9-light-20-11-2026-10-04-59
OTHER=rhel9-light-19-11-2026-08-00-00
OK='Successfully completed VirtualMachineBackup'

# shellcheck source=../cbt-scale/lib-naming.sh
source "$SCALE/lib-naming.sh"

# 1. Names: a fleet VM name and its bare rid yield the same stripped names.
[[ "$(scale_full_name "$G" vm-fleet-rhl-0001)" == "vm-backup-$G-fleet-rhl-0001" ]] || fail "full name"
[[ "$(scale_full_name "$G" fleet-rhl-0001)" == "vm-backup-$G-fleet-rhl-0001" ]] || fail "full name idempotent"
[[ "$(scale_incr_name "$G" vm-fleet-rhl-0001 1)" == "vm-incremental-$G-fleet-rhl-0001-p01" ]] || fail "incr name"
[[ "$(scale_tracker_name "$G" vm-fleet-rhl-0001)" == "vm-tracker-$G-fleet-rhl-0001" ]] || fail "tracker name"

# Fake oc over a fixed namespace: this group (stripped names), another group,
# and a non-fleet run. Records every call.
cat > "$TEST_TMP/bin/oc" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FAKE_OC_LOG"
case "\$*" in
  "get vmbackup -n vm-cbt-demo vm-backup-$G-fleet-rhl-0001 "*|"get vmbackup -n vm-cbt-demo vm-incremental-$G-fleet-rhl-0001-p01 "*) printf '%s' '$OK' ;;
  "get vmbackuptracker -n vm-cbt-demo vm-tracker-$G-fleet-rhl-0001 "*) printf '%s' 'vm-incremental-$G-fleet-rhl-0001-p01-cp' ;;
  "get vmbackup -n vm-cbt-demo -o custom-columns"*)
    printf '%s\n' vm-backup-$G-fleet-rhl-0001 vm-incremental-$G-fleet-rhl-0001-p01 \\
      vm-backup-$OTHER-fleet-rhl-0001 vm-incremental-$OTHER-fleet-rhl-0001-p01 vm-backup-fleet-rhl-0001 ;;
  "get vmbackuptracker -n vm-cbt-demo -o custom-columns"*)
    printf '%s\n' vm-tracker-$G-fleet-rhl-0001 vm-tracker-$OTHER-fleet-rhl-0001 ;;
  "get pvc -n vm-cbt-demo -o custom-columns"*)
    printf '%s\n' vm-backup-pvc-$G-fleet-rhl-0001 vm-incremental-pvc-$G-fleet-rhl-0001-p01 vm-backup-pvc-$OTHER-fleet-rhl-0001 root-fleet-rhl-0001 ;;
  "get pv -o json") printf '{"items":[]}' ;;
  "get vmbackup "*|"get vmbackuptracker "*) printf 'missing' >&2; exit 1 ;;
esac
EOF
chmod +x "$TEST_TMP/bin/oc"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/bin/sleep"; chmod +x "$TEST_TMP/bin/sleep"
export PATH="$TEST_TMP/bin:$PATH" FAKE_OC_LOG="$TEST_TMP/oc.log" KUBECONFIG=/nonexistent
state="$TEST_TMP/state"; mkdir -p "$state/groups"
printf 'vm\tstate\tfull\tincr\tresult\nvm-fleet-rhl-0001\tpending\t-\t-\t-\n' > "$state/groups/$G.yaml"

# 2. fleet-verify looks up the stripped names and passes.
: > "$FAKE_OC_LOG"
SCALE_STATE_DIR="$state" bash "$SCALE/fleet-verify.sh" "$G" >"$TEST_TMP/verify.out" 2>&1 \
  || { cat "$TEST_TMP/verify.out"; fail "fleet-verify did not pass for stripped names"; }
grep -q 'verify: 1/1 pass' "$TEST_TMP/verify.out" || fail "verify output"

# 3. reset deletes only this group's objects and never enumerates via delete.
: > "$FAKE_OC_LOG"
SCALE_STATE_DIR="$state" bash "$SCALE/fleet-e2e.sh" reset "$G" >/dev/null 2>&1 || fail "reset exited non-zero"
if grep -E '^delete [a-z]+ .*-o name' "$FAKE_OC_LOG"; then fail "reset enumerates with oc delete"; fi
deleted="$(grep -E '^delete ' "$FAKE_OC_LOG" || true)"
[[ -n "$deleted" ]] || fail "reset deleted nothing"
if [[ "$deleted" == *"$OTHER"* ]]; then fail "reset touched another group"; fi
if grep -E '^delete (vmbackup|vmbackuptracker|pvc) ' "$FAKE_OC_LOG" | grep -E ' (vm-backup-fleet-rhl-0001|root-fleet-rhl-0001)( |$)'; then
  fail "reset touched non-group objects"
fi
for n in vm-backup-$G-fleet-rhl-0001 vm-incremental-$G-fleet-rhl-0001-p01 vm-tracker-$G-fleet-rhl-0001 \
         vm-backup-pvc-$G-fleet-rhl-0001 vm-incremental-pvc-$G-fleet-rhl-0001-p01; do
  grep -q "$n" <<<"$deleted" || fail "reset did not delete $n"
done

printf 'PASS: fleet naming and scoped reset\n'

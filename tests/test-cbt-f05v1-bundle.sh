#!/usr/bin/env bash
set -euo pipefail
# CBT-F-05V1 offline self-test. No cluster, container runtime, network, build or
# fault. The rehearsal tree lives under a temporary directory, never under the
# repository's runs/ trees.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_SRC="$ROOT/cbt-chaos/scenarios_v2/CBT-F-05V1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REHEARSAL="$TMP/cbt-chaos/scenarios_v2/CBT-F-05V1"
mkdir -p "$REHEARSAL" "$TMP/scripts" "$TMP/cbt-chaos"

cp "$BUNDLE_SRC/run.sh" "$BUNDLE_SRC/inject.sh" "$BUNDLE_SRC/condition.sh" \
   "$BUNDLE_SRC/checks.jq" "$BUNDLE_SRC/product-guard.sh" "$BUNDLE_SRC/cleanup-observer.py" \
   "$BUNDLE_SRC/guest-key-approval.sh" "$BUNDLE_SRC/bundle-files.txt" \
   "$BUNDLE_SRC/approval.json" "$REHEARSAL/"
cp "$ROOT/scripts/run-id.sh" "$TMP/scripts/"
cp "$ROOT/cbt-chaos/scenario-runtime.sh" "$TMP/cbt-chaos/"

export LIFECYCLE_ID=f05v1-offline
export CHAOS_RUN_ID="16-10-2026-01-02-03-vm-${LIFECYCLE_ID}-full-copy-iteration-1"
RUN="$REHEARSAL/runs/$CHAOS_RUN_ID"

# --- guest-key approval modes -------------------------------------------------
source "$REHEARSAL/guest-key-approval.sh"
KEY_DIR="$TMP/key-approval"
mkdir -p "$KEY_DIR"
KEY="$KEY_DIR/id_ed25519"
approval="$(guest_key_approval_parameters "$KEY")"
jq -e '.mode == "setup-managed" and .public_sha256 == null' <<<"$approval" >/dev/null
[[ ! -e "$KEY" && ! -e "$KEY.pub" ]] || { printf 'FAIL: missing key preflight generated a key\n' >&2; exit 1; }
: > "$KEY"
approval="$(guest_key_approval_parameters "$KEY")"
jq -e '.mode == "setup-managed" and .public_sha256 == null' <<<"$approval" >/dev/null
[[ -f "$KEY" && ! -e "$KEY.pub" ]] || { printf 'FAIL: incomplete key preflight changed key files\n' >&2; exit 1; }
printf 'ssh-ed25519 test-public-half\n' > "$KEY.pub"
expected_fingerprint="$(sha256sum "$KEY.pub" | cut -d ' ' -f1)"
approval="$(guest_key_approval_parameters "$KEY")"
jq -e --arg fingerprint "$expected_fingerprint" \
  '.mode == "existing-pair" and .public_sha256 == $fingerprint' <<<"$approval" >/dev/null
[[ "$(guest_key_capture_after_setup "$KEY")" == "$expected_fingerprint" ]] ||
  { printf 'FAIL: post-setup public fingerprint mismatch\n' >&2; exit 1; }
BAD_KEY="$KEY_DIR/not-a-private-key"
mkdir "$BAD_KEY"
if guest_key_approval_parameters "$BAD_KEY" >/dev/null 2>&1; then
  printf 'FAIL: non-regular existing key accepted\n' >&2; exit 1
fi

# --- manifest completeness and placeholder approval ---------------------------
for file in run.sh inject.sh condition.sh checks.jq product-guard.sh cleanup-observer.py \
            guest-key-approval.sh bundle-files.txt scenario-spec.md jira-issue.md; do
  grep -Fxq "cbt-chaos/scenarios_v2/CBT-F-05V1/$file" "$BUNDLE_SRC/bundle-files.txt" ||
    { printf 'FAIL: bundle file not in the hash manifest: %s\n' "$file" >&2; exit 1; }
done
grep -Fxq 'cbt-chaos/scenario-runtime.sh' "$BUNDLE_SRC/bundle-files.txt" ||
  { printf 'FAIL: shared runtime helper missing from the manifest\n' >&2; exit 1; }
grep -Fxq 'tests/test-cbt-f05v1-bundle.sh' "$BUNDLE_SRC/bundle-files.txt" &&
grep -Fxq 'tests/test-cbt-f05v1-cleanup.py' "$BUNDLE_SRC/bundle-files.txt" ||
  { printf 'FAIL: offline tests missing from the manifest\n' >&2; exit 1; }
grep -Fxq '.env' "$BUNDLE_SRC/bundle-files.txt" ||
  { printf 'FAIL: .env digest entry missing from the manifest\n' >&2; exit 1; }
while IFS= read -r file; do
  [[ -f "$ROOT/$file" ]] || { printf 'FAIL: manifest entry does not exist: %s\n' "$file" >&2; exit 1; }
done < "$BUNDLE_SRC/bundle-files.txt"
jq -e '.scenario_id == "CBT-F-05V1" and .status == "NOT_APPROVED"
       and .approved_by == null and .approved_at == null
       and (.parameters | length) == 0 and (.files | length) == 0' \
  "$BUNDLE_SRC/approval.json" >/dev/null ||
  { printf 'FAIL: approval placeholder is not NOT_APPROVED with empty binding\n' >&2; exit 1; }

# --- manifest mode ------------------------------------------------------------
diff <(bash "$REHEARSAL/run.sh" --manifest) "$REHEARSAL/bundle-files.txt" >/dev/null ||
  { printf 'FAIL: --manifest does not print the declared manifest\n' >&2; exit 1; }

# --- run-root identity and freshness -----------------------------------------
mkdir -p "$RUN"
printf '%s\n' '{"scenario_id":"CBT-F-05V1","run_id":"wrong","lifecycle_id":"f05v1-offline","vm_name":"vm-f05v1-offline"}' \
  > "$RUN/run.json"
reject_root() {
  local rc=0
  bash "$REHEARSAL/run.sh" --check-root > "$TMP/stdout" 2> "$TMP/stderr" || rc=$?
  [[ "$rc" == 2 && -s "$TMP/stderr" ]] || { printf 'FAIL: unsafe run root accepted\n' >&2; exit 1; }
}
reject_root
jq --arg id "$CHAOS_RUN_ID" '.run_id = $id' "$RUN/run.json" > "$TMP/run.json"
mv "$TMP/run.json" "$RUN/run.json"
# The Lead-created matching root is accepted, including read-only preflight evidence.
mkdir "$RUN/preflight"
bash "$REHEARSAL/run.sh" --check-root
for output in execution action action.argv condition.json cleanup-check.json \
              injection-confirmation.json handoff.json analysis.json; do
  printf 'immutable evidence\n' > "$RUN/$output"
  reject_root
  [[ "$(cat "$RUN/$output")" == 'immutable evidence' ]] ||
    { printf 'FAIL: check-root modified evidence\n' >&2; exit 1; }
  rm "$RUN/$output"
done
printf '%s\n' "{\"scenario_id\":\"CBT-F-05V1\",\"run_id\":\"$CHAOS_RUN_ID\",\"lifecycle_id\":\"f05v1-offline\",\"vm_name\":\"vm-f05v1-offline\",\"phase\":\"closed\",\"verdict\":\"FAIL\"}" \
  > "$RUN/run.json"
reject_root
printf '%s\n' "{\"scenario_id\":\"CBT-F-05V1\",\"run_id\":\"$CHAOS_RUN_ID\",\"lifecycle_id\":\"f05v1-offline\",\"vm_name\":\"vm-f05v1-offline\",\"verdict\":\"PASS\"}" \
  > "$RUN/run.json"
reject_root
printf '%s\n' "{\"scenario_id\":\"CBT-F-05V1\",\"run_id\":\"$CHAOS_RUN_ID\",\"lifecycle_id\":\"f05v1-offline\",\"vm_name\":\"vm-f05v1-offline\"}" \
  > "$RUN/run.json"
mkdir -p "$TMP/runs/$LIFECYCLE_ID"
reject_root
rmdir "$TMP/runs/$LIFECYCLE_ID"
bash "$REHEARSAL/run.sh" --check-root

# --- offline plan -------------------------------------------------------------
bash "$REHEARSAL/run.sh" --plan > "$TMP/plan.json"
jq -e --arg id "$CHAOS_RUN_ID" --arg life "$LIFECYCLE_ID" '
  .scenario == "CBT-F-05V1" and .chaos_run_id == $id and .lifecycle_id == $life
  and .fault.action_file == "inject.sh" and .fault.uses_krkn == true
  and .fault.triggers_on_timeout == "fail" and .fault.max_deletions == 1
  and .fault.force == false
  and .cleanup.read_only == true and .cleanup.new_pods == false
  and .cleanup.observation_window_seconds == 300
  and .cleanup.sample_interval_seconds == 10
  and .cleanup.process_timeout_seconds == 2520
  and .cleanup.terminal_discovery_timeout_seconds == 2100
  and .cleanup.read_timeout_seconds == 12
  and .cleanup.first_observation_max_lag_seconds == 60
  and .evaluator.status == "NOT_APPLICABLE" and .evaluator.fallback_invoked == false
  and (.named_criteria | length) == 9' "$TMP/plan.json" >/dev/null ||
  { printf 'FAIL: offline plan is missing the approved contract\n' >&2; exit 1; }

# --- predicate boundaries ----------------------------------------------------
# Missing/unsafe copy signals and a completed copy must never open the window.
for jobs in '{}' '{"return":[]}' \
            '{"return":[{"type":"backup","status":"running","offset":0,"len":100}]}' \
            '{"return":[{"type":"backup","status":"running","offset":100,"len":100}]}' \
            '{"return":[{"type":"backup","status":"concluded","offset":50,"len":100}]}' \
            '{"return":[{"type":"mirror","status":"running","offset":50,"len":100}]}'; do
  if jq -en -L "$REHEARSAL" --argjson jobs "$jobs" 'include "checks"; $jobs | active_jobs' >/dev/null; then
    printf 'FAIL: invalid active-copy signal accepted: %s\n' "$jobs" >&2; exit 1
  fi
done
jq -en -L "$REHEARSAL" 'include "checks"; {return:[{type:"backup",status:"running",offset:1,len:100}]} | active_jobs' >/dev/null

# Target selection excludes the wrong node, owner, readiness and deleting pods.
jq -en -L "$REHEARSAL" 'include "checks";
  def pod($name;$node;$owner;$ready;$deleting): {
    metadata:{name:$name,uid:$name,labels:{"kubevirt.io":"virt-handler"},
      deletionTimestamp:$deleting,ownerReferences:[{kind:"DaemonSet",uid:$owner}]},
    spec:{nodeName:$node},status:{phase:"Running",conditions:[{type:"Ready",status:$ready}]}};
  {items:[pod("good";"node";"ds";"True";null), pod("wrong-node";"other";"ds";"True";null),
          pod("wrong-owner";"node";"other";"True";null), pod("unready";"node";"ds";"False";null),
          pod("deleting";"node";"ds";"True";"now")]}
  | target("node";"ds") | length == 1 and .[0].metadata.name == "good"' >/dev/null

# The copy candidate must be this run's fresh, nonterminal, run-labeled backup.
copy_probe() {
  jq -en -L "$REHEARSAL" --arg created "$1" --arg label "$2" --arg source "$3" \
    --arg done "$4" 'include "checks";
    {metadata:{uid:"u",creationTimestamp:$created,deletionTimestamp:null,
       labels:{"virt-cbt-lab/run-id":$label}},
     spec:{source:{name:$source}},
     status:{conditions:[{type:"Done",status:$done}]}}
    | copy_candidate("life";"tracker";"2026-10-23T00:00:00Z")'
}
[[ "$(copy_probe 2026-10-23T00:00:05Z life tracker False)" == true ]] ||
  { printf 'FAIL: a valid fresh copy candidate was rejected\n' >&2; exit 1; }
for fields in '2026-10-23T00:00:05Z|other|tracker|False' \
              '2026-10-23T00:00:05Z|life|other|False' \
              '2026-10-22T23:00:00Z|life|tracker|False' \
              '2026-10-23T00:00:05Z|life|tracker|True'; do
  IFS='|' read -r created label source done <<< "$fields"
  [[ "$(copy_probe "$created" "$label" "$source" "$done")" == false ]] ||
    { printf 'FAIL: an unowned/non-fresh/completed backup was accepted: %s\n' "$fields" >&2; exit 1; }
done

# Sibling exclusion keeps identity/node/readiness/restart fields for all others.
jq -en -L "$REHEARSAL" 'include "checks";
  def pod($uid;$node;$ready;$restarts): {metadata:{name:$uid,uid:$uid},spec:{nodeName:$node},
    status:{phase:"Running",restartCount:$restarts,
      conditions:[{type:"Ready",status:$ready}],
      containerStatuses:[{restartCount:$restarts}]}};
  {items:[pod("target";"n";"True";0), pod("sibling";"n";"True";2)]}
  | siblings("target") | length == 1 and .[0].uid == "sibling" and .[0].restarts == 2' >/dev/null

# Headroom must be the exact pool's trusted logical max_avail, never raw bytes.
for capacity in '{"stats":{"total_avail_bytes":99999999999999}}' \
                '{"pools":[{"name":"other","stats":{"max_avail":99999999999999}}]}' \
                '{"pools":[{"name":"pool","stats":{"max_avail":99}}]}' \
                '{"pools":[{"name":"pool","stats":{"max_avail":"1000"}}]}'; do
  if jq -en -L "$REHEARSAL" --argjson capacity "$capacity" \
       'include "checks"; $capacity | pool_headroom("pool"; 100)' >/dev/null; then
    printf 'FAIL: untrustworthy destination headroom accepted: %s\n' "$capacity" >&2; exit 1
  fi
done
jq -en -L "$REHEARSAL" 'include "checks"; {pools:[{name:"pool",stats:{max_avail:100}}]} | pool_headroom("pool";100)' >/dev/null
jq -en -L "$REHEARSAL" 'include "checks"; {items:[{status:{hard:{"requests.storage":"1Gi"}}}]} | no_storage_quota | not' >/dev/null
jq -en -L "$REHEARSAL" 'include "checks"; {items:[{status:{hard:{cpu:"1"}}}]} | no_storage_quota' >/dev/null

# --- inject.sh operand guards (no cluster read, no container, no cidfile) -----
inject_reject() {
  local rc=0
  env -i PATH="$PATH" HOME="$HOME" "$@" > "$TMP/inject.stdout" 2> "$TMP/inject.stderr" || rc=$?
  [[ "$rc" == 2 ]] || { printf 'FAIL: inject.sh accepted invalid operands (rc=%s)\n' "$rc" >&2; exit 1; }
}
base_env=(BUNDLE_DIR="$REHEARSAL" TARGET_NAMESPACE=openshift-cnv
  TARGET_NAME=virt-handler-abcde TARGET_UID=11111111-1111-1111-1111-111111111111
  TARGET_NODE=worker-0 TARGET_DS_UID=22222222-2222-2222-2222-222222222222
  KUBECONFIG_PATH="$TMP/no-such-kubeconfig"
  EVIDENCE_DIR="$TMP/evidence" IMAGE="example.invalid/krkn@sha256:$(printf 'a%.0s' {1..64})"
  CIDFILE="$TMP/container.cid")
mkdir -p "$TMP/evidence"
# Missing operands first.
inject_reject bash "$REHEARSAL/inject.sh"
inject_reject env TARGET_NAMESPACE=openshift-cnv bash "$REHEARSAL/inject.sh"
# Wrong namespace widens the blast radius and must be refused.
inject_reject "${base_env[@]}" TARGET_NAMESPACE=default bash "$REHEARSAL/inject.sh"
# A name carrying regex/flag syntax can redirect NAME_PATTERN and is refused.
inject_reject "${base_env[@]}" TARGET_NAME='virt-handler-.*' bash "$REHEARSAL/inject.sh"
inject_reject "${base_env[@]}" TARGET_NAME='virt-handler-abcde -e X=1' bash "$REHEARSAL/inject.sh"
# Degraded UID operands never reach the command.
inject_reject "${base_env[@]}" TARGET_UID=null bash "$REHEARSAL/inject.sh"
inject_reject "${base_env[@]}" TARGET_DS_UID=not-a-uid bash "$REHEARSAL/inject.sh"
# An unpinned image is refused.
inject_reject "${base_env[@]}" IMAGE=example.invalid/krkn:latest bash "$REHEARSAL/inject.sh"
# An unreadable kubeconfig is refused before any container could start.
inject_reject "${base_env[@]}" bash "$REHEARSAL/inject.sh"
[[ ! -e "$TMP/container.cid" ]] ||
  { printf 'FAIL: inject.sh wrote a container id for a rejected invocation\n' >&2; exit 1; }

PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/test-cbt-f05v1-cleanup.py"
printf 'PASS: F05V1 manifest, root freshness, plan, predicates, and inject.sh operand guards\n'

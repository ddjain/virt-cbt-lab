#!/usr/bin/env bash
set -euo pipefail
# Offline consumer tests. No cluster, container runtime, build, or fault.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BUNDLE="$TMP/cbt-chaos/scenarios_v2/CBT-F-05"
mkdir -p "$BUNDLE" "$TMP/scripts"
cp "$ROOT/cbt-chaos/scenarios_v2/CBT-F-05/run.sh" "$BUNDLE/"
cp "$ROOT/cbt-chaos/scenarios_v2/CBT-F-05/checks.jq" "$BUNDLE/"
cp "$ROOT/cbt-chaos/scenarios_v2/CBT-F-05/guest-key-approval.sh" "$BUNDLE/"
source "$BUNDLE/guest-key-approval.sh"
KEY_DIR="$TMP/key-approval"
mkdir -p "$KEY_DIR"
KEY="$KEY_DIR/id_ed25519"
approval="$(guest_key_approval_parameters "$KEY")"
jq -e '.mode=="setup-managed" and .public_sha256==null' <<<"$approval" >/dev/null
[[ ! -e "$KEY" && ! -e "$KEY.pub" ]] || { printf 'FAIL: missing key preflight generated a key\n' >&2; exit 1; }
: > "$KEY"
approval="$(guest_key_approval_parameters "$KEY")"
jq -e '.mode=="setup-managed" and .public_sha256==null' <<<"$approval" >/dev/null
[[ -f "$KEY" && ! -e "$KEY.pub" ]] || { printf 'FAIL: incomplete key preflight changed key files\n' >&2; exit 1; }
printf 'ssh-ed25519 test-public-half\n' > "$KEY.pub"
expected_fingerprint="$(sha256sum "$KEY.pub" | cut -d ' ' -f1)"
approval="$(guest_key_approval_parameters "$KEY")"
jq -e --arg fingerprint "$expected_fingerprint" '.mode=="existing-pair" and .public_sha256==$fingerprint' <<<"$approval" >/dev/null
[[ "$(guest_key_capture_after_setup "$KEY")" == "$expected_fingerprint" ]] || { printf 'FAIL: post-setup public fingerprint mismatch\n' >&2; exit 1; }
BAD_KEY="$KEY_DIR/not-a-private-key"
mkdir "$BAD_KEY"
if guest_key_approval_parameters "$BAD_KEY" >/dev/null 2>&1; then
  printf 'FAIL: non-regular existing key accepted\n' >&2; exit 1
fi
cp "$ROOT/scripts/run-id.sh" "$TMP/scripts/"
export LIFECYCLE_ID=f05-offline
export CHAOS_RUN_ID=16-10-2026-01-02-03-vm-f05-offline-full-copy-iteration-1
RUN="$BUNDLE/runs/$CHAOS_RUN_ID"
mkdir -p "$RUN"
printf '%s\n' '{"scenario_id":"CBT-F-05","run_id":"wrong","lifecycle_id":"f05-offline","vm_name":"vm-f05-offline"}' > "$RUN/run.json"
reject_root() {
  local rc=0
  bash "$BUNDLE/run.sh" --check-root > "$TMP/stdout" 2> "$TMP/stderr" || rc=$?
  [[ "$rc" == 2 && -s "$TMP/stderr" ]] || { printf 'FAIL: unsafe run root accepted\n' >&2; exit 1; }
}
reject_root
jq --arg id "$CHAOS_RUN_ID" '.run_id=$id' "$RUN/run.json" > "$TMP/run.json"
mv "$TMP/run.json" "$RUN/run.json"
# The Lead-created matching root is accepted, including read-only rehearsal evidence.
mkdir "$RUN/preflight"
bash "$BUNDLE/run.sh" --check-root
for output in execution execute action action.json effect effect.json condition.json injection-confirmation.json; do
  printf 'immutable evidence\n' > "$RUN/$output"
  reject_root
  [[ "$(cat "$RUN/$output")" == 'immutable evidence' ]]
  rm "$RUN/$output"
done
mkdir -p "$TMP/runs/$LIFECYCLE_ID"
reject_root
rmdir "$TMP/runs/$LIFECYCLE_ID"
# Missing/malformed copy evidence and completed copy must never open the window.
for jobs in '{}' '{"return":[]}' '{"return":[{"type":"backup","status":"running","offset":0,"len":100}]}' '{"return":[{"type":"backup","status":"running","offset":100,"len":100}]}' '{"return":[{"type":"backup","status":"concluded","offset":50,"len":100}]}' '{"return":[{"type":"mirror","status":"running","offset":50,"len":100}]}'; do
  if jq -en -L "$BUNDLE" --argjson jobs "$jobs" 'include "checks"; $jobs|active_jobs' >/dev/null; then
    printf 'FAIL: invalid active-copy signal accepted\n' >&2; exit 1
  fi
done
jq -en -L "$BUNDLE" 'include "checks"; {return:[{type:"backup",status:"running",offset:1,len:100}]}|active_jobs' >/dev/null
# Headroom must be the exact pool's trusted logical max_avail, never raw bytes.
for capacity in '{"stats":{"total_avail_bytes":99999999999999}}' '{"pools":[{"name":"other","stats":{"max_avail":99999999999999}}]}' '{"pools":[{"name":"pool","stats":{"max_avail":99}}]}' '{"pools":[{"name":"pool","stats":{"max_avail":"1000"}}]}'; do
  if jq -en -L "$BUNDLE" --argjson capacity "$capacity" 'include "checks"; $capacity|pool_headroom("pool";100)' >/dev/null; then
    printf 'FAIL: untrustworthy destination headroom accepted\n' >&2; exit 1
  fi
done
jq -en -L "$BUNDLE" 'include "checks"; {pools:[{name:"pool",stats:{max_avail:100}}]}|pool_headroom("pool";100)' >/dev/null
# Target selection excludes wrong node, owner, readiness and deleting pods.
jq -en -L "$BUNDLE" 'include "checks";
  def pod($name;$node;$owner;$ready;$deleting): {metadata:{name:$name,uid:$name,labels:{"kubevirt.io":"virt-handler"},deletionTimestamp:$deleting,ownerReferences:[{kind:"DaemonSet",uid:$owner}]},spec:{nodeName:$node},status:{phase:"Running",conditions:[{type:"Ready",status:$ready}]}};
  {items:[pod("good";"node";"ds";"True";null),pod("wrong-node";"other";"ds";"True";null),pod("wrong-owner";"node";"other";"True";null),pod("unready";"node";"ds";"False";null),pod("deleting";"node";"ds";"True";"now")]} | target("node";"ds") | length==1 and .[0].metadata.name=="good"' >/dev/null
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/test-cbt-f-05-cleanup.py"
printf 'PASS: F05 root freshness, active-copy, target identity, and logical-headroom boundaries\n'

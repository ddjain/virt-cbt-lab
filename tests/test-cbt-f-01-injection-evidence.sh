#!/usr/bin/env bash
set -euo pipefail

# Contract test between the CBT-F-01 chaos trigger and the deterministic verdict
# evaluator. Runs the real trigger against a stubbed `oc`/`make` pair in a
# throwaway checkout root, then asserts the evaluator recognises the injection
# evidence the trigger actually writes. This is the integration the unit tests
# of either side cannot cover alone: the trigger owns the artifact shape and the
# evaluator owns its parser, so a key rename on either side must fail here.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

SCEN_REL="cbt-chaos/scenarios_v2/CBT-F-01"
SCEN_DIR="$WORK/$SCEN_REL"
mkdir -p "$SCEN_DIR" "$WORK/bin" "$WORK/state"
cp "$ROOT_DIR/$SCEN_REL/chaos-trigger.sh" "$SCEN_DIR/chaos-trigger.sh"
cp "$ROOT_DIR/cbt-chaos/scenario-verdict.sh" "$WORK/cbt-chaos/scenario-verdict.sh"
# The evaluator resolves its check-set registry next to its own bytes; a fixture
# that copies the script must copy the registry with it (otherwise every
# invocation exits 2 with a usage error).
cp "$ROOT_DIR/cbt-chaos/scenario-check-sets.tsv" "$WORK/cbt-chaos/scenario-check-sets.tsv"

RUN_ID="20260101-cbt-f-01-000000"
VM_NAME="vm-$RUN_ID"
# A real run always has an armed independent observer; the evaluator refuses to
# treat the injector as the sole authority for its own injection.
mkdir -p "$SCEN_DIR/runs/$RUN_ID/observer/watches"
printf '{"utc":"2026-01-01T00:00:01Z","watch_pids":[4242]}\n' \
  > "$SCEN_DIR/runs/$RUN_ID/observer/ARMED"
printf '{"type":"BOOKMARK","object":{"metadata":{"name":"%s"}}}\n' "$VM_NAME" \
  > "$SCEN_DIR/runs/$RUN_ID/observer/watches/vmbackup.jsonl"
OLD_UID="11111111-1111-1111-1111-111111111111"
NEW_UID="22222222-2222-2222-2222-222222222222"
OLD_POD="virt-launcher-$VM_NAME-aaaaa"
NEW_POD="virt-launcher-$VM_NAME-bbbbb"

cat >"$WORK/bin/oc" <<SH
#!/usr/bin/env bash
set -euo pipefail
STATE="$WORK/state"
args="\$*"
case "\$args" in
  *"get vm,vmi,vmbackup"*) exit 0 ;;
  "logs --follow"*) printf '{"component":"virt-launcher","level":"info","msg":"Backup started","pos":"backup.go:83","timestamp":"2026-01-01T00:00:10Z"}\n'; exit 0 ;;
  "exec "*) printf ' Name                 Creation Time\n-----------------------------------\n'; exit 0 ;;
  *"--ignore-not-found"*"vmbackuptracker"*) exit 0 ;;
  "delete pod "*) : >"\$STATE/deleted"; exit 0 ;;
esac
if [[ "\$args" == *"-o jsonpath="* ]]; then
  case "\$args" in
    *"{.items[0].metadata.name}"*) printf '%s\n' "$OLD_POD"; exit 0 ;;
    *"{.metadata.uid}"*) printf '%s\n' "$OLD_UID"; exit 0 ;;
  esac
fi
if [[ "\$args" == *"get pod $OLD_POD"* ]]; then
  if [[ -f "\$STATE/deleted" ]]; then exit 0; fi
  printf '{"metadata":{"name":"%s","uid":"%s"},"status":{"phase":"Running"}}\n' "$OLD_POD" "$OLD_UID"
  exit 0
fi
if [[ "\$args" == *"get pods"*"-o json"* ]]; then
  if [[ -f "\$STATE/deleted" ]]; then
    # Reproduce the real race: the first post-delete read can see no matching
    # ready replacement yet. The trigger must keep polling, not report readiness
    # without an identity.
    if [[ ! -f "\$STATE/pods-empty-done" ]]; then
      : >"\$STATE/pods-empty-done"
      printf '{"items":[]}\n'
      exit 0
    fi
    printf '{"items":[{"metadata":{"name":"%s","uid":"%s"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}\n' "$NEW_POD" "$NEW_UID"
  else
    printf '{"items":[{"metadata":{"name":"%s","uid":"%s"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}\n' "$OLD_POD" "$OLD_UID"
  fi
  exit 0
fi
exit 0
SH

cat >"$WORK/bin/make" <<'SH'
#!/usr/bin/env bash
# The interrupted full backup is expected to fail: sleep long enough for the
# observer to fire, then exit non-zero.
sleep 3
exit 7
SH
chmod +x "$WORK/bin/oc" "$WORK/bin/make"

export PATH="$WORK/bin:$PATH"
export RUN_ID KUBECONFIG_PATH="$WORK/kubeconfig.conf"
: >"$KUBECONFIG_PATH"

mkdir -p "$SCEN_DIR/runs/$RUN_ID/trigger"

# --plan must accept the pre-armed run directory (observer armed, Lead state and
# scaffolding present) and still refuse a directory that holds run output — the
# pre-arm ordering otherwise makes the mandated rehearsal unsatisfiable.
PLAN_RUN_ID="20260101-cbt-f-01-plan"
PLAN_DIR="$SCEN_DIR/runs/$PLAN_RUN_ID"
mkdir -p "$PLAN_DIR"/{contracts,observer,trigger,recovery,checkers,reports}
printf '{"phase":"resolved"}\n' > "$PLAN_DIR/state.json"
if ! RUN_ID="$PLAN_RUN_ID" bash "$SCEN_DIR/chaos-trigger.sh" --plan >"$WORK/plan.out" 2>&1; then
  fail "the rehearsal must accept a pre-armed run directory (see $WORK/plan.out)"
fi
grep -q 'pre-armed' "$WORK/plan.out" ||
  fail "--plan did not report the pre-armed run directory it accepted"
grep -q 'local precondition check: clear' "$WORK/plan.out" ||
  fail "--plan did not report a clear precondition for a pre-armed run directory"
printf '{}\n' > "$PLAN_DIR/driver-timings.json"
if RUN_ID="$PLAN_RUN_ID" bash "$SCEN_DIR/chaos-trigger.sh" --plan >"$WORK/plan-collision.out" 2>&1; then
  fail "the rehearsal must still refuse a run directory that holds run output"
fi
grep -q 'already holds run output' "$WORK/plan-collision.out" ||
  fail "the rehearsal refusal did not name the run output it found"
rm -rf "$PLAN_DIR"

set +e
bash "$SCEN_DIR/chaos-trigger.sh" >"$WORK/trigger.out" 2>&1
trigger_status=$?
set -e
[[ "$trigger_status" == "7" ]] ||
  fail "trigger exited $trigger_status instead of the expected interrupted-backup status 7 (see $WORK/trigger.out)"

EVIDENCE="$SCEN_DIR/runs/$RUN_ID/trigger"
for artifact in command.txt action-request.json effect-check.json exit-statuses.json trigger.log; do
  [[ -s "$EVIDENCE/$artifact" ]] || fail "trigger did not write $artifact"
done
jq -e 'type == "object"' "$EVIDENCE/action-request.json" >/dev/null || fail "action-request.json is not a JSON object"
jq -e 'type == "object"' "$EVIDENCE/effect-check.json" >/dev/null || fail "effect-check.json is not a JSON object"
jq -e '.replacement_pod.name != "" and .replacement_pod.uid != "" and .replacement_pod.ready == true' \
  "$EVIDENCE/effect-check.json" >/dev/null ||
  fail "effect-check.json must record the replacement pod identity, not only readiness: $(jq -c . "$EVIDENCE/effect-check.json")"
jq -e 'type == "object"' "$EVIDENCE/exit-statuses.json" >/dev/null || fail "exit-statuses.json is not a JSON object"

# The capture of the pre-injection checkpoint tree must record its own exit
# status: an empty tree on a fresh lifecycle and a failed capture both print no
# checkpoints, and the log must not conflate them.
grep -Eq 'Pre-backup checkpoint tree \(exit=0, lines=[0-9]+; empty is expected on a fresh lifecycle\):' \
  "$EVIDENCE/trigger.log" ||
  fail "trigger.log does not record the checkpoint-tree capture exit status: $(grep -n 'checkpoint tree' "$EVIDENCE/trigger.log" || printf '<no match>')"

if grep -q "$WORK/kubeconfig.conf" "$EVIDENCE"/*.json "$EVIDENCE"/command.txt "$EVIDENCE"/trigger.log; then
  fail "trigger evidence leaked the kubeconfig path"
fi

set +e
verdict_json="$(bash "$WORK/cbt-chaos/scenario-verdict.sh" \
  --scenario-dir "$SCEN_DIR" --run-id "$RUN_ID" 2>"$WORK/verdict.err")"
verdict_status=$?
set -e
[[ "$verdict_status" == "1" ]] ||
  fail "evaluator should return 1 without lifecycle evidence, got $verdict_status"
jq -e 'type == "object" and (.checks | length > 0)' <<<"$verdict_json" >/dev/null ||
  fail "evaluator did not emit the expected JSON verdict: $verdict_json"

check_status() { # <id>
  jq -r --arg id "$1" '.checks[] | select(.id == $id) | .status' <<<"$verdict_json"
}
[[ "$(check_status injection-signal)" == "PASS" ]] ||
  fail "evaluator did not recognise the trigger's injection signal evidence (got $(check_status injection-signal)); action-request.json=$(jq -c . "$EVIDENCE/action-request.json")"
[[ "$(check_status launcher-replacement)" == "PASS" ]] ||
  fail "evaluator did not recognise the trigger's launcher replacement evidence (got $(check_status launcher-replacement)); effect-check.json=$(jq -c . "$EVIDENCE/effect-check.json")"

printf 'PASS: the CBT-F-01 trigger and the deterministic evaluator agree on the injection-evidence contract.\n'

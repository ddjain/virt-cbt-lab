# Reusable CBT chaos bundle patterns (v2)

The Chaos Engineer (`cbt-chaos-trigger-preparer-v2`) prepares the bundle.
The Lead obtains approval, executes, monitors, and reports.
The independent CBT Analyst (`cbt-chaos-analyst-v2`) reviews raw evidence;
the script author's success message is not injection confirmation.
These are illustrative shapes, not executable scenario implementations.
Verify every krkn flag, enum, default, and runtime behavior against the
installed metadata before authoring; read `skill://krkn-scenario`.

## Common preparation and stage ownership

Keep the reusable pipeline in `cbt-chaos/scenarios_v2/<ID>/run.sh`.
It may include injection directly or invoke minimal scenario-local helpers
such as `inject.sh`, `condition.sh`, or `effect.sh`. Names are unrestricted;
an existing `chaos-trigger.sh` is fine, not mandatory. There is no line-count
limit or single-script requirement. Split distinct concerns only; do not
add a generic framework.

Reuse existing stage scripts/Make targets and the applicable scenario
evaluator. Read `docs/agent-workflow-audit.md` and resolve the current stage
interface when unknown. Never substitute a full lifecycle for a requested
stage, skip preflight, or use a full-interruption evaluator for unrelated
faults.

Record each stage's exact command, owner (Lead or `run.sh`), readiness
handoff, timeout, and exit handling. Only that owner starts the stage.
Before a costly pipeline, verify the real execution host/tool or image
metadata, krkn scenario/trigger support, container runtime, trigger tools
and paths, mounts, cluster context, authentication, and permissions.
Command triggers may run inside a container: host-only `oc`/`jq` and
host-only credentials do not prove they are available there.

Arm the trigger and run/UID-scoped collection before starting the stage
that can open the window; signal readiness before the stage owner proceeds.
This avoids losing short copy windows to trigger/container startup.
For stable-system faults, arm against the approved readiness condition
instead of inventing an in-flight backup dependency.

## Pattern A — native krkn event trigger

Preferred sequence:

1. Resolve approved target rules live; enforce count, scope, and exclusions.
2. Arm a native Kubernetes condition trigger if it can express the exact
   condition and resource identity; otherwise use a native command trigger.
3. Set an explicit bounded timeout and **fail on timeout**, using verified
   installed names and enum values. A default that skips injection is unsafe.
4. Capture the raw condition and exact target UID/state immediately before
   action; execute the approved krkn fault once.
5. Capture raw effect, target UID/state after action, affected identities,
   and exclusion snapshots within the approved observation bound.

Native triggers exist in supported krkn releases; inspect
`krknctl describe <scenario>` and `krknctl run <scenario> --help` on the
execution host rather than claiming they never exist or guessing flags.
An exit-0 command predicate is sufficient only when its saved raw evidence
proves the scenario's exact condition, not merely that an API call worked.
`Progressing=True` does not universally establish active data copy; a
copy-window scenario needs the required run/backup UID and exact copy
signal, scoped by time, before action.

If the native trigger cannot save or reference that condition evidence,
bind an approved minimal evidence helper to the trigger, or use Pattern B.
Do not claim event timing from an uncorrelated later snapshot.

## Pattern B — bounded condition watcher around krkn

Use when native triggers are absent or cannot express the exact condition.
Keep the same krkn fault; missing trigger support does not justify an
oc/kubectl fault action.

- One bounded watcher, armed before the relevant stage, captures the exact
  condition and target identity, then invokes krkn once.
- Record the condition-before-action and action timestamps. Revalidate
  target UID/window immediately before mutation; fail closed if it changed.
- Bound polling, action, effect checks, and process joins. A polling interval
  is not proof of readiness; an arbitrary sleep is not a condition.
- Trap only this invocation's owned background processes and approved
  scenario rollback. Never kill broad process groups or delete evidence,
  failed backups, unrelated resources, or another run's processes.

## Pattern C — oc/kubectl fault action exception

Only use this when no available krkn scenario can express the required
fault. Record the scenario metadata checked and the precise missing
capability. Use the same exact-condition, bounded-wait, identity, evidence,
effect, exclusion, rollback, and exit-status rules as Patterns A and B.
Read-only oc/kubectl queries are allowed in all patterns.

## Simple example — preserve the action and logging exit statuses

This Bash fragment runs an already-approved argv and records its output
without losing the action status to `tee`. It deliberately does not
implement a trigger or claim an effect; wrap the real scenario's approved
action with it after recording the condition and UID evidence.

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${ACTION_LOG:?set ACTION_LOG}"
: "${STATUS_LOG:?set STATUS_LOG}"
(($#)) || { printf 'expected an approved command argv\n' >&2; exit 2; }

if "$@" 2>&1 | tee "$ACTION_LOG"; then
  statuses=("${PIPESTATUS[@]}")
else
  statuses=("${PIPESTATUS[@]}")
fi
printf 'action_rc=%d tee_rc=%d\n' "${statuses[0]}" "${statuses[1]}" \
  > "$STATUS_LOG"
((statuses[1] == 0)) || exit 1
exit "${statuses[0]}"
```

Capture `PIPESTATUS` immediately in both branches: any intervening command
overwrites it. A real scenario also preserves stage/watcher/evidence-write
statuses and applies explicit exit arbitration. An interrupted backup's
expected nonzero is not automatically product FAIL; do not hide it with
`|| true` or treat bare exit 0/no exception as effect evidence.

## Approval, evidence, and feedback

Approve the entire bundle once: entrypoint, all invoked local
scripts/configs, scenario spec/Jira conditions, effective blast radius and
window, and run parameters. The Lead records the explicit approval ask and
hashes in `approval.json` and rechecks hashes/parameters immediately before
execution. The unchanged approved bundle may rerun; changed scope, inputs,
or files need fresh approval. No mid-run edits to the bundle.

Store each attempt under `cbt-chaos/scenarios_v2/<ID>/runs/<attempt-id>/`:
`run.json`, raw condition/action/effect/exclusion evidence and logs,
`injection-confirmation.json`, `analysis.json`, and `run-report.md`.
Lifecycle evidence stays in repository `runs/<lifecycle-id>/`; link to it,
do not copy or move it. Reports exist for every terminal attempt, including
INVALID and BLOCKED. Existing legacy evidence is not moved or regraded.

The Analyst independently checks raw timing, identity, effect, and blast
radius. Unproven injection is INVALID; unmet prerequisites before injection
are BLOCKED. Confirmed injection with a required product violation is FAIL,
even if the root cause is unknown; missing mandatory product evidence is
INCONCLUSIVE. PASS requires every mandatory criterion proven.

After a closed INVALID injection defect, the Lead may request ONE evidenced
repair from the Chaos Engineer, followed by fresh complete-bundle approval
and a fresh attempt, never a silent retry. Handoff includes the exact
change, cited evidence, checks actually performed, and remaining limits.
New-scope ideas become proposed/unexecuted
`scenarios_v2/<new-ID>/jira-issue.md` follow-ups linked from the report, not
immediate tests. The Lead owns `consolidated-report.md` and short
evidence-backed generic lessons in `improvement.md`; the Analyst records
deduplicated product defects in `bugs/<defect-slug>.md`.

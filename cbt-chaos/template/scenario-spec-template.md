# Scenario: <ID> — <scenario-name>

**Planning reference:** <QE matrix row/priority or source issue link, if applicable>
**Jira conditions:** `jira-issue.md`

Use heading titles when linking this spec; do not depend on section numbers.

## Title

<One line: the CBT behavior under test and why.>

## Description

<Component, correctness question, failure boundary, and required initial
state. Specify full/incremental and the lifecycle window only when relevant;
stable-system faults are supported without an in-flight backup.>

## Chaos Injection

**Target and fault:** <selection rules, resource kinds, namespace scope,
exact count/intensity/duration, target UID validation, and exclusions.
Resolve live identities inside the reusable bundle, not from a prior run.>

**Command metadata:** <execution tool/version or image identity; installed
scenario tag and relevant metadata/help evidence. Read `skill://krkn-scenario`;
inspect `krknctl list available`, `krknctl describe <scenario>`, and
`krknctl run <scenario> --help` before choosing flags and values.
Do not guess scenario tags, selectors, flags, enums, or defaults.>

**Primary:** <native krkn event-triggered fault. Prefer a native Kubernetes
condition trigger if it expresses the exact condition and identity,
otherwise a native command trigger. If native triggers are unavailable or
insufficient, wrap the same krkn action in a bounded condition watcher.>

**Exception, only if needed:** <oc/kubectl fault action; identify the
available krkn scenarios checked and the precise fault capability missing.
Missing native trigger support alone does not justify this exception.
Read-only oc/kubectl queries are permitted in every trigger pattern.>

**Reusable command:** <exact `run.sh` invocation and required input names.
Use guarded inputs and live resolution, explicit kubeconfig/context and
namespace selection, and no unresolved values at execution time. Keep
secrets and environment-specific private values out of committed docs.>

## Injection Timing

**Deterministic condition:** <exact observable resource condition/event/log
signal, resource/run UID, required state, and valid window. For active-copy
faults, specify the exact copy evidence: `Progressing=True` alone is not
universally sufficient. For stable-system faults, specify readiness.>

**Arming and handoff:** <who arms the trigger and scoped raw collection,
how readiness is signalled before the operation can open the window, and
which stage owner may then proceed. Do not lose short windows to trigger
startup; do not use arbitrary sleep as synchronization.>

**Trigger implementation:** <installed native condition/command trigger
metadata or justified bounded wrapper. Native triggers exist in supported
krkn releases; verify this installation rather than assuming flags exist
or do not exist. Verify tools/paths/authentication in the trigger's actual
execution environment, including inside a container when applicable.>

**Bounds:** <condition, action, effect, stage, and join deadlines; observation
window. Configure native trigger timeout to fail explicitly using the
installed names/values: a default that skips the fault is unsafe.>

**Condition-before-action evidence:** <raw signal and timestamp saved before
mutation; exact target name/UID/state immediately before action, UID/window
revalidation, and exact action argv/start/end/exit status.>

## Effect and Blast-Radius Evidence

**Machine effect check:** <scenario-specific fail-closed query and expected
transition; raw output, UTC timestamps, target UID/state after action, and
replacement UID when relevant. Exit 0, no exception, or an "injected" line
does not prove the fault took effect.>

**Blast-radius proof:** <before/after affected-identity inventory, exact
count/scope/duration, excluded-object snapshots and checks, and artifact
paths. Selector intent alone does not prove actual blast radius.>

**Evidence scope:** <backup/VM/pod UIDs, lifecycle and attempt IDs, start/end
times, and source/container for logs. Avoid unscoped historical matches.>

## Expected Behavior / Pass-Fail Criteria

Define every mandatory requirement before approval; record exact evidence
and applicable evaluator/check commands rather than relying on narrative.

| Requirement | Expected product behavior | Evidence / check | Mandatory? |
|---|---|---|---|
| <criterion ID> | <checkable behavior and bound> | <raw path/query/evaluator> | <yes/no> |

**Verification:** <applicable metadata, checkpoint/tracker, physical image,
CBT state, restore, and data-integrity checks. A CR's requested/reported type
alone does not establish physical full/incremental behavior. A single
`Done=True` read or Warning event alone is insufficient. Reuse the applicable
scenario evaluator; a default full-interruption evaluator is not valid for
arbitrary scenarios. Deterministic UNKNOWN/failure must not become a
narrative PASS.>

**Terminal verdicts:**

- **BLOCKED:** prerequisites prevent injection.
- **INVALID:** injection condition/target/window/effect/blast radius is
  wrong or unproven.
- **FAIL:** confirmed valid injection and an observed mandatory product
  violation, even when root cause remains unknown.
- **INCONCLUSIVE:** confirmed valid injection but mandatory product
  evidence is missing, without an already-proven required violation.
- **PASS:** valid injection and every mandatory requirement proven.

An expected interrupted-backup nonzero is not automatically product FAIL.
Preserve stage and action exit statuses and grade the specified behavior.

**Post-chaos same-VM backup verification, when applicable:**

- <Declare whether required, and why. After the affected VM is Ready with
  CBT Enabled, request a uniquely named full backup/destination if no valid
  full checkpoint exists; otherwise use the required new incremental
  request based on the last known-good checkpoint.>
- Preserve failed backup objects/PVCs and destinations; never reuse their
  names to retry. Verify type, terminal reason, checkpoint/tracker
  advancement, CBT state, and the required physical/restore/data evidence.
- If the workflow cannot safely request the same-VM backup without reusing
  failed resources, mark that check BLOCKED and record the missing approved
  recovery path. A fresh-VM lifecycle does not replace a required same-VM
  check. Map unmet mandatory evidence to the terminal rules above.

## Execution and Approval

The Lead owns approval, execution, monitoring, and reports. The Chaos
Engineer (`cbt-chaos-trigger-preparer-v2`) prepares/revises the bundle only;
the independent CBT Analyst (`cbt-chaos-analyst-v2`) reviews raw evidence,
criteria, bounded investigation, defects, and proposed follow-ups.

**Preflight before costly pipeline:** <execution host/tool or image metadata,
scenario/trigger support, runtime tools and mounts, cluster context,
authentication and permissions, and read-only condition/effect access in
the actual trigger environment. Fail closed on missing prerequisites;
never commit credentials, private hostnames/paths, or environment values.>

| Stage / purpose | Exact existing command | Owner: Lead or run.sh | Readiness handoff | Deadline / exit handling |
|---|---|---|---|---|
| <stage> | <stage script/Make target> | <one owner> | <signal/evidence> | <bound/status capture> |

**Process and rollback ownership:** <owned background PIDs and bounded
joins; traps limited to those processes and approved scenario rollback.
Never delete evidence or unrelated resources. Capture every relevant
status; if using `tee`, save `PIPESTATUS` immediately before any other
command. Never suppress an unexpected failure or claim exit 0 as proof.>

**Approval bundle:** <entrypoint plus every invoked local script/config,
this spec and Jira conditions, effective blast radius/window, and approved
run parameters. The Lead records explicit ask/approval and hashes in
`approval.json` and verifies hashes/parameters immediately before execution.
Unchanged approval permits reruns; changes require fresh approval. Never
edit the approved bundle mid-run.>

## Reproducibility and Outputs

Canonical generated outputs live with the scenario:

```text
cbt-chaos/scenarios_v2/<ID>/
  scenario-spec.md
  jira-issue.md
  run.sh
  inject.sh                    # optional; helper names are unrestricted
  approval.json
  runs/<attempt-id>/
    run.json
    injection-confirmation.json
    analysis.json
    run-report.md
    <raw evidence and logs>
  consolidated-report.md
  bugs/<defect-slug>.md
```

`run.sh` is the reusable pipeline entrypoint; injection may be inline or in
minimal scenario-local helpers. An existing `chaos-trigger.sh` is fine,
not required. There is no line-count cap. Reuse existing workflow scripts;
do not create a new generic framework. Reference lifecycle evidence at
repository `runs/<lifecycle-id>/` rather than copying it. Do not move or
regrade archived/legacy evidence.

## Handoff and Follow-up

<Engineer handoff: bundle paths/command, stage ownership/readiness,
metadata, bounds, rollback, raw effect/exclusion checks, checks actually
performed, and known limits. Analyst feedback cites raw evidence and
separates confirmed product violations from injection defects.>

The Lead closes and reports every terminal attempt, including
INVALID/BLOCKED, before any optional retry. After an INVALID injection
defect, permit at most ONE evidenced repair by the Engineer, fresh
complete-bundle approval, and a fresh attempt; never a silent retry.

Deduplicate confirmed product defects across runs in
`bugs/<defect-slug>.md`. New-scope follow-ups are proposed/unexecuted
`cbt-chaos/scenarios_v2/<new-ID>/jira-issue.md`, linked from the report;
do not immediately test them. The Lead alone maintains `improvement.md`
with 1–3 lines per deduplicated evidence-backed generic lesson.

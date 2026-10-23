# CBT-EXP-08V1 — consolidated chaos report

The Lead updates this scenario-root report after every terminal attempt,
including INVALID and BLOCKED, before an optional repaired retry. Historical
archived evidence is linked as recorded, never moved or retroactively regraded.

## Scope

[scenario-spec.md](scenario-spec.md) (EXP-8: tracker deletion mid-copy —
second entry path to the no-deadline wedge; v2 re-host of CBT-EXP-08) and the
validation contract [jira-issue.md](jira-issue.md). Approved scope: one fresh
run-owned VM via `make vm-setup`/`make vm-backup`, one UID-preconditioned
mid-copy deletion of the run's own `VirtualMachineBackupTracker` through an
owned loopback `oc proxy` (fault action isolated in `inject.sh`), 900 s
terminal-or-stuck observation with per-sample resourceVersion and a
both-replica three-pin controller log window, and a bounded recovery leg
(wedged-CR delete ≤300 s never forced; tracker re-apply only if absent;
fresh-named forceFullBackup + operand checks; no restore leg by spec). The
v1 scenario's five closed attempts (2 BLOCKED, 1 INVALID, 2 FAIL, including
two graded reproductions of the same wedge) remain in
[../CBT-EXP-08/consolidated-report.md](../CBT-EXP-08/consolidated-report.md)
and are not regraded or imported here.

## All terminal attempts

| Attempt ID | Date (UTC) | Lifecycle evidence | Verdict | Per-run report | Bundle / approval reference | Previous / repaired attempt | Summary |
|---|---|---|---|---|---|---|---|
| 22-10-2026-22-02-00-vm-20261022220159-swift-wolf-e7a4-tracker-delete-iteration-1 | 2026-10-22/23 | `runs/20261022220159-swift-wolf-e7a4/` | **FAIL** | [run-report](runs/22-10-2026-22-02-00-vm-20261022220159-swift-wolf-e7a4-tracker-delete-iteration-1/run-report.md) · [test-run-result](runs/22-10-2026-22-02-00-vm-20261022220159-swift-wolf-e7a4-tracker-delete-iteration-1/test-run-result.md) · [test-run-report](runs/22-10-2026-22-02-00-vm-20261022220159-swift-wolf-e7a4-tracker-delete-iteration-1/test-run-report.md) | request `cbt-exp08v1-bundle-20261022T221000Z`, fingerprint `0211e89d…`, approved 2026-10-23T00:24:00Z; 23-file manifest, 23/23 pre-execute hash match | none — first attempt of the v2 scenario | **Wedge reproduced from the API-side entry path (third independently graded reproduction of the defect, first under the v2 bundle).** Valid injection (compound active-copy condition 00:56:50Z, same-instant revalidation, UID-preconditioned DELETE 200 at 00:57:06Z, GET 404, DELETED watch event). Backup silently non-terminal for the full 900 s bound (60/60 samples, rv frozen 38417908, finalizer retained; QEMU job ended 00:57:55Z with no completion write). Product never recreated the tracker. Wedged CR's own deletion deadlocked 300 s until the harness re-applied the tracker; then Done=True "backup was deleted during initialization" and gone in the first post-tracker sample. Recovery forceFullBackup verified 11/11; blast radius clean; VMI never Paused. Independent grading owner: `analysis.json` in the run root. |

Per-run reports live at `runs/<attempt-id>/run-report.md` within this scenario.
Include every terminal attempt, not only successful or valid injections; retain
the original INVALID attempt when a repaired attempt is added.

## Counts

- Total terminal attempts: 1
- PASS: 0
- Product FAIL: 1
- INVALID injection: 0
- BLOCKED prerequisites: 0
- INCONCLUSIVE product evidence: 0

The five verdict counts sum to the total. INVALID, BLOCKED and INCONCLUSIVE
are not product failures and must not be folded into a product failure rate.
An expected interrupted-backup exit is not itself a product FAIL.

## Confirmed product defects and recurrence

| Deduplicated defect | Bug draft | Supporting attempts / evidence | Observed impact | Root cause status |
|---|---|---|---|---|
| Mid-copy tracker deletion wedges the in-flight backup (silent no-terminal wedge, finalizer retained, destination attached ~20 m) and deadlocks the backup CR's own deletion until the tracker is recreated; tracker never recreated by the product | [../CBT-EXP-08/bugs/mid-copy-tracker-deletion-wedges-backup-and-cr-deletion.md](../CBT-EXP-08/bugs/mid-copy-tracker-deletion-wedges-backup-and-cr-deletion.md) (one bug per distinct defect; third-reproduction section appended with this run's evidence) | this attempt (graded FAIL) + CBT-EXP-08 iterations 4–5 (graded FAIL, same build, distinct resources) + archived 2026-10-14 predecessor lead | loss of backup coverage for the VM; operator must know the repair order (recreate tracker first, then the wedged CR clears) | not determined; recurrence of symptoms established across three graded reproductions, not demonstrated causality |

The independent Analyst maintains one `bugs/<defect-slug>.md` per confirmed
observed product defect across attempts. Unknown causes are allowed; unknown
product outcomes, injection defects and harness issues do not create bugs.

## Injection, harness and evidence limitations

- None for this attempt: the freshly re-derived v2 bundle (separate
  fault-action file `inject.sh`, shared `cbt-chaos/scenario-runtime.sh`)
  executed its first live attempt without a harness defect; every bound and
  fail-closed gate behaved as rehearsed (56/0 offline harness, 21/0 mocked
  inject, 171 jq compiles, live non-mutating mechanism probe).
- Evidence limits (grading owner): the pre-delete wedge is *silent* — the
  `end`-pinned controller window holds 0 run-scoped lines (live re-verified
  read-only at 2026-10-23T02:06:44Z); per the pre-registered contract the
  "requeue/404 lines" signature is a hypothesis, not required evidence, and
  the FAIL rests on the sample/finalizer/frozen-resourceVersion evidence and
  the abort-path deadlock. Host/storage release: API-level CLEAR (no
  VolumeAttachment on either PV, hotplug empty, live check 01:52:29Z); host
  layer UNKNOWN by design. Restore correctness not exercised
  (NOT_INCLUDED_BY_SPEC). Lifecycle `summary.json` verdict INCOMPLETE is the
  lifecycle harness's incremental-pass accounting (no incremental passes by
  design), not a product observation.

No INVALID repair relation: this request had a single valid attempt.

## Proposed scenarios — not executed or approved

None. No `proposed_scenarios` were created by this scenario's Lead, grading
owner or specialists (`run.json.proposed_scenarios=[]`; the grading owner
deduplicated the observed defect into the existing bug instead).

## Coverage, recovery and report notes

- Scenario outcome: **FAIL** — the wedge is reachable from the API-side
  operator action (tracker deletion mid-copy) on the current build, now with
  three independently graded reproductions on distinct run-scoped resources
  (two under the v1 bundle, one under this v2 bundle). The resilient
  alternative was not observed.
- Recovery knowledge re-validated: deleting the wedged CR alone does not
  clear it while the tracker is absent; re-applying the tracker unblocks the
  abort, after which a fresh full backup completes and verifies.
- Retained run-owned objects (no-cleanup design): the run VM/root DV/SSH
  service, destination PVC (evidence), recovery PVC + recovery backup CR and
  the re-applied tracker (advanced to the recovery checkpoint); the wedged
  CR and original tracker are gone (released via the recovery leg).
- Generic evidence-backed lessons are deduplicated by the Lead in its skill's
  `improvement.md`, not here.

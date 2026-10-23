# FAIL — CBT-EXP-08V1 — attempt 22-10-2026-22-02-00-vm-20261022220159-swift-wolf-e7a4-tracker-delete-iteration-1 — 2026-10-22/23 (UTC)

The Lead writes this report for every terminal attempt, including INVALID and
BLOCKED, before any repaired retry. Stored at
`runs/22-10-2026-22-02-00-vm-20261022220159-swift-wolf-e7a4-tracker-delete-iteration-1/run-report.md`
inside the scenario directory. Observed facts only, from the raw evidence.

## Attempt and approval

| Field | Value |
|---|---|
| Scenario / specification / Jira conditions | [scenario-spec.md](../../scenario-spec.md) (EXP-8: tracker deletion mid-copy — second entry path to the no-deadline wedge; v2 re-host) · [jira-issue.md](../../jira-issue.md) (validation contract, §5 pre-registered classification) |
| Attempt / lifecycle IDs | `22-10-2026-22-02-00-vm-20261022220159-swift-wolf-e7a4-tracker-delete-iteration-1` / `20261022220159-swift-wolf-e7a4` (lifecycle evidence: `runs/20261022220159-swift-wolf-e7a4/`) |
| Previous / repaired attempt relation | none — first attempt of the v2 scenario, iteration 1 |
| Scenario iteration / note | 1 / `tracker-delete` |
| Namespace / VM / VM UID | `vm-cbt-demo` / `vm-20261022220159-swift-wolf-e7a4` / `89f57256-287a-4fe1-8d0e-80147d846304` |
| Target kind / name / UID before and after | `VirtualMachineBackupTracker` `vm-tracker-20261022220159-swift-wolf-e7a4`; before `61da2429-d4b3-45fe-b6d6-e15998124e61` (deleted 00:57:06Z, GET 404 verified); after: absent for the whole observation window; re-applied by the recovery leg as `92756b7c-ecbd-4426-901a-fb7e057e720c` at 01:17:16Z |
| Approved entrypoint and effective parameters | `env CHAOS_RUN_ID=… LIFECYCLE_ID=… bash cbt-chaos/scenarios_v2/CBT-EXP-08V1/run.sh --execute` on cloud05 (`/root/virt-cbt-lab`); parameters verbatim in `preflight/approval-candidate.json` and `approval.json` (rhel9 / large-odf / 1000 baseline files 15–20 MiB / ns vm-cbt-demo / dwell 15 s / stuck 900 s / recovery r001 forceFullBackup) |
| Complete bundle hash / approval reference | 23-file SHA-256 manifest in `approval.json`; approval request `cbt-exp08v1-bundle-20261022T221000Z`, bundle fingerprint `0211e89d9cd0e7dcec5d1647a32f4c0f3304e6d09917d2b8812bddaffd1b14c7`; approved 2026-10-23T00:24:00Z via Main structured ask ("Approve bundle") |
| Immediate pre-execution hash verification | all 23 manifest files re-hashed live on cloud05 immediately before execution, 23/23 match (`ALL-23-HASHES-MATCH-NOW`, 2026-10-23T00:26Z vicinity); recorded in run.json `approval` snapshot |
| Phase / verdict / start and close UTC | started 2026-10-22T22:02Z (run root armed); execute 00:27Z–01:18:34Z (rc 0); closed FAIL 2026-10-23T02:5xZ |

`run.json` is the canonical attempt state. `analysis.json` records the
independent Analyst's (grading owner `GraderEXP08V1i1`) assessment.

## Injection proof and independent validity

- **Condition before action (UTC):** active-copy compound condition at
  2026-10-23T00:56:50Z — backup `Progressing=True`, `Done≠True`, run-scoped
  labels/source/pvc, launcher `Backup started` line at 00:56:48.683Z for
  `vm-backup-20261022220159-swift-wolf-e7a4`, live QMP backup job
  `offset=2828009472 < len=83869302784` (running, not paused), VMI `Running`
  on uid `950d3488-70cd-402b-a902-61d38059a9b4`, tracker present with exact
  uid `61da2429…`, `spec.source.name` = the run VM, checkpoint unset
  (`condition.json`, raw `execution/polls/10`).
- **Action:** after the 15 s dwell, same-instant revalidation at 00:57:05Z
  (backup same uid, not Done, not deleting, run-scoped; tracker same uid,
  checkpoint unset, not deleting), then `inject.sh` issued exactly one
  UID-preconditioned `DELETE` (`DeleteOptions.preconditions.uid=61da2429…`,
  `gracePeriodSeconds=0`) through the owned loopback `oc proxy` at
  00:57:06Z → HTTP 200, transport rc 0 (`inject-result.txt`,
  `execution/inject/`). Fail-closed postcondition: first GET → 404 at
  00:57:06Z (`execution/tracker-get-codes.log`); `DELETED` watch event for
  the exact target uid (`execution/watch-tracker.jsonl`).
- **Effect and exclusions:** backup never terminal in the 900 s bound (see
  criteria table); blast radius clean — before/after name→UID maps identical
  for vmbackup(7)/vmbackuptracker(3)/vm(3)/vmi(3)/pvc(15) with this
  attempt's own names excluded; control VM `vm-cbt-demo` unchanged
  (`execution/blast-radius.json`).
- **Independent validity:** the grading owner re-verified injection from the
  raw streams (not the machine summary): `injection.valid=true`, target,
  window, effect and exclusions all PASS (`analysis.json` `.injection`).

## Deterministic outcomes and criterion coverage

| Mandatory criterion | Expected behavior | Observed result | Evidence path + field / UTC / UID | Coverage or unknown reason |
|---|---|---|---|---|
| Injection validity (spec §5) | mid-copy window proven; UID-preconditioned delete accepted; GET 404 | **pass** | `condition.json` (00:56:50Z); `execution/inject/` DELETE 200 at 00:57:06Z for uid 61da2429…; first GET 404; watch DELETED event | fully covered from raw streams |
| Backup outcome (spec §5) | terminal (Done=True non-failure, or explicit bounded failure) inside 900 s | **fail — STUCK** | `backup-samples.json`: 60/60 samples over 896 s `Done=False` "Backup is in progress", rv frozen 38417908, finalizer `backup.kubevirt.io/vmbackup-protection` retained; QEMU job ended 00:57:55Z with no completion write; Done=True only at 01:17:17Z after operator intervention ("Backup has failed: backup was deleted during initialization") | fully covered; per-sample resourceVersion surfaced |
| Mechanism evidence (Jira row: window covers delete instant) | both-replica controller window covering the delete instant | **pass** (window recorded) | `controller-window.log/.json`: three pinned pulls (end/wedged/recovery-done), 6 raw files, both replicas, pull rc 0 | window covered; the pre-delete window is affirmatively silent (0 run-scoped lines, live re-verified by the grader at 02:06:44Z) — per the pre-registered contract the "requeue/404 lines" signature is a hypothesis, not required evidence; the wedge is proven silent by the frozen rv |
| Guest effect | VMI never `Paused`; destination attachment recorded | **pass** | `vmi-after-fault.yaml`, `execution/guest-*`, watch streams: zero Paused conditions; hotplug `hp-volume-vbn4p` MountedToPod 00:56:48Z→01:17:17Z (~20 m 29 s) | fully covered |
| Wedged-CR deletion outcome | bounded, never forced; release classified | **fail (product)** | `wedged-deletion.json`: UID-guarded DELETE 01:12:16Z → 200, stuck full 300 s bound (145 samples, rv frozen 38435280, deletionTimestamp+finalizer retained, Progressing reason "BackupTracker … does not exist"); released only after tracker re-apply | fully covered; recorded, never auto-repaired |
| Tracker post-state | recreated silently / absent / chain intact | **pass (classified: absent)** | `tracker-samples.json`: 60/60 absent over 896 s; product never recreated; only new tracker is the bundle's re-apply (uid 92756b7c…, `tracker-recreation.json`) | fully covered |
| Recovery (spec §5) | fresh backup Done=True/type=Full/reason+checkpoint, PVC Bound, tracker advanced | **pass** | `recovery-backup.yaml`, `recovery-operand-checks.json` (11/11): Done=True "Successfully completed VirtualMachineBackup", type Full, checkpoint `…r001-2026-10-23_01-17-19`, new PVC Bound, tracker advanced; lifecycle `runs/20261022220159-swift-wolf-e7a4/run.json` `.recovery.attempts[r001]` status `backup_verified` | fully covered |
| Blast radius / exclusions | every other object unchanged | **pass** | `execution/blast-radius.json`: others_unchanged=true across 5 kinds; control VM unchanged | fully covered |

**Stage exit statuses:** entrypoint rc 0 (injection_proven=true,
recovery_leg_terminal=true, status=backup_verified — orchestration facts,
not a product verdict); `make run-summary` rc 0 (lifecycle verdict INCOMPLETE
is the lifecycle harness's own incremental-pass accounting, expected here:
this scenario never runs incremental passes). Deterministic evaluator
`cbt-chaos/scenario-verdict.sh`: not applicable (no clause set maps to a
mid-copy tracker deletion; `run.sh --plan` records
`evaluator.status=NOT_APPLICABLE`; the independent Analyst graded the named
criteria instead).

**Recovery layers (terminal residual audit, grading owner):**
- API/control-plane — CLEAR-with-evidence: wedged CR and original tracker
  gone (released via the recovery leg); destination PVC
  `ce2e9efe-0e69-4a24-81b5-102e9d7f7cd4` / recovery PVC / recovery backup CR
  / tracker retained **by design** (`preserve_failed_resources=true`).
- Attachment layer — CLEAR at API level: live read-only check 01:52:29Z, no
  VolumeAttachment on either PV, utilityVolumes/hotplug empty, no hp-volume
  pod.
- Guest layer — CLEAR: VMI Running, never Paused, AgentConnected.
- Host/storage layer — **UNKNOWN by design** (no host-level probe authorized
  in this bundle's read scope; `execution/storage-identity.json` `.host_layer`
  records status UNKNOWN + reason).
- Cleanup warnings (HotplugFailed/lstat) — investigated by the grading owner:
  paired with successful unmounts, match the documented CBT-F-04 family, not
  wedge-attributable.

## Verdict and limits

**FAIL** (pre-registered spec §5: "FAIL: wedge from the API-side path").
Decisive requirements: valid injection (independent grading owner confirmed
from raw streams) + the backup never reached a terminal state inside the
approved 900 s observation bound (silent wedge: frozen resourceVersion, zero
run-scoped controller lines pre-delete) + the wedged CR's own deletion
deadlocked until the tracker was re-applied + the product never recreated the
tracker. Root cause remains not determined; per policy an unknown root cause
does not erase the observed defect.

Limits: 900 s (and every bound) is an approved test window, not a product
SLA. This is one execution; recurrence is established against the two prior
v1-scenario reproductions on the same build (symptom recurrence, not
demonstrated causality). Host-layer release is UNKNOWN by design. Restore
correctness was NOT exercised (not included by spec; the recovery criterion
is a fresh verified full backup).

## Scoped investigation and recovery

- Investigation bounded to this run's objects/UIDs and time ranges; decisive
  controller lines (`backup.go:1088` tracker-404 family) all post-date the
  wedged-CR delete (wedged phase: 2 tracker-absent + 2 "backup is deleting"
  lines; recovery phase: 2 + 6), consistent with the silent pre-delete wedge.
- Recovery actions (all by the entrypoint, all bounded): UID-guarded unforced
  DELETE of the wedged CR at 01:12:16Z (stuck 300 s bound, never forced, no
  finalizer edits); tracker manifest re-apply at 01:17:16Z (only because
  absent); wedged CR gone in the first post-tracker sample; terminal write
  Done=True "Backup has failed: backup was deleted during initialization"
  01:17:17Z; fresh `vm-recovery-pvc-…-r001` + `vm-recovery-full-…-r001`
  (forceFullBackup) verified 11/11 operand checks; tracker advanced to
  `…r001-2026-10-23_01-17-19`.
- Retained resources (no-cleanup design): the run VM + root DV + SSH service,
  destination PVC (evidence), recovery PVC + recovery backup CR, re-applied
  tracker. The wedged backup CR and the original tracker are gone (released
  via the recovery leg).

## Report notes, bugs and proposed follow-ups

- Harness notes: none adverse. The re-derived v2 bundle (separate
  `inject.sh` fault-action file, shared `cbt-chaos/scenario-runtime.sh`)
  completed its first live execution without a harness defect; all bounds and
  fail-closed gates behaved as rehearsed.
- Deduplicated bug (updated with this run as a third independently graded
  reproduction on the same build, distinct resources):
  [../../CBT-EXP-08/bugs/mid-copy-tracker-deletion-wedges-backup-and-cr-deletion.md](../../CBT-EXP-08/bugs/mid-copy-tracker-deletion-wedges-backup-and-cr-deletion.md)
  — the defect sits in the v1 scenario's bug file per the one-bug-per-defect
  rule; this attempt's evidence is appended there, not duplicated.
- Proposed follow-up scenarios: **none** — `proposed_scenarios=[]`; the
  grading owner found no new weakness outside the documented family.

## Evidence inventory

All relative to this run root
(`cbt-chaos/scenarios_v2/CBT-EXP-08V1/runs/22-10-2026-22-02-00-vm-20261022220159-swift-wolf-e7a4-tracker-delete-iteration-1/`):
`run.json` (canonical state, approval snapshot), `analysis.json` (grading
owner), `injection-confirmation.json` (machine observations, verdict null by
design), `condition.json`, `inject-result.txt`/`.json`,
`backup-pre-delete.yaml`, `tracker-pre-delete.yaml`, `backup-samples.json`,
`tracker-samples.json`, `tracker-deletion.json`, `backup-final.yaml`,
`tracker-final.yaml`, `controller-window.log`/`.json`,
`vmi-after-fault.yaml`, `wedged-deletion.json`, `tracker-recreation.json`,
`recovery-backup.yaml`, `recovery-operand-checks.json`, `trigger.log`,
`preflight/` (approval candidate + read-only environment evidence),
`execution/` (raw polls, watches, inject request/response, wedged samples,
controller-raw per-replica logs, blast-radius, storage-identity,
recovery operands). Lifecycle evidence in place at
`runs/20261022220159-swift-wolf-e7a4/` (run.json, report.json, summary.json).
Availability limits: host-layer release UNKNOWN (no authorized probe);
nothing else missing.

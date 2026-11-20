# Scenario: CBT-S-00 — Scale suite contract and no-chaos baseline (control)

**Status:** PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW (spec-first; nothing in this suite has been run)
**Planning reference:** scale-resilience campaign (design draft v0.1, decisions from rounds 1–3). Jira key: none yet; `jira-issue.md` is not drafted until an epic exists, and this spec is canonical until then.
**Suite members:** CBT-S-01 controller leader, CBT-S-02 virt-handler, CBT-S-03 OSD, CBT-S-04 storage-path network, CBT-S-05 node pressure. Every member inherits this document; a member only states what differs.

Use heading titles when linking this spec; do not depend on section numbers.

## Title

Define the fleet-scale backup workload, the shared trigger/evidence/grading contract, and the no-chaos baseline that every chaos leg is measured against.

## Description

**Question under test (suite level):** when one fault lands while many full or incremental backups are in flight on the persistent fleet, does CBT backup remain resilient: all backups terminal, no false success, tracker integrity, recovery by one retry, no cross-VM collateral, control plane back to steady state.

**Workload (fixed for the suite):** fleet mode, one group per run, `rhel9-light` + Windows in one wave, light incremental profile, backups on replica-1 `cbt-scale-pool` (test data only), ROOT disks on durable ODF. Phases: A baseline guest workload (SSH waves), B all full backups at once, C incremental guest workload, D all incremental backups at once. One injection per run, in phase B or phase D only.

| Stage | Group size | Purpose |
|---|---|---|
| Pilot | 10 VMs: 5 `rhel9-light` + 5 Windows | validate trigger, timing, evidence capture |
| Target | 100 VMs: 50 + 50 | the resilience result |

**Prerequisites (preflight, fail closed):** `rhel9-light` DataSource present; backup StorageClass `cbt-scale-pool` present; fleet registry matches live VMs for the selected range; no unrelated vmbackups in `vm-cbt-demo` (abort if any exist that are not about to be reset); no other mutating driver running (rule: one driver at a time); ceph health no worse than the recorded pre-window baseline.

**Group identity:** run with an explicit `--offset` per OS so the VM set, and therefore the node set, is known before the run. The group id is auto-generated at `fleet-e2e.sh run` start and read back from the wrapper log.

## Chaos Injection

**Target and fault:** none for CBT-S-00. This is the control run; it also fixes the numbers the chaos legs use.

**Command metadata:** workload commands only (no krknctl). For chaos members the metadata, versions and `--dry-run` evidence are recorded in each member spec. Installed at survey time: `krknctl v0.14.2-beta`; `krknctl run --dry-run` validates schema/required fields/values locally with no cluster access and is part of every member's preflight.

**Primary:** n/a.

**Reusable command:** pilot, then target (the Lead pre-creates the attempt directory; kubeconfig is passed explicitly):

```sh
KUBECONFIG=<approved-kubeconfig> cbt-scale/fleet-e2e.sh run \
  --os rhel9-light --count <N_RHL> --offset <OFF_RHL> \
  --windows-count <N_WIN> --wave 25
KUBECONFIG=<approved-kubeconfig> cbt-scale/fleet-verify.sh <group-id> <start-UTC> <end-UTC>
```

Pilot `N_RHL=5 N_WIN=5`; target `N_RHL=50 N_WIN=50`. Windows shares the group through `--windows-count`; its driver log reports `pass=0` as a known artifact, so Windows is judged from cluster state only. The wrapper `.summary` is NOT a verdict source until the validator bug is fixed (it looks up incrementals as `...-p01`, real names end `...-p01-<timestamp>`); `fleet-verify.sh` and the grader below are.

## Injection Timing

**Deterministic condition (baseline):** none. Instead the baseline records the timeline that chaos legs trigger on:

- timestamp when all N full vmbackups exist; when ≥50% are copying; when ≥80% are Done; when all are Done (phase B), and the same four for phase D;
- per VM: vmbackup `creationTimestamp`, launcher `Backup started` log line time, Done transition time, tracker checkpoint time.

**Arming and handoff:** read-only watcher (per `scripts/backup-state-watch.sh` conventions: no checkout lock, safe beside any stage) armed before `fleet-e2e.sh run` and bound to the attempt directory.

**Bounds:** phase B and D walls are recorded, not asserted. Known reference points from earlier runs: 50 VMs ≈ 191–220 s full / 39–40 s incremental; 100 ≈ 321 s / 110 s (stock rhel9); a 10-VM `rhel9-light` group once showed 63 s full / 363 s incremental, which this baseline must explain. Run wall budget 45 min.

**Condition-before-action evidence:** n/a.

## Effect and Blast-Radius Evidence

**Machine effect check:** n/a (no fault). The baseline must prove the *absence* of faults: no pod restarts in `openshift-cnv`/`openshift-storage` in the window, no new ceph health checks beyond baseline, no `Backup has failed` reason.

**Blast-radius proof:** n/a.

**Evidence scope:** group id, vmbackup/tracker/PVC UIDs for the group, UTC start/end from the wrapper log (`RUN: driving group` → `DONE group=`).

## Expected Behavior / Pass-Fail Criteria

### Shared grading contract (used by every member)

Per-VM classification, computed from live cluster state, never from exit codes or driver tallies:

| Class | Definition |
|---|---|
| `PASS` | full and incremental Done=True with reason `Successfully completed VirtualMachineBackup`; tracker `latestCheckpoint` equals the incremental's checkpoint; physical evidence consistent (below) |
| `FAILED-CLEAN` | Done=True with reason starting `Backup has failed`; tracker `latestCheckpoint` unchanged from before that backup; destination objects preserved |
| `FALSE-SUCCESS` | Done=True success reason but any of: tracker checkpoint not the backup's, missing `status.checkpointName`, wrong `status.type`, destination holds no/too little data |
| `TRACKER-DRIFT` | tracker advanced past a failed backup, or advanced more than once for one backup |
| `WEDGED` | not Done at the terminal deadline, or deletion stuck on finalizers |
| `MISSING` | expected vmbackup object absent |

Requirement set (member specs add bars, they do not remove rows):

| Requirement | Expected behavior | Evidence / check | Mandatory? |
|---|---|---|---|
| R1 terminal | every backup `PASS` or `FAILED-CLEAN` by the 30-min terminal deadline; zero `WEDGED`/`MISSING` | grader output `grade.tsv` | yes |
| R2 no false success | zero `FALSE-SUCCESS` | grader + physical check | yes |
| R3 tracker integrity | zero `TRACKER-DRIFT`; checkpoint chain monotonic per VM | tracker snapshots before action, after full, after incremental | yes |
| R4 recovery | all `FAILED-CLEAN` VMs reach `PASS` on one `fleet-e2e.sh run --retry <group> --only-failed` | retry group grade | yes (when any failure) |
| R5 isolation | VMs outside the declared blast radius have the same class distribution as the baseline (no new failures attributable to the fault) | per-VM class vs blast-radius inventory | yes |
| R6 control plane | no restart loop; no SyncVMI storm beyond a declared bound; controller Lease stable; CNV restarts delta equals only the intended kills | `prom-sweep.sh` over the window + pod restart inventory | yes |
| R7 injection validity | fault fired once, in the declared phase, at the declared condition, on the declared targets, with proven effect | member's evidence set; Analyst-graded | yes (INVALID otherwise) |

**Physical-data check (R2):** (a) full coverage, if the access path is verified in preflight: per-destination RBD allocated bytes (same access path `cbt-scale/scale-pool-gc.sh` already uses) compared with thresholds fixed by this baseline (expected ≈10 GiB per `rhel9-light` full; Windows threshold measured here; incrementals ≈45 MiB/VM for the light profile); (b) deep sample: `qemu-img info` on the preserved artifact for a stratified sample of 10 VMs (all in-radius VMs up to 10, topped up from out-of-radius). If (a) is unavailable the verdict for R2 is INCONCLUSIVE, never PASS.

**Verification:** `fleet-verify.sh <group-id> <start> <end>` for object-level + Prometheus; the new grader (below) for classes R1–R5. Layer 1 and Layer 2 must agree; a Prometheus spike with all backups passing is reported as a finding.

**Required new component — `cbt-scale/chaos-grade.sh <group-id>` (contract only, not yet authored):**
- input: group id, optional blast-radius inventory file; read-only against the cluster;
- output: `grade.tsv` (per-VM class + the evidence fields above), `grade.summary` (counts per class), exit 0 only when R1–R3 are satisfied;
- must be correct for names with timestamp suffix (the validator bug above);
- when authored it needs an offline test under `tests/` wired into `make test`, a row in `docs/agent-workflow-audit.md`, and a skill reference, per repository convention.

**Baseline pass criteria (CBT-S-00 itself):**

| Requirement | Expected | Mandatory? |
|---|---|---|
| B1 | 100% `PASS` at pilot and at target size | yes |
| B2 | phase B/D timeline captured for all VMs (4 timestamps each) | yes |
| B3 | the `rhel9-light` 363 s incremental anomaly is either reproduced and explained, or shown not to recur | yes (blocks fixing chaos fire windows) |
| B4 | trigger conditions of the member specs evaluated against baseline objects: positive case rc=0 at the intended moment, negative cases rc≠0 (`bash -c`, replaying saved vmbackup JSON) | yes |
| B5 | Windows full-backup wall, bytes per VM, and total pool growth recorded (capacity risk for 50 Windows × ~60–70 GiB) | yes |

**Terminal verdicts:**

- **BLOCKED:** prerequisites prevent the run.
- **INVALID:** run harness defect (e.g. wrong group, wrong VM range, watcher not armed).
- **FAIL:** any of B1–B2 unmet with valid run.
- **INCONCLUSIVE:** mandatory evidence missing (e.g. B3 not explained, physical check unavailable) without a proven violation.
- **PASS:** every mandatory criterion proven.

**Post-chaos same-VM backup verification, when applicable:** for chaos members, R4 is the same-VM check: failed VMs are retried through the fleet retry path, which resets the group's failed backup objects. Therefore before any retry `run.sh` MUST snapshot (yaml) every failed vmbackup, tracker, backup PVC and related events into `runs/<attempt-id>/pre-retry/`; failed objects are never reused by name and never deleted by the bundle itself. If the retry path cannot run without destroying that evidence first, mark R4 BLOCKED and record the missing approved recovery path.

## Execution and Approval

The Lead owns approval, execution, monitoring and reports. The Chaos Engineer prepares bundles only. The independent Analyst grades from raw evidence. Per the chosen operating style, each experiment is a lightweight `run.sh` bundle (Pattern A: native krkn trigger armed before the stage), human approval before arming.

**Preflight before costly pipeline:** execution host reachable; `oc`, `jq`, `krknctl`, `make` present; explicit kubeconfig; namespace `vm-cbt-demo`; `krknctl list available` / `describe` / `run --help` / `run --dry-run` for the exact command; trigger container has `oc`/`jq`/`bash` and a mounted kubeconfig (established for the krkn-hub image by the F-05 bundle preparation; re-verify on the installed version); read-only condition/effect access verified from inside the trigger environment; arming-ready marker (`waiting for triggers` in the krkn action log); pre-existing vmbackup inventory recorded.

| Stage / purpose | Exact existing command | Owner | Readiness handoff | Deadline / exit handling |
|---|---|---|---|---|
| Pre-run inventory | read-only `oc get` of nodes, VMIs, leases, ceph health, vmbackups | run.sh | inventory files written | 5 min; abort on error |
| Arm watcher (+ injector for chaos members) | member `inject.sh` | run.sh | arming-ready marker | 10 min; fail closed |
| Group run | `cbt-scale/fleet-e2e.sh run --os rhel9-light --count … --windows-count … --wave 25` | run.sh | wrapper log `RUN: driving group` | 45 min wall; capture exit separately |
| Grade | `cbt-scale/fleet-verify.sh`, `cbt-scale/chaos-grade.sh` | Lead | group `DONE` | 15 min |
| Pre-retry snapshot, then retry | snapshot to `runs/<attempt>/pre-retry/`; `fleet-e2e.sh run --retry <group> --only-failed` | run.sh (snapshot), Lead (retry) | snapshot complete | retry 30 min |

**Process and rollback ownership:** only invocation-owned background PIDs and the exact owned krkn container are stopped on interruption; trigger timeout/exit statuses are saved separately (never `tee` without `PIPESTATUS`). Rollback is limited to the scenario's own cleanup. Never run `make clean-all`, `ns-wipe.sh` or `scale-pool-gc.sh --delete` as part of a test; never delete evidence or objects of other groups.

**Approval bundle:** entrypoint plus every invoked script/config, this spec, effective blast radius and window, exact node/pod names resolved at plan time, run parameters. Lead records approval and file hashes in `approval.json` and rechecks before execution. Unchanged approval allows reruns; any change needs fresh approval.

## Reproducibility and Outputs

```text
cbt-chaos/scenarios_v2/<ID>/
  scenario-spec.md  run.sh  inject.sh  approval.json
  runs/<attempt-id>/
    run.json  injection-confirmation.json  analysis.json  run-report.md
    pre-run/  trigger/  pre-retry/  grade.tsv  verify.tsv  prom-sweep.log
  consolidated-report.md  bugs/<defect-slug>.md
```

Lifecycle/group evidence stays under `artifacts/groups/<group-id>/` and is referenced, not copied. `artifacts/` and `cbt-chaos/scenarios_v2/<ID>/runs/` are the only evidence locations; archive only on explicit request.

## Handoff and Follow-up

Engineer handoff lists bundle paths, stage ownership, bounds, rollback, effect/exclusion checks actually performed and known limits. The Lead closes every terminal attempt (including INVALID/BLOCKED) before any retry; after an INVALID injection defect at most ONE evidenced repair, fresh approval and a fresh attempt. Confirmed defects are deduplicated into `bugs/<defect-slug>.md`; new-scope ideas become PROPOSED/UNEXECUTED follow-up drafts.

**Open questions owned by the suite (resolve before approving any member):**
1. Fix the `fleet-e2e.sh` validator (`...-p01` vs `...-p01-<timestamp>`) or rely only on `fleet-verify.sh`/the grader. Decision: baseline-only (leave `fleet-e2e.sh` untouched) unless you approve a diff.
2. Verify the RBD allocated-bytes access path and the rack label (`topology.rook.io/rack`) used by S-03/S-04 node/OSD selection; unverified until preflight.
3. Terminal deadline 30 min and the 0% failure bar for S-01/S-02 are proposals to approve with engineering; they are test bounds, not product SLAs.

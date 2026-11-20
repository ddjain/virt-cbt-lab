# Scenario: CBT-S-03 — Kill OSD pods under the replica-1 backup pool while many backups copy

**Status:** PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW
**Planning reference:** scale campaign experiment E3; adapted from CBT-O-06 (OSD pod kill sweep), CBT-O-02/O-03 (CSI plugin kills). Shared contract: `CBT-S-00`; trigger/proof mechanics: `CBT-S-01`.

Use heading titles when linking this spec; do not depend on section numbers.

## Title

Prove that losing one (then three) OSDs under the size-1 backup pool turns into stalled-then-resumed or cleanly failed backups, never into false success or tracker corruption, and that backups recover on one retry.

## Description

`cbt-scale-pool` is replicated size 1, failureDomain `osd`, no device class: it spans all OSDs and has no redundancy. RBD images are striped into 4 MiB objects over many PGs, so [HYPOTHESIS] almost every in-flight backup image has objects on any given OSD, and one OSD kill stalls most or all concurrent backups until that OSD returns. Root disks live in the size-3, rack-failure-domain pool and are expected to ride through a single OSD loss.

**Legs (phase B peak first; phase D after S-03a passes):** S-03a one OSD; S-03b three OSDs on 3 distinct nodes and racks, killed serially. Pilot 10 → target 100.

**Safety (decision: "scoped"):** one component at a time; never two OSDs in the same rack at once (would put the size-3 root pool at risk); preflight aborts unless ceph has all PGs `active+clean`, no recovery/backfill in progress, and health no worse than the recorded pre-window baseline (known pre-existing warnings: insecure auth keys, `POOL_NO_REDUNDANCY`). Data loss risk: a pod delete leaves the OSD's disk intact so PGs go inactive, not lost; but any unplanned loss of the backing disk permanently loses backup data in this pool (test data only, rule 5).

## Chaos Injection

**Target and fault:** `rook-ceph-osd-<id>` pods in `openshift-storage`, 1 (S-03a) or 3 (S-03b), graceful delete. Selection at plan time: OSDs on nodes that host no `rook-ceph-mon` and no CNV control-plane pod; for S-03b, 3 distinct nodes and 3 distinct racks (rack label verified in preflight; unverified at spec time). OSD ids are recorded with pod UID, node, rack, host disk; selection is revalidated immediately before action.

**Command metadata:** `krknctl v0.14.2-beta`, `pod-scenarios` (flags as CBT-S-01). Exact names via `--name-pattern`, so `--pod-label` is omitted (same constraint as F-04 §7). Example for one OSD:

```sh
krknctl run pod-scenarios --kubeconfig "$KUBECONFIG_PATH" \
  --namespace openshift-storage --name-pattern "^rook-ceph-osd-${OSD_ID}-" \
  --disruption-count 1 --execution serial \
  --kill-timeout 180 --expected-recovery-time 300 \
  --trigger-command "$(cat trigger/condition.sh)" --trigger-expected-rc 0 \
  --triggers-mode all_of --triggers-interval 1 \
  --triggers-timeout 2700 --triggers-on-timeout fail
```
S-03b uses a regex alternation of the 3 selected ids and `--disruption-count 3 --execution serial`. [UNVERIFIED] whether krkn's serial mode waits for the first OSD's recovery before killing the next; the effect check defines the actual overlap and the leg's meaning (sequential vs near-simultaneous) — if near-simultaneous, S-03b is redesigned as three independent injections each with its own recovery gate before approval.

**Primary:** native command trigger, Pattern A. **Exception:** none anticipated.

**Reusable command:** `CHAOS_RUN_ID=<id> LEG=<A|B> STAGE=<pilot|target> PHASE=<F|I> KUBECONFIG_PATH=<approved-kubeconfig> bash cbt-chaos/scenarios_v2/CBT-S-03/run.sh --plan|--execute`.

## Injection Timing

Per CBT-S-01 (peak condition without the Lease clause; post-hoc proof). Additional read-only pre-action capture: `ceph status` and PG summary (via the existing toolbox access path used by `cbt-scale/scale-pool-gc.sh`, verified in preflight; if unavailable the leg is BLOCKED, not weakened). Bounds: as S-01; recovery observation until all PGs `active+clean` or 30 min.

## Effect and Blast-Radius Evidence

**Machine effect check:** per killed OSD: old pod UID gone, new pod Running/Ready; `ceph osd tree`/`ceph status` shows the OSD down→up with timestamps; PGs of `cbt-scale-pool` went `inactive`/`peering` during the window (proof the pool was actually affected) and returned `active+clean`. Per-VM stall proof: backup destination RBD write counters or backup progress stalled for the OSD-down interval.

**Blast-radius proof:** before/after OSD pod inventory (only the selected OSDs changed); size-3 root-pool PG states (must never become `inactive`); Ceph health delta; all non-selected pods unchanged.

**Evidence scope:** group id, T_ARM, fire time, OSD ids/UIDs/nodes/racks, ceph status snapshots.

## Expected Behavior / Pass-Fail Criteria

R1–R7 from CBT-S-00. Suite-specific (decision: failures tolerated, terminal within 30 min, no false success, 100% pass on one retry):

| Requirement | Expected product behavior | Evidence / check | Mandatory? |
|---|---|---|---|
| S03-1 | OSD(s) back and PGs `active+clean` within the observation window; root-pool PGs never inactive | ceph snapshots | yes (else INVALID/BLOCKED per cause) |
| S03-2 | every backup terminal by 30 min after fire; either `PASS` or `FAILED-CLEAN` | grader | yes |
| S03-3 | zero `FALSE-SUCCESS`: no backup reports success while its destination lacks data (EXP-07 class) | physical check (RBD allocated bytes + deep sample) | yes |
| S03-4 | zero `TRACKER-DRIFT`: failed backups leave the tracker at its prior checkpoint | tracker snapshots | yes |
| S03-5 | 100% of non-`PASS` VMs reach `PASS` on one retry | retry grade | yes |
| S03-6 | no stuck finalizers: failed/terminal backup objects and hp-volume attachments release (4-hop chain: VMI hotplug status → VolumeAttachment → PV external-attacher → RBD image) | inventory at deadline | yes |
| S03-7 | record share of backups stalled and per-VM stall duration (measurement, hypothesis check) | timeline | no |

**Terminal verdicts / same-VM verification:** per CBT-S-00 (pre-retry snapshot is mandatory; the retry reset removes failed objects). INVALID if the pool PGs were never inactive (fault had no effect on the backup path) or if two OSDs in one rack were down together.

## Execution and Approval

Per CBT-S-00/CBT-S-01. Additional approval items: OSD ids/UIDs/racks, ceph baseline, explicit acceptance of the replica-1 data-loss risk. Rollback: Rook/Deployment reconciliation only; never run `ceph osd out/purge`, `rbd rm`, `scale-pool-gc.sh --delete`, or touch OSD disks. After the run, report any orphan images via `scale-pool-gc.sh` in report-only mode.

## Reproducibility and Outputs

Per CBT-S-00. ceph snapshots saved under `runs/<attempt>/pre-run/` and `runs/<attempt>/post/`.

## Handoff and Follow-up

Per CBT-S-00. Follow-ups (unexecuted): CSI node-plugin kill on the target nodes (adapts O-02), CSI provisioner kill (adapts O-03), mon/mgr kill (adapts O-07). **Uncertainties:** how widely a single OSD kill stalls backups (hypothesis above); serial semantics of krkn for 3 kills; ceph toolbox access path; whether stalled copies time out into `Backup has failed` or resume.

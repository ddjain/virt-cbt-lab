# CBT product-flow analysis — CBT-F-01 — run `20261016-cbt-f-01-r04` (interrupted full backup)

> Scope: what the **CBT product** (KubeVirt/OpenShift Virtualization `VirtualMachineBackup`
> + `VirtualMachineBackupTracker` machinery) did under a launcher-pod deletion in the active
> disk-copy window, judged from this run's closed evidence pack and the two earlier run labels
> cited for the repeated quiesce warning. Harness/sequence events (late `PRESERVED` handoff,
> duplicate trigger launch refused, trigger self-match, non-monotonic `deletionTimestamp`,
> the missing post-recovery checkpoint-tree capture, report citation errors, container
> `PodSecurity` warnings) are classified as harness observations and are **excluded from
> product findings** except where they bound product evidence (called out explicitly below).
> All times UTC; run labels are dated `20261016`, while the r02/r03 cluster timestamps fall on
> 2026-10-15T21:xxZ and r04's on 2026-10-16T01:xxZ.
>
> Read-only wrt the run directory. Sources used: this run's pack
> (`runs/20261016-cbt-f-01-r04/{trigger,observer,checkers,reports}/**`, `driver.log`,
> `driver-timings.json`, `verdict.json`, `state.json`, `ledger.jsonl`, `evidence-index.json`),
> `scenario-spec.md`, `jira-issue.md`; run `20261016-cbt-f-01-r03` (scenario artifacts);
> lifecycle run artifacts `runs/20261016-cbt-f-01-r02/**` (r02 has no scenario-level artifact
> directory — see §4); upstream API source
> `kubevirt/kubevirt` `staging/src/kubevirt.io/api/backup/v1alpha1/types.go` (branch `main`,
> read 2026-10-16). No cluster access was used for this analysis.

## 0. Bottom line

**No product defect is supported by this run's evidence.** Every CBT behaviour the run
exercised landed on the safe side of the scenario's own fail criteria (`scenario-spec.md` §4):
the interrupted full backup reached a terminal **failure** with an explicit failure reason and
created nothing a consumer could accept as a recovery point; the tracker's `latestCheckpoint`
never advanced for the interrupted copy; the VM/VMI recovered and CBT returned to `Enabled`; the
failed backup object and its destination PVC were preserved rather than reused; and a separate
clean lifecycle completed a full + incremental with restore verification passing. One
**product** question remains open and is not answerable from this run (§5): whether a backup
taken in the first seconds after a VM restart, when the guest filesystem could not be quiesced,
is crash-consistent — and, secondarily, whether the interrupted copy left a launcher-side
libvirt checkpoint after the restart (`scenario-spec.md` §4.3 post-recovery capture, which this
run never took). No engineering ticket is drafted, because no observed behaviour warrants one
(§3 records the three candidate observations and why each is dispositioned as not-a-defect).

## 1. Observed CBT behaviour vs the intended contract

| # | Intended contract (`scenario-spec.md` §1/§4, `jira-issue.md`) | Observed CBT behaviour | Evidence | Verdict |
|---|---|---|---|---|
| 1 | Copy interrupted in the active window; VMI gets a replacement launcher | `Backup started` (`backup.go:83`) with `backupName=vm-backup-20261016-cbt-f-01-r04` at 01:12:26.758Z; that backup object flips `Progressing=True` "Backup is in progress" in the same second; launcher pod UID `8fa3ecb1…` gone at 01:12:38Z; replacement UID `18f9474d…` Ready 01:12:49Z | `trigger/trigger.log:10`, `observer/watches/vmbackup-run.jsonl` rv 27101677, `trigger/effect-check.json` (`elapsed_seconds=23`, `within_120s=true`), `observer/watches/pods-vm.jsonl` DELETED/ADDED | HELD |
| 2 | In-progress full backup **fails safely** with a clear reason | Terminal at 01:12:38Z: `Progressing=False` **and** `Done=True`, both reason `Backup has failed: VMI backup status was lost`; `status.type=Full`; `status.error` absent; the launcher's loss 12 s into a 22 s copy is the only candidate cause | `observer/watches/vmbackup-run.jsonl` rv 27101944; `driver.log` FULL BACKUP step 4 (`✗ Full backup failed`) | HELD |
| 3 | No checkpoint advancement attributable to the failed copy | Tracker `vm-tracker-20261016-cbt-f-01-r04`: `latestCheckpoint` **absent/null** before and after the failure; the stream holds exactly 2 events (ADDED rv 27101450 null → MODIFIED rv 27102706 = the later same-VM recovery checkpoint). The failed object's own stamped name `vm-backup-20261016-cbt-f-01-r04-2026-10-16_01-12-16` appears in **no** tracker field | `observer/watches/tracker.jsonl`; `observer/finding.md`; `verdict.json` check `tracker-not-advanced` (`tracker_latest_checkpoint=<empty>`) | HELD |
| 4 | Failed artifact preserved and **not** accepted as a recovery point | Failed object and destination PVC `vm-backup-pvc-20261016-cbt-f-01-r04` (Bound, 80Gi) still present and unchanged at preservation and on later live re-reads; the recovery leg used a **distinct** object and PVC (`vm-recovery-full-…-r001` / `vm-recovery-pvc-…-r001`) while the failed PVC stayed untouched | `observer/PRESERVED`, `observer/finding.md`, `observer/watches/vmbackup-run.jsonl` rv 27102251 (recovery object spec, `forceFullBackup: true`, source = the run tracker) | HELD |
| 5 | VM/VMI returns to Running and CBT returns to `Enabled` | Replacement launcher Ready 01:12:49Z; VM UID `24f3a591…` unchanged across the disruption while the VMI object was replaced; recovery-leg preconditions record `vmi_running=Running`, `cbt_enabled=Enabled`, `vm_uid_matches_run=true` | `trigger/effect-check.json`; `reports/test-run-report.md` "Recovery of disrupted workload"; `verdict.json` check `cbt-recovered` | HELD |
| 6 | Same-VM recovery full backup completes; tracker advances to **its** checkpoint | `vm-recovery-full-20261016-cbt-f-01-r04-r001` `Done=True` at 01:13:14Z, reason `Completed VirtualMachineBackup, warning: Failed freezing guest filesystem: virError(Code=86, … Guest agent is not responding: QEMU guest agent is not connected)`; tracker advances to `vm-recovery-full-…-r001-2026-10-16_01-12-53` (a checkpoint distinct from the interrupted copy) | `observer/watches/vmbackup-run.jsonl` rv 27102723; `observer/watches/tracker.jsonl` rv 27102706; `driver.log` step 3 of the recovery leg | HELD, with the unquiesced-copy question of §5.1 |
| 7 | Recovery is real: restore of the recovery full matches the baseline | 1000 files, 18,277,728,256 bytes, manifest SHA-256 match on the recovery attempt; same for the clean lifecycle's full-only, incremental-prefix and combined restores | `driver.log` (VERIFICATION steps, `✓ Recovery attempt r001 baseline file set, bytes, and hashes match`); `verdict.json` checks `same-vm-recovery`, `clean-lifecycle`; `reports/test-run-report.md` "Data integrity" | HELD |
| 8 | Separate clean lifecycle: fresh full + incremental, repository restore verification passes | Clean full `Done=True` "Successfully completed VirtualMachineBackup" @01:16:47Z (76 s) on a **fresh** tracker whose VM never restarted; incremental `…-p01` `Done=True` same reason @01:18:40Z; tracker `tracker_matches_final_checkpoint: true`; both restores match | `observer/watches/vmbackup-clean.jsonl` rv 27107127 / rv 27109311; `driver.log` clean leg; `verdict.json` check `clean-lifecycle` | HELD |

Nothing in the run exercised a CBT path that behaved outside the contract. In particular, the
two conditions that would have been headline defects — a successful terminal state on the
interrupted copy, or any tracker advancement attributable to it — did not occur (rows 2–3).

## 2. The negative, stated with its evidence

**No product defect is supported by this run's evidence.** The negative rests on:

- **The failure was reported, not masked** — `observer/watches/vmbackup-run.jsonl` rv 27101944
  carries `Done=True` **together with** `Progressing=False` and the reason
  `Backup has failed: VMI backup status was lost`, `lastTransitionTime=2026-10-16T01:12:38Z`
  (identical on the observer's later live re-reads per `observer/finding.md`), and the repo
  pipeline's own check refused it (`driver.log`: `✗ Full backup failed … reached Done=True but
  the backup actually failed`). A masked failure would have shown a success reason here.
- **No checkpoint advancement** — `observer/watches/tracker.jsonl` holds exactly two events
  (§1 row 3); the interrupted copy's checkpoint name is absent from every tracker field, and the
  only value the tracker ever takes is the same-VM recovery checkpoint.
- **No partial artifact was accepted as restorable** — restore verification ran only against the
  recovery full (`vm-recovery-pvc-…-r001`) and the clean lifecycle's volumes;
  `vm-backup-pvc-20261016-cbt-f-01-r04` was retained Bound and untouched (`observer/PRESERVED`,
  `observer/finding.md`).
- **Recovery happened and CBT re-enabled** — `verdict.json` checks `launcher-replacement`,
  `cbt-recovered`; `trigger/effect-check.json` (`old_pod_gone=true`, replacement Ready,
  `within_120s=true`).
- **The clean lifecycle passed end to end** — `verdict.json` check `clean-lifecycle` and
  `driver.log`'s clean leg: full + 1 incremental, both `Done=True` with
  `Successfully completed VirtualMachineBackup`, tracker matching the final checkpoint, and all
  restore/hash comparisons matching.

The three findings a reader might expect — and their disposition — are in §3. They are
**observations about the deployed API surface and about an untested guest state, not defects**.

This negative is **in agreement with the run's own reports and the sibling run analysis**, which
reach it independently: `reports/test-run-report.md:162` ("**Product findings:** none established
by this run … the product behaved as required") with the same statement in
`reports/test-run-result.md:70` ("No product defect was established from this run"), the next
action recorded there being harness coverage rather than a product change, and
`analysis/20261016-cbt-f-01-r04.md` §4.1 row P6 ("No product defect established … the sixth
[spec criterion] unestablished for missing evidence, not for contrary evidence"). No artifact in
this pack asserts a contrary product finding.

## 3. Candidate product observations, examined and dispositioned (no ticket)

### 3.1 A failed backup exposes `Done=True` + `type=Full` + a Bound destination PVC; success and failure are distinguishable only by free text

Observed: `observer/watches/vmbackup-run.jsonl` rv 27101944 — `type: Full`,
`Done=True` with reason `Backup has failed: VMI backup status was lost`, `checkpointName`
populated, destination PVC Bound. The **only** machine-readable discriminator between this and
the successful backups (`Done=True`, reason `Successfully completed VirtualMachineBackup` on the
clean full/incremental, rv 27107127 / rv 27109311, and on the recovery full with a warning,
rv 27102723) is the `reason` string; there is no `Failed`/`Complete` condition type and no
`status.error` in this deployment.

Consumer-visible consequence, observed inside this run: the repo pipeline read the interruption
as success first — `driver.log` FULL BACKUP step 2 printed `✓ Backup completed · 22s` and step 3
printed `✓ vm-backup-20261016-cbt-f-01-r04 is a Full backup` — and only step 4 (reason-string
inspection) caught the failure. That is a harness artefact in execution, but it is real
evidence of the **API surface** at issue: `Done=True` + `type=Full` + a Bound PVC is exactly the
shape a naive consumer keying on `Done` would accept.

Disposition — **no ticket from this run**, for two reasons.
(a) The behaviour is coherent with the condition model this deployment actually exposes
(`Initializing` / `Progressing` / `Done` only, everywhere in the pack): a single terminal
condition whose reason carries the outcome. `scenario-spec.md` §4 already encodes that reading
("`Done=True` alone is not success or failure evidence; inspect its reason"). No evidence in the
pack shows a success reason on a failed copy or vice versa.
(b) Upstream `main` has restructured exactly this surface — `staging/src/kubevirt.io/api/backup/v1alpha1/types.go`
defines condition types `Complete`, `Failed`, `Progressing`, `Quiesced` with reasons
`ReasonFailed`, `ReasonSourceLost`, `ReasonCompletedWithWarning`, `ReasonQuiesceFailed`, and the
in-tree changelog for v1.9.0 lists "Expose FS freeze status early in VirtualMachineBackup"
(`kubevirt.io/2026/changelog-v1.9.0.html`, item `[PR #18082]`). **[INFERENCE]** this deployment
predates that restructure — the condition vocabulary in every snapshot here
(`Initializing`/`Progressing`/`Done`) does not contain `Failed`, `Complete` or `Quiesced`, and
the KubeVirt version is not recorded in the pack (§6), so the delta cannot be pinned to a
release. Filing a new engineering ticket for an ambiguity that upstream has already replaced
would be duplicative; the correct action is the consumer-side reading rule, which §7 states.

### 3.2 A failed guest-filesystem freeze is reported only as a warning inside `Done.reason`, and a *successful* freeze is signalled only by the absence of that warning

Observed on the r04 same-VM recovery full: `Done=True`, reason
`Completed VirtualMachineBackup, warning: Failed freezing guest filesystem: virError(Code=86, … QEMU guest agent is not connected)`
(`observer/watches/vmbackup-run.jsonl` rv 27102723). The copy then proceeded and completed. In
r03 the same sequence is visible line-by-line in the launcher's own log: `Freezing VMI to
capture backup state` (backup.go:181) → libvirt `Guest agent is not responding: QEMU guest agent
is not connected` (qemuDomainAgentAvailable:7402) → launcher `warning Failed freezing guest
filesystem` → `Backup started` (backup.go:83) 60 ms later — i.e. **the freeze failure does not
stop the copy** (`runs/20261016-cbt-f-01-r03/observer/watches/launcher-compute.log:70-78`). The
successful clean full carries no warning at all, so in this deployment a consumer can only
infer "quiesced" from the absence of the warning text.

Disposition — **no ticket**: proceeding without quiesce is the product's documented
non-fatal design, not an error path gone wrong. The `VirtualMachineBackup` spec exposes
`skipQuiesce` as an explicit opt-out (`…/backup/v1alpha1/types.go`, `VirtualMachineBackupSpec`),
and upstream models the outcome as its own condition (`ConditionQuiesced` with
`ReasonQuiesceFailed` / `ReasonQuiesceSucceeded` / `ReasonQuiesceSkipped`) separate from
`Complete`/`Failed` — i.e. quiesce failure is deliberately *not* a backup failure. The scenario
itself does not classify it as one (`checkers/evidence-sufficiency.json:109`: "This is a
completion with a warning, not a masked failure"). The residual concern is the guest state this
created, which is §5.1 — a question, not a defect.

### 3.3 The failed object carried a `checkpointName` that was never published to the tracker

Observed: `status.checkpointName=vm-backup-20261016-cbt-f-01-r04-2026-10-16_01-12-16` from
rv 27101678 onward on the interrupted object, while `vm-tracker-20261016-cbt-f-01-r04`
`latestCheckpoint` stayed empty (`observer/watches/tracker.jsonl`). The checkpoint name exists
on the failed object only; it is not a tracker advancement and no consumer in this run treated
it as one.

Disposition — **no ticket**; single-run observation with no demonstrated consumer harm, and it
is the same object-field surface already restructured upstream (§3.1b). It does bound §5.2: the
pack proves the name was *stamped*, and proves nothing about whether a libvirt checkpoint
actually existed at the launcher or survived the restart.

## 4. The repeated post-restart quiesce warning — re-verified against the runs it cites

The claim "already reproduced twice (`20261016-cbt-f-01-r02`/`-r03`)" was re-verified from those
runs' own artifacts rather than repeated from prose. Both hold:

| Run label | Interrupted full (same failure mode) | Same-VM recovery full | Quiesce-warning evidence |
|---|---|---|---|
| `20261016-cbt-f-01-r02` | `vm-backup-20261016-cbt-f-01-r02`: `type=Full`, `done=True`, reason `Backup has failed: VMI backup status was lost`, stamped checkpoint `…-2026-10-15_21-12-08`, `pvc_phase=Bound`, `tracker_checkpoint_at_failure=""` | `vm-recovery-full-20261016-cbt-f-01-r02-r001`, `done_status=True`, reason `Completed VirtualMachineBackup, warning: Failed freezing guest filesystem: virError(Code=86, … QEMU guest agent is not connected)`, checkpoint `…-2026-10-15_21-12-36`, `force_full_backup=true`, restore `passed` | lifecycle artifacts `runs/20261016-cbt-f-01-r02/run.json` (`backups.full_failure`, `recovery.attempts[0].recovery_full.done_reason`), `summary.json` (`recovery_attempts[0].recovery_backup.done_reason`), `report.json`, `fragments/recovery-r001.json`, `logs/workflow.log:49` |
| `20261016-cbt-f-01-r03` | `vm-backup-20261016-cbt-f-01-r03` identical failure reason, `pvc_phase=Bound`, interrupted checkpoint `…-2026-10-15_21-25-19`, tracker empty (`verdict.json` checks `backup-interrupted`, `tracker-not-advanced`; `driver.log:70`) | `vm-recovery-full-20261016-cbt-f-01-r03-r001`, checkpoint `…-2026-10-15_21-25-54`, `forceFullBackup=true` (`driver.log:107`) | `runs/20261016-cbt-f-01-r03/observer/watches/launcher-compute.log:75` (launcher warning, 2026-10-15T21:26:00.033Z, with the libvirt agent-not-connected error on the preceding lines), `observer/events-final.json:594`, `observer/events-preserved.json:771`, `test-run-report.md:77,85,133` |

So the warning is now observed on **three** run labels (r02, r03, r04), each time on the forced
full backup taken on the same VM seconds after that VM's launcher was deleted and replaced, and
each time the copy completed and its restore matched. One correction to the record: the r03
report attributes the second observation to "the equivalent run labelled
`20261016-cbt-f-01-r02`", but r02 has **no scenario-level artifact directory** under
`cbt-chaos/scenarios_v2/CBT-F-01/runs/` — the corroboration is available only from r02's
lifecycle run artifacts (`runs/20261016-cbt-f-01-r02/**`), which is where it was verified above.
That does not weaken the claim; it is a sourcing correction a reader should have.

## 5. Open product questions this run leaves (the only ones)

### 5.1 (Primary) Is a post-restart, unquiesced backup crash-consistent?

The r04 recovery full was requested with quiesce **enabled** (`VirtualMachineBackupSpec` of
`vm-recovery-full-…-r001` sets `forceFullBackup: true` and no `skipQuiesce`,
`observer/watches/vmbackup-run.jsonl` rv 27102251/27102252), and the freeze failed because the
guest agent had not reconnected yet. Timing: the VMI was restarted at ~01:12:38Z (old launcher
gone), the replacement launcher reached Ready at 01:12:49Z, the recovery backup object was
created at 01:12:53Z, its `Progressing=True "Backup is in progress"` appears at 01:12:57Z, and
the terminal warning is stamped 01:13:14Z — i.e. the freeze attempt fell inside
01:12:57Z–01:13:14Z, roughly 19–36 s after the VMI restart and 8–25 s after launcher readiness.
(The exact freeze instant is not recoverable for r04: the pack holds no launcher `compute` log
for leg 2 — the warning survives only in the CR reason. r03 has the launcher-side line, at
2026-10-15T21:26:00.033Z, ≈6 s after its recovery checkpoint window opened, and it is the same
`Initializing backup → Freezing VMI → agent not connected → warning → Backup started`
sequence.)

What the run *does* establish: the unquiesced copy completed and its restore matched the
baseline (1000 files / 18,277,728,256 B / manifest hash,
`driver.log` recovery-leg VERIFICATION; `verdict.json` `same-vm-recovery`). What it does **not**
establish: crash-consistency of the guest filesystem. The workload is quiesce-insensitive by
construction — 1000 static files written and hashed *before* the backup, with no in-flight
writes at the restart instant (`scenario-spec.md` §2 baseline workload; `reports/test-run-report.md`
environment table) — so a matching restore cannot distinguish a crash-consistent image from a
journal-dirty one. Answering it needs a workload with buffered/in-flight writes at restart time
(e.g. an fsync-heavy or database-shaped writer) plus a post-restore guest-side check
(filesystem check / journal replay / application-level validation), and a comparison against a
quiesced backup of the same state. **This is the only product question this run genuinely
leaves open.** It is a test-coverage gap in the scenario, not evidence of a defect.

### 5.2 (Hypothesis, unverified) Did the interrupted copy leave a launcher-side libvirt checkpoint that survived the restart, and would the next incremental's base have been well-defined?

**HYPOTHESIS.** The interrupted backup failed *after* its checkpoint was created (name stamped
by 01:12:26Z, failure 01:12:38Z), and the same-VM recovery path used `forceFullBackup: true`,
so no incremental was ever taken on that VM's tracker afterwards — the incremental path on the
post-failure tracker is **untested by this run**. Whether a libvirt checkpoint/bitmap existed at
the moment the launcher died, and whether it persisted in the disk image across the restart, is
not established by any artifact here: the pack contains no libvirt checkpoint-tree capture after
VM recovery (`scenario-spec.md` §4.3 requires one before injection **and** after recovery; only
the pre-injection capture exists, `trigger/trigger.log:9`, empty, exit 0) and no on-disk
inspection of the failed destination PVC. Related prior art from another scenario — CBT-F-04
r03 observed an orphaned libvirt checkpoint retained after a failed backup's CR was deleted
(`cbt-chaos/scenarios_v2/CBT-F-04/analysis/20261015-cbtf04-r03-product-flow.md` §3 Finding 2 /
Draft 3), while CBT-F-04 r04's initialisation-time failure left no tree entry — narrows the
question to the **post-checkpoint failure path**, which is exactly this run's path. Testable
next run with a read-only `virsh checkpoint-list … --tree` before injection and after recovery,
plus an incremental on the same tracker (no `forceFullBackup`) to confirm the base checkpoint
the engine actually uses.

**Harness boundary, stated so it is not mistaken for a product finding:** the missing capture is
a harness gap — the observer contract excluded `oc exec` and the trigger captures only
pre-injection state (`observer/finding.md` gaps; `ledger.jsonl` `reject_verified`;
`checkers/evidence-sufficiency.json` REJECT on spec-4.3). It is the reason the **run verdict is
BLOCKED**, and it is why §5.2 cannot be answered. It is not a CBT behaviour, and nothing in it
implicates the product. The gap is also **not an r04 regression**: r03's trigger log carries the
pre-injection label with no capture annotation at all (`runs/20261016-cbt-f-01-r03/trigger/trigger.log:5`,
versus r04's annotated `trigger/trigger.log:9`), the same bare label recurs with no output at
`runs/20261016-cbt-f-01-r03/driver.log:54`, and a pack-wide search of r03 for
`virsh`/`checkpoint-list`/"checkpoint tree" hits only those two labels — no capture output —
so neither run ever captured a usable libvirt checkpoint tree.

### 5.3 Ruled out as product questions

- **False success / masked failure:** ruled out (§2, §1 row 2).
- **A partial artifact accepted as restorable:** ruled out — the failed PVC was preserved and
  never used as a recovery point (§1 row 4).
- **Failure to recover the VM or CBT state:** ruled out (§1 row 5).
- **Broken clean-lifecycle backup/restore path:** ruled out (§1 row 8).
- **Chaos causation of the freezes:** ruled out — the r04 recovery leg ran 15 s after the
  replacement launcher became Ready on a VM whose only anomaly was the guest agent not yet
  reconnected; the identical warning appears in a run where nothing else was disturbed, and the
  clean lifecycle (no restart, no disruption) had no warning at all. The mechanism is guest-agent
  readiness, not the disruption.

## 6. Environment actually exercised (from the artifacts)

| Component | Value | Evidence |
|---|---|---|
| OpenShift / Kubernetes | Server Version 4.22.15, Kubernetes v1.35.6 (client 4.22.15) | `preflight.json` check `1-cluster-reachable-and-namespace-present` |
| CNV / KubeVirt presence | KubeVirt CR `openshift-cnv/kubevirt-kubevirt-hyperconverged` `phase=Deployed`, conditions `Available=True(AllComponentsReady)`, `Progressing=False`, `Degraded=False`; CDI `Deployed`; `openshift-cnv` deployments all at ready/desired (virt-api 2/2, virt-controller 2/2, virt-operator 2/2, virt-synchronization-controller 2/2, cdi-* 1/1, hco-operator 1/1) | `preflight.json` check `2-kubevirt-and-cdi-available` |
| **KubeVirt / CNV software version** | **Not recorded in this run's artifacts** (no image tag or digest anywhere in the pack — the only version strings present are the OpenShift/Kubernetes ones above). The observable discriminator is the **condition vocabulary** of `backup.kubevirt.io/v1alpha1`: this deployment exposes only `Initializing` / `Progressing` / `Done` (+ `status.type`, `status.checkpointName`, `status.includedVolumes`), with no `Complete`, `Failed` or `Quiesced` condition and no `status.error` | `observer/watches/vmbackup-run.jsonl` (rv 27101457, 27101677, 27101944, 27102364, 27102723), `observer/watches/vmbackup-clean.jsonl` (rv 27105668, 27107127, 27109311) vs upstream `staging/src/kubevirt.io/api/backup/v1alpha1/types.go` (main) |
| libvirt (guest host, launcher-side) | libvirt 11.10.0, package `12.3.el9_8` | `runs/20261016-cbt-f-01-r03/observer/watches/launcher-compute.log:72` (r03 only; r04's pack has no launcher log) |
| Storage | ODF, storage class `ocs-storagecluster-ceph-rbd` (provisioner `openshift-storage.rbd.csi.ceph.com`, `volumeBindingMode=Immediate`, `reclaimPolicy=Delete`); StorageCluster `Ready`; CephCluster `phase=Ready`, `HEALTH_OK` | `preflight.json` check `3-large-odf-storage-class-usable` |
| Guest | RHEL 9, CBT enabled; baseline 1000 files / 15–20 MiB each (18,277,728,256 B); incremental pass +1000 files | `driver.log` pipeline configuration; `reports/test-run-report.md` environment table |
| Backup API objects exercised | `VirtualMachineBackup` (Full; Full forced; Incremental) sourced from `VirtualMachineBackupTracker`, push mode, default quiesce | `observer/watches/vmbackup-run.jsonl`, `observer/watches/vmbackup-clean.jsonl` (`.spec`) |

## 7. Operational guidance implied by this run (consumer-side, not a product change)

- **Do not read `Done=True` as success on this deployment.** Success and failure share the
  `Done` condition; the outcome is in `Done`/`Progressing` `reason`
  (`Successfully completed VirtualMachineBackup` / `Completed VirtualMachineBackup, warning: …`
  vs `Backup has failed: …`), and `type=Full` plus a Bound destination PVC is set even for a
  copy that never produced a usable artifact (§3.1; this run's own pipeline initially printed
  "Backup completed" for the interrupted copy).
- **A destination PVC in `Bound` proves allocation, not validity.** The interrupted copy's PVC
  was Bound for the whole run; validity comes from the terminal reason and, for a recovery
  point, from restore verification against the workload manifest.
- **After a launcher loss, expect the first backup on that VM to be unquiesced.** In all three
  observed runs the guest agent had not reconnected when the recovery copy froze the guest; if
  application consistency matters for that copy, wait for the guest agent to answer before
  starting it, or accept a crash-consistent image and validate it accordingly (§5.1).
- **Treat the tracker as the only advancement signal.** `VirtualMachineBackupTracker.status.latestCheckpoint`
  is what this deployment advances on success, and it did not move for the interrupted copy;
  a checkpoint name present on a failed `VirtualMachineBackup` object is not an advancement
  (§3.3).

## 8. Evidence-confidence limits (stated, non-blocking)

- The failed destination PVC was **not** inspected on disk and its libvirt checkpoint tree was
  never captured; "the interrupted artifact is not usable as a recovery point" rests on the
  object's terminal failure reason, on the tracker never advancing, and on the artifact never
  being restored — not on positive inspection of the bytes. Deliberate: the pack's missing
  spec-4.3 capture (`trigger/trigger.log:9` only, after four failed attempts on lines 4–7) is a
  harness gap, and it is what makes the run verdict BLOCKED.
- The exact launcher-loss instant is bounded, not exact, on non-trigger evidence
  (01:12:31Z present → 01:12:41Z absent per `observer/finding.md`; the delete request and kill
  events are second-resolution); the failed copy's duration (22 s per `driver.log`) therefore
  carries a few seconds of slack.
- Snapshot timing of the failure is second-resolution (`lastTransitionTime` fields); sub-second
  ordering within 01:12:26Z cannot be resolved from the streams.
- The recovery leg's freeze instant is bounded by the object's condition transitions, not
  observed directly, for r04 (§5.1). Its completion is recorded one second apart in two
  artifacts — stream `lastTransitionTime` 01:13:14Z (`observer/watches/vmbackup-run.jsonl`
  rv 27102723) versus 01:13:15Z in the report's key-timings table
  (`reports/test-run-result.md`) — with no criterion depending on it; this file uses the
  stream value throughout.
- The r04 pack contains no KubeVirt/CNV version string, so version-scoped claims are stated as
  observed vocabulary plus labelled inference (§3.1b, §6), never as pinned releases.
- Harness-classified items, recorded for completeness and excluded from the product findings
  above: the observer's `PRESERVED` handoff 6m22s late (its own poll-loop arithmetic error,
  self-reported, streams continuous and nothing lost); the Lead's duplicate trigger launch
  refused by the trigger's collision guard; the trigger worker's first launch self-refused on a
  self-matching `pgrep`; the unexplained non-monotonic `deletionTimestamp` on the interrupted
  pod UID (01:13:26Z in rv 27101685/27101692/27101917, 01:12:38Z in rv 27101925/27101926 — cited
  per `checkers/report-fidelity.json`'s corrected attribution); the four failed pre-injection
  checkpoint-tree capture attempts; the missing post-recovery capture; the restore-verifier
  `PodSecurity` warnings; the report-fidelity REJECT→revision→PASS cycle; and the
  evaluator-wider-than-spec PASS (deterministic core PASS 8/8 vs run verdict BLOCKED on
  evidence). None of these is a CBT product behaviour.

# CBT-EXP-06 — product findings from run `20261016-exp06-r02` and its same-VM follow-up

> **Consolidated working analysis — NOT a filed ticket.** This document is the working analysis behind the CBT-EXP-06 defect set; the per-defect Jira-ready tickets are the sibling files in this folder: `backup-cr-livelock-on-missing-per-disk-bitmap.md` (P1), `vm-wide-backup-capability-deadlock.md` (P2), `backup-destination-volume-stuck-hotplug-mounted-during-wedge.md` (P3), `backup-cr-event-stream-empty-on-wedge.md` (P4), `checkpoint-redefinition-accepts-incomplete-checkpoint.md` (P5), `vmi-backupstatus-advertises-nonexistent-checkpoint.md` (P6). Its drafts A/B/C and its negative-result sections are retained as provenance for those tickets.
> Do not file this document itself, and do not treat its Draft A as a single ticket — the Lead's mapping splits it across P1/P2/P5.

Engineering-ticket drafts, written from the **closed** run `20261016-exp06-r02`
(verdict `BLOCKED`, closed 2026-10-16T05:34:13Z) and from the post-close same-VM
follow-up on that run's VM (`20261016-exp06-r02-same-vm`, driver window
05:34:34Z–05:55:26Z). Nothing under `runs/20261016-exp06-r02/` was modified.

Provenance convention used below: **observed** = backed by a named artifact in
this repository; **reported** = asserted by the follow-up driver's write-up
without a dedicated artifact; **inference** = reasoning the artifacts support but
do not close. Every UTC is from the named artifact. Prior-run material
(`20261014-exp06-r01`, `20261014-exp08-r01`) is cited only where the closed run or
the reference finding `docs/findings/finding-1-backup-cr-livelock.md` draws on it.

---

## 0. Disposition of the existing draft (explicit answer)

Existing draft: `cbt-chaos/scenarios_v2/CBT-EXP-06/bugs/backup-cr-livelock-on-missing-per-disk-bitmap.md`
(merged "finding-1 Path A" from `20261014-exp06-r01` + Path B from `20261014-exp08-r01`).

**Recommendation: UPDATE that draft in place — do not open a second ticket for the
same root cause, and do not treat it as merely "supplemented" by a new file.**

Reasoning, finding by finding:

| New finding | Already in the existing draft? | Action |
|---|---|---|
| 1. Non-terminal wedge on checkpoint/bitmap inconsistency | Yes — this is the draft's core (Path A). | **UPDATE**: add the `20261016-exp06-r02` + follow-up evidence and the refined numbers; the draft currently reports "19 retries in 22 minutes" from r01 only. |
| 2. One-backup-per-source turns the wedge into a VM-wide capability deadlock | Yes, but only as a Path-B (deleted-tracker) variant ("Second entry path + deadlock variants", EXP-8 section). | **UPDATE**: promote it to a first-class, path-independent behaviour and add the corrupt-checkpoint reproduction (follow-up F1). |
| 3. Checkpoint redefinition silently drops the disk; the tracker keeps advertising it | Partly — item 1 of the draft's summary names the redefinition; the tracker retention is stated. | **UPDATE**: add r02's checkpoint XML (only `vda`) + tracker `volumes=[rootdisk,datadisk]` pair and the follow-up's proof that this stale entry is what keeps *later* passes wedged. |
| 4. VMI `status.changedBlockTracking.backupStatus` names a nonexistent checkpoint | No. | **NEW ticket** — Draft B below. |
| 5. Guest-freeze `Code=113` on `/mnt/datadisk` role unresolved | No. | **NEW ticket (question)** — Draft C below. |
| 6. Hypothesised silent *completed* drop did NOT reproduce | Partly — the draft says "the hypothesized silent drop did NOT occur" for r01. | **UPDATE**: state it for all three attempts, explicitly, with the negative-result section below. |

Supplementary material (r02 lifecycle records, checker rejects, harness findings)
belongs to the scenario/harness tickets, not to this product ticket set.

---

## 1. Confirmed defects vs open questions (explicit separation)

**Confirmed product defects (behaviour reproduced, contract violated):**

- D1 — A `VirtualMachineBackup` whose checkpoint is inconsistent with the QEMU
  dirty bitmaps is left **non-terminal indefinitely** (no `Done`, no `Failed`, no
  deadline, finalizer held, target PVC leak). Reproduced **3/3** on the
  corrupt-checkpoint path (`20261014-exp06-r01` leg B; `20261016-exp06-r02` p01;
  `20261016-exp06-r02` follow-up p02). → Draft A.
- D2 — While such a CR is wedged, the **one-backup-per-source rule rejects every
  new backup on the VM** (admission error), deadlocking the VM's whole backup
  capability. Now reproduced on the corrupt-checkpoint path too. → Draft A.
- D3 — The checkpoint redefinition **silently excludes** a disk whose bitmap is
  missing, while the `VirtualMachineBackupTracker` keeps advertising it; the two
  metadata layers disagree with QEMU, with no warning at any layer. → Draft A.
- D4 — The VMI's `status.changedBlockTracking.backupStatus` publishes a
  **checkpoint name that does not exist in libvirt**, and a volume set for a pass
  whose backing chain is broken. → Draft B (medium confidence; classification
  Bug-vs-Improvement is itself a triage question).

**Open questions (not defects on the current evidence):**

- Q1 — What role does the guest-freeze failure (`virError(Code=113)`, `/mnt/datadisk`
  Permission denied) play? It appears on a *successful* full backup's `Done` reason
  and on the failed pass's `backupStatus`, so it is neither necessary nor sufficient
  for the wedge. → Draft C.
- Q2 — Whether a later pass could ever complete with the datadisk omitted (the
  original silent-drop hypothesis) remains open: the tracker-reset leg of the
  matrix is **capacity-blocked** (~80 GiB needed, 40.25 GiB free) and was not run.
- Q3 — Whether the retained tracker entry is causal for the D1 wedge or only
  correlated: the follow-up proves the VM stays wedged *while* the entry is stale
  (F1 rejection names the wedged CR), but no pass was ever allowed to succeed with
  the entry present, so "repairing the tracker also unblocks the VM" is unverified.

---

## Draft A — [Bug] `VirtualMachineBackup` never reaches a terminal state when its checkpoint is inconsistent with the QEMU dirty bitmaps, and the one-backup-per-source rule then deadlocks the VM's backup capability

| Field | Value |
|---|---|
| Issue type | Bug |
| Owning component | CNV/KubeVirt backup stack: virt-controller backup controller (`pkg/storage/cbt/backup.go` — start/requeue/abort path, per the reference finding's source anchors) and virt-launcher checkpoint path (`pkg/virt-launcher/virtwrap/storage/backup.go` — `RedefineCheckpoint` / `findDisksWithCheckpointBitmap`); API surface `backup.kubevirt.io/v1alpha1` |
| Priority | Proposed **High** (availability: the VM's backup capability is dead until an operator deletes the wedged CR; no API-only, evidence-preserving recovery). Unassigned pending triage. |
| Status / confidence | **Confirmed behaviour, high confidence in the observation**: 3 independent reproductions of the wedge (2 runs, 3 passes), 1 of them on the corrupt-checkpoint path *after* the runbook step. One residual attribution caveat: in `20261016-exp06-r02` the pre-removal bitmap state was witnessed only by the injector (the run's own injection checker REJECTed on that gap), so "the removal caused this" rests on the product's own `virError(Code=109)` message naming the removed bitmap. |
| Related scenario / execution | `CBT-EXP-06` / `20261014-exp06-r01` (2026-10-14, leg B); `CBT-EXP-06` / `20261016-exp06-r02` (2026-10-16, closed `BLOCKED` — control leg + affected pass `…-p01`); `CBT-EXP-06` / `20261016-exp06-r02` **post-close same-VM follow-up** `20261016-exp06-r02-same-vm` (2026-10-16, F0–F3); `CBT-EXP-08` / `20261014-exp08-r01` (2026-10-14, Path B, cited via `docs/findings/finding-1-backup-cr-livelock.md`) |
| Affected versions | Observed on the `20261016-exp06-r02` cluster: OpenShift 4.22.15 (server `4.22.15`, Kubernetes `v1.35.6`; `oc` client 4.22.15); OpenShift Virtualization / kubevirt-hyperconverged-operator **v4.22.12** (KubeVirt operator image digest `sha256:2f654df4f4b026b85abc62bfe834a842b3a49b054f97a5999a85443320a29293`); nodes Red Hat Enterprise Linux CoreOS 9.8.20260915-0; guest RHEL 9 (`pc-q35-rhel9.8.0`); `virsh` 11.10.0 in the launcher `compute` container; storage HostPathProvisioner `cbt-demo-hpp` (pool `/var/hpvolumes/csi`, node `d38-h18-000-r660`); backup API `backup.kubevirt.io/v1alpha1`. Harness: `virt-cbt-lab` workflow, trigger sha256 `9291f017a605ad0cee49e754d4eebe0f38e9d89db0ae19ad3f489366dd241f92`. Full virt-controller/virt-launcher image digests: **not recorded** in the run artifacts. `20261014-exp06-r01` and `20261014-exp08-r01` were observed on OpenShift 4.22 (cluster 4.22.1531), same CNV 4.22.12. |

### Description (plain language)

A push-mode `VirtualMachineBackup` that hits a **permanent, non-retryable** start
failure (checkpoint inconsistent with the QEMU dirty bitmaps — one disk's bitmap is
gone) requeues forever: the CR never reaches `Done` **or** `Failed`, keeps its
`backup.kubevirt.io/vmbackup-protection` finalizer, and leaves its hotplugged
target PVC mounted to the VMI. The CR's only visible status is a **stale**
`Initializing=True` reason that still says the target PVC "is being attached",
stamped once at creation and never updated. Because of the one-backup-per-source
rule, the wedged CR then blocks **every** new backup on that VM at admission, so
the VM's entire backup capability is dead until an operator deletes the CR by hand.

The failure *is* detected (repeated `BackupError` warning events naming
`virError(Code=109) … checkpoint inconsistent: missing or broken bitmap … for disk
'vdb'`), but only on the **VMI** object — the backup CR's own event stream is
empty, so CR-scoped monitoring sees a healthy "in progress" backup indefinitely.

This is a proven defect against the established contract that a backup eventually
reaches a terminal condition (the same CR reaches `Done` on success and the API
exposes a `Done` condition type), and that a deletion removes the object (its
finalizer releases); it is not a request for clarification.

### Steps to reproduce

> Validated in-run (trigger `cbt-chaos/scenarios_v2/CBT-EXP-06/chaos-trigger.sh`,
> frozen sha256 `9291f017…`, and driver `same-vm-followup.sh`). Use a dedicated
> cluster, a fresh run-scoped VM and new object names; never reuse another run's
> names. Commands below are illustrative re-creations of the recorded shapes.

1. **Setup.** Create a 2-disk RHEL 9 VM (`rootdisk`=`vda`, `datadisk`=`vdb`) with
   CBT enabled, e.g. from `cbt-chaos/scenarios_v2/CBT-EXP-06/vm-2disk.yaml`. Take
   a **full** backup and confirm it terminates: `type=Full`, `Done=True`,
   `includedVolumes` contains both disks. Record the tracker's
   `status.latestCheckpoint.name` — that is the checkpoint whose bitmaps matter.
2. **Locate the target disk's QEMU node, fail-closed.** `exec` into the launcher's
   `compute` container and run `virsh qemu-monitor-command <domain>
   '{"execute":"query-named-block-nodes"}'`, selecting the node whose file is the
   datadisk (`…/cbt/datadisk.qcow2`, node name ending `-format`; `libvirt-2-format`
   in this run). Verify the checkpoint bitmap is present on **that node only**.
   Prerequisite: a **non-injector** witness must capture the pre-removal state
   (the r02 run's injection checker REJECTed because only the injector did — see
   `checkers/injection-validity.json`).
3. **Remove the bitmap from that disk only.** `{"execute":"block-dirty-bitmap-remove",
   "arguments":{"node":"<vdb format node>","name":"<checkpoint name>"}}`; expect
   `{"return":{}}`, then re-query and confirm the datadisk list is empty while the
   rootdisk node still holds the bitmap.
4. **Restart the VMI** (`oc delete vmi <vmi>`) to fire the checkpoint-redefinition
   path; wait for the replacement VMI to be `Running` with CBT `Enabled`.
5. **Request an incremental** backup against the same `VirtualMachineBackupTracker`
   (a new CR + a new target PVC), then watch it read-only:
   `oc get vmbackup <new-cr> -o yaml -w`; `oc get events -n <ns>`; and
   `oc get vmbackuptracker <tracker> -o jsonpath='{.status.latestCheckpoint}'`.
6. **Inspect the wedge** (see next section) and, separately, try to create one more
   backup on the same VM to observe the admission rejection.

### Actual result

Observed on `20261016-exp06-r02` (all times UTC, from the named artifacts):

- **Control full backup is healthy.** `vm-backup-20261016-exp06-r02`, uid
  `4adf728a-a38f-4a23-878d-e466965180e4`: created 04:27:24Z, `type=Full`,
  `Done=True` at **04:28:20Z**, `includedVolumes=[vda/rootdisk, vdb/datadisk]`
  (`trigger/legA-full-backup.yaml`). Its `Done` reason carries a *warning*
  (`virError(Code=113) … failed to open /mnt/datadisk: Permission denied`) — see
  Draft C.
- **Surgery is per-disk and verified.** datadisk node `libvirt-2-format` bitmap
  present at 04:28:21.582Z (`trigger/bitmaps-before.json`), removed at 04:28:21.690Z
  with reply `{"return":{}}` (`trigger/qmp-remove-result.txt`), empty after
  (`trigger/bitmaps-after.json`); the observer's own read at 04:28:54Z shows the
  datadisk node empty while the rootdisk node still lists the bitmap
  (`observer/effect/qmp-nodes-post.json`, `observer/effect/pre-bitmap-history.jsonl`).
- **Redefinition reports success and silently drops the disk.** VMI uid
  `968b6e7e-c021-46e4-a731-ca0dbec6121f` deleted 04:28:22Z; replacement
  `9651acfc-1e0d-4c4e-ad94-581e2c4cdf11` `Running`, CBT `Enabled`, old launcher pod
  replaced, by 04:28:49Z (`trigger/effect-check.json`). virt-controller logs
  "Checkpoint redefinition successful" at **04:28:45.625161Z**
  (`trigger/controller-redefinition-window.log:87`, `backuptracker.go:117`), yet the
  resulting libvirt checkpoint XML lists **only** `<disk name='vda' …/>`
  (`observer/effect/checkpoint-dumpxml-post.xml`, read 04:52:08Z). No exclusion
  warning anywhere in the captured window.
- **Metadata disagrees with QEMU.** Tracker `vm-tracker-20261016-exp06-r02`
  (uid `366be1f0-…`, `resourceVersion 27322960`) still advertises
  `latestCheckpoint.volumes=[{vda,rootdisk},{vdb,datadisk}]`
  (`trigger/tracker-after-restart.yaml`; identical in
  `followup/…/tracker-before.json` and `…/tracker-after.json` — unchanged across the
  whole follow-up).
- **The affected pass never terminates.** `vm-incremental-20261016-exp06-r02-p01`,
  uid `46b6f5e1-ced6-4094-8c96-e4d7690c3ea0`, created **04:29:26Z**:
  `Initializing=True`, `Progressing=False`, reason verbatim *"backup target PVC
  vm-incremental-pvc-20261016-exp06-r02-p01 is being attached to VMI
  vm-20261016-exp06-r02"*, `lastTransitionTime` 04:29:26Z and never re-stamped;
  **no** `type`, **no** `Done` condition, **no** `includedVolumes`, **no**
  `completionTimestamp`; finalizer `backup.kubevirt.io/vmbackup-protection` held;
  `resourceVersion 27323776` unchanged from 04:29:26Z through the last read
  (`trigger/legB-incremental-backup.yaml`, `observer/FINAL.json`,
  `recovery/recovery-report.json#steps[0]`).
- **Detection is loud but mis-scoped.** 21 `BackupError` warning rows on the
  **VMI** between 04:29:29Z and 04:57:02Z (`observer/watches/events.jsonl`; the
  single aggregated Event object `vm-20261016-exp06-r02.18dee82a1076f935` carried
  `count=41`, `firstTimestamp 04:29:29Z`, `lastTimestamp 05:46:12Z` by the
  follow-up's capture — `followup/…/f3-events-ns.json`), message verbatim
  *"Failed backing up VM: server error. command Backup failed: "virError(Code=109,
  Domain=10, Message='checkpoint inconsistent: missing or broken bitmap
  'vm-backup-20261016-exp06-r02-2026-10-16_04-27-24' for disk 'vdb'')""*. 40
  virt-controller lines carrying the same error between 04:29:29.103549Z and
  04:40:22.432162Z, plus 20 virt-handler lines
  (`observer/effect/virt-controller-window.log`, `…/virt-handler-window.log`).
  `involvedObject.kind = VirtualMachineInstance` for every one of them.
- **The CR's own event stream is empty.** `oc get events --field-selector
  involvedObject.name=<cr>` returns zero items
  (`followup/20261016-r02-same-vm/wedged-cr-events.json` → `items: []`;
  `followup/…/f3-events-cr.json` → `items: []`).
- **The target PVC leaks mounted.** The hotplug volume
  `vm-incremental-20261016-exp06-r02-p01-backup-target-pvc` was `MountedToPod` via
  attachment pod `hp-volume-gkq77` at 05:34Z — i.e. still mounted ~65 minutes after
  creation (`followup/…/hotplug-before.json`, `followup/…/followup.log` F0).
- **VM-wide capability deadlock (D2).** At 05:34Z, creating *any* new backup on the
  same VM is rejected at admission, verbatim: `The request is invalid:
  spec.source: VirtualMachineBackup "vm-incremental-20261016-exp06-r02-p01" in
  progress for source` (`followup/…/f1-apply.out`, apply exit 1; the test CR never
  existed).
- **Runbook step works, then the wedge recurs (D1, 3rd reproduction).** Deleting
  only the wedged CR (PVC kept) released the finalizer and the object disappeared in
  **3 s**; `vm-incremental-pvc-20261016-exp06-r02-p01` stayed `Bound` (30Gi,
  created 04:29:26Z) and the hotplug volume detached (empty list)
  (`followup/…/f2-delete-wedged.out`, `…/wedged-pvc-after.json`,
  `…/hotplug-after-unblock.json`). A NEW pass `vm-incremental-20261016-exp06-r02-p02`
  (uid `72272cb4-be66-4cdd-a880-85d3b850c134`, 30Gi PVC) created **05:35:13Z** wedged
  identically: still `Initializing=True`/`Progressing=False` with the same PVC-reason
  at the last read **05:55Z** (~20 min), no terminal condition, finalizer held,
  `resourceVersion 27397408` (`followup/…/f3-new-backup.json`, `…/f3-result.json`
  `f3_verdict=wedged`). Its own hotplug pod `hp-volume-ngsjk` was created and its
  volume `MountedToPod` at 05:35:13–16Z with **no** unmount event afterwards
  (`followup/…/f3-events-ns.json`); the follow-up reports it still attached at
  05:55Z (reported, `followup/…/FINDINGS.md`). The namespace `BackupError` event's
  `lastTimestamp` advanced to **05:46:12Z**, i.e. p02 re-fired the same
  `virError(Code=109)`.
- Harness-side bookkeeping (recorded, not a product claim): `make e2e
  TYPE=incremental` gave up at 04:49:27Z after 20m35s
  (`trigger/trigger.log`), and the *harness* marked the pass `failed`
  (`runs/20261016-exp06-r02/run.json#current_incremental_pass`), while the product
  object recorded no failure at all.
- Attribution: **inference** (from the product's own `Code=109` message plus the
  verified per-disk surgery) — that the removed datadisk bitmap is the trigger.
  Independent confirmation of the removal itself is absent in r02 (injector-only
  pre-state witness); the observation of the wedge itself is independent
  (observer streams, controller logs, live CR reads).

### Expected result / requested outcome

Established contract, to be met:

1. A backup start that fails with a **permanent** error must reach a **terminal**
   condition (`Failed` with a reason, or an explicit fallback to a full backup),
   release its `backup.kubevirt.io/vmbackup-protection` finalizer, and detach its
   hotplugged target PVC — within a bounded time or bounded retry count. It must
   not be left `Initializing` forever, and its status reason must not keep
   advertising a PVC attachment that already happened.
2. The status of a stalled pass must be **current**, i.e. not a creation-time stamp
   that contradicts the recorded failures.
3. A wedged pass must not disable backup creation for the whole VM: either the
   one-backup-per-source guard must be released when the in-progress pass is
   known-failed, or the guard must surface a distinguishable, actionable condition.
4. Backup-start failures must be observable on the **backup object's** event
   stream, not only on the VMI.

Acceptance check: with the repro above, the new incremental must reach a terminal
condition (or a clean full fallback) within the configured bound; its finalizer
must be released without manual deletion; its target PVC must detach; and a second
backup created on the same VM concurrently must not be rejected with "in progress
for source" while the first is terminal.

### Impact and workaround

- **Availability / blast radius:** one corrupt-checkpoint or wedged pass disables
  **all** backups on that VM (`spec.source … in progress for source`), including
  incrementals for other disks. Per-VM, not cluster-wide, but with no API-only,
  evidence-preserving recovery: the documented unblock deletes the failed pass's CR
  **and PVC**.
- **Data protection:** no silent data loss observed (QEMU refuses the inconsistent
  backup — positive backstop); the harm is loss of *coverage*: the VM is simply not
  backed up until an operator intervenes.
- **Observability:** CR-scoped monitoring (the natural surface for a backup CR)
  cannot see the failure at all; VMI-scoped `BackupError` warnings are the only
  signal, and the CR status actively says "in progress".
- **Frequency / reproducibility:** deterministic — 3/3 attempts on the
  corrupt-checkpoint path, plus 1/1 on the deleted-tracker path
  (`docs/findings/finding-1-backup-cr-livelock.md`).
- **Supported mitigation (operator runbook, all live-verified):** with the tracker
  present, delete the wedged CR (finalizer released in seconds, hotplug detached);
  the destination PVC stays `Bound` and must be reclaimed deliberately. To reset the
  chain instead, delete the tracker and take a new backup (fresh `type=Full`, chain
  silently discarded). When the tracker is *absent*, the abort itself wedges
  (Path B) — recreate the tracker first.
- **Remains unknown:** whether the stale tracker entry must be repaired for backup
  to work again on the same VM long-term (Q3), and whether the datadisk omission can
  ever reach a *completed* pass (Q2).

### Additional information and evidence

`20261016-exp06-r02` (closed run root
`cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02/`):

- `trigger/legA-full-backup.yaml` — control full `type=Full`, `Done=True` 04:28:20Z,
  both disks included, `Code=113` warning in the Done reason.
- `trigger/legB-incremental-backup.yaml`, `observer/FINAL.json#runtime_checks_at_final_utc.p01`,
  `observer/effect/preserved-summary.json` — p01 non-terminal, rv unchanged.
- `observer/watches/events.jsonl` (21 rows, VMI-scoped) and
  `observer/effect/virt-controller-window.log` / `virt-handler-window.log` — the
  `Code=109` retry storm.
- `observer/effect/checkpoint-dumpxml-post.xml` (only `vda`) vs
  `trigger/tracker-after-restart.yaml` and `observer/effect/post-tracker.json`
  (`rootdisk`+`datadisk`) — the metadata divergence.
- `trigger/controller-redefinition-window.log:79-87` — redefinition "successful"
  with no warning.
- `observer/effect/pre-bitmap-history.jsonl`, `…/qmp-bitmaps-post.json`,
  `…/qmp-nodes-post.json`, `…/qmp-nodes-post-late.json` — per-disk contrast; zero
  `target_present=true` rows (the independent-witness gap).
- `checkers/verdict.json` (`product_findings[0]`, `attribution_caveat`),
  `checkers/evidence-sufficiency.json` (C2 BLOCKED, C4 UNKNOWN),
  `checkers/injection-validity.json` (REJECT), `state.json` (closed),
  `evidence-index.json` (157 files).
- `recovery/recovery-report.json#steps[0]`, `#steps[2]`, `#terminal_status=BLOCKED`,
  `recovery/step3-extend.log` — the harness could not add a same-VM pass without
  destroying the evidence.
- `trigger/exit-statuses.json#surgery_incremental` — trigger's own
  `type=""`, `done=""`, `included_volumes=""`.

Post-close same-VM follow-up
(`cbt-chaos/scenarios_v2/CBT-EXP-06/followup/20261016-exp06-r02-same-vm/`):
`wedged-cr-before-delete.{json,yaml}`, `f0-retry.json` (46 controller bitmap-error
lines in the preceding 180 min), `hotplug-before.json`, `f1-apply.out`,
`f1-delete-cr.out`, `f2-delete-wedged.out`, `wedged-pvc-after.json`,
`hotplug-after-unblock.json`, `vmi-after-unblock.json`, `f3-apply.out`,
`f3-new-backup.{json,yaml}`, `f3-events-ns.json`, `f3-events-cr.json`,
`f3-result.json`, `tracker-{before,after}.json`, `vmi-before.json`, `followup.log`,
`controller-window.log`; earlier capture
`followup/20261016-r02-same-vm/{wedged-cr.json,wedge-cr-events.json,…}` (CR-scoped
events empty). Driver: `cbt-chaos/scenarios_v2/CBT-EXP-06/same-vm-followup.sh`.
Follow-up write-up: `followup/20261016-exp06-r02-same-vm/FINDINGS.md` (present in
the working tree; not part of the frozen r02 pack).

Prior runs: `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261014-exp06-r01/`
(`legB-incremental-backup.yaml`, `legB-controller-retry-loop.log`,
`bitmaps-*.json`, `tracker-after-restart.yaml`) and
`cbt-chaos/scenarios_v2/CBT-EXP-08/runs/20261014-exp08-r01/`
(Path B: `backup-deletion-stuck.yaml`, `controller-window.log`,
`recovery-backup.yaml`); reference finding `docs/findings/finding-1-backup-cr-livelock.md`.

Contradictory evidence / limits, recorded honestly: (a) r02's injection checker
REJECTed because the pre-removal bitmap state had no non-injector witness, so the
causal attribution is injector-attested; (b) the run's deterministic evaluator
returned `FAIL` on an `injection-signal` check whose table models a different
scenario family — a harness fact, not product evidence; (c) the wedged CR "looks"
healthy to a naive `status.conditions` reader, so any automated detector must treat
"non-terminal past bound" as failure rather than rely on `Failed`.

### Acceptance criteria

- With the repro, the affected backup reaches a terminal condition (`Failed` with a
  reason, or a documented full fallback) within the configured bound, and
  `type`/`Done`/`includedVolumes` are all set.
- The finalizer `backup.kubevirt.io/vmbackup-protection` is released and the
  hotplugged target PVC is detached **without** manual deletion.
- The backup CR's event stream carries the start-failure events (or an equivalent
  CR-level condition), so CR-scoped monitoring detects the wedge.
- Regression boundary: a *second* backup created on the same VM while the first is
  wedged is either accepted or rejected with a distinguishable, documented
  condition, and once the first is terminal the second succeeds (the
  one-backup-per-source guard does not outlive the in-progress pass).
- Regression check for the original failure mode: the checkpoint-redefinition path
  either excludes the disk **and warns** and repairs the tracker, or invalidates the
  checkpoint and falls back to a full backup — and the tracker never advertises a
  volume whose QEMU bitmap is absent.

### Triage questions

- Which is the intended terminal-resolution mechanism for a permanent backup-start
  failure — max-retry counter, deadline, or immediate classification of
  `isCheckpointInvalid`-style errors? (Affects the fix's shape.)
- Is the one-backup-per-source guard supposed to consult the wedged pass's
  terminal-ness, or is the intended recovery "operator deletes the CR"?
- Should the abort path work when the tracker is absent (Path B), or is tracker
  presence a documented prerequisite?

---

## Draft B — [Improvement] VMI `status.changedBlockTracking.backupStatus` advertises a checkpoint name (and a volume set) that libvirt does not have

| Field | Value |
|---|---|
| Issue type | Improvement (contract clarification + guardrail). **If** the established contract is that `backupStatus.checkpointName` must name an existing libvirt checkpoint, this becomes a Bug — see triage questions. |
| Owning component | CNV/KubeVirt backup stack: the VMI CBT status publisher (virt-handler/virt-launcher `changedBlockTracking` status path); API surface `kubevirt.io/v1` `VirtualMachineInstance.status.changedBlockTracking` |
| Priority | Proposed **Medium** (observability/misleading progress surface; no data loss on its own). Unassigned pending triage. |
| Status / confidence | **Observed behaviour, medium confidence about its product-level significance.** The artifact facts are unambiguous; whether the field is *intended* to be a request projection (name written before the backend object exists) or a statement of an existing checkpoint is a contract question this run cannot settle (the run's own evidence checker flagged it as a false-positive trap for exactly this reason). |
| Related scenario / execution | `CBT-EXP-06` / `20261016-exp06-r02` (2026-10-16, closed `BLOCKED`); `CBT-EXP-06` / `20261016-exp06-r02` post-close same-VM follow-up `20261016-exp06-r02-same-vm` (2026-10-16, F0 snapshot read 05:34Z) |
| Affected versions | Same cluster/version set as Draft A (OpenShift 4.22.15 / Kubernetes v1.35.6; CNV kubevirt-hyperconverged-operator v4.22.12; guest RHEL 9; `backup.kubevirt.io/v1alpha1`). Not recorded: the exact virt-handler image digest. |

### Description (plain language)

For the failed pass `vm-incremental-20261016-exp06-r02-p01`, the VMI reports
`status.changedBlockTracking.backupStatus.checkpointName =
vm-incremental-20261016-exp06-r02-p01-2026-10-16_04-29-26` and lists **both**
volumes (`vda/rootdisk`, `vdb/datadisk`) — but a libvirt `checkpoint-dumpxml` for
that exact name returns *"Domain checkpoint not found"*. The only checkpoint that
exists in libvirt is the full backup's redefined checkpoint, and it declares **only
`vda`**. So the status surface an operator/monitor would read to learn "what
checkpoint is this VM tracking" names an object that does not exist, with a volume
set that contradicts both libvirt and the dirty-bitmap reality.

Because this is a *status* field, the harm is misleading operators/monitoring (and
any tooling that keys "chain is healthy" off the checkpoint name) rather than data
loss. Whether that is a defect or an under-specified contract is what triage must
decide; this is filed as an Improvement with a Bug-lean.

### Steps to reproduce

1. Reproduce the Draft A wedge (steps 1–5) so a pass is created whose checkpoint
   write never succeeded.
2. Read the VMI status:
   `oc get vmi <vmi> -n <ns> -o jsonpath='{.status.changedBlockTracking.backupStatus}'`.
3. Read the same name from libvirt inside the launcher's `compute` container:
   `virsh checkpoint-dumpxml <domain> <checkpointName>` (expect "Domain checkpoint
   not found"), then `virsh checkpoint-list --tree <domain>` and
   `virsh checkpoint-dumpxml <domain> <existing-checkpoint-name>` to see which disks
   the existing checkpoint really covers.
4. Cross-check the QEMU dirty bitmaps for the VM's disks
   (`query-named-block-nodes`) to confirm the discrepancy is real and not a stale
   status read.

### Actual result

Observed (`20261016-exp06-r02`):

- `observer/effect/post-vmi-cbt.json`, captured **04:54:41Z** (VMI uid
  `9651acfc-1e0d-4c4e-ad94-581e2c4cdf11`): `state=Enabled`,
  `backupStatus.backupName=vm-incremental-20261016-exp06-r02-p01`,
  `backupStatus.checkpointName=vm-incremental-20261016-exp06-r02-p01-2026-10-16_04-29-26`,
  `backupStatus.startTimestamp=2026-10-16T04:29:26Z`,
  `backupStatus.volumes=[{vda,rootdisk},{vdb,datadisk}]`,
  `backupStatus.backupMsg="Failed freezing guest filesystem: virError(Code=113 …)"`.
- `observer/effect/checkpoint-dumpxml-p01.txt` (read 04:54Z):
  `error: Domain checkpoint not found: no domain checkpoint with matching name
  'vm-incremental-20261016-exp06-r02-p01-2026-10-16_04-29-26'`.
- The checkpoint that does exist, `observer/effect/checkpoint-dumpxml-post.xml`
  (read 04:52:08Z), declares only `<disk name='vda' checkpoint='bitmap' …/>`.
- The status value is **stable**, not a transient read: the same `checkpointName`
  and `volumes` are present in the follow-up's VMI snapshot at 05:34Z
  (`followup/20261016-exp06-r02-same-vm/vmi-before.json`, VMI rv `27323878`), i.e.
  ~65 minutes after the pass was created and after the pass was already known-failed
  to the harness.
- The tracker simultaneously advertised `volumes=[rootdisk,datadisk]` with the *full
  backup's* checkpoint name (`observer/effect/post-tracker.json`,
  `followup/…/tracker-before.json`) — so three surfaces disagree: VMI status names a
  nonexistent checkpoint; the tracker names an existing checkpoint but a too-wide
  volume set; libvirt's checkpoint covers only `vda`.
- Independent vs inferred: the artifact facts above are independent observations
  (observer-captured, plus a live follow-up read). The *significance* claim (that
  consumers would be misled) is **inference**.

### Expected result / requested outcome

A clarified, enforced contract for `VirtualMachineBackupTracker`/VMI backup status:

- Either `backupStatus.checkpointName` must be published only once the checkpoint
  actually exists in libvirt (and `volumes` must reflect the checkpoint's real disk
  set), or the field must be explicitly documented as a *requested* name (e.g. with a
  co-located state that says the checkpoint does not yet exist / the pass never
  started).
- A failed pass must not leave a status surface that reads like an active,
  both-disks checkpoint.

Acceptance check: in the repro state, either the status names an existing
checkpoint, or it carries an explicit marker that the checkpoint is absent; a
`virsh checkpoint-dumpxml` of every name the API publishes succeeds.

### Impact and workaround

- Misleading progress surface for operators and for CR/VMI-based monitoring; a
  naive "chain covers vdb" conclusion would be wrong in this state.
- Workaround: verify chain coverage against libvirt (`checkpoint-dumpxml` /
  `checkpoint-list`) and QEMU dirty-bitmap state, never against the VMI status
  alone.
- Blast radius: this VM only (status is per-VMI). Frequency: deterministic in the
  wedge state; unknown outside it (not attempted).
- Unknown: whether the same field can name a nonexistent checkpoint on other
  failure paths, and whether any consumer (OCP UI, monitoring) keys off it.

### Additional information and evidence

- `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02/observer/effect/post-vmi-cbt.json`
- `…/observer/effect/checkpoint-dumpxml-p01.txt`, `…/checkpoint-dumpxml-post.xml`,
  `…/checkpoint-list-post.txt`
- `…/observer/effect/post-tracker.json`, `…/trigger/tracker-after-restart.yaml`
- `…/checkers/evidence-sufficiency.json#false_positive_risks/3` (the checker's
  warning that VMI status is a request projection, not chain proof)
- `cbt-chaos/scenarios_v2/CBT-EXP-06/followup/20261016-exp06-r02-same-vm/vmi-before.json`
- Related: Draft A (this status is what makes the wedge look healthy to a VMI-level
  reader).

### Acceptance criteria

- In the wedge state, every checkpoint name published by the product API
  (`VMI.status.changedBlockTracking.backupStatus.checkpointName`, tracker
  `status.latestCheckpoint.name`) resolves in libvirt, or the API states explicitly
  that the checkpoint is absent.
- The published `volumes` set matches the libvirt checkpoint's disk set.
- Regression: after a successful incremental, the published checkpoint name and
  volumes match `virsh checkpoint-dumpxml` output.

### Triage questions

- Is `backupStatus.checkpointName` specified as "requested" or "existing"? If
  "existing", this is a Bug, not an Improvement.
- Should a failed pass clear/reset its `backupStatus` entry on the VMI?
- Does any shipped consumer (UI, alerts) depend on this field for chain health?

---

## Draft C — [Improvement] Guest-freeze failure on `/mnt/datadisk` (`virError(Code=113)`, Permission denied): product defect or guest misconfiguration?

| Field | Value |
|---|---|
| Issue type | Improvement — **investigation / contract question**, deliberately not filed as a defect (per the closed run's own product-findings note). |
| Owning component | Unresolved between (a) the CNV guest-agent / `guest-fsfreeze-freeze` path and its failure reporting (product) and (b) the harness-authored guest configuration that mounts `/mnt/datadisk` (test asset, `vm-2disk.yaml` cloud-init). |
| Priority | Proposed **Low/Medium** for triage — it does not block a full backup, and it is *not* necessary or sufficient for the Draft A wedge; but it contaminates the control baseline. Unassigned pending triage. |
| Status / confidence | **Observation confirmed, causality unresolved.** The same warning appears on a *successful* full backup and on the *failed* pass, so it cannot be the wedge's cause on its own; whether it is an independent product issue is open. |
| Related scenario / execution | `CBT-EXP-06` / `20261016-exp06-r02` (2026-10-16, closed `BLOCKED` — control leg and affected pass p01); `CBT-EXP-06` / `20261016-exp06-r02` post-close same-VM follow-up `20261016-exp06-r02-same-vm` (2026-10-16) |
| Affected versions | Same cluster/version set as Draft A (OpenShift 4.22.15; CNV v4.22.12; guest RHEL 9). Guest `qemu-guest-agent` version: **not recorded**. |

### Description (plain language)

Both the **successful** control full backup and the **failed** incremental report
the same guest-side problem: `guest-fsfreeze-freeze` could not freeze the datadisk
mount — `virError(Code=113, Domain=10, Message='guest agent command failed: unable
to execute QEMU agent command 'guest-fsfreeze-freeze': failed to open
/mnt/datadisk: Permission denied')`. On the full backup it is attached as a
*warning* to an otherwise successful `Done=True`; on the failed pass it is the
value of `backupStatus.backupMsg`. Because it appears in both outcomes, it is
neither necessary nor sufficient for the Draft A wedge — but it does mean the
control leg was **not** a cleanly frozen snapshot, and it leaves a real question:
is the product mis-reporting/mis-handling a guest-agent freeze failure, or is
`/mnt/datadisk` merely mis-mounted/mis-permissioned in the test VM?

This draft exists so the question is tracked rather than lost, and so nobody later
presents it as a product defect or as the wedge's cause.

### Steps to reproduce

1. Build the 2-disk test VM from `cbt-chaos/scenarios_v2/CBT-EXP-06/vm-2disk.yaml`
   (RHEL 9 guest; datadisk attached and mounted at `/mnt/datadisk` by cloud-init).
2. Confirm CBT is `Enabled`, then take a full backup and read its `Done` condition
   reason: `oc get vmbackup <full-cr> -o
   jsonpath='{.status.conditions[?(@.type=="Done")].reason}'`.
3. Inside the guest, check the mount's ownership/permissions and whether the guest
   agent can open it: e.g. `stat -c '%U %G %a %n' /mnt/datadisk`, `ls -ld
   /mnt/datadisk`, and a manual `virsh domfsfreeze`-equivalent from the launcher /
   a `guest-fsfreeze-freeze` attempt; capture `journalctl -u qemu-guest-agent` in
   the guest.
4. Compare with the same VM built **without** the datadisk mount, to separate
   "freeze of a second filesystem" from "this specific mount's permissions".

### Actual result

Observed (`20261016-exp06-r02`):

- Control full `vm-backup-20261016-exp06-r02` (`trigger/legA-full-backup.yaml`),
  `Done=True` at **04:28:20Z**, both disks in `includedVolumes`, with the `Done`
  condition reason (and the paired `Progressing=False` reason) verbatim:
  *"Completed VirtualMachineBackup, warning: Failed freezing guest filesystem:
  virError(Code=113, Domain=10, Message='guest agent command failed: unable to
  execute QEMU agent command 'guest-fsfreeze-freeze': failed to open
  /mnt/datadisk: Permission denied')"*. So the freeze failure did **not** block a
  full backup.
- The failed pass reports the same message as its **only** `backupMsg`:
  `observer/effect/post-vmi-cbt.json` (04:54:41Z) and, unchanged, in the follow-up's
  VMI snapshot `followup/20261016-exp06-r02-same-vm/vmi-before.json` (05:34Z).
- The pass's actual detected failure is the *other*, per-disk error
  (`virError(Code=109) … missing or broken bitmap … for disk 'vdb'`, 21
  `BackupError` events 04:29:29Z–04:57:02Z) — so two different guest/backend errors
  coexist and were deliberately not merged by the run's checkers
  (`checkers/verdict.json#product_findings[2]`, `observer/FINAL.json`
  contradictions X1).
- Independent vs inferred: the message texts and their appearances are independent
  observations. The claim "its causal contribution is unresolved" is the honest
  summary; **inference** that the guest mount permissions are the proximate cause
  comes from the message's own `/mnt/datadisk: Permission denied` text only — no
  guest-side inspection was captured.

### Expected result / requested outcome

A settled answer to the investigation question, recorded as a test-harness or
product fact:

- If a guest-agent freeze failure is benign for a full backup, the product contract
  should say so (and the reason should be classified as a warning, which it
  currently is) — and the harness should either fix the `/mnt/datadisk` mount so the
  control leg is a cleanly frozen baseline, or record the caveat (the run's report
  does record it).
- If a datadisk freeze failure should prevent a backup from claiming success for
  that disk, then the current "warning attached to Done=True" is a product defect
  and must become a `Bug` with the affected disk excluded from `includedVolumes` —
  but that is exactly the behaviour this run did **not** observe (both disks were
  reported as included), so this draft stays an open question until someone decides
  which contract holds.

Acceptance check: a documented decision (product contract or guest-config fix),
validated by a re-run whose control full shows either no `Code=113` warning or an
explicit product-side explanation for it.

### Impact and workaround

- Contaminates the control baseline: the "both disks backed up" claim rests on
  `includedVolumes`, while the snapshot was demonstrably not cleanly frozen for
  `vdb`, so a restore-content grading of `vdb` could not be trusted even if it had
  run (it did not).
- Consumer risk: an operator seeing the warning on a `Done=True` backup cannot tell
  whether `vdb` content is protection-grade.
- Workaround: none needed operationally; fix the guest mount permissions or the
  guest-agent invocation before using this VM layout for content grading.
- Blast radius: this test VM layout; the question of general guest-freeze reporting
  would apply to any multi-filesystem guest.
- Frequency: deterministic in this run (present on both legs).

### Additional information and evidence

- `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02/trigger/legA-full-backup.yaml`
  (`Done` reason verbatim) and `…/observer/watches/vmbackup.jsonl.ts` (04:28:20Z).
- `…/observer/effect/post-vmi-cbt.json` (04:54:41Z, `backupMsg`).
- `cbt-chaos/scenarios_v2/CBT-EXP-06/followup/20261016-exp06-r02-same-vm/vmi-before.json`
  (05:34Z, same `backupMsg`).
- `…/checkers/verdict.json#product_findings[2]`, `…/observer/FINAL.json`
  (contradiction X1), `…/reports/test-run-result.md` (limitation recorded).
- VM manifest that creates the mount:
  `cbt-chaos/scenarios_v2/CBT-EXP-06/vm-2disk.yaml` (cloud-init).
- Not captured: guest `journalctl -u qemu-guest-agent`, `stat` of `/mnt/datadisk`,
  guest-agent version. This is the main gap the investigation must close.

### Acceptance criteria

- A recorded decision (product contract vs guest-config defect) with the artifact
  that supports it.
- Re-run of the control leg shows either a clean freeze or an explicit, documented
  product-side treatment of the freeze failure.
- If the decision is "guest config", `vm-2disk.yaml` is fixed and the control leg no
  longer carries a `Code=113` warning in its `Done` reason.

### Triage questions

- Is a `Code=113` freeze failure on a second filesystem expected to produce a
  warning-only `Done=True` for a full backup, or should the affected disk be
  reported as not-backed-up?
- Who owns `/mnt/datadisk`'s permissions in the test VM — harness cloud-init or
  the product's disk attachment path?
- Does any product behaviour change when the fuse/freeze failure is absent (i.e. is
  the wedge independent of it)? Final-pass evidence would come from a re-run with
  the mount fixed.

---

## Explicit negative result — the hypothesised silent *completed* drop was NOT observed

This must be stated in the tickets so the claim is not made by accident:

- The original CBT-EXP-06 hypothesis was that a disk whose checkpoint bitmap is
  removed would be **silently excluded** and all later incrementals would complete
  `Done=True` **without** that disk (`scenario-spec.md#2`, `#5` DEFECT branch:
  "Done=True Incremental with datadisk missing from includedVolumes and no
  warning").
- In **three** attempts on the corrupt-checkpoint path — `20261014-exp06-r01` leg B,
  `20261016-exp06-r02` `…-p01`, and `20261016-exp06-r02` follow-up `…-p02` — **no
  pass ever completed**: every affected pass had no `type`, no `Done`, no
  `includedVolumes`, and the missing bitmap was *loudly* refused by QEMU
  (`virError(Code=109)`), not silently dropped.
- Therefore **do not** file "silent completed data-protection loss" as a
  confirmed defect. What *is* observed as "silent" is the **metadata** layer:
  the redefinition removes `vdb` from the checkpoint with no warning while the
  tracker keeps advertising it (D3, Draft A) — a silent *metadata* drop, not a
  silent completed-backup drop.
- The residual open question (Q2) is whether a completed pass with `vdb` missing can
  be produced via the **tracker-reset** path (delete the tracker, then take a new
  backup → full fallback, chain discarded). That leg is **capacity-blocked**:
  it needs a fresh full-backup PVC (~80 GiB) while the pool holding every PVC
  (`/dev/sdb` at `/var/hpvolumes/csi`) has only **40.25 GiB** free
  (`followup/…/f3-result.json#pool_free_before_bytes = 43215937536`,
  `recovery/recovery-report.json#pool_free_bytes`). It was deliberately not run; it
  is the one remaining experiment that could revive or finally close the original
  hypothesis.

---

## How to verify this document

1. Read `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02/state.json`
   (closed) and `checkers/verdict.json` (`BLOCKED`) — the run is frozen.
2. Reproduce the wedge observations from the closed pack: `trigger/legB-incremental-backup.yaml`,
   `observer/watches/events.jsonl`, `observer/effect/virt-controller-window.log`,
   `observer/effect/checkpoint-dumpxml-post.xml`, `trigger/tracker-after-restart.yaml`.
3. Reproduce the follow-up observations:
   `followup/20261016-exp06-r02-same-vm/{followup.log,f1-apply.out,f2-delete-wedged.out,f3-new-backup.json,f3-events-ns.json,f3-events-cr.json,tracker-before.json,tracker-after.json,hotplug-before.json,hotplug-after-unblock.json,wedged-pvc-after.json}`.
4. Live state deliberately left in place (read-only verification): VM/VMI healthy
   (`Running`, CBT `Enabled`), `vm-incremental-20261016-exp06-r02-p02` wedged,
   `vm-incremental-pvc-20261016-exp06-r02-p01` `Bound`, tracker still holding the
   stale checkpoint, pool free 40.25 GiB.

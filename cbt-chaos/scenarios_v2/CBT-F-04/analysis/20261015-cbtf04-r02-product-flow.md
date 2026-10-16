# CBT product-flow analysis — CBT-F-04 — run 20261015-cbtf04-r02

> **Ticket drafts moved.** The engineering-ticket draft that lived in §3 of this file now lives at
> `bugs/hotplugfailed-lstat-on-successful-detach.md` (same title, issue type, claims, quotes and UTCs; re-rendered onto `template/engineering-jira-issue-template.md`), and the repetition recorded in the r03 analysis §5 is carried there too. Everything else in this analysis is unchanged.

> Scope: product-flow behavior of the CBT backup/checkpoint/tracker/recovery
> machinery under the controller-kill disruption, from the closed run's
> evidence pack only. Harness findings (trigger env-leak abort, run.json
> repair) are routed to the Scenario Improver's lane and excluded here except
> where they bound evidence confidence. All times UTC, 2026-10-15.

## 1. Observed CBT-flow behavior vs the intended contract

Sources verified: `observer/finding.md`, `observer/watches/*.jsonl` (tracker,
events, pods, lease, vmbackup, pvc), `observer/evidence-terminal/*`,
`recovery/{summary.json,done.json,checkpoint-tree.txt}`, `reports/*`,
`scenario-spec.md` §5.

| # | Contract behavior (spec §5 / jira) | Observed behavior | Evidence | Verdict |
|---|-------------------------------------|--------------------|----------|---------|
| 1 | Data copy survives controller kill (data plane in launcher, control plane in controller) | Launcher `virt-launcher-vm-20261015-cbtf04-r02-jl5lt` never restarted (single pod, 0 restarts, never Failed); copy began 06:48:50.467875Z, controller leader `virt-controller-6f7bc6b44c-5h4hs` deleted 06:49:07.697Z, backup settled Done 17 s later | launcher-backup-lines.log; observer finding timeline; pods watch | HELD |
| 2 | Failover + reconciliation complete | Lease holder `5h4hs` → `kgtth` at 06:49:24Z; replacement `mrspr` Ready; 2/2 replicas Ready at final snapshot 07:20:28Z | watches/lease.jsonl; ctrl-pods-final.json | HELD |
| 3 | Full backup terminal state correct: Done=True, non-failure reason, type Full, non-empty checkpoint, expected volumes, no duplicate | `Done=True`, reason `Successfully completed VirtualMachineBackup`, type Full, checkpoint `vm-backup-20261015-cbtf04-r02-2026-10-15_06-48-48`, volume `rootdisk`/`vda`; exactly one run-named vmbackup object | vmbackup-final.json (uid `eb1e4bb2-…`); vmbackup watch | HELD |
| 4 | Tracker advances exactly once per backup | Tracker watch stream has exactly 3 records: empty → full checkpoint → incremental child `vm-incremental-20261015-cbtf04-r02-p01-2026-10-15_07-12-14`; `latestCheckpoint.name` equals the child at final state | watches/tracker-20261015-cbtf04-r02.jsonl; tracker-post-incremental.json | HELD |
| 5 | No false Incremental / chain stays rebaseable | Incremental was a true child of the full checkpoint; libvirt checkpoint tree (full → child) matches the CR chain; cumulative restore through the child succeeded | recovery/checkpoint-tree.txt; recovery/summary.json | HELD |
| 6 | Temp attachment cleanup; destination PVC stays run PVC and Bound | Attachment pods `hp-volume-bn45q` (full) / `hp-volume-fc4cn` (incremental) deleted; volume unmounted; `vm-backup-pvc-20261015-cbtf04-r02` (80 GiB) and `vm-incremental-pvc-…-p01` (30 GiB) both Bound at final | events watch (`SuccessfulDelete`, `VolumeUnMountedFromPod`); pvc-list-run.txt | HELD, with anomaly (see §2) |
| 7 | VM/VMI Running, CBT Enabled throughout | VM Ready, VMI Running on `d39-h05-000-r660`, `changedBlockTracking.state=Enabled` at all observation points | vm/vmi final + post-incremental snapshots | HELD |
| 8 | Restore data-correctness (not just Done=True) | Full-only: 1,000 files / 18,277,728,256 B / manifest SHA-256 match; cumulative incremental: 2,000 files / 36,561,747,968 B / match; 0 failed restore checks, 0 hash mismatches | recovery/summary.json; recovery/done.json | HELD (guest-level; see limits below) |
| 9 | Detach path emits no failure signal on a successful backup | **2× `HotplugFailed` events during post-backup detach in BOTH passes** (06:49:55Z full, 07:12:34Z incremental) | events watch; observer finding contradiction #2 | **VIOLATED-AS-OBSERVED (unresolved)** — §2 |

Evidence-confidence limits (stated, not blocking): no `qemu-img info`/`map`
capture anywhere in the run, so physical qcow2 allocation claims are
unverified and data correctness rests on guest-level file/byte/manifest-hash
checks; restore verification and the checkpoint tree are RecoveryWorker
evidence, not observer-witnessed; `recovery/summary.json` records the full
backup's status as PENDING (artifact of run.json repair after the trigger
abort) while the live object was Done=True — a harness artifact, not a
product contradiction.

## 2. HotplugFailed during post-backup volume detach — analysis

### Event sequence (from `observer/watches/events-20261015-cbtf04-r02.jsonl`)

Full pass, all events timestamped 06:49:55Z (second granularity; stream order
within the second as recorded):

1. `VirtualMachineBackupCompletedSuccessfully` on `vm-backup-20261015-cbtf04-r02` (backup already terminal-successful).
2. `Killing` on pod `hp-volume-bn45q` — "Stopping container hotplug-disk" (attachment pod teardown begins).
3. `HotplugFailed` on VMI `vm-20261015-cbtf04-r02`, source `virt-handler` on node `d39-h05-000-r660`, ADDED count=1: "failed to mount filesystem hotplug volume vm-backup-20261015-cbtf04-r02-backup-target-pvc: lstat /proc/1/root/var/lib/kubelet/plugins/kubernetes.io/csi/openshift-storage.rbd.csi.ceph.com/f1994c9a…/globalmount/0001-0011-…-41afed24…/disk.img: no such file or directory".
4. Same event MODIFIED to count=2 within the same second.
5. `SuccessfulDelete` (VMI) — attachment pod deleted; `SuccessfulDelete` — hotplug volume deleted.
6. `VolumeUnMountedFromPod` — backup-target volume unmounted from the launcher.

Incremental pass, 07:12:34Z: byte-for-byte the same pattern against
`hp-volume-fc4cn` / `vm-incremental-…-p01-backup-target-pvc` (CSI handle
`a9658af1…`, volume-id `967e60aa…`), including the identical count 1→2
doubling.

### What succeeded despite the events

Both passes nonetheless ended fully correct: `Done=True` with reason
`Successfully completed VirtualMachineBackup`; attachment pods deleted;
hotplug volumes deleted and unmounted; destination PVCs Bound; tracker
advanced exactly once per pass; checkpoint chain full → child verified in
libvirt; both restore points hash-verified with zero failures. The anomaly is
therefore not a functional failure of backup, cleanup, chain, or restore — it
is a failure-signature event emitted on an otherwise fully successful path.

### Key observations sharpening the question

- The identical pattern fired in the **incremental pass, which ran under no
  chaos** (23 min after the controller kill, on a settled cluster). The
  anomaly is therefore **not attributable to the controller disruption** —
  it is ordinary detach-path behavior in this setup (OpenShift
  Virtualization 4.22.12, ODF/Ceph RBD CSI, filesystem-mode hotplug).
- The event message says "failed to **mount** filesystem hotplug volume" while
  the lifecycle phase is **unmount/detach** (the attachment pod's container is
  stopping). A mount attempt (or mount-path validation) against a CSI
  globalmount path that is already being torn down (`disk.img` gone) suggests
  a stale reconcile or a teardown-path check that re-reads the source path —
  but the mechanism is unestablished (hypotheses in §4).
- The event doubled (count 1→2) within one second, consistent with a retry
  loop that then gave up silently because the volume was already removed.

### Remaining question

Is the `HotplugFailed`/`lstat disk.img` event on successful backup detach
(a) benign event noise from a racy-but-harmless validation/retry path, or
(b) a real cleanup race in the hotplug detach logic that happens to be masked
by the volume's eventual deletion? Either way it degrades failure semantics:
consumers alerting on `HotplugFailed` (a reasonable reading of the reason
code) will fire on every successful backup of this shape — a "loud failure
event on a correct path" monitoring hazard, even if functionally benign.

## 3. Engineering-ticket draft (single reproduction — do not file as confirmed defect)

Per the reproduction rule, this observation comes from ONE run label
(20261015-cbtf04-r02). Although the pattern occurred twice within the run
(full and incremental passes), those are two passes of a single run on a
single cluster/version, not independent reproductions. It stays in the run
report and this analysis until a second run reproduces it or a stronger
contract basis is established. No entry is written to `bugs/` yet; the draft
below is ready to move there on second reproduction.

---

# [Improvement]: `HotplugFailed` event with `lstat disk.img` message fires on the detach path of every successful backup-target hotplug volume

> Single-reproduction observation (run 20261015-cbtf04-r02 only). Not yet a
> confirmed defect: cleanup and data outcomes were fully correct in both
> observed passes.

| Field | Value |
|---|---|
| Issue type | Improvement (candidate Bug pending second reproduction) |
| Owning component | KubeVirt/OpenShift Virtualization hotplug detach path (`virt-handler` on the VM's node; backup-target volume attachment lifecycle) |
| Priority | Unassigned pending triage (proposed low functional / medium observability: false failure-signal on every successful backup detach) |
| Status / confidence | Confirmed observed behavior in one run (both the chaos full pass and a no-chaos incremental pass); mechanism unknown; not reproducible-attributable to the controller disruption |
| Related scenario / execution | CBT-F-04, run label `20261015-cbtf04-r02`, 2026-10-15 (UTC). Single run — reproduction rule applies: a second reproducing run label must be added before Bug classification |
| Affected versions | OpenShift Virtualization 4.22.12 (virt-controller pod label `app.kubernetes.io/version=4.22.12`); storage ODF / Ceph RBD (`ocs-storagecluster-ceph-rbd`, CSI driver `openshift-storage.rbd.csi.ceph.com`); OpenShift cluster version not recorded; guest RHEL 9 |

## Description (plain language)

When a CBT backup finishes and the controller detaches the temporary
backup-target hotplug volume, `virt-handler` on the VM's node emits a
`HotplugFailed` event on the VMI, message "failed to mount filesystem hotplug
volume <backup-target-pvc>: lstat /proc/1/root/…/openshift-storage.rbd.csi.ceph.com/<handle>/globalmount/<volume-id>/disk.img: no such file or directory", even though the backup completed successfully and cleanup fully
succeeds (attachment pod deleted, volume unmounted, PVC Bound). The message
describes a mount failure while the lifecycle phase is unmount/detach. Users
alerting on `HotplugFailed` will get a failure page on every successful
backup of this shape. This is a request to investigate/clarify the detach
path's event semantics; it is not a demonstrated functional defect.

## Steps to reproduce

> Illustrative (from one observed run; not independently re-validated).
> Dedicated cluster, new run-scoped names.

1. Create a VM with changed-block-tracking enabled and a deterministic guest
   workload; create a destination PVC for the backup on the ODF/Ceph RBD
   storage class.
2. Run one full backup, wait for terminal `Done=True`, and watch namespace
   events during the post-backup detach of the backup-target hotplug volume.
3. Read-only inspection: `oc get events -n <namespace> --sort-by=.lastTimestamp`
   and inspect `HotplugFailed` events on the run VMI; check the backup's
   conditions/reason, the attachment (`hp-volume-*`) pod's deletion, and the
   destination PVC phase. The pattern was also observed on an incremental
   backup pass with no chaos active, so the disruption is not a prerequisite.

## Actual result

Run `20261015-cbtf04-r02`, namespace `vm-cbt-demo`, VMI
`vm-20261015-cbtf04-r02` (uid `9f3d823f-c3e2-4071-b1cd-0e438d0b9377`), node
`d39-h05-000-r660`. At 06:49:55Z (full pass, backup
`vm-backup-20261015-cbtf04-r02`, uid `eb1e4bb2-cef5-4de6-b404-d0c5eb85ec69`,
already `Done=True` / "Successfully completed VirtualMachineBackup"): during
teardown of attachment pod `hp-volume-bn45q`, two `HotplugFailed` events
(count 1→2 within the same second) from `virt-handler`, message "failed to
mount filesystem hotplug volume vm-backup-20261015-cbtf04-r02-backup-target-pvc: lstat /proc/1/root/var/lib/kubelet/plugins/kubernetes.io/csi/openshift-storage.rbd.csi.ceph.com/f1994c9a1b94f05f4c4c01cd72cd407e2f76b4f140c87b996332b5c350250d8b/globalmount/0001-0011-openshift-storage-0000000000000002-41afed24-710d-4595-9919-55b426311dc4/disk.img: no such file or directory". Identical pattern at 07:12:34Z on the
no-chaos incremental pass (`hp-volume-fc4cn`,
`vm-incremental-20261015-cbtf04-r02-p01-backup-target-pvc`, CSI handle
`a9658af1b692c6eafd6379b72085a0dfbd1326c746a4e051f4e4263cab760b0a`, volume-id
`…-967e60aa-a654-4dab-b8c0-29a7848fa9ea`). In both passes the events were
followed within the same second by `SuccessfulDelete` (attachment pod and
hotplug volume) and `VolumeUnMountedFromPod`; destination PVCs stayed Bound.
Independently observed by a read-only event watch stream, separate from the
disruption tooling.

## Expected result / requested outcome

A successful backup whose hotplug detach completes cleanly should not emit a
failure-reasoned event on the VMI, or the event semantics should be clarified
(what `HotplugFailed` with a mount message during detach obligates consumers
to do). Acceptance: after the fix/clarification, the detach of a
successfully-completed backup's target volume emits no `HotplugFailed` event
(or a documented, distinguishable informational signal), with cleanup still
completing (attachment pod gone, volume unmounted, PVC Bound).

## Impact and workaround

No data-loss, cleanup, or restore impact observed: both passes completed
Done=True with success reasons, cleanup finished, tracker advanced exactly
once per backup, and both restore points hash-verified. Main risk is
observability: false failure signals on every successful backup detach can
mask real hotplug failures and page operators unnecessarily. No customer
mitigation identified from this run; backups, cleanup, and restores were
correct despite the events.

## Additional information and evidence

- Event records: `runs/20261015-cbtf04-r02/observer/watches/events-20261015-cbtf04-r02.jsonl` (`HotplugFailed` ADDED/MODIFIED at 06:49:55Z and 07:12:34Z, source `virt-handler`/`d39-h05-000-r660`).
- Observer finding: `runs/20261015-cbtf04-r02/observer/finding.md` (contradiction #2, criterion 5 "anomaly: HotplugFailed x2").
- Run reports: `runs/20261015-cbtf04-r02/reports/test-run-report.md` (findings section), `test-run-result.md`.
- Contradictory evidence: none — no functional failure co-occurred with the events.
- Confidence limits: single run label; second-granularity event timestamps (sub-second ordering within the detach burst not established); the doubling (count 1→2) is from a single event object's watch updates; OpenShift cluster version not recorded; no `qemu-img` allocation-map evidence in the run (data correctness established at guest level only).

## Acceptance criteria

- Post-backup detach of the backup-target hotplug volume on a successful
  backup emits no `HotplugFailed` (or the reason/message accurately reflects
  the phase and is documented as non-actionable).
- Cleanup invariants hold after the change: attachment pod deleted, volume
  unmounted, destination PVC Bound, tracker advanced exactly once.
- Regression check: full + incremental backup-then-detach cycle on ODF/Ceph
  RBD with filesystem-mode hotplug, asserting the namespace event stream
  contains no failure-reasoned hotplug events on successful passes.

## Triage questions

- Is the `HotplugFailed` event emitted by a mount-path validation/retry that
  races the CSI globalmount teardown, or by a stale VMI-status reconcile after
  the volume is already removed? (Determines Bug vs Improvement and the fix
  site.)
- Is the "failed to mount" message during a detach phase a wrong-message bug
  independent of whether the event should fire at all?
- Do real hotplug failures on this path use the same reason code, making the
  signal indistinguishable for alerting consumers?

---

## 4. Follow-up hypotheses (labeled — not established mechanisms)

- **HYPOTHESIS (teardown re-check race):** `virt-handler`'s filesystem-hotplug
  logic re-validates the mount source path during volume removal; by then the
  CSI node-stage globalmount path (`…/globalmount/<volume-id>/disk.img`) is
  already deleted, so the `lstat` fails and is reported through the generic
  `HotplugFailed` reason. Consistent with the message appearing during
  detach and with the count doubling (one retry, then the volume is gone).
- **HYPOTHESIS (stale reconcile):** the VMI status still references the
  hotplug volume while the attachment pod is being deleted; a virt-handler
  reconcile loop attempts a (re)mount from stale state and fails on the
  vanished path, emitting the event before the final successful delete/unmount
  records.
- **HYPOTHESIS (observability-only impact):** the event is purely noisy and
  has no functional consequence on this version/storage combination; the
  mask is the eventual volume deletion making the failed retry moot. Would be
  supported if a second run reproduces the event pattern with the same clean
  outcomes; contradicted if any future run shows a wedged attachment
  correlated with the event.
- **NON-hypothesis (ruled out):** causation by the controller kill — the
  identical pattern fired on the no-chaos incremental pass 23 minutes after
  failover, on a settled control plane.

## 5. Customer recommendation

None. The run does not support customer action: backups, cleanup, chain
integrity, and restores completed correctly despite the events. (If an
operator alerts on `HotplugFailed`, they may see false pages during
successful CBT backup detach — worth noting in the ticket, not a
customer-facing mitigation from this evidence.)

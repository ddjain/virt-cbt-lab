# Bug: Deleting a VirtualMachineBackupTracker mid-copy wedges the in-flight backup permanently and deadlocks the backup CR's own deletion until the tracker is recreated by hand

> Standalone doc. An engineer with cluster access but no knowledge of this
> harness should be able to read this file alone and reproduce the problem.
> The independent CBT Analyst writes one scenario-root
> `bugs/<defect-slug>.md` per deduplicated defect, adding corroborating runs.
> A confirmed valid injection and an observed required product violation are
> mandatory; do not file bugs for unknown outcomes, injection or harness issues.
> Every claim needs an object field, output or timestamp; root cause may be
> unknown. A draft does not create a Jira issue; never invent a filed key.

## Summary

In CBT-EXP-08 (attempt `18-10-2026-10-07-15-vm-20261018100715-wild-falcon-ad5d-tracker-delete-iteration-4`, closed 2026-10-18), a single UID-preconditioned API deletion of a run's `VirtualMachineBackupTracker` — issued 17 s after the backup's copy started, with the copy proven mid-flight by QEMU — left the `VirtualMachineBackup` permanently non-terminal: no `Done`, no failure condition, no deadline, the `backup.kubevirt.io/vmbackup-protection` finalizer retained and the destination PVC hot-plugged into the running VM for over 20 minutes until an operator intervened. Deleting the wedged backup CR did not clear it either: the API accepted the DELETE (HTTP 200) and then kept the object for the full 5-minute observation bound with a `deletionTimestamp` and the finalizer retained, because the abort path itself re-reads the deleted tracker and loops on `BackupTracker … does not exist`. The wedge released only after the tracker was re-applied (recreated as a new object), and the product never recreated the tracker itself. After the tracker existed again, a fresh full backup of the same VM completed normally — proving the VM and its data were healthy throughout and the entire outage was the tracker dependency.

This is the **API-side entry path** to the same no-terminal-resolution wedge family already documented from checkpoint corruption in `artifacts/CBT-EXP-06/bugs/backup-cr-livelock-on-missing-per-disk-bitmap.md` (whose "Second entry path" section holds a partly-reconstructed 2026-10-14 predecessor). This ticket is the first clean, evidence-complete, independently graded reproduction of that entry path; it is filed per-scenario rather than editing the EXP-06 ticket, and cross-references it instead of duplicating it. A defect reachable two ways is not an artefact of one test.

**Reproduced.** On 2026-10-19 a user-requested, independently graded
reproduction attempt on the same build and distinct run-scoped resources
repeated every product symptom with the same shape and magnitude (see
"Reproducibility" below).

## Component & Version

| Component | Version / identifier |
|---|---|
| Suspected component | CNV/KubeVirt `virt-controller` backup reconciler: the completion path's tracker update (`updateBackupTracker`, `backup.go:1088` vicinity) and the abort/deletion path (`backup.go:1003`, `backup.go:395`, `backup.go:1088`) — suspected from log positions; root cause not determined |
| OpenShift | 4.22.15 (`oc` client 4.22.15; cluster UID `10b6cf63-8bde-411f-a1be-60a213587238` from `preflight/cluster.json`) |
| OpenShift Virtualization / KubeVirt | CNV `kubevirt-hyperconverged-operator.v4.22.12`; `virt-controller` pods `virt-controller-6f7bc6b44c-cd845` / `-rh7ct` (`app.kubernetes.io/version=4.22.12` on `execution/controller-deployment.json`), 2/2 Ready, 0 restarts across the window |
| Backup API | `backup.kubevirt.io/v1alpha1` (`virtualmachinebackups`, `virtualmachinebackuptrackers`) |
| Storage (ODF/Ceph) | `ocs-storagecluster-ceph-rbd`, destination PVC 80 Gi Filesystem/ReadWriteOnce, driver `openshift-storage.rbd.csi.ceph.com`; pool `HEALTH_OK` with ≈27.8 TiB free at preflight (`preflight/ceph-df.log`, `preflight/ceph-status.log`) |
| Krkn / krknctl | not used — krknctl v0.14.2-beta metadata verified to offer no scenario that deletes a named custom resource on a condition (`execution/krkn-metadata.json`); this is a documented `oc`/API fault action (Pattern C) |

## Steps to Reproduce

These steps describe the approved reusable reproduction; they are not
authorization to execute another fault. Never reuse another run's names.

1. Use `cbt-chaos/scenarios_v2/CBT-EXP-08/run.sh` (approval record
   `cbt-chaos/scenarios_v2/CBT-EXP-08/approval.json`, request
   `cbt-exp08-bundle-20261018T101500Z`, fingerprint `b2114ff8…`). On the
   approved execution host supply the host-local configuration (kubeconfig
   path, guest-key mode `existing-pair`, digest-pinned restore image) as
   described in the scenario's `jira-issue.md`; then:

   ```sh
   export LIFECYCLE_ID='<fresh-lifecycle-id>'
   export CHAOS_RUN_ID='<fresh-attempt-id-from-cbt-chaos/run-id.sh>'
   bash cbt-chaos/scenarios_v2/CBT-EXP-08/run.sh --plan
   bash cbt-chaos/scenarios_v2/CBT-EXP-08/run.sh --preflight   # read-only
   # only after explicit whole-bundle approval:
   bash cbt-chaos/scenarios_v2/CBT-EXP-08/run.sh --execute
   ```

   Fixed stage inputs for the recorded run: `NAMESPACE=vm-cbt-demo`,
   `VM_OS=rhel9`, `MANIFEST_VARIANT=large-odf` (fresh VM, ~17 GiB payload,
   CBT enabled), destination PVC 80 Gi on `ocs-storagecluster-ceph-rbd`,
   tracker `vm-tracker-<lifecycle>`, backup `vm-backup-<lifecycle>`.

2. `run.sh` alone owns the sequence: `make vm-setup`, read-only watches on
   backup/tracker/VM/VMI/PVC/launchers, `make vm-backup` as a background
   child, then the armed window. The window waits for the compound
   active-copy condition — backup `Progressing=True` ∧ `Done≠True` ∧ no
   `deletionTimestamp` ∧ run-scoped labels/source/PVC ∧ the launcher's
   `Backup started` line for that backup name ∧ a live QMP
   `query-block-jobs` backup job with `0 < offset < len` ∧ VMI `Running` ∧
   the tracker present with the exact UID, `spec.source` = this VM and no
   `status.latestCheckpoint`.

3. After a 15 s dwell, the run **re-validates both operands in the same
   instant as the action** (backup: same UID, still not Done, not deleting,
   run-scoped; tracker: same UID, checkpoint still unset, not deleting), then
   issues exactly one deletion through an owned local `oc proxy` with the
   live tracker UID as a precondition:

   ```sh
   curl --noproxy '*' -sS -X DELETE -H 'Content-Type: application/json' \
     --data-binary @delete-options.json -o delete-response.json -w '%{http_code}\n' \
     "http://127.0.0.1:<port>/apis/backup.kubevirt.io/v1alpha1/namespaces/<ns>/virtualmachinebackuptrackers/<tracker-name>"
   # delete-options.json:
   # {"apiVersion":"v1","kind":"DeleteOptions","gracePeriodSeconds":0,
   #  "preconditions":{"uid":"<live-tracker-uid>"}}
   ```

   Then it requires the tracker `GET` to return HTTP 404 (fail-closed) and
   samples the backup and tracker read-only every 15 s to a 900 s bound.

4. Recovery leg (bounded, unforced): one UID-guarded DELETE of the wedged
   backup CR (300 s bound), then re-apply of the tracker manifest when the
   tracker is absent (observe whether the wedged CR releases), then one
   fresh-named `forceFullBackup: true` backup with a new PVC (validated for
   Done/type/reason/checkpoint/PVC Bound/tracker advance).

5. Read-only defect check against the preserved artifacts of the recorded
   run (no cluster needed): verify the backup never became terminal in
   `backup-samples.json` (60/60 `Done=False`, finalizer retained, rv frozen
   at 30950340) while the tracker was absent (`tracker-samples.json`, 60/60
   absent), and that the wedged CR kept a `deletionTimestamp` + finalizer
   for the full 300 s bound (`wedged-deletion.json`, 145 samples, rv frozen
   at 30967644, Progressing reason `BackupTracker … does not exist`).

## Current Behavior

All UTC times and UIDs are from the recorded attempt's artifacts.

- **Fault, proven:** active-copy condition at `2026-10-18T10:12:39Z`
  (launcher `Backup started` at `10:12:38.122796478Z`; QMP job running
  `offset=1876951040 < len=83872448512`; tracker checkpoint unset; VMI
  Running). Same-instant operand revalidation at `10:12:54Z` (backup uid
  `517340ea-779e-487e-a837-c819ecfa7074`, rv 30950340, not Done, not
  deleting; tracker uid `9610c8af-4dd8-48e2-82e2-914fd93f7c77`, rv 30950166,
  checkpoint unset). UID-preconditioned DELETE at `10:12:55Z` → HTTP 200
  `Success` for exactly that UID; first GET → 404 (`NotFound`); `DELETED`
  watch event for that UID (`execution/watch-tracker.jsonl`).
- **Wedge:** the backup never reached a terminal state in the 900 s bound —
  60/60 readable samples `10:13:01Z–10:27:57Z` all `Done=False` /
  `Progressing=True`, reason `Backup is in progress`, `deletionTimestamp`
  null, finalizer `backup.kubevirt.io/vmbackup-protection` retained, and the
  CR `resourceVersion` frozen at `30950340` (no controller write at all
  after `10:12:38Z`). The QEMU backup job itself ended during the window
  (`query-block-jobs` empty at `10:27:58Z`) with no completion write. The
  destination PVC stayed hot-plugged (`volumeStatus` entry
  `MountedToPod`/`VolumeMountedToPod`, attachment pod `hp-volume-c6x44`)
  from `10:12:30Z` until `10:33:07Z` (~20 m 37 s).
- **Tracker never recreated by the product:** 60 tracker samples over 896 s
  all absent; the only new tracker (`fc8fbdac-4077-479e-9704-8a3ab41c0045`)
  was the bundle's own re-apply at `10:33:07Z`.
- **Deletion deadlock:** UID-guarded, unforced DELETE of the wedged CR at
  `10:28:06Z` → HTTP 200, then the object persisted the full 300 s bound
  (145 samples `10:28:06Z–10:33:07Z`: `deletionTimestamp=10:28:06Z`,
  finalizer retained, rv frozen `30967644`, every sample's Progressing
  reason `BackupTracker vm-tracker-20261018100715-wild-falcon-ad5d does not
  exist`). Release happened only after the tracker re-apply: gone within the
  first post-tracker sample at `10:33:07Z`
  (`execution/wedged/release-1.json`).
- **Controller log (both replicas; analyst re-verified read-only on
  2026-10-18):** zero run-scoped lines between `10:12:38Z` (`Started backup
  for VMI … successfully`, `backup.go:648`) and `10:28:06Z` — the pre-delete
  wedge is silent, not a logged requeue loop. The decisive lines are all on
  the abort path and post-date the wedged-CR delete: `BackupTracker … does
  not exist` (`backup.go:1088`, ×2 at `10:28:06Z`), `update backup is
  deleting` (`backup.go:1003`, ×5), `reenqueuing VirtualMachineBackup …
  reason=ongoing cleanup for backup deletion` (`backup.go:395`, ×6 at
  `10:33:07Z`).
- **Blast radius:** clean — every other VM/tracker/backup/PVC in the
  namespace kept its name→UID map (added/removed/changed = 0 across
  vmbackup 41, vmbackuptracker 25, vm 28, vmi 28, pvc 103); control VM
  `vm-cbt-demo` unchanged; VMI never `Paused`; guest agent connected
  throughout.

The expected disruption (one tracker object deleted) and the unexpected
product failure (permanent non-terminal backup + non-deletable CR) are
clearly separated above; the deletion of the tracker is the modeled operator
action, not the defect.

## Reproducibility

**Second reproduction — 2026-10-19, user-requested confirmation, independently
graded FAIL.** Attempt
`19-10-2026-08-32-54-vm-20261019083254-wild-mountain-cf47-tracker-delete-iteration-5`
(sole grading record: that run's `analysis.json`). Same build, distinct
run-scoped resources:

- **Same build:** cluster UID `10b6cf63-8bde-411f-a1be-60a213587238`,
  OpenShift 4.22.15, CNV `kubevirt-hyperconverged-operator.v4.22.12`,
  identical `virt-controller` image digest
  `sha256:23e9322e64f0f4bc8b6e9786249efb6a1810507cb3ea0c9cee27c2b1a0e6c780`
  (both attempts' `execution/controller-deployment.json`). Approved bundles
  share 20/21 file hashes; only the harness-side shared checkout `Makefile`
  was re-pinned (`f03f649d…` → `734f6b30…`); the attempt's live re-hash
  matched its own approval 21/21.
- **Distinct resources:** fresh lifecycle `20261019083254-wild-mountain-cf47`
  (VM uid `46858532-d081-470f-97a8-2faebf618b6f`, tracker uid
  `0607a5e7-c397-44f1-ac07-2005f5670ccc`, backup uid
  `f350d26c-5a7c-468b-87de-9ba3796ac857`).
- **Fault, proven again:** mid-copy condition at `2026-10-19T08:48:16Z`
  (launcher `Backup started` `08:48:14.989373Z`; QMP job running
  `offset=2411724800 < len=83875594240`; job still running 5 s post-fault at
  `offset=33537654784`); UID-preconditioned DELETE at `08:48:32Z` → HTTP 200
  `Success`; first GET → 404; `DELETED` watch event for that UID.
- **Wedge, same shape and magnitude:** 60/60 readable samples over 896 s
  (bound 900 s) all `Done=False` / "Backup is in progress", finalizer
  retained, rv frozen at `32484190`, QEMU job ended with no completion write
  (`query-block-jobs` empty at `09:03:35Z`); destination PVC hot-plugged
  (`MountedToPod`, attachment pod `hp-volume-22m7b`) from `08:48:14Z` until
  `09:08:44Z` (~20 m 30 s).
- **Tracker never recreated by the product:** 60/60 tracker samples absent
  over 896 s; the only new tracker (`48431099-0d9d-4353-807d-cbd66a72f501`)
  was the bundle's own re-apply at `09:08:44Z`.
- **Deletion deadlock, same shape and magnitude:** UID-guarded unforced
  DELETE of the wedged CR at `09:03:42Z` → HTTP 200, then stuck the full
  300 s bound (145 samples, `deletionTimestamp` + finalizer retained, rv
  frozen `32501446`, every sample's Progressing reason `BackupTracker
  vm-tracker-20261019083254-wild-mountain-cf47 does not exist`); released
  only after the tracker re-apply (`gone_after_tracker_recreation`, gone in
  the first post-tracker sample at `09:08:44Z`; terminal write `Done=True`
  "Backup has failed: backup was deleted during initialization").
- **Fresh backup after recovery:** `vm-recovery-full-…-r001`
  `forceFullBackup` completed normally — 11/11 operand checks
  (`execution/recovery-operand-checks.json`), new PVC Bound, tracker
  advanced to the recovery checkpoint.
- **Guest / blast radius:** VMI `Running` throughout, never `Paused`
  (27 watch events, zero Paused conditions), `AgentConnected=True`; every
  other VM/tracker/backup/PVC kept its name→UID map (vmbackup 25,
  vmbackuptracker 14, vm 14, vmi 14, pvc 54); control VM unchanged.
- **Silent pre-delete wedge, again:** the controller window pinned to the
  delete instant captured 0 lines from both replicas (0 restarts; analyst
  live read-only re-verification at 2026-10-19T09:26Z confirmed zero
  run-scoped lines in `08:48:32Z–09:03:35Z`); the decisive
  `backup.go:1088` / `backup.go:1003` / `backup.go:395` lines all post-date
  the wedged-CR delete, and the `backup.go:395` reenqueues appear only
  after the tracker re-apply.

**Third reproduction — 2026-10-23, v2 re-host scenario CBT-EXP-08V1,
independently graded FAIL.** Attempt
`22-10-2026-22-02-00-vm-20261022220159-swift-wolf-e7a4-tracker-delete-iteration-1`
(sole grading record: that run's `analysis.json`). Same build, distinct
run-scoped resources, freshly re-derived bundle (separate fault-action file
`inject.sh`, shared `cbt-chaos/scenario-runtime.sh`):
- **Same build:** cluster UID `10b6cf63-8bde-411f-a1be-60a213587238`,
  OpenShift 4.22.15, CNV `kubevirt-hyperconverged-operator.v4.22.12`,
  `virt-controller` image digest
  `sha256:23e9322e64f0f4bc8b6e9786249efb6a1810507cb3ea0c9cee27c2b1a0e6c780`
  (this run's `execution/controller-deployment.json`), 2/2 Ready, 0 restarts.
- **Distinct resources:** fresh lifecycle `20261022220159-swift-wolf-e7a4`
  (VM uid `89f57256-287a-4fe1-8d0e-80147d846304`, tracker uid
  `61da2429-d4b3-45fe-b6d6-e15998124e61`, backup uid
  `545d359f-1b1a-472c-8999-3f0a2c37fcca`).
- **Fault, proven again:** mid-copy compound condition at
  `2026-10-23T00:56:50Z` (launcher `Backup started` `00:56:48.683Z`; QMP
  job running `offset=2828009472 < len=83869302784`; VMI Running same UID;
  tracker checkpoint unset); same-instant revalidation at `00:57:05Z`;
  UID-preconditioned DELETE at `00:57:06Z` → HTTP 200 for exactly that UID;
  first GET → 404; `DELETED` watch event for that UID.
- **Wedge, same shape and magnitude:** 60/60 readable samples over 896 s
  (bound 900 s) all `Done=False` / "Backup is in progress", finalizer
  retained, rv frozen at `38417908`, QEMU job ended `00:57:55Z` with no
  completion write; destination attachment (`hp-volume-vbn4p`) held from
  `00:56:48Z` to `01:17:17Z` (~20 m 29 s).
- **Tracker never recreated by the product:** 60/60 tracker samples absent;
  the only new tracker (`92756b7c-ecbd-4426-901a-fb7e057e720c`) was the
  bundle's own re-apply at `01:17:16Z`.
- **Deletion deadlock, same shape and magnitude:** UID-guarded unforced
  DELETE of the wedged CR at `01:12:16Z` → HTTP 200, then stuck the full
  300 s bound (145 samples, rv frozen `38435280`, every sample's
  Progressing reason `BackupTracker vm-tracker-20261022220159-swift-wolf-e7a4
  does not exist`); released only after the tracker re-apply
  (`gone_after_tracker_recreation`; terminal write `Done=True` "Backup has
  failed: backup was deleted during initialization" at `01:17:17Z`).
- **Fresh backup after recovery:** `vm-recovery-full-…-r001`
  `forceFullBackup` completed normally — 11/11 operand checks
  (`recovery-operand-checks.json`), new PVC `vm-recovery-pvc-…-r001` Bound,
  tracker advanced to the recovery checkpoint
  `vm-recovery-full-20261022220159-swift-wolf-e7a4-r001-2026-10-23_01-17-19`.
- **Guest / blast radius:** VMI `Running` throughout, never `Paused`; every
  other VM/tracker/backup/PVC kept its name→UID map (vmbackup 7,
  vmbackuptracker 3, vm 3, vmi 3, pvc 15); control VM `vm-cbt-demo`
  unchanged.
- **Silent pre-delete wedge, again:** the `end`-pinned window captured 0
  run-scoped lines from both replicas (analyst live read-only
  re-verification at `2026-10-23T02:06:44Z`); the decisive `backup.go:1088`
  tracker-404 lines post-date the wedged-CR delete (`wedged` phase: 2
  tracker-absent lines, 2 "backup is deleting"; `recovery` phase: 2 + 6).

**Conclusion:** recurrence of the symptom set on the same build is
established across three independently graded reproductions (2026-10-18,
2026-10-19, 2026-10-23) on distinct run-scoped resources. Per policy this is
recurrence of symptoms, not proof of an identical causal mechanism — root
cause remains not determined, and repeated executions on a single
cluster/build are not a controlled experiment.

## Expected Behavior

Per the scenario's acceptance contract (`scenario-spec.md` §5 and
`jira-issue.md`): deleting the tracker of an in-flight backup must not be
able to strand the backup. The backup should reach a terminal condition
within a bounded time — a genuine completion (`Done=True`, non-failure
reason, checkpoint recorded) or a bounded, honest failure reported on the
backup object itself — releasing its finalizer and detaching its destination
volume, and leaving the VM able to produce a verified new full backup
without the operator having to guess a repair order. The wedged CR's own
deletion should not depend on the continued existence of the very object the
fault removed.

## Additional Notes

- **Root cause: not determined.** Log positions show the completion path
  (`backup.go:648` vicinity) and the abort path (`backup.go:1003`,
  `:395`, `:1088`) both touching the tracker, but no source was read for
  this bundle. The observed facts are: no controller write to the CR at all
  after the tracker deletion (rv frozen), the QEMU job finishing without a
  completion write, and the abort path looping on the missing tracker until
  it exists again. Whether the controller should recreate the tracker, fail
  the backup honestly, or release the CR without it is a triage question
  this ticket does not answer.
- **Independent injection-validity proof:** same-instant revalidation
  artifacts (`execution/backup-immediately-before-delete.json`,
  `execution/tracker-immediately-before-delete.json`), UID-preconditioned
  DELETE (`execution/delete-options.json` → `execution/delete-response.json`
  HTTP 200 for UID `9610c8af-…`), fail-closed 404
  (`execution/tracker-get-codes.log`, `execution/tracker-get-response.json`),
  `DELETED` watch event for the exact UID (`execution/watch-tracker.jsonl`),
  and the mid-copy QMP job at the fault instant
  (`execution/guest-jobs-after-fault.json`, offset 32812040192 < len
  83872448512 at `10:13:00Z`).
- **Observed recovery / workaround (evidence-backed):** recreate the tracker
  first (any manifest applying the same `spec.source` VM works — the bundle
  re-applied the backup manifest shape), which unblocks the abort and lets
  the wedged CR delete; then a fresh `forceFullBackup` completes normally
  (`recovery-backup.yaml`: `Done=True`, `Successfully completed
  VirtualMachineBackup`, `type=Full`, checkpoint recorded, new PVC Bound,
  tracker advanced — 11/11 operand checks in
  `execution/recovery-operand-checks.json`). Deleting the wedged CR alone
  does **not** work while the tracker is gone.
- **Limits:** host/node-local release of the retained destination PVC is
  UNKNOWN (no host probe authorized; API-level attachment cleared — no
  VolumeAttachment referenced the retained PV on a 2026-10-18T11:25Z
  read-only check). The one-backup-per-source guard rejection was not
  exercised (the fresh backup was created only after the wedged CR was
  gone). The 900 s / 300 s bounds are approved observation windows, not
  documented product SLAs. A `HotplugFailed`/`lstat … disk.img: no such
  file or directory` event pair appeared at the abort instant and again on
  the fully successful recovery backup's cleanup, so it is not
  wedge-attributable.
- **Corroborating runs / family:** same-consequence family ticket
  `artifacts/CBT-EXP-06/bugs/backup-cr-livelock-on-missing-per-disk-bitmap.md`
  (checkpoint-corruption entry; its "Second entry path" section documents the
  2026-10-14 predecessor `20261014-exp08-r01`, whose trigger died
  mid-recovery and whose record is partly reconstructed). First clean,
  evidence-complete reproduction of the API-side entry:
  `18-10-2026-10-07-15-vm-20261018100715-wild-falcon-ad5d-tracker-delete-iteration-4`
  (iteration 4 after BLOCKED/BLOCKED/INVALID predecessors; graded FAIL in
  its `runs/<attempt-id>/analysis.json`). Second reproduction (same build,
  distinct resources, user-requested confirmation):
  `19-10-2026-08-32-54-vm-20261019083254-wild-mountain-cf47-tracker-delete-iteration-5`
  — graded FAIL in its `runs/<attempt-id>/analysis.json`; see
  "Reproducibility" above. Supporting artifacts per run:
  `runs/<attempt-id>/analysis.json`, `run-report.md`, `trigger.log`,
  `backup-samples.json`, `tracker-samples.json`, `wedged-deletion.json`,
  `tracker-recreation.json`, `controller-window.log`,
  `execution/wedged/`, `execution/watch-*.jsonl`. No fix proposal is made.

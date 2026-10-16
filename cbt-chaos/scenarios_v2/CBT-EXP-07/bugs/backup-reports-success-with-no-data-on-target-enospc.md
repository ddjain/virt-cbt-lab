# [CBT] Backup reports success with ~0% of the data when the destination runs out of space mid-copy (failed push job recorded as success; chain advances onto the empty backup)

## What this is, in one paragraph

If the destination disk for a backup runs out of space during the copy, the backup still reports
success. What it actually leaves behind is a 4 MiB "shell" file that stores no data of its own and
points at the running VM's own disk — so it looks restorable only while the VM is alive, reading
straight through to the live machine. When the VM is gone (the exact situation a backup exists for),
that shell restores nothing: the restore fails with `Could not open backing file`. The change-tracking
bookkeeping ("tracker": the object that remembers the latest checkpoint so the next backup can be
incremental) then advances onto this empty backup, so every later incremental backup builds on nothing.
The ENOSPC ("no space left on device") error appears in no object, no condition and no event.

**When → then → expected**

- **When** the product is taking a push-mode backup — CBT: the change-tracking backup mode, the copy
  driven from the VM's own launcher process — into a destination volume **too small to hold the copy**,
  and the volume runs out of space *after* the checkpoint has been created (that ordering is what
  poisons the chain).
- **And** the disruption `EXP-7` (this is **not** a krknctl scenario: no krkn primitive can size a
  destination volume, so the recorded runs applied the constraint by hand) is applied: **pre-fill the
  destination PVC with a filler file before the backup object exists**, in the recorded run leaving
  ~127 MiB free on a 4 GiB volume (r02 pre-fill recorded at 20:30:23Z, before backup creation).
- **Then (current behaviour):** the backup reaches `Done=True` with reason
  `Successfully completed VirtualMachineBackup` after a 3-second "copy" (a real copy took 64 s), the
  destination holds only a 4,456,448-byte qcow2 shell against a 17,431 MiB workload (0.02 %), no
  ENOSPC text appears anywhere, and the tracker advances onto the empty backup's checkpoint.
- **Expected behaviour:** the failed copy ends the backup with a failure reason that names the real
  error, and the tracker does not advance. A backup that cannot hold the data must never be reported as
  a successful restore point.

> **Standalone engineering ticket.** Write it so an engineer who has never seen this repository,
> this cluster, or this test harness can reproduce and triage it from the ticket alone.
>
> Fill rules:
> - Choose **Bug** only for a demonstrated violation of an established contract; choose
>   **Improvement** for an ambiguous contract, a requested behaviour, or a status/reporting gap.
> - Keep **product** defects and **test-harness** defects in separate tickets. Never mix them.
> - Every factual claim carries an evidence citation — a command output, an object field with its
>   UTC timestamp, or a sanitized short quote. Label anything beyond the artifacts as **inference**.
> - Never invent a Jira key or claim this was filed. Mark unproven causes as unproven.
> - Write `not recorded` (and say why) rather than guessing a value. Never fill a gap with a
>   plausible number.
> - Sanitize: no credentials, tokens, kubeconfig paths, private hostnames, absolute host paths,
>   broad selectors, or cluster-cleanup commands.
>
> Delete this preamble in the filed ticket; keep the structure below.

## At a glance

| Field | Value |
|---|---|
| Issue type | **Bug** — a demonstrated violation of an established contract: a backup that copied no data reported terminal success with a pure success reason, and the checkpoint chain advanced onto it. (Not a reporting nicety: the success path is what consumers act on.) |
| Priority (proposed) | **High** (critical class for data protection) — silent loss of a backup that the product reports as healthy; a restore is impossible exactly in the disaster case the backup exists for. Unassigned pending triage for final severity. |
| Severity class | data protection (silent corruption of the backup chain) + status truthfulness (failure recorded as success) |
| Owning component (suspected) | **suspected** KubeVirt backup job-completion handling: the launcher-side `DOMAIN_JOB_COMPLETED` handler that records the job as successful, and the tracker update path that consumes it. |
| Component(s) proven involved | the virt-launcher backup job path (it produced a success terminal state and a metadata-only qcow2 overlay whose backing file is the live VM disk) and the `VirtualMachineBackupTracker` update path (it advanced `latestCheckpoint` onto the empty backup). The destination storage never reported the ENOSPC into any product surface. |
| Reproducibility | `deterministic (3/3 run labels of the campaign)` — the same effect every time the destination cannot hold the dirty set: r01 leg B, r02 surgery leg, r03 surgery leg (all 2026-10-14), each with an independent control leg that behaved correctly. All attempts were made by the same reporter/harness on one cluster/build; no third-party reproduction. |
| Status / confidence | **Confirmed behaviour** (loud artifacts: object status, destination contents, `qemu-img info`, and a restore attempt). Certain: the CR reports success while the destination holds a metadata-only overlay, no ENOSPC string appears anywhere, and the tracker advanced. **[INFERENCE]** at the code level: the upstream anchor and source anchors below are read from the kubevirt v1.8.4 tree, not executed with instrumentation. |
| Blast radius | the affected backup and **every later incremental rooted in it** (the chain advances onto the empty backup) — i.e. a whole protection chain per VM, not one backup. No guest impact: the VM stays healthy. |
| Data at risk? | **Yes — the primary risk of this ticket.** The backup that a consumer would restore contains no source data; a restore against a deleted/sourceless VM fails outright (`Could not open backing file`). The *source* data is untouched: this is loss of the protection copy, not of the live VM. |
| Related scenario / execution | `CBT-EXP-07` (late-copy ENOSPC), run `20261014-exp07-r01` (2026-10-14) with the same-day reproductions `20261014-exp07-r02` (workflow-driven) and `20261014-exp07-r03` (alive-restore triad); upstream anchor **kubevirt#17578**; companion product ticket `CBT-EXP-06/bugs/backup-cr-livelock-on-missing-per-disk-bitmap.md` (the same "VMI backup status was lost" ghost event masks that defect's real cause too). |
| Affected versions | OpenShift Virtualization 4.22.12 (kubevirt v1.8.4-era backup implementation, `backup.kubevirt.io/v1alpha1`); RHEL 9 VM, 1000-file / 17,431 MiB workload; push-mode backup; HostPath storage class (node-local PV destination). The full measured matrix is in **Environment** below. |

## Context (for an engineer new to this area)

- **What the feature does** — a push-mode `VirtualMachineBackup` copies the VM's disk into a
  destination PVC (here a node-local HostPath volume), driven from the virt-launcher side as a
  libvirt/QEMU job. Per backup the chain records a **checkpoint**; a `VirtualMachineBackupTracker`
  holds the chain's `latestCheckpoint` so the next backup can be incremental from it.
- **Where the failure sits** — three surfaces disagree: the `VirtualMachineBackup` CR says
  `Done=True` with reason `Successfully completed VirtualMachineBackup`; the destination volume holds a
  metadata-sized qcow2 **overlay** (4,456,448 bytes) whose backing file is the *live* VM disk; and the
  tracker's `latestCheckpoint` advances onto that empty backup. The underlying ENOSPC never appears in
  the CR's conditions, reason, `status`, or the object's events.
- **Observed surface vs. origin** — the only failure trace is a Warning event
  `VirtualMachineBackupFailed: "Backup has failed: VMI backup status was lost"` fired at the same
  second as the completion — a message that reads like a benign status race and, per this campaign's
  other findings, is also emitted on healthy completions. The origin (the copy job's `succeeded`-style
  outcome and the destination write error) is never surfaced at all.
- **Why it matters** — a consumer/operator sees a healthy chain. Restore verification *while the VM
  still runs* passes (the overlay reads through to the live source disk, so the "restore" silently
  reads the running VM); the only case that fails is restoring after the VM is gone — precisely when
  the backup is needed. Every subsequent incremental then chains off the 4 MiB shell.

## Environment (measured, not assumed)

The per-ticket table below maps **this** run's layers: the destination is the **node-local HostPath
pool** (in use — the failure is a capacity failure on that filesystem), and the cluster's ODF/Ceph
stack is *present but not exercised* by this scenario. Rows are provenance-tagged: `run` = captured by
the campaign's own artifacts; `cluster 2026-10-16` = measured on the same cluster two days later
because this run's pack did not capture the layer; `not recorded` where nothing captured it (never
inferred).

| Layer | Component | Version / identifier | How obtained | Provenance |
|---|---|---|---|---|
| Platform | OpenShift Container Platform (server and `oc` client) | `not recorded` in this run's pack — the campaign captured no `oc version`/`clusterversion` output (the same cluster measured on 2026-10-16 reports 4.22.15 server+client with kustomize v5.7.1) | `oc version`, `oc get clusterversion version` (not run) | `not recorded` |
| Platform | Kubernetes API | v1.35.6 | `oc version` | `cluster 2026-10-16` |
| Platform | OpenShift update channel | `not recorded` — never captured | `oc get clusterversion version -o jsonpath='{.spec.channel}'` (not run) | `not recorded` |
| Platform | `oc`/`kubectl` plugin versions | `not recorded` — never captured | `oc plugin list` (not run) | `not recorded` |
| Nodes | OS image | Red Hat Enterprise Linux CoreOS 9.8.20260915-0 (Plow) | `oc nodes -o wide` | `cluster 2026-10-16` |
| Nodes | kernel | 5.14.0-687.48.1.el9_8.x86_64 | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | container runtime | cri-o 1.35.8-11.rhaos4.22.giteaf45bc.el9 | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | topology / node in scope | the destination PV is a **node-local** volume on the worker that runs the CBT VM; the run's own free-space capture ran from a debug pod on the node (`legB-prefill.txt` / `prefill.txt` name that node; genericised here as `<node>`) | run's `legB-prefill.txt`, `prefill.txt` (debug-pod header) | `run` |
| Virtualization | CNV / HCO CSV | `not recorded` for the CSV name/version in this pack; the run's report states "OpenShift Virtualization 4.22.12" | `oc get csv -A` (not run) / run report | `not recorded` (pack) — draft+report claim: 4.22.12 |
| Virtualization | kubevirt observed version | `status.observedKubeVirtVersion` = virt-operator image digest `sha256:2f654df4f4b026b85abc62bfe834a842b3a49b054f97a5999a85443320a29293` | `oc get kubevirt -n openshift-cnv -o jsonpath='{.status.observedKubeVirtVersion}'` | `cluster 2026-10-16` |
| Virtualization | kubevirt source/branch in scope | v1.8.4-era tree (the draft's source anchors below are read at that revision) | kubevirt source tree | draft claim (not measured on-cluster) |
| Virtualization | virt-launcher image digest | `not recorded` in this pack — the launcher pod spec was not among the saved artifacts | `oc get pod <launcher> -o jsonpath='{.spec.containers[*].image}'` (not run) | `not recorded` |
| Virtualization | virt-handler / virt-controller image digests | `not recorded` — not captured by this run | `oc get ds virt-handler -n openshift-cnv -o jsonpath=…`, `oc get deploy virt-controller -n openshift-cnv -o jsonpath=…` (not run) | `not recorded` |
| Virtualization | libvirt / QEMU / QEMU API in the launcher | `not recorded` for this run; the cluster's launcher images report libvirt 11.10.0 / QEMU 10.1.0 / QEMU API 11.10.0 | `virsh version` in the launcher's `compute` container | `not recorded` (run) / `cluster 2026-10-16` |
| Backup API | CRD group / version | `backup.kubevirt.io/v1alpha1` (the API version of every watched backup/tracker object in this run) | run's observer streams (`observer/surgery-backup.jsonl`, `observer/tracker.jsonl`) | `run` |
| Storage (**in use**) | StorageClass + provisioner + pool | node-local **HostPath** pool: the destination PV's files materialise under `/var/hpvolumes/csi/…` (the hostpath CSI pool path); the StorageClass **name** is `not recorded` in this run's own pack — on this cluster the pool is `cbt-demo-hpp` (provisioner `kubevirt.io.hostpath-provisioner`, pool `cbt-demo-pool`, DaemonSet `hostpath-provisioner-csi` in ns `openshift-cnv`) | run's `legB-target-files.txt`, `legB-prefill.txt` (paths + `df`); cluster reads for the pool identity | `run` (paths, capacity) / `cluster 2026-10-16` (pool identity) |
| Storage (**in use**) | CSI driver image + version | DaemonSet `hostpath-provisioner-csi` (ns `openshift-cnv`), image `registry.redhat.io/container-native-virtualization/hostpath-csi-driver-rhel9@sha256:72cdfd4ab6621148bf2a70485394d335d9ccc5045ab0aa82018e72472444bf6b`, `VERSION=v4.22` | `oc get ds hostpath-provisioner-csi -n openshift-cnv -o jsonpath='{.spec.template.spec.containers[*].image}'` | `cluster 2026-10-16` |
| Storage (**in use**) | backing device / filesystem / free space at the time | `/dev/sdb` → XFS, mounted at `/var/hpvolumes/csi`, ~1.5 TiB total: **1,394,597 MiB used / 130,291 MiB available (92%)** at the run's pre-fill capture; the volumes each carry a `filler.img` plus the backup shell | `df` from a debug pod on `<node>` recorded in `legB-prefill.txt` (r01) and `prefill.txt` (r02) | `run` |
| Storage (**in use**) | capacity trap for the next reproducer | the CSI data directory `/var/hpvolumes/csi` sits on **its own** filesystem (`/dev/sdb`) while its parent `/var/hpvolumes` is a different filesystem — measuring free space on the parent gives the wrong answer, so every capacity figure here is for `/var/hpvolumes/csi` | the two `df` captures above | `run` |
| Storage (**present but NOT exercised**) | ODF/OCS stack | `4.22.5-rhodf` operators (`odf-operator`, `ocs-operator`, `rook-ceph-operator`, `cephcsi-operator`, `mcg-operator`, `odf-csi-addons-operator`, external-snapshotter), RHCS 9 Ceph image `sha256:926d15fddae065a1e82b3634f80847253fa2cc14e9888e15b19b72a2cf144a58`, StorageClasses `ocs-storagecluster-ceph-rbd`, `ocs-storagecluster-ceph-rbd-virtualization`, `ocs-storagecluster-cephfs`, cluster health `HEALTH_OK` — installed but **not part of this scenario**: every volume in this ticket is the node-local hostpath pool (stated so triage does not chase a Ceph hypothesis) | `oc get csv -n openshift-storage`, `oc get cephcluster -n openshift-storage -o jsonpath=…`, `oc get sc` | `cluster 2026-10-16` |
| Storage (**present but NOT exercised**) | local-storage-operator | `local-storage-operator.v4.22.0-202609291750` — installed, not exercised by this scenario | `oc get csv -A` | `cluster 2026-10-16` |
| Guest | OS release | RHEL 9 (`VM_OS=rhel9`; "RHEL 9 VM") | run `trigger.log`; run report | `run` |
| Guest | kernel | `not recorded` for this run — no guest `uname -r` capture (the guest kernel `5.14.0-687.5.1.el9_8.x86_64` in the shared cluster notes was measured on a different, later guest) | `uname -r` in the guest (not run) | `not recorded` |
| Guest | guest agent package version | `not recorded` for this run (the cluster note `qemu-guest-agent-10.1.0-17.el9_8` was measured on a different guest) | `rpm -q qemu-guest-agent` (not run) | `not recorded` |
| Guest | vCPU / memory | `not recorded` — not captured | VM spec vs `nproc` / `free` (not run) | `not recorded` |
| Guest | workload used (context, not a version) | 1,000 files / 17,431 MiB payload; push-mode backup; destination PVCs 4 GiB (surgery legs) vs a normal-sized control target; `qemu-img info` reports the source disk's virtual size as 79.7 GiB | run's `trigger.log`; `legB-*`/`surgery-*` artifacts; `test-run-report.md` | `run` |
| Harness (internal only) | workflow version / trigger checksum | EXP-7 direct-drive and workflow-driven legs (not a chaos-injection scenario: the "injection" is the pre-filled destination); the trigger checksum is `not recorded` in this pack (and CBT-EXP-06's checksum must not be reused) | run pack | `not recorded` |

**Load-bearing facts.** Two matter for the diagnosis: (1) the destination filesystem is the node-local
hostpath pool, so an ENOSPC there surfaces only as a write error inside the copy job — the product has
no capacity pre-check to consult; (2) the target volume's 4 GiB size combined with a pre-fill that
leaves ~127 MiB free makes the copy hit the wall *after* checkpoint creation, which is what puts the
chain in the corrupted state rather than failing before any state was written.

## Reproducibility

- **Classification**: `deterministic (3/3 run labels of the campaign)` — the effect appeared on every
  attempt whose destination could not hold the dirty set: r01 leg B (direct-drive), r02 surgery leg
  (workflow-driven lifecycle), r03 surgery leg (with the alive-restore triad). Each run label also has
  a control leg that behaved correctly (64 s / 53 s with real data), so the difference is the capacity
  constraint, not the harness path.
- **Attempts**: 3 run labels on 2026-10-14, all by the campaign's own workflow/operator on one
  cluster/build (the reporter only — **no independent observer reproduced it**; the r01 leg was
  direct-drive with an independent read-only event/object watcher, r02/r03 were workflow-driven).
- **Stability — exact every time**: `Done=True` with a pure success reason; the destination holding a
  ~4.25 MiB qcow2 overlay; the absurdly short copy window (3 s vs a 64 s control); the absence of any
  ENOSPC text in object/events/status; the tracker advancing onto the shell. **Varies**: the exact
  shell byte count across pairs (4,456,448 B in r01 leg B and r02; 8.19 MiB disk size in r03's
  descriptor, i.e. the same overlay class with a slightly larger metadata set), the pre-fill free-space
  margin, and the guest mutation set per leg.
- **Preconditions**: (a) push-mode CBT backup with the destination PVC smaller than the volume's
  pending dirty set; (b) the destination pre-filled so the copy reaches ENOSPC **after** checkpoint
  creation; (c) no pre-copy capacity/dirty-set check exists in the product (nothing rejected the
  backup before copying).
- **Second entry path**: not established — every observed instance came from the same precondition
  (destination capacity < copy size). A *different* path to a metadata-only success (e.g. a job killed
  as "completed", which is what the upstream anchor describes) is plausible but was not exercised here.

## Steps to reproduce (exact commands and injection timing)

> Everything below uses the **recorded names of run `20261014-exp07-r01`** (namespace `vm-cbt-demo`), so
> each command can be compared with this ticket's evidence. For a fresh reproduction pick your own
> run-scoped names. Every command is scoped to one named object. There is no chaos tool in this
> scenario: the "injection" is a capacity constraint applied **before** the backup object is created.

### Concrete objects used in this report

| Kind | Name | UID | Created (UTC) | Fate |
|---|---|---|---|---|
| VirtualMachine / VMI | `vm-20261014-exp07-r01` | `not recorded` | 2026-10-14 ~20:09Z | kept; Running/Ready/AgentConnected throughout, no restart |
| VirtualMachineBackupTracker | `vm-tracker-20261014-exp07-r01` | `not recorded` | `not recorded` | kept — **its `status.latestCheckpoint` is what advances onto the empty backup** |
| VirtualMachineBackup (control, r01 leg A) | `vm-backup-20261014-exp07-r01` | a125b1cc-5f66-4cc3-81c3-78bfd6d4bf3c | 20:09:43Z | kept; `Done=True` 20:10:47Z (64 s), type `Full` |
| Checkpoint (control) | `vm-backup-20261014-exp07-r01-2026-10-14_20-09-43` | — (libvirt checkpoint) | 20:09:43Z | kept |
| PVC (control destination) | `vm-backup-pvc-20261014-exp07-r01` | `not recorded` | 20:09:43Z | kept, `Bound`; usage 86,882 MiB (du-inclusive of PV overhead) |
| VirtualMachineBackup (surgery, r01 leg B) | `vm-backup-enospc-20261014-exp07-r01` | 5ace84fe-8e29-4255-b1f7-39da274785a5 | 20:10:50Z | kept; `Done=True` 20:10:53Z (3 s), type `Incremental` — **the defect** |
| Checkpoint (surgery) | `vm-backup-enospc-20261014-exp07-r01-2026-10-14_20-10-50` | — (libvirt checkpoint) | 20:10:50Z | kept; the tracker advanced onto it |
| PVC (surgery destination) | `vm-backup-pvc-enospc-20261014-exp07-r01` | pvc-b60d4683-06a1-436e-864e-a64f463119c4 | ~20:10Z (pre-filled before the backup) | kept as evidence: holds `filler.img` 2,726,297,600 B + the 4,456,448 B shell |
| Backup object finalizer | `backup.kubevirt.io/vmbackup-protection` on the surgery backup | — | — | still present (the object was never cleaned up) |
| Reproductions (same day) | surgery backups `vm-backup-enospc-20261014-exp07-r02` (UID f195bdd5-a973-4d7d-961f-f590d1d689e5, created 20:30:23Z, `Done=True` 20:30:26Z) and `vm-backup-enospc-20261014-exp07-r03` (UID bc968532-ec71-4d80-8c7e-a6df6eb34c5e, created 20:40:46Z, `Done=True` 20:40:49Z), destinations `vm-backup-pvc-enospc-20261014-exp07-r02` (UID pvc-f0a5f020-c3f0-404b-8b85-4912547af06f) and `…-r03` | see left | 20:30–20:49Z | kept; r02's target again held the same filler + 4,456,448 B shell |
| Guest workload (context) | 1,000 files / 17,431 MiB on the RHEL 9 VM's root disk (`rootdisk`/`vda`, virtual size 79.7 GiB) | — | ~20:09Z | kept with the VM |

### Steps

**Step 1 — Setup: CBT-enabled VM with a workload that takes tens of seconds to copy, plus the destination PVCs.**
When: before anything else.
```bash
oc get vmi vm-20261014-exp07-r01 -n vm-cbt-demo \
  -o jsonpath='{.status.phase}{" "}{.status.changedBlockTracking.state}{"\n"}'
oc get vmbackuptracker vm-tracker-20261014-exp07-r01 -n vm-cbt-demo \
  -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'   # empty before the first backup
```
What you must see: VMI `Running` with `changedBlockTracking.state` = `Enabled`; a tracker with an empty
`latestCheckpoint`.

**Step 2 — Control leg: take a normal full backup, so you have a baseline duration and a valid chain head.**
When: before the injection.
```bash
oc apply -f - <<'YAML'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-backup-20261014-exp07-r01
  namespace: vm-cbt-demo
spec:
  pvcName: vm-backup-pvc-20261014-exp07-r01
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261014-exp07-r01
YAML
oc get vmbackup vm-backup-20261014-exp07-r01 -n vm-cbt-demo \
  -o jsonpath='{.status.type}{" "}{.status.conditions[?(@.type=="Done")].status}{" "}{.status.conditions[?(@.type=="Done")].reason}{"\n"}'
oc debug node/<node> -- chroot /host bash -c 'du -sm /var/hpvolumes/csi/pvc-<control-pvc-uid>'
```
What you must see: type `Full`, `True Successfully completed VirtualMachineBackup`, and a destination
usage in the tens of GiB (recorded: 86,882 MiB, 64 s duration). **Record the duration** — it is the
yardstick the defect is measured against.

**Step 3 — (Injection) Pre-fill the surgery destination: this is the whole injection, and its timing is the
point.** When: **after the control leg is terminal and before the surgery backup object exists.**
```bash
# create the 4 Gi destination PVC for the surgery leg first (recorded object name), then:
oc debug node/<node> -- chroot /host bash -c \
  'df -h /var/hpvolumes/csi && fallocate -l 2600M /var/hpvolumes/csi/pvc-b60d4683-06a1-436e-864e-a64f463119c4/filler.img'
# record the pre-fill timestamp now — it must precede the backup creation
date -u +%Y-%m-%dT%H:%M:%SZ
oc debug node/<node> -- chroot /host bash -c \
  'ls -l /var/hpvolumes/csi/pvc-b60d4683-06a1-436e-864e-a64f463119c4 && df -h /var/hpvolumes/csi'
```
**Window/injection point: it opens at the pre-fill (a written filler leaving far less free space than
the expected copy — recorded ~127 MiB free against a 17.4 GiB copy; r02 pre-fill 20:30:23Z) and closes
when the surgery backup object is created.** Fail-closed pre-check: the destination PVC is `Bound`, the
control backup is terminal, and the free space inside it is far below the copy size. Post-check: `ls -l`
shows the filler and `df` shows the small margin. **Measure free space on `/var/hpvolumes/csi` itself —
its parent `/var/hpvolumes` is a different filesystem and gives the wrong answer.**

**Step 4 — Trigger the defect: create the surgery backup against the pre-filled destination.** When: right
after the post-check above (recorded: 20:10:50Z, seven seconds after a same-second pre-fill).
```bash
oc apply -f - <<'YAML'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-backup-enospc-20261014-exp07-r01
  namespace: vm-cbt-demo
spec:
  pvcName: vm-backup-pvc-enospc-20261014-exp07-r01
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261014-exp07-r01
YAML
oc get vmbackup vm-backup-enospc-20261014-exp07-r01 -n vm-cbt-demo -o yaml | grep -A12 '^status:'
```
What you must see: `Done=True`, reason `Successfully completed VirtualMachineBackup`, type
`Incremental`, and **zero warning conditions** — reached in seconds, not tens of seconds.

**Step 5 — Read-only demonstration of the defect.**
```bash
# 5a. the destination holds no data: filler + a few-MiB shell (recorded: 2,726,297,600 B + 4,456,448 B)
oc debug node/<node> -- chroot /host bash -c \
  'ls -l /var/hpvolumes/csi/pvc-b60d4683-06a1-436e-864e-a64f463119c4/vm-20261014-exp07-r01/'
# 5b. the shell is an overlay that points at the LIVE VM disk
oc debug node/<node> -- chroot /host bash -c \
  'qemu-img info /var/hpvolumes/csi/pvc-b60d4683-06a1-436e-864e-a64f463119c4/vm-20261014-exp07-r01/vm-backup-enospc-20261014-exp07-r01-rootdisk.qcow2'
# 5c. the chain advanced onto the empty backup
oc get vmbackuptracker vm-tracker-20261014-exp07-r01 -n vm-cbt-demo \
  -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'
# 5d. the error is nowhere: no ENOSPC in status, events or VMI status
oc get vmbackup vm-backup-enospc-20261014-exp07-r01 -n vm-cbt-demo -o yaml | grep -i 'no space'   # expect no match
oc get events -n vm-cbt-demo --sort-by=.lastTimestamp | grep -iE 'VirtualMachineBackupFailed|no space'
```
What you must see: a `virtual size` far larger than the `disk size` (recorded: `virtual size 79.7 GiB`,
`disk size 7.94 MiB`) and a `backing file:` line naming the launcher's live disk; a tracker
`latestCheckpoint` equal to the surgery backup's checkpoint; and no ENOSPC match — only the ghost event
`VirtualMachineBackupFailed("Backup has failed: VMI backup status was lost")` in the same second as the
completion.

**Step 6 — The discriminating check: restore the shell with the source unavailable.** When: after 5a–5d.
```bash
# from a container/pod where the launcher-internal backing path does not exist (VM gone / disk unavailable)
qemu-img convert -O raw <shell-qcow2> /tmp/restored.raw
```
What you must see: failure with `Could not open backing file: ... No such file or directory`. **Do not
substitute the alive-restore here:** with the VM running, `qemu-img convert` succeeds in ~16 s and the
first GiB matches the live source disk (recorded md5 `45268f192734f13ed74d855a43cc23e1`) — it reads
through the overlay and proves nothing.

**Step 7 — Recovery: there is none inside the product.** When: after capturing the evidence (the shells are
the defect, so keep a copy before cleaning up).
```bash
oc delete vmbackuptracker vm-tracker-20261014-exp07-r01 -n vm-cbt-demo
# next backup falls back to Full — re-take it on a correctly sized destination
oc apply -f - <<'YAML'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-backup-refresh-20261014-exp07-r01
  namespace: vm-cbt-demo
spec:
  pvcName: vm-backup-pvc-20261014-exp07-r01
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261014-exp07-r01
YAML
```
What you must see: the fresh backup is type `Full` and its destination grows to tens of GiB. What this
does **not** restore: the backups the corrupt chain advanced onto remain empty shells, and the space the
filler and shells consume stays consumed until you clean it up. Discarding the tracker is the recovery
path verified for chain corruption in the companion EXP-6 finding — it is a workaround, not a fix.

## Current behaviour (observed)

- When a push-mode VirtualMachineBackup's destination PVC runs out of space during the live copy
  (after checkpoint creation), the backup completes with **Done=True and reason "Successfully completed
  VirtualMachineBackup"** while the destination contains only a metadata-sized qcow2 shell — in the
  reproducer, **4,456,448 bytes (≈4.25 MiB) against a 17,431 MiB workload (0.02%)**. The copy "window"
  was 3 seconds (a real copy of this workload takes 64 s). The underlying ENOSPC error never surfaces
  in the backup object's conditions, reason, or events — the only failure trace is the misleading
  Warning event `VirtualMachineBackupFailed: "Backup has failed: VMI backup status was lost"` fired at
  the same instant.
- Compounding the corruption: the tracker's `latestCheckpoint` **advances to the empty backup's
  checkpoint**, so subsequent incremental backups silently chain off a 4 MiB shell.
- **Mechanism (r02, live-verified):** the "successful" backup is a qcow2 overlay whose BACKING FILE is
  the LIVE VM's disk (`/var/run/kubevirt-private/libvirt/qemu/cbt/rootdisk.qcow2`). The copy never
  ran — the target holds only the overlay metadata. A restore against a deleted/sourceless VM (the
  disaster scenario a backup exists for) fails with `Could not open backing file` — the backup restores
  NOTHING.
- **Actual behaviour, restated as the draft recorded it**: `Done=True` with a pure success reason; zero
  warning conditions on the CR; no ENOSPC text anywhere (object, events, VMI status) — only the generic
  "VMI backup status was lost" Warning event; destination at 0.02% of the workload; chain advanced onto
  the empty backup.
- **Decisive verbatim strings / outputs** (each an independent artifact observation):
  `Successfully completed VirtualMachineBackup` (terminal reason);
  `Backup has failed: VMI backup status was lost` (the ghost Warning event at 20:10:53Z);
  `virtual size 79.7 GiB, disk size 7.94 MiB, backing file: /var/run/kubevirt-private/libvirt/qemu/cbt/rootdisk.qcow2` (`qemu-img info` on the shell);
  `Could not open backing file: ... No such file or directory` (disaster-case `qemu-img convert`).
- **End-to-end restore evidence (r02 reproduction, 2026-10-14):** reproduced with a workflow-driven
  lifecycle: control full (53 s, real data) → surgery backup on the pre-filled 4 Gi target →
  **Done=True "Successfully completed VirtualMachineBackup"** again; target again holds the
  2,726,297,600-byte filler + a **4,456,448-byte qcow2**; pre-fill timestamp (20:30:23Z) recorded
  BEFORE backup creation (injection-window proof).
- **Restore-while-alive (r03):** with the VM still running and the backing file reachable,
  `qemu-img convert` of the shell completes in **15.8 s** and produces a full-size 79.7 GiB raw image
  whose first GiB is byte-identical (md5 `45268f192734f13ed74d855a43cc23e1` match) to the live source
  disk — the "restore" simply reads through the overlay to the running VM's disk. **Normal restore
  verification cannot detect this corruption class while the VM lives; only the disaster case fails —
  exactly when the backup is needed.**

## Expected behaviour (contract)

- The failed copy terminal-fails the backup CR with the real reason (e.g. "No space left on device").
- The tracker does not advance from a failed copy.
- (From the run's own acceptance table, preserved:) the surgery leg's terminal state must reflect the
  copy failure, the real error must be visible to the operator, the destination must hold the workload,
  and chain integrity must be preserved.

**Acceptance check.** With the source VM gone (its live disk unavailable), restoring the destination
of an ENOSPC-limited backup must either succeed with the workload or be impossible to mistake for
success: the reviewer runs the restore and observes that a *fully successful* backup whose destination
grew proportionally is the only one that restores. Operationally: after the fix, a backup whose copy
cannot complete shows a non-success terminal condition carrying the ENOSPC reason, and
`latestCheckpoint` for the chain is unchanged.

## Impact, workaround and data safety

- **Functions lost / how an operator notices (or fails to).** The protection copy for that backup —
  and, through the advanced checkpoint, the whole subsequent chain — is worthless, while every
  standard surface (CR conditions, reason, tracker, VMI state) reports health. The only operator-visible
  signal is a Warning event that reads as a benign completion race ("status was lost") and that
  customers are trained to ignore because it also fires on healthy completions. Nothing detects the
  loss until a disaster restore is attempted.
- **Blast radius.** Per-chain, per-VM: the affected backup plus every later incremental rooted in it.
  No guest impact (the VM stays healthy) and no source-data impact.
- **Data safety.** **The data path that matters is at risk**: the backup image holds no source data, and
  the overlay points at the live VM's disk — so once that disk is gone, the backup restores nothing
  (`Could not open backing file`). The *live* VM's data is untouched; what is lost is the ability to
  recover it. This is a silent data-protection failure, the worst class for a backup feature.
- **Workaround / operator runbook.** None inside the product: the corrupt chain must be manually
  discarded (delete the tracker; the next backup falls back to Full — the recovery path verified for
  chain corruption in the companion EXP-6 finding) and then re-taken on correctly sized storage.
  Detection heuristic for operators (from the run's customer recommendation): a "successful" backup
  whose duration is implausibly short for the VM's data size, or whose destination usage did not grow
  proportionally — monitor destination growth per backup as a canary. Cost: the lost chain must be
  re-copied from scratch (a full backup), and the shell/filler space stays consumed until cleaned up.
  It does not fix the defect and it does not detect an already-corrupted historical chain.
- **Frequency.** Deterministic whenever the destination cannot hold the copy (3/3 campaign run labels):
  in production that means any undersized destination — a sizing decision that the product offers no
  guidance for, and which this same campaign demonstrated is easy to get wrong (an incremental copy is
  sized by the dirty set, not by the logical change — see the CBT-F-04 contract ticket family).
- **Unknowns this ticket deliberately does not claim.** Whether the job-stats `succeeded` flag is the
  only missed signal or whether the write error is also available somewhere the handler could read;
  whether an asynchronous post-completion write could ever populate the target after `Done=True` (no
  such behaviour was observed — the target's mtime is the run's start time and the tracker had already
  advanced); whether other error classes (I/O error, device removal) take the same silent path.

## Evidence

**Artifact index** (repository-relative; "raw" = API/log capture, "derived" = run report):

| Artifact | What it carries | UTC | Type |
|---|---|---|---|
| `cbt-chaos/scenarios_v2/CBT-EXP-07/runs/20261014-exp07-r01/legA-full-backup.yaml` | control leg: `Done=True`, success reason, 64 s — proves the harness path and the baseline | 20:10:47Z | raw |
| `…/20261014-exp07-r01/legA-target-usage-mib.txt` | control destination usage `86882` (MiB, du-inclusive of PV overhead) | 20:10Z | raw |
| `…/20261014-exp07-r01/legB-backup.yaml` | surgery leg: `Done=True`, reason `Successfully completed VirtualMachineBackup`, type `Incremental` — the defect's status surface | 20:10:53Z | raw |
| `…/20261014-exp07-r01/legB-target-files.txt` | destination contents: `filler.img` 2,726,297,600 B + `…rootdisk.qcow2` **4,456,448 B** | 20:10Z | raw |
| `…/20261014-exp07-r01/legB-target-usage-mib.txt` | destination usage `2608` MiB (includes the filler) — the "0.02% of the workload" figure | 20:10Z | raw |
| `…/20261014-exp07-r01/legB-prefill.txt` | `df` of the hostpath filesystem at pre-fill: `/dev/sdb … /var/hpvolumes/csi` (92% used, 130,291 MiB avail) — the capacity trap | pre-fill | raw |
| `…/20261014-exp07-r01/observer/surgery-backup.jsonl` | backup watch stream: `Progressing` → `Done` inside the same second, and the absence of any ENOSPC text | 20:10:50–20:10:53Z | raw |
| `…/20261014-exp07-r01/observer/control-backup.jsonl` | control-leg backup watch (real copy window) for the duration comparison | 20:09–20:10:47Z | raw |
| `…/20261014-exp07-r01/observer/events-surgery.jsonl`, `observer/events-vm.jsonl` | surgery-leg events: the ghost `VirtualMachineBackupFailed("Backup has failed: VMI backup status was lost")` and the absence of any other failure event | 20:10:53Z | raw |
| `…/20261014-exp07-r01/observer/vmi.jsonl` | VMI `backupStatus` start/end (20:10:50 → 20:10:53Z) and guest health (`Running`/`Ready`/`AgentConnected` throughout, no restart/migration) | 20:09–20:11Z | raw |
| `…/20261014-exp07-r01/observer/tracker.jsonl` | `latestCheckpoint` advanced from the control's checkpoint to the surgery backup's checkpoint | 20:10:50–20:10:53Z | raw |
| `…/20261014-exp07-r01/test-run-report.md` | verdict `FAIL (silent-corruption defect found)`, experiment identification, UTC timeline, acceptance-vs-outcome table, engineering/customer recommendations, harness findings | run window | derived |
| `…/20261014-exp07-r02/prefill.txt` | second reproduction: pre-fill on the same filesystem (92% used) | pre-backup | raw |
| `…/20261014-exp07-r02/surgery-target-files.txt` | second reproduction's destination: same 2,726,297,600 B filler + 4,456,448 B qcow2 | 20:30Z | raw |
| `…/20261014-exp07-r02/surgery-target-usage-mib.txt`, `…/20261014-exp07-r02/surgery-backup.yaml`, `…/20261014-exp07-r02/chain-incremental.yaml` | usage, surgery backup status, and the post-recovery chain leg | 20:30Z+ | raw |
| `…/20261014-exp07-r03/surgery-backup.yaml`, `…/20261014-exp07-r03/alive-restore-info.txt` | third instance + the restore-descriptor of the shell (`virtual size 79.7 GiB (85590016000 bytes)`, `disk size 8.19 MiB`, `backing file: /var/run/kubevirt-private/libvirt/qemu/cbt/rootdisk.qcow2`) | 20:40Z | raw |
| `…/20261014-exp07-r03/trigger.log` (lines 55–59) | the alive/disaster restore triad: `qemu-img convert` in 15.8 s, first-GiB md5 `45268f192734f13ed74d855a43cc23e1` identical to the live source; disaster case fails `Could not open backing file` | 20:4x–20:5xZ | raw |
| Upstream/source anchors (not artifacts of this run) | kubevirt#17578 (`succeeded:false` `DOMAIN_JOB_COMPLETED` recorded as success; closed rotten without a fix); source: `pkg/virt-launcher/virtwrap/storage/backup.go` `HandleBackupJobCompletedEvent` (event-type-only switch; job-stats `succeeded` unexamined) and the tracker update path in `pkg/storage/cbt/backup.go` | — | draft claim (read from the v1.8.4 tree) |

**UTC timeline** (setup → precondition → injection → effect → failure → recovery); the run's own
timeline is preserved here in full:

| # | Time (UTC), 2026-10-14 | Event | Source |
|---|---|---|---|
| 1 | ~20:09Z | VM ready with the 17,431 MiB workload; control target prepared | `test-run-report.md` |
| 2 | 20:10:47Z | **Control**: full backup `Done` after 64 s, real data on the target (`86,882` MiB usage) | `legA-full-backup.yaml`, `legA-target-usage-mib.txt` |
| 3 | ~20:10Z (pre-fill; r02: 20:30:23Z) | **Injection (capacity constraint)**: surgery target pre-filled to ~127 MiB free, **before** the backup object is created | `legB-target-files.txt`, `legB-prefill.txt`; r02 `surgery-target-files.txt` (20:30Z) |
| 4 | 20:10:50Z | **Trigger**: surgery backup created; checkpoint creation succeeds (needs only metadata space) | `observer/surgery-backup.jsonl`; `observer/vmi.jsonl` (backupStatus start) |
| 5 | 20:10:50 → 20:10:53Z | **Effect**: the "copy" window is 3 s — versus 64 s for the control; the destination never grows beyond the overlay metadata | `observer/surgery-backup.jsonl`; `legB-target-files.txt`; `legB-target-usage-mib.txt` |
| 6 | 20:10:53Z | **Failure (silent)**: `Done=True` + reason `Successfully completed VirtualMachineBackup`; zero warning conditions; the only failure-shaped event is the ghost `VirtualMachineBackupFailed("Backup has failed: VMI backup status was lost")` in the same second | `legB-backup.yaml`; `observer/events-surgery.jsonl` |
| 7 | 20:10:53Z | **Chain corruption**: tracker `latestCheckpoint` advances onto the empty backup's checkpoint | `observer/tracker.jsonl` |
| 8 | 20:30:23Z / 20:40:46Z | **Reproductions**: r02 (workflow-driven) and r03 (surgery + restore triad) produce the same state | r02/r03 artifacts above |
| 9 | r02/r03 (20:3x–20:5xZ) | **Data-truth check**: `qemu-img info` shows the overlay's backing file is the live source disk; restore-while-alive "succeeds" (15.8 s, md5 match) because it reads through to the running VM; the disaster-case restore fails `Could not open backing file` | `alive-restore-info.txt`; `trigger.log:55-59` |
| 10 | after r02/r03 | **Recovery**: none in-product — the chain was discarded/re-taken on correctly sized storage (the companion EXP-6 finding's verified path for chain corruption) | run report; companion ticket |

**Retained state.** The evidence pack was preserved entire: the control and surgery backup objects,
the tracker streams (showing the bad advancement), both destination PVCs with their contents
(`filler.img` + the 4 MiB shell — the objects that *are* the defect), and the observer streams. The
r01 experiment's `summary.json`/`run.json` were **not** written (direct-drive run; the report records
this as a harness finding and reconstructs the run from the trigger log and observer streams). The
shells were retained rather than cleaned up, which is why the byte-level comparison against the
workload is possible in the pack. Nothing was deleted to hide the state; the VM was left running for
the alive-restore test and then handled by the campaign's normal teardown (outside this pack).

## Negative results and what would falsify this ticket

- **Refuted: "the copy ran fast because the VM was idle."** The same VM's control backup on the same
  cluster took 64 s (r01) / 53 s (r02) and produced tens of GiB on the destination; the surgery leg
  took 3 s and produced 4.25 MiB. The difference is the destination capacity, not the workload.
- **Refuted: "the destination filled only afterwards / ordering was wrong."** The pre-fill timestamp
  (r02: 20:30:23Z) is recorded **before** the backup object was created — the space wall existed before
  the copy started.
- **Refuted: "the CR exposes the failure somewhere subtle."** No ENOSPC text exists in the backup
  watch stream, the surgery events, or the VMI stream; the CR has zero warning conditions and a pure
  success reason.
- **Refuted: "restore verification would catch this."** With the VM alive, `qemu-img convert` of the
  shell succeeds in 15.8 s and its first GiB md5 is identical to the live source disk — i.e. it reads
  through the overlay. **Normal restore verification is a false negative for this class**; only the
  sourceless (disaster) restore fails.
- **Refuted: "the harness path is at fault."** The control legs on the same harness produced correct
  backups with real data, and r02/r03 re-produced the defect under the workflow-driven lifecycle rather
  than only by direct drive.
- **Limits of this evidence (stated, not refuted).** The control leg's usage figure is `du`-inclusive
  of PV overhead; the r01 summary/run JSON are missing (harness finding); all three reproductions are
  from one campaign on one cluster/build; the mechanism at code level rests on the upstream/source
  anchors, not on instrumented execution.
- **Falsifiers.** This ticket is wrong, or a non-issue, if any of the following holds:
  1. The destination is shown to gain the data after `Done=True` (an asynchronous completion) — no such
     behaviour was observed, and the tracker had already advanced.
  2. Restoring the shell with the source VM gone is shown to work (i.e. the overlay is self-contained
     in some cases) — the observed disaster-case failure says otherwise for this shape.
  3. The reported success is shown to be *contractually* correct (e.g. `Done=True` means "the job
     ended", with success only in the reason string) — then the defect is the missing machine-readable
     failure status and a documented contract, not the success itself; that is a triage question below.
  4. The ENOSPC is shown to be detectable by a documented pre-copy check that this run failed to use —
     that would make this an operator error, not a product defect (no such check exists in the observed
     surface).

## Additional feedback (reporter's notes)

- **Preserved recommendations from the run.**
  - Engineering (critical, upstream-worthy): (1) inspect the backup job's `succeeded` flag (and/or
    target-write errors) on `DOMAIN_JOB_COMPLETED` — a failed copy must terminal-fail the CR with the
    real reason (e.g. "No space left on device"), never report success; (2) do not advance the
    tracker's `latestCheckpoint` from a backup whose copy failed; (3) the "VMI backup status was lost"
    event should not be the only failure trace — it currently masks real copy errors behind a generic
    message.
  - Customer: until fixed, treat any suspiciously fast "successful" backup as suspect (compare duration
    against historical baselines) and monitor destination usage growth per backup as a canary; a backup
    completing in seconds for a multi-GiB VM has almost certainly written nothing.
- **Open triage questions.** (a) Is `Done=True` intended as "the reconciler finished" rather than "the
  backup succeeded"? If so it must be documented and a machine-readable failure signal added; if not,
  the success reason on a failed copy is itself the bug. (b) Should the chain advance be gated on a
  destination-side verification (e.g. size/bytes written) rather than on the job outcome alone?
  (c) Is a dirty-set/capacity pre-check feasible before the copy starts (see the CBT-F-04 sizing
  family)? (d) Does the same silent path apply to other error classes (I/O error, device removal)?
- **Smallest experiments that would settle the open points.** (1) Re-run the reproduction and watch
  whether **any** `NodeUnstage`/job-stats signal reaching the handler contains the failure (would move
  the fix site). (2) Run the disaster restore explicitly as part of the reproducer's acceptance script
  (the run recorded this as an untested follow-on for r01 and then executed it in r02/r03 — make it
  mandatory, since the alive-restore passes and hides the defect). (3) Take one control backup onto a
  destination with *just* enough space and confirm the boundary behaviour (success vs silent shell) to
  bound the risk window.
- **Cross-references.**
  - Companion product ticket: `cbt-chaos/scenarios_v2/CBT-EXP-06/bugs/backup-cr-livelock-on-missing-per-disk-bitmap.md`
    — the same "VMI backup status was lost" ghost event masks that defect's real cause; both tickets
    should reference the event-masking issue so a fix covers both.
  - Sizing context (different scenario, different defect, same product family):
    `cbt-chaos/scenarios_v2/CBT-F-04/bugs/cbt-incremental-copy-size-is-peak-dirty-volume.md` — the
    destination-sizing contract gap that makes undersized destinations easy to create.
  - Harness/tooling gaps (clearly separate, **not** part of this ticket): r01's `summary.json`/`run.json`
    were not written for a direct-drive run (reconstructed from the trigger log + observer streams);
    the pre-fill overshot the intended free-space margin (127 MiB vs ~1,500 MiB intended — tighter than
    planned, verdict unaffected); the control-leg usage figure is `du`-inclusive of PV overhead. These
    belong to the scenario/harness lane.
- **Environment-specific notes for the next reproducer.** (a) Measure free space on `/var/hpvolumes/csi`
    and not on its parent — they are different filesystems, and a parent measurement gives the wrong
    answer. (b) The destination must be pre-filled *before* the backup object exists, otherwise the
    checkpoint may not be created and the chain never advances (a different, less severe outcome).
    (c) Do not rely on the workflow's restore verification while the VM is alive — it will pass.
    (d) Event timestamps are second-granularity; use the observer stream ordering plus the VMI
    `backupStatus` start/end for sub-second claims.

## Sanitisation checklist

- [x] No credentials, tokens, kubeconfig contents or private keys — none quoted.
- [x] No private hostnames or absolute host paths — the node is genericised as `<node>`; the
      filesystem path `/var/hpvolumes/csi` is given as the measured pool identifier needed to interpret
      the capacity figures (not a user's data path), and the absolute paths inside verbatim product
      output (`backing file: /var/run/kubevirt-private/libvirt/qemu/cbt/rootdisk.qcow2`,
      `Could not open backing file: …`) are quoted as product output, abbreviated.
- [x] No broad selectors (names or run-scoped labels only) — every command in the steps is scoped by the
      run's exact backup/tracker/PVC names or by the node that holds the PV.
- [x] No destructive commands other than the documented, scoped workaround — the recovery (discard the
      tracker so the next backup falls back to Full, then re-take the backup) is the only deletion
      described, is scoped to the chain it repairs, and is labelled with what it does not restore; no
      cluster-cleanup commands appear.
- [x] Commands are the ones actually validated (illustrative ones are labelled) — the pre-fill, backup
      creation and inspection commands are the ones the campaign used; the note above the steps says
      which command shapes are re-creations and that this scenario has no chaos injection.

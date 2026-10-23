# [Bug] A backup whose destination runs out of space mid-copy reports success while the destination holds no data

> **PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW.** This is a chaos experiment
> intent derived from the CBT campaign, written so an engineer who has never
> seen this cluster, this repository or its harness can reproduce and triage it
> from this file alone. It is **not a filed ticket**: no Jira key exists for it
> and none is invented. Historical observations are cited as historical, with
> their run labels; this execution's outcome is decided by the independent
> Analyst from this attempt's raw evidence and is deliberately **not** asserted
> here, and no old evidence is presented as this attempt's result.

## What this is, in one paragraph

A push-mode changed-block-tracking (CBT) backup of a running VM copies the disk
into a destination volume. If that destination runs out of space *while the copy
is in flight* (after the checkpoint exists), the backup is expected to fail
loudly. Instead it can reach `Done=True` with the reason
`Successfully completed VirtualMachineBackup` while the destination contains only
a metadata-sized qcow2 "shell" that stores no data of its own and points at the
**live** VM disk — so the backup looks restorable only while the VM is alive.
The change-tracking bookmark ("tracker", the object that remembers the chain's
latest checkpoint) then advances onto the empty backup, so every later
incremental builds on nothing. No `no space` text appears in any object, event
or status. This experiment reproduces that window deterministically on a
disposable cluster and files the raw evidence.

**When → then → expected**

- **When** the product is taking a push-mode CBT backup of a RHEL 9 VM into a
  destination PVC whose capacity cannot hold the copy, and that destination is
  already nearly full when the backup object is created.
- **And** the disruption **CBT-EXP-07** is applied (chaos bundle
  `cbt-chaos/scenarios_v2/CBT-EXP-07/`; **not** a krknctl scenario — see
  "Why not a krkn scenario" below): a distinct 4 GiB destination PVC
  (`vm-backup-pvc-enospc-<lifecycle>`, storage class
  `ocs-storagecluster-ceph-rbd`, so the request **is** the block-image size) is
  created, bound, and pre-filled with a single ~2600 MiB filler file so that at
  most ~1500 MiB remain; the guest is then mutated with new workload files
  totalling at least twice that remaining capacity; **only then** is the backup
  object (`vm-backup-enospc-<lifecycle>`, source = the run's existing
  `VirtualMachineBackupTracker`) created against that destination.
- **Then (current behaviour):** historically the backup reached `Done=True` with
  reason `Successfully completed VirtualMachineBackup` within seconds, the
  destination held a ~4.25 MiB qcow2 overlay whose backing file is the live VM
  disk, the tracker advanced onto that empty backup, and no `no space` string
  appeared anywhere — the only trace was a `Warning` event
  `VirtualMachineBackupFailed: Backup has failed: VMI backup status was lost`
  in the same second as the success. **This execution's own behaviour is not
  recorded here.**
- **Expected behaviour:** a copy that cannot hold the data must end the backup
  with a failure reason naming the real error, must not report success, and must
  not advance the tracker onto an unusable checkpoint. A backup that copied no
  data must never be reported as a successful restore point.

## Iteration 2 design change (attempt 2; repair after an INVALID injection)

The first attempt of this bundle (`runs/17-10-2026-05-59-03-vm-20261017053225-brave-ocean-efa8-late-enospc-iteration-1/`)
was graded **INVALID** by the independent Analyst: the injection *action* was
performed as approved, but the hunted fault never engaged. Two design defects
were recorded, and this iteration repairs exactly those two.

1. **No dirty data → the copy never had to fill the destination.** The surgery
   backup chains off the control checkpoint through the shared
   `VirtualMachineBackupTracker`, so a guest that is bit-identical between the
   legs produces a zero-delta **Incremental**: attempt 1 copied
   `6,029,312` bytes in ~78 ms against a 1496 MiB margin, reached `Done=True`
   with a success reason, and the destination was never stressed. The pipeline's
   own `expected copy > margin` check encoded a *full-copy* assumption the bundle
   never established. Repair: after the control full backup and before the
   surgery backup, the run writes **new** guest files totalling
   `clamp(2 x measured_margin, 512 MiB, 6144 MiB)` (18 MiB per file, so
   ~2.6–3.0 GiB and ~150 files at the measured margin) into a run-owned guest
   directory, with raw evidence (file count, bytes, sha256 manifest, unchanged
   baseline manifest digest, guest df before/after). The surgery Incremental's
   payload is then that dirty set, which exceeds the remaining capacity by
   construction.
2. **No enforced capacity bound → a "4 GiB PVC" bounded nothing.** On
   `cbt-demo-hpp` the request is not enforced per volume: attempt 1's control PV
   held 82.4 GiB on an 80 Gi request and the PV reported 1489 Gi capacity from
   the shared 1.5 TiB pool. A 4 GiB HostPath PVC therefore created no ENOSPC
   condition of its own. Repair: the surgery destination is
   `ocs-storagecluster-ceph-rbd` (provisioner
   `openshift-storage.rbd.csi.ceph.com`, pool
   `ocs-storagecluster-cephblockpool`), where the PVC request is the block-image
   size, so the filesystem inside the 4 GiB device returns ENOSPC when full. The
   control leg deliberately stays on `cbt-demo-hpp` (unchanged, 80 Gi target).

What that changes for measurement:

- The surgery leg's expected payload is the **recorded dirty set**, not the
  ~17.4 GiB guest workload and not the ~79.7 GiB preallocated disk. The
  "usage << expected with Done=True + success" rule is therefore evaluated
  against `legB-guest-mutation.txt` (bytes written as new guest data) and the
  in-pod destination listing (`legB-target-usage-mib.txt`,
  `legB-target-files.txt`), never against the baseline workload size.
- The destination's capacity and usage are read **inside a pod that mounts the
  claim** (`df`/`du`/`find -ls`), plus the PVC/PV/CSI API chain (Bound,
  request == capacity, driver, pool, image). An RBD image has no host directory,
  so the node-debug host probes used in attempt 1 are recorded N/A for this
  volume with that reason; they remain in use for the control HostPath PVC.
- The copy is expected to exhaust the destination at roughly half of its own
  payload (`margin / dirty ≈ 1/2` by the 2x rule). "Late" here means after the
  checkpoint and the backup object exist — the destination write failure happens
  inside the copy job started after `status.checkpointName` was armed — not a
  specific percentage of a full-disk copy. This attempt's own copy window and
  terminal state are recorded raw; no outcome is predicted here.

Known limits of the repaired design (stated, not worked around): the RBD
destination path (backup hotplug + copy into an RBD volume) has not previously
been exercised by this bundle on this cluster, so a failure to *start* the copy
would be a surface finding for the Analyst rather than a capacity verdict; and
the guest mutation writes real data into the disposable run VM, which therefore
holds the dirty set at terminal (rollback is `none` by design).

## At a glance

| Field | Value |
|---|---|
| Issue type | Bug (expected); becomes an Improvement only if this execution shows the failure is reported but merely mislabelled |
| Priority (proposed) | High — silent loss of a protection copy; unassigned pending triage |
| Severity class | data protection (silent corruption of the backup chain) + status truthfulness (failure recorded as success) |
| Owning component (suspected) | KubeVirt backup job-completion handling in the virt-launcher copy path and the tracker-update path — **suspected** |
| Component(s) proven involved | historically: the virt-launcher backup job produced a terminal success state plus a metadata-only qcow2 overlay, and the `VirtualMachineBackupTracker` update advanced `latestCheckpoint` onto it; the destination storage layer never surfaced the write error |
| Reproducibility | historical: `deterministic (3/3 archived run labels, 2026-10-14)`; this execution's reproducibility is not recorded yet |
| Status / confidence | historical confirmed behaviour; this execution unexecuted. Root cause at code level unproven (upstream anchor `kubevirt#17578`, closed rotten) |
| Blast radius | the affected backup and every later incremental rooted in it (a whole protection chain per VM); the guest VM itself stays healthy. Measured scope of the disruption: one 4 GiB Ceph RBD PVC (one 4 GiB block image, ~2600 MiB actually allocated in the shared `ocs-storagecluster-cephblockpool`), one run-owned transient filler pod, one run-owned transient measurement pod, one run-owned transient inspection pod, and at most ~6 GiB of new files under a run-owned directory in the disposable run VM |
| Data at risk? | the protection copy is at risk; the live VM's data is not touched by the disruption |
| Related scenario / execution | scenario ID `CBT-EXP-07`; historical runs `20261014-exp07-r01` (direct-drive), `20261014-exp07-r02` (workflow-driven), `20261014-exp07-r03` (alive-restore triad) — same-day reproductions on one cluster/build. This execution's attempts live under `cbt-chaos/scenarios_v2/CBT-EXP-07/runs/<attempt-id>/` |
| Affected versions | historical: OpenShift 4.22 / OpenShift Virtualization 4.22.12, `backup.kubevirt.io/v1alpha1`, push-mode backup, node-local HostPath destination. Iteration 2 uses a Ceph RBD destination (the destination storage layer is part of the perturbation, so conclusions are scoped to the storage class this attempt actually used). Measured matrix in **Environment** |

## Context (for an engineer new to this area)

- **What the feature does.** A push-mode CBT backup (1) creates a *checkpoint*
  and arms a per-disk *dirty bitmap* (the change-tracking map inside the running
  QEMU), (2) hot-plugs the destination volume into the running VM and copies the
  changed blocks from the VM's own launcher process, (3) detaches the
  destination and updates the chain's *tracker* object with the new checkpoint.
  The destination in iteration 2 is a Ceph RBD volume
  (`ocs-storagecluster-ceph-rbd`): the PVC request is the block-image size, so the
  figure that matters is that volume's own capacity — measured inside a pod that
  mounts the claim, never on the shared pool's numbers. (The control leg still
  uses the node-local HostPath class `cbt-demo-hpp`, where a PVC's files live as a
  directory on one worker node; that is why its usage is measured inside the PV's
  own directory and never on the pool's parent filesystem.)
- **Where the failure sits.** The authoritative state is the
  `VirtualMachineBackup`'s `status.conditions[]` (`Progressing`, `Done`) and the
  `VirtualMachineBackupTracker`'s `status.latestCheckpoint`. The observed
  failure is that these two say "healthy" while the destination holds nothing.
- **Observed surface vs. origin.** The surface is the backup CR's terminal
  condition plus the destination directory; the origin is inside the copy job.
  Historically the only failure-shaped trace was an event whose text reads like
  a benign status race and which also fires on healthy completions.
- **Why it matters.** Restore verification performed while the VM still runs
  cannot detect this class: the overlay reads straight through to the running
  source disk. The failure only becomes visible when the VM is gone — exactly
  when the backup is needed.
- **Capacity trap (harness-relevant).** For the control leg's HostPath class, the
  pool's CSI data directory (`/var/hpvolumes/csi`) is its **own** filesystem; its
  parent (`/var/hpvolumes`) is a different filesystem on the same node, so
  measuring free space on the parent gives the wrong answer. For the iteration-2
  RBD surgery volume the analogous trap is measuring the shared Ceph pool's free
  space instead of the volume's own 4 GiB image: the copy's bound is the image
  size, and the only place that is visible as filesystem capacity is inside a pod
  that mounts the claim.

### Why not a krkn scenario (disruption disclosure)

The disruption is a destination-capacity constraint that must exist **before**
the backup object exists, which no installed krkn scenario expresses. Checked on
the intended execution host against the installed tooling (krknctl v0.14.2-beta):

- `krknctl list available` offers `pvc-scenarios` as the closest fit, but its
  semantics are wrong here: it needs an already-mounted consumer pod, derives its
  fill from that mount's `df` (on this cluster the shared pool's filesystem,
  i.e. wrong blast radius), and it deletes its temporary file after
  `--duration`, which would undo the injection in the middle of the copy window.
- No installed scenario can create and pre-size a destination PVC before its
  backup object exists, none can write a sized dirty set into the guest, and the
  trigger framework cannot express that ordering.
- Therefore the approved mechanism is a bounded sequence of plain `oc` actions
  plus one run-owned, node-pinned, single-purpose filler pod that mounts only
  this run's own PVC, plus one bounded guest write through the run's existing
  guest SSH path. Read-only `oc` queries for the condition and the evidence are
  not a fault-action fallback.

## Environment (measured, not assumed)

| Layer | Component | Version / identifier | How obtained |
|---|---|---|---|
| Platform | OpenShift Container Platform (server and client) | 4.22.15 | `oc version` |
| Platform | Kubernetes API | v1.35.6 | `oc version` |
| Nodes | OS image / kernel / runtime | RHCOS 9.8 (kernel 5.14.0-687.48.1.el9_8) / cri-o 1.35.8 | `oc get node <node> -o json` |
| Nodes | topology in scope | one CBT worker (`<node>`) hosts the HostPath pool and every vm-cbt-demo launcher; the control HostPath PV is node-pinned by `topology.hostpath.csi/node`, while the surgery Ceph RBD PV carries no `nodeAffinity` (all pods are still placed on that worker for the run) | `oc get node`, `PV.spec.nodeAffinity` |
| Virtualization | OpenShift Virtualization | 4.22.12 | `oc get csv -A` |
| Virtualization | kubevirt observed version | operator image digest `sha256:2f654df4…29293` | `oc get kubevirt -n openshift-cnv -o jsonpath='{.items[0].status.observedKubeVirtVersion}'` |
| Backup API | CRD group / version | `backup.kubevirt.io/v1alpha1` | object `apiVersion` |
| Storage (in use) | StorageClass / provisioner / pool (control leg only) | `cbt-demo-hpp` / `kubevirt.io.hostpath-provisioner` / `cbt-demo-pool`, `volumeBindingMode: WaitForFirstConsumer` | `oc get sc cbt-demo-hpp -o json` |
| Storage (in use) | HostPath data directory | `/var/hpvolumes/csi` (its own filesystem) with one directory per PV, named by `PV.spec.csi.volumeHandle` (`pvc-<uuid>`) | read-only `oc debug node/<node> -- chroot /host` probes |
| Storage (in use) | CSI node plugin | DaemonSet `hostpath-provisioner-csi` (ns `openshift-cnv`), container `hostpath-provisioner` | `oc get pods -n openshift-cnv` |
| Storage (surgery destination, iteration 2) | StorageClass / provisioner / pool | `ocs-storagecluster-ceph-rbd` / `openshift-storage.rbd.csi.ceph.com` / `ocs-storagecluster-cephblockpool`, `fstype: ext4`, `volumeBindingMode: Immediate`, `allowVolumeExpansion: true`; the PVC request is the block-image size, so the filesystem inside a 4 GiB device returns ENOSPC when full. CephCluster `Ready`; measured `bytesAvailable` ≈ 105 TiB at preparation time | `oc get sc ocs-storagecluster-ceph-rbd -o json`; `oc get cephcluster -n openshift-storage -o json` |
| Storage (surgery destination, iteration 2) | PV shape | Ceph RBD PVs on this cluster carry **no** `nodeAffinity`; `csi.volumeHandle` = `0001-0011-openshift-storage-…-<uuid>`, `volumeAttributes.imageName` = `csi-vol-<uuid>`, `fsType: ext4` | `oc get pv -o json` (read-only, at preparation time) |
| Guest | OS / workload | RHEL 9; 1000 baseline files of 15–20 MiB (≈17.4 GiB) created by the lifecycle stage | `runs/<lifecycle-id>/run.json`, guest probe |
| Harness (internal only) | chaos tooling present but not used for the fault | `krknctl v0.14.2-beta` | `krknctl --version` |

## Reproducibility

- **Classification (historical):** `deterministic (3/3 archived run labels)`. The
  same effect appeared in each of three same-day reproductions, each with its own
  control leg that behaved correctly (real copy duration and real destination
  usage). This execution's classification is not recorded here.
- **Stability (historical):** exact every time — terminal success reason, a
  metadata-only overlay of a few MiB, a copy window measured in seconds against a
  control measured in tens of seconds, no `no space` text on any surface, and the
  tracker advancing. Varying: the exact shell byte count, the pre-fill margin and
  the guest mutation set.
- **Preconditions that must hold here:** a fresh RHEL 9 VM with CBT
  `Enabled`; a completed control full backup whose checkpoint the tracker
  references; a 4 GiB destination PVC on `ocs-storagecluster-ceph-rbd` (the
  request is the block-image size, so it is an enforced capacity bound) with its
  request equal to its capacity; a filler file that leaves at most ~1500 MiB
  free, written **before** the surgery backup object exists; and a guest dirty
  set of at least twice that remaining capacity, written after the control backup
  and **before** the surgery backup object. The surgery leg chains from the
  control checkpoint (historically it was recorded as `type: Incremental`), so
  its payload is exactly the guest's changed set — which is why the dirty set is
  mandatory and why a zero-delta guest reproduces nothing.
- **What breaks the repro:** omitting the guest mutation (a zero-delta
  Incremental copies only metadata — attempt 1 of this bundle did exactly that);
  writing the filler after the copy has started or after it ended; using the
  shared HostPath pool as the destination (its per-PVC request is not enforced, so
  the destination never runs out); leaving a consumer pod attached to the
  destination while the backup hot-plugs it.

## Steps to reproduce (exact commands and injection timing)

Prerequisites: a dedicated disposable cluster, `oc` authenticated with a
kubeconfig that is never printed, a checkout of this repository on the execution
host, and the bundle `cbt-chaos/scenarios_v2/CBT-EXP-07/`. Replace `<ns>`,
`<lifecycle>`, `<vm>`, `<node>` with your own values. The bundle derives every
object name from `<lifecycle>`; the commands below show what it does, in order.

**Step 1 — plan and identity (no cluster contact).**

```sh
LIFECYCLE_ID=<fresh-40-char-or-less-id> bash cbt-chaos/scenarios_v2/CBT-EXP-07/run.sh --plan
```

What you must see: `sequence`, `objects`, `injection`, `bounds_seconds`, and the
exact `run_id_command` for the evidence attempt ID.

**Step 2 — baseline state: fresh VM and the probe workload.**

```sh
make --no-print-directory vm-setup RUN_ID=<lifecycle> VM_OS=rhel9 \
  MANIFEST_VARIANT=default NAMESPACE=<ns> GUEST_BASE_FILE_COUNT=1000 \
  GUEST_FILE_SIZE_MIN_MIB=15 GUEST_FILE_SIZE_MAX_MIB=20 GUEST_INCREMENTAL_FILE_COUNT=4
oc get vm <vm> -n <ns> -o jsonpath='{.status.changedBlockTracking.state}{"\n"}'
```

What you must see: `Enabled` for CBT, VM `Ready=True`, and a guest probe
reporting `WORKLOAD_FILES=1000`.

**Step 3 — control leg: one full backup to a normal 80 Gi destination.**

```sh
make --no-print-directory vm-backup RUN_ID=<lifecycle> NAMESPACE=<ns>
oc get vmbackup vm-backup-<lifecycle> -n <ns> -o jsonpath='{.status.type} {.status.conditions[?(@.type=="Done")].status} {.status.checkpointName}{"\n"}'
oc get vmbackuptracker vm-tracker-<lifecycle> -n <ns> -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'
```

What you must see: `Full True`, a checkpoint name, and a tracker
`latestCheckpoint` equal to it. Record the control copy duration and the
destination usage — they are the yardstick.

**Step 4 — (injection, part 1) create the 4 Gi surgery destination.**

```sh
oc create -f /path/to/rendered-surgery-pvc.yaml    # name vm-backup-pvc-enospc-<lifecycle>, storageClass ocs-storagecluster-ceph-rbd, 4Gi
oc get pvc vm-backup-pvc-enospc-<lifecycle> -n <ns> -o jsonpath='{.status.phase} {.spec.volumeName} {.status.capacity.storage}{"\n"}'
oc get pv <pv> -o jsonpath='{.spec.csi.driver} {.spec.csi.volumeHandle} {.spec.csi.volumeAttributes.imageName}{"\n"}'
```

What you must see: `Bound`, a PV name, capacity `4Gi` equal to the request, and
driver `openshift-storage.rbd.csi.ceph.com` with an `imageName`. **Note for the
reproducer:** this storage class binds `Immediate`, so no consumer is needed to
make the PV exist; the volume is still filled by a pod that mounts it (Step 5),
because the archived node-debug `fallocate` needs a mounted filesystem. The
capacity bound is the 4 GiB image size at the block layer — the filesystem inside
it returns ENOSPC when full, whatever the shared Ceph pool still has free.

**Step 5 — (injection, part 2) fill the destination before the backup exists.**

```sh
oc create -f /path/to/filler-pod.yaml   # node-pinned, mounts ONLY vm-backup-pvc-enospc-<lifecycle> at /data
oc logs pod/<filler-pod> -n <ns>        # prints the tool used, its UTC stamp, the filler size and df/du of the mount
oc delete pod <filler-pod> -n <ns> --wait=true
```

What you must see: the pod `Succeeded` with a filler of ~2600 MiB inside `/data`,
`df -B1 /data` reporting a ~4.0 GB filesystem of which at most ~1500 MiB is
available, and exactly one filler file in the mount listing. **Measure the
destination from inside its own mount; an RBD volume has no host directory.**
Do not proceed while any pod still mounts the destination.

**Step 6 — (injection, part 3) write the guest dirty set.**

```sh
# bundle helper; target_MiB = clamp(2 x measured margin MiB, 512, 6144)
bash cbt-chaos/scenarios_v2/CBT-EXP-07/guest-mutate.sh <lifecycle> <target_MiB> 18
```

What you must see: `MUTATE_FILES`/`MUTATE_BYTES` reporting ~150 new files and
~2.6–3.0 GiB, `MUTATE_MANIFEST_SHA256` over the new files,
`MUTATE_BASELINE_SHA256_BEFORE` equal to `MUTATE_BASELINE_SHA256_AFTER` (the
1000 baseline files untouched), and `MUTATE_DF_AFTER` still showing free space.
Sizing rule: the dirty set must be at least twice the destination's remaining
capacity, so the incremental copy cannot fit.

**Step 7 — (injection, part 4) create the surgery backup, against the same tracker.**

```sh
oc create -f /path/to/rendered-surgery-backup.yaml   # name vm-backup-enospc-<lifecycle>, pvcName = surgery PVC, source = vm-tracker-<lifecycle>
```

What you must see (historically): `Done=True`, reason
`Successfully completed VirtualMachineBackup`, reached in seconds rather than
tens of seconds. In this iteration the copy payload is the dirty set from Step 6,
which does not fit the destination; **this attempt's terminal state and copy
window are recorded raw and are not predicted here.**

**Step 8 — observe (read-only).**

```sh
oc get vmbackup vm-backup-enospc-<lifecycle> -n <ns> -o yaml
oc get vmbackuptracker vm-tracker-<lifecycle> -n <ns> -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'
oc get events -n <ns> --field-selector involvedObject.kind=VirtualMachineBackup -o json
# destination usage/listing from inside a pod that mounts the claim (no host directory exists for RBD):
#   df -B1 /data; du -s -B1 /data; find /data -maxdepth 5 -ls
```

What you must see (historically): a destination holding only a few-MiB qcow2
beside the filler, a tracker advanced onto the surgery checkpoint, no `no space`
string on any surface, and at most the ghost event named above. Compare the
destination's artifact allocation against the Step 6 dirty-set size, never against
the ~17.4 GiB baseline workload: the incremental only ever carries the dirty set.

**Step 9 — read-only artifact inspection (no writes to the artifact).**

```sh
# in a temporary pod that mounts the surgery PVC read-only and provides qemu-img:
qemu-img info <surgery-backup-dir>/<backup-name>-rootdisk.qcow2
qemu-img info --backing-chain <the same file>
qemu-img map --output=json <the same file>
```

What you must see (historically): `virtual size` ≈ 79.7 GiB against a `disk size`
of a few MiB, and a `backing file:` line naming the live VM's source disk. Restore
the shell with the source unavailable (`qemu-img convert` where the launcher's
private path does not exist) to see it fail with
`Could not open backing file: … No such file or directory`; a convert performed
while the VM runs instead reads through to the live disk and proves nothing.

**Step 10 — recover.** There is no product-level recovery for the corrupt chain:
delete the tracker so the next backup falls back to `Full`, and take that backup
on a correctly sized destination. Note that this does **not** restore anything —
the empty backup is gone.

## Current behaviour (observed)

**Not recorded for this execution.** The historical observations are summarised
in the table below and are **leads, not this attempt's result**; the archived raw
artifacts are named in **Evidence**.

| Measurement | Historical result (2026-10-14 runs) |
|---|---|
| Terminal state | `Done=True`, reason `Successfully completed VirtualMachineBackup`, no warning condition |
| Copy window | seconds, against tens of seconds for the control leg |
| Destination contents | a metadata-only qcow2 of a few MiB — a tiny fraction of the workload — beside the filler |
| Error visibility | no `no space` text in any object, event or status |
| Tracker | advanced onto the empty backup's checkpoint |
| Guest impact | none: the VM stayed Running/Ready |

## Expected behaviour (contract)

The established contract: a backup operation either produces a restore point that
holds the source data, or reports its failure with a reason that names the real
error; and the change-tracking chain never advances onto a backup that copied no
data. The acceptance check a reviewer runs: repeat Steps 4–8 and read the
destination listing plus the backup's `Done` reason — a success reason with a
near-empty destination fails this check, a failure reason naming the capacity or
I/O error passes it.

## Impact, workaround and data safety

- **Functions lost:** trust in the affected backup chain; every incremental taken
  after it chains off an unusable parent.
- **How an operator notices (historically: they do not):** normal
  restore verification passes while the VM is alive. Heuristics that do work:
  an implausibly short copy window for the VM's data size, and a destination whose
  usage did not grow proportionally to the workload.
- **Data safety:** the live VM's data is not touched by this disruption; the
  protection copy is the thing at risk. The scenario's blast radius is one 4 GiB
  Ceph RBD PVC (a 4 GiB block image; ~2600 MiB actually allocated), a transient
  filler pod, a transient measurement pod, a transient inspection pod, and at
  most ~6 GiB of new files inside a run-owned directory of the disposable VM.
- **Workaround:** discard the chain head (delete the tracker) and take a new full
  backup on a correctly sized destination; verify the destination's usage grew.
- **Unknowns:** whether the defect is exactly the upstream job-completion
  handling referenced below, and whether it is already fixed in newer builds.

## Evidence

- **This execution:** `cbt-chaos/scenarios_v2/CBT-EXP-07/runs/<attempt-id>/` —
  `trigger.log` (harness timeline), `legA-full-backup.yaml`,
  `legA-target-usage-mib.txt`, `legB-surgery-pvc.yaml`, `legB-prefill.txt`,
  `legB-guest-mutation.txt`, `legB-backup.yaml`, `legB-target-usage-mib.txt`,
  `legB-target-files.txt`, `legB-inspect-pod.yaml`, `injection-confirmation.json`,
  `execution/injection/guest-mutate.stdout` (raw guest mutation output),
  `execution/injection/prefill-pod-logs.stdout` (in-pod df/du/find of the
  destination), `execution/effect/destination-usage.json` and
  `execution/preflight/render-check.json` (manifest placeholder audit), the observer streams
  under the attempt's `execution/watch/` and `execution/collector/`, and the
  lifecycle's own `runs/<lifecycle-id>/` evidence. Raw artifacts only; the
  product verdict belongs to the independent Analyst.
- **Historical (campaign artifacts, different cluster state and harness):**
  `artifacts/CBT-EXP-07/runs/20261014-exp07-r01..r03/` and the same-day bug draft
  `artifacts/CBT-EXP-07/bugs/backup-reports-success-with-no-data-on-target-enospc.md`.
- **Upstream anchor:** `kubevirt#17578` (closed rotten) — job-completion handling
  that keys off the completion event type without inspecting the job's success
  flag. Unproven at code level for this build.

## Negative results and what would falsify this ticket

- **Falsifier:** a surgery leg whose terminal condition names a real failure (or
  a warning naming the capacity error), or a destination whose usage grows to
  roughly the copy's expected payload. Either disproves the silent-corruption
  claim for this build. In this bundle the expected payload of the surgery copy is
  the **dirty set recorded in `legB-guest-mutation.txt`** (>= 2x the remaining
  destination capacity), not the ~17.4 GiB baseline workload and not the ~79.7 GiB
  preallocated disk.
- **Refuted elsewhere (do not relevel):** an *early* destination ENOSPC (before
  any checkpoint exists) was already shown to fail cleanly; this experiment
  deliberately targets the late window.
- **Structural caveat:** the surgery leg is an incremental over the control
  checkpoint (same tracker), so the payload it *would* copy is the guest's
  changed set since that checkpoint — which this iteration makes explicit and
  measurable by writing the dirty set before the backup object exists. Any
  conclusion must compare like with like: the surgery leg's artifact allocation
  against the recorded dirty-set size (and the control leg's full-copy usage and
  duration), all read from this attempt's own artifacts. A zero-delta guest
  (attempt 1) makes the fault unreachable and the measurement meaningless.

## Additional feedback (reporter's notes)

- The harness deviation (filler pod instead of a host-side `fallocate`) is
  documented in the bundle's plan and handoff; it does not change the fault, only
  how the filler is written. Iteration 2 also drops the node-debug usage probes
  for the surgery volume: a Ceph RBD image has no host directory, so the
  destination's capacity and usage are read inside the pod that mounts it.
- Iteration 2 renders every submitted manifest through a fail-closed placeholder
  audit (`run.sh --render-check`, also run in preflight): attempt 1 aborted *after*
  injection because the inspection pod kept an unsubstituted
  `__RESTORE_HELPER_IMAGE__`. A reproducer should run `run.sh --render-check`
  before any execution; it needs no cluster contact.
- Triage question: is the guard supposed to consult the copy job's success flag?
  If yes, this is a bug with a precise fix site; if the overlay design is
  intentional, the defect is the *absence* of a capacity pre-check.
- Open question worth a smaller experiment: does the same outcome occur when the
  destination is exhausted by a genuine large copy rather than by a pre-fill?

## Sanitisation checklist

- [x] No credentials, tokens, kubeconfig contents or private keys
- [x] No private hostnames (the worker is `<node>`) or user data paths; the pool
      directory is given as the measured storage identifier needed to interpret
      the capacity figures
- [x] No broad selectors: every command names one run-scoped object
- [x] No destructive commands beyond the documented, scoped recovery step
- [x] Commands shown are the ones the bundle runs (the bundle is the validated
      path; the archived harness variants are cited as history only)

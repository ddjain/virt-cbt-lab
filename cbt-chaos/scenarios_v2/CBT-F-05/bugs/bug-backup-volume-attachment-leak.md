# [Bug]: Backup destination volume stays attached to the VM's node after a virt-handler restart during a full backup, blocking any reader on another node

## What this is, in one paragraph

A backup that finished successfully leaves its destination disk attached to the node running the VM, so
nothing on any other node can read that backup. A "reader" — the restore or verification pod whose job
is to prove the backup is usable — stays stuck in `Pending` (a pod that cannot be scheduled) with a
"Multi-Attach" error (Kubernetes refuses to attach a single-writer disk to a second node) while the
backup object itself cheerfully reports success. Two runs on 2026-10-11 reproduced this with different
guest operating systems, and a third run on 2026-10-12 documented the manual cleanup that frees the
volume. The backup data itself is not damaged; the ability to read it back is what is lost.

**When → then → expected**

- **When** the product is taking a full changed-block-tracking backup of a running VM — CBT, the
  incremental backup mode driven by per-disk change tracking — into a destination volume that must be
  **hotplugged** into the VM for the copy (the destination disk is attached to the running node and
  handed to the guest's QEMU while the VM keeps running).
- **And** the disruption `CBT-F-05` (a CBT chaos scenario; its spec calls for the krkn primitive
  `pod-scenarios`, but the recorded runs executed a direct `oc delete` of the one `virt-handler` pod on
  the VM's node, because that pod's name and node only exist after the setup stage finishes — the run
  report states this explicitly) is applied: **delete the single Ready `virt-handler` pod on the VM's
  node while the backup copy is progressing.** Run `20261011-win-f05-r01`: copy signal 13:40:18.303Z,
  pod `virt-handler-jg4pg` (UID d0cf7d37-43d9-4fd3-8239-c1bd009eec75) deleted at 13:40:31Z, backup
  terminal at 13:40:52Z. **The window opens when the copy starts and closes when the backup becomes
  terminal.**
- **Then (current behaviour):** the backup reaches `Done=True` with the success reason, but the
  destination volume's node attachment is never released. The volume stays attached to the VM's node,
  and a pod that mounts the same backup PVC on another node stays `Pending` with `FailedAttachVolume`
  Multi-Attach for its full 1800 s timeout — no restore result, no automatic recovery.
- **Expected behaviour:** when a backup reaches a terminal state, its destination volume's node
  attachment is released. A pod on any other node then mounts the backup PVC and reads the backup
  image without an operator deleting objects by hand.

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
| Issue type | **Bug** — a demonstrated violation of an established contract: a `VirtualMachineBackup` reached terminal success, yet the backup destination volume's node attachment was never released, so the volume is unreadable from any other node. |
| Priority (proposed) | **High** — blocks restore/verification workflows after the disruption; not data corruption. Scenario priority was P1. |
| Severity class | resource leak (leaked storage attachment), with an availability consequence for consumers |
| Owning component (suspected) | **suspected** CBT backup hotplug/volume-attachment cleanup path (virt-handler driven). |
| Component(s) proven involved | virt-handler (it emitted the `HotplugFailed` / `SyncFailed` events on the cleanup path), the ODF/Ceph RBD attach path (`VolumeAttachment` retained with the external-attacher finalizer, `spec.attached: true`), and the attach-detach controller for the reader pod (its Multi-Attach failure is what blocks the reader). The code path that skips the detach is **not** proven. |
| Reproducibility | `deterministic (2/2 run labels)` — reproduced on both CBT-F-05 run labels observed on 2026-10-11, on two different guest OSes, on the same cluster/build. |
| Status / confidence | **Confirmed behaviour on two independent runs** (RHEL 9 and Windows Server 2022 guests). Certain from artifacts: the cleanup failure events, the retained `attached: true` attachment, the reader's Multi-Attach block, the backup's success. The defect classification (missing detach vs. legitimate long-lived attachment) is high confidence; the root cause inside the cleanup path is **unproven**. |
| Blast radius | the affected backup volume only (an RWO volume is usable from one node at a time), and through it any consumer scheduled elsewhere. Cluster-wide check during the RHEL 9 run: it was the only leaked backup-volume attachment at that time. |
| Data at risk? | **No** — the backup data itself is intact (`Done=True`, correct checkpoint, volumes preserved). What is lost is the *availability of the reader path*, not data. |
| Related scenario / execution | CBT-F-05 (restart node backup handler during full backup); runs `20261011064508-fuzzy-wolf-6cb9` (RHEL 9) and `20261011-win-f05-r01` (Windows), both 2026-10-11 UTC. Companion ticket from the third run label (`20261012-cbtf05-r01`, 2026-10-12) in this folder: `leaked-hotplug-attachment-on-handler-restart.md` — the longer evidence narrative of the same behaviour family. |
| Affected versions | OpenShift 4.22.15; OpenShift Virtualization 4.22.12 (`kubevirt-hyperconverged-operator.v4.22.12`); ODF Ceph RBD (Block for VM disks, Filesystem for backup volumes); guest OS RHEL 9 and Windows Server 2022. The full measured matrix is in **Environment** below. |

## Context (for an engineer new to this area)

**What the feature does.** When a `virt-handler` pod is deleted while a full CBT backup is actively
copying, the backup itself completes correctly, but the backup destination volume's hotplug cleanup
on the VM fails. The volume's node attachment is then never released after the backup completes: the
persistent volume stays attached to the node running the source VM indefinitely. Because the volume
is RWO (single-node attach), any pod scheduled on a different node that needs to read the backup —
for example a restore/verification pod — fails with a Multi-Attach error and cannot start. In both
observed runs this blocked data-level restore verification for the full 30-minute wait window.

**Where the failure sits.** The objects a user or operator observes are: the `VirtualMachineBackup`
CR (terminal `Done=True`, success reason — it looks healthy), the VMI's events (`HotplugFailed`,
`SyncFailed` — emitted by virt-handler on the VM's node), and the `storage.k8s.io/v1` `VolumeAttachment`
for the backup PV (`spec.attached: true`, no `deletionTimestamp`, external-attacher finalizer intact).

**Observed surface vs. origin.** The surface that reports the problem is the VMI's event stream and
the reader pod's `FailedAttachVolume`; the site that caused it is the hotplug cleanup on the VM's
node, and the object that stays wrong is a `VolumeAttachment` — an object the backup's own status
never mentions. That mismatch (the backup reports success while a different object leaks) is the
defect.

**Why it matters.** The data path of the backup is fine and the CR says "success", but the backup
cannot be read back from anywhere except the one node that still holds the attachment. Every
restore, verification, or external copy step silently degrades to "blocked" until an operator
intervenes, and nothing in the backup's own status tells them so.

### Background: how a CBT backup uses storage (for readers new to storage plugins)

Actors:

- **KubeVirt controller** — the control-plane "brain"; creates the `VirtualMachineBackup` object and the backup PVC.
- **`virt-handler`** — KubeVirt's per-node agent (DaemonSet pod on every worker node). It plugs/unplugs disks into the VM and talks to libvirt/QEMU. *This is the pod our chaos scenario deletes.*
- **CSI storage driver** (here ODF/Ceph RBD) — the only component that can physically attach/detach a disk to a server. KubeVirt requests; CSI performs.
- **`VolumeAttachment`** — a Kubernetes record meaning "disk X is currently plugged into server Y". While it exists, no other server may attach the same disk.
- **Backup PVC (RWO)** — the empty disk the backup is written to. `ReadWriteOnce` = attachable to exactly one node at a time.
- **Hotplug** — plugging the backup PVC into the *running* VM so QEMU can copy the disk to it; after the copy it must be unplugged (cleanup/detach).

### Happy flow (no disruption)

```
 STEP 1  Controller creates Backup CR + empty backup PVC
            |
 STEP 2  Controller asks virt-handler (Node A) to hotplug the volume
            |
         virt-handler -> CSI driver attaches disk to Node A
            |
         VolumeAttachment{backupPVC, node=A, attached=true}   <- record created
            |
 STEP 3  QEMU copies VM disk -> backup PVC   ("Backup started" ... copy ... done)
            |
 STEP 4  Backup Done=True; virt-handler unplugs the volume;
         CSI driver detaches; VolumeAttachment DELETED          <- record removed
            |
 STEP 5  Volume is FREE: any pod on ANY node can mount the backup PVC
         (restore, verify, export).                             <- the invariant
```

### Buggy flow (virt-handler restarted during STEP 3)

```
 STEP 3'  virt-handler on Node A is deleted mid-copy (replacement starts ~20s later)
            |
 STEP 4'  Backup finishes (Done=True). Replacement handler attempts the unplug:
            |    HotplugFailed: "failed to mount filesystem hotplug volume"
            |    SyncFailed:    "failed to remove hotplug disk directory"
            |
         The cleanup is one-shot and is NOT retried; nothing asks CSI to detach.
            |
         VolumeAttachment{backupPVC, node=A, attached=true}    <- STAYS FOREVER
            |
 STEP 5'  Node A holds the disk; RWO forbids a second node:

            Node A                          Node B
         +--------------------+       +--------------------------+
         | VM (running)       |       | restore/verify pod       |
         | backup PVC stuck   |       | "I need to READ backup"  |
         | plugged here       |       +------------+-------------+
         +---------+----------+                    |
                   |        RWO = one node         |
                   +-------------- X --------------+
                            Multi-Attach error
         "Volume is already exclusively attached to one node
          and can't be attached to another"
         Verify pod: Pending ... (30 min) ... timeout
```

Why it persists: no component owns a retry. The handler's cleanup attempt failed once, the Backup CR
is already terminal/successful, so from the controller's perspective nothing remains to reconcile —
the leaked `VolumeAttachment` is invisible to the backup's own status.

**What this is NOT:** it is not data corruption (backup data intact, `Done=True`, correct checkpoint),
and not a backup failure (full and incremental both succeeded after the disruption). It is a leaked
storage attachment that blocks any *reader* of the backup volume from another node.

## Environment (measured, not assumed)

The per-ticket table below is the point of this ticket: **these runs exercised ODF/Ceph RBD**, so the
ODF rows are *in use* and the HostPathProvisioner pool is *present but not exercised*. Rows are
provenance-tagged: `run` = captured by these runs' own artifacts; `cluster 2026-10-16` = measured on
the same cluster two to five days later, because these runs' packs did not capture the layer; and
`not recorded` where nothing captured it (never inferred). Node names are genericised as `<vm-node>`
and `<reader-node>`; the runs' own packs record the exact names.

| Layer | Component | Version / identifier | How obtained | Provenance |
|---|---|---|---|---|
| Platform | OpenShift Container Platform (server and `oc` client) | 4.22.15 | both runs' reports, environment table (`test-run-report.md`) | `run` |
| Platform | Kubernetes API | v1.35.6 | `oc version` | `cluster 2026-10-16` |
| Platform | OpenShift update channel | `not recorded` — never captured by these runs or the later cluster measurement | `oc get clusterversion version -o jsonpath='{.spec.channel}'` (not run) | `not recorded` |
| Platform | `oc`/`kubectl` plugin versions | `not recorded` — only the `oc` server/client version is known | `oc plugin list` (not run) | `not recorded` |
| Nodes | OS image | Red Hat Enterprise Linux CoreOS 9.8.20260915-0 (Plow) | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | kernel | 5.14.0-687.48.1.el9_8.x86_64 | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | container runtime | cri-o 1.35.8-11.rhaos4.22.giteaf45bc.el9 | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | topology / nodes in scope | the CBT VM ran on a single worker (`<vm-node>`); the restore-verification pod was scheduled to a *different* worker (`<reader-node>`) — that node difference is what turns the leak into a failure | runs' VMI/`spec.nodeName` and restore-verifier pod records; exact names in the runs' packs | `run` |
| Virtualization | CNV / HCO CSV | `kubevirt-hyperconverged-operator.v4.22.12` | both runs' reports (`oc get csv -A`) | `run` |
| Virtualization | kubevirt observed version | `status.observedKubeVirtVersion` = virt-operator image digest `sha256:2f654df4f4b026b85abc62bfe834a842b3a49b054f97a5999a85443320a29293` | `oc get kubevirt -n openshift-cnv -o jsonpath='{.status.observedKubeVirtVersion}'` | `cluster 2026-10-16` |
| Virtualization | virt-launcher image digest (RHEL 9 guest) | `registry.redhat.io/container-native-virtualization/virt-launcher-rhel9@sha256:2131d3d24616971b92d7e986635673b6dc731da3d43cae46540882993d36596f` | launcher pod spec recorded in the Windows run's pack (`observer/launcher-final.json`, `.spec.containers[*].image`) | `run` |
| Virtualization | virt-handler image digest | `registry.redhat.io/container-native-virtualization/virt-handler-rhel9@sha256:9b3aa0c6b2786ea3d5bfd25e79546b30563e54e739aef7b21cfa8b4dfc66e83b` | virt-handler DaemonSet recorded in the RHEL 9 run's pack (`observer/virt-handler-ds-baseline.json`) | `run` |
| Virtualization | virt-controller image digest | `not recorded` — not captured by these runs | `oc get deploy virt-controller -n openshift-cnv -o jsonpath='{.spec.template.spec.containers[*].image}'` (not run) | `not recorded` |
| Virtualization | libvirt / QEMU / QEMU API in the launcher | libvirt 11.10.0, QEMU 10.1.0, QEMU API 11.10.0 | `virsh version` in the launcher's `compute` container | `cluster 2026-10-16` |
| Backup API | CRD group / version | `backup.kubevirt.io/v1alpha1` (also the API version of the watched backup objects) | run packs' backup object watches; `oc get crd` for the CRD metadata | `run` (API group of watched objects) |
| Storage (**in use**) | StorageClass + provisioner + pool | `ocs-storagecluster-ceph-rbd` for VM root disk and backup volumes; RV = VM disks, Filesystem-mode hotplug for the backup target; Ceph RBD pool `ocs-storagecluster-cephblockpool` (leaked image `csi-vol-53263947-…`) | RHEL 9 run report ("Storage backend"); `spec.attacher` of the leaked `VolumeAttachment` = `openshift-storage.rbd.csi.ceph.com`; `investigation/rbd7-holder.txt` (run 20261012-cbtf05-r01) | `run` |
| Storage (**in use**) | CSI driver image + version | `not recorded` for the driver image — these runs captured the driver *identity* (`openshift-storage.rbd.csi.ceph.com`) but not its image digest | `oc get ds` in the CSI namespace (not run) | `not recorded` |
| Storage (**in use**) | backing device / filesystem / free space at the time | `not recorded` — Ceph capacity/health at run time was not captured by these runs (the provider-side evidence captured instead is the RBD image name and the exclusive-lock watcher) | storage provider's own tools (`ceph df`, `rbd status`) — only partially run, see the companion ticket | `not recorded` |
| Storage (**in use**) | ODF/OCS operators, Ceph image, health | `4.22.5-rhodf` operators (`odf-operator`, `ocs-operator`, `rook-ceph-operator`, `cephcsi-operator`, `mcg-operator`, `odf-csi-addons-operator`, external-snapshotter); RHCS 9 Ceph image `sha256:926d15fddae065a1e82b3634f80847253fa2cc14e9888e15b19b72a2cf144a58`; cluster health `HEALTH_OK` | `oc get csv -n openshift-storage`, `oc get cephcluster -n openshift-storage -o jsonpath=…` | `cluster 2026-10-16` |
| Storage (**present but NOT exercised**) | HostPathProvisioner / hostpath CSI | StorageClass `cbt-demo-hpp`, provisioner `kubevirt.io.hostpath-provisioner`, pool `cbt-demo-pool`, hostpath-CSI DaemonSet `hostpath-provisioner-csi` (ns `openshift-cnv`), image `…/hostpath-csi-driver-rhel9@sha256:72cdfd4ab6621148bf2a70485394d335d9ccc5045ab0aa82018e72472444bf6b`, `VERSION=v4.22`, data dir `/var/hpvolumes/csi` (its **own** filesystem, unlike its parent `/var/hpvolumes`) — installed on this cluster but **not exercised by these runs**: every volume in these runs is ODF/Ceph RBD, stated so triage does not chase a hostpath hypothesis | `oc get sc`, `oc get ds hostpath-provisioner-csi -n openshift-cnv` | `cluster 2026-10-16` |
| Storage (**present but NOT exercised**) | local-storage-operator | `local-storage-operator.v4.22.0-202609291750` — installed, not exercised by these runs | `oc get csv -A` | `cluster 2026-10-16` |
| Guest | OS release — run `20261011064508-fuzzy-wolf-6cb9` | RHEL 9 (DataSource "RHEL 9"; `VM_OS=rhel9` in `trigger.log`) | run's `trigger.log`; run report | `run` |
| Guest | OS release — run `20261011-win-f05-r01` | Windows Server 2022 (build `not recorded`) — `VM_OS=windows`, cloned from a cached Windows golden image | run's `trigger.log`; run report | `run` |
| Guest | kernel — both runs | `not recorded` — no `/etc/redhat-release`/`uname -r` capture in either pack (the RHEL 9 kernel `5.14.0-687.5.1.el9_8.x86_64` in the cluster block was measured on a different, later guest) | `cat /etc/redhat-release`, `uname -r` in the guest (not run) | `not recorded` |
| Guest | guest agent package version | `not recorded` — not captured by these runs (the Windows run's timeline notes transient QGA failures during setup, but no package version) | `rpm -q qemu-guest-agent` (RHEL) / OS equivalent (not run) | `not recorded` |
| Guest | vCPU / memory as configured and as seen | `not recorded` — neither pack captured the VM spec or in-guest values; the Windows VM's root disk was 40 GiB (`rootdisk`/`sda`) | VM spec vs `nproc`/`free` (not run); root disk from the Windows run report | `not recorded` (root disk: `run`) |
| Guest | workload used (context, not a version) | RHEL 9 run: 8 baseline files × 1 GiB; Windows run: 8 files × 1 GiB on an NTFS root disk | runs' `trigger.log` + reports | `run` |
| Harness (internal only) | workflow version / trigger checksum | `virt-cbt-lab` workflow; the trigger checksum is `not recorded` in these runs' packs (the pack carries the run label and its report, not a checksum — and CBT-EXP-06's checksum must not be reused here) | run packs | `not recorded` |

**Load-bearing versions.** The CNV/KubeVirt version matters: the failing cleanup path is in
virt-handler (`failed to remove hotplug disk directory`), and the event reason codes /
finalizer names observed here are version-specific. The storage mode matters too: the backup target
is asked to be hotplugged in *Filesystem* mode on ODF/Ceph RBD, which is why a CSI `globalmount`
path (and its `disk.img`) is in play at all. Nothing in this ticket depends on the HostPath pool.

## Reproducibility

- **Classification**: `deterministic (2/2 run labels)` — the same failure signature in 2 of 2
  observed CBT-F-05 run labels on 2026-10-11 (RHEL 9 guest, and Windows Server 2022 guest), on the
  same cluster/build.
- **Attempts**: 2 run labels, each with one injection (handler pod deletion during the active copy);
  2026-10-11; executed by the CBT-F-05 workflow under an independent read-only watcher (authenticated
  watches on the run's VM, backup, PVCs, handler pods and events) — so the observations are not the
  workflow's own exit status alone.
- **Stability — exact every time**: the event pair (`HotplugFailed` + `SyncFailed`) at the backup's
  terminal second, the backup's `Done=True` with reason `Successfully completed VirtualMachineBackup`,
  the retained `attached: true` attachment on the VM's node, and the reader pod's Multi-Attach block
  for the full 1800 s window. **Varies**: the exact second of the terminal transition, and the
  guest OS (deliberately: two different guests produced the same signature).
- **Preconditions**: CBT-enabled VM with a guest workload large enough to yield an observable copy
  window; a backup destination PVC on ODF/Ceph RBD; the *single* `virt-handler` pod on the VM's node
  deleted **while the copy is progressing** (not before the copy starts, not after terminal).
- **Second entry path**: not established. The sibling ticket
  (`leaked-hotplug-attachment-on-handler-restart.md`) reaches the same leaked-attachment state from a
  third run label (2026-10-12) with a different injection timing inside the copy→unplug window, plus
  a verified recovery procedure; treat that as the same-family confirmation, not an independent
  second fault path, until someone reaches the leak without a handler restart.

## Steps to reproduce (exact commands and injection timing)

> Everything below uses the **recorded names of run `20261011-win-f05-r01`** (namespace `vm-cbt-demo`),
> so a reader can compare each command with this ticket's evidence. For a fresh reproduction pick your
> own run-scoped names. Every command is scoped to one named object — never to a label selector that
> could match other tenants. Repository helper for this scenario (optional accelerator, never required):
> `cbt-chaos/scenarios_v2/CBT-F-05/chaos-trigger.sh`.

### Concrete objects used in this report

| Kind | Name | UID | Created (UTC) | Fate |
|---|---|---|---|---|
| VirtualMachine | `vm-20261011-win-f05-r01` | `not recorded` | 2026-10-11 ~13:05Z | kept (the source VM) |
| VirtualMachineInstance | `vm-20261011-win-f05-r01` | c3e10e87-9747-428f-ad2f-a94f52e2550a | 13:05:29Z | kept; Running on `<vm-node>` |
| Pod (launcher) | `virt-launcher-vm-20261011-win-f05-r01-grcq9` | f4563d74-0000-47f4-8dbd-9a28139d77c0 | 13:05:29Z | kept; never restarted |
| Pod (disruption target) | `virt-handler-jg4pg`, ns `openshift-cnv`, node `<vm-node>` | d0cf7d37-43d9-4fd3-8239-c1bd009eec75 | `not recorded` | **deleted by the scenario** (deletion timestamp 13:40:31Z); DaemonSet recreated `virt-handler-655mx` (UID 184db2c1-8107-4cbe-b27f-f78e5a056960), Ready 13:40:53Z |
| VirtualMachineBackupTracker | `vm-tracker-20261011-win-f05-r01` | 85ae1fcc-87d1-4b36-a679-b7d27024cf3e | `not recorded` | kept |
| VirtualMachineBackup (full) | `vm-backup-20261011-win-f05-r01` | 30275775-950a-4da7-ad2a-375d597e38b5 | 13:40:08Z | kept; `Done=True` 13:40:52Z |
| Checkpoint (full) | `vm-backup-20261011-win-f05-r01-2026-10-11_13-40-08` | — (libvirt checkpoint) | 13:40:08Z | kept |
| PVC (full destination) | `vm-backup-pvc-20261011-win-f05-r01` → PV `pvc-01522b2e-bd7a-445a-b674-06037de2e969` | 01522b2e-bd7a-445a-b674-06037de2e969 | 13:40:08Z | kept, `Bound` 48Gi — **this is the volume that leaks** |
| VolumeAttachment (leaked) | `csi-1dbaa20e1c8daff5370ddb1a4303628e25a7bb9fc8c48d6eda2809456fe84559` | `not recorded` | 13:40:08Z | left in place on the VM's node; the name comes from a live post-run read and is **not** among the retained pack files |
| VirtualMachineBackup (incremental) | `vm-incremental-20261011-win-f05-r01-p01` | `not recorded` | 13:42:55Z | kept; `Done=True` 13:43:12Z (its window had no disruption — the control) |
| PVC (incremental destination) | `vm-incremental-pvc-20261011-win-f05-r01-p01` → PV `pvc-d55911d8-9a21-406c-a34f-aeae35a7030d` | d55911d8-9a21-406c-a34f-aeae35a7030d | 13:42:55Z | kept, `Bound`; attached on `<reader-node>` at 13:43:24Z |
| Pod (reader = restore verification) | `vm-restore-verify-20261011-win-f05-r01` | 8d2f2a6d-1193-45fa-9a91-fe045af65489 | 13:43:16Z | kept as the failed attempt; `Pending` 13:43:16Z–14:15:32Z, never ran |
| RHEL 9 run equivalents | VM/backup `vm-20261011064508-fuzzy-wolf-6cb9`; PVC `vm-backup-pvc-20261011064508-fuzzy-wolf-6cb9` → PV `pvc-0aa3ec7c-348a-410e-b0b3-68aa18041725`; incremental `vm-incremental-20261011064508-fuzzy-wolf-6cb9-p01` → PV `pvc-751759c9-2382-4d09-953b-ffeb93a863ff`; reader `vm-restore-verify-20261011064508-fuzzy-wolf-6cb9` (UID 5689bcd6-3bed-4345-bb84-331f1f745f09); deleted handler `virt-handler-mlvzn` (UID 95b1af4c-67d5-4e6b-b0d2-ef5909e1048f) | leaked VA `csi-5922145910592e2a96669734a32b0ef262fdc3b3f0592cf22ed1691a034e3c2e` (UID `not recorded`) | 06:54:04Z (backup + PVC + VA) | same fates: objects kept, leak preserved |

### Steps

**Step 1 — Setup: VM with CBT enabled, its workload, and the destination PVC.** When: before any backup.
```bash
oc get vmi vm-20261011-win-f05-r01 -n vm-cbt-demo \
  -o jsonpath='{.status.phase}{" "}{.status.nodeName}{" "}{.status.changedBlockTracking.state}{"\n"}'
oc get pvc vm-backup-pvc-20261011-win-f05-r01 -n vm-cbt-demo \
  -o jsonpath='{.status.phase}{" "}{.spec.resources.requests.storage}{"\n"}'
```
What you must see: VMI `Running`, `changedBlockTracking.state` = `Enabled`, destination PVC `Bound`.
(The recorded workload was 8 files × 1 GiB on a 40 GiB root disk — big enough to make the copy window
observable.)

**Step 2 — Start the full backup: this is what the injection window hangs on.** When: immediately before step 3.
```bash
oc get virtualmachinebackuptracker vm-tracker-20261011-win-f05-r01 -n vm-cbt-demo \
  -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'
oc apply -f - <<'YAML'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-backup-20261011-win-f05-r01
  namespace: vm-cbt-demo
spec:
  pvcName: vm-backup-pvc-20261011-win-f05-r01
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261011-win-f05-r01
YAML
# the backup object alone does NOT prove a copy is running — wait for the launcher signal
oc logs virt-launcher-vm-20261011-win-f05-r01-grcq9 -n vm-cbt-demo -c compute | grep -F 'Backup started'
```
**Injection window: it opens at the `"msg":"Backup started"` line naming this exact backup (recorded
13:40:18.303Z) and closes when the backup becomes terminal (recorded 13:40:52Z).** What you must see:
`Backup started` in the launcher log and the backup still non-terminal —
`oc get vmbackup vm-backup-20261011-win-f05-r01 -n vm-cbt-demo -o jsonpath='{.status.conditions}'`.

**Step 3 — (Injection) Delete the single handler pod on the VM's node: with a fail-closed pre-check.**
When: any moment inside that window (the recorded run acted 13 s into the copy).
```bash
NODE=$(oc get vmi vm-20261011-win-f05-r01 -n vm-cbt-demo -o jsonpath='{.status.nodeName}')
oc get pods -n openshift-cnv --field-selector "spec.nodeName=${NODE}" -l kubevirt.io=virt-handler \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,READY:.status.conditions[?(@.type=="Ready")].status
# fail closed unless that returns exactly one Ready pod; then (the recorded command form):
oc delete pod virt-handler-jg4pg -n openshift-cnv --wait=false
```
What you must see: a `Killing` event for that UID, then a replacement handler Ready on the same node
within about a minute (recorded: 13:40:53Z, DaemonSet 28/28).

**Step 4 — Let the backup run to completion: the defect is created at copy end.** When: no action; wait.
```bash
oc get vmbackup vm-backup-20261011-win-f05-r01 -n vm-cbt-demo \
  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}{" "}{.status.conditions[?(@.type=="Done")].reason}{"\n"}'
oc get events -n vm-cbt-demo --field-selector involvedObject.name=vm-20261011-win-f05-r01 \
  --sort-by=.lastTimestamp | grep -E 'HotplugFailed|SyncFailed'
```
What you must see: `True Successfully completed VirtualMachineBackup` — the backup looks healthy — and,
in that same second, `HotplugFailed` ("failed to mount filesystem hotplug volume … lstat /proc/1/root")
plus `SyncFailed` ("failed to remove hotplug disk directory").

**Step 5 — Read-only demonstration of the defect.**
```bash
# 5a. the leaked attachment: attached on the VM's node, no deletion timestamp, finalizer intact
oc get volumeattachment -o json \
  | jq '.items[] | select(.spec.source.persistentVolumeName=="pvc-01522b2e-bd7a-445a-b674-06037de2e969")
        | {name:.metadata.name, node:.spec.nodeName, attached:.status.attached,
           deletionTimestamp:.metadata.deletionTimestamp, finalizers:.metadata.finalizers}'
# 5b. post-check that it is stuck, not transient: re-read 5a after >=10 minutes (the leaked attachment
#     stays; in the RHEL 9 run the storage attacher logged "already attached" every ~10 min, no detach)
# 5c. a reader pod on another node cannot attach the backup volume
oc get events -n vm-cbt-demo --field-selector involvedObject.name=vm-restore-verify-20261011-win-f05-r01 \
  --sort-by=.lastTimestamp | grep FailedAttachVolume
oc get pod vm-restore-verify-20261011-win-f05-r01 -n vm-cbt-demo -o wide
```
What you must see: `attached: true` with `node` = the VM's node and `deletionTimestamp: null`;
`FailedAttachVolume` carrying `Volume is already exclusively attached to one node and can't be attached
to another`; and the reader pod `Pending` on a **different** node. Declare it stuck only after the
reader's own deadline (recorded: 1800 s).

**Step 6 — Recovery: verified in the third run label `20261012-cbtf05-r01`; not attempted in these two runs
because the leak was deliberately preserved as evidence.** When: after capturing 5a–5c.
```bash
oc delete volumeattachment csi-1dbaa20e1c8daff5370ddb1a4303628e25a7bb9fc8c48d6eda2809456fe84559
oc delete pod virt-handler-655mx -n openshift-cnv --wait=false   # restart the replacement handler
oc get pvc vm-backup-pvc-20261011-win-f05-r01 -n vm-cbt-demo -o jsonpath='{.status.phase}{"\n"}'
```
What you must see: the attachment disappears, the device unmaps on the node, and the backup PVC can be
attached by a pod on another node. What this does **not** restore: the reader that already timed out
must be re-created, and nothing does this automatically — without the manual sequence the volume stays
blocked indefinitely (the recorded leak stayed ~2 h until an operator acted).

## Current behaviour (observed)

- **Windows run `20261011-win-f05-r01`**: active-copy signal 13:40:18.303Z; handler
  `virt-handler-jg4pg` (UID d0cf7d37-43d9-4fd3-8239-c1bd009eec75) deleted on node `<vm-node>` (API
  deletion timestamp 13:40:31Z); full backup `vm-backup-20261011-win-f05-r01` `Done=True`, reason
  "Successfully completed VirtualMachineBackup" at 13:40:52Z; at that same second, events
  `HotplugFailed` ("failed to mount filesystem hotplug volume … lstat /proc/1/root") and `SyncFailed`
  ("failed to remove hotplug disk directory") were emitted for the backup-target volume. The full
  PVC's PV (`pvc-01522b2e-bd7a-445a-b674-06037de2e969`) remained `attached: true` on the VM's node
  via volumeattachment `csi-1dbaa20e…` (verified live after the run). The restore-verification pod
  (scheduled on node `<reader-node>`) stayed Pending on Multi-Attach for the full 1800 s timeout
  (13:43:16Z–14:15:32Z); no restore result was produced. *(All of the above: independent artifact
  observation; the volumeattachment hash itself was recorded by a live post-run read and is not among
  this repository's retained pack files — see Evidence.)*
- **RHEL 9 run `20261011064508-fuzzy-wolf-6cb9`**: same scenario; hotplug cleanup failed at backup
  completion (`HotplugFailed`, `SyncFailed` at 06:55:19Z); the storage attacher logged "already
  attached" every ~10 minutes with no detach ever requested; the backup volume's attachment was the
  only leaked backup-volume attachment on the cluster; restore verification blocked the same way for
  the full window (reader pod `vm-restore-verify-20261011064508-fuzzy-wolf-6cb9` scheduled
  06:56:12.677834Z to node `<reader-node>`, `FailedAttachVolume` Multi-Attach for the full backup's PV
  `pvc-0aa3ec7c-348a-410e-b0b3-68aa18041725` at 06:56:12Z, while the *incremental's* PV
  `pvc-751759c9-2382-4d09-953b-ffeb93a863ff` attached successfully at 06:56:13Z on the same node;
  Pending until 07:28:27Z). *(Same status; in this pack the retained
  `VolumeAttachment` itself is a captured artifact: `observer/volumeattachment-final.json` —
  attachment `csi-5922145910592e2a96669734a32b0ef262fdc3b3f0592cf22ed1691a034e3c2e`,
  `spec.nodeName` `<vm-node>`, `spec.source.persistentVolumeName`
  `pvc-0aa3ec7c-348a-410e-b0b3-68aa18041725`, `status.attached: true`, finalizer
  `external-attacher/openshift-storage-rbd-csi-ceph-com`, `creationTimestamp`
  2026-10-11T06:54:04Z.)*
- **Decisive verbatim strings** (each an independent artifact observation):
  `"Successfully completed VirtualMachineBackup"`; `HotplugFailed: "failed to mount filesystem hotplug volume"`;
  `SyncFailed: "failed to remove hotplug disk directory"`;
  `"already attached"` (csi-attacher controller-plugin log, 7 occurrences in the RHEL 9 run's captured log);
  `"Volume is already exclusively attached to one node and can't be attached to another"` (reader pod's FailedAttachVolume).
- **Duration**: the leak outlived both runs' observation windows — it was still present at the end of
  each run (RHEL 9: from `creationTimestamp` 06:54:04Z through the last read after the run; Windows:
  still present when the run's observation closed at ~14:19Z). It does **not** self-heal within the
  windows observed; the draft's third run label keeps it until an operator deletes it (~2 h).

### Side-by-side comparison of the two runs

| | RHEL 9 run | Windows run |
|---|---|---|
| Run label | 20261011064508-fuzzy-wolf-6cb9 | 20261011-win-f05-r01 |
| Guest OS | RHEL 9 | Windows Server 2022 |
| Cleanup failure time (UTC) | 06:55:19Z | 13:40:52Z |
| Backup outcome | Done=True, Full, checkpoint OK | Done=True, Full, checkpoint OK |
| HotplugFailed / SyncFailed events | Present | Present |
| VolumeAttachment after completion | attached=true, no detach ever requested (attacher logged "already attached" every ~10 min) | attached=true, verified live post-run |
| Restore verification | Blocked, 30-min timeout | Blocked, 30-min timeout |

Identical failure signature across two guest OSes on the same cluster/build → the defect is in the
hotplug-cleanup path, not guest-OS-specific. **[INFERENCE]** — the run artifacts prove the signature
is guest-independent and correlated with the handler restart; they do not isolate which line of the
cleanup path drops the detach.

The backup, checkpoint, tracker, CBT state, and same-VM incremental follow-up were correct in both
runs (incremental `Done=True` 13:43:12Z / 06:56:08Z respectively, child checkpoint, tracker advanced
once). All identity/timing observations above were captured by an authenticated, run-scoped read-only
watcher plus the API objects, not only by the workflow's own exit status.

## Expected behaviour (contract)

After a `VirtualMachineBackup` reaches a terminal state (success or failure), the hotplugged backup
destination volume's node attachment should be released (detached), even when the handler pod that
manages the hotplug was restarted during the backup. Cleanup failure during the copy should be
retried or reconciled by the controller rather than silently abandoned.

**Acceptance check.** After a handler restart mid-full-backup and the backup's terminal completion,
`oc get volumeattachment` for the backup PV shows no lingering `attached: true` entry on the VM's
node (within a bounded reconciliation window), and a pod on a different node can mount the backup PVC
and read the backup image.

**Acceptance criteria (from the reporter draft, preserved):**

- After a full backup that experienced a virt-handler restart during active copy reaches a terminal
  state, the backup destination volume's node attachment is released within a bounded, documented
  reconciliation window.
- A regression test covering the original failure mode: handler deletion during active full copy,
  backup completes, then a reader pod on a *different* node successfully mounts the backup PVC and
  reads the backup image.
- No regression for the normal path: handler not disrupted → attachment already released today must
  remain released.

## Impact, workaround and data safety

- **Functions lost / how an operator notices.** Data-level restore verification and any other reader
  of the backup volume from a different node stops working entirely, while every product object
  reports success. An operator notices only by looking at the reader's events (`FailedAttachVolume`,
  Multi-Attach) or by noticing that a "successful" backup was never actually read back — the backup
  CR itself never says so.
- **Blast radius.** The affected volume only (one RWO volume, pinned to one node) — but through it,
  every consumer scheduled elsewhere. In the RHEL 9 run it was the only leaked backup-volume
  attachment cluster-wide at that time, so this is not a cluster-wide cascade on this build.
- **Data safety.** Data is **not** at risk: both backups terminal-succeeded with correct checkpoints
  and the volumes were preserved and Bound. The loss is availability of the reader path (and, for the
  workflow, the ability to prove the data is good). What the runs could not verify *because* of the
  leak is restore/data correctness of the affected volumes — that gap is an artifact of this defect,
  not evidence of corruption.
- **Workaround / operator runbook.** No workaround was validated in these two runs; the workflow
  simply timed out. Candidate mitigations (untested here): schedule the reader pod on the node that
  holds the attachment, or force removal of the `VolumeAttachment`. Manual `VolumeAttachment`
  deletion is risky and was **not** attempted in these runs. A live-verified procedure exists for the
  same state from the third run label — delete the orphaned `VolumeAttachment`, then restart the
  replacement `virt-handler` pod (companion ticket, run 20261012-cbtf05-r01) — with the cost that the
  reader pod must be re-run and the stale-mount window is only closed by the handler restart.
- **Frequency.** Deterministic given the precondition (2/2 run labels). The precondition itself —
  deleting the node's `virt-handler` while an active CBT copy is running — is a narrow
  chaos/maintenance window (node maintenance, agent crash, rolling update), not routine operation.
- **Unknowns this ticket deliberately does not claim.** Whether the attachment is retained
  deliberately while the source VM runs or is simply orphaned by the failed hotplug cleanup; the
  exact code path that skips the detach; whether an unmodified cluster (no chaos) can reach the same
  state through a handler crash.

## Evidence

**Artifact index** (repository-relative; all paths under
`cbt-chaos/scenarios_v2/CBT-F-05/runs/<run label>/`; "raw" = API object/log capture, "derived" =
report/summary written by the run):

| Artifact | What it carries | UTC | Type |
|---|---|---|---|
| `20261011-win-f05-r01/observer/events.jsonl` | the `HotplugFailed` events (4 watch rows: on the full backup-target volume at 13:40:52Z and on the incremental's target at 13:43:12Z, each count 1→2), one `SyncFailed` (13:40:52Z), the `Killing` of the handler pod and later of the `hotplug-disk` containers, the two `FailedAttachVolume` Multi-Attach events, and the ghost `VirtualMachineBackupFailed("Backup has failed: VMI backup status was lost")` at 13:40:52Z | 13:40:52Z, 13:43:12Z | raw |
| `20261011-win-f05-r01/observer/restore-verifier-events.json` | reader pod events: pod assigned to `<reader-node>` 13:43:16.528028Z, `FailedAttachVolume` Multi-Attach for **both** the full PV (`pvc-01522b2e-…`) and the incremental PV (`pvc-d55911d8-…`) at 13:43:16Z, then `SuccessfulAttachVolume` for the incremental's volume at 13:43:24Z (only the full's volume stayed stuck) | 13:43:16Z, 13:43:24Z | raw |
| `20261011-win-f05-r01/observer/timeline.md` | the run's ordered UTC timeline, incl. the handler deletion (13:40:31Z), replacement Ready (13:40:53Z), backup terminal (13:40:52Z), reader pod Pending through the 1800 s deadline (14:15:32Z) | 13:04–14:19Z | derived (from raw watches) |
| `20261011-win-f05-r01/observer/finding.md`, `preserved.md`, `test-run-report.md` | finding text (leaked destination attachment), preserved state notes, the run's environment table (OpenShift 4.22.15 / CNV 4.22.12) | run window | derived |
| `20261011-win-f05-r01/observer/launcher-final.json` | virt-launcher pod spec → image digest | post-run | raw |
| `20261011064508-fuzzy-wolf-6cb9/observer/volumeattachment-final.json` | the leaked `VolumeAttachment` object verbatim (`attached: true`, VM node, PV, finalizer, created 06:54:04Z) | post-run | raw |
| `20261011064508-fuzzy-wolf-6cb9/observer/csi-attacher-openshift-storage.rbd.csi.ceph.com-ctrlplugin-nv8xr.log` | 7 × `already attached` with **no** detach request | run window | raw |
| `20261011064508-fuzzy-wolf-6cb9/observer/restore-events-final.json` | reader-side `FailedAttachVolume`: `Multi-Attach error for volume "pvc-0aa3ec7c-…" Volume is already exclusively attached to one node and can't be attached to another` at 06:56:12Z; the incremental's PV attached at 06:56:13Z (3 events total) | 06:56:12Z–06:56:13Z | raw |
| `20261011064508-fuzzy-wolf-6cb9/observer/virt-handler-ds-baseline.json` | virt-handler DaemonSet spec → image digest | pre-injection | raw |
| `20261011064508-fuzzy-wolf-6cb9/test-run-report.md` | Finding 1 (attachment leak), environment table, UTC timeline, acceptance table with restore/data verification `BLOCKED` | run window | derived |
| `20261011-win-f05-r01/observer/launcher-compute.log` | the exact-backup-name `msg=Backup started` signal and the copy window | 13:40:18Z | raw |

**Draft-cited paths and command forms, preserved verbatim from the reporter draft** (so this ticket's
evidence index still matches the original record): the repository-relative paths
`cbt-chaos/scenarios_v2/CBT-F-05/runs/20261011-win-f05-r01/observer/events.jsonl`,
`cbt-chaos/scenarios_v2/CBT-F-05/runs/20261011-win-f05-r01/observer/restore-verifier-events.json` and
`cbt-chaos/scenarios_v2/CBT-F-05/runs/20261011064508-fuzzy-wolf-6cb9/test-run-report.md` ("and run
artifacts"); and the draft's placeholder command forms
`oc delete pod <virt-handler-pod> -n openshift-cnv --wait=false`,
`oc get events -n <vm-namespace> --field-selector involvedObject.name=<vm-name>` and
`oc get volumeattachment -o json | jq '.items[] | select(.spec.source.persistentVolumeName == "<backup PV name>") | {name: .metadata.name, node: .spec.nodeName, attached: .status.attached}'`
— the steps in this ticket use the same commands with the run's concrete names substituted.

**Not retained in this repository** (draft-only, do not re-quote as an artifact): the Windows run's
`VolumeAttachment` name `csi-1dbaa20e1c8daff5370ddb1a4303628e25a7bb9fc8c48d6eda2809456fe84559` — it
was recorded by a live post-run read while triaging the Windows run; the local pack keeps the
*events* (Multi-Attach, HotplugFailed/SyncFailed) that establish the same state. The RHEL 9 run's
attachment hash, by contrast, **is** a retained artifact (row above).

**UTC timeline** (setup → precondition → injection → effect → failure → recovery):

| # | Time (UTC), 2026-10-11 | Event | Source |
|---|---|---|---|
| 1 | 06:54:04Z / 13:40:08Z | Full backup CR + destination PVC created; `VolumeAttachment` created attached to `<vm-node>` | RHEL 9 `volumeattachment-final.json` (06:54:04Z); Windows `timeline.md` (13:40:08Z) |
| 2 | 06:54:12.936Z / 13:40:18.303Z | Exact-backup-name `"msg":"Backup started"` signal (copy active) | both runs' launcher logs / `trigger.log` |
| 3 | ~06:54:13Z / 13:40:31Z | **Injection**: handler pod (`virt-handler-mlvzn` UID 95b1af4c… / `virt-handler-jg4pg` UID d0cf7d37…) deleted on `<vm-node>` | runs' reports + customs watch `Killing`/`DELETED` frames |
| 4 | 06:54:22–24Z / 13:40:26–53Z | Replacement handler Ready on the same node; DaemonSet 28/28 | RHEL 9 report; Windows `timeline.md` |
| 5 | 06:55:19Z / 13:40:52Z | **Effect**: backup terminal `Done=True` "Successfully completed VirtualMachineBackup" **and**, in the same second, `HotplugFailed` + `SyncFailed` for the backup-target volume | both runs' reports/events |
| 6 | 06:56:08Z / 13:43:12Z | Same-VM incremental backup terminal `Done=True` (control: the flow keeps working) | runs' reports |
| 7 | 06:56–07:28Z / 13:43:16–14:15:32Z | **Failure**: reader pod Pending on Multi-Attach for the full 1800 s window (only the full backup's volume was stuck; the incremental's volume attached) | `restore-events-final.json`; `restore-verifier-events.json` / `timeline.md` |
| 8 | end of run, both runs | **Recovery**: none attempted — leak preserved for triage | runs' `preserved.md` / reports |

**Retained state.** Both runs left the objects in place: the backup CRs (full + incremental, both
`Done=True`), the tracker at the incremental's child checkpoint, the destination PVCs `Bound`, and —
as the defect — the leaked node attachment on the backup PV. Nothing was deleted to "clean up" the
defect in these two run labels; the deliberate cleanup path (delete `VolumeAttachment` + restart the
replacement handler) was exercised only in the third run label, `20261012-cbtf05-r01` (2026-10-12),
and is documented in the companion ticket. The virtual machines were kept (they are the source VMs
this backup family exists for); the reader pod's failed attempt was left as evidence, not re-run in
these runs.

## Negative results and what would falsify this ticket

- **Refuted: "this is a backup failure."** Both backups reached `Done=True` with success reasons,
  correct checkpoints, and a working same-VM incremental follow-up; the backup data path is intact.
  Ruled out by the terminal states in both runs.
- **Refuted: "guest-OS-specific."** The signature is identical on a RHEL 9 guest and a Windows Server
  2022 guest on the same cluster/build.
- **Refuted: "the reader pod's block is a scheduling problem."** The reader pod failed with an
  explicit Multi-Attach / `FailedAttachVolume` for the full backup's PV while the *incremental's*
  volume attached successfully on the same node — i.e. attachment-specific, not node-specific
  (`restore-verifier-events.json`).
- **Refuted (within these runs): "a leak always accompanies a handler restart."** The RHEL 9 run's
  cluster-wide check found this attachment to be the only leaked backup-volume attachment at that
  time, so the effect is per-interaction, not a blanket consequence of any restart.
- **Refuted: "`HotplugFailed` alone implies the leak."** In the Windows run the same
  `HotplugFailed` reason ("failed to mount filesystem hotplug volume
  `vm-incremental-20261011-win-f05-r01-p01-backup-target-pvc`: lstat /proc/1/root/…") fired at
  13:43:12Z while the `hotplug-disk` container of the *incremental's* attachment pod was being
  stopped — a teardown that ran with a healthy handler (replacement Ready since 13:40:53Z) — and left
  **no** leaked attachment: that volume attached on the other node at 13:43:24Z
  (`observer/events.jsonl`, `observer/restore-verifier-events.json`). So the event is necessary but
  not sufficient; what distinguishes the leaked case is that the restarting handler is still holding
  the volume's mount (see the sibling ticket's `investigation/rbd7-holder.txt`). [INFERENCE] on the
  distinguishing mechanism; the two artifact observations above are independent.
- **Not tested here (so not claimed):** whether the same leak appears with **no** disruption at all;
  whether the leak self-heals given a longer window (the third run label's leak persisted ~2 h until
  manual cleanup); whether Detach/Delete calls reach CSI at all after the failed unplug.
- **Falsifiers.** This ticket is wrong, or a non-issue, if any of the following holds:
  1. `VolumeAttachment` for a backup PV is *contractually* meant to persist while the source VM runs
     (then the defect is that the contract is undocumented and no release condition exists) — a
     triage/API-contract answer, not an artifact.
  2. A longer, uninterrupted observation shows the attachment being released without operator action.
  3. A clean (non-restarted) handler also leaves the attachment behind — then the restart is not the
     trigger and the ticket's precondition is wrong.
  4. The reader pod's failure is shown to be an unrelated attach-detach controller bug reproducible
     without any leaked attachment on the VM's node.

## Additional feedback (reporter's notes)

- **Open triage questions (from the draft, preserved).**
  - Is a lingering backup-volume attachment while the source VM runs an intentional contract (e.g. for
    follow-up incrementals) or orphaned state? If intentional, the contract needs a documented
    release condition.
  - Should the hotplug cleanup failure (`SyncFailed: failed to remove hotplug disk directory`) be
    retried by the controller, or should a terminal backup trigger an independent detach
    reconciliation?
  - Is the `HotplugFailed`/`SyncFailed` at backup-completion time causally tied to the earlier handler
    restart, or is it an independent cleanup race that also occurs without disruption?
- **Smallest experiment that settles the main question.** A control run on the same cluster with **no
  injection**: take a full backup and watch, after `Done=True`, whether the `VolumeAttachment` for the
  backup PV disappears on its own (and how fast). If it does not disappear even without disruption,
  the precondition in this ticket is wrong; if it does, the restart→leak causality stands. Second
  cheap experiment: repeat the injection and watch whether any Detach/Unstage call reaches the CSI
  driver for that volume after the failed unplug.
- **Triage question that decides scope.** Is the fix expected in virt-handler's hotplug cleanup
  (retry/terminal-state handling) or in the backup controller (own the detach of a terminal backup)?
  The two have different owners and different regression tests.
- **Cross-references.**
  - Sibling ticket in this folder: `leaked-hotplug-attachment-on-handler-restart.md` — same behaviour
    family, third run label `20261012-cbtf05-r01` (2026-10-12), with the *verified recovery*
    procedure and the RBD-side evidence (handler holding the mapped device, `rbd unmap` EBUSY loop,
    exclusive-lock watcher). Read the two together: this ticket is the filed defect with two
    independent runs; the sibling is the longer evidence narrative and the operator runbook.
  - Related, **not** part of this ticket (different defect class, different component): both runs also
    recorded a contradictory failure event on backups whose terminal state was success — the RHEL 9
    run on the post-chaos incremental (`VirtualMachineBackupCompletedSuccessfully` +
    `VirtualMachineBackupFailed("Backup has failed: VMI backup status was lost")` at 06:56:08Z) and
    the Windows run on the *full* backup at 13:40:52Z, the same second as its success event
    (`observer/events.jsonl`, count 1, message verbatim `Backup has failed: VMI backup status was
    lost`). This is an event-semantics/masking question (the same class as the one masking the real
    ENOSPC in CBT-EXP-07), tracked by the scenario's own analyses, not by this ticket.
  - Harness/tooling gap (clearly separate): the workflow's own restore stage cannot distinguish
    "restore blocked by a leaked attachment" from "restore failed"; the runs classified it `BLOCKED`.
    No harness ticket is filed by this ticket.
- **Environment-specific notes for the next reproducer.** (a) The event timestamps are
  second-granularity, so the ordering of "backup terminal" vs "cleanup failure" within the same second
  cannot be resolved from Kubernetes events — use the launcher log for sub-second ordering. (b) The
  copy must still be running when the handler is deleted; deleting before `"Backup started"` or after
  terminal does not reproduce. (c) The reader pod must be scheduled to a *different* node, otherwise
  the leak is invisible. (d) Do not delete or reuse the backup PV of a leaked attachment — keep the
  object for triage.

## Sanitisation checklist

- [x] No credentials, tokens, kubeconfig contents or private keys — none quoted; all object
      identities are run-scoped names/UIDs.
- [x] No private hostnames or absolute host paths — cluster node names are genericised as
      `<vm-node>` / `<reader-node>`; the only path-like strings kept are verbatim product message
      fragments (`lstat /proc/1/root`) and container-internal paths inside sanitized quotes.
- [x] No broad selectors (names or run-scoped labels only) — all reads are scoped to the run's exact
      VM/backup/PVC names or to the backup PV; the `label: kubevirt.io=virt-handler` +
      `spec.nodeName` selector in the steps resolves exactly one pod on one node.
- [x] No destructive commands other than the documented, scoped workaround — the only delete in the
      steps is the injected `oc delete pod <virt-handler-pod>` on the VM's node; the recovery
      (delete the orphaned `VolumeAttachment`, restart the replacement handler) is described, marked
      as the sibling ticket's live-verified procedure, and scoped to the run's own objects.
- [x] Commands are the ones actually validated (illustrative ones are labelled) — the injection and
      inspection commands are the ones the runs used; the note above the steps says which command
      shapes are re-creations.

# [Bug]: Checkpoint redefinition reports success while silently dropping a disk whose bitmap is missing, and leaves the tracker advertising that disk

## What this is, in one paragraph

A KubeVirt VM's incremental backups are described in two metadata layers: a libvirt **checkpoint**
inside the VM's helper pod (`virt-launcher`), which says which disks the backup chain really covers,
and a **dirty bitmap** per disk — the change-tracking map inside the running VM's QEMU process that
the checkpoint names for that disk. A `VirtualMachineBackupTracker` object (the **tracker**) is what
an operator or tooling reads to learn what the chain protects. When the VM restarts, `virt-controller`
**redefines** the checkpoint from the disks that still have a bitmap. In this defect one disk
(`datadisk`/`vdb`) had lost its bitmap, so the rebuilt checkpoint covered only `rootdisk`/`vda` — yet
the redefinition logged plain success and the tracker went on advertising both disks, with no error and
no warning. Anyone reading the tracker is told a disk is protected when neither the checkpoint nor QEMU
covers it.

**When → then → expected**

- **When** a VM with CBT (changed-block tracking, the feature that makes incremental backups possible)
  enabled restarts — its `VirtualMachineInstance` (VMI, the running-instance object) is deleted and
  re-created — while the checkpoint's dirty bitmap is missing for one of its disks, and the
  checkpoint-redefinition path runs on that restart.
- **And** the disruption **CBT-EXP-06 — per-disk checkpoint-bitmap removal** (`chaos-trigger.sh`; **not a krknctl scenario** — krkn's 38 tags include no primitive that can touch a guest QEMU dirty bitmap) is applied: the datadisk's (`vdb`, node `libvirt-2-format`) checkpoint bitmap is removed by one QMP (`qemu-monitor-command`) `block-dirty-bitmap-remove` call, leaving only `rootdisk` (`vda`) with a bitmap, and the VMI is then deleted so the restart fires the redefinition.
- **Then (current behaviour):** the redefinition reports plain success — `virt-controller` logs "Checkpoint redefinition successful" at 04:28:45.625161Z with no warning — while the checkpoint it produced declares only `<disk name='vda' checkpoint='bitmap' bitmap='vm-backup-20261016-exp06-r02-2026-10-16_04-27-24'/>` (no `vdb` element) and the tracker still advertises `status.latestCheckpoint.volumes` = `[vda/rootdisk, vdb/datadisk]` (rv `27322960`, 04:28:48.689Z) and the datadisk's QEMU node `libvirt-2-format` has an empty bitmap list. The metadata an operator reads no longer describes the same disk set QEMU is tracking.
- **Expected behaviour:** the redefinition must not silently accept a checkpoint it cannot fully honour — for every disk whose bitmap is missing it must either invalidate the checkpoint and fall back to a clean full backup, or exclude the disk with the exclusion reported (event, condition or log at default verbosity) — and the tracker's `status.latestCheckpoint.volumes` must be updated or invalidated to match the checkpoint actually produced.

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
> - Sanitize: no credentials, tokens, kubeconfig contents, private hostnames, absolute host paths,
>   broad selectors, or cluster-cleanup commands.
>
> Delete this preamble in the filed ticket; keep the structure below.

## At a glance

| Field | Value |
|---|---|
| Issue type | **Bug** — demonstrated violation of two established expectations at once: a redefinition that reports plain success with a partially covered checkpoint, and a tracker whose `status.latestCheckpoint.volumes` advertises a volume the checkpoint does not cover. Both are observable facts, not ambiguous contracts. |
| Priority (proposed) | **High** — data-protection metadata integrity (the chain-coverage answer an operator gets is wrong) *and* the standing precondition of the P1 availability wedge. Unassigned pending triage. |
| Severity class | data protection (chain-coverage metadata integrity), with an availability precondition |
| Owning component (suspected) | **suspected** CNV/KubeVirt backup stack: the virt-launcher checkpoint path (`RedefineCheckpoint` / `findDisksWithCheckpointBitmap`, per the source anchors in `docs/findings/finding-1-backup-cr-livelock.md` §8, kubevirt v1.8.4-era) together with the `VirtualMachineBackupTracker` status writer; API surface `backup.kubevirt.io/v1alpha1`. The probe's silent-success behaviour is **inference from the source anchor plus the observation** (see Status / confidence). |
| Component(s) proven involved | virt-launcher + QEMU (they produced the `vda`-only checkpoint and the per-disk bitmap state) and the tracker status writer (it kept advertising `vda`+`vdb`). The virt-controller is proven to have logged the redefinition as successful with no warning. |
| Reproducibility | `deterministic state divergence` — the split (checkpoint covers `vda` only; tracker advertises both; QEMU agrees with the checkpoint) reproduced on r01 leg B (2026-10-14) and on all three r02 passes (2026-10-16). It survived a manual tracker repair and was still the checkpoint's real coverage when the chain was discarded. |
| Status / confidence | **Confirmed behaviour, high confidence** for the observable split. The **downstream consequence claimed here is deliberately narrower** than the original hypothesis and is stated precisely: the split does *not* silently produce a completed incremental missing a disk (see Negative results). The claim "the probe deliberately excluded the disk but never reported it" is **inference** from the code anchor plus the observed silent success. |
| Blast radius | one VM's incremental-chain metadata (the tracker object and any tooling that reads it); plus the availability consequence once a later pass quotes the uncovered disk (P1). Not cluster-wide. |
| Data at risk? | **Metadata yes, backup data no** — chain-coverage metadata is wrong (a volume covered by neither checkpoint nor bitmap is advertised as protected), but no completed backup was observed to lose a disk, and no source data is touched. |
| Related scenario / execution | `CBT-EXP-06` / `20261016-exp06-r02` (2026-10-16, closed `BLOCKED`; redefinition at 04:28:45Z, divergence stable through the whole session and all follow-ups); antecedent `CBT-EXP-06` / `20261014-exp06-r01` (2026-10-14, leg B); post-close `20261016-exp06-r02-leg1-tracker-repair` (06:35Z–06:56Z) and `…-leg2-chain-discard` (07:00Z–07:01Z). |
| Affected versions | short pointer — OpenShift 4.22.15, CNV `kubevirt-hyperconverged-operator.v4.22.12`, libvirt 11.10.0 / QEMU 10.1.0 in the launcher, `backup.kubevirt.io/v1alpha1`. The full measured matrix is in **Environment** below. |

## Context (for an engineer new to this area)

- **What the feature does** — KubeVirt keeps incremental-backup chain bookkeeping in two metadata
  layers: a libvirt **checkpoint** object inside the launcher, which records which disks it really
  covers (per-disk dirty bitmaps), and the `VirtualMachineBackupTracker` CR, which records what the
  VM's backup chain is believed to cover (the latest checkpoint and its volumes). When a VMI restarts,
  the checkpoint is **redefined**: the launcher probes each disk's QEMU dirty bitmap and rebuilds the
  checkpoint from the disks that still have one.
- **Where the failure sits** — the `VirtualMachineBackupTracker`'s
  `status.latestCheckpoint.volumes` field (it lists a disk the checkpoint does not cover), together
  with the *absence* of any warning/event/condition from the redefinition and the checkpoint XML that
  the launcher produced.
- **Observed surface vs. origin** — the surface an operator reads (the tracker CR) is not the site
  that holds the truth (the libvirt checkpoint + QEMU bitmaps). The two disagree silently, and the
  redefinition — the operation that produced the disagreement — reports plain success.
- **Why it matters** — an operator or tooling reading the tracker to learn "what does this VM's
  incremental chain protect?" gets a wrong answer, and a *silent* one: the next pass quotes the
  uncovered disk and is loudly refused (P1), wedging the VM's backups. The wrong metadata is the
  standing state an operator sees while the VM cannot be backed up.

## Environment (measured, not assumed)

Measured once for this defect set and re-stated in full in each ticket, so this ticket stands alone.
Rows marked `set-wide` are identical across all six tickets (P1–P6); rows marked `ticket-specific`
are the ones only this ticket turns on.

| Layer | Component | Version / identifier | How obtained | Scope |
|---|---|---|---|---|
| Platform | OpenShift Container Platform (server and `oc` client) | 4.22.15 — server and client both 4.22.15; `oc version` also reports kustomize v5.7.1 | `oc version`, `oc get clusterversion version` | set-wide |
| Platform | Kubernetes API | v1.35.6 | `oc version` | set-wide |
| Platform | OpenShift update channel | `not recorded` — the channel was not captured in this run's preflight or later | `oc get clusterversion version -o jsonpath='{.spec.channel}'` (not run) | set-wide |
| Platform | `oc`/`kubectl` plugin versions beyond the above | `not recorded` — only the `oc` server/client version and bundled kustomize were captured | `oc plugin list` (not run) | set-wide |
| Nodes | OS image | Red Hat Enterprise Linux CoreOS 9.8.20260915-0 (Plow) | `oc get nodes -o wide` | set-wide |
| Nodes | kernel | 5.14.0-687.48.1.el9_8.x86_64 | `oc get nodes -o wide` | set-wide |
| Nodes | container runtime | cri-o 1.35.8-11.rhaos4.22.giteaf45bc.el9 | `oc get nodes -o wide` | set-wide |
| Nodes | topology / node in scope | the storage pool node in scope is the single worker running the hostpath CSI DaemonSet (`hostpath-provisioner-csi`, namespace `openshift-cnv`); its name is deliberately genericised here as `<node>` | `oc get nodes`; `oc get ds hostpath-provisioner-csi -n openshift-cnv -o wide` | set-wide |
| Virtualization | CNV / HCO CSV | `kubevirt-hyperconverged-operator.v4.22.12` | `oc get csv -A` | set-wide |
| Virtualization | kubevirt observed version | `status.observedKubeVirtVersion` equals the virt-operator image digest `sha256:2f654df4f4b026b85abc62bfe834a842b3a49b054f97a5999a85443320a29293` (`registry.redhat.io/container-native-virtualization/virt-operator-rhel9@…`) | `oc get kubevirt -n openshift-cnv -o jsonpath='{.status.observedKubeVirtVersion}'` | set-wide |
| Virtualization | virt-launcher image digest (per-guest) | `registry.redhat.io/container-native-virtualization/virt-launcher-rhel9@sha256:2131d3d24616971b92d7e986635673b6dc731da3d43cae46540882993d36596f` | `oc get pod <launcher> -o jsonpath='{.spec.containers[*].image}'` | set-wide |
| Virtualization | virt-handler / virt-controller image digests | `not recorded` — not captured for this run (the pack's `observer/effect/facts-digest.json` is a stream/state first-seen digest and carries no image fields; only the virt-launcher digest above was recorded) | `oc get ds virt-handler -n openshift-cnv -o jsonpath='{.spec.template.spec.containers[*].image}'`, `oc get deploy virt-controller -n openshift-cnv -o jsonpath='{.spec.template.spec.containers[*].image}'` (not run) | set-wide |
| Virtualization | libvirt / QEMU / QEMU API in the launcher | libvirt 11.10.0 (compiled and running), QEMU 10.1.0, QEMU API 11.10.0 | `virsh version` in the launcher's `compute` container | set-wide |
| Backup API | CRD group / version | `backup.kubevirt.io/v1alpha1` (`virtualmachinebackups`, `virtualmachinebackuptrackers`); the CRD was created 2026-09-28T14:39:02Z | `oc get crd virtualmachinebackups.backup.kubevirt.io -o jsonpath='{.metadata.creationTimestamp}'` | set-wide |
| Storage (in use) | StorageClass + provisioner + pool | `cbt-demo-hpp` / `kubevirt.io.hostpath-provisioner` / pool `cbt-demo-pool` | `oc get sc -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner` | set-wide |
| Storage (in use) | HostPathProvisioner CR | `cbt-demo-hpp`, pool path `/var/hpvolumes`, workload nodeSelector pinned to that one worker | `oc get hostpathprovisioner cbt-demo-hpp -o yaml` | set-wide |
| Storage (in use) | CSI driver image + version | DaemonSet `hostpath-provisioner-csi` (namespace `openshift-cnv`), image `registry.redhat.io/container-native-virtualization/hostpath-csi-driver-rhel9@sha256:72cdfd4ab6621148bf2a70485394d335d9ccc5045ab0aa82018e72472444bf6b`, `VERSION=v4.22` | `oc get ds hostpath-provisioner-csi -n openshift-cnv -o jsonpath='{.spec.template.spec.containers[*].image}'` | set-wide |
| Storage (in use) | **pool-filesystem trap** | the CSI data directory `/var/hpvolumes/csi` sits on its **own** filesystem (`/dev/sdb`, XFS, ~1.5 TiB) while its parent `/var/hpvolumes` is on `/dev/sda4` — measuring free space on the parent reports the wrong filesystem, so every capacity figure below is for `/var/hpvolumes/csi` | `df -B1 /var/hpvolumes/csi` from the driver pod / on `<node>` | set-wide |
| Storage (in use) | observed free space | 140.0 GiB before the run → 40.25 GiB after it → 119.97 GiB after the approved reclaim of the run's own 80 GiB full-backup PVC | `df -B1 /var/hpvolumes/csi`; the 40.25 GiB point also in `followup/20261016-exp06-r02-same-vm/f3-result.json#pool_free_before_bytes` = 43215937536 | set-wide |
| Storage (in use) | sizing facts | a clone DataVolume materialises the whole 80 GiB disk and a full backup image is fully allocated (~80 GiB) — the reason one follow-up leg that would have needed a fresh full-backup PVC was refused for capacity | run pack DataVolume/PVC objects + the `df` pair above | set-wide |
| Storage (present but **NOT** exercised) | ODF/OCS stack | `4.22.5-rhodf` operators (`odf-operator`, `ocs-operator`, `rook-ceph-operator`, `cephcsi-operator`, `mcg-operator`, `odf-csi-addons-operator`, external-snapshotter), RHCS 9 Ceph image `sha256:926d15fddae065a1e82b3634f80847253fa2cc14e9888e15b19b72a2cf144a58`, cluster health `HEALTH_OK` — installed but **not part of this scenario**: every volume here is `cbt-demo-hpp` (stated so triage does not chase a Ceph hypothesis) | `oc get csv -n openshift-storage`, `oc get cephcluster -n openshift-storage -o jsonpath=…` | set-wide |
| Storage (present but **NOT** exercised) | local-storage-operator | `local-storage-operator.v4.22.0-202609291750` — installed, not exercised by this scenario | `oc get csv -A` | set-wide |
| Guest | OS release, kernel | RHEL 9.8 (Plow); kernel 5.14.0-687.5.1.el9_8.x86_64 | `cat /etc/redhat-release`, `uname -r` in the guest | set-wide |
| Guest | guest agent package | `qemu-guest-agent-10.1.0-17.el9_8` | `rpm -q qemu-guest-agent` | set-wide |
| Guest | vCPU / memory | 1 vCPU; 2 GiB configured (≈1 GiB visible to the guest) | VM spec vs `nproc` / `free` in the guest | set-wide |
| Guest | disks | `rootdisk`/vda 80 GiB cloned from the RHEL 9 DataSource; `datadisk`/vdb 2 GiB blank, ext4 mounted at `/mnt/datadisk` | VM spec; `virsh domblklist <domain>` | set-wide |
| Guest | root-disk filesystem type | `not recorded` — the root disk's filesystem was not captured (the datadisk is ext4, above) | `lsblk -f` in the guest (not run) | set-wide |
| Harness (**internal only** — not part of the product defect) | workflow + trigger checksum | `virt-cbt-lab` workflow; trigger sha256 `9291f017a605ad0cee49e754d4eebe0f38e9d89db0ae19ad3f489366dd241f92` for this run (its validated diff is in the run pack) | run pack | set-wide |

**Load-bearing versions.** The QEMU/libvirt version matters: this repro drives `query-named-block-nodes`
and `block-dirty-bitmap-remove` over QMP, and the decisive error text (`checkpoint inconsistent:
missing or broken bitmap …`) is QEMU's own. The pool-filesystem trap matters too — capacity was
measured on `/var/hpvolumes/csi` (`/dev/sdb`), not on its parent filesystem, and a measurement on the
parent gives the wrong answer.

**Storage present but not exercised.** ODF/OCS and local-storage are captured only to bound the
search space; nothing in this ticket depends on them. The only storage path in play is the hostpath
CSI pool `cbt-demo-hpp` on the single worker `<node>`.

## Reproducibility

- **Classification**: deterministic state divergence. The three-layer split is exact and stable
  whenever the precondition holds.
- **Attempts**: reproduced on r01 leg B (2026-10-14) and on all three r02 passes (2026-10-16) — 4/4
  states; the divergence survived the whole session, the same-VM follow-up, and a manual tracker repair
  (leg 1).
- **Stability** — exact every time: the redefinition logs success with no warning; the checkpoint XML
  declares only the surviving disk; the tracker advertises both; QEMU agrees with the checkpoint.
  Varying: only the timestamps and how long the state was observed.
- **Preconditions**: a VMI restart while one disk's QEMU checkpoint bitmap is absent and the tracker
  still names it. What breaks the repro: a healthy bitmap set (the redefinition then keeps the full
  disk set — the regression case in Expected behaviour).
- **Second entry path**: not separately attempted. The divergence follows from the redefinition probe,
  so any path that removes one disk's bitmap before a restart should show it; that is **[INFERENCE]**.
- **Attribution caveat (must not be dropped)**: the *heterogeneous state* (tracker vs checkpoint vs
  QEMU disagreeing) must be attributed to the product's own surfaces — not to the removal — because
  r02's pre-removal bitmap state was witnessed only by the injector
  (`checkers/injection-validity.json` REJECT; `observer/effect/pre-bitmap-history.jsonl`, 0 rows with
  `target_present=true`). The wedge that follows this state is reproduced on a path with no injection
  (leg 1).

## Steps to reproduce (exact commands and injection timing)

> Validated in-run (r02 trigger plus follow-ups). Prerequisites: a dedicated cluster, a fresh
> run-scoped VM and new object names; never reuse another run's names. The commands below are
> illustrative re-creations of the recorded shapes.

The object names below are the **recorded names of run `20261016-exp06-r02`** (namespace `vm-cbt-demo`),
verbatim from that run's artifacts — they are not placeholders. To run this on your own fresh cluster,
create equivalents under your own run-scoped names and substitute them everywhere below; nothing else
in the procedure changes. All objects live in namespace `vm-cbt-demo`.

**Concrete objects used in this report**

| Kind | Name | uid | Created (UTC) | Fate |
|---|---|---|---|---|
| VirtualMachine | `vm-20261016-exp06-r02` | `00c5615f-a7ea-4899-90e0-167cf912b0f0` | not recorded | kept; runStrategy Always, 1 vCPU / 2 GiB |
| DataVolume (rootdisk, vda) | `vm-disk-20261016-exp06-r02` | not recorded | not recorded | kept; 80 GiB clone of the RHEL 9 DataSource |
| DataVolume (datadisk, vdb) | `vm-data-20261016-exp06-r02` | not recorded | not recorded | kept; 2 GiB blank, ext4 mounted at `/mnt/datadisk` |
| Service (SSH) | `vm-ssh-20261016-exp06-r02` | not recorded | not recorded | kept |
| VMI (before the injection) | `vm-20261016-exp06-r02` | `968b6e7e-c021-46e4-a731-ca0dbec6121f` | not recorded | deleted by the injection at 04:28:22Z |
| VMI (after the injection) | `vm-20261016-exp06-r02` | `9651acfc-1e0d-4c4e-ad94-581e2c4cdf11` | not recorded | Running with CBT Enabled at 04:28:45Z |
| Pod (virt-launcher, before) | `virt-launcher-vm-20261016-exp06-r02-ljm2w` | `1160f767-7cbb-4352-a5cf-3ee37aac611d` | not recorded | replaced with the VMI |
| Pod (virt-launcher, after) | `virt-launcher-vm-20261016-exp06-r02-rwzzr` | `6bb8b6c5-e7af-4ee8-84d6-a689c4159ece` | not recorded | kept through the wedge |
| libvirt domain | `vm-cbt-demo_vm-20261016-exp06-r02` | n/a | not recorded | recreated with the replacement VMI |
| VirtualMachineBackupTracker | `vm-tracker-20261016-exp06-r02` | not recorded | not recorded | deleted in leg 2 L3 (chain discard); re-created in leg 2 L4 |
| Checkpoint (the one whose datadisk bitmap was removed) | `vm-backup-20261016-exp06-r02-2026-10-16_04-27-24` | n/a | 04:27:24Z | still advertised by the tracker after the bitmap was gone |
| VirtualMachineBackup (control full) | `vm-backup-20261016-exp06-r02` | `4adf728a-a38f-4a23-878d-e466965180e4` | 04:27:24Z | `type=Full`, `Done=True` 04:28:20Z, `includedVolumes=[rootdisk,datadisk]`; CR kept, destination PVC deleted 2026-10-16 on operator approval |
| PersistentVolumeClaim (control full destination) | `vm-backup-pvc-20261016-exp06-r02` | not recorded | not recorded | 80 GiB, fully allocated; **deleted** 2026-10-16 on operator approval to reclaim pool space |
| VirtualMachineBackup (pass 1) | `vm-incremental-20261016-exp06-r02-p01` | `46b6f5e1-ced6-4094-8c96-e4d7690c3ea0` | 04:29:26Z | wedged; CR deleted in follow-up F2 (finalizer released in 3 s) |
| PersistentVolumeClaim | `vm-incremental-pvc-20261016-exp06-r02-p01` | not recorded | not recorded | **kept**, `Bound`, ~0 bytes |
| VirtualMachineBackup (pass 2) | `vm-incremental-20261016-exp06-r02-p02` | `72272cb4-be66-4cdd-a880-85d3b850c134` | 05:35:13Z | wedged; CR deleted in leg 1 L2 (3 s) |
| PersistentVolumeClaim | `vm-incremental-pvc-20261016-exp06-r02-p02` | not recorded | not recorded | **kept**, `Bound` |
| VirtualMachineBackup (pass 3) | `vm-incremental-20261016-exp06-r02-p03` | `55907953-1f2b-476f-a095-9f4934bb07ff` | 06:36:00Z | wedged; CR deleted in leg 2 L2 (2 s) |
| PersistentVolumeClaim | `vm-incremental-pvc-20261016-exp06-r02-p03` | not recorded | not recorded | **kept**, `Bound` |
| VirtualMachineBackup (never admitted) | `vm-followup-20261016-exp06-r02-f01` | n/a — **never created** | n/a — admission rejected it (see the deadlock ticket) | its 3 GiB PVC `vm-followup-pvc-20261016-exp06-r02-f01` was created and then removed |
| VirtualMachineBackup (post-recovery full) | `vm-followup-full-20261016-exp06-r02-f02` | not recorded | 07:00Z | `type=Full`, `Done=True` 07:00:53Z, `includedVolumes=[rootdisk,datadisk]` |
| PersistentVolumeClaim (post-recovery full destination) | `vm-followup-full-pvc-20261016-exp06-r02-f02` | not recorded | not recorded | 80 GiB; **kept** |
| Checkpoint (created against the re-created tracker) | `vm-followup-full-20261016-exp06-r02-f02-2026-10-16_07-00-35` | n/a | 07:00:35Z | new both-disk checkpoint after the chain discard |

**Which CRs were deleted, and by which leg:** the pre-injection VMI (uid
`968b6e7e-c021-46e4-a731-ca0dbec6121f`) was deleted by the injection itself at 04:28:22Z; the three
wedged `VirtualMachineBackup` CRs were deleted during the follow-ups as the documented unblock — `…-p01`
in follow-up F2 (finalizer released in 3 s), `…-p02` in leg 1 L2 (3 s), `…-p03` in leg 2 L2 (2 s); the
tracker `vm-tracker-20261016-exp06-r02` was deleted in leg 2 L3 (chain discard) and re-created in
leg 2 L4; `vm-followup-20261016-exp06-r02-f01` was never created at all (admission rejected it, and its
3 GiB PVC was removed again). **Which PVCs were kept:** the VM's DataVolumes and SSH service, the three
incremental destination PVCs (`vm-incremental-pvc-…-p01/-p02/-p03`, `Bound`) and the post-recovery full
destination `vm-followup-full-pvc-20261016-exp06-r02-f02` (80 GiB). Only the control full's 80 GiB
destination PVC `vm-backup-pvc-20261016-exp06-r02` was deleted (2026-10-16, operator approval) to
reclaim pool space.

**Step 1 — Set up the two-disk RHEL 9 VM with CBT enabled and take the control full backup.** *Run this first,
on a dedicated cluster, before anything else.* The VM is `runStrategy: Always`, 1 vCPU / 2 GiB, with
`rootdisk`/vda (80 GiB clone of the RHEL 9 DataSource in DataVolume `vm-disk-20261016-exp06-r02`) and
`datadisk`/vdb (2 GiB blank, ext4 mounted at `/mnt/datadisk`, DataVolume `vm-data-20261016-exp06-r02`),
plus the SSH service `vm-ssh-20261016-exp06-r02`; CBT must be enabled on the VM template. With the VM
running, apply the tracker, the destination PVC and the full backup in one go:
```bash
oc apply -f - <<'YAML'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackupTracker
metadata:
  name: vm-tracker-20261016-exp06-r02
  namespace: vm-cbt-demo
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: 20261016-exp06-r02
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: vm-20261016-exp06-r02
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vm-backup-pvc-20261016-exp06-r02
  namespace: vm-cbt-demo
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: 20261016-exp06-r02
spec:
  storageClassName: cbt-demo-hpp
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 80Gi
---
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-backup-20261016-exp06-r02
  namespace: vm-cbt-demo
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: 20261016-exp06-r02
spec:
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261016-exp06-r02
  pvcName: vm-backup-pvc-20261016-exp06-r02
YAML
```
Then wait for the control full to finish and check it:
```bash
oc get vmbackup vm-backup-20261016-exp06-r02 -n vm-cbt-demo -o json \
  | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes}'
```
**Must see:** `status.type` = `Full`, a condition of type `Done` with `status=True` (recorded
04:28:20Z), and `status.includedVolumes` listing **both** `rootdisk` and `datadisk`. If the full
does not reach that state, the precondition for this defect is not set up — stop here.

**Step 2 — Locate the launcher pod and the libvirt domain, and record the healthy baseline.** *Run this once
the VMI is `Running` with CBT `Enabled`, after step 1.*
```bash
oc get pod -n vm-cbt-demo -l vm.kubevirt.io/name=vm-20261016-exp06-r02 -o jsonpath='{.items[0].metadata.name}'
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- \
  virsh list --all
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- \
  virsh domblklist vm-cbt-demo_vm-20261016-exp06-r02
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- \
  virsh checkpoint-dumpxml vm-cbt-demo_vm-20261016-exp06-r02 vm-backup-20261016-exp06-r02-2026-10-16_04-27-24
oc get vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.status.latestCheckpoint}{"\n"}'
```
**Must see:** the first command prints the pre-injection launcher pod
`virt-launcher-vm-20261016-exp06-r02-ljm2w`; the domain is `vm-cbt-demo_vm-20261016-exp06-r02`;
`domblklist` shows `vda` (rootdisk) and `vdb` (datadisk, backed by the overlay
`/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2`); the checkpoint XML lists **both**
disks; and `status.latestCheckpoint` carries `name` = `vm-backup-20261016-exp06-r02-2026-10-16_04-27-24`
with `volumes` = `[vda/rootdisk, vdb/datadisk]`. Record this baseline — step 8 compares against it.

**Step 3 — PRE-check (fail closed): confirm both disks carry the checkpoint bitmap before touching anything.**
*Run immediately after step 2 and before step 4.* This pre-state read must be witnessed by a party
other than the injector: in r02 only the injector read it, and the run's injection checker REJECTed
on that gap (`checkers/injection-validity.json`).
```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- \
  virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}' \
  | jq -r '.return[] | "\(.nodeName): \([.dirty-bitmaps[]? | .name + " recording=" + (.recording|tostring)] | join(", "))"'
```
**Must see:** node `libvirt-2-format` (the datadisk overlay) and node `libvirt-4-format` (rootdisk)
**both** list the checkpoint bitmap `vm-backup-20261016-exp06-r02-2026-10-16_04-27-24` with
`recording=true`, while `libvirt-2-storage` carries an empty list. Read each node's `dirty-bitmaps`
array — this QEMU 10.1.0 has **no** `query-block-dirty-bitmap` command — and match nodes by their
`-format`/`-storage` suffix, not by the `libvirt-N` prefix. If either disk's bitmap is absent here,
**fail closed**: rebuild the control full from step 1 and start again.

**Step 4 — Injection — remove the datadisk's checkpoint bitmap *(window: after `Done=True`, before the next
backup object)*.** *Run only inside the injection window: after the control full's terminal
`Done=True` transition (r02: 04:28:20Z) and before the next backup object is created (r02: 04:29:26Z,
step 7), with the VM `Running` and CBT `Enabled`.*
```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- \
  virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 \
  '{"execute":"block-dirty-bitmap-remove","arguments":{"node":"libvirt-2-format","name":"vm-backup-20261016-exp06-r02-2026-10-16_04-27-24"}}'
```
**Must see:** the QMP reply `{"return":{}}` (recorded 04:28:21.690Z,
`trigger/qmp-remove-result.txt`). This removes the bitmap from the datadisk's `-format` node only; it
writes no guest or backup data.

**Step 5 — POST-check (fail closed): the datadisk's bitmap is gone and the rootdisk's is intact.** *Run
immediately after step 4, still inside the window, before step 7 creates the next backup object.*
```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- \
  virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}' \
  | jq -r '.return[] | "\(.nodeName): \([.dirty-bitmaps[]? | .name] | join(", "))"'
```
**Must see:** `libvirt-2-format` with an empty `dirty-bitmaps` list and `libvirt-4-format` still
listing `vm-backup-20261016-exp06-r02-2026-10-16_04-27-24`
(`trigger/bitmaps-before.json`, `trigger/bitmaps-after.json`). If *both* lists are empty, the
precondition is wrong — **stop and redo**, because this defect requires exactly one disk to have lost
its bitmap.

**Step 6 — Fire the checkpoint redefinition by restarting the VMI.** *Run after the POST-check passes.*
```bash
oc delete vmi vm-20261016-exp06-r02 -n vm-cbt-demo
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.metadata.uid}{"  "}{.status.phase}{"\n"}'
oc get pod -n vm-cbt-demo -l vm.kubevirt.io/name=vm-20261016-exp06-r02 -o jsonpath='{.items[0].metadata.name}{"\n"}'
```
**Must see:** the VMI uid changes from `968b6e7e-c021-46e4-a731-ca0dbec6121f` to
`9651acfc-1e0d-4c4e-ad94-581e2c4cdf11` (deleted 04:28:22Z; replacement `Running` with CBT `Enabled` at
04:28:45Z) and the launcher pod becomes `virt-launcher-vm-20261016-exp06-r02-rwzzr`. **The
redefinition runs on this restart, not on the injection** — use the replacement pod for the reads in
step 8, and do not mistake the trigger's benign first-attempt requeue at 04:28:45.568760Z for a
failure.

**Step 7 — Create the incremental pass that wedges.** *Run once the replacement VMI is `Running` with CBT
`Enabled` (r02: 04:29:26Z); this is what closes the injection window.*
```bash
oc apply -f - <<'YAML'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackupTracker
metadata:
  name: vm-tracker-20261016-exp06-r02
  namespace: vm-cbt-demo
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: 20261016-exp06-r02
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: vm-20261016-exp06-r02
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vm-incremental-pvc-20261016-exp06-r02-p01
  namespace: vm-cbt-demo
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: 20261016-exp06-r02
spec:
  storageClassName: cbt-demo-hpp
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 30Gi
---
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-incremental-20261016-exp06-r02-p01
  namespace: vm-cbt-demo
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: 20261016-exp06-r02
spec:
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261016-exp06-r02
  pvcName: vm-incremental-pvc-20261016-exp06-r02-p01
YAML
```
**Must see:** `vm-incremental-20261016-exp06-r02-p01` created (uid
`46b6f5e1-ced6-4094-8c96-e4d7690c3ea0`), and — read immediately and again after the wait bound —
QEMU refusing the pass at the datadisk, verbatim: `virError(Code=109, Domain=10, Message='checkpoint
inconsistent: missing or broken bitmap 'vm-backup-20261016-exp06-r02-2026-10-16_04-27-24' for disk
'vdb'')`. Read the CR's own state with:
```bash
oc get vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo -o json \
  | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes,finalizers:.metadata.finalizers}'
oc get events -n vm-cbt-demo --field-selector involvedObject.name=vm-incremental-20261016-exp06-r02-p01 -o json   # expect an EMPTY list
```
**Must see:** no `Done=True` condition (`status.type` still `Incremental`, finalizer
`backup.kubevirt.io/vmbackup-protection` still present) and — as the recorded CR-level silence —
the event list for this CR is empty. **Wait bound: do not declare the pass wedged before the
harness's 20-minute pass bound has elapsed** (the harness gave up at 04:49:27Z after 20m35s; a
healthy incremental here completes in seconds).

**Step 8 — Read-only demonstration of THIS ticket's defect — read all three layers plus the controller's own
verdict.** *Run right after the replacement VMI reports CBT `Enabled`, and again 20+ minutes later:
the divergence appears as soon as the redefinition succeeds (recorded 04:28:45.625161Z) and is
stable, not a transient read.*
```bash
# 1. checkpoint (truth): which <disk> elements does it really declare?
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-rwzzr -c compute -- \
  virsh checkpoint-dumpxml vm-cbt-demo_vm-20261016-exp06-r02 vm-backup-20261016-exp06-r02-2026-10-16_04-27-24
# 2. tracker (claim): which volumes does it advertise?
oc get vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.status.latestCheckpoint.volumes}{"\n"}'
# 3. QEMU (arbiter): which nodes still carry the checkpoint bitmap?
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-rwzzr -c compute -- \
  virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}' \
  | jq -r '.return[] | "\(.nodeName): \([.dirty-bitmaps[]? | .name] | join(", "))"'
# 4. what the controller said about the redefinition itself
oc logs -n vm-cbt-demo deploy/virt-controller --since=30m | grep -i -e redefin -e checkpoint -e bitmap
```
**Must see — this is the defect:**
- the checkpoint XML's `<disks>` block declares only
`<disk name='vda' checkpoint='bitmap' bitmap='vm-backup-20261016-exp06-r02-2026-10-16_04-27-24'/>`
— no `vdb` element;
- `status.latestCheckpoint.volumes` still advertises the **full** set, `[vda/rootdisk, vdb/datadisk]`
(recorded rv `27322960`, 04:28:48.689Z);
- node `libvirt-2-format` (datadisk) has an empty `dirty-bitmaps` list while node `libvirt-4-format`
(rootdisk) still lists the checkpoint bitmap — i.e. QEMU agrees with the checkpoint, not with the
tracker;
- the controller log contains `Checkpoint redefinition successful` and **no** exclusion, skip or
warning line for the datadisk in the same window.
Always read all three layers: the checkpoint XML is the truth, the tracker is the claim, QEMU is the
arbiter — a single-layer read looks self-consistent and hides the defect.

**Step 9 — Recover (also the workaround; only partially effective).** *Run after the state above is confirmed.
The two legs are ordered on purpose: the first is the tempting fix and does not work.*
*Leg 1 — repair the tracker (does not unblock).* First, patch the tracker's status to match the
checkpoint:
```bash
oc patch vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo --subresource=status --type=merge \
  -p '{"status":{"latestCheckpoint":{"volumes":[{"diskTarget":"vda","volumeName":"rootdisk"}]}}}'
```
Then request another incremental pass (same trio as step 7, pass-2 names; the tracker is
unchanged):
```bash
oc apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vm-incremental-pvc-20261016-exp06-r02-p02
  namespace: vm-cbt-demo
spec:
  storageClassName: cbt-demo-hpp
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 30Gi
---
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-incremental-20261016-exp06-r02-p02
  namespace: vm-cbt-demo
spec:
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261016-exp06-r02
  pvcName: vm-incremental-pvc-20261016-exp06-r02-p02
YAML
```
**Must see:** the patch is accepted and stable (recorded rv `27464802`; stable at +0 s and +30 s —
`followup/20261016-exp06-r02-leg1-tracker-repair/{l3-patch.out,leg1.log,tracker-after.json}`), yet
the next pass **still** quotes the uncovered disk and is refused on the same missing bitmap
(`…-leg1-tracker-repair/l5-new-backup.json`): repairing the tracker's volume list does **not**
restore capability.
*Leg 2 — discard the chain (works).* Delete the wedged CR, delete the tracker, then re-create the
tracker and take a fresh full backup, which rebuilds a both-disk checkpoint:
```bash
oc delete vmbackup vm-incremental-20261016-exp06-r02-p03 -n vm-cbt-demo     # releases the finalizer and detaches the hotplug mount
oc delete vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo
oc apply -f - <<'YAML'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackupTracker
metadata:
  name: vm-tracker-20261016-exp06-r02
  namespace: vm-cbt-demo
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: vm-20261016-exp06-r02
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vm-followup-full-pvc-20261016-exp06-r02-f02
  namespace: vm-cbt-demo
spec:
  storageClassName: cbt-demo-hpp
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 80Gi
---
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-followup-full-20261016-exp06-r02-f02
  namespace: vm-cbt-demo
spec:
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261016-exp06-r02
  pvcName: vm-followup-full-pvc-20261016-exp06-r02-f02
YAML
```
**Must see:** the CR deletion reports the finalizer released and the destination mount detached;
the new full reaches `status.type=Full` with `Done=True` in ~18 s (recorded 07:00:53Z) and
`status.includedVolumes` = both disks; and a new both-disk checkpoint
`vm-followup-full-20261016-exp06-r02-f02-2026-10-16_07-00-35` appears
(`followup/20261016-exp06-r02-leg2-chain-discard/l5-full-backup.json`, `RESULT.md`).
**Does not restore**: the old incremental chain — a fresh full replaces it, at the cost of a full copy
(~80 GiB here). Never delete the VM's own DataVolumes or PVCs; the wedged passes' destination PVCs
stay `Bound`.

**Step 10 — Optional accelerators (never required).** *Run these instead of typing the steps by hand, if you
prefer; they assume the same object names on a dedicated cluster.* The recorded run used
`cbt-chaos/scenarios_v2/CBT-EXP-06/chaos-trigger.sh` (steps 1–8), then
`…/same-vm-followup.sh`, `…/leg1-tracker-repair.sh` (step 9, leg 1) and `…/leg2-chain-discard.sh`
(step 9, leg 2), plus `…/chaos-trigger-r01b.sh` for the r01 re-run. **Must see:** each script's own
result file under `cbt-chaos/scenarios_v2/CBT-EXP-06/followup/` names the objects it acted on.

## Current behaviour (observed)

Observed on `20261016-exp06-r02` (all times UTC, from the named artifacts):

- **Redefinition reported success with no warning.**
  `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02/trigger/controller-redefinition-window.log:87`
  — "Checkpoint redefinition successful" at **04:28:45.625161Z**, after a benign first-attempt requeue
  at 04:28:45.568760Z (`:79,:80,:82`). No exclusion/warning line appears anywhere in the captured
  window. *Independent artifact observation.*
- **The redefined checkpoint covers only `vda`.**
  `…/runs/20261016-exp06-r02/observer/effect/checkpoint-dumpxml-post.xml` (read 04:52:08Z), verbatim:
  ```
  <domaincheckpoint>
    <name>vm-backup-20261016-exp06-r02-2026-10-16_04-27-24</name>
    <disks>
      <disk name='vda' checkpoint='bitmap' bitmap='vm-backup-20261016-exp06-r02-2026-10-16_04-27-24'/>
    </disks>
  </domaincheckpoint>
  ```
- **The tracker still advertises both disks.**
  `…/runs/20261016-exp06-r02/trigger/tracker-after-restart.yaml#status.latestCheckpoint.volumes` =
  `[vda/rootdisk, vdb/datadisk]` (rv `27322960`, mtime 04:28:48.689Z); identical in
  `…/runs/20261016-exp06-r02/observer/effect/post-tracker.json` (read 04:50:46Z) and unchanged in the
  follow-up's `followup/20261016-exp06-r02-same-vm/tracker-{before,after}.json`. The trigger's own
  effect check recorded `tracker_volumes_after_redefinition: "rootdisk datadisk"`
  (`…/runs/20261016-exp06-r02/trigger/effect-check.json`).
- **QEMU agrees with the checkpoint, not the tracker.** The datadisk node `libvirt-2-format` has an
  empty bitmap list at 04:28:54Z, 04:50:46Z and 04:54:4xZ while the rootdisk node `libvirt-4-format`
  still holds the checkpoint bitmap in the same raw read
  (`…/runs/20261016-exp06-r02/observer/effect/pre-bitmap-history.jsonl`, `…/qmp-nodes-post.json`,
  `…/qmp-nodes-post-late.json`, `…/observer/FINAL.json#runtime_checks_at_final_utc`).
- **The split is stable, not a transient read.** It survived the whole session, the same-VM follow-up,
  and a manual tracker repair: leg 1 patched the tracker's status to `[vda/rootdisk]`
  (`followup/20261016-exp06-r02-leg1-tracker-repair/l3-patch.out`; accepted and stable at +0 s and +30 s;
  `leg1.log` L3; `tracker-after.json` rv `27464802`) while the checkpoint XML stayed `vda`-only
  (`followup/20261016-exp06-r02-leg1-tracker-repair/checkpoint-dumpxml-{before-patch,after}.xml`).
- **All three layer reads are independent artifacts.** The claim that "the probe deliberately excluded
  the disk but never reported it" is **inference**, from the code anchor in
  `docs/findings/finding-1-backup-cr-livelock.md` §8 (`findDisksWithCheckpointBitmap` probes per disk;
  missing bitmaps are logged at `V(3)` only; `isCheckpointInvalidError` fires only when **zero** disks
  match) plus the observed silent success.

## Expected behaviour (contract)

- The redefinition must not silently accept a checkpoint it cannot fully honour. For every disk whose
  QEMU checkpoint bitmap is missing it must either (a) invalidate the checkpoint and force a clean,
  complete fallback to a full backup (the proven-safe path — see P1's recovery matrix), or (b) exclude
  the disk **and warn**, with the exclusion visible in the redefinition result.
- The tracker must never advertise a volume whose QEMU bitmap is absent: the redefinition must update
  or invalidate `status.latestCheckpoint.volumes` to match the checkpoint it actually produced.
- Regression: a healthy restart redefines the checkpoint with the full disk set and leaves the
  tracker's volume list unchanged.

**Acceptance check (what a reviewer runs).** After the repro, `virsh checkpoint-dumpxml` and the
tracker's `status.latestCheckpoint.volumes` list the same disk set, and any exclusion is reported
(event/condition/log at default verbosity).

## Impact, workaround and data safety

- **Metadata integrity / trust**: operators and any tooling that read the tracker to learn "what is
  this VM's incremental chain protecting" get a wrong answer — a volume covered by neither the
  checkpoint nor a QEMU bitmap is advertised as protected. This is a *silent* wrong answer, unlike the
  loud per-disk refusal that follows it.
- **Operational consequence**: the split state is the standing precondition of the P1 wedge (a later
  incremental quotes `vdb`, QEMU refuses with `Code=109`, and the pass never terminates). It is not the
  sole cause — leg 1 refuted the "tracker drives the request" explanation — but it *is* the state an
  operator sees while the VM is unable to back up.
- **Data safety**: no source data and no completed backup image are affected; what is wrong is the
  metadata that says which disks are protected. Stated explicitly: this is a metadata-integrity defect,
  not observed data loss.
- **Workaround (live-verified, only partially effective)**: repairing the tracker's volume list to
  match the checkpoint does **not** restore capability (leg 1: the next pass still wedges on the same
  bitmap); discarding the tracker and taking a fresh full does (leg 2: `type=Full`, `Done=True` in 18 s,
  both disks — `followup/20261016-exp06-r02-leg2-chain-discard/l5-full-backup.json`). Do not trust the
  tracker's volume list for chain coverage; verify against `virsh checkpoint-dumpxml` and the QEMU
  bitmaps. Cost: a full re-copy and the loss of the incremental chain.
- **Frequency**: deterministic in this scenario family (r01 leg B and all three r02 passes showed the
  same split).
- **Unknowns / what this ticket does not claim**: whether the exclusion is intended to be silent at
  some higher verbosity, or is simply not reported; whether `isCheckpointInvalidError`'s "zero disks
  match" rule is the intended boundary; and it does not claim any *completed* pass omits a disk.

## Evidence

**Artifact index** (repository-relative; run root
`cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02/`, follow-ups under
`cbt-chaos/scenarios_v2/CBT-EXP-06/followup/`). "raw" = captured stream/command output;
"summary" = derived.

- `trigger/controller-redefinition-window.log` (raw; `:79,:80,:82,:87` — the requeue and "Checkpoint
  redefinition successful" at 04:28:45.625161Z), `trigger/effect-check.json` (raw;
  `tracker_volumes_after_redefinition`).
- `observer/effect/checkpoint-dumpxml-post.xml` (raw; only `vda`) versus
  `trigger/tracker-after-restart.yaml#status.latestCheckpoint.volumes` (raw; `rootdisk`+`datadisk`,
  rv `27322960`) versus `observer/effect/{qmp-nodes-post.json,qmp-nodes-post-late.json,pre-bitmap-history.jsonl}`
  (raw; the per-disk bitmap contrast).
- `observer/effect/post-tracker.json` (raw; read 04:50:46Z) — the tracker's claim later in the session.
- `followup/20261016-exp06-r02-leg1-tracker-repair/{l3-patch.out,leg1.log,tracker-before-patch.json,tracker-after.json,checkpoint-dumpxml-before-patch.xml,checkpoint-dumpxml-after.xml,RESULT.md}`
  (raw + summary) — the split survives manual repair; repair does not unblock.
- `followup/20261016-exp06-r02-leg2-chain-discard/RESULT.md` and `…/checkpoint-dumpxml-before.xml`
  (summary + raw) — the checkpoint's real coverage (`vda`) before the chain was discarded, and the fresh
  full that restored both disks (`…/l5-full-backup.json`).
- `trigger/bitmaps-before.json`, `trigger/qmp-remove-result.txt`, `trigger/bitmaps-after.json` (raw) —
  the per-disk surgery whose result the redefinition then handled silently.
- `checkers/injection-validity.json` (summary) and `observer/effect/pre-bitmap-history.jsonl` (raw) —
  the pre-removal witness caveat.
- `checkers/evidence-sufficiency.json#false_positive_risks/3` (summary) — the checker's warning that the
  VMI `backupStatus` is a request projection rather than chain proof (relevant to P6, not here).
- `observer/effect/facts-digest.json` (summary) — stream/state first-seen digest used for the timeline;
  note it carries **no** image digests (see Environment: those are `not recorded`).
- Prior run: `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261014-exp06-r01/` (`tracker-after-restart.yaml`,
  `bitmaps-*.json`, `legB-*`) — the same split in r01 leg B.

- Also present in the pack (recorded; not load-bearing for any claim above): `trigger/action-request.json`, `trigger/exit-statuses.json`, `observer/ARMED`, `observer/PRESERVED`, `observer/finding.md`, `observer/effect/post-vmbackups.json`, `recovery/step2-verify.log`, `reports/test-run-result.md`, `reports/test-run-report.md`, `checkers/report-fidelity.json`.

**UTC timeline** (setup → precondition → injection → effect → failure → recovery; source per entry):

1. 04:27:24Z → 04:28:20Z — control full backup created and reaches `Done=True`, both disks included
   (`observer/effect/facts-digest.json#vmbackup_state_first_recv_utc`, `trigger/legA-full-backup.yaml`).
   **Injection window opens.**
2. 04:28:21.582Z → 04:28:21.690Z — datadisk bitmap present, then removed with reply `{"return":{}}`
   (`trigger/bitmaps-before.json`, `trigger/qmp-remove-result.txt`); empty after
   (`trigger/bitmaps-after.json`).
3. 04:28:32Z — replacement VMI (uid `9651acfc-…`) first observed; the restart fires redefinition
   (`observer/effect/facts-digest.json`).
4. 04:28:45.568760Z → **04:28:45.625161Z** — benign requeue, then "Checkpoint redefinition successful"
   with **no** warning (`trigger/controller-redefinition-window.log:79-87`).
5. 04:28:48.689Z — tracker rv `27322960` advertises `[vda/rootdisk, vdb/datadisk]`
   (`trigger/tracker-after-restart.yaml`; `trigger/effect-check.json#tracker_volumes_after_redefinition`).
   **04:29:26Z — the next backup object is created (`trigger/legB-incremental-backup.yaml`);
   the injection window closes.**
6. 04:28:54Z / 04:50:46Z / 04:54:4xZ — datadisk node `libvirt-2-format` has no bitmap while rootdisk
   node `libvirt-4-format` still lists it (`observer/effect/qmp-nodes-post.json`,
   `…/qmp-nodes-post-late.json`, `…/pre-bitmap-history.jsonl`).
7. 04:52:08Z — the checkpoint XML (read then) declares only `vda`
   (`observer/effect/checkpoint-dumpxml-post.xml`).
8. 04:29:29Z onwards — the consequences of the split: the next incremental is refused with
   `Code=109` and wedges (P1; `observer/watches/events.jsonl`).
9. 05:34Z — the follow-up's `tracker-{before,after}.json` still show both volumes advertised.
10. 06:35Z–06:56Z — leg 1: tracker status patched to `[vda/rootdisk]` (accepted, rv `27464802`) while
    the checkpoint stayed `vda`-only; the next pass still wedged (`…-leg1-tracker-repair/RESULT.md`).
11. 07:00Z–07:01Z — leg 2: the tracker is deleted and a fresh full completes in 18 s with a new
    both-disk checkpoint (`…-leg2-chain-discard/l5-full-backup.json`, `RESULT.md`) — recovery.

**Retained state.** The run is closed and its pack frozen; nothing under the run root was modified
post-close. The pre-wedge tracker object no longer exists (deleted in leg 2, with its final state
captured in `…-leg2-chain-discard/tracker-before-delete.json`). The wedged CRs were deleted during the
follow-ups as the documented unblock; their destination PVCs were retained
(`followup/20261016-exp06-r02-same-vm/wedged-pvc-after.json#status.phase: Bound`). The VMI that
produced the split was replaced by the restart, and its status capture is retained in
`observer/effect/post-vmi-cbt.json`.

## Negative results and what would falsify this ticket

- **Explicit negative result (must not be filed as a defect): "silent *completed* per-disk drop" did
  not reproduce in 4 attempts / 2 designs** (r01 leg B; r02 `…-p01`; `…-p02`; `…-p03`) — every
  affected pass was loudly refused by QEMU (`virError(Code=109)`), never silently omitted from a
  completed incremental's `includedVolumes`, and the loss of protection was never permanent (leg 2
  restored both disks with a fresh full). What is silent is the **metadata** layer, which is what this
  ticket claims.
- **Refuted: "the tracker's stale volume list drives the failing request".** Leg 1 proved that with the
  tracker advertising only `rootdisk`, the next pass still quoted `vdb` and failed on the same missing
  bitmap (`…-leg1-tracker-repair/RESULT.md`, `l5-new-backup.json`). The request comes from the
  checkpoint/QEMU reality, so the tracker entry is a *correlated*, not *causal*, artefact.
- **Explicitly NOT the cause**: the guest-freeze warning `virError(Code=113)` on `/mnt/datadisk`, which
  also appears on successful fulls (r02 leg A and leg 2) — neither necessary nor sufficient for this
  state.
- **Residual open question (not answered, and why)**: whether a *completed* pass omitting `vdb` is
  reachable via the tracker-reset path. The leg that could answer it needs a fresh full-backup PVC
  while the pool held only 40.25 GiB free
  (`followup/20261016-exp06-r02-same-vm/f3-result.json#pool_free_before_bytes` = 43215937536); it was
  refused for capacity rather than run.
- **Contradictory/limiting evidence**: the checker's false-positive risk note that the VMI's
  `backupStatus` is a *request projection* rather than chain proof
  (`checkers/evidence-sufficiency.json#false_positive_risks/3`) applies to the VMI surface (P6) — not to
  the checkpoint-vs-tracker-vs-QEMU contrast used here, which is read from three independent backends.
- **Falsifier.** This ticket is wrong if the checkpoint XML in fact declares the same disk set as the
  tracker (i.e. the split is a stale read or a rendering artefact), or if `latestCheckpoint.volumes` is
  explicitly documented as a *requested* rather than a *realised* volume set and consumers are told to
  ignore it for coverage questions — in that case the defect reduces to the missing warning.

## Additional feedback (reporter's notes)

- **Open hypotheses and the smallest experiments that would settle them.**
  - *Is the exclusion reported at higher verbosity?* Smallest experiment: repeat the repro with
    virt-launcher/virt-controller log level raised and grep the same window for any per-disk skip line.
  - *Does the probe invalidate the checkpoint when zero disks match?* Smallest experiment: remove both
    disks' bitmaps and restart; observe whether a full fallback occurs — this tests the inferred
    `isCheckpointInvalidError` boundary without touching the wedge.
- **Triage questions that decide scope.**
  - Is a per-disk bitmap absence during redefinition supposed to invalidate the whole checkpoint, or to
    be excluded with a warning? (Decides the shape of the fix and whether the current silent success is
    a defect or an under-specified boundary.)
  - Should the tracker's `latestCheckpoint.volumes` be written from the checkpoint's actual coverage, or
    is it intentionally independent?
- **Environment-specific notes for the next reproducer.**
  - Read all three layers, always: the checkpoint XML is the truth, the tracker is the claim, QEMU is
    the arbiter. A single-layer read looks self-consistent and hides the defect.
  - The bitmap lives on the disk's `-format` node (`libvirt-2-format` for the datadisk here) — matching
    by node name suffix, not by the `libvirt-N` prefix, is what makes the per-disk contrast valid.
  - The redefinition is on the VMI-restart path, so the timing anchor is the restart, not the injection;
    do not confuse the trigger's benign first-attempt requeue (04:28:45.568760Z) with a failure.
  - Capacity: measure on `/var/hpvolumes/csi` (`/dev/sdb`), never on its parent `/var/hpvolumes`
    (`/dev/sda4`); a full backup destination is fully allocated (~80 GiB).
- **Cross-references.** Siblings in this folder: `backup-cr-livelock-on-missing-per-disk-bitmap.md`
  (**P1**, the wedge that follows from this state and the ticket that owns the recovery matrix),
  `vm-wide-backup-capability-deadlock.md` (**P2**, the availability consequence once the wedge occurs),
  `backup-destination-volume-stuck-hotplug-mounted-during-wedge.md` (**P3**, the leaked destination
  mount during the wedge), `backup-cr-event-stream-empty-on-wedge.md` (**P4**, the missing CR-level
  failure signal), `vmi-backupstatus-advertises-nonexistent-checkpoint.md` (**P6**, the third metadata
  surface that disagrees in the same state), and `20261016-exp06-r02-product-findings.md` (the
  consolidated working analysis; its Draft A groups this with the wedge, and the Lead's mapping splits
  it out as P5; not filed itself). Findings registry:
  `docs/findings/finding-1-backup-cr-livelock.md` (prior-run characterization and the source anchors for
  `RedefineCheckpoint` / `findDisksWithCheckpointBitmap`). **Separately and clearly labelled:
  harness/tooling gaps are not in this ticket** — see
  `cbt-chaos/scenarios_v2/CBT-EXP-06/harness-tickets-20261016-exp06-r02.md` (notably H-03, the
  pre-state witness gap, and H-09, preflight capacity measured on the wrong filesystem).

## Sanitisation checklist

- [ ] No credentials, tokens, kubeconfig contents or private keys
- [ ] No private hostnames or absolute host paths
- [ ] No broad selectors (names or run-scoped labels only)
- [ ] No destructive commands other than the documented, scoped workaround
- [ ] Commands are the ones actually validated (illustrative ones are labelled)

Notes making the checklist true: the worker node name is genericised as `<node>` and no reporter host
path appears; the only absolute paths retained are cluster-internal storage-pool paths
(`/var/hpvolumes`, `/var/hpvolumes/csi`) and guest paths (`/mnt/datadisk`), which are product data
needed to reproduce the setup; all object names are run-scoped or `<placeholders>`; the destructive
commands in Steps (`oc delete vmi`, the QMP `block-dirty-bitmap-remove`, `oc delete vmbackup`, deleting
the tracker) are this ticket's own scoped repro/workaround steps on a dedicated cluster, and no
cluster-cleanup command is included; the commands are re-creations of the recorded shapes and are
labelled as such.

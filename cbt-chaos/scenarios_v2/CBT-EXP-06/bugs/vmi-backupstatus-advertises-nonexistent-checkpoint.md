# [Improvement]: The VMI's `status.changedBlockTracking.backupStatus` advertises a checkpoint name (and a volume set) that libvirt does not have

## What this is, in one paragraph

**CBT** (changed block tracking) is how KubeVirt incremental backups know what changed since the last
backup: each disk carries a **dirty bitmap** — a per-disk change-tracking map inside the running VM's
QEMU — and those bitmaps are grouped under a **checkpoint**, a named libvirt-side record of which disks
a backup covers. The **VMI** (VirtualMachineInstance, the API object that reports on a running VM)
publishes a CBT block at `status.changedBlockTracking.backupStatus` so a monitor or operator can see
which checkpoint the backup in flight covers. In this defect that published block names checkpoint
`vm-incremental-20261016-exp06-r02-p01-2026-10-16_04-29-26` and a volume set of both disks, even
though no such checkpoint exists in libvirt — the redefinition dropped the datadisk's checkpoint
bitmap, and the only checkpoint that does exist covers `vda` alone. Anyone reading the product's own
status field therefore gets a wrong answer about data-protection coverage.

**When → then → expected**

- **When** the VirtualMachineInstance `vm-20261016-exp06-r02` (uid `9651acfc-1e0d-4c4e-ad94-581e2c4cdf11`, the VMI created by the restart) publishes its CBT status in the wedge state: `status.changedBlockTracking.state=Enabled` with `backupStatus.backupName=vm-incremental-20261016-exp06-r02-p01`, `backupStatus.checkpointName=vm-incremental-20261016-exp06-r02-p01-2026-10-16_04-29-26`, `backupStatus.startTimestamp=2026-10-16T04:29:26Z` and `backupStatus.volumes=[{vda,rootdisk},{vdb,datadisk}]` (read 04:54:41Z).
- **And** the disruption **CBT-EXP-06 — per-disk checkpoint-bitmap removal** (`chaos-trigger.sh`; **not a krknctl scenario** — krkn's 38 tags include no primitive that can touch a guest QEMU dirty bitmap) is applied: the datadisk's checkpoint bitmap `vm-backup-20261016-exp06-r02-2026-10-16_04-27-24` is removed over QMP from node `libvirt-2-format` with `block-dirty-bitmap-remove` at 04:28:21.690Z, and the VMI is then deleted so the replacement VMI (Running + CBT `Enabled`, 04:28:45Z) rewrites the checkpoint chain.
- **Then (current behaviour):** the published `checkpointName` does not resolve in libvirt — `virsh checkpoint-dumpxml` answers `Domain checkpoint not found: no domain checkpoint with matching name 'vm-incremental-20261016-exp06-r02-p01-2026-10-16_04-29-26'` (read 04:54Z) — and the checkpoint that does exist declares only `<disk name='vda' checkpoint='bitmap' …/>`, so the published `volumes` set is too wide as well. The value is stable, not a transient read: identical `checkpointName` and `volumes` at 05:34Z, ~65 minutes later and long after the harness had declared the pass failed (04:49:27Z).
- **Expected behaviour:** either `checkpointName` is published only once the checkpoint actually exists in libvirt (with `volumes` reflecting that checkpoint's real disk set), or the field is explicitly documented as a *requested* name with a co-located state saying the checkpoint does not yet exist / the pass never started; a failed pass must not leave a status surface that reads like an active, both-disks checkpoint. Reviewer check: in the repro state either the published name resolves with `virsh checkpoint-dumpxml`, or the status carries an explicit absent marker.

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
| Issue type | **Improvement** (contract clarification + guardrail), **Bug-leaning**: *if* the established contract is that `backupStatus.checkpointName` must name an existing libvirt checkpoint, this is a Bug. That classification is itself a triage question, so it is filed as an Improvement with the Bug-lean stated explicitly rather than guessed. |
| Priority (proposed) | **Medium** — a misleading status surface; no data loss on its own. Unassigned pending triage. |
| Severity class | status truthfulness |
| Owning component (suspected) | **suspected** CNV/KubeVirt backup stack: the VMI CBT status publisher (`VirtualMachineInstance.status.changedBlockTracking`, written by the virt-handler / virt-launcher status path); API surface `kubevirt.io/v1`. |
| Component(s) proven involved | the VMI status writer (it published the name and the volume set) together with libvirt inside the launcher (the published checkpoint name does not exist there) and the checkpoint probe (the only checkpoint that does exist covers `vda` only). |
| Reproducibility | `single observation` — 1 wedge pass, with the published value stable across two VMI snapshots ~65 minutes apart. The decisive check is a **libvirt-level lookup** (`virsh checkpoint-dumpxml`), not an API-only read. Outside the wedge state it was **not attempted**, so no rate is claimed. |
| Status / confidence | **Observed behaviour, medium confidence about its product-level significance.** The artifact facts are unambiguous (the published name does not exist in libvirt; the published volume set contradicts the checkpoint). Whether the field is *intended* as a request projection — a name written before the backend object exists — is a contract question this run cannot settle; the run's own evidence checker flagged exactly this as a false-positive trap (`checkers/evidence-sufficiency.json#false_positive_risks/3`). |
| Blast radius | this VM only (the status is per-VMI) — plus any tooling that keys "the chain covers these disks" off the published name. |
| Data at risk? | **No** — a status-consistency defect: no source data and no backup image is affected. The risk is a wrong answer about coverage, not a wrong backup. |
| Related scenario / execution | `CBT-EXP-06` / `20261016-exp06-r02` (2026-10-16, closed `BLOCKED`, pass `…-p01`); post-close same-VM follow-up `20261016-exp06-r02-same-vm` (VMI snapshot 05:34Z). |
| Affected versions | short pointer — OpenShift 4.22.15, CNV `kubevirt-hyperconverged-operator.v4.22.12`, APIs `kubevirt.io/v1` and `backup.kubevirt.io/v1alpha1`, libvirt 11.10.0 / QEMU 10.1.0 in the launcher. The full measured matrix is in **Environment** below. |

## Context (for an engineer new to this area)

- **What the feature does** — KubeVirt CBT push-mode backups track changes per disk in QEMU dirty
  bitmaps, grouped by a libvirt **checkpoint** per backup, with the chain's latest checkpoint recorded
  in a `VirtualMachineBackupTracker` CR. The VMI also publishes a CBT status block,
  `status.changedBlockTracking`, whose `backupStatus` describes the backup currently requested/underway
  on that VMI (`backupName`, `checkpointName`, `startTimestamp`, `volumes`, `backupMsg`).
- **Where the failure sits** — the VMI status field `status.changedBlockTracking.backupStatus
  .checkpointName` (and its `volumes`): the name it publishes does not resolve in libvirt, and the
  volume set it publishes is wider than the checkpoint that does exist.
- **Observed surface vs. origin** — the surface is the VMI status; the truth lives in libvirt inside the
  launcher and in the QEMU bitmaps. Three surfaces disagree in the same state: the VMI status names a
  checkpoint that does not exist and over-claims volumes; the tracker names an existing checkpoint and
  also over-claims volumes (P5); libvirt/QEMU cover only one disk.
- **Why it matters** — an operator or monitor reading the VMI status concludes the VM tracks a
  both-disks checkpoint, when libvirt holds a `vda`-only checkpoint under a different name. It is a
  wrong answer about data-protection coverage derived from a product-published field — the third (with
  P4 and P1's stale reason) surface that reads healthy/plausible while the backup is provably not
  progressing.

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
| Virtualization | VMI status API in scope | `kubevirt.io/v1` — `VirtualMachineInstance.status.changedBlockTracking.backupStatus` (written by the virt-handler / virt-launcher status path) | `oc get vmi <vmi> -o jsonpath='{.apiVersion}'` | **ticket-specific (P6)** |

**Load-bearing versions.** The QEMU/libvirt version matters: this repro drives `query-named-block-nodes`
and `block-dirty-bitmap-remove` over QMP, and the decisive error text (`checkpoint inconsistent:
missing or broken bitmap …`) is QEMU's own. The pool-filesystem trap matters too — capacity was
measured on `/var/hpvolumes/csi` (`/dev/sdb`), not on its parent filesystem, and a measurement on the
parent gives the wrong answer.

**Storage present but not exercised.** ODF/OCS and local-storage are captured only to bound the
search space; nothing in this ticket depends on them. The only storage path in play is the hostpath
CSI pool `cbt-demo-hpp` on the single worker `<node>`.

## Reproducibility

- **Classification**: single observation (1/1), and the observation is a libvirt-level lookup rather
  than an API read: the published name was queried directly against libvirt and did not exist.
- **Attempts**: one wedged pass in one run (r02 `…-p01`, 2026-10-16), read twice with the same value
  (04:54:41Z and ~05:34Z); the pass itself is one of the 4 P1 reproductions, so the *state* is
  deterministic even though this status observation was taken once.
- **Stability** — exact: the same `checkpointName` and `volumes` in both snapshots ~65 minutes apart,
  and still present long after the harness had declared the pass failed at 04:49:27Z. Outside the wedge
  state: **not attempted**, so no claim is made there.
- **Preconditions**: a pass whose checkpoint write never succeeded (the P1 wedge) — i.e. the backend
  object the status names was never created.
- **Second entry path**: not attempted; **[INFERENCE]** that any pass reaching this non-terminal state
  publishes the same shape, since the published value is written at request time.
- **Attribution caveat (must not be dropped)**: the *heterogeneous state* observation (VMI status vs
  tracker vs QEMU disagreeing) is attributed to the product's own published surfaces; in
  `20261016-exp06-r02` the pre-removal bitmap state was witnessed only by the disruptor
  (`checkers/injection-validity.json` REJECT; `observer/effect/pre-bitmap-history.jsonl`, 0 rows with
  `target_present=true`), and the wedge that produces this status is reproduced on a path with no
  injection (leg 1).

## Steps to reproduce (exact commands and injection timing)

Prerequisites: a dedicated cluster, a fresh run-scoped VM and new object names; never reuse another
run's names. The object names below are the **recorded names of run `20261016-exp06-r02`** (namespace
`vm-cbt-demo`), taken verbatim from the run's artifacts, and the commands are re-creations of the
recorded shapes rather than commands re-run against a live cluster. On a fresh cluster, create
equivalents with your own run-scoped names and substitute them for these names everywhere — that
substitution is the only change this section allows. Every other value below is literal and runnable
as written: namespace `vm-cbt-demo`, the `compute` container, the libvirt domain
`vm-cbt-demo_vm-20261016-exp06-r02`, the QMP payloads and the checkpoint names.

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

Read the `Fate` column for the two questions that decide scope: the three wedged backups
`vm-incremental-20261016-exp06-r02-p02` (leg 1 L2, finalizer released in 3 s),
`vm-incremental-20261016-exp06-r02-p03` (leg 2 L2, 2 s) and `vm-incremental-20261016-exp06-r02-p01`
(follow-up F2, 3 s) were **deleted**, while their destination PVCs
`vm-incremental-pvc-20261016-exp06-r02-p01/p02/p03` were all **kept** (`Bound`). The control full's
CR `vm-backup-20261016-exp06-r02` was **kept** but its destination PVC
`vm-backup-pvc-20261016-exp06-r02` was **deleted** 2026-10-16 on operator approval to reclaim pool
space; the post-recovery full's destination PVC `vm-followup-full-pvc-20261016-exp06-r02-f02` was
**kept**. `vm-followup-20261016-exp06-r02-f01` was never created (admission rejected it), so of that
leg only the 3 GiB PVC `vm-followup-pvc-20261016-exp06-r02-f01` existed, and it was removed.

**Step 1 — Setup: a two-disk CBT-enabled VM and one control full backup.**

Run this first, on a dedicated cluster, before anything else. Create the equivalent of the run's VM
(runStrategy Always, 1 vCPU / 2 GiB; `rootdisk`/`vda` from an 80 GiB RHEL 9 clone DataVolume;
`datadisk`/`vdb` from a 2 GiB blank DataVolume, ext4 mounted at `/mnt/datadisk`; SSH Service), then
confirm CBT is on:

```bash
oc create namespace vm-cbt-demo   # already exists in run 20261016-exp06-r02
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo \
  -o jsonpath='{.metadata.uid}{"\n"}{.status.phase}{"\n"}{.status.changedBlockTracking.state}{"\n"}'
```

Then apply the tracker + destination PVC + backup trio for the control full:

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
oc get vmbackup vm-backup-20261016-exp06-r02 -n vm-cbt-demo -o json \
  | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes}'
```

*What you must see:* before the injection the VMI uid is `968b6e7e-c021-46e4-a731-ca0dbec6121f` with
`status.phase=Running` and `status.changedBlockTracking.state=Enabled` (if the state is not `Enabled`,
stop — CBT is off and nothing below reproduces); and the control full reaches `status.type=Full` with a
`Done` condition whose `status=True` (r02: 04:28:20Z) and `status.includedVolumes` covering both
`rootdisk` and `datadisk`. **The injection window opens the moment that `Done=True` is observed.**

**Step 2 — Locate the launcher pod and the libvirt domain.**

Run right after the control full is terminal and before the injection.

```bash
oc get pod -n vm-cbt-demo -l vm.kubevirt.io/name=vm-20261016-exp06-r02 -o jsonpath='{.items[0].metadata.name}'
```

*What you must see:* one `virt-launcher-vm-20261016-exp06-r02-*` pod name — in r02
`virt-launcher-vm-20261016-exp06-r02-ljm2w` before the restart and
`virt-launcher-vm-20261016-exp06-r02-rwzzr` after it. The libvirt domain is
`vm-cbt-demo_vm-20261016-exp06-r02` (namespace, underscore, VM name) and is spelled literally in every
`virsh` command below.

**Step 3 — Fail-closed PRE-check: the datadisk's checkpoint bitmap must exist before you remove it.**

Run immediately before the injection, while the control full is terminal and no next backup object has
been created.

```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- \
  virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}'
```

*What you must see:* node `libvirt-2-format` (the datadisk overlay
`/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2`) with a `dirty-bitmaps` entry named
`vm-backup-20261016-exp06-r02-2026-10-16_04-27-24` and `recording=true`, and node `libvirt-4-format`
(rootdisk) holding the same name; record node `libvirt-2-storage` too — in r02 its `dirty-bitmaps` list
was **empty**. Capture this read from a **non-injector** witness: the r02 injection checker REJECTed
the injection because the only pre-removal witness was the injector itself. Fail closed — if
`libvirt-2-format` does not list the checkpoint bitmap, stop and re-set-up, because nothing below will
demonstrate anything. Note that `query-block-dirty-bitmap` does not exist on this QEMU (libvirt 11.10.0
/ QEMU 10.1.0); list bitmaps with `query-named-block-nodes` and read each node's `dirty-bitmaps`.

**Step 4 — Injection window: remove the datadisk's checkpoint bitmap, and only that one.**

Run **after** the control full's terminal `Done=True` and **before** the next backup object is created
(r02: `Done=True` 04:28:20Z → injection 04:28:21.690Z → next object 04:29:26Z); outside that window the
injection is invalid.

```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- \
  virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"block-dirty-bitmap-remove","arguments":{"node":"libvirt-2-format","name":"vm-backup-20261016-exp06-r02-2026-10-16_04-27-24"}}'
```

*What you must see:* the QMP reply `{"return":{}}` (recorded 04:28:21.690Z in
`trigger/qmp-remove-result.txt`). The payload names exactly one node and one bitmap — the datadisk's;
never pass `libvirt-4-format` or the rootdisk bitmap.

**Step 5 — Fail-closed POST-check: the datadisk bitmap is gone, the rootdisk's remains.**

Run immediately after the injection, in the same launcher pod.

```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- \
  virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}'
```

*What you must see:* `libvirt-2-format`'s `dirty-bitmaps` no longer lists
`vm-backup-20261016-exp06-r02-2026-10-16_04-27-24`, while `libvirt-4-format` still lists it — the
removal was per-disk, not VM-wide. Fail closed: if the name is still present on `libvirt-2-format`, the
injection did not take and the rest of this section will not reproduce.

**Step 6 — Fire the checkpoint redefinition by deleting the VMI.**

Run once the POST-check has passed.

```bash
oc delete vmi vm-20261016-exp06-r02 -n vm-cbt-demo
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo \
  -o jsonpath='{.metadata.uid}{"\n"}{.status.phase}{"\n"}{.status.changedBlockTracking.state}{"\n"}'
```

*What you must see:* the pre-injection VMI uid `968b6e7e-c021-46e4-a731-ca0dbec6121f` goes away and the
replacement VMI carries uid `9651acfc-1e0d-4c4e-ad94-581e2c4cdf11` — **the VMI whose status this ticket
is about** — reaching `status.phase=Running` with `status.changedBlockTracking.state=Enabled` (r02:
delete requested 04:28:22Z, Running + CBT Enabled 04:28:45Z). The controller's recorded redefinition
window logs success at 04:28:45.625161Z (`trigger/controller-redefinition-window.log:87`) and produces a
`vda`-only checkpoint (`observer/effect/checkpoint-dumpxml-post.xml`, read 04:52:08Z). Confirm that
against the recreated launcher, and confirm the datadisk bitmap stayed gone:

```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-rwzzr -c compute -- \
  virsh checkpoint-list --tree vm-cbt-demo_vm-20261016-exp06-r02
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-rwzzr -c compute -- \
  virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}'
```

*What you must see:* a checkpoint whose tree declares `vda` only (no `vdb` disk) — the checkpoint that
exists here cannot cover the datadisk — and `libvirt-2-format` with an empty `dirty-bitmaps` list while
`libvirt-4-format` still holds the rootdisk bitmap.

**Step 7 — Create the pass whose checkpoint write never succeeds (the P1 wedge).**

Run after the replacement VMI is `Running` with CBT `Enabled`, and before declaring anything terminal.
Apply the same trio with incremental names (tracker unchanged, this pass's own PVC and backup):

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
oc get vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo -o json | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes,finalizers:.metadata.finalizers}'
```

*What you must see:* `metadata.finalizers` still contains `backup.kubevirt.io/vmbackup-protection` and
`status.conditions` has **no** terminal `Done`/`status=True` — the CR stays non-terminal (the P1
livelock). The CR is created 04:29:26Z in r02 and its destination PVC
`vm-incremental-pvc-20261016-exp06-r02-p01` reaches `status.phase=Bound` (~0 bytes; the recorded
request was 30 GiB `ReadWriteOnce` on `cbt-demo-hpp` —
`followup/20261016-exp06-r02-same-vm/wedged-pvc-after.json#spec`). 21 `BackupError` events follow on the VMI between 04:29:29Z and
04:57:02Z (`observer/watches/events.jsonl`). Cross-check owned by the P4 ticket: the same selector
scoped to the CR returns an **empty** list, so the wedge leaves no CR-level failure signal:

```bash
oc get events -n vm-cbt-demo --field-selector involvedObject.name=vm-incremental-20261016-exp06-r02-p01 -o json   # expect an EMPTY list
```

**The injection window closes when this object is created (04:29:26Z in r02).**

**Step 8 — Demonstrate this ticket's defect (read-only): the VMI status advertises a checkpoint that does not exist.**

Run **no earlier than 20 minutes after the pass was created**: do not declare the pass wedged before the
harness's 20-minute pass bound has elapsed, because a healthy incremental here completes in seconds and
r02's own harness only gave up at 04:49:27Z, 20m35s after 04:29:26Z. These two reads are the whole
repro.

```bash
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo \
  -o jsonpath='{.metadata.uid}{"\n"}{.status.changedBlockTracking.state}{"\n"}{.status.changedBlockTracking.backupStatus}{"\n"}'
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-rwzzr -c compute -- \
  virsh checkpoint-dumpxml vm-cbt-demo_vm-20261016-exp06-r02 "vm-incremental-20261016-exp06-r02-p01-2026-10-16_04-29-26"
```

*What you must see:* in the status, the VMI uid `9651acfc-1e0d-4c4e-ad94-581e2c4cdf11` with
`changedBlockTracking.state=Enabled`, then
`changedBlockTracking.backupStatus.backupName=vm-incremental-20261016-exp06-r02-p01`,
`.backupStatus.checkpointName=vm-incremental-20261016-exp06-r02-p01-2026-10-16_04-29-26`,
`.backupStatus.startTimestamp=2026-10-16T04:29:26Z`,
`.backupStatus.volumes=[{vda,rootdisk},{vdb,datadisk}]` and
`.backupStatus.backupMsg="Failed freezing guest filesystem: virError(Code=113 …)"` — all recorded at
04:54:41Z in `observer/effect/post-vmi-cbt.json`; and in the libvirt read, that exact published name
failing, verbatim:

```
error: Domain checkpoint not found: no domain checkpoint with matching name 'vm-incremental-20261016-exp06-r02-p01-2026-10-16_04-29-26'
```

(recorded 04:54Z in `observer/effect/checkpoint-dumpxml-p01.txt`). That mismatch between the API's own
advertised checkpoint and the checkpoint that exists in libvirt is this ticket's defect. Then establish
what *really* exists, because the published volume set is wider than the real checkpoint:

```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-rwzzr -c compute -- \
  virsh checkpoint-list --tree vm-cbt-demo_vm-20261016-exp06-r02
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-rwzzr -c compute -- \
  virsh checkpoint-dumpxml vm-cbt-demo_vm-20261016-exp06-r02 vm-backup-20261016-exp06-r02-2026-10-16_04-27-24
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-rwzzr -c compute -- \
  virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}'
```

*What you must see:* the existing checkpoint declaring only `<disk name='vda' checkpoint='bitmap' …/>`
— no `vdb` disk — so the published `volumes` list over-claims (read 04:52:08Z in
`observer/effect/checkpoint-dumpxml-post.xml`); and the datadisk's node `libvirt-2-format` with an empty
`dirty-bitmaps` list, i.e. the datadisk bitmap the redefinition dropped is gone. Finally, show that the
published value is stable rather than a transient read: repeat the VMI jsonpath read after the harness
has declared the pass failed (r02: `run.json#current_incremental_pass.status=failed`, 04:49:27Z) and
again ~65 minutes after creation (r02: 05:34Z, VMI resourceVersion `27323878`,
`followup/20261016-exp06-r02-same-vm/vmi-before.json`). *What you must see:* the identical
`checkpointName` and `volumes` both times.

**Step 9 — Recover: delete the wedged CRs, then rebuild a real both-disk chain.**

Run after the defect has been observed. The recorded sequence matters: repairing the tracker does
**not** unblock (leg 1), while discarding it does (leg 2).

```bash
oc delete vmbackup vm-incremental-20261016-exp06-r02-p02 -n vm-cbt-demo     # leg 1 L2, finalizer released in 3 s
oc delete vmbackup vm-incremental-20261016-exp06-r02-p03 -n vm-cbt-demo     # releases the finalizer and detaches the hotplug mount
oc delete vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo     # follow-up F2, finalizer released in 3 s
oc patch vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo --subresource=status --type=merge -p '{"status":{"latestCheckpoint":{"volumes":[{"diskTarget":"vda","volumeName":"rootdisk"}]}}}'
oc delete vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo
```

*What you must see:* each `oc delete vmbackup` completes with the CR's `metadata.finalizers` released
(3 s, 2 s and 3 s as recorded) and its destination PVC still `Bound`; the tracker-status patch alone
does **not** unblock the next pass (leg 1), whereas deleting the tracker discards the chain and does
(leg 2). If you are short on pool space, the PVC r02 reclaimed on operator approval was the control
full's fully allocated 80 GiB `vm-backup-pvc-20261016-exp06-r02` — not the three `vm-incremental-pvc-…`
PVCs, which were kept.

Then re-create the tracker and take a fresh full backup to rebuild the chain (leg 2 L4):

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
  name: vm-followup-full-pvc-20261016-exp06-r02-f02
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
  name: vm-followup-full-20261016-exp06-r02-f02
  namespace: vm-cbt-demo
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: 20261016-exp06-r02
spec:
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261016-exp06-r02
  pvcName: vm-followup-full-pvc-20261016-exp06-r02-f02
YAML
oc get vmbackup vm-followup-full-20261016-exp06-r02-f02 -n vm-cbt-demo -o json \
  | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes}'
```

*What you must see:* `status.type=Full` with a `Done` condition whose `status=True` (r02: 07:00:53Z) and
`status.includedVolumes` covering both `rootdisk` and `datadisk`, plus a new checkpoint
`vm-followup-full-20261016-exp06-r02-f02-2026-10-16_07-00-35` (07:00:35Z) on the re-created tracker.
The stale published VMI status entry is only **superseded by a new successful pass**; nothing in the
recorded evidence shows it being cleared on failure.

**Step 10 — Optional accelerators (never required).**

The recorded run drove all of the above with scripts; none is needed to reproduce by hand:
`cbt-chaos/scenarios_v2/CBT-EXP-06/chaos-trigger.sh`,
`cbt-chaos/scenarios_v2/CBT-EXP-06/same-vm-followup.sh`,
`cbt-chaos/scenarios_v2/CBT-EXP-06/leg1-tracker-repair.sh` and
`cbt-chaos/scenarios_v2/CBT-EXP-06/leg2-chain-discard.sh`.

## Current behaviour (observed)

Observed on `20261016-exp06-r02` (all times UTC, from the named artifacts):

- `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02/observer/effect/post-vmi-cbt.json`,
  captured **04:54:41Z** (VMI uid `9651acfc-1e0d-4c4e-ad94-581e2c4cdf11`):
  `changedBlockTracking.state=Enabled`; `backupStatus.backupName=vm-incremental-20261016-exp06-r02-p01`;
  `backupStatus.checkpointName=vm-incremental-20261016-exp06-r02-p01-2026-10-16_04-29-26`;
  `backupStatus.startTimestamp=2026-10-16T04:29:26Z`;
  `backupStatus.volumes=[{vda,rootdisk},{vdb,datadisk}]`;
  `backupStatus.backupMsg="Failed freezing guest filesystem: virError(Code=113 …)"`.
  *Independent artifact observation.*
- The published name does not exist in libvirt —
  `…/runs/20261016-exp06-r02/observer/effect/checkpoint-dumpxml-p01.txt` (read 04:54Z), verbatim:
  ```
  error: Domain checkpoint not found: no domain checkpoint with matching name 'vm-incremental-20261016-exp06-r02-p01-2026-10-16_04-29-26'
  ```
- The checkpoint that **does** exist, `…/runs/20261016-exp06-r02/observer/effect/checkpoint-dumpxml-post.xml`
  (read 04:52:08Z), declares only `<disk name='vda' checkpoint='bitmap' …/>` — so the published volume
  set is also too wide (the tracker-level view of the same split is P5;
  `…/observer/effect/checkpoint-list-post.txt` and `…/checkpoint-tree-post.txt` list what is really
  there).
- **The published value is stable, not a transient read.** The same `checkpointName` and `volumes`
  appear in the follow-up's VMI snapshot at 05:34Z
  (`cbt-chaos/scenarios_v2/CBT-EXP-06/followup/20261016-exp06-r02-same-vm/vmi-before.json`, VMI rv
  `27323878`) — i.e. ~65 minutes after the pass was created and long after the harness had declared it
  failed (`runs/20261016-exp06-r02/run.json#current_incremental_pass.status=failed`, 04:49:27Z).
- **Independent vs inference**: the three reads above are independent artifact observations. The claim
  that consumers would be misled is **inference**; the run's own checker explicitly warns this field is
  a request projection rather than chain proof
  (`runs/20261016-exp06-r02/checkers/evidence-sufficiency.json#false_positive_risks/3`).
- **Neutral/positive fact — keep out of scope**: the guest-freeze warning `virError(Code=113)` on
  `/mnt/datadisk` also appears on successful fulls (r02 leg A; leg 2), so it is neither necessary nor
  sufficient for this state and is **not** filed as a defect here.

## Expected behaviour (contract)

A clarified, enforced contract for the `VirtualMachineInstance.status.changedBlockTracking.backupStatus`
surface:

- Either `checkpointName` is published only once the checkpoint actually exists in libvirt (and
  `volumes` reflects the checkpoint's real disk set), or the field is explicitly documented as a
  *requested* name, with a co-located state saying the checkpoint does not yet exist / the pass never
  started.
- A failed pass must not leave a status surface that reads like an active, both-disks checkpoint.
- Regression: after a successful full and a successful incremental, the published checkpoint name and
  volume set match `virsh checkpoint-dumpxml`.

**Acceptance check (what a reviewer runs).** In the repro state, either the published name resolves
with `virsh checkpoint-dumpxml`, or the status carries an explicit marker that the checkpoint is
absent; every checkpoint name the product API publishes resolves in libvirt.

## Impact, workaround and data safety

- **Consumer risk**: an operator or monitor reading the VMI status concludes the VM tracks a both-disks
  checkpoint when libvirt holds a `vda`-only checkpoint under a different name — a wrong answer about
  data-protection coverage derived from a product-published field.
- **Combined effect**: together with P4 (empty CR event stream) and P1's stale `Initializing` reason,
  this is the third surface that reads healthy/plausible while the backup is provably not progressing.
- **Blast radius**: this VM only (the status is per-VMI). Frequency: deterministic in the wedge state;
  unknown outside it (not attempted).
- **Data safety**: **not** at risk — this is a status-consistency defect only.
- **Workaround**: never infer chain coverage from the VMI status alone; verify against
  `virsh checkpoint-dumpxml` / `checkpoint-list` and the QEMU dirty-bitmap state. Cost: requires
  in-launcher access for every coverage question, which is exactly what a published status field is
  supposed to avoid.
- **Unknowns / what this ticket does not claim**: whether the field can name a nonexistent checkpoint
  on other failure paths; whether any shipped consumer (UI, alerts, tooling) keys off it; and it does
  **not** claim the field is wrong to be written optimistically — that is the contract question.

## Evidence

**Artifact index** (repository-relative; run root
`cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02/`). "raw" = captured command output;
"summary" = derived.

- `observer/effect/post-vmi-cbt.json` (raw; 04:54:41Z, the published `checkpointName` + `volumes`).
- `observer/effect/checkpoint-dumpxml-p01.txt` (raw; "Domain checkpoint not found" — the decisive
  libvirt-level fact), `observer/effect/checkpoint-dumpxml-post.xml` (raw; the existing checkpoint
  covers only `vda`), `observer/effect/checkpoint-list-post.txt` and `…/checkpoint-tree-post.txt` (raw;
  what really exists in libvirt).
- `observer/effect/post-tracker.json` and `trigger/tracker-after-restart.yaml` (raw) — the second
  surface that disagrees (the tracker advertising both volumes; see P5).
- `checkers/evidence-sufficiency.json#false_positive_risks/3` (summary) — the checker's warning that the
  VMI status is a request projection, not chain proof.
- `cbt-chaos/scenarios_v2/CBT-EXP-06/followup/20261016-exp06-r02-same-vm/vmi-before.json` (raw; 05:34Z,
  unchanged value) — stability of the published name.
- `run.json#current_incremental_pass.status=failed` (summary; 04:49:27Z) — the harness had given up
  while the status still read as an active pass.
- `checkers/injection-validity.json` (summary) and `observer/effect/pre-bitmap-history.jsonl` (raw) —
  the pre-removal witness caveat for the state that produces this status.
- `observer/effect/facts-digest.json` (summary) — stream/state first-seen digest used for the timeline;
  it carries **no** image digests (Environment marks those `not recorded`).

- Also present in the pack (recorded; not load-bearing for any claim above): `trigger/action-request.json`, `trigger/exit-statuses.json`, `observer/ARMED`, `observer/PRESERVED`, `observer/finding.md`, `observer/effect/post-vmbackups.json`, `recovery/step2-verify.log`, `reports/test-run-result.md`, `reports/test-run-report.md`, `checkers/report-fidelity.json`.

**UTC timeline** (setup → precondition → injection → effect → failure → recovery; source per entry):

1. 04:27:24Z → 04:28:20Z — control full backup created and reaches `Done=True`
   (`observer/effect/facts-digest.json#vmbackup_state_first_recv_utc`). **Injection window opens.**
2. 04:28:21.690Z — per-disk bitmap removed (`trigger/qmp-remove-result.txt`); VMI restarted; redefinition
   "successful" at 04:28:45.625161Z (`trigger/controller-redefinition-window.log:87`), producing a
   `vda`-only checkpoint (`observer/effect/checkpoint-dumpxml-post.xml`, read 04:52:08Z).
3. **04:29:26Z** — affected pass `…-p01` created, `backupStatus.startTimestamp=2026-10-16T04:29:26Z`
   (`trigger/legB-incremental-backup.yaml`, `observer/effect/post-vmi-cbt.json`). **Injection window
   closes.** The VMI status now carries the name this ticket is about.
4. 04:29:29Z–04:57:02Z — the pass is refused repeatedly by QEMU (`Code=109`) and never becomes terminal
   (`observer/watches/events.jsonl`) — the state in which the status over-claims.
5. 04:49:27Z — the harness declares the pass failed (`run.json#current_incremental_pass`); the VMI
   status is unchanged.
6. **04:54:41Z** — VMI status read: `checkpointName=…-p01-2026-10-16_04-29-26`, `volumes=[vda,vdb]`
   (`observer/effect/post-vmi-cbt.json`). **04:54Z** — libvirt lookup of that name fails
   (`observer/effect/checkpoint-dumpxml-p01.txt`).
7. 05:34Z — the same published value ~65 minutes after creation
   (`followup/20261016-exp06-r02-same-vm/vmi-before.json`).
8. 05:35Z / 06:35Z / 07:00Z — recovery legs (wedged CR deletions; tracker discarded; a fresh full
   completes at 07:01Z) per P1 — the stale published name is only superseded by a *new successful*
   pass, not cleared on failure.

**Retained state.** The run is closed and its pack frozen; nothing under the run root was modified
post-close. The VMI that carried this status was replaced during the run's own restart and later legs,
so the live object is gone; its status capture is retained in `observer/effect/post-vmi-cbt.json` and
the follow-up snapshot. The wedged CRs were deleted during the post-close follow-ups as the documented
unblock; their destination PVCs were retained
(`followup/20261016-exp06-r02-same-vm/wedged-pvc-after.json#status.phase: Bound`).

## Negative results and what would falsify this ticket

- **No artifact contradiction was found for the three reads** (the published name, its absence in
  libvirt, and the `vda`-only real checkpoint) — but the run's own checker warns that this surface is a
  *request projection* rather than chain proof (`checkers/evidence-sufficiency.json#false_positive_risks/3`),
  which is precisely why this is filed as an Improvement with an explicit Bug-lean instead of a Bug.
- **Explicitly out of scope / not a defect here**: the guest-freeze warning `virError(Code=113)` on
  `/mnt/datadisk` also appears on successful fulls (r02 leg A, leg 2), so it neither explains this state
  nor is filed.
- **Related negative result inherited from P5 (do not re-file)**: a silently *completed* per-disk drop
  did not reproduce in 4 attempts / 2 designs; the silent part lives in the metadata layers, which is
  what this ticket and P5 describe.
- **Evidence caveat (must not be dropped)**: the state that produces this status rests partly on the
  injector-only pre-removal bitmap witness (`checkers/injection-validity.json` REJECT;
  `observer/effect/pre-bitmap-history.jsonl`, 0 rows with `target_present=true`); this defect does not
  depend on that attribution, because the wedge is reproduced on a path with no injection (leg 1).
- **Falsifier.** This ticket is a non-issue if `backupStatus.checkpointName` is documented as the
  *requested* checkpoint name and consumers are directed elsewhere for coverage — then only the
  documentation needs the "not yet existing" marker. It is wrong (and would instead be a Bug) if a
  published name is shown to resolve in libvirt on every other failure class while failing only here —
  that would make this a specific bug rather than a contract gap.

## Additional feedback (reporter's notes)

- **Open hypotheses and the smallest experiments that would settle them.**
  - *Is the published name the requested or the existing checkpoint?* Smallest experiment: on a scratch
    VM, read the status immediately after a *successful* incremental and compare the published name with
    `virsh checkpoint-list` — if it matches, the field is "existing" and this is a Bug.
  - *Does a failed pass ever clear/reset its `backupStatus` entry?* Smallest experiment: watch the same
    field across a pass that reaches terminal `Failed` for a different reason.
- **Triage questions that decide scope.**
  - Is `backupStatus.checkpointName` specified as "requested" or "existing"? If "existing", this is a
    Bug, not an Improvement.
  - Should a failed pass clear or reset its `backupStatus` entry on the VMI?
  - Does any shipped consumer (UI, alerts, tooling) depend on this field for chain health?
- **Environment-specific notes for the next reproducer.**
  - The decisive check is inside the launcher: `virsh checkpoint-dumpxml` / `checkpoint-list --tree` in
    the `compute` container. An API-only reader cannot see the defect.
  - Snapshot the VMI status *before* any deletion, and again later, to show it is stable rather than a
    transient read — that contrast is what makes the observation credible.
  - The VMI object is replaced on the restart that fires the redefinition, so match the snapshot to the
    VMI uid you captured the status from.
  - The wedge's own status is in `kubevirt.io/v1`; the chain bookkeeping is in
    `backup.kubevirt.io/v1alpha1`. Do not expect the two to agree in this state — that disagreement is
    the point.
- **Cross-references.** Siblings in this folder: `backup-cr-livelock-on-missing-per-disk-bitmap.md`
  (**P1**, the wedge that produces this status), `vm-wide-backup-capability-deadlock.md` (**P2**, the
  availability consequence of the same wedge),
  `backup-destination-volume-stuck-hotplug-mounted-during-wedge.md` (**P3**, the leaked destination
  mount), `backup-cr-event-stream-empty-on-wedge.md` (**P4**, the missing CR-level failure signal),
  `checkpoint-redefinition-accepts-incomplete-checkpoint.md` (**P5**, the checkpoint/tracker divergence
  this status contradicts), and `20261016-exp06-r02-product-findings.md` (the consolidated working
  analysis; this file corresponds to its Draft B; not filed itself). Findings registry:
  `docs/findings/finding-1-backup-cr-livelock.md` (the wedge) and
  `docs/findings/finding-3-ghost-event-observability.md` (the related misleading-signal
  characterization — other product surfaces that mislead in the same state). **Separately and clearly
  labelled: harness/tooling gaps are not in this ticket** — see
  `cbt-chaos/scenarios_v2/CBT-EXP-06/harness-tickets-20261016-exp06-r02.md`.

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
commands in Steps (`oc delete vmi`, the QMP `block-dirty-bitmap-remove`, `oc delete vmbackup`) are this
ticket's own scoped repro/workaround steps on a dedicated cluster, and no cluster-cleanup command is
included; the commands are re-creations of the recorded shapes and are labelled as such.

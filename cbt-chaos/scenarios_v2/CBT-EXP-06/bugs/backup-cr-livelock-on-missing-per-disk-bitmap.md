# [CBT] Incremental backup wedges permanently in Initializing with no terminal condition and no events on the backup CR when the checkpoint bitmap is missing for one disk

## What this is, in one paragraph

An incremental backup of a virtual machine sticks for ever in its "initializing" state when one of the
VM's disks has lost its dirty bitmap (the per-disk change-tracking map that lives inside the running
VM's QEMU process) while the backup metadata still names that disk. The backup object never reaches a
terminal state, so it keeps its finalizer (the marker that delays deletion of a Kubernetes object) and
its destination volume attached, while the only failure signal appears on the VM instance rather than
on the backup. For an operator this means a VM that looks like it is being backed up is not, until
someone deletes the stuck object by hand.

**When → then → expected**

- **When** an incremental `VirtualMachineBackup` is started against a `VirtualMachineBackupTracker`
  (the CR storing the chain's latest checkpoint) whose recorded state covers two disks — `rootdisk`
  (vda) and `datadisk` (vdb) — on a VM whose checkpoint bitmaps are still present.
- **And** the disruption **CBT-EXP-06 — per-disk checkpoint-bitmap removal** (`chaos-trigger.sh`; **not a krknctl scenario** — krkn's 38 tags include no primitive that can touch a guest QEMU dirty bitmap) is applied: the `datadisk` checkpoint bitmap is deleted from the running QEMU (`block-dirty-bitmap-remove`,`node=libvirt-2-format`, `name=vm-backup-20261016-exp06-r02-2026-10-16_04-27-24`) and the VMI is then restarted to fire the checkpoint-redefinition path.
- **Then (current behaviour):** the new pass stays at `Initializing=True` / `Progressing=False` with
  its creation-time reason for ever — no `type`, no `Done`, no `includedVolumes` — holds
  `backup.kubevirt.io/vmbackup-protection`, and re-tries the identical permanent QEMU refusal
  (`virError(Code=109) … missing or broken bitmap '<checkpoint>' for disk 'vdb'`) until a human
  deletes the CR; the backup object's own event stream stays empty.
- **Expected behaviour:** a start that fails with a permanent error reaches a terminal condition (or
  an explicit full-backup fallback) within a bounded time, releases its finalizer, detaches its
  destination volume, and reports the failure on the backup object itself.

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
| Issue type | **Bug** — a demonstrated violation of the established contract that a backup eventually reaches a terminal condition, releases its finalizer and detaches its destination volume. The failure is a *permanent* error being retried forever, not an ambiguous contract. |
| Priority (proposed) | **High** — availability. The pass never terminates, holds its `backup.kubevirt.io/vmbackup-protection` finalizer, leaves its destination volume mounted **and** rejects every other backup on the VM (see P2); recovery requires an operator to delete the failed CR. Unassigned pending triage. |
| Severity class | availability (with a co-located observability component that hides it — see P4) |
| Owning component (suspected) | **suspected** CNV/KubeVirt backup stack: the virt-controller backup controller's start/requeue path — no terminal resolution for a permanent start failure (source anchor `pkg/storage/cbt/backup.go`, kubevirt v1.8.4-era) — together with the virt-launcher checkpoint path (`pkg/virt-launcher/virtwrap/storage/backup.go` — `RedefineCheckpoint` / `findDisksWithCheckpointBitmap`); API surface `backup.kubevirt.io/v1alpha1`. The precise failing function is **unproven**: no source was read for this run. |
| Component(s) proven involved | virt-controller (unbounded requeue loop; emits `BackupError`), virt-launcher + QEMU (own the per-disk checkpoint bitmap and the `Code=109` refusal), virt-handler (the error-reporting path), and the `VirtualMachineBackup` status writer (a creation-time `Initializing=True` that is never re-stamped). Proven: the backup object's liveness/abort path does not terminate for this error class. |
| Reproducibility | `deterministic` — 4/4: 3/3 on the corrupt-checkpoint path (r01 leg B, r02 `…-p01`, r02 `…-p02`, plus `…-p03` after a manual tracker repair = 4 including it) and 1/1 on the deleted-tracker path (EXP-8). |
| Status / confidence | **Confirmed behaviour, high confidence.** Certain: the wedge, its non-terminal status, the per-disk `Code=109` refusal, 4 reproductions, the CR-only deletion unblock, and that repairing the tracker does **not** unblock. One residual caveat: in r02 the *pre-removal* bitmap state was witnessed only by the disruptor (see Reproducibility → Preconditions). |
| Blast radius | one VM — its entire backup capability, including disks that are individually healthy (via P2). Not cluster-wide. There is no API-only, evidence-preserving recovery. |
| Data at risk? | **No** — QEMU's checkpoint-consistency check refuses the inconsistent backup (a positive backstop, not silent corruption). The harm is loss of backup *coverage* and availability until an operator intervenes. |
| Related scenario / execution | `CBT-EXP-06` / `20261014-exp06-r01` (2026-10-14, leg B); `CBT-EXP-06` / `20261016-exp06-r02` (2026-10-16, closed `BLOCKED` — control leg + affected passes `…-p01`/`…-p02`); post-close same-VM follow-up `20261016-exp06-r02-same-vm` (05:34–05:55Z); post-close `20261016-exp06-r02-leg1-tracker-repair` (06:35–06:56Z); post-close `20261016-exp06-r02-leg2-chain-discard` (07:00–07:01Z); second entry path `CBT-EXP-08` / `20261014-exp08-r01` (2026-10-14). |
| Affected versions | short pointer — OpenShift 4.22.15, CNV `kubevirt-hyperconverged-operator.v4.22.12`, libvirt 11.10.0 / QEMU 10.1.0 in the launcher, `backup.kubevirt.io/v1alpha1`, hostpath CSI pool `cbt-demo-hpp`. The full measured matrix is in **Environment** below. |

## Context (for an engineer new to this area)

- **What the feature does** — KubeVirt changed-block-tracking (CBT) push-mode backups. A
  `VirtualMachineBackup` CR requests a backup of a *source* (a `VirtualMachine`) into a *destination*
  volume that the backup stack hot-plugs into the running VM. Incremental passes work from a chain:
  a **checkpoint** object per backup (the metadata naming the disks and dirty bitmaps it covers), a
  **dirty bitmap per disk inside the running QEMU** (the actual change tracking), and a
  `VirtualMachineBackupTracker` CR holding the chain's latest checkpoint so the next pass can start
  where the last one ended. Redefining a checkpoint on VMI restart means probing each disk's QEMU
  bitmap and rebuilding the checkpoint from the disks that still have one.
- **Where the failure sits** — on the `VirtualMachineBackup` object: `status.conditions` stays at
  `Initializing=True` / `Progressing=False` with a creation-time reason, and `status.type`, `Done`,
  `includedVolumes` and `completionTimestamp` are never set, so the CR never reaches a terminal
  condition and never releases its finalizer.
- **Observed surface vs. origin** — this is the defect: the *failing* object is the backup CR, but
  every failure signal is emitted on the **VMI** (`BackupError` warning events, `involvedObject.kind =
  VirtualMachineInstance`) while the CR's own event stream is empty (P4). An operator who reads only
  the backup object sees a pass that is "still attaching its volume" for hours.
- **Why it matters** — one permanently failing backup start silently disables *all* backups for that
  VM (P2), keeps a destination volume attached to the node (P3), and needs a human to delete a
  CR to clear it. The backup chain is only restored by discarding the tracker, which drops the
  incremental chain.

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

- **Classification**: deterministic. 4 reproductions, 0 failures to reproduce.
- **Attempts**: 4 damaging attempts, on 4 distinct passes over 3 sessions, observed independently.
  - corrupt-checkpoint path (bitmap removed for one disk): 3/3 with the same outcome —
    `20261014-exp06-r01` leg B (2026-10-14, prior run); `20261016-exp06-r02` `…-p01` and `…-p02`
    (2026-10-16); a fourth pass `…-p03` wedged identically after a manual tracker repair.
  - deleted-tracker path: 1/1 (`20261014-exp08-r01`, 2026-10-14).
  - who observed: the r02 run's observer/checker streams and the reporter's post-close follow-up
    drivers; the wedge is visible in raw captured streams (`observer/watches/*.jsonl`,
    `observer/effect/*-window.log`) independent of the reporter.
- **Stability** — exact every time: the two non-terminal conditions with the created-time reason,
  the held finalizer, the `virError(Code=109) … missing or broken bitmap '<checkpoint>' for disk
  'vdb'` error, and the fact that only deleting the CR clears it. Varying: only the retry counts and
  the elapsed time (21 VMI events / ~28 min in r02; 19 retries / ~22 min in r01; 38 controller lines
  / 35 min in leg 1), which depend on the observation window, not the outcome.
- **Preconditions**: a CBT-enabled VM with ≥2 disks whose tracker holds a checkpoint that covers
  them; a full backup that terminates; then a state where *one* disk's QEMU checkpoint bitmap is
  absent while the checkpoint/tracker metadata still names it (per-disk bitmap loss + VMI restart
  fires it). What breaks the repro: a healthy bitmap set (the pass would succeed) or removing the
  tracker instead of a bitmap (a different entry path with its own deadlock variant, below).
- **Attribution caveat (must not be dropped)**: in r02 the *pre-removal* bitmap state was witnessed
  only by the disruptor — the run's own injection checker REJECTed on that gap
  (`checkers/injection-validity.json`; `observer/effect/pre-bitmap-history.jsonl` has 0 rows with
  `target_present=true`). The wedge observation itself is independent (raw observer streams,
  controller logs, live CR reads) and is reproduced on a path with **no injection** (leg 1, tracker
  repair). The heterogeneous tracker/checkpoint/QEMU state must therefore be attributed to the
  product's own surfaces, not to the removal.
- **Second entry path — deleting the tracker mid-copy** (`20261014-exp08-r01`, 2026-10-14): the same
  no-terminal-resolution wedge is reachable from an operator "cleanup" action, with two extra
  consequences.
  1. *Wedge (same class, API-side entry)*: tracker deleted 15 s after observed copy start
     (404-verified) → the backup sticks in `Progressing` while the controller requeues with
     `BackupTracker … does not exist`; no terminal state, no deadline.
  2. *Deletion deadlock (Path-B-specific)*: deleting the wedged CR does **not** clear it while the
     tracker is gone — the abort path itself requires the tracker (`update backup is deleting`
     loop); the CR sat with a `deletionTimestamp` for 35+ minutes, versus 2–3 s when the tracker
     exists (see Current behaviour).
  3. The VM-wide capability deadlock seen here is **not** Path-B-specific; it is filed separately as
     **P2**.
  Recovery (verified): recreating the tracker (re-applying any backup manifest for the VM recreates
  it) unblocks the abort and the wedged CR then deletes. Evidence:
  `cbt-chaos/scenarios_v2/CBT-EXP-08/runs/20261014-exp08-r01/` (`backup-deletion-stuck.yaml`,
  `controller-window.log`, `recovery-backup.yaml`, `trigger.log`).
  A defect reachable two ways is not an artefact of one test; both paths funnel into the same root
  cause, so one fix should close both.

## Steps to reproduce (exact commands and injection timing)

**How to read these steps.** Every object name below is the recorded name of run
`20261016-exp06-r02` in namespace `vm-cbt-demo`, taken verbatim from that run's artifacts, and the
command shapes are the recorded shapes validated in that run (`chaos-trigger.sh`, frozen sha256
`9291f017…`, plus the same-VM follow-up and the two corrective legs). Run this on a dedicated cluster;
on a fresh cluster create the same objects with **new run-scoped names** and substitute them
everywhere — the sequence and the commands do not change, and never reuse another run's names. No
value is left as a placeholder below; the only substitutions a reader makes are their own run-scoped
names.

**Concrete objects used in this report** (all in namespace `vm-cbt-demo`; `uid n/a` = the object kind
has no uid, `not recorded` = the run did not capture it):

| Kind | Name | uid | Created (UTC) | Fate |
|---|---|---|---|---|
| VirtualMachine | `vm-20261016-exp06-r02` | `00c5615f-a7ea-4899-90e0-167cf912b0f0` | not recorded | kept; runStrategy Always, 1 vCPU / 2 GiB |
| DataVolume (`rootdisk`, vda) | `vm-disk-20261016-exp06-r02` | not recorded | not recorded | kept; 80 GiB clone of the RHEL 9 DataSource |
| DataVolume (`datadisk`, vdb) | `vm-data-20261016-exp06-r02` | not recorded | not recorded | kept; 2 GiB blank, ext4 mounted at `/mnt/datadisk` |
| Service (SSH) | `vm-ssh-20261016-exp06-r02` | not recorded | not recorded | kept |
| VMI (before the injection) | `vm-20261016-exp06-r02` | `968b6e7e-c021-46e4-a731-ca0dbec6121f` | not recorded | deleted by the injection at 04:28:22Z |
| VMI (after the injection) | `vm-20261016-exp06-r02` | `9651acfc-1e0d-4c4e-ad94-581e2c4cdf11` | not recorded | Running with CBT Enabled at 04:28:45Z |
| Pod (virt-launcher, before) | `virt-launcher-vm-20261016-exp06-r02-ljm2w` | `1160f767-7cbb-4352-a5cf-3ee37aac611d` | not recorded | replaced with the VMI |
| Pod (virt-launcher, after) | `virt-launcher-vm-20261016-exp06-r02-rwzzr` | `6bb8b6c5-e7af-4ee8-84d6-a689c4159ece` | not recorded | kept through the wedge |
| libvirt domain | `vm-cbt-demo_vm-20261016-exp06-r02` | n/a | not recorded | recreated with the replacement VMI |
| VirtualMachineBackupTracker | `vm-tracker-20261016-exp06-r02` | not recorded | not recorded | deleted in leg 2 L3 (chain discard); re-created in leg 2 L4 |
| Checkpoint (the one whose `datadisk` bitmap was removed) | `vm-backup-20261016-exp06-r02-2026-10-16_04-27-24` | n/a | 04:27:24Z | still advertised by the tracker after its `datadisk` bitmap was gone |
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


**Step 1 — Setup: the 2-disk VM.** Run this first, before any tracker or backup object exists. The
run's VM is the harness's rendering of the templated manifest
`cbt-chaos/scenarios_v2/CBT-EXP-06/vm-2disk.yaml` — its `__VM_NAME__`, `__NAMESPACE__`, `__DV_NAME__`,
`__EXTRA_DV_NAME__`, `__DATA_SOURCE_*__` tokens are filled with the run-scoped names — and that
template is what defines the guest: 1 vCPU / 2 GiB, CBT enabled (the `cbt-demo: enabled` label on the
VM and its pod template), `rootdisk`/vda an 80 GiB clone of the RHEL 9 DataSource and
`datadisk`/vdb 2 GiB blank. On the recorded cluster use the command below to confirm it exists; on a
fresh cluster render that template with your own run-scoped names and apply the rendered file
(`oc apply -f <rendered vm-2disk.yaml>`), because the template's `__…__` tokens are not valid YAML
values as they stand.

```bash
oc get vm vm-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.spec.runStrategy}{"|"}{.spec.template.spec.domain.devices.disks[*].name}'; echo
oc get dv vm-disk-20261016-exp06-r02 vm-data-20261016-exp06-r02 -n vm-cbt-demo -o custom-columns=NAME:.metadata.name,SIZE:.spec.storage.resources.requests.storage,PHASE:.status.phase
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.status.phase}'; echo
```

**What you must see:** `runStrategy` is `Always` and the disk list contains `rootdisk` and `datadisk`;
both DataVolumes report their size and `Succeeded`; the VMI for `vm-20261016-exp06-r02` reports
`status.phase` `Running`.

**Step 2 — Setup: tracker, destination volume and the control full backup.** Run this once the VM is
Running. This is the working schema from `leg2-chain-discard.sh` / `same-vm-followup.sh`; the trio
is (tracker whose `spec.source` is the VM) + (80 GiB PVC on `cbt-demo-hpp`) + (backup whose
`spec.source` is the tracker and whose `pvcName` is that PVC).
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
oc get vmbackup vm-backup-20261016-exp06-r02 -n vm-cbt-demo -o json | jq '{type:.status.type,done:[.status.conditions[]?|select(.type=="Done")],included:.status.includedVolumes}'
oc get vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.status.latestCheckpoint.name}'
```
**What you must see:** `status.type` is `Full`; a `Done` condition with status `True`;
`status.includedVolumes` lists both `rootdisk` and `datadisk` (recorded: created 04:27:24Z,
`Done=True` 04:28:20Z). The tracker's `status.latestCheckpoint.name` printed in the second command
is the checkpoint whose bitmaps matter — recorded `vm-backup-20261016-exp06-r02-2026-10-16_04-27-24`.

**Step 3 — Locate the launcher pod and the domain.** Run this after the control backup completed, and
re-run it after step 7 because the pod name changes with the VMI.
```bash
launcher=$(oc get pod -n vm-cbt-demo -l vm.kubevirt.io/name=vm-20261016-exp06-r02 -o jsonpath='{.items[0].metadata.name}')
echo "$launcher"
oc exec -n vm-cbt-demo "$launcher" -c compute -- virsh list --all
```
**What you must see:** one launcher pod name (recorded `virt-launcher-vm-20261016-exp06-r02-ljm2w`
before the restart, `…-rwzzr` after) and the domain `vm-cbt-demo_vm-20261016-exp06-r02` in state
`running`.

**Step 4 — Fail-closed PRE-check — prove the bitmaps are present before touching anything (read-only).**
Run this immediately after the control backup reached `Done=True`. If it fails, abort the run: the
repro requires a *before* state in which **both** disks hold the checkpoint bitmap.
```bash
kubectl exec -n vm-cbt-demo "$launcher" -c compute -- virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}' | jq '[.return[] | {node:."node-name", bitmaps:[.dirty-bitmaps[]?.name]}]'
```
**What you must see:** node `libvirt-2-format` (the `datadisk` overlay
`/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2`) and node `libvirt-4-format`
(`rootdisk`) each list the checkpoint `vm-backup-20261016-exp06-r02-2026-10-16_04-27-24` in
`dirty-bitmaps`, and the `-storage` siblings `libvirt-2-storage` / `libvirt-4-storage` list none.
Abort if the bitmap is absent on either `-format` node, or if it is not `recording=true`. Note:
`query-block-dirty-bitmap` does not exist on this QEMU — list bitmaps with
`query-named-block-nodes` and read each node's `dirty-bitmaps`.
**A non-injector witness must capture this pre-removal state:** in r02 only the injector did, so
the run's injection checker REJECTed the injection (`checkers/injection-validity.json`;
`observer/effect/pre-bitmap-history.jsonl` has 0 rows with `target_present=true`). Have a second
party, or the observer process, read the same QMP query before the removal.

**Step 5 — INJECTION WINDOW — remove the `datadisk` bitmap only.** The window opens when the control full
backup flips to `Done=True` and closes when the next backup object is created; in r02 it lasted
about a minute (`Done=True` 04:28:20Z, injection 04:28:21.690Z, next backup created 04:29:26Z). Run
the removal inside that window, after step 4 has passed.
```bash
kubectl exec -n vm-cbt-demo "$launcher" -c compute -- virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"block-dirty-bitmap-remove","arguments":{"node":"libvirt-2-format","name":"vm-backup-20261016-exp06-r02-2026-10-16_04-27-24"}}'
```
**What you must see:** exactly `{"return":{}}` — the recorded injection's reply
(`trigger/qmp-remove-result.txt`).

**Step 6 — Fail-closed POST-check — confirm the effect (read-only).** Run the same query as step 4,
immediately after the removal and still inside the window. Do not continue if both disks lost
their bitmap (a different state) or if neither changed.
```bash
kubectl exec -n vm-cbt-demo "$launcher" -c compute -- virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}' | jq '[.return[] | {node:."node-name", bitmaps:[.dirty-bitmaps[]?.name]}]'
```
**What you must see:** `libvirt-2-format`'s `bitmaps` list is now empty while `libvirt-4-format`
still lists the checkpoint bitmap.

**Step 7 — Fire the checkpoint redefinition.** Run this immediately after the POST-check passes; this is
the VMI restart that re-runs checkpoint redefinition against the now-inconsistent QEMU state (in
r02 the delete was requested at 04:28:22Z).
```bash
oc delete vmi vm-20261016-exp06-r02 -n vm-cbt-demo
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.metadata.uid}{"|"}{.status.phase}{"|"}{.status.changedBlockTracking}'; echo
launcher=$(oc get pod -n vm-cbt-demo -l vm.kubevirt.io/name=vm-20261016-exp06-r02 -o jsonpath='{.items[0].metadata.name}')
echo "$launcher"
```
**What you must see:** the VMI uid changes (recorded `968b6e7e-c021-46e4-a731-ca0dbec6121f` →
`9651acfc-1e0d-4c4e-ad94-581e2c4cdf11`), `status.phase` is `Running` with CBT enabled (recorded
04:28:45Z), and the launcher pod name changes with it (recorded `…-ljm2w` → `…-rwzzr`).

**Step 8 — Create the pass that wedges.** Run this once the replacement VMI is Running (r02 created it at
04:29:26Z). Same trio as step 2, with the incremental names; the destination PVC is the pass's own
volume.
```bash
oc apply -f - <<'YAML'
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
oc get vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo -o name
```
**What you must see:** the apply exits 0 and `vm-incremental-20261016-exp06-r02-p01` exists in
`vm-cbt-demo`. (The recorded incremental destination PVC requested 30 GiB, `ReadWriteOnce` on
`cbt-demo-hpp`, and was kept `Bound` with ~0 bytes written —
`followup/20261016-exp06-r02-same-vm/wedged-pvc-after.json#spec`.)

**Step 9 — Observe the defect (read-only).** Start this at creation and keep it running; **wait at least the
harness's 20-minute pass bound** before calling the pass stuck (the harness gave up at 04:49:27Z
after 20m35s; a healthy incremental on this VM completes in seconds).
```bash
oc get vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo -o json | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes,finalizers:.metadata.finalizers}'
oc get events -n vm-cbt-demo --field-selector involvedObject.name=vm-incremental-20261016-exp06-r02-p01 -o json
oc get events -n vm-cbt-demo --field-selector involvedObject.name=vm-20261016-exp06-r02 -o json | jq -r '.items[] | "\(.reason) \(.firstTimestamp) \(.lastTimestamp) count=\(.count)"'
leader=$(oc get lease virt-controller -n openshift-cnv -o jsonpath='{.spec.holderIdentity}' | sed 's/_.*//')
oc logs "$leader" -n openshift-cnv --since=60m | grep -F 'missing or broken bitmap' | tail -5
oc get vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.status.latestCheckpoint}'; echo
```
**What you must see:** `status.conditions` holds only `Initializing` with status `True` and
`Progressing` with status `False`, whose `reason` still names the destination-PVC attach, and its
`lastTransitionTime` never moves; `status.type`, `status.includedVolumes` and any `Done`
condition or `completionTimestamp` are absent; `metadata.finalizers` still lists
`backup.kubevirt.io/vmbackup-protection`; the CR-scoped event list has an **empty** `items` array
while the VMI-scoped list repeats `BackupError` warnings (recorded: 21 of them from 04:29:29Z to
04:57:02Z); the controller log lines carry the per-disk refusal naming disk `vdb`. A healthy pass
in the same run (the step-2 control) already reached `Done=True`, which is what makes this
state-specific.

**Step 10 — Recover — the operator workaround, in two parts.** Run part (a) only after you have saved the
outputs from step 9, because deleting the CR is what removes the failed pass's own evidence.
- **(a) Delete the wedged CR only.** This releases the finalizer and detaches the leaked hotplug
mount; the destination PVC stays behind.
```bash
oc delete vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo
oc get pvc vm-incremental-pvc-20261016-exp06-r02-p01 -n vm-cbt-demo -o jsonpath='{.status.phase}'; echo
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo -o json | jq '[.status.volumeStatus[]?|select(.persistentVolumeClaimInfo.claimName=="vm-incremental-pvc-20261016-exp06-r02-p01")]'
```
**What you must see:** the CR disappears within seconds and stops holding
`backup.kubevirt.io/vmbackup-protection` (recorded: 3 s for `…-p01` in follow-up F2, 3 s for
`…-p02` in leg 1 L2, 2 s for `…-p03` in leg 2 L2), the destination PVC reports `Bound`, and
the VMI's hotplug list for that PVC is `[]`. **The wedged pass itself cannot be revived.**
- **(b) Restore protection — discard the chain, do not repair it.** Repairing the tracker's volume
list is a negative control that **must not** unblock:
```bash
oc patch vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo --subresource=status --type=merge -p '{"status":{"latestCheckpoint":{"volumes":[{"diskTarget":"vda","volumeName":"rootdisk"}]}}}'
```
**What you must see:** the patch is accepted and stays stable (recorded: no controller revert,
`resourceVersion` `27464802`) — and a new pass created after it still names `vdb` and wedges on
the same `virError(Code=109)`, so repairing the tracker does not restore capability. The action
that does is the chain discard, followed by a fresh full backup (the step-2 trio again, with a
new 80 GiB PVC):
```bash
oc delete vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo
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
oc get vmbackup vm-followup-full-20261016-exp06-r02-f02 -n vm-cbt-demo -o json | jq '{type:.status.type,done:[.status.conditions[]?|select(.type=="Done")],included:.status.includedVolumes}'
oc get vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.status.latestCheckpoint.name}'; echo
```
**What you must see:** the fresh full completes quickly (recorded: `Done=True` at 07:00:53Z,
18 s after the leg 2 apply) with both disks in `status.includedVolumes`, and the re-created
tracker's `status.latestCheckpoint.name` is the new both-disk checkpoint (recorded
`vm-followup-full-20261016-exp06-r02-f02-2026-10-16_07-00-35`). This costs a full copy
(~80 GiB here) and silently drops the previous incremental chain. Budget pool space first: the
control full backup's own 80 GiB destination PVC (`vm-backup-pvc-20261016-exp06-r02`) had to be
deleted 2026-10-16 on operator approval, the pool free space having fallen 140.0 GiB →
40.25 GiB.

**Step 11 — Optional accelerators (never required).** `cbt-chaos/scenarios_v2/CBT-EXP-06/chaos-trigger.sh`
performs the whole trigger including the injection; `same-vm-followup.sh`,
`leg1-tracker-repair.sh` and `leg2-chain-discard.sh` are the recorded drivers behind follow-up F2
and legs 1 and 2. The numbered steps above are the manual equivalent of those scripts.

## Current behaviour (observed)

Observed on `20261016-exp06-r02` and its follow-ups (all times UTC, from the named artifacts):

- **The affected pass never terminates.** `vm-incremental-20261016-exp06-r02-p01`, uid
  `46b6f5e1-ced6-4094-8c96-e4d7690c3ea0`, created **04:29:26Z**: `Initializing=True`,
  `Progressing=False`, reason verbatim *"backup target PVC
  vm-incremental-pvc-20261016-exp06-r02-p01 is being attached to VMI vm-20261016-exp06-r02"*,
  `lastTransitionTime` 04:29:26Z never re-stamped; **no** `type`, **no** `Done` condition, **no**
  `includedVolumes`, **no** `completionTimestamp`; finalizer
  `backup.kubevirt.io/vmbackup-protection` held; `resourceVersion 27323776` unchanged from 04:29:26Z
  through the last read (`trigger/legB-incremental-backup.yaml`, `observer/FINAL.json`,
  `recovery/recovery-report.json#steps[0]`). Duration so far: still non-terminal at the last read
  ~65 minutes later (`followup/20261016-exp06-r02-same-vm/wedged-cr-before-delete.yaml`, 05:34Z).
- **The refusal is per-disk and QEMU-authored.** Message verbatim: *"Failed backing up VM: server
  error. command Backup failed: "virError(Code=109, Domain=10, Message='checkpoint inconsistent:
  missing or broken bitmap 'vm-backup-20261016-exp06-r02-2026-10-16_04-27-24' for disk 'vdb'')""*.
- **Every start attempt fails with a deterministic libvirt 400** — the error text
  *"checkpoint inconsistent: missing or broken bitmap '<checkpoint>' for disk 'vdb'"*
  (`virError` Code=109) — and the controller surfaces it as *"failed to send Start backup command:
  Internal error occurred: unexpected return code 400 (400 Bad Request), message: server error.
  command Backup failed: …"*: recorded 19 times in ~22 minutes in r01
  (`cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261014-exp06-r01/legB-controller-retry-loop.log`) and
  40 times in the r02 controller window cited below. *Independent artifact observation.*
- **Redefinition reports success and silently drops one disk** (filed separately as P5):
  virt-controller logs "Checkpoint redefinition successful" at **04:28:45.625161Z**
  (`trigger/controller-redefinition-window.log:87`), yet the resulting checkpoint XML lists **only**
  `<disk name='vda' …/>` (`observer/effect/checkpoint-dumpxml-post.xml`), while the tracker still
  advertises `latestCheckpoint.volumes=[{vda,rootdisk},{vdb,datadisk}]` (rv `27322960`,
  `trigger/tracker-after-restart.yaml`; unchanged in `followup/…/tracker-{before,after}.json`).
- **Detection is loud but mis-scoped.** 21 `BackupError` warning events on the **VMI** between
  04:29:29Z and 04:57:02Z (`observer/watches/events.jsonl`); the single aggregated Event object
  `vm-20261016-exp06-r02.18dee82a1076f935` carried `count=41`, `firstTimestamp 04:29:29Z`,
  `lastTimestamp 05:46:12Z` by the follow-up's capture (`followup/…/f3-events-ns.json`). 40
  virt-controller lines carry the same error between 04:29:29.103549Z and 04:40:22.432162Z, and 20
  virt-handler lines in the same window (`observer/effect/virt-controller-window.log`,
  `…/virt-handler-window.log`). `involvedObject.kind = VirtualMachineInstance` for every one of them,
  and **zero** events on the CR (filed as **P4**). *Independent observation.*
- **Retry cadence (corrected counts).** r02: **21** VMI events over ~28 min (04:29:29Z–04:57:02Z),
  **40** virt-controller + **20** virt-handler lines in the 04:29–04:40 window. The earlier draft's
  "19 retries in 22 minutes" was the r01 figure — r01 remains 19 in ~22 min. Same-VM follow-up:
  **46** controller per-disk bitmap-error lines in the preceding 180 min
  (`followup/20261016-exp06-r02-same-vm/f0-retry.json`), and `…-p02` re-fired one namespace
  `BackupError` at 05:46:12Z. Leg 1: **38** controller lines in 35 min
  (`followup/20261016-exp06-r02-leg1-tracker-repair/RESULT.md`, error at 06:46:59Z).
- **The control pass in the same run was healthy**, which is why this is a state-specific defect and
  not a broken feature: `vm-backup-20261016-exp06-r02`, uid
  `4adf728a-a38f-4a23-878d-e466965180e4`, created 04:27:24Z, `type=Full`, `Done=True` at
  **04:28:20Z**, `includedVolumes=[vda/rootdisk, vdb/datadisk]`
  (`trigger/legA-full-backup.yaml`). Its `Done` reason carries a *warning*
  (`virError(Code=113) … failed to open /mnt/datadisk: Permission denied`) that also appears on
  successful fulls in leg 2 — see Negative results: it is **not** the wedge's cause.
- **Four reproductions of the identical state.** (i) `…-p02`, uid
  `72272cb4-be66-4cdd-a880-85d3b850c134`, created 05:35:13Z, wedged identically at the last read
  05:55Z (`followup/…/f3-new-backup.{json,yaml}`, `f3-result.json` `f3_verdict=wedged`). (ii)
  `…-p03`, uid `55907953-1f2b-476f-a095-9f4934bb07ff`, created 06:36:00Z, wedged with the identical
  `Code=109` error (`followup/20261016-exp06-r02-leg1-tracker-repair/l5-new-backup.json`,
  `leg1-result.json` `verdict=wedged`). (iii) r01 leg B. (iv) the deleted-tracker path (EXP-8).
  **Total: 4** (r01 leg B; r02 `…-p01`, `…-p02`, `…-p03`).
- **Only deleting the CR clears it.** Deleting the wedged CR **only** (keeping its destination PVC)
  releases the finalizer and detaches the leaked hotplug mount in **2–3 s**, with the PVC staying
  `Bound`: `…-p01` 3 s (`followup/20261016-exp06-r02-same-vm/f2-delete-wedged.out`,
  `hotplug-after-unblock.json` = `[]`, `wedged-pvc-after.json#status.phase: Bound`); `…-p02` 3 s
  (`…-leg1-tracker-repair/l2-delete.out`); `…-p03` 2 s (`…-leg2-chain-discard/l2-delete.out`). The
  leaked mount itself is **P3**. *Inference* that the release is bound to CR deletion rather than to
  any timeout: no detach happened across three stalls of 20–65 min, while a deletion detached in 2–3 s.
- **What unblocks backup, and what does not (both follow-up legs).**
  - *Leg 1 — repairing the tracker does NOT help (negative, decisive).* With the tracker's status
    patched to `volumes=[vda/rootdisk]` (accepted, stable at +0 s/+30 s, rv `27464802`, no controller
    revert — `l3-patch.out`, `leg1.log`, `tracker-after.json`), the next pass `…-p03` still named
    `vdb` and wedged on the same `virError(Code=109)`. **The earlier explanation that the tracker's
    stale volume list drives the request is thereby refuted**: the request comes from the
    checkpoint/QEMU mismatch itself, so *repairing* the tracker cannot restore capability.
  - *Leg 2 — discarding the tracker DOES (positive).* With the wedged CR removed and the tracker
    deleted (QEMU's stale root-disk bitmap survived the deletion), a fresh tracker and a new 80 GiB
    destination PVC applied, the next backup completed **`type=Full`, `Done=True` in 18 s,
    `includedVolumes=[vda/rootdisk, vdb/datadisk]`**, with a new both-disk checkpoint and no hotplug
    mounts left (`followup/20261016-exp06-r02-leg2-chain-discard/l5-full-backup.json`, `RESULT.md`).
    So the chain is silently discarded and protection is restored on both disks; the tracker must be
    discarded rather than edited.
- Harness-side bookkeeping (recorded, not a product claim): `make e2e TYPE=incremental` gave up at
  04:49:27Z after 20m35s (`trigger/trigger.log`) and the *harness* marked the pass `failed`
  (`runs/20261016-exp06-r02/run.json#current_incremental_pass`), while the product object recorded no
  failure at all. The harness gap is filed in `harness-tickets-20261016-exp06-r02.md` (H-12), not here.

## Expected behaviour (contract)

Established contract this violates, stated as acceptance criteria:

1. A backup start that fails with a **permanent** error must reach a **terminal** condition
   (`Failed` with a reason, or an explicit fallback to a full backup), release its
   `backup.kubevirt.io/vmbackup-protection` finalizer, and detach its hotplugged destination PVC —
   within a bounded time or bounded retry count. It must not be left `Initializing` forever, and its
   status reason must not keep advertising a PVC attachment that already happened.
2. The status of a stalled pass must be **current**, not a creation-time stamp that contradicts the
   recorded failures.
3. A wedged pass must not disable backup creation for the whole VM (P2).
4. Backup-start failures must be observable on the **backup object's** event stream (P4).
5. The checkpoint-redefinition path must either exclude a disk **and warn** and repair the tracker, or
   invalidate the checkpoint and fall back to a full backup — and the tracker must never advertise a
   volume whose QEMU bitmap is absent (P5).

**Acceptance check (what a reviewer runs).** With the repro above: the new incremental reaches a
terminal condition (or a clean full fallback) within the configured bound and has `type`/`Done`/
`includedVolumes` set; its finalizer is released and its destination PVC detached **without** manual
deletion; a second backup created on the same VM concurrently is either accepted or rejected with a
distinguishable, documented condition, and once the first is terminal the second succeeds (the
one-backup-per-source guard does not outlive the in-progress pass).

## Impact, workaround and data safety

- **Functions lost**: backups for the affected VM — full and incremental, for **all** of its disks,
  including disks that are individually healthy (P2). How an operator notices: only by inspecting the
  VMI event stream or the VMI hotplug state (P3/P4); the backup CR itself reads "in progress" and a
  CR-only monitor never notices.
- **Blast radius**: one VM, per-VM only (other VMs are unaffected). Within that VM the impact is
  total: zero creatable backups until a human deletes the wedged CR, then a chain discard is needed
  to restore protection on both disks.
- **Data safety**: the data path is **not** at risk — QEMU refuses the inconsistent backup, which is a
  positive backstop. What degrades is *coverage*: the VM is simply not backed up until an operator
  intervenes. No silent data loss was observed anywhere in this defect set.
- **Workaround / operator runbook (live-verified)**: delete the wedged CR **only** — the finalizer
  releases and the leaked hotplug mount detaches in 2–3 s, and the destination PVC stays `Bound` and
  must be reclaimed deliberately. Then choose (a) **discard** the tracker and take a fresh backup
  (the chain is silently dropped; a new full completes with both disks protected — leg 2, positive),
  or (b) recreate/ensure the tracker and take a `forceFullBackup: true` backup. **Do not** try to
  *repair* the tracker's volume list (leg 1: it does not unblock). When the tracker is *absent*
  (second entry path), the abort itself wedges, so recreate the tracker before deleting the CR. Cost:
  a manual, evidence-destroying intervention plus a full re-copy; it does **not** fix the underlying
  retry loop and it does not preserve the incremental chain.
- **The run's recovery contract recorded a harness-side unblock that deletes the failed pass's CR
  **and** its PVC** (which would remove the evidence); per the run's errata (item 2) the shipped
  `scripts/vm-cbt-reconcile.sh` deletes nothing and instead refuses unless the operator has already
  deleted both by hand (`cbt-chaos/scenarios_v2/CBT-EXP-06/analysis/20261016-exp06-r02-errata.md`).
  Either way there is no API-only, evidence-preserving recovery.
- **Frequency**: deterministic in this scenario family — it will be hit whenever a per-disk bitmap
  is lost while the metadata still names it (and on the deleted-tracker path). Not a rare race.
- **Unknowns / what this ticket does not claim**: it does not claim a completed backup with a disk
  silently omitted (see Negative results); it does not claim the `Code=113` guest-freeze warning as a
  cause; and it does not attribute the wedge to the injection itself (the pre-removal witness gap).

## Evidence

**Artifact index** (repository-relative; run root
`cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02/`). "raw" = captured stream/command
output; "summary" = derived by the run's observer/checkers.

- `trigger/legA-full-backup.yaml` (raw) — control full: `type=Full`, `Done=True` 04:28:20Z, both disks
  included, `Code=113` warning in the Done reason.
- `trigger/legB-incremental-backup.yaml` (raw), `observer/FINAL.json#runtime_checks_at_final_utc.p01`
  (summary), `observer/effect/preserved-summary.json` (summary) — p01 non-terminal, rv unchanged.
- `observer/watches/events.jsonl` (raw; 21 `BackupError` rows, VMI-scoped),
  `observer/effect/virt-controller-window.log` (raw; 40 lines) and `…/virt-handler-window.log` (raw;
  20 lines) — the `Code=109` retry storm.
- `trigger/bitmaps-before.json`, `trigger/qmp-remove-result.txt` (`{"return":{}}`),
  `trigger/bitmaps-after.json` (all raw) — the per-disk surgery (injector-attested).
- `observer/effect/pre-bitmap-history.jsonl`, `…/qmp-nodes-post.json`, `…/qmp-bitmaps-post.json`,
  `…/qmp-nodes-post-late.json` (raw) — per-disk contrast; zero `target_present=true` rows (the
  independent-witness gap).
- `trigger/controller-redefinition-window.log:79-87` (raw) — redefinition "successful" with no warning.
- `observer/effect/checkpoint-dumpxml-post.xml` (raw; only `vda`) versus
  `trigger/tracker-after-restart.yaml` and `observer/effect/post-tracker.json` (raw; read 04:50:46Z,
  `rootdisk`+`datadisk`) — the metadata divergence (P5).
- `checkers/verdict.json` (summary; `product_findings[0]`, `attribution_caveat`),
  `checkers/evidence-sufficiency.json` (summary; C2 BLOCKED, C4 UNKNOWN),
  `checkers/injection-validity.json` (summary; REJECT), `state.json` (summary; closed),
  `evidence-index.json` (summary; 157 files).
- `recovery/recovery-report.json#steps[0]`, `#steps[2]`, `#terminal_status=BLOCKED` and
  `recovery/step3-extend.log` (summary + raw) — the harness could not add a same-VM pass without
  destroying the evidence.
- Post-close same-VM follow-up
  (`cbt-chaos/scenarios_v2/CBT-EXP-06/followup/20261016-exp06-r02-same-vm/`):
  `wedged-cr-before-delete.{json,yaml}`, `f0-retry.json` (46 controller bitmap-error lines in the
  preceding 180 min), `hotplug-before.json`, `f1-apply.out`, `f2-delete-wedged.out`,
  `wedged-pvc-after.json`, `hotplug-after-unblock.json`, `f3-new-backup.{json,yaml}`,
  `f3-events-ns.json`, `f3-events-cr.json`, `f3-result.json`, `tracker-{before,after}.json`,
  `vmi-before.json`, `followup.log`, `controller-window.log` (all raw); earlier CR-scoped capture
  `followup/20261016-r02-same-vm/wedged-cr-events.json` (raw; `items: []`). Driver:
  `cbt-chaos/scenarios_v2/CBT-EXP-06/same-vm-followup.sh`; write-up
  `followup/20261016-exp06-r02-same-vm/FINDINGS.md` (summary; not part of the frozen pack).
- Post-close leg 1 (`followup/20261016-exp06-r02-leg1-tracker-repair/`, raw + summary):
  `l2-delete.out`, `l3-patch.out`, `tracker-before-patch.json`, `tracker-after.json`,
  `checkpoint-dumpxml-before-patch.xml`, `checkpoint-dumpxml-after.xml`, `l4-apply.out`,
  `l5-new-backup.json`, `l5-events-ns.json`, `leg1-result.json`, `leg1.log`, `RESULT.md`.
  Driver: `cbt-chaos/scenarios_v2/CBT-EXP-06/leg1-tracker-repair.sh`.
- Post-close leg 2 (`followup/20261016-exp06-r02-leg2-chain-discard/`, raw + summary):
  `l2-delete.out`, `l3-delete-tracker.out`, `l4-apply.out`, `l5-full-backup.{json,yaml}`,
  `l5-events-ns.json`, `leg2-result.json`, `RESULT.md`.
  Driver: `cbt-chaos/scenarios_v2/CBT-EXP-06/leg2-chain-discard.sh`.
- Prior runs: `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261014-exp06-r01/`
  (`legB-incremental-backup.yaml`, `legB-controller-retry-loop.log`, `bitmaps-*.json`,
  `tracker-after-restart.yaml`; and the prior-run observability contrast `observer/events-incr.jsonl`
  — backup-object events: EMPTY — versus `observer/events-vm.jsonl` — 19 `BackupError` events on the
  VMI, the antecedent of P4) and `cbt-chaos/scenarios_v2/CBT-EXP-08/runs/20261014-exp08-r01/`
  (second entry path: `backup-deletion-stuck.yaml`, `controller-window.log`, `recovery-backup.yaml`).
- Reference finding: `docs/findings/finding-1-backup-cr-livelock.md` (summary; prior-run
  characterization incl. the source anchors cited above).

- Also present in the pack (recorded; not load-bearing for any claim above): `trigger/action-request.json`, `trigger/exit-statuses.json`, `observer/ARMED`, `observer/PRESERVED`, `observer/finding.md`, `observer/effect/post-vmbackups.json`, `recovery/step2-verify.log`, `reports/test-run-result.md`, `reports/test-run-report.md`, `checkers/report-fidelity.json`.

**UTC timeline** (setup → precondition → injection → effect → failure → recovery; source per entry):

1. 04:26:10Z — first VMI (uid `968b6e7e-…`) observed `Pending`/CBT `Initializing`
   (`observer/effect/facts-digest.json#vmi_phase_cbt_first_recv_utc`).
2. 04:26:33Z — VMI `Running`, CBT `Enabled` (same source) — the VM can be backed up.
3. 04:27:24Z — control full backup created, uid `4adf728a-…` (`facts-digest.json`,
   `trigger/legA-full-backup.yaml`).
4. 04:28:19Z → **04:28:20Z** — full pass detaches its target PVC and reaches `Done=True` (with the
   unrelated `Code=113` warning). **The injection window opens here.**
5. 04:28:21.582Z — datadisk node `libvirt-2-format` bitmap present (injector-attested;
   `trigger/bitmaps-before.json`).
6. 04:28:21.690Z — bitmap removed, reply `{"return":{}}` (`trigger/qmp-remove-result.txt`); empty
   after (`trigger/bitmaps-after.json`).
7. 04:28:32Z — replacement VMI (uid `9651acfc-…`) first observed; the restart fires redefinition
   (`facts-digest.json`).
8. 04:28:45.625161Z — "Checkpoint redefinition successful", no warning
   (`trigger/controller-redefinition-window.log:87`).
9. 04:28:48.689Z — tracker rv `27322960` still advertises both volumes
   (`trigger/tracker-after-restart.yaml`); the checkpoint XML from 04:52:08Z covers only `vda`
   (`observer/effect/checkpoint-dumpxml-post.xml`).
10. 04:28:54Z — datadisk node empty while the rootdisk node still holds the bitmap
    (`observer/effect/qmp-nodes-post.json`).
11. **04:29:26Z** — affected pass `…-p01` created, `Initializing=True`/`Progressing=False`.
    **The injection window closes here** (the next backup object exists).
12. 04:29:29Z — first `BackupError` on the VMI (`observer/watches/events.jsonl`).
13. 04:29:29.103549Z–04:40:22.432162Z — 40 virt-controller + 20 virt-handler error lines
    (`observer/effect/*-window.log`).
14. 04:49:27Z — the *harness* gives up after 20m35s and marks the pass failed
    (`trigger/trigger.log`); the product object records nothing.
15. 04:57:02Z — last of the 21 VMI `BackupError` rows (`observer/watches/events.jsonl`).
16. 05:34Z — the CR is still non-terminal ~65 min after creation; a new backup on the same VM is
    rejected at admission (`followup/20261016-exp06-r02-same-vm/wedged-cr-before-delete.yaml`,
    `f1-apply.out` — P2).
17. 05:35:13Z — `…-p02` created (uid `72272cb4-…`), wedges identically; 05:46:12Z it re-fires one
    namespace `BackupError`; still wedged at 05:55Z (`f3-result.json#f3_verdict=wedged`).
18. 06:35Z–06:56Z — leg 1: tracker repaired (rv `27464802`), `…-p03` created 06:36:00Z, wedges on
    `vdb`; 38 controller lines in 35 min, error at 06:46:59Z (`leg1-tracker-repair/RESULT.md`).
19. 07:00Z–07:01Z — leg 2: wedged CR deleted, tracker deleted, fresh tracker + new 80 GiB PVC; the
    next backup completes `type=Full`, `Done=True` in 18 s, both disks
    (`leg2-chain-discard/l5-full-backup.json`) — recovery.
20. Post-run — approved reclaim of the run's own 80 GiB full-backup PVC (pool free space 40.25 →
    119.97 GiB).

**Retained state.** The run is closed and its pack frozen (`state.json` closed;
`evidence-index.json` lists 157 files) and nothing under the run root was modified post-close. Live
objects: the wedged CRs `…-p01`, `…-p02`, `…-p03` were deleted during the post-close follow-ups —
that deletion *is* the documented unblock under test, and their destination PVCs were deliberately
kept (`wedged-pvc-after.json#status.phase: Bound`). The tracker was deleted and replaced in leg 2,
so the pre-wedge tracker object no longer exists. The run's own 80 GiB full-backup PVC was reclaimed
after the run with approval (capacity recovery). Whether the scenario VM itself was finally deleted
is `not recorded` — the evidence ends with a successful full backup on it.

## Negative results and what would falsify this ticket

**Refuted hypotheses (do not re-file these as defects):**

- **Silent *completed* per-disk drop — refuted 0/4 across 2 designs.** The hypothesis that a pass
  could complete while silently omitting the disk did **not** occur in **4 attempts across 2 designs**
  (r01 leg B; r02
  `…-p01`, `…-p02`, `…-p03`): no affected pass ever completed, every one was loudly refused by QEMU
  (`Code=109`), and the loss of protection was never permanent — leg 2 restored **both** disks with a
  fresh full. What *is* silent is the **metadata** layer (P5).
- **The `Code=113` guest-freeze warning is not the cause.** `virError(Code=113) … failed to open
  /mnt/datadisk: Permission denied` also appears on successful fulls (r02 leg A and leg 2), so it is
  neither necessary nor sufficient for this state (`trigger/legA-full-backup.yaml`,
  `leg2-chain-discard/l5-full-backup.json`).
- **The tracker's stale volume list does not drive the failing request.** Leg 1 patched the tracker
  to `[vda/rootdisk]` and the next pass still named `vdb` and failed on the same bitmap
  (`leg1-tracker-repair/l3-patch.out`, `l5-new-backup.json`) — the request comes from the
  checkpoint/QEMU reality.
- **It is not a broken detach mechanism.** Finalizer release and mount detach succeeded every time
  once triggered, in 2–3 s; the defect is the *trigger*, not the cleanup (P3).
- **Contradictory/limiting evidence recorded honestly**: (a) the run's injection checker REJECTed on
  the missing non-injector pre-removal witness, so the causal attribution is injector-attested and the
  heterogeneous state must be attributed to the product's own surfaces, not to the removal
  (`checkers/injection-validity.json`; `observer/effect/pre-bitmap-history.jsonl`, 0 rows with
  `target_present=true`); (b) the run's deterministic evaluator returned `FAIL` on an
  `injection-signal` check whose table models a different scenario family — a harness fact, not
  product evidence (`verdict-evaluator.json`; harness ticket H-01); (c) the wedged CR "looks" healthy
  to a naive `status.conditions` reader, so any automated detector must treat "non-terminal past
  bound" as failure rather than rely on `Failed`.

**Falsifier.** This ticket is wrong if a wedged pass like `…-p01` is shown to reach a terminal
condition on its own within a bounded window (i.e. the retry loop does terminate eventually), or if
the same non-terminal CR state is shown to be reachable *only* by way of the harness's own actions
rather than by a per-disk bitmap loss + VMI restart on unmodified product code. Either observation
would downgrade this from a defect to a non-issue or a harness artefact. Note that the negative
result above already rules out the "it eventually completes while dropping the disk" variant.

## Additional feedback (reporter's notes)

- **Open hypotheses and the smallest experiments that would settle them.**
  - *Is there any bounded retry/deadline at all?* Smallest experiment: leave one wedged pass alone
    for 24 h on a scratch VM and read `status.conditions` + the CR's `resourceVersion` change count;
    a non-moving rv with a growing VMI event count answers it without touching the evidence.
  - *Can a completed pass omit a disk via the tracker-reset path?* Not answered here: the leg that
    could answer it needs a fresh full-backup PVC (~80 GiB) while the pool held only 40.25 GiB free
    (`followup/20261016-exp06-r02-same-vm/f3-result.json#pool_free_before_bytes` = 43215937536), so it
    was refused for capacity rather than run.
  - *Which component owns the detach and is a stall timeout never reached?* See P3's triage question.
- **Triage questions that decide scope.**
  - Which is the intended terminal-resolution mechanism for a permanent backup-start failure —
    a max-retry counter, a deadline, or immediate classification of `isCheckpointInvalid`-style
    errors?
  - Is the one-backup-per-source guard supposed to consult the wedged pass's terminal-ness (P2), or
    is the intended recovery "operator deletes the CR"?
  - Should the abort path work when the tracker is absent (second entry path), or is tracker presence
    a documented prerequisite?
- **Environment-specific notes for the next reproducer.**
  - Capacity must be measured on `/var/hpvolumes/csi` (`/dev/sdb`), not on its parent
    `/var/hpvolumes` (`/dev/sda4`) — measuring the parent gives the wrong filesystem (Environment,
    "pool-filesystem trap"). This directly affected the follow-up planning.
  - Everything runs on one worker node (`<node>`) because the hostpath CSI pool is pinned there; a
    fresh full backup costs ~80 GiB of fully allocated pool space per attempt. Plan capacity before
    attempting extra legs.
  - The injection window is short: the control full's `Done=True` transition to the creation of the
    next backup object (r02: 04:28:20Z → 04:29:26Z). Have the QMP query typed and a second witness
    ready before you start.
  - QMP sub-commands matter: `query-named-block-nodes` and `block-dirty-bitmap-remove` used here are
    QEMU-version-sensitive, and the bitmap lives on the disk's `-format` node
    (`libvirt-2-format` for the datadisk in this run).
  - The `Initializing=True` reason is a creation-time stamp; do not use it as a progress signal — use
    the CR's `resourceVersion` movement.
  - A hash/introspection note for someone re-deriving this: `observer/effect/facts-digest.json` is a
    stream/state first-seen digest; despite an earlier draft's pointer it carries **no** image digests
    (Environment marks the virt-handler/virt-controller digests `not recorded`).
- **Cross-references.** Siblings in this folder: `vm-wide-backup-capability-deadlock.md` (**P2** — the
  one-backup-per-source rejection that turns this wedge into a VM-wide backup outage),
  `backup-destination-volume-stuck-hotplug-mounted-during-wedge.md` (**P3** — the destination volume
  held hotplug-mounted for the whole stall, released only on CR deletion),
  `backup-cr-event-stream-empty-on-wedge.md` (**P4** — the failure is emitted only on the VMI),
  `checkpoint-redefinition-accepts-incomplete-checkpoint.md` (**P5** — the silent incomplete
  checkpoint redefinition and tracker divergence that precede this wedge),
  `vmi-backupstatus-advertises-nonexistent-checkpoint.md` (**P6** — the VMI status surface naming a
  checkpoint libvirt does not have), and `20261016-exp06-r02-product-findings.md` (the consolidated
  working analysis for the run; not filed itself). Findings registry:
  `docs/findings/finding-1-backup-cr-livelock.md` (Path A, Path B, the deadlock variant, the source
  anchors cited here) and `docs/findings/finding-3-ghost-event-observability.md` (the related
  misleading-event characterization, whose recorded disposition folds the observability component into
  the root-cause ticket — realized here as P4). **Separately and clearly labelled: harness/tooling
  gaps for this run are not in this ticket** — they live in
  `cbt-chaos/scenarios_v2/CBT-EXP-06/harness-tickets-20261016-exp06-r02.md` (e.g. the pre-state
  witness gap H-03, the out-of-shape evaluator H-01, the hard-coded trigger exit status H-05).

## Sanitisation checklist

- [ ] No credentials, tokens, kubeconfig contents or private keys
- [ ] No private hostnames or absolute host paths
- [ ] No broad selectors (names or run-scoped labels only)
- [ ] No destructive commands other than the documented, scoped workaround
- [ ] Commands are the ones actually validated (illustrative ones are labelled)

Notes making the checklist true: the worker node name is genericised as `<node>` and no reporter host
path appears; the only absolute paths retained are the cluster-internal storage-pool paths
(`/var/hpvolumes`, `/var/hpvolumes/csi`, `/dev/sdb`, `/dev/sda4`) and guest paths (`/mnt/datadisk`),
which are product data required to reproduce the pool-filesystem trap; every object name used is
run-scoped or a `<placeholder>`; the destructive commands in Steps (`oc delete vmi`, the QMP
`block-dirty-bitmap-remove`, `oc delete vmbackup`) are the ticket's own scoped repro/workaround steps
on a dedicated cluster, and no cluster-cleanup command is included; the commands are re-creations of
the recorded shapes and are labelled as such in the Steps preamble.

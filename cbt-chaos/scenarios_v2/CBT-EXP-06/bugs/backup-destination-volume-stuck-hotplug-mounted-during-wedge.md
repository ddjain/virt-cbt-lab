# [Bug]: A wedged backup keeps its destination volume hotplug-mounted to the VM for the entire stall, released only when the stuck CR is deleted

## What this is, in one paragraph

KubeVirt CBT (**Changed Block Tracking**, the feature that lets an incremental backup copy only the disk
blocks that changed since the previous pass) writes each pass into an empty **destination** PVC, which
the backup stack **hotplugs** into the running VM — it is attached to the live VM as an extra disk and
served by an attachment pod named `hp-volume-*`, so it shows up on the VirtualMachineInstance (VMI, the
running-instance object that carries the live volume state) as a hotplug volume under
`status.volumeStatus[*].hotplugVolume`. The contract is that a backup releases that volume when it
reaches a terminal state. Here a pass that never reaches any terminal state keeps the mount for its
whole stall (20–65 minutes observed), and the mount clears only when an operator deletes the stuck
`VirtualMachineBackup` CR (custom resource) — no timeout releases it. For that whole time the
destination volume, which is `ReadWriteOnce`, stays pinned to the node the VM runs on, and one hotplug
attachment slot on the VMI stays consumed, per wedged pass.

**When → then → expected**

- **When** a `VirtualMachineBackup` (an incremental pass against a `VirtualMachineBackupTracker`, the
  object that owns the checkpoint chain) has hotplugged its destination PVC into the running VMI and
  then cannot make progress, so the CR stays non-terminal for longer than the harness's 20-minute pass
  bound — no terminal condition, and its `backup.kubevirt.io/vmbackup-protection` finalizer (the
  `metadata.finalizers` entry that keeps the object alive) still held. A healthy incremental here
  completes in seconds.
- **And** the disruption **CBT-EXP-06 — per-disk checkpoint-bitmap removal** (`chaos-trigger.sh`; **not a krknctl scenario** — krkn's 38 tags include no primitive that can touch a guest QEMU dirty bitmap) is applied: right after the control full backup reports `Done=True`, the datadisk's dirty bitmap (the per-disk change-tracking map inside the running VM's QEMU, reached through the QMP/QEMU monitor) is removed with `block-dirty-bitmap-remove`, then the VMI is deleted so the replacement VMI re-creates its checkpoint, and the next pass on that tracker starts against the now-missing bitmap.
- **Then (current behaviour):** the destination volume stays `phase: MountedToPod` with its own
  `hp-volume-*` attach pod on the VMI for the entire stall — recorded for ~65 minutes on `…-p01` and
  ~20 minutes each on `…-p02` and `…-p03`, with no unmount event — and it clears only when the wedged
  CR itself is deleted, in 2–3 s, not by any timeout.
- **Expected behaviour:** a backup that cannot progress must release its hotplugged destination volume
  by a mechanism that needs no operator action — on terminal-failure classification, on a bounded
  stall timeout, or by a cleanup reconciliation driven by the backup object's own state — and, pending
  that, the stall must be visible as a cleanup condition so a monitor can detect "an attached
  destination volume with a non-progressing backup" without inspecting the VMI.

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
| Issue type | **Bug** — the ordinary contract "terminal backup ⇒ destination volume detached" is demonstrated to be violated for a permanently non-terminal pass. The machinery is not broken; nothing drives it from the failure. |
| Priority (proposed) | **Medium/High** — resource leak plus an operator-visible stuck state (an `ReadWriteOnce` volume pinned to the VM's node for the whole stall, and a stale hotplug attachment entry on the VMI). No data loss. Scenario priority was P1 in this defect set. Unassigned pending triage. |
| Severity class | resource leak |
| Owning component (suspected) | **suspected** CBT backup hotplug/volume-attachment path: virt-handler-driven attach with controller-driven release on terminal state. The exact cleanup owner is **unproven** — no source anchor was read for this run. |
| Component(s) proven involved | the VMI hotplug volume status surface (`vmi.status.volumeStatus[*].hotplugVolume`, attach pods named `hp-volume-*`) and the `VirtualMachineBackup` liveness path (the CR is non-terminal, so no terminal-state cleanup ever runs). Proven by contrast: the detach machinery itself works — it detaches in 2–3 s when a CR is deleted. |
| Reproducibility | `deterministic` — 4/4 wedged passes leaked their own attachment and released it only on CR deletion: r02 `…-p01` (65 min), follow-up `…-p02` (~20 min), `…-p03` (~20 min), plus the r02 pass counted with the follow-ups. |
| Status / confidence | **Confirmed behaviour, high confidence.** Certain: the mount state, the attach-pod names, the deletion outputs and the 2–3 s release timings. **Inference**: that the release is *bound to* CR deletion rather than to any timeout (no detach across three stalls of 20–65 minutes, while a deletion detached every time). |
| Blast radius | one VM and the node it runs on (the `ReadWriteOnce` destination volume stays attached to that node); it consumes a hotplug attachment slot on the VMI for as long as the wedge lives. Repeated wedges accumulate one attachment each. |
| Data at risk? | **No** — the destination volume is empty (the copy never progressed), and the source data is untouched. This is a leak of attachment/resources, not of data. |
| Related scenario / execution | `CBT-EXP-06` / `20261016-exp06-r02` (2026-10-16, closed `BLOCKED`, pass `…-p01`); post-close same-VM follow-up `20261016-exp06-r02-same-vm` (F0 05:34Z, F2, F3), post-close leg 1 `20261016-exp06-r02-leg1-tracker-repair` (06:35Z–06:56Z), post-close leg 2 `20261016-exp06-r02-leg2-chain-discard` (07:00Z–07:01Z). |
| Affected versions | short pointer — OpenShift 4.22.15, CNV `kubevirt-hyperconverged-operator.v4.22.12`, `backup.kubevirt.io/v1alpha1`, hostpath CSI pool `cbt-demo-hpp`. The full measured matrix is in **Environment** below. |

## Context (for an engineer new to this area)

- **What the feature does** — KubeVirt CBT push-mode backups copy into an empty **destination** PVC
  that the backup stack **hotplugs** into the running VM: it appears in the VMI's volume status as a
  hotplug volume (`MountedToPod`) served by an attachment pod (`hp-volume-*`). On the healthy path the
  volume is detached when the backup reaches its terminal state.
- **Where the failure sits** — on the VMI's volume status: the destination volume's hotplug entry
  stays `MountedToPod` with its attach pod for the whole stall, and the destination PVC (which is
  `ReadWriteOnce`) therefore stays attached to the VM's node.
- **Observed surface vs. origin** — the failed object is the backup CR (non-terminal, P1), but the
  *visible* symptom is on the VMI: a stale hotplug attachment. The CR itself carries no cleanup
  condition (P4), so the leaked mount is the only unilateral, inspectable symptom of the wedge.
- **Why it matters** — an operator who does not inspect the VMI cannot see it; an operator who does
  sees a mount that will never clear by itself. On a cluster where many VMs wedge, one RWO volume per
  wedge is pinned to a node and one hotplug slot per wedge is consumed, indefinitely.

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
| Storage (in use) | destination (backup-target) PVC access mode | `ReadWriteOnce` — e.g. `vm-backup-pvc-20261016-exp06-r02` (80 Gi full-backup destination) and `vm-incremental-pvc-20261016-exp06-r02-p01` (30 Gi incremental destination); this is why a leaked hotplug mount pins the volume to the VM's node for the whole stall | `oc get pvc -n <ns> -o jsonpath='{.spec.accessModes}'`; pack `observer/effect/post-pvcs.json` | **ticket-specific (P3)** |
| Virtualization | hotplug attach mechanism in scope | virt-handler-driven hotplug attach pod (`hp-volume-*`) with the destination volume reported under `vmi.status.volumeStatus[*].hotplugVolume` | `oc get vmi <vmi> -o jsonpath='{.status.volumeStatus[*].hotplugVolume}'` | **ticket-specific (P3)** |

**Load-bearing versions.** The QEMU/libvirt version matters: this repro drives `query-named-block-nodes`
and `block-dirty-bitmap-remove` over QMP, and the decisive error text (`checkpoint inconsistent:
missing or broken bitmap …`) is QEMU's own. The pool-filesystem trap matters too — capacity was
measured on `/var/hpvolumes/csi` (`/dev/sdb`), not on its parent filesystem, and a measurement on the
parent gives the wrong answer.

**Storage present but not exercised.** ODF/OCS and local-storage are captured only to bound the
search space; nothing in this ticket depends on them. The only storage path in play is the hostpath
CSI pool `cbt-demo-hpp` on the single worker `<node>`.

## Reproducibility

- **Classification**: deterministic — the leak recurred on every wedged pass observed (4/4 including
  the r02 pass itself: 3/3 in the follow-ups, plus the r02 pass).
- **Attempts**: r02 `…-p01` (created 04:29:26Z, still mounted at 05:34Z ≈ 65 min);
  follow-up `…-p02` (created 05:35:13Z, own attach pod `hp-volume-ngsjk`, no unmount event);
  leg-1 `…-p03` (created 06:36:00Z, own destination PVC attached, stayed wedged); each released only
  when its CR was deleted (3 s, 3 s, 2 s respectively).
- **Stability** — exact every time: the `MountedToPod` phase with a `hp-volume-*` attach pod that
  has no matching unmount; the 2–3 s release on CR deletion; the destination PVC remaining `Bound`.
  Varying: only the attach-pod name and the stall duration.
- **Preconditions**: a non-terminal backup that has already hotplugged its destination volume (i.e.
  the P1 wedge, or any non-terminal pass on that path). What breaks the repro: a pass that reaches a
  terminal state — the volume then detaches normally.
- **Second entry path**: not separately attempted. The leak is a function of the CR being
  non-terminal, so the deleted-tracker entry path (EXP-8) should show the same leak; that is
  **[INFERENCE]**, not an observation, and it is listed as an open question below.
- **Attribution caveat**: the *cause* of the stall rests partly on the injector-only pre-removal
  bitmap witness (`checkers/injection-validity.json` REJECT;
  `observer/effect/pre-bitmap-history.jsonl`, 0 rows with `target_present=true`). The leak observation
  is independent of that gap: it is a pure VMI/CR state read, and it is reproduced on a path with no
  injection (leg 1).

## Steps to reproduce (exact commands and injection timing)

Every object name below is the recorded name of run `20261016-exp06-r02` (namespace `vm-cbt-demo`),
taken verbatim from that run's artifacts, so the commands run as written against a re-creation of it on
a dedicated cluster. On a fresh cluster, create equivalents with your own run-scoped names and
substitute them everywhere; never reuse another run's names. All commands are reads or scoped actions
on these named objects; no cluster-cleanup command is included.

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

**Which CRs were deleted and by which leg, and which PVCs were kept** (the `Fate` column, spelled out):
the three wedged CRs were each deleted by a different post-close leg — `…-p01` in the same-VM follow-up
(F2), `…-p02` in leg 1 L2, `…-p03` in leg 2 L2 — every one of those deletions being the documented
unblock under test; their destination PVCs `vm-incremental-pvc-20261016-exp06-r02-p01`/`-p02`/`-p03`
were deliberately **kept** and remain `Bound`. The control full's CR `vm-backup-20261016-exp06-r02` was
kept while its 80 GiB destination PVC `vm-backup-pvc-20261016-exp06-r02` was **deleted** on 2026-10-16
on operator approval to reclaim pool space; the post-recovery full's 80 GiB destination PVC
`vm-followup-full-pvc-20261016-exp06-r02-f02` was **kept**. The pre-wedge tracker object no longer
exists (deleted in leg 2, then re-created in leg 2 L4). The never-admitted `…-f01` backup CR was never
created (admission rejected it — see the deadlock ticket) and its 3 GiB PVC was created and then
removed. Whether the scenario VM itself was finally deleted is `not recorded`.

**Step 1 — Setup — the VM, the tracker, the control full backup, and the healthy baseline.** Run first, on a
dedicated cluster, before anything is injected. The 2-disk CBT-enabled RHEL 9 VM
`vm-20261016-exp06-r02` must already be running (`rootdisk`/vda from DataVolume
`vm-disk-20261016-exp06-r02`, `datadisk`/vdb from DataVolume `vm-data-20261016-exp06-r02`, ext4
mounted at `/mnt/datadisk`); then create the tracker, the 80 GiB full-backup destination PVC and the
control full backup.
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
**What you must see** (wait for the full to terminate; recorded `Done=True` 04:28:20Z):
```bash
oc get vmbackup vm-backup-20261016-exp06-r02 -n vm-cbt-demo -o json \
  | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes}'
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo -o json \
  | jq '.status.volumeStatus[] | select(.hotplugVolume) | {name, hotplugVolume}'
```
`status.type` is `Full`; a condition of type `Done` has `status: "True"`; `status.includedVolumes`
names both disks. The second read prints **nothing** — the control full's destination volume is
detached, which is the healthy contrast this ticket's defect violates.

**Step 2 — Locate the virt-launcher pod (the pod running the VM's QEMU) and the libvirt domain.** Run after
the control full terminates and before the injection; note the pod name, you need it in steps 3–5.
```bash
oc get pod -n vm-cbt-demo -l vm.kubevirt.io/name=vm-20261016-exp06-r02 -o jsonpath='{.items[0].metadata.name}'
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- virsh list --name
```
The first command's `metadata.name` is the launcher pod (`virt-launcher-vm-20261016-exp06-r02-ljm2w`
in the recorded run *before* the injection; `…-rwzzr` after it — substitute whichever name your
cluster prints everywhere below). The second prints the libvirt domain
`vm-cbt-demo_vm-20261016-exp06-r02` as running.

**Step 3 — PRE-check, fail closed — the bitmap is really there before you remove it.** Run immediately after
step 2, still before anything is injected; if this check does not pass, STOP and do not carry on.
```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- \
  virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}' \
  | jq -r '.return[] | select(.node_name=="libvirt-2-format" or .node_name=="libvirt-2-storage" or .node_name=="libvirt-4-format")
           | {node:.node_name, bitmaps:(."dirty-bitmaps" // [])}'
```
Node `libvirt-2-format` (the datadisk overlay `datadisk.qcow2`) must list a `dirty-bitmaps` entry
whose `name` is the checkpoint `vm-backup-20261016-exp06-r02-2026-10-16_04-27-24` with
`recording: true`; node `libvirt-4-format` (rootdisk) must list the same-named entry with
`recording: true` (checkpoints are per-disk, so the same checkpoint name appears once per disk node);
node `libvirt-2-storage`'s `dirty-bitmaps` must be empty. This read is the **non-injector witness**
for the pre-removal state that this run's own pack lacked — `checkers/injection-validity.json` was a
REJECT, with `observer/effect/pre-bitmap-history.jsonl` holding 0 rows with `target_present=true`.

**Step 4 — Injection window — remove the datadisk's checkpoint bitmap, and only that one.** The window opens
when the control full's `Done` condition flips to `status: "True"` (recorded 04:28:20Z) and closes
when the next backup object is created (recorded 04:29:26Z). Run this inside the window; recorded
execution 04:28:21.690Z, with the QMP reply `{"return":{}}`.
```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- \
  virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 \
  '{"execute":"block-dirty-bitmap-remove","arguments":{"node":"libvirt-2-format","name":"vm-backup-20261016-exp06-r02-2026-10-16_04-27-24"}}'
```
The reply must carry only the `return` key (an empty object = accepted); an `error` key instead means
the bitmap was not there and the injection did not take. `node` is the datadisk's format node, so
only the datadisk bitmap goes. Note: `query-block-dirty-bitmap` does not exist on this QEMU — always
list bitmaps with `query-named-block-nodes` and read each node's `dirty-bitmaps`.

**Step 5 — POST-check, fail closed — the removal took, and only on the datadisk.** Run a few seconds after
step 4, still before the VMI restart; if it does not pass, STOP.
```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- \
  virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}' \
  | jq -r '.return[] | select(.node_name=="libvirt-2-format" or .node_name=="libvirt-2-storage" or .node_name=="libvirt-4-format")
           | {node:.node_name, bitmaps:(."dirty-bitmaps" // [])}'
```
`libvirt-2-format`'s `dirty-bitmaps` must now be **empty** while `libvirt-4-format` still lists the
checkpoint `name` with `recording: true` (that asymmetry is exactly what QEMU later reports as
missing only "for disk 'vdb'"). If the datadisk node still lists it, the failure you would then
observe is not this scenario.

**Step 6 — Fire the checkpoint redefinition (delete the VMI).** Run immediately after step 5 passes — recorded
request 04:28:22Z. This makes the replacement VMI re-create the checkpoint, against a bitmap that is
already gone.
```bash
oc delete vmi vm-20261016-exp06-r02 -n vm-cbt-demo
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.metadata.uid} {.status.phase}'
oc get pod -n vm-cbt-demo -l vm.kubevirt.io/name=vm-20261016-exp06-r02 -o jsonpath='{.items[0].metadata.name}'
```
`metadata.uid` is a **new** value (recorded `968b6e7e-c021-46e4-a731-ca0dbec6121f` before →
`9651acfc-1e0d-4c4e-ad94-581e2c4cdf11` after), `status.phase` reaches `Running`, and the pod
`metadata.name` changes (`…-ljm2w` → `…-rwzzr`). The redefinition is logged as "successful" at
04:28:45.625161Z (`trigger/controller-redefinition-window.log:87`) even though the datadisk bitmap is
missing — the metadata state the P5 ticket covers. Use the new launcher pod name from here on.

**Step 7 — Create the pass that wedges.** Run once the replacement VMI is `Running` (recorded 04:28:45Z) and
before the pass bound. The tracker is unchanged; only the destination PVC and the backup CR are new
(recorded pass `…-p01` created 04:29:26Z).
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
**What you must see** (the re-applied tracker is unchanged; the 30 GiB destination size is the
recorded incremental size in the Environment table):
```bash
oc get vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo -o json \
  | jq '{type:.status.type,conditions:.status.conditions,finalizers:.metadata.finalizers}'
```
`status.type` is `Incremental`; `status.conditions` carries the creation-time reason `backup target
PVC vm-incremental-pvc-20261016-exp06-r02-p01 is being attached to VMI vm-20261016-exp06-r02` (the
destination volume is being hotplugged) and **no** terminal condition; `metadata.finalizers` holds
`backup.kubevirt.io/vmbackup-protection`.

**Step 8 — Read-only demonstration of this ticket's defect — the mount stays for the whole stall.** Run the
first read straight after step 7 (so you see the mount appear), then repeat after the pass bound.
**Do not declare the pass wedged before the harness's 20-minute pass bound has elapsed** — a healthy
incremental here completes in seconds, and the harness gave up at 04:49:27Z after 20m35s.
```bash
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo -o json \
  | jq '.status.volumeStatus[] | select(.hotplugVolume) | {name, hotplugVolume}'
oc get vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo -o json \
  | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes,finalizers:.metadata.finalizers}'
oc get pvc vm-incremental-pvc-20261016-exp06-r02-p01 -n vm-cbt-demo -o jsonpath='{.status.phase}'
oc get events -n vm-cbt-demo --field-selector involvedObject.name=vm-20261016-exp06-r02 | grep -i -e unmount -e detach
```
One hotplug entry is present: `hotplugVolume.phase` is `MountedToPod` and
`hotplugVolume.attachPodName` is an `hp-volume-*` pod (recorded for `…-p01`: entry `name`
`vm-incremental-20261016-exp06-r02-p01-backup-target-pvc`, `phase` `MountedToPod`, `attachPodName`
`hp-volume-gkq77`, read at 05:34Z ≈ 65 minutes after creation, with the destination directory
byte-empty, `du 0`, throughout — `recovery/recovery-report.json`). On the CR, the same non-terminal
`status.conditions` and the `metadata.finalizers` entry as in step 7; on the destination PVC,
`status.phase` is `Bound`; and the event read prints **no** event whose text mentions unmount or
detach. The leak recurred on every later pass: `…-p02` had its own `hp-volume-ngsjk` mount with no
unmount event (`f3-events-ns.json`), and `…-p03` likewise.

**Step 9 — The contrast that names the defect — it clears only on CR deletion, in 2–3 s, with no timeout.**
Run only after step 8's post-bound read, on the wedged pass you are holding (the recorded run did
this once per pass; the command below uses the recorded `…-p03`, released in 2 s).
```bash
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo -o json \
  | jq '.status.volumeStatus[] | select(.hotplugVolume) | {name, hotplugVolume}'
date -u +%H:%M:%SZ
oc delete vmbackup vm-incremental-20261016-exp06-r02-p03 -n vm-cbt-demo
date -u +%H:%M:%SZ
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo -o json \
  | jq '.status.volumeStatus[] | select(.hotplugVolume) | {name, hotplugVolume}'
oc get pvc vm-incremental-pvc-20261016-exp06-r02-p03 -n vm-cbt-demo -o jsonpath='{.status.phase}'
```
Before the `oc delete`, that pass's `hotplugVolume.phase`/`hotplugVolume.attachPodName`; after it,
that entry's `name` is **absent** from the listing (nothing takes its place) while the destination
PVC's `status.phase` is still `Bound` — the two `date` stamps bound the release. Recorded wall-clock
releases: `…-p01` 3 s (`followup/20261016-exp06-r02-same-vm/f2-delete-wedged.out`, listing afterwards
`[]`), `…-p02` 3 s (`…-leg1-tracker-repair/l2-delete.out`), `…-p03` 2 s
(`…-leg2-chain-discard/l2-delete.out`). Nothing in three stalls of 20–65 minutes released a mount
without this deletion. Substitute your own wedged CR/PVC names if they differ.

**Step 10 — Recovery — the tracker-repair route does not work, the chain discard does.** Run after you have
taken the leak evidence. Leg 1 repaired the tracker and did **not** unblock (kept here as the
negative control); leg 2 discarded the chain and then took a fresh full.
```bash
# leg 1 (recorded 06:35Z–06:56Z) — repair does NOT unblock
oc patch vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo --subresource=status --type=merge \
   -p '{"status":{"latestCheckpoint":{"volumes":[{"diskTarget":"vda","volumeName":"rootdisk"}]}}}'
# leg 2 (recorded 07:00Z–07:01Z) — discard the chain, then re-create the tracker and take a fresh full
oc delete vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo
```
Then re-apply the step 1 trio with the post-recovery full's names — tracker
`vm-tracker-20261016-exp06-r02`, 80 GiB PVC `vm-followup-full-pvc-20261016-exp06-r02-f02`, backup
`vm-followup-full-20261016-exp06-r02-f02` with `pvcName` = that PVC — and check:
```bash
oc get vmbackup vm-followup-full-20261016-exp06-r02-f02 -n vm-cbt-demo -o json \
   | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes}'
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo -o json \
   | jq '.status.volumeStatus[] | select(.hotplugVolume) | {name, hotplugVolume}'
```
`status.type` is `Full`, the `Done` condition has `status: "True"` (recorded 07:00:53Z),
`status.includedVolumes` names both disks, and the hotplug listing is **empty** — no mounts left.
**Does not restore**: the wedged passes (they are gone) nor the incremental chain (a fresh full is
needed — P1 leg 2). The kept destination PVCs `vm-incremental-pvc-20261016-exp06-r02-p01`/`-p02`/`-p03`
stay `Bound` and must be reclaimed deliberately.

**Step 11 — Optional accelerators (never required).** The scenario's own scripts under
`cbt-chaos/scenarios_v2/CBT-EXP-06/`: `chaos-trigger.sh` (the injection of steps 4–6),
`same-vm-followup.sh` (pass 2 and the F2 release timing), `leg1-tracker-repair.sh` (the negative
control) and `leg2-chain-discard.sh` (the working recovery).

## Current behaviour (observed)

Observed on `20261016-exp06-r02` and its follow-ups (all times UTC, from the named artifacts):

- **`…-p01`'s destination volume stayed mounted for the whole wedge.**
  `followup/20261016-exp06-r02-same-vm/hotplug-before.json` (05:34Z):
  `[{"name":"vm-incremental-20261016-exp06-r02-p01-backup-target-pvc","phase":"MountedToPod","attachPod":"hp-volume-gkq77"}]`
  — i.e. still attached ~65 minutes after the pass was created at 04:29:26Z. The destination directory
  was byte-empty (`du 0`) while mounted, recorded in
  `runs/20261016-exp06-r02/recovery/recovery-report.json`. *Independent artifact observation.*
- **Every later wedged pass leaked its own attachment.** `…-p02` (created 05:35:13Z) had its own
  hotplug pod `hp-volume-ngsjk` with the volume `MountedToPod` at 05:35:13–16Z and **no** unmount
  event afterwards (`followup/20261016-exp06-r02-same-vm/f3-events-ns.json`, and the F3 row in
  `followup/20261016-exp06-r02-same-vm/FINDINGS.md`). `…-p03` (created 06:36:00Z) likewise attached
  its destination PVC and stayed wedged
  (`followup/20261016-exp06-r02-leg1-tracker-repair/leg1.log` L4/L5, `l5-new-backup.json`,
  `RESULT.md`).
- **Release happens only on manual CR deletion, and is fast.** Deleting only the wedged CR released
  the finalizer and the mount in **3 s** for `…-p01`
  (`followup/20261016-exp06-r02-same-vm/f2-delete-wedged.out`), with
  `followup/20261016-exp06-r02-same-vm/hotplug-after-unblock.json` = `[]` and the PVC still `Bound`
  (`followup/20261016-exp06-r02-same-vm/wedged-pvc-after.json#status.phase: Bound`,
  `#metadata.creationTimestamp: 2026-10-16T04:29:26Z`, no terminal outcome); **3 s** for `…-p02`
  (`followup/20261016-exp06-r02-leg1-tracker-repair/l2-delete.out`); **2 s** for `…-p03`
  (`followup/20261016-exp06-r02-leg2-chain-discard/l2-delete.out`). After leg 2's successful full, no
  hotplug mounts were left (`followup/20261016-exp06-r02-leg2-chain-discard/RESULT.md`).
  *Independent artifact observation of the timings; the "bound to deletion, not to a timeout"
  reading is **inference** (see Status / confidence).*

## Expected behaviour (contract)

- A backup that cannot make progress must release its hotplugged destination volume by a mechanism
  that does **not** require an operator to delete the failed CR: on terminal-failure classification,
  on a bounded stall timeout, or via a cleanup reconciliation driven by the backup object's own state.
- Pending that, the stall must be visible as a cleanup condition, so a monitor can detect "an attached
  destination volume with a non-progressing backup" without inspecting the VMI.
- Regression: a successful full and a successful incremental still release their destination volumes.

**Acceptance check (what a reviewer runs).** After the repro, the destination volume's hotplug mount
is gone within a bounded, documented window **without** deleting the backup CR, and the destination
PVC's state is explicit (`Bound` with no writer, or reaped per the documented policy). Regression: a
normal successful backup still detaches as today.

## Impact, workaround and data safety

- **Functions lost / resources leaked**: an `ReadWriteOnce` destination volume stays attached to the
  VM's node for the whole stall, and the VMI carries a stale hotplug attachment entry. Three such
  attachments accumulated across the wedged passes in this run (`hp-volume-gkq77`,
  `hp-volume-ngsjk`, and `…-p03`'s) until each CR was deleted.
- **Operator impact**: the leaked mount is itself the visible symptom that a pass is stuck — but only
  if someone inspects the VMI; it is not reported on the backup CR (P4). Combined with P1's
  "in progress" status and P6's optimistic VMI status, nothing on the backup object says anything is
  wrong.
- **Blast radius**: one VM plus the node hosting it. Because the volume is `ReadWriteOnce`, it cannot
  be used elsewhere while leaked; each wedge also consumes a hotplug slot on that VMI.
- **Data safety**: **not** at risk — the destination volume is empty (the copy never progressed), and
  the source disks are untouched; QEMU refused the inconsistent pass rather than writing anything.
- **Workaround / operator runbook (live-verified)**: delete the wedged CR (**CR only**) — the mount
  detaches in 2–3 s; keep the destination PVC if it is evidence. The PVC stays `Bound` and must be
  reclaimed deliberately. Cost: manual intervention; it does not release anything until an operator
  acts, and it does not fix the retry loop.
- **Frequency**: deterministic — it will be hit whenever a backup becomes permanently non-terminal
  (including the deleted-tracker path), not only under fault injection.
- **Unknowns / what this ticket does not claim**: it does not claim which component owns the detach,
  nor that the same leak occurs on other non-terminal backup paths (the second entry path was not
  re-tested for the leak).

## Evidence

**Artifact index** (repository-relative; run root
`cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02/`, follow-ups under
`cbt-chaos/scenarios_v2/CBT-EXP-06/followup/`). "raw" = captured command output; "summary" = derived.

- `followup/20261016-exp06-r02-same-vm/hotplug-before.json` (raw; 05:34Z, `MountedToPod`,
  `hp-volume-gkq77`), `…/hotplug-after-unblock.json` (raw; `[]` after CR deletion),
  `…/f2-delete-wedged.out` (raw), `…/wedged-pvc-after.json` (raw; PVC still `Bound`).
- `followup/20261016-exp06-r02-same-vm/f3-events-ns.json` (raw) + `FINDINGS.md` (summary; F3 row) —
  `…-p02`'s own `hp-volume-ngsjk` mount with no unmount event.
- `followup/20261016-exp06-r02-leg1-tracker-repair/{leg1.log,l5-new-backup.json,l2-delete.out,RESULT.md}`
  (raw + summary) and `followup/20261016-exp06-r02-leg2-chain-discard/{l2-delete.out,l5-full-backup.json,RESULT.md}`
  (raw + summary) — `…-p03`'s mount and its 2 s release; no mounts left after the successful full.
- `runs/20261016-exp06-r02/recovery/recovery-report.json` (summary) — destination directory byte-empty
  while mounted; run-scoped objects preserved.
- `runs/20261016-exp06-r02/trigger/legB-incremental-backup.yaml` (raw) — the at-creation CR state.
- `runs/20261016-exp06-r02/checkers/injection-validity.json` (summary) and
  `runs/20261016-exp06-r02/observer/effect/pre-bitmap-history.jsonl` (raw) — the pre-removal witness
  caveat for the *cause* of the stall (the leak itself does not depend on it).

- Also present in the pack (recorded; not load-bearing for any claim above): `trigger/action-request.json`, `trigger/exit-statuses.json`, `observer/ARMED`, `observer/PRESERVED`, `observer/finding.md`, `observer/effect/post-vmbackups.json`, `recovery/step2-verify.log`, `reports/test-run-result.md`, `reports/test-run-report.md`, `checkers/report-fidelity.json`.

**UTC timeline** (setup → precondition → injection → effect → failure → recovery; source per entry):

1. 04:27:24Z → 04:28:20Z — control full backup created and reaches `Done=True`; its destination volume
   detaches normally (`runs/20261016-exp06-r02/observer/effect/facts-digest.json#vmbackup_state_first_recv_utc`,
   `trigger/legA-full-backup.yaml`). **Injection window opens.**
2. 04:28:21.690Z — per-disk bitmap removed (`trigger/qmp-remove-result.txt`); VMI restarted; redefinition
   "successful" at 04:28:45.625161Z (`trigger/controller-redefinition-window.log:87`).
3. **04:29:26Z** — affected pass `…-p01` created (`trigger/legB-incremental-backup.yaml`).
   **Injection window closes.** Its destination volume is hotplugged (attach pod `hp-volume-gkq77`).
4. 04:29:29Z–04:57:02Z — the retry storm; the pass never becomes terminal
   (`runs/20261016-exp06-r02/observer/watches/events.jsonl`).
5. **05:34Z** — destination volume still `MountedToPod` ~65 min after creation, destination directory
   byte-empty (`followup/20261016-exp06-r02-same-vm/hotplug-before.json`,
   `runs/20261016-exp06-r02/recovery/recovery-report.json`).
6. 05:35Z — CR deleted, mount released in **3 s**, PVC stays `Bound`
   (`followup/20261016-exp06-r02-same-vm/f2-delete-wedged.out`, `hotplug-after-unblock.json`,
   `wedged-pvc-after.json`).
7. 05:35:13Z–16Z — a new pass `…-p02` attaches its **own** destination volume (`hp-volume-ngsjk`) and
   leaks it too; no unmount event follows (`followup/20261016-exp06-r02-same-vm/f3-events-ns.json`).
8. 06:35Z–06:56Z — leg 1: `…-p02` deleted → 3 s release (`…-leg1-tracker-repair/l2-delete.out`); the
   next pass `…-p03` (06:36:00Z) attaches and leaks its own volume.
9. 07:00Z–07:01Z — leg 2: `…-p03` deleted → 2 s release (`…-leg2-chain-discard/l2-delete.out`); the
   subsequent full backup completes with **no** hotplug mounts left
   (`…-leg2-chain-discard/l5-full-backup.json`, `RESULT.md`) — recovery.

**Retained state.** The run is closed and frozen; nothing under the run root was modified post-close.
The three wedged CRs were deleted during the post-close follow-ups (each deletion being the documented
unblock under test), and their destination PVCs were deliberately retained
(`followup/20261016-exp06-r02-same-vm/wedged-pvc-after.json#status.phase: Bound`). The wedged test's
own 3 Gi PVC from the same-VM follow-up's F1 attempt was removed because its CR never existed
(`followup/20261016-exp06-r02-same-vm/f1-delete-cr.out`). The pre-wedge tracker object no longer
exists (deleted in leg 2). Whether the scenario VM itself was finally deleted is `not recorded`.

## Negative results and what would falsify this ticket

- **Refuted: "the detach machinery is broken".** Every release that was triggered succeeded, in 2–3 s,
  with the PVC left intact and `Bound`; the *trigger* is the defect, not the cleanup path. This also
  distinguishes it from the different, prior defect
  `cbt-chaos/scenarios_v2/CBT-F-05/bugs/bug-backup-volume-attachment-leak.md`, which is a different
  failure mode in the same subsystem.
- **Refuted: "the volume is detached once the retry loop quietens".** No unmount event appears in
  `followup/20261016-exp06-r02-same-vm/f3-events-ns.json` after the mount, and the 65-minute stall had
  no release until deletion.
- **Refuted: "the destination directory holds partial backup data".** It was byte-empty (`du 0`) while
  mounted (`recovery/recovery-report.json`), so this leak does not endanger data.
- **Evidence caveat (must not be dropped)**: the stall's *cause* rests partly on the injector-only
  pre-removal bitmap witness (`checkers/injection-validity.json` REJECT;
  `observer/effect/pre-bitmap-history.jsonl`, 0 rows with `target_present=true`). The leak observation
  is independent: it is a pure VMI/CR state read and is reproduced on a path with no injection (leg 1).
- **Contradictory/limiting evidence**: none found for the leak itself.
- **Falsifier.** This ticket is wrong if a wedged pass's destination volume is shown to detach within a
  bounded window *without* any operator action (then the release is timeout-driven and this is only an
  observability gap), or if the mount is shown to be harmless because the volume is not actually
  `ReadWriteOnce`/node-pinned in the affected configuration.

## Additional feedback (reporter's notes)

- **Open hypotheses and the smallest experiments that would settle them.**
  - *Does the same leak occur on the deleted-tracker entry path (EXP-8)?* Smallest experiment: capture
    `vmi.status.volumeStatus[*].hotplugVolume` while the EXP-8 wedge is live, before any deletion. Not
    attempted here — currently **[INFERENCE]** that it does.
  - *Is a bounded stall timeout present but never reached?* Smallest experiment: hold one wedged pass
    for 24 h on a scratch VM and watch the hotplug list and any unmount event.
- **Triage questions that decide scope.**
  - Should the destination volume be released on terminal-failure classification, on a stall timeout,
    or by an independent cleanup reconciliation keyed on the backup object's state?
  - Is a lingering hotplug attachment while the backup CR exists intentional? If so, the release
    condition needs to be documented and bounded.
- **Environment-specific notes for the next reproducer.**
  - The mount is only visible on the VMI: read `vmi.status.volumeStatus[*].hotplugVolume`, and look for
    an attach pod named `hp-volume-*`. There is no ready-made field on the backup CR for it.
  - The destination volume is `ReadWriteOnce` (Environment, ticket-specific row) — plan for the volume
    being unusable elsewhere while leaked.
  - Capacity for extra attempts must be measured on `/var/hpvolumes/csi` (`/dev/sdb`), not on its
    parent `/var/hpvolumes` (`/dev/sda4`); a full backup destination is fully allocated (~80 GiB).
  - Deleting the wedged CR manually is currently the only way to release the mount, so any "leave it
    alone" observation is a race with your own harness cleanup — record who deleted what and when.
- **Cross-references.** Siblings in this folder: `backup-cr-livelock-on-missing-per-disk-bitmap.md`
  (**P1**, the root cause; its operator runbook documents the detached-on-delete behaviour),
  `vm-wide-backup-capability-deadlock.md` (**P2**, the availability consequence while the mount is
  leaked), `backup-cr-event-stream-empty-on-wedge.md` (**P4**, why the leaked mount is the only
  unilateral symptom), `checkpoint-redefinition-accepts-incomplete-checkpoint.md` (**P5**, the metadata
  state preceding the wedge), `vmi-backupstatus-advertises-nonexistent-checkpoint.md` (**P6**, the
  status surface that contradicts the real chain coverage), and `20261016-exp06-r02-product-findings.md`
  (the consolidated working analysis; not filed itself). Findings registry:
  `docs/findings/finding-1-backup-cr-livelock.md` (prior-run characterization of the same wedge). Prior
  related defect in the same subsystem with a different failure mode:
  `cbt-chaos/scenarios_v2/CBT-F-05/bugs/bug-backup-volume-attachment-leak.md`. **Separately and
  clearly labelled: harness/tooling gaps are not in this ticket** — see
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
commands in Steps (`oc delete vmi`, the QMP `block-dirty-bitmap-remove`, `oc delete vmbackup`) are
this ticket's own scoped repro/workaround steps on a dedicated cluster, and no cluster-cleanup command
is included; the commands are re-creations of the recorded shapes and are labelled as such.

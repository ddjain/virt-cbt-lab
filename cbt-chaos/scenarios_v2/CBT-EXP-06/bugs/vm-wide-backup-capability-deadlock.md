# [Bug]: A non-terminal backup on a VM rejects every other backup on that VM ("in progress for source"), deadlocking the VM's whole backup capability

## What this is, in one paragraph

A KubeVirt CBT (changed-block tracking) backup copies a running VM's disks into a destination volume
that is hot-plugged into that VM. The backup API allows only **one backup per source VM at a time** —
one per *source*, VM-wide, covering every disk, not per disk; a second request is refused with
`in progress for source`. When one pass never reaches a terminal state (a *wedged* backup, whose
`VirtualMachineBackup` CR stays `Initializing=True` / `Progressing=False` indefinitely), that
one-backup-per-source guard never clears: every later backup for the same VM is refused at admission
with `in progress for source` and its CR is never created. The VM is then completely un-backupable —
full and incremental, for every disk — until an operator deletes the stuck CR by hand.

**When → then → expected**

- **When** an engineer creates any second `VirtualMachineBackup` (full or incremental, any destination PVC) for a VM that already has one non-terminal, wedged backup CR.
- **And** the disruption **CBT-EXP-06 — per-disk checkpoint-bitmap removal** (`chaos-trigger.sh`; **not a krknctl scenario** — krkn's 38 tags include no primitive that can touch a guest QEMU dirty bitmap) is applied: the datadisk (`vdb`) checkpoint bitmap (the per-disk change-tracking map inside the running VM's QEMU) is removed over QMP and the VMI is deleted so virt-controller redefines the checkpoint.
- **Then (current behaviour):** the second backup is rejected at admission — `The request is invalid: spec.source: VirtualMachineBackup "vm-incremental-20261016-exp06-r02-p01" in progress for source`, apply exit 1 — and its CR is never created (`vm-followup-20261016-exp06-r02-f01` never existed), while the blocking pass stays non-terminal ~65 minutes after creation.
- **Expected behaviour:** the one-backup-per-source guard must not outlive a known-failed or demonstrably non-progressing pass — the second creation either succeeds once the first pass is terminal, or is rejected with a condition that identifies the blocking pass as failed/stalled and points to a bounded, documented release instead of the generic `in progress for source`.

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
| Issue type | **Bug** — the established contract is that a *terminal* pass frees the one-backup-per-source guard. The guard instead outlives a pass that is permanently unable to progress, so the demonstrated behaviour (a VM with zero creatable backups for ~65 minutes) violates it. |
| Priority (proposed) | **High** — availability. One non-terminal pass disables **all** backups on that VM until an operator deletes the CR by hand. Per-VM, not cluster-wide, but the affected VM has no backup coverage at all. Unassigned pending triage. |
| Severity class | availability |
| Owning component (suspected) | **suspected** CNV/KubeVirt backup stack: the `VirtualMachineBackup` admission/validation path that enforces one-backup-per-source (the guard is reached at `spec.source` validation; the exact function/file is **unproven** — no source anchor was read for this run). |
| Component(s) proven involved | the backup admission/validation path (it authored the verbatim rejection with exit 1) together with the `VirtualMachineBackup` liveness path (the blocking CR is proven non-terminal, so nothing ever releases the guard). Which of the two should be changed is the triage question. |
| Reproducibility | `deterministic` — 2/2 independent fault entry paths: 1/1 on the corrupt-checkpoint path (r02 follow-up F1, 2026-10-16 ~05:34Z) and 1/1 on the deleted-tracker path (EXP-8, 2026-10-14). |
| Status / confidence | **Confirmed behaviour, high confidence.** Certain: the verbatim rejection, the apply exit code, and the blocking CR's non-terminal state at that moment. **Inference**: the causal link that the rejection happened *because* the guard outlived a permanently-failing pass (from those artifacts plus P1's finding that no terminal resolution exists). |
| Blast radius | one VM — **every** backup for it, for all disks, including incrementals for disks that are individually healthy. Other VMs are unaffected. |
| Data at risk? | **No** — the VM is simply not backed up while the guard is held; no corruption or silent data loss. The impact is loss of coverage plus an operator intervention. |
| Related scenario / execution | `CBT-EXP-06` / `20261016-exp06-r02` (2026-10-16, closed `BLOCKED`) + post-close same-VM follow-up `20261016-exp06-r02-same-vm` (F1, 05:34Z) + post-close leg 1 `20261016-exp06-r02-leg1-tracker-repair` (06:35Z–06:56Z) + leg 2 `20261016-exp06-r02-leg2-chain-discard` (07:00Z–07:01Z); `CBT-EXP-08` / `20261014-exp08-r01` (2026-10-14, deleted-tracker path, cited via `docs/findings/finding-1-backup-cr-livelock.md`). |
| Affected versions | short pointer — OpenShift 4.22.15, CNV `kubevirt-hyperconverged-operator.v4.22.12`, `backup.kubevirt.io/v1alpha1`, hostpath CSI pool `cbt-demo-hpp`. The full measured matrix is in **Environment** below. |

## Context (for an engineer new to this area)

- **What the feature does** — KubeVirt CBT push-mode backups. Each `VirtualMachineBackup` names a
  *source* (a `VirtualMachine`) and copies into a *destination* volume hot-plugged into the running
  VM. Because a second concurrent pass would interleave two copies of the same disk chain, the API
  enforces **one backup per source at a time**: creating a second backup while one is in progress is
  rejected at admission/validation.
- **Where the failure sits** — on the *second* backup's creation request: admission returns
  `spec.source: VirtualMachineBackup "<first>" in progress for source`, and the second CR is never
  created. The object an operator would consult is the first (blocking) backup CR and its
  `status.conditions`.
- **Observed surface vs. origin** — the rejection message names the blocking pass by name, but the
  *reason* the guard never clears is on a different object: the blocking pass is permanently
  non-terminal (the P1 wedge). The API surface a user hits (admission error) and the site that causes
  it (no terminal resolution for a permanent start failure) are different objects — that mismatch is
  the defect.
- **Why it matters** — the guard is only safe if a non-terminal pass is *guaranteed* to become
  terminal. Here it never does, so the guard never clears and the VM loses its entire backup
  capability: no full, no incremental, for any disk, until a human deletes the wedged CR. There is no
  API-only, evidence-preserving way out: the documented harness unblock (`scripts/vm-cbt-reconcile.sh`)
  refuses unless the operator has already deleted the failed CR **and** its PVC (errata item 2 of
  `cbt-chaos/scenarios_v2/CBT-EXP-06/analysis/20261016-exp06-r02-errata.md`).

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

- **Classification**: deterministic, on two independent fault entry paths (2/2).
- **Attempts**: 1/1 on the corrupt-checkpoint path (r02 post-close follow-up, F1 at ~05:34Z,
  2026-10-16) and 1/1 on the deleted-tracker path (`20261014-exp08-r01` per finding-1 §4, 2026-10-14).
  The same behaviour is corroborated twice more by construction: in leg 1 a new pass could only be
  created after the previously wedged CR was deleted, and in leg 2 the same was true again.
- **Stability** — exact every time: the rejection text (`… in progress for source`), the apply exit
  code 1, and the blocking CR's non-terminal state. Varying: only which pass is named as the blocker
  (it is whichever wedged CR exists).
- **Preconditions**: at least one non-terminal `VirtualMachineBackup` for the VM must exist (here: the
  P1 wedge). What breaks the repro: a VM with no in-flight pass — then the second backup is accepted
  normally.
- **Second entry path**: the deleted-tracker wedge (`20261014-exp08-r01`) produces the identical
  rejection, so this is a property of the guard-plus-no-terminal-resolution pair, not of one
  injection. A defect reachable two ways is not an artefact of a single test.
- **Attribution caveat**: the run's injection checker REJECTed on a missing non-injector pre-removal
  bitmap witness (`checkers/injection-validity.json`). The deadlock observation does **not** depend on
  the removal: it is reproduced on a path with no injection (leg 1) and on a different fault entry
  path (EXP-8).

## Steps to reproduce (exact commands and injection timing)

The object names below are the recorded names of run `20261016-exp06-r02` (namespace `vm-cbt-demo`),
verbatim from that run's artifacts. Run this on a dedicated cluster with OpenShift Virtualization and
the CBT backup API enabled, and never reuse another run's names: on your own fresh cluster, create
equivalents with your own run-scoped names and substitute them everywhere they appear — that is the
only substitution this ticket expects. Namespace, container, libvirt domain and QMP payload are
literal below, so each block is runnable as written once the run-scoped objects exist; the commands
are re-creations of the recorded shapes.

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

**Which leg deleted which CR, and which PVCs were kept.** All objects are in namespace `vm-cbt-demo`.
The wedged CRs were deleted by the follow-up legs: `vm-incremental-20261016-exp06-r02-p01` in follow-up
F2 (the same-VM follow-up; finalizer released in 3 s), `vm-incremental-20261016-exp06-r02-p02` in leg 1
(`20261016-exp06-r02-leg1-tracker-repair`, 3 s) and `vm-incremental-20261016-exp06-r02-p03` in leg 2
(`20261016-exp06-r02-leg2-chain-discard`, 2 s) — deleting the wedged CR is what releases the
one-backup-per-source guard. The three incremental destination PVCs
(`vm-incremental-pvc-20261016-exp06-r02-p01/p02/p03`) were all **kept** (`Bound`), as was the
post-recovery full destination `vm-followup-full-pvc-20261016-exp06-r02-f02` (80 GiB). The only PVCs
deleted were the control full's 80 GiB `vm-backup-pvc-20261016-exp06-r02` (on operator approval, to
reclaim pool space) and the rejected follow-up's 3 GiB `vm-followup-pvc-20261016-exp06-r02-f01`
(removed because its CR never existed).

**Step 1 — Create the VM, the tracker and the control full backup.** The VM is the 2-disk CBT-enabled RHEL 9
VM in the table above (`rootdisk`=`vda` 80 GiB, `datadisk`=`vdb` 2 GiB, runStrategy Always). Run
this first, before anything else; the trio below is the validated schema (tracker `spec.source` is
the `VirtualMachine`, backup `spec.source` is the tracker plus `pvcName`).
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
Run the next block when the full backup has finished, to confirm the terminal state.
```bash
oc get vmbackup vm-backup-20261016-exp06-r02 -n vm-cbt-demo -o json | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes}'
oc get vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.status.latestCheckpoint.name}'
```
You must see `status.type` `Full`; a `Done` condition with `status: "True"` (r02: 04:28:20Z);
`status.includedVolumes` naming both `rootdisk` and `datadisk`; and the tracker's
`status.latestCheckpoint.name` equal to the checkpoint `vm-backup-20261016-exp06-r02-2026-10-16_04-27-24`
(created 04:27:24Z). This terminal `Done=True` transition is what opens the injection window.

**Step 2 — Locate the launcher pod and the libvirt domain.** Run this after step 1 (any time while the
launcher pod is Running); do it before the checks below so you have the pod name to use.
```bash
oc get pod -n vm-cbt-demo -l vm.kubevirt.io/name=vm-20261016-exp06-r02 -o jsonpath='{.items[0].metadata.name}'
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- virsh list --name
```
You must see exactly one pod name (before the injection in r02:
`virt-launcher-vm-20261016-exp06-r02-ljm2w`, uid `1160f767-7cbb-4352-a5cf-3ee37aac611d`) and, from
`virsh list --name`, the domain `vm-cbt-demo_vm-20261016-exp06-r02` — the domain name is
`<namespace>_<VM name>`. After the VMI deletion in step 6 the launcher pod is
`virt-launcher-vm-20261016-exp06-r02-rwzzr` (uid `6bb8b6c5-e7af-4ee8-84d6-a689c4159ece`); the later
steps use that name.

**Step 3 — PRE-check, fail closed: both disks must advertise the checkpoint bitmap.** Run this inside the
injection window — immediately after step 1's terminal `Done=True` (r02: 04:28:20Z) and before the
removal. A **non-injector witness** must capture the same output: in r02 only the injector
witnessed it, and the run's injection checker REJECTed for that gap
(`checkers/injection-validity.json`).
```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}'
```
You must see, in the JSON reply, that the datadisk's node `libvirt-2-format` (the overlay
`/var/run/kubevirt-private/libvirt/qemu/cbt/datadisk.qcow2`) lists a `dirty-bitmaps` entry whose
`name` is `vm-backup-20261016-exp06-r02-2026-10-16_04-27-24` with `recording` `true`, that the
rootdisk's `libvirt-4-format` lists the same bitmap, and that `libvirt-2-storage` and
`libvirt-4-storage` have an empty `dirty-bitmaps` list. If the datadisk node does not show the
bitmap, fail closed and stop — do not inject. (`query-block-dirty-bitmap` does not exist on this
QEMU; always list bitmaps with `query-named-block-nodes` and read each node's `dirty-bitmaps`.)

**Step 4 — Injection window — remove the datadisk's checkpoint bitmap only.** Run this once, inside the
window **[control full backup `Done=True` 04:28:20Z → next backup object created 04:29:26Z]**,
immediately after the PRE-check passed; the recorded removal ran at **04:28:21.690Z**.
```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"block-dirty-bitmap-remove","arguments":{"node":"libvirt-2-format","name":"vm-backup-20261016-exp06-r02-2026-10-16_04-27-24"}}'
```
You must see the QMP reply `{"return":{}}` — an empty result object and no `error` member (the
recorded reply is `trigger/qmp-remove-result.txt`). This removes the `vdb` bitmap only; the `vda`
bitmap is left in place.

**Step 5 — POST-check, fail closed: the datadisk bitmap is gone, the rootdisk bitmap is not.** Run this
immediately after the removal reply and **before** deleting the VMI.
```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}'
```
You must see `libvirt-2-format`'s `dirty-bitmaps` list now **empty** while `libvirt-4-format` still
lists the checkpoint bitmap with `recording` `true`. If the datadisk list is not empty the injection
did not take — fail closed and stop.

**Step 6 — Fire the checkpoint redefinition by deleting the VMI.** Run this right after the POST-check
passed; virt-controller redefines the checkpoints when the VMI is recreated.
```bash
oc delete vmi vm-20261016-exp06-r02 -n vm-cbt-demo
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.metadata.uid}{"|"}{.status.phase}'
```
You must see the VMI `metadata.uid` change to the replacement VMI (r02: `968b6e7e-c021-46e4-a731-ca0dbec6121f`
→ `9651acfc-1e0d-4c4e-ad94-581e2c4cdf11`) and `status.phase` become `Running` (replacement Running
with CBT `Enabled` at 04:28:45Z; the controller's redefinition window is recorded at
04:28:45.625161Z). Wait for `Running` before continuing — the injection window closes when the next
backup object is created.

**Step 7 — Create the pass that wedges.** Run this once the replacement VMI is `Running` (r02: `…-p01`
created 04:29:26Z — this closes the injection window). It is a new incremental against the same
tracker, with its own new destination PVC.
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
oc get vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo -o json | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes,finalizers:.metadata.finalizers}'
```
You must see the CR exists with uid `46b6f5e1-ced6-4094-8c96-e4d7690c3ea0`; `status.conditions`
containing `Initializing` with `status: "True"` and `Progressing` with `status: "False"`, and no
`Done` condition; and `metadata.finalizers` containing `backup.kubevirt.io/vmbackup-protection`. Its
condition message is the creation-time stamp naming the destination PVC being attached (verbatim in
r02: `backup target PVC vm-incremental-pvc-20261016-exp06-r02-p01 is being attached to VMI vm-20261016-exp06-r02`).
Note: that verbose `Initializing=True` reason is written once at creation — use
`metadata.resourceVersion` movement as the liveness signal, not the reason text.

**Step 8 — Demonstrate THIS ticket's defect (read-only apart from the rejected apply): a second backup on
the same VM is refused and its CR never appears.** Run this while the pass from step 7 is still
non-terminal **and at least 20 minutes after that pass was created** — do not declare it wedged
before the harness's 20-minute pass bound has elapsed (r02: created 04:29:26Z, the harness gave up
at 04:49:27Z after 20m35s, whereas a healthy incremental here completes in seconds; the rejection
itself was recorded at 05:34Z, ~65 min after creation). Run it **before** deleting anything.
```bash
oc apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vm-followup-pvc-20261016-exp06-r02-f01
  namespace: vm-cbt-demo
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: 20261016-exp06-r02
spec:
  storageClassName: cbt-demo-hpp
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 3Gi
---
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-followup-20261016-exp06-r02-f01
  namespace: vm-cbt-demo
  labels:
    app.kubernetes.io/managed-by: virt-cbt-lab
    virt-cbt-lab/run-id: 20261016-exp06-r02
spec:
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261016-exp06-r02
  pvcName: vm-followup-pvc-20261016-exp06-r02-f01
YAML
echo "apply exit: $?"
oc get vmbackup vm-followup-20261016-exp06-r02-f01 -n vm-cbt-demo
oc get vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo -o jsonpath='{.metadata.resourceVersion}{"|"}{.status.conditions}'
oc get vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo -o jsonpath='{.status.type}'
```
You must see (this is the defect): the apply prints
`persistentvolumeclaim/vm-followup-pvc-20261016-exp06-r02-f01 created` and then fails with
`The request is invalid: spec.source: VirtualMachineBackup "vm-incremental-20261016-exp06-r02-p01" in progress for source`,
and `apply exit:` prints **1**; `oc get vmbackup vm-followup-20261016-exp06-r02-f01` returns
`Error from server (NotFound)` — the CR was **never created**, because a validation error creates
nothing, so the apply exit code (not `oc get`) is the evidence; the blocking CR's `status.conditions`
still show `Initializing=True` / `Progressing=False` with `metadata.resourceVersion` unmoved ~65
minutes after creation. Note the guard blocks **every** backup for this VM — full or incremental,
any destination PVC, all disks — not just the follow-up.

**Step 9 — Recover: delete the wedged CR, then discard the chain.** Run this after step 8 has been
observed and recorded; this is the documented operator runbook (the CR deletion is what frees the
guard — nothing else does).
```bash
oc delete vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo
oc get vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo   # NotFound once the finalizer releases
oc delete pvc vm-followup-pvc-20261016-exp06-r02-f01 -n vm-cbt-demo
oc delete vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo   # discard the chain; do NOT repair it
```
You must see the CR's finalizer `backup.kubevirt.io/vmbackup-protection` released within seconds
(recorded 3 s in F2 and leg 1 L2, 2 s in leg 2 L2) and the leaked hotplug mount detach (P3); the
three incremental destination PVCs stay `Bound` and must be reclaimed deliberately.
Now re-apply the step-8 trio (PVC `vm-followup-pvc-20261016-exp06-r02-f01` + backup
`vm-followup-20261016-exp06-r02-f01`, 3 GiB) — it must be **admitted** now that the wedged CR is
gone — then re-create the tracker (validated trio, leg 2) with a fresh destination PVC and run:
```bash
oc get vmbackup vm-followup-full-20261016-exp06-r02-f02 -n vm-cbt-demo -o json | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes}'
oc get vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.status.latestCheckpoint.name}'
```
You must see the post-recovery backup with `status.type` `Full`, a `Done` condition with
`status: "True"` (`Done=True` 07:00:53Z, 18 s) and `status.includedVolumes` naming `rootdisk` and
`datadisk`; and the re-created tracker's `status.latestCheckpoint.name` equal to the new both-disk
checkpoint `vm-followup-full-20261016-exp06-r02-f02-2026-10-16_07-00-35` (07:00:35Z).

**Step 10 — Optional accelerators (never required).** Run these only after reproducing the manual sequence
once, on a dedicated cluster; they script the same actions.
```bash
cbt-chaos/scenarios_v2/CBT-EXP-06/chaos-trigger.sh
cbt-chaos/scenarios_v2/CBT-EXP-06/same-vm-followup.sh
cbt-chaos/scenarios_v2/CBT-EXP-06/leg1-tracker-repair.sh
cbt-chaos/scenarios_v2/CBT-EXP-06/leg2-chain-discard.sh
```
The leg-1 repair patches the tracker so it advertises only the surviving disk's checkpoint — and
does **not** unblock a later pass, while the leg-2 discard (`oc delete vmbackuptracker`, step 9)
does:
```bash
oc patch vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo --subresource=status --type=merge -p '{"status":{"latestCheckpoint":{"volumes":[{"diskTarget":"vda","volumeName":"rootdisk"}]}}}'
```
You must see the same recorded states as the manual steps. Neither legacy path is needed to
reproduce the deadlock, which happens with no injection at all (leg 1) and on a different fault
entry path (EXP-8).

## Current behaviour (observed)

Observed on `20261016-exp06-r02` and its post-close follow-up (all times UTC, from the named
artifacts):

- **The second backup is rejected at admission.** `followup/20261016-exp06-r02-same-vm/f1-apply.out`
  records verbatim:
  ```
  persistentvolumeclaim/vm-followup-pvc-20261016-exp06-r02-f01 created
  The request is invalid: spec.source: VirtualMachineBackup "vm-incremental-20261016-exp06-r02-p01" in progress for source
  ```
  Apply exit **1** (`followup/20261016-exp06-r02-same-vm/FINDINGS.md`, leg F1); the test backup
  **never existed** and its 3 Gi PVC was removed (`followup/20261016-exp06-r02-same-vm/f1-delete-cr.out`).
  *Independent artifact observation.*
- **The blocking pass was demonstrably non-terminal at that moment**:
  `vm-incremental-20261016-exp06-r02-p01` (uid `46b6f5e1-ced6-4094-8c96-e4d7690c3ea0`), created
  04:29:26Z, still `Initializing=True` / `Progressing=False` with the creation-time reason *"backup
  target PVC … is being attached to VMI …"* ~65 minutes later
  (`followup/20261016-exp06-r02-same-vm/wedged-cr-before-delete.yaml`, `hotplug-before.json`).
  *Independent artifact observation.*
- **The guard is the only path forward, so a forward pass requires manual deletion first.** In leg 1
  the new pass `vm-incremental-20261016-exp06-r02-p03` could only be created (06:36:00Z) after the
  previously wedged `…-p02` CR was deleted
  (`followup/20261016-exp06-r02-leg1-tracker-repair/l2-delete.out`, `leg1.log` L2/L4,
  `l5-new-backup.json#metadata.creationTimestamp`). Leg 2 repeated the pattern (07:00Z): delete the
  wedged CR, then the next backup was accepted and completed.
- **Independent second path.** The identical rejection is recorded for the deleted-tracker wedge:
  `spec.source: VirtualMachineBackup "…" in progress for source` while the wedged CR was stuck
  (`docs/findings/finding-1-backup-cr-livelock.md` §4, EXP-8, 2026-10-14).
- **Causal link is inference**: that the rejection happened *because* the guard outlived a
  permanently-failed pass is **inference** from the artifacts above plus P1's finding that no terminal
  resolution exists for this error class.

## Expected behaviour (contract)

- The one-backup-per-source guard must not outlive a pass that is known-failed or demonstrably unable
  to progress: either release it when the in-progress pass is classified non-recoverable, or surface a
  distinguishable, actionable condition (e.g. a `Failed`/`Stalled` pass state) that admission and
  operators can key on — instead of the generic `in progress for source` message.
- Once the first pass is terminal, creating a second backup on the same VM must succeed.
- Regression: a permanent backup-start failure must not leave the VM with zero creatable backups.

**Acceptance check (what a reviewer runs).** With a wedged pass present, a second backup created on
the same VM is either accepted, or rejected with a condition that identifies the blocking pass as
failed/stalled and points to a bounded, documented release (no manual `oc delete` of an
evidence-bearing CR required beyond the documented runbook). After the first pass becomes terminal,
the second creation succeeds.

## Impact, workaround and data safety

- **Functions lost**: every backup operation for that VM — full and incremental, all disks — from the
  moment the first pass wedges until an operator deletes the CR. How an operator notices: only via
  the rejected apply, the VMI-scoped `BackupError` events (P4), or the leaked hotplug mount (P3);
  a CR-scoped monitor sees a pass that is merely "in progress".
- **Blast radius**: one VM (other VMs on the cluster are unaffected). This is the consequence that
  makes the P1 wedge operationally critical rather than merely untidy.
- **Data safety**: **not** at risk — the VM is simply not backed up; no corruption is involved and
  QEMU refuses the inconsistent pass rather than producing a bad backup.
- **Workaround / operator runbook (live-verified)**: delete the wedged CR (**CR only**), then create
  the new backup. The finalizer releases in seconds and the leaked hotplug mount detaches (P3); the
  destination PVC stays `Bound` and must be reclaimed deliberately. In leg 1 this unblocked creation
  of the next pass; in leg 2 the tracker then had to be **discarded** (not repaired) for that pass to
  *complete* (P1). Cost: manual intervention that removes evidence, plus a full re-copy if the chain
  is discarded. Does not fix: the retry loop that keeps the pass non-terminal.
- **Frequency**: deterministic given a wedged pass; in production it fires whenever any pass fails
  permanently at start (including the deleted-tracker path), not only under fault injection.
- **Unknowns / what this ticket does not claim**: it does not claim the guard is wrong in itself, nor
  which component should change; it does not claim any shipped consumer keys on the message.

## Evidence

**Artifact index** (repository-relative; run roots under
`cbt-chaos/scenarios_v2/CBT-EXP-06/`). "raw" = captured command output; "summary" = derived.

- `followup/20261016-exp06-r02-same-vm/f1-apply.out` (raw) — the verbatim rejection, apply exit 1.
- `followup/20261016-exp06-r02-same-vm/FINDINGS.md` (summary; leg F1 row) — "REJECTED at admission …
  The test backup never existed"; also the F0/F3 rows used in the timeline.
- `followup/20261016-exp06-r02-same-vm/wedged-cr-before-delete.{json,yaml}`, `hotplug-before.json`
  (raw) — the blocking pass's non-terminal state and its leaked mount at ~05:34Z.
- `followup/20261016-exp06-r02-same-vm/f1-delete-cr.out` (raw) — removal of the rejected test's 3 Gi PVC.
- `followup/20261016-exp06-r02-leg1-tracker-repair/{l2-delete.out,leg1.log,l4-apply.out,RESULT.md}`
  (raw + summary) — a new pass is creatable only after the wedged CR is removed.
- `followup/20261016-exp06-r02-leg2-chain-discard/{l2-delete.out,l5-full-backup.json,RESULT.md}`
  (raw + summary) — same pattern, and the next pass then completes.
- `runs/20261016-exp06-r02/trigger/legB-incremental-backup.yaml`, `observer/FINAL.json` (raw +
  summary) — the blocking CR's `Initializing=True`/`Progressing=False` state at creation.
- `docs/findings/finding-1-backup-cr-livelock.md` §4 (summary) — the same rejection on the
  deleted-tracker path (EXP-8).
- `cbt-chaos/scenarios_v2/CBT-EXP-06/analysis/20261016-exp06-r02-errata.md` (summary; errata item 2) —
  the detailed refusal behaviour of `scripts/vm-cbt-reconcile.sh` quoted in Context.
- `runs/20261016-exp06-r02/checkers/injection-validity.json`,
  `runs/20261016-exp06-r02/observer/effect/pre-bitmap-history.jsonl` (summary + raw) — the
  pre-removal witness caveat (belt-and-braces: this defect does not depend on the removal).

- Also present in the pack (recorded; not load-bearing for any claim above): `trigger/action-request.json`, `trigger/exit-statuses.json`, `observer/ARMED`, `observer/PRESERVED`, `observer/finding.md`, `observer/effect/post-vmbackups.json`, `recovery/step2-verify.log`, `reports/test-run-result.md`, `reports/test-run-report.md`, `checkers/report-fidelity.json`.

**UTC timeline** (setup → precondition → injection → effect → failure → recovery; source per entry):

1. 04:27:24Z → 04:28:20Z — control full backup created and reaches `Done=True`
   (`runs/20261016-exp06-r02/observer/effect/facts-digest.json#vmbackup_state_first_recv_utc`).
   **Injection window opens.**
2. 04:28:21.690Z — per-disk bitmap removed (reply `{"return":{}}`;
   `runs/20261016-exp06-r02/trigger/qmp-remove-result.txt`); VMI restarted → redefinition at
   04:28:45.625161Z (`runs/20261016-exp06-r02/trigger/controller-redefinition-window.log:87`).
3. **04:29:26Z** — the blocking pass `…-p01` is created and is immediately non-terminal
   (`runs/20261016-exp06-r02/trigger/legB-incremental-backup.yaml`). **Injection window closes.**
4. 04:29:29Z–04:57:02Z — the wedge's retry storm (21 VMI-scoped `BackupError` rows;
   `runs/20261016-exp06-r02/observer/watches/events.jsonl`).
5. 04:49:27Z — the harness gives up after 20m35s and marks the pass failed
   (`runs/20261016-exp06-r02/trigger/trigger.log`); the product object records nothing.
6. **05:34Z** — second backup for the same VM rejected at admission, apply exit 1
   (`followup/20261016-exp06-r02-same-vm/f1-apply.out`); blocking CR still non-terminal ~65 min after
   creation (`followup/20261016-exp06-r02-same-vm/wedged-cr-before-delete.yaml`).
7. 05:35Z — wedged CR deleted (F2); 05:35:13Z — a fresh pass `…-p02` is created and accepted, then
   wedges identically (`followup/20261016-exp06-r02-same-vm/f2-delete-wedged.out`, `f3-new-backup.json`).
8. 06:35Z–06:56Z — leg 1: `…-p02` deleted (`l2-delete.out`), then `…-p03` created 06:36:00Z
   (`followup/20261016-exp06-r02-leg1-tracker-repair/l4-apply.out`) — creation only after deletion.
9. 07:00Z–07:01Z — leg 2: `…-p03` deleted, tracker discarded, fresh tracker + new destination PVC, and
   the next backup completes `type=Full`, `Done=True` in 18 s
   (`followup/20261016-exp06-r02-leg2-chain-discard/l5-full-backup.json`) — recovery.
10. 2026-10-14 (prior run) — the same rejection on the deleted-tracker path
    (`docs/findings/finding-1-backup-cr-livelock.md` §4, `20261014-exp08-r01`).

**Retained state.** The run is closed and frozen; nothing under the run root was modified post-close.
The blocking CR `…-p01` was deleted during the follow-up (that deletion is the documented unblock
under test); the same happened to `…-p02` and `…-p03`. Their destination PVCs were deliberately kept
(`followup/20261016-exp06-r02-same-vm/wedged-pvc-after.json#status.phase: Bound`); the rejected
follow-up test's own 3 Gi PVC was removed because the CR never existed
(`f1-delete-cr.out`). The pre-wedge tracker object no longer exists (deleted in leg 2).

## Negative results and what would falsify this ticket

- **Refuted: "the rejection is a Path-B (deleted-tracker) peculiarity".** It was reproduced on the
  corrupt-checkpoint path as well (`followup/20261016-exp06-r02-same-vm/f1-apply.out`, apply exit 1),
  which is why it is its own ticket rather than a paragraph in the EXP-8 analysis.
- **Refuted: "the guard clears on its own after a timeout".** It was still held ~65 minutes after the
  blocking pass was created, with the blocking CR's `resourceVersion` unmoved and the VMI event count
  growing; only explicit deletion released it (steps 6–8 of the timeline).
- **Refuted: "the state causes data loss".** The reversibility of the state (leg 2: a new full
  restores capability on both disks, `Done=True` in 18 s) is why this is an availability defect, not
  data loss.
- **Evidence caveat (must not be dropped)**: in `20261016-exp06-r02` the *pre-removal* bitmap state
  was witnessed only by the disruptor (the run's own injection checker REJECTed on that gap;
  `checkers/injection-validity.json`, and the observer's 48-row pre-capture history has zero
  `target_present=true` rows — `observer/effect/pre-bitmap-history.jsonl`). The deadlock observation
  itself does **not** depend on the removal: it is reproduced on a path with no injection (leg 1) and
  on a different fault entry path (EXP-8).
- **Contradictory/limiting evidence**: none found for the rejection itself.
- **Falsifier.** This ticket is wrong if a second backup created while the first is non-terminal is in
  fact *accepted* (the message would then be non-blocking), or if the blocking pass is shown to
  become terminal on its own within a bounded time so the guard always clears (that would make this a
  duplicate of P1 with no separate impact). Either observation downgrades it to a non-issue.

## Additional feedback (reporter's notes)

- **Open hypotheses and the smallest experiments that would settle them.**
  - *Does the guard consult terminal-ness at all, or only "an object with this source exists"?*
    Smallest experiment: on a scratch VM, create a CR that is provably terminal (`Done=True`) and then
    a second one — accepted, as expected; then compare with the wedged case. That only bounds the
    question; the code path is unproven here.
  - *Is there a `Failed`/`Stalled` classification the guard could key on?* No such condition was
    observed on the wedged CR (P4), so the smallest experiment is to look for the condition in the
    status of any other failure class and see whether admission consults it.
- **Triage questions that decide scope.**
  - Is the one-backup-per-source guard supposed to consult the blocking pass's terminal-ness, or is
    "operator deletes the wedged CR" the intended release? (Decides whether the fix belongs in
    admission or in the P1 terminal-resolution change.)
  - Should the admission error distinguish "in progress" from "stuck/non-recoverable" so monitoring
    and operators can act without inspecting the blocking CR by hand?
- **Environment-specific notes for the next reproducer.**
  - The rejection is a *validation* error on apply, so it never creates an object: check the apply
    exit code, not `oc get` — there is nothing to `get`.
  - Reconstruct the prerequisite state exactly as in the P1 surgery; note the fail-closed pre-check
    and the need for a **non-injector** witness of the pre-removal bitmap state (the r02 injection
    checker REJECTed on that gap), and measure pool capacity on `/var/hpvolumes/csi` (`/dev/sdb`),
    never on its parent filesystem.
  - Every backup attempt on this VM needs a destination PVC; a full one is fully allocated (~80 GiB)
    on a pool that had only 40.25 GiB free at the time of the follow-ups — plan capacity.
  - The verbose `Initializing=True` reason is a creation-time stamp; use `resourceVersion` movement
    as the liveness signal.
- **Cross-references.** Siblings in this folder: `backup-cr-livelock-on-missing-per-disk-bitmap.md`
  (**P1**, the root cause this deadlock amplifies, which also owns the deleted-tracker path),
  `backup-destination-volume-stuck-hotplug-mounted-during-wedge.md` (**P3**, the leaked hotplug mount
  of the blocking pass), `backup-cr-event-stream-empty-on-wedge.md` (**P4**, why the blocking pass
  looks healthy to CR-scoped monitoring),
  `checkpoint-redefinition-accepts-incomplete-checkpoint.md` (**P5**, the metadata state that precedes
  the wedge), `vmi-backupstatus-advertises-nonexistent-checkpoint.md` (**P6**, the status surface that
  also reads healthy in this state), and `20261016-exp06-r02-product-findings.md` (the consolidated
  working analysis; not filed itself). Findings registry:
  `docs/findings/finding-1-backup-cr-livelock.md` (prior-run characterization: Path A, Path B, the
  deadlock variant). **Separately and clearly labelled: harness/tooling gaps are not in this ticket** —
  see `cbt-chaos/scenarios_v2/CBT-EXP-06/harness-tickets-20261016-exp06-r02.md` (notably H-03, the
  pre-state witness gap, and H-04, no pass-adding path that preserves failed evidence).

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

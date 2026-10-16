# [Bug]: The failing backup CR's own event stream is empty — every failure event targets the VMI, so CR-scoped monitoring sees a healthy "in progress" backup forever

## What this is, in one paragraph

Changed block tracking (CBT) backups rest on a **checkpoint** — a named mark that records which of a
disk's blocks changed since the previous backup — backed by a per-disk **dirty bitmap**, the
change-tracking map that lives inside the running VM's QEMU process. When such a backup fails to
start, KubeVirt announces the failure only against the **VMI** (`VirtualMachineInstance`, the object
standing for the running VM) and never against the `VirtualMachineBackup` CR — the object the user
creates and watches. In this run the same failure fired 21 times as `BackupError` warnings over ~28
minutes, while a query for events on the backup CR itself returned an empty list and the CR's status
still advertised "in progress". A monitor or alert keyed on the backup object therefore sees a healthy
backup for ever, so a pass that can never complete — and the backup coverage the VM has silently lost
— go unnoticed.

**When → then → expected**

- **When** an incremental `VirtualMachineBackup` (a pass that copies only the blocks changed since the
  tracker's last checkpoint) is created against the `VirtualMachineBackupTracker`
  `vm-tracker-20261016-exp06-r02` after one of the VM's two disks has lost its checkpoint bitmap.
- **And** the disruption **CBT-EXP-06 — per-disk checkpoint-bitmap removal** (`chaos-trigger.sh`; **not a krknctl scenario** — krkn's 38 tags include no primitive that can touch a guest QEMU dirty bitmap) is applied: the `datadisk` checkpoint bitmap is deleted from the running QEMU (`block-dirty-bitmap-remove`, `node=libvirt-2-format`, `name=vm-backup-20261016-exp06-r02-2026-10-16_04-27-24`) and the VMI is then restarted to fire the checkpoint-redefinition path.
- **Then (current behaviour):** the failure is emitted only against the VMI — 21 `BackupError` warning
  events between 04:29:29Z and 04:57:02Z, every one with `involvedObject.kind =
  VirtualMachineInstance`, aggregating into the single Event object
  `vm-20261016-exp06-r02.18dee82a1076f935` (`count=41`, firstTimestamp 04:29:29Z, lastTimestamp
  05:46:12Z) — while the backup CR's own stream stays empty in both recorded captures (`{"items": []}`
  each) and the CR still reads `Initializing=True` / `Progressing=False` with its creation-time
  "being attached" reason ~65 minutes later.
- **Expected behaviour:** the failure is observable on the **backup object** — either the CR's event
  stream carries the failure events, or the CR exposes an equivalent `Stalled`/`Failed`-leaning
  condition carrying the backend error — so a consumer watching only the backup CR can tell "still
  running" from "permanently failing"; and a successful full or incremental still produces no CR-level
  failure event and no false "stalled" condition.

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
| Issue type | **Bug** — a demonstrated mis-scoping of the failure signal: the object the user manages (the backup CR) carries no failure event, and its status actively reads "in progress" while the backend refuses the pass. The residual "is VMI-scoped emission the intended contract?" question is a triage question, not a reason to file this as an Improvement: the observable defect (a CR-scoped consumer is misled indefinitely) is demonstrated. |
| Priority (proposed) | **Medium/High** — observability. No data loss; the harm is that the failure is invisible on the object a backup operator or monitor naturally watches. Unassigned pending triage. |
| Severity class | observability (status truthfulness once combined with P1's stale reason) |
| Owning component (suspected) | **suspected** CNV/KubeVirt backup stack: event emission on the `VirtualMachineBackup` object (virt-controller backup controller emit path). The exact emit site is **unproven** — no source anchor was read for this run. |
| Component(s) proven involved | the VMI-scoped event emitter (it produced 21 `BackupError` warnings with `involvedObject.kind = VirtualMachineInstance`) and the `VirtualMachineBackup` status writer (it produced no CR-scoped event at all across two independent capture paths, while writing a positive "in progress" reason). What is proven is the *scope* of emission, not the code path that chooses it. |
| Reproducibility | `deterministic` in the wedge state — 2/2 CR-scoped captures empty (two capture paths, covering the two wedged passes) while the VMI received 21+ failure events over the same ~65-minute period. |
| Status / confidence | **Confirmed behaviour, high confidence** for the artifact facts (empty CR stream twice; VMI-scoped emission 21+ times; counts and scopes). Whether the intended contract requires CR-level events, or VMI-scoped emission is the documented surface, is a **contract question** flagged for triage. |
| Blast radius | consumers of this VM's backups (per-VM) — and, since prior runs show the same pattern, any cluster-wide backup monitoring keyed on `VirtualMachineBackup` objects (r01 leg B and EXP-8 recorded the same behaviour; finding-3 records a related misleading-signal pattern). |
| Data at risk? | **No** — nothing about the data path changes; the harm is purely that a stalled pass is not reported where it is expected. |
| Related scenario / execution | `CBT-EXP-06` / `20261016-exp06-r02` (2026-10-16, closed `BLOCKED`, pass `…-p01`); post-close same-VM follow-up `20261016-exp06-r02-same-vm` (F0/F3, 05:34–05:55Z); antecedents `CBT-EXP-06` / `20261014-exp06-r01` (2026-10-14, leg B) and `CBT-EXP-08` / `20261014-exp08-r01` (2026-10-14). |
| Affected versions | short pointer — OpenShift 4.22.15, CNV `kubevirt-hyperconverged-operator.v4.22.12`, APIs `backup.kubevirt.io/v1alpha1` and `kubevirt.io/v1`. The full measured matrix is in **Environment** below. |

## Context (for an engineer new to this area)

- **What the feature does** — KubeVirt CBT push-mode backups. A `VirtualMachineBackup` CR requests a
  backup of a source VM into a hotplugged destination volume; the pass reports progress through
  `status.conditions` (`Initializing`, `Progressing`, then a terminal `Done`), and failures are
  reported as Kubernetes **events**.
- **Where the failure sits** — on the **event scope**: `oc get events --field-selector
  involvedObject.name=<backup-cr>` returns nothing for a failing pass, while the same failure is
  emitted repeatedly against the VMI. The CR's `status.conditions` meanwhile still says
  `Initializing=True` with a creation-time reason.
- **Observed surface vs. origin** — exactly the mismatch that is the defect: the *failing* object is
  the backup CR, but every signal lands on the VMI. An operator or controller watching the CR sees a
  pass that is "still attaching its volume", indefinitely.
- **Why it matters** — the natural monitoring surface for a backup (the backup object) is silent for
  the one failure mode that needs a human (P1/P2). Alerts keyed on the CR never fire, so the VM loses
  its backup coverage without a signal where anyone is looking.

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

- **Classification**: deterministic *in the wedge state* — the CR stream was empty in both captures
  covering ~65 minutes, while the VMI received 21+ failure events in the same interval.
- **Attempts**: 2 independent CR-scoped captures, both empty (see Current behaviour); the VMI-scoped
  emission was captured from the run's own event stream plus the follow-up's namespace capture. Two
  different wedged passes (r02 `…-p01` and follow-up `…-p02`) exhibit the same pattern.
- **Stability** — exact every time: emptiness of the CR-scoped list; the presence of repeating
  VMI-scoped `BackupError` warnings naming the per-disk checkpoint error; the CR's positive
  `Initializing=True` reason. Varying: only the event counts and the observation window.
- **Preconditions**: a backup start failure on the path documented in P1 (checkpoint bitmap missing for
  one disk, VMI restarted, incremental requested). What breaks the repro: a successful pass — the CR
  then legitimately has no failure event.
- **Second entry path**: not tested for the event scope in this defect set. The pattern is *documented*
  in prior runs (r01 leg B, EXP-8 per `docs/findings/finding-3-ghost-event-observability.md` and
  `docs/findings/finding-1-backup-cr-livelock.md`), so it is likely generic to backup start failures;
  that is **[INFERENCE]** from those prior records, not an observation made here.
- **Attribution caveat**: the run's injection checker REJECTed on a missing non-injector pre-removal
  bitmap witness (`checkers/injection-validity.json`; `observer/effect/pre-bitmap-history.jsonl`,
  0 rows with `target_present=true`). **This defect does not depend on that attribution**: the empty CR
  stream and the VMI-scoped emission are properties of the wedge, which is reproduced on a path with no
  injection (leg 1), and they have antecedents in r01/EXP-8.

## Steps to reproduce (exact commands and injection timing)

The object names below are the **recorded names** of run `20261016-exp06-r02` in namespace
`vm-cbt-demo`, taken verbatim from that run's artifacts, and the commands are re-creations of the
recorded shapes (the run's trigger is frozen at sha256
`9291f017a605ad0cee49e754d4eebe0f38e9d89db0ae19ad3f489366dd241f92`), not a live transcript. On a fresh
cluster create equivalents with your own run-scoped names and substitute them everywhere — the names
in the table and in the commands are the only values you need to change, and they are callable out of
this document. Use a dedicated cluster and never reuse another run's names.

One scoping note before you start: the empty CR event stream is a property of the **wedge** state and
is present whenever a pass is stuck this way — the recorded run also reached it on a leg with no
injection at all — so the read-only command in step 8 can be pointed at *any* wedged pass. The full
sequence below, injection included, is the reproduction of the recorded state.

**Concrete objects used in this report** (namespace `vm-cbt-demo`; recorded names of run
`20261016-exp06-r02`):

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

Which objects were deleted, and by which leg, in one paragraph so triage does not have to reconstruct
it from the table: each of the three wedged CRs was deleted **CR-only** during the post-close
follow-ups — `…-p01` in follow-up F2, `…-p02` in leg 1 L2, `…-p03` in leg 2 L2 — and each deletion
released the finalizer in 2–3 s; **all three of their destination PVCs were kept** (`Bound`, ~0 bytes
written). The only destination PVC deleted was the control full's 80 GiB
`vm-backup-pvc-20261016-exp06-r02` (deleted 2026-10-16 on operator approval, to reclaim pool space);
the never-admitted follow-up's 3 GiB PVC `vm-followup-pvc-20261016-exp06-r02-f01` was created and then
removed without ever being used; and the post-recovery full's 80 GiB destination PVC
`vm-followup-full-pvc-20261016-exp06-r02-f02` was kept. The tracker was deleted in leg 2 L3 and
re-created in leg 2 L4; the VMI and its launcher pod were replaced by the injection.

**Step 1 — Create the two-disk CBT VM and take a control full backup.** Run this first, on a dedicated
cluster, before anything else.

Create your own equivalent of the recorded VM `vm-20261016-exp06-r02`: `runStrategy: Always`, 1 vCPU /
2 GiB, `rootdisk` (vda) an 80 GiB clone of the RHEL 9 DataSource on StorageClass `cbt-demo-hpp`, and
`datadisk` (vdb) a 2 GiB blank disk with ext4 mounted at `/mnt/datadisk`. The run rendered the repo's
templated manifest `cbt-chaos/scenarios_v2/CBT-EXP-06/vm-2disk.yaml` with its own run-scoped names,
SSH key and DataSource. Wait until the VMI reaches the trigger's own gate, `status.phase=Running` plus
`status.changedBlockTracking.state=Enabled`:

```bash
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.status.phase}{" "}{.status.changedBlockTracking.state}{"\n"}'
```

**What you must see:** `Running Enabled`. Do not continue while `changedBlockTracking.state` reads
anything other than `Enabled`.

Then create the chain's tracker, the full backup's destination PVC and the full backup itself — the
validated trio schema (`spec.source.apiGroup/kind/name` on both the tracker and the backup, `pvcName`
on the backup):

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

**What you must see:** `virtualmachinebackuptracker/vm-tracker-20261016-exp06-r02`,
`persistentvolumeclaim/vm-backup-pvc-20261016-exp06-r02` and
`virtualmachinebackup/vm-backup-20261016-exp06-r02` each reported as created or configured. Then wait
for the full to terminate:

```bash
oc get vmbackup vm-backup-20261016-exp06-r02 -n vm-cbt-demo -o json | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes}'
oc get vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'
```

**What you must see:** `status.type` = `Full`; a terminal `Done=True` condition in `status.conditions`;
`status.includedVolumes` containing both `rootdisk` and `datadisk` (recorded `Done=True` at 04:28:20Z);
and `status.latestCheckpoint.name` printing the checkpoint — recorded
`vm-backup-20261016-exp06-r02-2026-10-16_04-27-24` — whose datadisk bitmap step 4 removes. **The
injection window opens the moment the full reports `Done=True`.**

**Step 2 — Locate the launcher pod and the libvirt domain.** Run any time after the VMI is `Running`,
and re-run it after the restart in step 6, because both the VMI and the pod are replaced.

```bash
oc get pod -n vm-cbt-demo -l vm.kubevirt.io/name=vm-20261016-exp06-r02 -o jsonpath='{.items[0].metadata.name}'
oc exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- virsh list --name
```

**What you must see:** exactly one pod name — recorded `virt-launcher-vm-20261016-exp06-r02-ljm2w`
(uid `1160f767-7cbb-4352-a5cf-3ee37aac611d`) before the injection, replaced by
`virt-launcher-vm-20261016-exp06-r02-rwzzr` (uid `6bb8b6c5-e7af-4ee8-84d6-a689c4159ece`) after it — and
the domain `vm-cbt-demo_vm-20261016-exp06-r02` in the `virsh list --name` output. If your pod name
differs, substitute it in every `-c compute` command below; the domain name is always
`<namespace>_<vm-name>` (`vm-cbt-demo_vm-20261016-exp06-r02` here).

**Step 3 — Fail-closed PRE-check: the datadisk's checkpoint bitmap must be present before you touch
anything.** Run immediately after step 1's terminal `Done=True` and before step 7 creates the next
backup object — that is the whole injection window, and it is short (r02: `Done=True` 04:28:20Z →
removal 04:28:21.690Z → next backup object 04:29:26Z). An unreadable or unparseable reply is a stop,
never a pass.

```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}'
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}' | jq -r '.return[] | select(."node-name" | endswith("-format")) | "\(."node-name") \(.file) bitmaps=\([."dirty-bitmaps"[]?.name] | join(","))"'
```

**What you must see:** in the reply's `return[]` array, the datadisk node `libvirt-2-format` — the node
whose `file` ends `/cbt/datadisk.qcow2` — carries the checkpoint in its `dirty-bitmaps` array with
`recording=true`, **and** the rootdisk node `libvirt-4-format` holds the same checkpoint name too (the
same checkpoint is registered once per disk). `libvirt-2-storage` is the protocol child of the same
datadisk file and does not carry the bitmaps. If the bitmap is missing on either disk, **abort** — the
repro needs a *before* state in which both disks hold it.

**A non-injector witness must capture this pre-removal state.** In r02 only the injector did, and the
run's injection checker therefore REJECTed the injection (`checkers/injection-validity.json`;
`observer/effect/pre-bitmap-history.jsonl`, 0 rows with `target_present=true`). Have a second party or
the observer process run these two reads before you remove anything.

**Step 4 — The injection: remove the datadisk's checkpoint bitmap only.** Run inside the window opened
in step 1 and closed in step 7: after the control full's terminal `Done=True` (recorded 04:28:20Z) and
before the next backup object is created (recorded 04:29:26Z). The removal itself is recorded at
**04:28:21.690Z**.

```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"block-dirty-bitmap-remove","arguments":{"node":"libvirt-2-format","name":"vm-backup-20261016-exp06-r02-2026-10-16_04-27-24"}}'
```

**What you must see:** `.return` = `{}` — the recorded reply, byte for byte,
`trigger/qmp-remove-result.txt`. Any QMP error means abort. Note for the next reader:
`query-block-dirty-bitmap` does not exist on this QEMU (its `query-commands` lists only
`block-dirty-bitmap-{add,clear,disable,enable,merge,remove}`), so list a node's bitmaps from
`query-named-block-nodes` as in step 3; and target the datadisk's `-format` node only, never the
`-storage` protocol child.

**Step 5 — Fail-closed POST-check: the bitmap is gone from that node and still present on the other.**
Run immediately after step 4, on the same launcher — the VMI has not been restarted yet.

```bash
kubectl exec -n vm-cbt-demo virt-launcher-vm-20261016-exp06-r02-ljm2w -c compute -- virsh qemu-monitor-command vm-cbt-demo_vm-20261016-exp06-r02 '{"execute":"query-named-block-nodes"}' | jq -r '.return[] | select(."node-name" == "libvirt-2-format" or ."node-name" == "libvirt-4-format") | "\(."node-name") bitmaps=\([."dirty-bitmaps"[]?.name] | join(","))"'
```

**What you must see:** `libvirt-2-format bitmaps=` with an empty list (the recorded after-state,
`trigger/bitmaps-after.json` = `[]`) while `libvirt-4-format` still lists the checkpoint name. Do not
continue if both are empty (that is a different state) or if neither changed. The same contrast is
recorded from the replacement launcher at 04:28:54Z, 04:50:46Z and 04:54:4xZ
(`observer/effect/qmp-nodes-post.json`, `…/pre-bitmap-history.jsonl`).

**Step 6 — Fire the checkpoint redefinition by deleting the VMI.** Run immediately after step 5 passes:
the restart is what rebuilds the checkpoint, and it replaces both the VMI and the launcher pod.

```bash
oc delete vmi vm-20261016-exp06-r02 -n vm-cbt-demo
oc get vmi vm-20261016-exp06-r02 -n vm-cbt-demo -o jsonpath='{.metadata.uid}{" "}{.status.phase}{" "}{.status.changedBlockTracking.state}{"\n"}'
```

**What you must see:** the recorded VMI uid `968b6e7e-c021-46e4-a731-ca0dbec6121f` disappears (delete
requested 04:28:22Z), and the read then prints a **new** `metadata.uid` — recorded
`9651acfc-1e0d-4c4e-ad94-581e2c4cdf11` — with `status.phase=Running` and
`status.changedBlockTracking.state=Enabled` (recorded at 04:28:45Z; virt-controller logged the line
"Checkpoint redefinition successful" at 04:28:45.625161Z in that window). Poll until both fields read
that way; the replacement
launcher pod is `…-rwzzr` (step 2).

**Step 7 — Create the pass that wedges; this closes the injection window.** Run as soon as the
replacement VMI reads `Running`/`Enabled`. Apply the same trio schema as step 1 with the incremental
names — tracker unchanged, destination PVC `vm-incremental-pvc-20261016-exp06-r02-p01`, backup
`vm-incremental-20261016-exp06-r02-p01`, `pvcName` pointing at that PVC. The recorded incremental
destination was 30 GiB, `ReadWriteOnce` on `cbt-demo-hpp` and stayed `Bound` with ~0 bytes written
(`followup/20261016-exp06-r02-same-vm/wedged-pvc-after.json#spec`); size it for your own pool.

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
oc get pvc vm-incremental-pvc-20261016-exp06-r02-p01 -n vm-cbt-demo -o jsonpath='{.status.phase}{"\n"}'
```

**What you must see:** `persistentvolumeclaim/vm-incremental-pvc-20261016-exp06-r02-p01` and
`virtualmachinebackup/vm-incremental-20261016-exp06-r02-p01` each reported as created, then the PVC's
`status.phase` = `Bound` before the pass can start. **The injection window closes here** (recorded
creation 04:29:26Z).

**Step 8 — Observe (read-only): the defect — the CR's own event stream is empty while the VMI carries
every failure.** Run this from ~30 s after step 7 onwards and keep re-running it (events expire, so
capture as they appear). Declare the pass wedged only after the pass bound has elapsed — the harness
used 20 minutes, and a healthy incremental here completes in seconds (recorded: `…-p01` created
04:29:26Z, first VMI `BackupError` 04:29:29Z, the harness gave up at 04:49:27Z after 20m35s, and the
last of the 21 VMI events landed 04:57:02Z).

```bash
oc get events -n vm-cbt-demo --field-selector involvedObject.name=vm-incremental-20261016-exp06-r02-p01 -o json
oc get events -n vm-cbt-demo --field-selector involvedObject.name=vm-incremental-20261016-exp06-r02-p01 -o json | jq '.items | length'
oc get events -n vm-cbt-demo --field-selector involvedObject.kind=VirtualMachineInstance,involvedObject.name=vm-20261016-exp06-r02 -o json | jq -r '.items[] | [.type,.reason,.involvedObject.kind,.involvedObject.name,.count,.firstTimestamp,.lastTimestamp,.message] | @tsv'
oc get vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo -o json | jq '{type:.status.type,conditions:.status.conditions,included:.status.includedVolumes,finalizers:.metadata.finalizers}'
```

**What you must see:**
- The CR-scoped query returns an **empty** list: `.items | length` is `0`. That is this ticket's
  defect — the object the user manages carries no failure event at all. Both recorded captures are
  exactly that: `followup/20261016-r02-same-vm/wedged-cr-events.json` and
  `followup/20261016-exp06-r02-same-vm/f3-events-cr.json` are each `{"items": []}`, the second one for
  the replacement pass `…-p02`.
- The VMI-scoped query returns repeating rows with `type=Warning`, `reason=BackupError` and
  `involvedObject.kind=VirtualMachineInstance` (recorded: 21 such events between 04:29:29Z and
  04:57:02Z; the aggregated Event object `vm-20261016-exp06-r02.18dee82a1076f935` reached `count=41`,
  `firstTimestamp` 04:29:29Z, `lastTimestamp` 05:46:12Z), whose `message` names the per-disk backend
  error: *"Failed backing up VM: server error. command Backup failed: "virError(Code=109, Domain=10,
  Message='checkpoint inconsistent: missing or broken bitmap
  'vm-backup-20261016-exp06-r02-2026-10-16_04-27-24' for disk 'vdb'')""*.
- The CR's own status advertises progress instead of failure: `conditions[type=Initializing].status` =
  `True` and `conditions[type=Progressing].status` = `False`, with a creation-time reason ("backup
  target PVC … is being attached to VMI …"), **no** `status.type`, no `Done` condition and no
  `status.includedVolumes`, while `metadata.finalizers` still holds
  `backup.kubevirt.io/vmbackup-protection` (recorded `resourceVersion 27323776`, unchanged from
  04:29:26Z through the reads ~65 minutes later).

Two reader notes from the recorded captures: query the two scopes **separately** (a namespace-wide
listing interleaves both objects' events and hides the mismatch), and after step 6 query the VMI by its
**new** uid.

**Step 9 — Recover: delete only the wedged CR, then discard the chain.** Run after you have recorded
the observations in step 8.

```bash
oc delete vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo     # CR only: releases the finalizer and detaches the hotplug mount
oc get vmbackup vm-incremental-20261016-exp06-r02-p01 -n vm-cbt-demo --ignore-not-found
oc get pvc vm-incremental-pvc-20261016-exp06-r02-p01 -n vm-cbt-demo -o jsonpath='{.status.phase}{"\n"}'
```

**What you must see:** the CR disappears within seconds (recorded 3 s for `…-p01` in follow-up F2, 3 s
for `…-p02` in leg 1 L2, 2 s for `…-p03` in leg 2 L2 — the recorded leg-2 form of the same command
being `oc delete vmbackup vm-incremental-20261016-exp06-r02-p03 -n vm-cbt-demo`), while its destination
PVC stays `Bound`: the finalizer release and the hotplug detach are the documented unblock of **P1**
and **P3**. This does **not** restore the failed pass.

Repairing the tracker's volume list does **not** unblock anything (leg 1, decisive negative):

```bash
oc patch vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo --subresource=status --type=merge -p '{"status":{"latestCheckpoint":{"volumes":[{"diskTarget":"vda","volumeName":"rootdisk"}]}}}'
```

**What you must see:** the patch is accepted — `status.latestCheckpoint.volumes` lists `rootdisk` only
(recorded rv `27464802`, stable at +30 s) — and the **next** pass still names `vdb` and wedges on the
same `virError(Code=109)`. Discarding the chain is what restores capability (leg 2, positive):

```bash
oc delete vmbackuptracker vm-tracker-20261016-exp06-r02 -n vm-cbt-demo
```

then re-apply the step-1 trio for a fresh tracker, a fresh 80 GiB destination PVC and a new full backup
(recorded names `vm-followup-full-20261016-exp06-r02-f02` and
`vm-followup-full-pvc-20261016-exp06-r02-f02`, the destination PVC **kept**). **What you must see:** the
new full reads `status.type=Full` with `Done=True` — recorded 18 s after the fresh tracker, with
`includedVolumes=[vda/rootdisk, vdb/datadisk]` and `Done=True` at 07:00:53Z — and a new both-disk
checkpoint appears (recorded `vm-followup-full-20261016-exp06-r02-f02-2026-10-16_07-00-35` at
07:00:35Z).

**Step 10 — Optional accelerators, never required.** The recorded run shipped drivers for exactly these
steps: `cbt-chaos/scenarios_v2/CBT-EXP-06/chaos-trigger.sh` (the trigger that ran this scenario, frozen
sha256 `9291f017a605ad0cee49e754d4eebe0f38e9d89db0ae19ad3f489366dd241f92`),
`same-vm-followup.sh`, `leg1-tracker-repair.sh` and `leg2-chain-discard.sh`. Read them for the
fail-closed gates; the ten steps above stand alone.

## Current behaviour (observed)

Observed on `20261016-exp06-r02` and its follow-up (all times UTC, from the named artifacts):

- **Zero events on the backup CR — twice, from two capture paths.**
  - `cbt-chaos/scenarios_v2/CBT-EXP-06/followup/20261016-r02-same-vm/wedged-cr-events.json` →
    `{"items": []}` (captured ~05:0xZ, during the run's own wedge).
  - `cbt-chaos/scenarios_v2/CBT-EXP-06/followup/20261016-exp06-r02-same-vm/f3-events-cr.json` →
    `{"items": []}` (captured after 05:35Z, for the wedge's replacement pass `…-p02`).
  *Independent artifact observations.*
- **The failures are emitted, but only against the VMI.** 21 `BackupError` warning rows between
  04:29:29Z and 04:57:02Z in
  `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02/observer/watches/events.jsonl` — the
  file's only event kinds are `Event` (53), `VirtualMachineInstance` (49) and `VirtualMachine` (4), and
  all 21 `BackupError` rows are VMI-involved. The single aggregated Event object
  `vm-20261016-exp06-r02.18dee82a1076f935` carried `count=41`, `firstTimestamp 04:29:29Z`,
  `lastTimestamp 05:46:12Z` by the follow-up's capture
  (`followup/20261016-exp06-r02-same-vm/f3-events-ns.json`). Verbatim message: *"Failed backing up VM:
  server error. command Backup failed: "virError(Code=109, Domain=10, Message='checkpoint
  inconsistent: missing or broken bitmap 'vm-backup-20261016-exp06-r02-2026-10-16_04-27-24' for disk
  'vdb'')""*. The same error appears 40 times in
  `runs/20261016-exp06-r02/observer/effect/virt-controller-window.log`
  (04:29:29.103549Z→04:40:22.432162Z) and 20 times in `…/virt-handler-window.log`.
  *Independent artifact observation.*
- **The CR's status actively contradicts the failure.** `Initializing=True` / `Progressing=False`,
  reason *"backup target PVC … is being attached to VMI …"*, stamped once at creation (04:29:26Z) and
  never re-stamped; no `type`, no `Done`, no `includedVolumes`
  (`runs/20261016-exp06-r02/trigger/legB-incremental-backup.yaml#status`;
  `runs/20261016-exp06-r02/observer/effect/preserved-summary.json`;
  `runs/20261016-exp06-r02/observer/FINAL.json#runtime_checks_at_final_utc.p01`). The status still read
  that way ~65 minutes later (`followup/20261016-exp06-r02-same-vm/wedged-cr-before-delete.yaml`).
- **Same pattern in the follow-up's new pass.** `…-p02` re-fired one namespace-level `BackupError` at
  05:46:12Z while its own CR-scoped stream stayed empty
  (`followup/20261016-exp06-r02-same-vm/f3-events-ns.json`, `…/f3-events-cr.json`).
- **Significance claim is inference**: that CR-scoped monitoring is thereby misled is **inference**,
  though it rests on the recorded absence of any CR-level signal and the presence of a positive
  "in progress" status reason.

## Expected behaviour (contract)

- Backup start/copy failures must be observable on the **backup object**: either the CR's event stream
  carries the failure events, or the CR exposes an equivalent condition/status field (e.g. a
  `Stalled`/`Failed`-leaning condition carrying the backend error), so an operator or monitor watching
  the backup CR can distinguish "still running" from "permanently failing".
- Any alerting currently keyed on VMI-scoped `BackupError` events should have a documented CR-level
  equivalent.
- Regression: a successful full and a successful incremental still produce no CR-level failure event
  and no false "stalled" condition.

**Acceptance check (what a reviewer runs).** In the repro state,
`oc get events --field-selector involvedObject.name=<wedged-cr>` is non-empty (or the CR carries an
equivalent failure condition), and a CR-only reader can tell the pass is not progressing.

## Impact, workaround and data safety

- **Functions lost / consumer risk**: backup automation keyed on the `VirtualMachineBackup` object
  (the object type it manages) cannot see the wedge. Combined with P1's stale "in progress" status and
  P6's optimistic VMI status, every product surface a naive consumer reads says the pass is fine.
- **Blast radius**: the affected VM's backup consumers; the same pattern is documented in prior runs
  (r01 leg B, EXP-8) and in finding-3's "sole-signal-on-failure" analysis, so it is likely generic to
  backup start failures rather than specific to this injection.
- **Data safety**: **not** at risk — this is purely an observability/status-truthfulness defect.
- **Workaround (interim)**: monitoring must be re-pointed at VMI-scoped events (fragile — it crosses
  object kinds and mixes in other VMI warnings), or at the CR's *absence of progress* past a bound
  (which requires knowing the pass bound; the harness used 20 minutes —
  `runs/20261016-exp06-r02/trigger/trigger.log`). Neither is a supported contract.
- **Frequency**: deterministic in this failure state; how often in production depends on how often
  backup starts fail permanently.
- **Unknowns / what this ticket does not claim**: it does not claim the product emits *no* CR events
  ever (see Negative results), nor which emit site is responsible, nor that any shipped consumer keys
  on VMI events today.

## Evidence

**Artifact index** (repository-relative; run root
`cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02/`). "raw" = captured stream/command output;
"summary" = derived.

- CR-scoped event captures, both empty (raw):
  `cbt-chaos/scenarios_v2/CBT-EXP-06/followup/20261016-r02-same-vm/wedged-cr-events.json`
  (run-time capture) and
  `cbt-chaos/scenarios_v2/CBT-EXP-06/followup/20261016-exp06-r02-same-vm/f3-events-cr.json`
  (follow-up capture for `…-p02`).
- VMI-scoped failures (raw): `observer/watches/events.jsonl` (21 `BackupError` rows,
  04:29:29Z–04:57:02Z), `observer/effect/virt-controller-window.log` (40 lines,
  04:29:29.103549Z→04:40:22.432162Z), `observer/effect/virt-handler-window.log` (20 lines).
- CR status that reads healthy: `trigger/legB-incremental-backup.yaml#status` (raw),
  `observer/effect/preserved-summary.json` (summary),
  `observer/FINAL.json#runtime_checks_at_final_utc.p01` (summary),
  `followup/20261016-exp06-r02-same-vm/wedged-cr-before-delete.yaml` (raw; still in-progress ~65 min on).
- Follow-up corroboration (raw + summary):
  `followup/20261016-exp06-r02-same-vm/{f3-events-ns.json,FINDINGS.md}` (the 05:46:12Z namespace event
  with an empty CR stream).
- Event-object aggregation (raw): the `vm-20261016-exp06-r02.18dee82a1076f935` entry in
  `followup/20261016-exp06-r02-same-vm/f3-events-ns.json` (`count=41`, first 04:29:29Z, last 05:46:12Z).
- Related characterization (summary): `docs/findings/finding-3-ghost-event-observability.md` — the
  `VirtualMachineBackupFailed: "Backup has failed: VMI backup status was lost"` ghost event, its
  spurious-on-success role (7/9 RHEL runs) and its "sole-signal-on-failure" role; its recorded
  disposition folds this observability component into the root-cause ticket.
- Antecedents in the prior run (raw): `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261014-exp06-r01/observer/events-incr.jsonl`
  (backup-object events: EMPTY) versus
  `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261014-exp06-r01/observer/events-vm.jsonl` (19 `BackupError`
  events on the VMI) — the same scope mismatch a run earlier; plus the EXP-8 records summarized in
  `docs/findings/finding-1-backup-cr-livelock.md`.
- Evidence caveat artifacts (summary + raw): `checkers/injection-validity.json`,
  `observer/effect/pre-bitmap-history.jsonl`.

- Also present in the pack (recorded; not load-bearing for any claim above): `trigger/action-request.json`, `trigger/exit-statuses.json`, `observer/ARMED`, `observer/PRESERVED`, `observer/finding.md`, `observer/effect/post-vmbackups.json`, `recovery/step2-verify.log`, `reports/test-run-result.md`, `reports/test-run-report.md`, `checkers/report-fidelity.json`.

**UTC timeline** (setup → precondition → injection → effect → failure → recovery; source per entry):

1. 04:27:24Z → 04:28:20Z — control full backup created and reaches `Done=True`
   (`observer/effect/facts-digest.json#vmbackup_state_first_recv_utc`). **Injection window opens.**
2. 04:28:21.690Z — per-disk bitmap removed (`trigger/qmp-remove-result.txt`); VMI restarted;
   redefinition "successful" at 04:28:45.625161Z (`trigger/controller-redefinition-window.log:87`).
3. **04:29:26Z** — affected pass `…-p01` created, `Initializing=True`/`Progressing=False`
   (`trigger/legB-incremental-backup.yaml`). **Injection window closes.**
4. 04:29:29Z — first `BackupError`, on the **VMI** (`observer/watches/events.jsonl`); the CR-scoped
   stream is empty from this moment on.
5. 04:29:29.103549Z–04:40:22.432162Z — 40 virt-controller + 20 virt-handler error lines
   (`observer/effect/*-window.log`).
6. 04:49:27Z — the harness gives up after 20m35s; the product object records nothing
   (`trigger/trigger.log`).
7. 04:57:02Z — last of the 21 VMI `BackupError` rows (`observer/watches/events.jsonl`).
8. ~05:0xZ — run-time CR-scoped capture returns `{"items": []}`
   (`followup/20261016-r02-same-vm/wedged-cr-events.json`).
9. 05:34Z — the CR still reads in-progress ~65 minutes after creation
   (`followup/20261016-exp06-r02-same-vm/wedged-cr-before-delete.yaml`).
10. 05:35:13Z — `…-p02` created; 05:46:12Z it re-fires one namespace `BackupError` while its CR stream
    stays empty (`followup/20261016-exp06-r02-same-vm/f3-events-ns.json`, `f3-events-cr.json`) — the
    second, independent capture of the same scope mismatch.
11. 05:35Z / 06:35Z / 07:00Z — recovery legs (CR deletions, tracker discard) per P1; the failure is
    never reported on any of the three CRs before their deletion.

**Retained state.** The run is closed and its pack frozen; nothing under the run root was modified
post-close. The three wedged CRs (`…-p01`, `…-p02`, `…-p03`) were deleted during the post-close
follow-ups as the documented unblock, so their live objects no longer exist; their captured manifests,
event lists and statuses are retained in the artifacts above. Their destination PVCs were kept
(`wedged-pvc-after.json#status.phase: Bound`).

## Negative results and what would falsify this ticket

- **Counter-example that must not be over-read: CR-level events *do* exist on some paths.** A
  `VirtualMachineBackupFailed` event ("Backup has failed: VMI backup status was lost") is recorded in
  prior runs (`docs/findings/finding-3-ghost-event-observability.md`), where it is spurious on
  success and the sole signal on failure. So "the CR never gets events" is **specific to this
  wedge/start-failure state**, not a global absence — this ticket claims the specific case, not a
  global one.
- **Refuted: "the failure is not detected at all".** It is detected loudly — 21 VMI-scoped warnings,
  40 controller lines, 20 handler lines in this run — the defect is the *scope*, not the detection.
- **Refuted: "the CR status is a transient read that self-corrects".** The positive
  `Initializing=True` reason was still present ~65 minutes after creation with an unmoved
  `resourceVersion`, long after the harness had declared the pass failed.
- **Evidence caveat (must not be dropped)**: the wedge's attribution to the removed bitmap carries the
  injector-only pre-state gap (`checkers/injection-validity.json` REJECT;
  `observer/effect/pre-bitmap-history.jsonl`, 0 rows with `target_present=true`). This defect does not
  depend on that attribution: the empty CR stream and the VMI-scoped emission were observed on the
  wedge reproduced *without* injection (leg 1) and have antecedents in r01/EXP-8.
- **Contradictory/limiting evidence**: none for the empty CR scope in this state; the finding-3
  counter-example above bounds the claim.
- **Falsifier.** This ticket is wrong if a CR-scoped event query for a wedged pass in fact returns the
  failure events (i.e. the captures were scoped wrongly), or if the product's documented contract
  explicitly makes VMI-scoped events the only supported failure surface *and* provides another
  supported CR-level field that a CR-only consumer can read — in that case this becomes a
  documentation gap rather than a defect.

## Additional feedback (reporter's notes)

- **Open hypotheses and the smallest experiments that would settle them.**
  - *Which emit site chooses the VMI, and does it depend on the failure class?* Smallest experiment:
    trigger a different start-failure class (e.g. a destination PVC that cannot bind) and compare the
    event scopes — if the CR gets an event there, the defect is class-specific.
  - *Is there a CR-level condition intended but only set on other failure classes?* Smallest
    experiment: enumerate the conditions observed across failure classes in the pack and check whether
    any consumer key is documented.
- **Triage questions that decide scope.**
  - Is CR-level event emission for backup start failures part of the intended contract, or is
    VMI-scoped emission the documented surface?
  - If CR events are not intended, which CR field is the supported way for a consumer to detect a
    non-progressing backup — and is it set for this failure class?
- **Environment-specific notes for the next reproducer.**
  - Events are namespaced and short-lived: capture them into a file as they appear (`events.jsonl`
    style) instead of querying at the end, or the earlier occurrences will have expired.
  - Use two separate `--field-selector involvedObject.name=` queries (CR vs VMI) — a single namespace
    listing hides the mismatch because both objects' events are interleaved.
  - Beware that a VMI restart (needed to fire the redefinition path) replaces the VMI object, so adopt
    the new VMI name/uid for the VMI-scoped query.
  - The pass bound matters for the "stalled" reading: the harness used 20 minutes; a healthy
    incremental here completes in seconds, so a bound of a few minutes is usually enough to call it.
- **Cross-references.** Siblings in this folder: `backup-cr-livelock-on-missing-per-disk-bitmap.md`
  (**P1**, the wedge this blind spot hides — its r01 draft already recorded the empty CR stream),
  `vm-wide-backup-capability-deadlock.md` (**P2**, the availability consequence that CR-scoped
  monitoring would otherwise surface), `backup-destination-volume-stuck-hotplug-mounted-during-wedge.md`
  (**P3**, the leaked mount that is currently the only unilateral symptom),
  `checkpoint-redefinition-accepts-incomplete-checkpoint.md` (**P5**, the silent metadata split that
  precedes the failures), `vmi-backupstatus-advertises-nonexistent-checkpoint.md` (**P6**, the second
  status surface that reads healthy here), and `20261016-exp06-r02-product-findings.md` (the
  consolidated working analysis; not filed itself). Findings registry:
  `docs/findings/finding-3-ghost-event-observability.md` (disposition: fold the observability component
  into the root-cause ticket) and `docs/findings/finding-1-backup-cr-livelock.md`. **Separately and
  clearly labelled: harness/tooling gaps are not in this ticket** — see
  `cbt-chaos/scenarios_v2/CBT-EXP-06/harness-tickets-20261016-exp06-r02.md` (notably H-03, the
  pre-state witness gap).

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

# [Contract clarification / Documentation + RFE]: CBT incremental backup copy size is the peak dirty volume since the last checkpoint, not the logical change; destination sizing is undocumented and no pre-copy dirty-set size is exposed

## What this is, in one paragraph

An incremental backup copies far more than the data that changed in the guest: it copies every block
that was *written* since the previous backup — including blocks belonging to files that were written and
then deleted before the backup ran. So a ~3 GiB change measured by the guest produced a 61.2 GiB backup
in one run and 68 GiB in another (about 20×), because 60–66 GiB of files had been written and deleted in
between. Nothing in the product or its documentation says a destination must be sized to that peak
written volume rather than to the logical change, so a destination sized for "a 3 GiB change" ran out of
space mid-copy. The behaviour is **correct by design** for restore consistency (both runs' restores
verified with zero failures) — what is missing is the sizing rule and any way to see the copy size before
it starts.

**When → then → expected**

- **When** the product is taking an incremental CBT backup for a VM whose tracker holds a checkpoint —
  CBT: the change-tracking backup mode where each backup copies only blocks dirtied since the checkpoint
  its *bitmap* (the per-disk change-tracking map inside the running VM's QEMU) is based on.
- **And** the disruption `DIRTY_BLOCK_CHURN` (not a chaos primitive and not a krknctl scenario: it is
  this scenario's own guest-side churn script, `cbt-chaos/scenarios_v2/CBT-F-04/guest-churn.sh`, run
  under the CBT-F-04 chaos scenario's Leg 3) is applied: **inside the guest, write a large body of files
  and delete them again between two checkpoints**, leaving the on-disk live data small. Recorded (r04):
  60 GiB / 64,424,509,440 bytes written and deleted 16:14:17–16:16:29Z, guest left at 11G used / 67G
  free. Then make a small live change (~3 GiB) and run the incremental on a destination sized near that
  change (r03: 30 Gi — fails) or generously (r04: 100 Gi — succeeds).
- **Then (current behaviour):** the incremental copies the whole dirty set — 68 GiB in r03, 61.2 GiB /
  65,676,509,184 bytes in r04 — for a ~3 GiB logical change (~20–23×). With a 30 Gi destination it fills
  the volume and ends `Done=True` with reason `Backup has failed: No space left on device` after 29 GiB
  were written; nothing warned beforehand, and no status field exposes a dirty-set or copy size.
- **Expected behaviour:** documentation and API guidance state that incremental copy size is bounded by
  the peak dirty volume since the merge-base checkpoint (write-then-delete churn called out explicitly)
  and that destinations must be sized accordingly — or the product exposes a dirty-set size estimate
  before the copy starts, so an undersized destination is rejected up front instead of failing mid-copy.

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
>
> **Extraction note.** This file is the ticket draft formerly embedded in
> `cbt-chaos/scenarios_v2/CBT-F-04/analysis/20261015-cbtf04-r04-product-flow.md` §4 ("Final
> engineering-ticket draft (supersedes r03 Draft 1; file from both run labels)"), re-rendered onto this
> template with every claim, quoted string, artifact path and UTC preserved. It **supersedes** the
> earlier draft in `analysis/20261015-cbtf04-r03-product-flow.md` §4 Draft 1, which is materially the
> same contract gap; the r03 file was therefore **not** duplicated into `bugs/` — the r03 run is carried
> here as the first of the two observations below. Paths given without a prefix are relative to
> `cbt-chaos/scenarios_v2/CBT-F-04/`.

## At a glance

| Field | Value |
|---|---|
| Issue type | **Contract clarification / Documentation, with an RFE component** (pre-copy dirty-set size / admission-time capacity check) — **NOT a Bug claim**: the behaviour is correct by design and restore-verified in both runs. |
| Priority (proposed) | Unassigned pending triage (proposed **medium**: a customer-visible capacity-failure mode with no sizing guidance; ~20× copy amplification demonstrated twice). |
| Severity class | performance / capacity (copy size and destination sizing), with a documentation gap |
| Owning component (suspected) | **suspected** KubeVirt/OpenShift Virtualization CBT backup (incremental copy sizing, `VirtualMachineBackup` spec/status, and docs). |
| Component(s) proven involved | the QEMU dirty-bitmap path in the launcher (the copy demonstrably used the full checkpoint as its bitmap base and copied the dead blocks), and the backup API/status surface (no size-related field on either the successful or the failed object). |
| Reproducibility | `deterministic (2/2 run labels that measured a copy size)` — `20261015-cbtf04-r03` (accidental churn) and `20261015-cbtf04-r04` (deliberate, spec-directed churn), each with rbd-usage + `qemu-img` physical evidence and a restore-verified chain. Run `20261015-cbtf04-r02` is non-contradicting only: its incremental fit its 30 Gi destination and no copy-size measurement was captured. |
| Status / confidence | **Filed per the reproduction rule: two clean observations across two run labels.** The behaviour is data-correct in both and the semantics are **[INFERENCE] at the code level** (the dirty bitmap marks blocks on write and never un-marks them on deletion) — the arithmetic matches exactly in both runs, but no instrumentation proves the mechanism. Certain from artifacts: the copied byte counts, the destinations' usage, the rbd-usage figures, the ENOSPC failure on the undersized destination, and the zero-failure restores. |
| Blast radius | per-VM, per backup: the destination volume's capacity and the backup window. Not cluster-wide; no other object is affected. |
| Data at risk? | **No** — the copy is conservative and both runs' cumulative-chain restores matched the guest manifests (0 failed restore, 0 failed hash checks). The risk is operational: failed backups on undersized destinations, wasted capacity and time, and unexpected storage consumption for small logical deltas. |
| Related scenario / execution | CBT-F-04 Leg 3 (dirty-block), runs `20261015-cbtf04-r03` and `20261015-cbtf04-r04`, both 2026-10-15 (UTC). Run `20261015-cbtf04-r02` (same day) is non-contradicting only. |
| Affected versions | r04: OpenShift 4.22.15 (krkn live capture), ODF 4.22.5 (StorageCluster `ocs-storagecluster`), storage `ocs-storagecluster-cephblockpool` (RBD), guest RHEL 9. r03: versions `not recorded` (only the virt-controller image digest `sha256:23e9322e…` was captured). The full measured matrix is in **Environment** below. |

## Context (for an engineer new to this area)

**What the feature does.** An incremental CBT backup copies the blocks that changed since the checkpoint
its dirty bitmap is based on, into a destination volume that is hotplugged into the running VM for the
copy. The tracker (`VirtualMachineBackupTracker`) holds the chain's latest checkpoint so the next
backup can build on it.

**Where the gap sits.** In the backup API and documentation. The copy size is bounded by the **peak dirty
volume since the merge-base checkpoint** — every block ever written in that window, including blocks
whose files were deleted before the backup ran. Nothing observed in the API surface or docs states that,
and no field surfaces a dirty-set or expected copy size before the copy starts. The only signal a user
gets is the kernel's ENOSPC ("no space left on device") mid-copy.

**Observed surface vs. origin.** The user sees the destination volume fill up and the backup's reason
string say `Backup has failed: No space left on device`. What caused the size was guest write behaviour
between checkpoints, which no product surface reports.

**Why it matters.** Capacity planning for incremental backups is guesswork. Sizing to the logical change
is the natural reading — and it fails mid-copy, after writing as much as the volume holds, forcing a
retry on a larger volume. Conversely, correctly sized destinations silently consume churn-scale storage
for small deltas, which surprises both backup windows and budgets.

**Deliberate scope note.** This ticket makes **no defect claim**: the copies were data-correct in both
runs, and block-level restore consistency requires copying blocks that differ from the base image (a
deleted file's blocks do differ). The ask is the sizing rule and a pre-copy signal, not a change to the
copy semantics.

## Environment (measured, not assumed)

Per-run provenance is called out in the last column: `r03` (accidental churn) and `r04` (deliberate
churn) are the two observations; either is what makes a layer measurable. `not recorded` means nothing
captured it (never inferred). Node names are genericised as `<node>`.

| Layer | Component | Version / identifier | How obtained | Provenance |
|---|---|---|---|---|
| Platform | OpenShift Container Platform (server and `oc` client) | r03: `not recorded` (the run captured no cluster version — no `oc version`/`clusterversion` output in its pack). r04: **4.22.15** via the krkn live capture in `trigger/trigger.log` (`cluster_version`); the same cluster measured on 2026-10-16 reports 4.22.15 server+client with kustomize v5.7.1 | `trigger/trigger.log` (r04); `oc version`, `oc get clusterversion version` | r04 + `cluster 2026-10-16`; r03 `not recorded` |
| Platform | Kubernetes API | v1.35.6 | `oc version` | `cluster 2026-10-16` |
| Platform | OpenShift update channel | `not recorded` — never captured | `oc get clusterversion version -o jsonpath='{.spec.channel}'` (not run) | `not recorded` |
| Platform | `oc`/`kubectl` plugin versions | `not recorded` — never captured | `oc plugin list` (not run) | `not recorded` |
| Nodes | OS image | Red Hat Enterprise Linux CoreOS 9.8.20260915-0 (Plow) | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | kernel | 5.14.0-687.48.1.el9_8.x86_64 | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | container runtime | cri-o 1.35.8-11.rhaos4.22.giteaf45bc.el9 | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | topology / node in scope | one worker ran each CBT VM and its launcher (`<node>`); r04's VM node is recorded in its VMI snapshots, and the storage pool node is the same worker | run VMI snapshots | r03/r04 |
| Virtualization | CNV / HCO CSV | `kubevirt-hyperconverged-operator.v4.22.12`; r03 captured only the virt-controller **pod label** `app.kubernetes.io/version=4.22.12` and image digest `sha256:23e9322e…` (tag not captured); r04's preflight records the ODF stack as **4.22.5** | pod labels/digests in the run packs; `oc get csv -A` | r03 (label/digest) + r04 (ODF) + `cluster 2026-10-16` (CSV) |
| Virtualization | kubevirt observed version | `status.observedKubeVirtVersion` = virt-operator image digest `sha256:2f654df4f4b026b85abc62bfe834a842b3a49b054f97a5999a85443320a29293` | `oc get kubevirt -n openshift-cnv -o jsonpath='{.status.observedKubeVirtVersion}'` | `cluster 2026-10-16` |
| Virtualization | virt-launcher image digest | `not recorded` for both runs (the launcher spec was not among the saved artifacts) | `oc get pod <launcher> -o jsonpath='{.spec.containers[*].image}'` (not run) | `not recorded` |
| Virtualization | virt-controller image digest | r03: `registry.redhat.io/container-native-virtualization/virt-controller-rhel9@sha256:23e9322e…` (**load-bearing**: this is the component whose status/docs surface is the subject of the RFE); r04: `not recorded` | pod spec/digest recorded in the r03 analysis from the run's pod snapshot | r03 |
| Virtualization | libvirt / QEMU / QEMU API in the launcher | `not recorded` for both runs; the cluster's launcher images report libvirt 11.10.0 / QEMU 10.1.0 / QEMU API 11.10.0 — **load-bearing**, because the dirty bitmap lives in QEMU and its semantics are what this ticket documents | `virsh version` in the launcher's `compute` container | `not recorded` (runs) / `cluster 2026-10-16` |
| Backup API | CRD group / version | `backup.kubevirt.io/v1alpha1` (`VirtualMachineBackup`, `VirtualMachineBackupTracker`) | watched objects in the run packs | r03/r04 |
| Storage (**in use**) | StorageClass + provisioner + pool | ODF / Ceph RBD — r03 destinations: a 30 Gi volume that filled to 29 GiB and a 100 Gi volume that took 68 GiB; r04 destination: a pre-sized 100 Gi `INCREMENTAL_PVC_SIZE` volume on the RBD block pool `ocs-storagecluster-cephblockpool` (StorageCluster `ocs-storagecluster`) | `rbd du` captures in each run's `recovery/`; r04's preflight/spec agreement | r03/r04 |
| Storage (**in use**) | CSI driver image + version | `not recorded` — the runs name the driver/pool, not its image digest | `oc get ds` in the CSI namespace (not run) | `not recorded` |
| Storage (**in use**) | backing device / free space / usage at the time | r03: destination usage 68 GiB on the 100 Gi volume (rbd du) and 29 GiB written on the 30 Gi volume before ENOSPC; r04: rbd du 61 GiB used on the 100 Gi volume (~61 % utilisation) — an 80Gi-style default would have been marginal-to-insufficient (~76 % of the copy) | `recovery/rbd-du-retry5.txt`, `recovery/rbd-du-backup-volumes.txt` (r03); rbd du + `observer/evidence-terminal/pvc-incremental-terminal.yaml` (r04) | r03/r04 |
| Storage (**in use**, adjacent) | ODF/OCS operators, Ceph image, health | `4.22.5-rhodf` operators (`odf-operator`, `ocs-operator`, `rook-ceph-operator`, `cephcsi-operator`, `mcg-operator`, `odf-csi-addons-operator`, external-snapshotter); RHCS 9 Ceph image `sha256:926d15fddae065a1e82b3634f80847253fa2cc14e9888e15b19b72a2cf144a58`; cluster health `HEALTH_OK` | `oc get csv -n openshift-storage`, `oc get cephcluster` | `cluster 2026-10-16` (r04 preflight: ODF 4.22.5) |
| Storage (**present but NOT exercised**) | HostPathProvisioner / hostpath CSI | StorageClass `cbt-demo-hpp`, provisioner `kubevirt.io.hostpath-provisioner`, pool `cbt-demo-pool`, DaemonSet `hostpath-provisioner-csi` (ns `openshift-cnv`), image `…/hostpath-csi-driver-rhel9@sha256:72cdfd4ab6621148bf2a70485394d335d9ccc5045ab0aa82018e72472444bf6b`, `VERSION=v4.22`, data dir `/var/hpvolumes/csi` — installed, **not exercised by this scenario** (every CBT-F-04 volume is ODF/Ceph RBD) | `oc get sc`, `oc get ds hostpath-provisioner-csi -n openshift-cnv` | `cluster 2026-10-16` |
| Storage (**present but NOT exercised**) | local-storage-operator | `local-storage-operator.v4.22.0-202609291750` — installed, not exercised | `oc get csv -A` | `cluster 2026-10-16` |
| Guest | OS release | RHEL 9 (both runs) | run reports/analyses | r03/r04 |
| Guest | kernel | `not recorded` for both runs — no in-guest `uname -r` in either pack | `uname -r` in the guest (not run) | `not recorded` |
| Guest | guest agent package version | `not recorded` for both runs | `rpm -q qemu-guest-agent` (not run) | `not recorded` |
| Guest | vCPU / memory | `not recorded` — not captured | VM spec vs `nproc` / `free` (not run) | `not recorded` |
| Guest | disks / filesystem | r03 and r04 both backed up a ~78 Gi root disk (`rootdisk`/`vda`); r03's failed attempt 1 filled the guest (`df`: 77G/77G, 100%) before the churn was cleaned up; r04's post-churn guest state 11G used / 67G avail | `guest-state-post-failure.txt` (r03), `recovery/churn.log` (r04) | r03/r04 |
| Guest | workload / churn used (context) | r03: attempt-1 mutation intended 1,000 × 1,024 MiB against an 80 Gi root disk and ran `09:49:57→10:29:16Z`, killed by guest ENOSPC after 66 × 1 GiB files were written and `mv`-ed into place; those files were then deleted by the harness (the accidental write-then-delete cycle). r04: deliberate 60 GiB (64,424,509,440 B) written and deleted by `guest-churn.sh` | run analyses; `trigger/churn-record.json` (r04) | r03/r04 |
| Harness (internal only) | workflow + trigger checksum | `virt-cbt-lab`; per-run trigger sha256 from each run's own pack: r03 `a214796df0d0395833f23d9de07ef9d5a7888d5d1fcbef7bb4779926488d837b` (`runs/20261015-cbtf04-r03/preflight.json`), r04 `92f7bf6a3dcb21b570008e7f9a79b41d1afad074497ef819916ea3116e8417` (`runs/20261015-cbtf04-r04/preflight.json`) | run `preflight.json` | r03/r04 |

**Load-bearing rows.** QEMU/libvirt and the virt-controller revision matter: the dirty-bitmap semantics
live in QEMU (the cluster's launcher images report libvirt 11.10.0 / QEMU 10.1.0, but neither run
captured its own launcher's versions), and the API/documentation surface being asked for lives in the
controller. Both are `not recorded` for the runs themselves — a reproducer should capture them.

## Reproducibility

- **Classification**: `deterministic (2/2 run labels that measured a copy size)` — the effect appeared
  in both run labels that captured physical copy evidence, with complementary provenance:
  `20261015-cbtf04-r03` (accidental churn) and `20261015-cbtf04-r04` (deliberate, spec-directed churn).
  `20261015-cbtf04-r02` is **non-contradicting only**: its incremental fit its 30 Gi destination and no
  copy-size measurement was captured.
- **Attempts**: 3 run labels on 2026-10-15, all by the scenario's own workflow/harness on one
  cluster/build (reporter only, no independent observer). r03 needed three attempts on the same run to
  reach a successful incremental (retry-3 failed on capacity, retry-5 succeeded); r04's run-of-record
  attempt succeeded on a pre-sized destination after an earlier attempt failed for a harness reason
  (below).
- **Stability — exact**: the arithmetic of the copy in both runs — dead volume written between
  checkpoints + small live mutation − block overlap + metadata — and the consequences (undersized
  destination fails loudly mid-copy; correctly sized destination absorbs the dirty set; chain restore
  verifies with zero failures). **Varies**: how the write-then-delete cycle came about (accidental in
  r03, deliberate in r04), the exact copied byte counts (68 GiB vs 61.2 GiB), and the destination sizes
  used.
- **Preconditions**: (a) CBT enabled with an existing checkpoint (a tracker holding one); (b) a large
  body of data written **and deleted** in the guest between that checkpoint and the incremental;
  (c) a small live change so the logical delta is small; (d) a destination sized near the logical change
  (to see the failure) or sized to the dirty set (to see the amplification without failure).
- **Second entry path**: not applicable — the mechanism is one path (dirty-bitmap accumulation) reached
  with two different provenances of the churn. There is no second fault path, because this ticket makes
  no fault claim.

## Steps to reproduce (exact commands and injection timing)

> Everything below uses the **recorded names of run `20261015-cbtf04-r04`** (namespace `vm-cbt-demo`)
> with the r03 failure variant called out where it differs, so each command can be compared with this
> ticket's evidence. For a fresh reproduction pick your own run-scoped names. Every command is scoped to
> one named object. Reproduce on a dedicated cluster: the churn writes tens of GiB into a guest and the
> destinations are large. Repository helper (optional accelerator, never required):
> `cbt-chaos/scenarios_v2/CBT-F-04/chaos-trigger.sh` (Leg 3) and
> `cbt-chaos/scenarios_v2/CBT-F-04/guest-churn.sh` (the churn itself).

### Concrete objects used in this report

| Kind | Name | UID | Created (UTC) | Fate |
|---|---|---|---|---|
| VirtualMachine / VMI (r04) | `vm-20261015-cbtf04-r04` | `not recorded` | 2026-10-15 ~15:5xZ (full-backup window) | kept; Running, CBT `Enabled` |
| Pod (launcher, r04) | `virt-launcher-vm-20261015-cbtf04-r04-hh9q6` | ce095793-ecb6-405d-873d-7096bbd8c9ed | ~15:55Z | kept; 2/2 Running, 0 restarts; log lines `Backup started` 15:55:39.288849Z and `Backup has been completed successfully` 15:56:43Z |
| VirtualMachineBackupTracker (r04) | `vm-tracker-20261015-cbtf04-r04` | 5c4de4c0-e6cc-4090-86c7-697dad2c0266 | `not recorded` | kept; null → full checkpoint, then one advance to the incremental's child |
| VirtualMachineBackup (full, r04) | `vm-backup-20261015-cbtf04-r04`; checkpoint `vm-backup-20261015-cbtf04-r04-2026-10-15_15-55-29` | `not recorded` | 15:55Z (checkpoint 15-55-29) | kept; `Done=True` `Successfully completed VirtualMachineBackup` 15:57:09Z (74 s) — **the bitmap base for the incremental** |
| PVC (full destination, r04) | recorded as the run's full-backup destination; exact name `not recorded` in the local pack | `not recorded` | 15:55Z | kept |
| PVC (incremental destination, r04) | `vm-incremental-pvc-20261015-cbtf04-r04-p01` (100 Gi requested via `INCREMENTAL_PVC_SIZE=100Gi`) | `not recorded` | 16:28Z | kept, `Bound` 100Gi/100Gi; absorbed the 61.2 GiB copy at ~61 % utilisation |
| VirtualMachineBackup (incremental, r04) | `vm-incremental-20261015-cbtf04-r04-p01`; checkpoint `vm-incremental-20261015-cbtf04-r04-p01-2026-10-15_16-28-43` | 053d0ac2-6fac-4961-a33e-96453a2dcac4 | 16:28:43Z | kept; copy 16:28:49.759446Z → 16:29:43.159444Z (~54 s), `Done=True` `Successfully completed VirtualMachineBackup` 16:29:43Z |
| Guest churn record (r04) | 60 GiB / 64,424,509,440 bytes written then deleted | — | 16:14:17–16:16:29Z | files deleted in-guest; the write is what the copy had to carry |
| r03 run (first observation) | VM `vm-20261015-cbtf04-r03`; tracker `vm-tracker-20261015-cbtf04-r03` (UID 4e362574-dee7-4fec-bb8d-1ba46f814f02); full checkpoint `…-09-14-05` (`Done=True` 09:15:15Z); failing incremental `vm-incremental-20261015-cbtf04-r03-p01` (UID f71e404c-c817-489b-ac39-7e38a007aed8, checkpoint `…-10-35-19`, 30 Gi destination, filled to 29 GiB, `Done=True` + reason `Backup has failed: No space left on device` 10:35:56Z); succeeding retry `…-p01` on a 100 Gi destination (checkpoint `…-10-49-06`, `Done=True` 10:50:14Z) | see left | 09:14–10:50Z | kept; the failed backup CR was later deleted (Lead-approved, ~10:41Z) so the object name could be reused |
| Preserved artifacts | `runs/20261015-cbtf04-r03/recovery/{rbd-du-retry5.txt, rbd-du-backup-volumes.txt, qemu-img-preserved-artifacts.txt, qemu-img-post-retry3.txt, guest-state-post-failure.txt, incremental-backup-post-retry3.yaml, tracker-post-retry3.yaml, done.json}`; `runs/20261015-cbtf04-r04/{trigger/churn-record.json, recovery/churn.log, recovery/qemu-img-preserved-artifacts.txt, recovery/summary.json, recovery/done.json, recovery/tracker-pre-incremental.yaml, recovery/tracker-post-incremental.yaml, recovery/checkpoint-tree.txt, observer/evidence-terminal/launcher-backup-log-lines.txt, observer/evidence-terminal/pvc-incremental-terminal.yaml}`; each run's `evidence-index.json` (r03: 68 files; r04: 64 files, sha-pinned at run close) | — | run close | retained (destinations and artifacts kept for measurement) |

### Steps

**Step 1 — Setup: CBT-enabled VM with a checkpoint to build on.** When: before the churn.
```bash
oc get vmi vm-20261015-cbtf04-r04 -n vm-cbt-demo \
  -o jsonpath='{.status.phase}{" "}{.status.changedBlockTracking.state}{"\n"}'
oc get vmbackuptracker vm-tracker-20261015-cbtf04-r04 -n vm-cbt-demo \
  -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'
```
What you must see: VMI `Running` with CBT `Enabled`, and a tracker holding one checkpoint (r04:
`vm-backup-20261015-cbtf04-r04-2026-10-15_15-55-29`). If the tracker is empty, take a full backup first —
**that full backup's checkpoint is the bitmap base the incremental will use.**

**Step 2 — (Injection) Write then delete a large body of data inside the guest.** When: after the full
checkpoint exists and before the incremental is created — this is the whole setup that matters, and its
timing is what makes the copy huge. Recorded (r04): 16:14:17–16:16:29Z, 60 GiB / 64,424,509,440 bytes.
```bash
# spec-directed churn: writes deterministic files into the guest root disk and deletes them again
CHURN_BYTES_GIB=60 cbt-chaos/scenarios_v2/CBT-F-04/guest-churn.sh    # names the run's own helper
# verify inside the guest: the data is gone, the disk is mostly free again
#   guest: df -h / ; ls -l <workload dir>
oc get vmbackup -n vm-cbt-demo --sort-by=.metadata.creationTimestamp \
  -o custom-columns=NAME:.metadata.name,CHECKPOINT:.status.checkpointName
```
**Window/injection point: it opens at the first write after the checkpoint and closes when the churn
files are deleted; no chaos is required.** Fail-closed pre-check: the guest had free space for the churn
and the tracker still holds the intended checkpoint. Post-check: the guest reports the freed space (r04:
11G used / 67G avail in `recovery/churn.log`) and the recorded byte count is in `trigger/churn-record.json`.

**Step 3 — Make a small live change and create the incremental on a destination sized near that change.**
When: after the churn has been deleted (this is the r03 failure variant; r04 instead pre-sized the
destination to 100 Gi and saw the amplification without a failure).
```bash
# create ~3 GiB of new guest files (r04: 2 files added = 2,147,483,648 B + 1 modified)
oc apply -f - <<'YAML'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-incremental-20261015-cbtf04-r04-p01
  namespace: vm-cbt-demo
spec:
  pvcName: vm-incremental-pvc-20261015-cbtf04-r04-p01
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261015-cbtf04-r04
YAML
oc get vmbackup vm-incremental-20261015-cbtf04-r04-p01 -n vm-cbt-demo -o yaml | grep -A12 '^status:'
```
What you must see: either a success on a big destination, or — with a destination sized to the logical
change, as in r03's 30 Gi volume — the copy filling the volume and the backup ending `Done=True` with
reason `Backup has failed: No space left on device` (r03: after 29 GiB written, at 10:35:56Z) and the
tracker **not** advancing.

**Step 4 — Read-only demonstration: measure what was actually copied.** When: after the incremental
reaches a terminal state.
```bash
# 4a. the copy's physical size on the destination volume (r04: 61 GiB used of 100 GiB)
oc debug node/<node> -- chroot /host bash -c 'rbd du <rbd-image-of-the-destination>'   # or the provider's own tool
# 4b. the artifact's own shape: disk size vs the live source disk it points back at
oc debug node/<node> -- chroot /host bash -c \
  'qemu-img info <destination-path>/vm-incremental-20261015-cbtf04-r04-p01-rootdisk.qcow2'
# 4c. the copy really was generated from the full checkpoint (the bitmap base spans the churn)
oc logs virt-launcher-vm-20261015-cbtf04-r04-hh9q6 -n vm-cbt-demo -c compute \
  | grep -E 'Backup started|from checkpoint|completed successfully'
# 4d. compare against the logical change reported by the guest workload
```
What you must see: destination usage far above the logical change (r04: `61 GiB` used, artifact
`disk size 61.2 GiB (65,676,509,184 bytes)`, `backing file` → the live rootdisk, `corrupt=false`; r03:
68 GiB / 67.7 GiB for the same ~3 GiB delta) and a `Backup started`/`from checkpoint` line naming the
**full** checkpoint, not the last one created.

**Step 5 — Prove the copy was nevertheless data-correct (so triage does not mistake this for corruption).**
When: after step 4.
```bash
oc get vmbackup vm-incremental-20261015-cbtf04-r04-p01 -n vm-cbt-demo \
  -o jsonpath='{.status.type}{" "}{.status.conditions[?(@.type=="Done")].reason}{"\n"}'
# then restore the cumulative chain and compare manifests (recorded: 10 files / 10,737,418,240 B,
# SHA-256 manifest match, 0 failed restore and 0 failed hash checks)
```
What you must see: type `Incremental`, the success reason, and a manifest-matching restore. If the
restore were **not** matching, this ticket's whole framing would change — it would become a corruption
ticket instead of a sizing/documentation one.

**Step 6 — Recovery / workaround.** When: after capturing the evidence.
```bash
# size incremental destinations to the expected peak written volume (or tracked-disk capacity):
#   r04 used INCREMENTAL_PVC_SIZE=100Gi for a 61.2 GiB copy
# after large write-then-delete churn, either expect a churn-sized incremental, or reset the chain:
oc delete vmbackuptracker vm-tracker-20261015-cbtf04-r04 -n vm-cbt-demo   # next backup falls back to Full
```
What you must see: the retry/replacement incremental completes on the larger destination. What this does
**not** give back: the wasted copy time and space of the oversized incremental, and the "cheap
incremental" you were expecting — after churn, an incremental approaching the churn volume is normal.

## Current behaviour (observed)

Across two independent runs, an incremental CBT backup physically copied the entire write-then-delete
churn volume between checkpoints, not the live-data delta: **r03 copied 68 GiB** (rbd du; artifact qcow2
67.7 GiB) and **r04 copied 61.2 GiB** (65,676,509,184 B artifact qcow2 disk size; rbd du 61 GiB) — each
for a **~3 GiB logical mutation** (~20–23× amplification). In r04 the churn was deliberate and exact:
60 GiB (64,424,509,440 bytes) written then deleted between the full checkpoint and the incremental, guest
left at 67G free. Change tracking marks blocks dirty on write and never un-marks them on deletion, so the
incremental must copy data that is already dead at backup time. This is correct-by-design for block-level
restore consistency (deleted blocks differ from the base image; deletion churns FS metadata); both runs'
cumulative-chain restores matched the guest manifests with 0 failed restore and 0 failed hash checks. But
the observed API surface and documentation give no warning that incremental destination capacity must be
sized to the *peak dirty volume since the last checkpoint* — a quantity with no relation to logical
change and no observable bound short of tracked-disk capacity. r03 demonstrated the customer failure
mode: a 30 Gi destination sized for a "3 GiB change" failed mid-copy with ENOSPC after writing 29 GiB.
r04 demonstrated the sizing rule empirically: the pre-sized 100 Gi destination absorbed the 61.2 GiB
copy; an 80Gi-style default would have been marginal-to-insufficient (~76 % of the copy). No dirty-set
size is surfaced before or during the copy (no size-related status field on the failed r03 CR), so the
mismatch is discoverable only by kernel ENOSPC mid-copy.

Restated as the draft recorded it, per run:

- **r03** (`20261015-cbtf04-r03`, ns `vm-cbt-demo`, tracker `vm-tracker-20261015-cbtf04-r03`): full
  checkpoint 09-14-05 (`Done=True` 09:15:15Z); ~66 GiB dead writes (66 × 1 GiB files from a failed
  mutation attempt, deleted before retry); retry-3 incremental `vm-incremental-20261015-cbtf04-r03-p01`
  on a 30 Gi destination filled to 29 GiB and ended `Done=True` / "Backup has failed: No space left on
  device" at 10:35:56Z, tracker unchanged; retry-5 on a 100 Gi destination completed 10:50:14Z copying
  **68 GiB** for ~3 GiB logical; chain restore 10 files / 10,737,418,240 B manifest match, 0 failures.
- **r04** (`20261015-cbtf04-r04`, ns `vm-cbt-demo`, tracker `vm-tracker-20261015-cbtf04-r04` UID
  5c4de4c0-e6cc-4090-86c7-697dad2c0266): full checkpoint 15-55-29 (`Done=True` 15:57:09Z); deliberate
  churn 60 GiB / 64,424,509,440 B written and deleted 16:14:17–16:16:29Z (`trigger/churn-record.json`);
  incremental `vm-incremental-20261015-cbtf04-r04-p01` (UID 053d0ac2-6fac-4961-a33e-96453a2dcac4) on a
  pre-sized 100 Gi destination copied **61.2 GiB (65,676,509,184 B)** in ~54 s for ~3 GiB logical
  (2,147,483,648 B added + 1 modified); rbd du 61 GiB used; restore 0 failed checks (full-only 8 files /
  8,589,934,592 B; cumulative 10 files / 10,737,418,240 B, SHA-256 manifest match).

**Decisive verbatim string:** `Backup has failed: No space left on device` (r03's failed-incremental
reason, `incremental-backup-post-retry3.yaml`). All byte counts, usage figures and restore results above
are independent artifact observations from the runs' `recovery/` and `observer/` captures.

## Expected behaviour (contract)

Documentation and API guidance state that incremental copy size is bounded by peak dirty volume since
the merge-base checkpoint, and that destinations must be sized accordingly (or the product exposes a
dirty-set size estimate before the copy).

**Acceptance check.** A customer following documented sizing guidance for a write-then-delete workload
between checkpoints does not hit mid-copy ENOSPC: they size the destination to the peak written volume
(or the product rejects the backup up front with a capacity message), and the backup neither fills the
destination nor reports a capacity failure.

**Acceptance criteria (from the reporter draft, preserved):**

- Documented sizing rule for incremental destinations expressed in terms of dirty volume since the last
  checkpoint (write-then-delete churn called out explicitly).
- If implemented: an exposed pre-copy dirty-set size or admission-time capacity check that rejects an
  incremental whose dirty set exceeds the destination, before any bytes are copied.

## Impact, workaround and data safety

- **Functions lost / how an operator notices.** Nothing is corrupted; what fails is a backup that was
  sized by the wrong mental model. The operator sees a mid-copy ENOSPC on the backup object (a loud,
  correct failure — r03: after 29 GiB written, tracker untouched) and must retry on a larger volume. On
  the other side, a correctly sized destination unexpectedly consumes churn-scale capacity for a small
  logical delta (r04: 61.2 GiB for ~3 GiB), which shows up as backup-window and storage-cost surprise.
- **Blast radius.** Per VM and per backup: the destination volume's capacity and the copy window. No
  other object or subsystem is affected; no cluster-wide effect.
- **Data safety.** **Not at risk** — this is the point of the ticket: the conservative copy is what makes
  the chain restore correctly (0 failed restore and 0 failed hash checks in both runs). A Bug claim would
  be misfiled even with two reproductions.
- **Workaround / operator runbook.** (a) Size incremental destinations to the **expected peak written
  volume** since the last checkpoint, bounded by tracked-disk capacity (a 78 Gi disk can dirty up to
  ~78 GiB per interval; 61.2 GiB was ~76 % of an 80Gi default). (b) After large write-then-delete churn
  (temp files, scratch builds, DB rebuilds), either expect an incremental approaching the churn volume
  or take a fresh full backup to reset the dirty set. (c) Plan for the retry when an undersized
  destination fails: the failure is loud and the tracker does not advance, so a retry on a bigger volume
  is safe. Nothing here is a product fix; it is capacity planning around an undocumented rule.
- **Frequency.** Deterministic whenever the guest writes and deletes large data between checkpoints —
  i.e. routine for any workload with temp files, builds, or database rebuilds. The amplification is
  bounded only by the tracked disk size.
- **Unknowns this ticket deliberately does not claim.** Whether a dirty-set size is knowable before the
  copy starts (the RFE's core question); whether guest TRIM/discard (`fstrim`) shrinks the dirty set on
  this path (a hypothesis, untested in both runs); the exact bitmap merge semantics at code level; and
  whether the documentation gap exists in all supported versions or only in the observed ones.

## Evidence

**Artifact index.** Paths are as the analyses/drafts record them, relative to
`cbt-chaos/scenarios_v2/CBT-F-04/`. Each run's full root is sha-pinned in its `evidence-index.json`
(r03: 68 files, generated 2026-10-15T12:15:37Z; r04: 64 files, generated 2026-10-15T17:49:49Z); the raw
`recovery/`/`observer/` files live in the run root, while this checkout carries the pack metadata,
reports and analyses.

| Artifact | What it carries | UTC | Type |
|---|---|---|---|
| `runs/20261015-cbtf04-r04/trigger/churn-record.json` | the deliberate churn: exact bytes written/deleted and their times (60 GiB / 64,424,509,440 B, 16:14:17–16:16:29Z) | 16:14–16:16Z | raw |
| `runs/20261015-cbtf04-r04/recovery/churn.log` | post-churn guest state (`df` → 11G used / 67G avail) — the dead data is gone before the backup | 16:16Z | raw |
| `runs/20261015-cbtf04-r04/recovery/qemu-img-preserved-artifacts.txt` | artifact shapes: full 78.1 GiB / incremental **61.2 GiB (65,676,509,184 B)**, `backing file` → live rootdisk, `corrupt=false` | 16:29–16:40Z | raw |
| `runs/20261015-cbtf04-r04/observer/evidence-terminal/launcher-backup-log-lines.txt` | copy window and bitmap base: `Backup started` 16:28:49.759446Z → 16:29:43.159444Z (~54 s), generated from the full checkpoint | 16:28–16:29Z | raw |
| `runs/20261015-cbtf04-r04/observer/evidence-terminal/pvc-incremental-terminal.yaml` | the pre-sized 100 Gi destination, `Bound` 100Gi/100Gi — the empirical sizing result | 16:29Z | raw |
| `runs/20261015-cbtf04-r04/recovery/{summary.json, done.json}` | restore verification: full-only 8 files / 8,589,934,592 B; cumulative 10 files / 10,737,418,240 B; 0 failed restore, 0 failed hash checks | 16:29–16:40Z | raw |
| `runs/20261015-cbtf04-r04/recovery/{tracker-pre-incremental.yaml, tracker-post-incremental.yaml, checkpoint-tree.txt}` | tracker held the full checkpoint through the churn, then advanced exactly once to the child checkpoint | 16:1x–16:40Z | raw |
| `runs/20261015-cbtf04-r03/recovery/rbd-du-retry5.txt` | 68 GiB used on the 100 Gi destination for the ~3 GiB logical change | 10:50Z | raw |
| `runs/20261015-cbtf04-r03/recovery/rbd-du-backup-volumes.txt` | both destination volumes' usage (incl. the 30 Gi volume filled to 29 GiB) | 10:3x–10:50Z | raw |
| `runs/20261015-cbtf04-r03/recovery/qemu-img-preserved-artifacts.txt`, `qemu-img-post-retry3.txt` | artifact shapes: full 78.1 GiB (7,732 extents all present); incremental 67.7 GiB, backing file → live rootdisk, `corrupt=false` | 10:5xZ | raw |
| `runs/20261015-cbtf04-r03/recovery/incremental-backup-post-retry3.yaml` | the failed incremental: `Progressing=False` and `Done=True`, both carrying `Backup has failed: No space left on device`, type `Incremental` | 10:35:56Z | raw |
| `runs/20261015-cbtf04-r03/recovery/tracker-post-retry3.yaml` | tracker unchanged after the failure (still the full checkpoint) | 10:35–10:41Z | raw |
| `runs/20261015-cbtf04-r03/recovery/guest-state-post-failure.txt` | the guest at the failed attempt: workload dir 74 entries (8 baseline + 66), `df`: 77G/77G — the accidental churn's origin | 10:29Z | raw |
| `runs/<label>/reports/test-run-report.md`, `test-run-result.md` | run verdicts, the legs' outcomes, and the sizing statements | run window | derived |
| `analysis/20261015-cbtf04-r03-product-flow.md` §2, §4 Draft 1 | the first observation and the **superseded** draft (see the extraction note); its cited artifacts `observer/finding.md` (harness-vs-product classification) and `runs/20261015-cbtf04-r02/recovery/summary.json` (the r02 non-contradiction reference: incremental 1,000 files / 18.28 GiB fit its 30 Gi destination, no copy-size artifact captured) | 2026-10-15 | derived (analysis) |
| `analysis/20261015-cbtf04-r04-product-flow.md` §2, §4, §5 | the second observation, the final draft (this file's source), and the customer sizing guidance reproduced in Impact | 2026-10-15 | derived (analysis) |
| `runs/20261015-cbtf04-r0{3,4}/preflight.json` | GO decisions and per-run trigger sha256 (`a214796d…` r03, `92f7bf6a…` r04) | 09:04:06Z, 15:43:35Z | raw |

**UTC timeline** (setup → precondition → injection → effect → failure → recovery):

| # | Time (UTC), 2026-10-15 | Event | Source |
|---|---|---|---|
| 1 | 15:55:39.288849Z → 15:57:09Z (r04) | Control: full backup completes (`Done=True`, success reason, 74 s); checkpoint `…15-55-29` created — the bitmap base | launcher log lines; `vmbackup-terminal.yaml` |
| 2 | 16:14:17 → 16:16:29Z (r04) | **Injection**: deliberate churn — 60 GiB (64,424,509,440 B) written then deleted inside the guest; guest left 11G used / 67G avail | `trigger/churn-record.json`; `recovery/churn.log` |
| 3 | 16:28:43Z (r04) | Incremental created on the pre-sized 100 Gi destination; copy starts 16:28:49.759446Z **generated from the full checkpoint** | `observer/evidence-terminal/launcher-backup-log-lines.txt` |
| 4 | 16:29:43.159444Z (r04) | **Effect**: copy ends after ~54 s, `Done=True` `Successfully completed VirtualMachineBackup`; physical copy **61.2 GiB (65,676,509,184 B)**, rbd du 61 GiB of 100 Gi | `qemu-img-preserved-artifacts.txt`; `pvc-incremental-terminal.yaml`; tracker files |
| 5 | 16:29:46 → 16:40:14Z (r04) | Restore verification: full-only and cumulative chain match their manifests; **0 failed restore, 0 failed hash** — conservative copy is data-correct | `recovery/summary.json`; `recovery/done.json` |
| 6 | 09:14:05 → 10:35:56Z (r03, first observation) | Accidental churn (~66 GiB dead writes from a failed mutation attempt, then deleted); retry-3 incremental on a **30 Gi** destination fills to 29 GiB and ends `Done=True` + `Backup has failed: No space left on device`; tracker unchanged | `incremental-backup-post-retry3.yaml`; `tracker-post-retry3.yaml`; `guest-state-post-failure.txt` |
| 7 | 10:48:40 → 10:50:14Z (r03) | **Recovery/retry**: same logical change on a 100 Gi destination — `Done=True`, **68 GiB** copied, chain restore 10 files / 10,737,418,240 B with 0 failures | `rbd-du-retry5.txt`; `qemu-img-preserved-artifacts.txt`; `done.json` |

**Retained state.** The runs' objects were preserved for measurement, which is why the byte-level
comparisons exist: the backup CRs, the trackers (r04's showing the single advancement), the destination
PVCs (including r04's 100 Gi volume at 61 % utilisation, and r03's 30 Gi volume still holding the 29 GiB
partial copy), the checkpoint trees, and the guest-state captures. Two deliberate deletions are recorded:
r03's failed backup CR was deleted with Lead approval (~10:41Z) after its evidence was captured, so the
object name could be reused for the retry (the artifacts `incremental-backup-post-retry3.yaml` and
`tracker-post-retry3.yaml` are the retained record); and the guest churn files themselves were deleted as
part of the experiment (that deletion *is* the precondition). The virtual machines were kept.

## Negative results and what would falsify this ticket

- **Refuted: "the copy is a defect/corruption."** Both runs' cumulative-chain restores matched the guest
  manifests with 0 failed restore and 0 failed hash checks; the artifacts report `corrupt=false`. The
  conservative copy is what makes the chain correct — so a Bug claim would be misfiled.
- **Refuted: "the copy used the most recent checkpoint, so the churn should have been excluded."** r04's
  launcher log shows the copy generated from the **full** checkpoint (`…15-55-29`), i.e. its bitmap base
  spans the churn; r03's retry-5 copy demonstrably used the full checkpoint too (it copied the whole
  68 GiB dirty set, not merely post-10-35-19 changes).
- **Refuted: "the failure was caused by the chaos disruption."** All three run labels show the effect in
  the post-chaos recovery sequence, minutes after failover on a settled control plane, with no
  controller-availability dependency; r04's churn and incremental ran 18+ minutes after failover. Ruled
  out also: silent corruption (all restores hash-verified; the one capacity failure was loud).
- **Refuted: "r02 contradicts it."** r02's incremental (1,000 files, ~18.28 GiB payload) fit its 30 Gi
  destination and completed; r02 captured **no** copy-size measurement at all, so it is at most
  non-contradicting.
- **Limits of this evidence (stated, not refuted).** r03's OpenShift/CNV versions were not captured
  (only the virt-controller digest); the incremental chain extent map was not captured read-only in
  either run (chain correctness rests on backing-file metadata, rbd usage and the semantic restore);
  r03's churn was harness-induced while r04's was deliberate (complementary provenances, not two
  identical experiments); the r04 run's first incremental attempt failed for a harness reason and
  contributed no dirty blocks.
- **Falsifiers.** This ticket is wrong, or a non-issue, if any of the following holds:
  1. Documentation already states the peak-dirty-volume sizing rule (then this is only the RFE half).
  2. A future run shows the copy size tracking the logical change rather than the written volume — e.g.
     because guest discards/TRIM let the engine skip freed blocks (untested here).
  3. A pre-copy dirty-set estimate turns out to be unavailable by design **and** capacity failure is
     considered the intended discovery mechanism (then the ask is documentation of that contract only).
  4. The 61.2/68 GiB copies are shown to be explained by something else (e.g. metadata or alignment
     artefacts) rather than retained dirty blocks — the arithmetic fits the dirty-block explanation in
     both runs, but no instrumentation proves it.

## Additional feedback (reporter's notes)

- **Preserved triage questions.** (a) Is a dirty-set size (or estimated copy size) knowable before the
  copy starts, and should it be surfaced in `VirtualMachineBackup` status? (b) Should the docs define
  incremental destination sizing relative to tracked-disk capacity rather than logical change? (c) Does
  guest TRIM/discard (`fstrim`) shrink the dirty set on this path, and should that be recommended?
  (Hypothesis — untested.) (d) Should `vmbackup.status.lastCheckpoint` be populated (r04 observed it
  `null` on both backups while `status.checkpointName` and the tracker carry the identity)?
- **Preserved hypotheses (labelled — not established mechanisms).**
  - **HYPOTHESIS (bitmap semantics — high confidence, not code-verified):** the dirty bitmap marks blocks
    on write and retains them until the next checkpoint merge; file deletion never un-dirties blocks
    (deletion itself dirties FS metadata and possibly the freed blocks). Supported by two independent
    arithmetics: r03 68 GiB ≈ 66 dead + ~3 live; r04 61.2 GiB ≈ 60 dead + ~3 live − overlap.
  - **HYPOTHESIS (copy slightly under the churn+delta sum):** r04's 61.2 GiB < 63 GiB naive sum is
    cluster overlap between churn writes and the modified live file (same 256 KiB clusters rewritten);
    predicts copy size approaches `min(dirty bytes, disk capacity)` monotonically with churn. Testable
    with a churn-only pass (expect ≈ churn volume).
  - **HYPOTHESIS (no preflight sizing):** the copy path has no dirty-set estimation or admission-time
    capacity check; ENOSPC surfaces only from the kernel mid-copy. Supported by the absence of any
    size-related status field on r03's failed CR and by r04's only safeguard being the harness's
    pre-sized destination.
  - **HYPOTHESIS (TRIM interaction):** guest-level discard after file deletion could let the copy engine
    skip or zero-detect freed blocks, shrinking the incremental. Untested in both runs; would change the
    sizing guidance above.
- **Adjacent observations from the same runs, folded here with no separate ticket action** (r04 §3;
  both are single-run-label observations the analysis chose to fold into triage questions rather than
  file):
  - Stale same-second `VirtualMachineBackupFailed` event on a successful backup: at 16:29:43Z the event
    stream carries **both** `VirtualMachineBackupCompletedSuccessfully` and
    `VirtualMachineBackupFailed (VMI backup status was lost)` — the draft's exact rendering of the
    reason, i.e. `Backup has failed: VMI backup status was lost` — for
    `vm-incremental-…-p01` (events watch, count 1), while the terminal object state is `Done=True` with
    the success reason and a distinct child checkpoint. A consumer alerting on that event fires a false
    positive on a successful backup. Single run label (r04); the same string was seen on an unrelated
    backup in the run's pre-run live triage (`scenario-spec.md` §4), which is not run evidence. The
    evidence checker adjudicated it **not** a product failure for r04. Same event-masking class as the
    companion EXP-07 ticket referenced below.
  - `vmbackup.status.lastCheckpoint` is `null` on both r04 backups while `status.checkpointName` is
    populated and the tracker carries the identity — an API asymmetry, not a failure (see triage
    question (d)).
- **Cross-references.**
  - Same folder: `failed-backup-terminates-done-true-with-failure-reason.md` — the complementary
    failure-semantics question from the same run labels (r03's ENOSPC backup settled with `Done=True`
    plus a failure reason). Read together: this ticket is about *how much* gets copied, that one about
    how the outcome is *reported*.
  - Same folder: `hotplugfailed-lstat-on-successful-detach.md` and
    `libvirt-checkpoint-tree-retains-deleted-failed-backup-checkpoint.md` — other findings from the same
    runs.
  - Other scenario: `cbt-chaos/scenarios_v2/CBT-EXP-07/bugs/backup-reports-success-with-no-data-on-target-enospc.md`
    — the ENOSPC-adjacent data-protection defect (a copy that fails for space and still reports
    success). The storage-sizing context overlaps; the defects do not.
  - Source analyses (unchanged apart from the pointer at their head):
    `analysis/20261015-cbtf04-r04-product-flow.md` §2–§6 and
    `analysis/20261015-cbtf04-r03-product-flow.md` §2 (the superseded Draft 1 lives at §4 of the r03
    file).
  - **Separately and clearly labelled — harness/tooling, not this ticket:** r04's first incremental
    attempt failed during initialization because a harness `sed` pipeline left `__INCREMENTAL_BACKUP_PVC__`
    unsubstituted (`PVC … doesnt exist`); it copied nothing and created no checkpoint, so it neither
    reproduced nor contaminated the finding. r03's churn arose from a failed harness workload plan
    (1,000 × 1,024 MiB against an 80 Gi root disk). Both belong to the scenario/harness lane.
- **Customer guidance worth folding into documentation** (from both runs): size incremental
  destinations to the **peak volume written since the last checkpoint**, not to the live-data delta, and
  bounded by tracked-disk capacity; after large write-then-delete churn either expect an incremental
  approaching the churn volume or take a fresh full backup to reset the dirty set; an undersized
  destination fails loudly mid-copy with no pre-copy warning, so plan capacity up front.
- **Environment-specific notes for the next reproducer.** (a) The churn must be **deleted** before the
  backup runs — that is what makes it invisible to the guest and still present in the dirty set. (b) The
  destination must be pre-sized deliberately (record the value); an 80Gi-style default is marginal for a
  ~60 GiB dirty set. (c) Capture the launcher's libvirt/QEMU versions and the virt-controller digest —
  both are `not recorded` for these runs. (d) The extent map (`qemu-img map`) cannot be captured
  read-only while the backing chain resolves to the live launcher disk; expect to prove the chain via
  backing-file metadata, volume usage and the semantic restore instead. (e) Do not read the ENOSPC
  failure as corruption: check the tracker (it must not advance) and re-run on a larger volume.

## Sanitisation checklist

- [x] No credentials, tokens, kubeconfig contents or private keys — none quoted.
- [x] No private hostnames or absolute host paths — cluster node names are genericised as `<node>`; the
      only path-like strings are container/guest-internal locations needed to interpret the artifact
      shapes (destination mount paths, the live `rootdisk.qcow2` backing path), abbreviated as needed.
- [x] No broad selectors (names or run-scoped labels only) — every command is scoped by the run's exact
      VM/backup/tracker/PVC names or by the named destination volume.
- [x] No destructive commands other than the documented, scoped workaround — the only deletions
      described are the churn's own guest-side file deletion (the experiment's precondition), the
      tracker deletion used as the chain-reset workaround (scoped to the run's own tracker, with what it
      does not restore stated), and r03's already-performed, Lead-approved deletion of its failed backup
      CR (recorded as history, not prescribed).
- [x] Commands are the ones actually validated (illustrative ones are labelled) — the churn, backup
      creation and measurement commands are the ones the runs used; the note above the steps says which
      command shapes are re-creations and that the churn is the only "injection".

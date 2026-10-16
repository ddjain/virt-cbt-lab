# [Unresolved question]: libvirt checkpoint tree retains a failed backup's checkpoint after its backup CR is deleted (orphaned entry; tree diverges from CR chain)

## What this is, in one paragraph

Each backup leaves a checkpoint behind inside the running VM's libvirt (the per-VM virtualisation
library that QEMU runs under) — these checkpoints are what later incremental backups measure changes
against. If a backup fails **after** its checkpoint was created and its object is then deleted, the
checkpoint stays behind: the tree of checkpoints still contains an entry for a backup that no longer
exists, and the *next* successful backup's checkpoint hangs underneath that leftover. So anything that
reads the checkpoint tree to work out "which backups form the chain" gets a different answer than the
tracker (the object that remembers the chain's latest checkpoint) and the backup objects do. Nothing
broke in the recorded run — restores verified with zero failures — but the tree is not a faithful
picture of the chain, and nobody has said whether that retention is deliberate.

**When → then → expected**

- **When** the product is managing CBT checkpoints — CBT: the change-tracking backup mode where each
  backup creates a checkpoint that later backups measure the changed blocks against — for a VM whose
  running QEMU holds a checkpoint tree.
- **And** the disruption is applied: **none is required** from the chaos tooling. The recorded sequence
  was: run an incremental whose copy fails **after** its checkpoint is created (the destination filled
  up, ENOSPC), then delete the failed backup object (in the recorded run: at ~10:41Z, Lead-approved,
  after its evidence was captured, so the name could be reused). Recorded objects: the failing backup
  `vm-incremental-20261015-cbtf04-r03-p01` created 10:35:19Z, failed 10:35:56Z, CR deleted ~10:41Z.
- **Then (current behaviour):** the final checkpoint tree is
  `root (09-14-05) → 10-35-19 (orphaned) → 10-49-06 (successful)` — the tree strictly contains the live
  objects (an entry with no backup object and no tracker reference), and the successful incremental's
  checkpoint is nested under the orphan even though its copy used the **full** checkpoint as its bitmap
  base and the tracker advanced full → 10-49-06 directly.
- **Expected behaviour:** clarify the intended semantics — either a deleted backup's checkpoint is
  removed (or reconciled/marked) when its backup object is deleted after failure, or the retention is
  documented as deliberate, including the caveat that the tree cannot be used to derive the live chain.

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
> `cbt-chaos/scenarios_v2/CBT-F-04/analysis/20261015-cbtf04-r03-product-flow.md` §4 ("Draft 3 —
> [Unresolved question]: libvirt checkpoint tree retains a failed backup's checkpoint after its backup
> CR is deleted"), re-rendered onto this template with every claim, quoted string, artifact path and UTC
> preserved; it keeps the draft's single-run reproduction class and its "unresolved question"
> classification. Paths given without a prefix are relative to `cbt-chaos/scenarios_v2/CBT-F-04/`.

## At a glance

| Field | Value |
|---|---|
| Issue type | **Unresolved question / consistency observation (candidate Improvement)** — **not a violated criterion**: no spec criterion observed in the run mandates that the libvirt checkpoint tree equal the live objects. |
| Priority (proposed) | Unassigned pending triage (proposed **low**: no functional impact observed in-run). |
| Owning component (suspected) | **suspected** the boundary between the KubeVirt/OpenShift Virtualization backup controller and the libvirt checkpoint lifecycle (checkpoint creation/pruning when a backup is deleted). |
| Component(s) proven involved | the libvirt checkpoint tree inside the launcher (it holds an entry for a backup object that no longer exists) and the backup-object/tracker side (neither references that entry). Which side is responsible for pruning is exactly the open question. |
| Reproducibility | `single observation` — observed once (r03). The same run's **second** failed attempt (r04, another run label, same day) died *before* checkpoint creation and left **no** tree entry, which narrows the precondition to post-checkpoint failures rather than reproducing the orphan. |
| Status / confidence | **Observed once (r03); no impact on naming, tracker, or restore; mechanism unknown.** Certain from artifacts: the final tree shape, the absence of a corresponding live object, and the successful restore. Unproven: whether the retention is deliberate. |
| Blast radius | anything that reads the libvirt checkpoint tree to model the backup chain (tooling, future prune/rebase operations); the backup objects and tracker are unaffected. |
| Data at risk? | **No** — chain restore passed with 0 failures; no data or restore path was affected. The risk named here is a mis-modelled chain and possible unbounded tree growth (hypothesis). |
| Related scenario / execution | CBT-F-04, run label `20261015-cbtf04-r03`, 2026-10-15 (UTC) — single run. r02 had no failed-then-deleted backup CR. r04 (same day) had a failed attempt that never reached checkpoint creation, so it neither reproduces nor contradicts this observation. |
| Affected versions | Same as the sibling sizing ticket: OpenShift/CNV versions `not recorded` for r03 (only the virt-controller image digest `sha256:23e9322e…` was captured); storage ODF / Ceph RBD (`ocs-storagecluster-cephblockpool`); guest RHEL 9. The full measured matrix is in **Environment** below. |

## Context (for an engineer new to this area)

- **What the feature does** — every CBT backup creates a **checkpoint** in libvirt (the per-VM
  virtualisation library QEMU runs under). A later incremental backup measures changes against the
  checkpoint it selects as its bitmap base. The checkpoints form a **tree** inside libvirt (each new one
  is created as a child), while the product's own chain bookkeeping lives in the backup objects and in
  the `VirtualMachineBackupTracker` (`status.latestCheckpoint`).
- **Where the question sits** — the libvirt checkpoint tree. After a backup that failed **after**
  creating its checkpoint had its object deleted, the checkpoint remained, and the next successful
  backup's checkpoint was nested beneath it.
- **Observed surface vs. origin** — the surface is the launcher-side checkpoint tree; the objects that
  disagree with it are the backup CRs (the failed one deleted, so no object at all) and the tracker
  (which advanced full → successful child, skipping the orphan). Two representations of one chain,
  disagreeing.
- **Why it matters** — a tool or future operation that reads the tree alone would mis-model chain
  membership and parentage (e.g. treating an orphan as a live link in the chain). Repeated
  failed-then-deleted backups would, on the hypothesis below, accumulate orphans indefinitely. Nobody has
  stated whether the retention is intended, so both a "prune it" and a "document it" answer are open.

## Environment (measured, not assumed)

Only one run label (r03) is behind this ticket; provenance is tagged per row. `not recorded` means
nothing captured it (never inferred). Node names are genericised as `<node>`.

| Layer | Component | Version / identifier | How obtained | Provenance |
|---|---|---|---|---|
| Platform | OpenShift Container Platform (server and `oc` client) | `not recorded` — this run captured no cluster version (only the virt-controller digest was recorded) | `oc version`, `oc get clusterversion version` | `not recorded` |
| Platform | Kubernetes API | v1.35.6 | `oc version` | `cluster 2026-10-16` |
| Platform | OpenShift update channel / plugin versions | `not recorded` — never captured | `oc get clusterversion version`, `oc plugin list` (not run) | `not recorded` |
| Nodes | OS image / kernel / container runtime | Red Hat Enterprise Linux CoreOS 9.8.20260915-0 (Plow); kernel 5.14.0-687.48.1.el9_8.x86_64; cri-o 1.35.8-11.rhaos4.22.giteaf45bc.el9 | `oc get nodes -o wide` | `cluster 2026-10-16` |
| Nodes | topology / node in scope | one worker ran the CBT VM and its launcher (`<node>`) | run VMI snapshots | r03 |
| Virtualization | CNV / HCO CSV | `kubevirt-hyperconverged-operator.v4.22.12`; the run captured the virt-controller pod label `app.kubernetes.io/version=4.22.12` and image digest `sha256:23e9322e…` (tag not captured) | pod label/digest in the run analysis; `oc get csv -A` | r03 (label/digest) + `cluster 2026-10-16` (CSV) |
| Virtualization | virt-handler image digest | `not recorded` — not captured for this run | `oc get ds virt-handler -n openshift-cnv -o jsonpath=…` (not run) | `not recorded` |
| Virtualization | virt-launcher image digest | `not recorded` — not captured for this run (**load-bearing**: the checkpoint tree is created and pruned from inside the launcher, so its libvirt revision matters) | `oc get pod <launcher> -o jsonpath='{.spec.containers[*].image}'` (not run) | `not recorded` |
| Virtualization | libvirt / QEMU / QEMU API in the launcher | `not recorded` for this run; the cluster's launcher images report libvirt 11.10.0 / QEMU 10.1.0 / QEMU API 11.10.0. **Load-bearing**: `virsh checkpoint-list --tree` semantics and checkpoint pruning behaviour are libvirt's | `virsh version` in the launcher's `compute` container | `not recorded` (r03) / `cluster 2026-10-16` |
| Backup API | CRD group / version | `backup.kubevirt.io/v1alpha1` — `VirtualMachineBackup`, `VirtualMachineBackupTracker` | the run's captured objects (`runs/20261015-cbtf04-r03/recovery/*.yaml`) | r03 |
| Storage (**in use**) | StorageClass + provisioner + pool | ODF / Ceph RBD, block pool `ocs-storagecluster-cephblockpool`; the failed pass's destination was the 30 Gi volume that filled to 29 GiB | run analysis; `recovery/rbd-du-backup-volumes.txt` | r03 |
| Storage (**in use**) | CSI driver image + version | `not recorded` — the run names the driver/pool, not its digest | `oc get ds` in the CSI namespace (not run) | `not recorded` |
| Storage (**present but NOT exercised**) | ODF operator versions / Ceph image | ODF/OCS `4.22.5-rhodf` operator set; RHCS 9 Ceph image `sha256:926d15fddae065a1e82b3634f80847253fa2cc14e9888e15b19b72a2cf144a58`; cluster health `HEALTH_OK` | `oc get csv -n openshift-storage`, `oc get cephcluster` | `cluster 2026-10-16` (stack identity only — this ticket is about checkpoint lifecycle, not storage) |
| Storage (**present but NOT exercised**) | HostPathProvisioner / hostpath CSI; local-storage-operator | StorageClass `cbt-demo-hpp` (+ hostpath CSI DaemonSet in ns `openshift-cnv`); `local-storage-operator.v4.22.0-202609291750` — installed, not in this ticket's path | `oc get sc`, `oc get ds`, `oc get csv -A` | `cluster 2026-10-16` |
| Guest | OS release | RHEL 9 | run report/analysis | r03 |
| Guest | kernel / guest agent / vCPU / memory | `not recorded` — none captured for this run | `uname -r`, `rpm -q qemu-guest-agent`, `nproc`/`free` (not run) | `not recorded` |
| Guest | state at the observation | CBT `Enabled` at all observation points, including after the failed pass (`guest-state-post-failure.txt`: `cbt state=Enabled`); 65G free after cleanup | `recovery/guest-state-post-failure.txt`, `done.json` | r03 |
| Harness (internal only) | workflow + trigger checksum | `virt-cbt-lab`; trigger sha256 `a214796df0d0395833f23d9de07ef9d5a7888d5d1fcbef7bb4779926488d837b` from this run's own pack | `runs/20261015-cbtf04-r03/preflight.json` | r03 |

## Reproducibility

- **Classification**: `single observation` — observed once, on **one** run label
  (`20261015-cbtf04-r03`). No spec criterion observed in the run mandates that the checkpoint tree equal
  the live objects, so this stays an unresolved question rather than a confirmed defect.
- **Attempts**: 1 orphan observed (r03), by the scenario's own harness/operator on one cluster; the
  observer flagged it in run findings (`observer/finding.md` contradiction #3: "tree ⊃ live objects").
  The run's read-only watcher captured the CR deletion through a supplementary watch
  (`observer/WATCH-LOST` note M4, `vmbackup-all-r03`).
- **Related non-reproduction (narrows the precondition)**: on the next run label the same day (r04), a
  failed first attempt died **during initialization, before any checkpoint existed**, and left **no**
  tree entry — the final r04 tree was a clean single root + one child. r04 therefore neither reproduces
  nor contradicts this observation, but it does narrow the precondition: the orphan arises only when the
  backup fails **after** checkpoint creation.
- **Stability — exact**: the tree shape at both capture times (10:58:10Z and 10:59:31Z) and the absence
  of a matching live object or tracker reference. **Unknown**: how long the orphan persists (it was still
  present at the run's final reads), and whether a prune/rebase operation would remove it or fail on it.
- **Preconditions**: (a) an incremental backup that fails **after** its checkpoint has been created
  (the destination-capacity path is the recorded way to force this); (b) the failed backup object is then
  deleted, which is when the object-side reference disappears while the tree entry does not.
- **Second entry path**: not attempted. [INFERENCE] that any post-checkpoint failure plus object deletion
  produces the same orphan, since the tree entry is created before the failure and nothing observed
  removes it — unproven, and the reason the ticket asks for the intended semantics rather than asserting
  a bug.

## Steps to reproduce (exact commands and injection timing)

> Everything below uses the **recorded names of run `20261015-cbtf04-r03`** (namespace `vm-cbt-demo`), so
> each command can be compared with this ticket's evidence. For a fresh reproduction pick your own
> run-scoped names. Every command is scoped to one named object. **No chaos injection is required**: the
> sequence is "fail a backup after its checkpoint exists, then delete its object". Repository helper
> (optional accelerator, never required): `cbt-chaos/scenarios_v2/CBT-F-04/chaos-trigger.sh`.

### Concrete objects used in this report

| Kind | Name | UID | Created (UTC) | Fate |
|---|---|---|---|---|
| VirtualMachine / VMI | `vm-20261015-cbtf04-r03` | `not recorded` | 2026-10-15 ~09:1xZ | kept; Running, CBT `Enabled` throughout |
| Pod (launcher — where the checkpoint tree lives) | `virt-launcher-vm-20261015-cbtf04-r03-mqtfn` | bbaa5ed9-… (abbreviated in the analysis) | ~09:14Z | kept; never restarted across the window |
| VirtualMachineBackupTracker | `vm-tracker-20261015-cbtf04-r03` | 4e362574-dee7-4fec-bb8d-1ba46f814f02 | `not recorded` | kept; final state = the **successful** child checkpoint `…-10-49-06` (it advanced full → child directly, skipping the orphan) |
| VirtualMachineBackup (full — the tree root) | `vm-backup-20261015-cbtf04-r03`; checkpoint `vm-backup-20261015-cbtf04-r03-2026-10-15_09-14-05` | `not recorded` | 09:14:05Z | kept; `Done=True` `Successfully completed VirtualMachineBackup` 09:15:15Z |
| VirtualMachineBackup (failed, **the orphan's former owner**) | `vm-incremental-20261015-cbtf04-r03-p01`; checkpoint `vm-incremental-20261015-cbtf04-r03-p01-2026-10-15_10-35-19` | f71e404c-c817-489b-ac39-7e38a007aed8 | created 10:34:53Z (checkpoint 10:35:19Z) | **CR deleted ~10:41Z** (Lead-approved, after evidence capture, the name being reused for the retry); **its libvirt checkpoint `10-35-19` remained in the tree** |
| VirtualMachineBackup (successful retry — the child in the tree) | `vm-incremental-20261015-cbtf04-r03-p01` (reused name); checkpoint `vm-incremental-20261015-cbtf04-r03-p01-2026-10-15_10-49-06` | `not recorded` (re-created object) | 10:48:40Z | kept; `Done=True` 10:50:14Z; in libvirt's tree it is **nested under the orphan** `10-35-19` |
| PVC (failed destination) | the 30 Gi incremental destination of retry-3; exact name `not recorded` | `not recorded` | ~10:34Z | kept; holds the 29 GiB partial copy |
| PVC (retry destination) | the 100 Gi incremental destination of retry-5; exact name `not recorded` | `not recorded` | ~10:48Z | kept; absorbed the successful retry |
| Preserved artifacts | `runs/20261015-cbtf04-r03/recovery/{checkpoint-tree-post-retry5.txt, checkpoint-tree-post-incremental.txt, incremental-backup-post-retry3.yaml, tracker-post-retry3.yaml, tracker-post-retry5.yaml, done.json}` and the run's `evidence-index.json` (68 files, sha-pinned at run close) | — | run close | retained |

### Steps

**Step 1 — Setup: CBT-enabled VM with a full backup whose checkpoint becomes the tree root.** When:
before the failing backup.
```bash
oc get vmi vm-20261015-cbtf04-r03 -n vm-cbt-demo \
  -o jsonpath='{.status.phase}{" "}{.status.changedBlockTracking.state}{"\n"}'
oc get vmbackuptracker vm-tracker-20261015-cbtf04-r03 -n vm-cbt-demo \
  -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'
# read the checkpoint tree from the launcher's compute container (recorded shape; the run read it launcher-side)
oc exec -n vm-cbt-demo virt-launcher-vm-20261015-cbtf04-r03-mqtfn -c compute -- \
  virsh checkpoint-list --domain $(oc exec -n vm-cbt-demo virt-launcher-vm-20261015-cbtf04-r03-mqtfn -c compute -- virsh list --name | head -1) --tree
```
What you must see: VMI `Running` with CBT `Enabled`, a tracker holding the full checkpoint, and a tree
with a **single root** (recorded: `09-14-05`).

**Step 2 — Make an incremental fail *after* its checkpoint is created.** When: after step 1's tree
capture. The recorded way is a destination too small for the data that must be copied.
```bash
oc apply -f - <<'YAML'
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: vm-incremental-20261015-cbtf04-r03-p01
  namespace: vm-cbt-demo
spec:
  pvcName: <undersized-destination-pvc>
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: vm-tracker-20261015-cbtf04-r03
YAML
oc get vmbackup vm-incremental-20261015-cbtf04-r03-p01 -n vm-cbt-demo \
  -o jsonpath='{.status.checkpointName}{" "}{.status.conditions[?(@.type=="Done")].reason}{"\n"}'
```
**Window/injection point: it opens when the checkpoint is created (recorded 10:35:19Z — the checkpoint
exists before the copy starts, so it survives the failure) and closes when the failed backup object is
deleted in step 4.** Fail-closed pre-check: the destination really is too small, so the copy cannot
succeed. Post-check: the backup has a `status.checkpointName` (the checkpoint exists) **and** a failure
reason (recorded: `Backup has failed: No space left on device` at 10:35:56Z, tracker unchanged).

**Step 3 — Confirm the checkpoint is in the tree before the deletion.** When: right after the failure.
```bash
oc exec -n vm-cbt-demo virt-launcher-vm-20261015-cbtf04-r03-mqtfn -c compute -- \
  virsh checkpoint-list --domain $(oc exec -n vm-cbt-demo virt-launcher-vm-20261015-cbtf04-r03-mqtfn -c compute -- virsh list --name | head -1) --tree
```
What you must see: the failed backup's checkpoint present in the tree (recorded: `10-35-19` as a child
of the root). This is the "before" picture.

**Step 4 — Capture and delete the failed backup object (this is where the divergence appears).** When:
after step 3.
```bash
oc get vmbackup vm-incremental-20261015-cbtf04-r03-p01 -n vm-cbt-demo -o yaml > /tmp/failed-incremental-r03.yaml
oc delete vmbackup vm-incremental-20261015-cbtf04-r03-p01 -n vm-cbt-demo
oc get vmbackup vm-incremental-20261015-cbtf04-r03-p01 -n vm-cbt-demo   # NotFound
```
What you must see: the object is gone (recorded: deleted ~10:41Z, after the `vmbackup-protection`
finalizer completed) while the checkpoint tree is unchanged.

**Step 5 — Read-only demonstration of the defect.** When: after a successful retry exists, so the child
checkpoint is in the tree (recorded captures 10:58:10Z and 10:59:31Z).
```bash
# 5a. the tree still holds the deleted backup's checkpoint
oc exec -n vm-cbt-demo virt-launcher-vm-20261015-cbtf04-r03-mqtfn -c compute -- \
  virsh checkpoint-list --domain $(oc exec -n vm-cbt-demo virt-launcher-vm-20261015-cbtf04-r03-mqtfn -c compute -- virsh list --name | head -1) --tree
# 5b. and no live object references it: list the objects and the tracker
oc get vmbackup -n vm-cbt-demo -o custom-columns=NAME:.metadata.name,CHECKPOINT:.status.checkpointName,TYPE:.status.type
oc get vmbackuptracker vm-tracker-20261015-cbtf04-r03 -n vm-cbt-demo -o jsonpath='{.status.latestCheckpoint.name}{"\n"}'
```
What you must see (recorded): the tree reads
`root (09-14-05) → 10-35-19 (orphaned) → 10-49-06 (successful)` — the orphan sits **between** the root
and the successful child, while the live objects are only the full backup and the successful retry, and
the tracker went straight from the full checkpoint to `10-49-06`. **The punchline:** the tree strictly
contains the live objects, and the child's parent in the tree is not the checkpoint that was its actual
bitmap base.

**Step 6 — Recovery — by design there is nothing to recover yet.** When: after capturing step 5.
```bash
# Do NOT delete checkpoints to "clean up": what a prune/rebase would do with the orphan is exactly the
# open question. Capture the tree (step 5a) and the objects (5b) as the evidence instead.
```
What you must see: the chain restore still verifies (recorded: cumulative chain 10 files /
10,737,418,240 B manifest match, 0 failures) — i.e. the orphan had **no** functional impact, which is
why this ticket asks for the intended semantics instead of prescribing a fix. What this does **not**
give back: a tree-based answer to "which backups are live in this chain" — that question must be answered
from the objects and the tracker until the semantics are settled.

## Current behaviour (observed)

A failed incremental backup's CR was deleted (after ENOSPC; the deletion completed through the
`vmbackup-protection` finalizer), but its libvirt checkpoint (`…-10-35-19`) remains in the live
checkpoint tree between the full checkpoint and the successful incremental: final tree
`root (09-14-05) → 10-35-19 (orphaned) → 10-49-06 (successful)`. The tree strictly contains the live
objects. Additionally, the tree parentage diverges from the logical chain: the successful incremental's
copy used the full checkpoint as its bitmap base (it copied the full 68 GiB dirty set, and the tracker
advanced full → 10-49-06 directly), yet in libvirt's tree its checkpoint is nested under the orphan. No
functional impact was observed — chain restore passed with 0 failures — but tree structure alone
mis-models the chain, and repeated failed attempts would (hypothesis) accumulate orphans.

Observed details (recorded): r03 retry-3 backup CR created 10:35:19Z (checkpoint `…-10-35-19`), failed
10:35:56Z (ENOSPC, tracker unchanged), CR deleted ~10:41Z (Lead-approved; captured by the
`vmbackup-all-r03` watch). Trees captured 10:58:10Z (`checkpoint-tree-post-retry5.txt`) and 10:59:31Z
(final live reads) show the orphaned `10-35-19` between root and the successful child `10-49-06`. The
observer flagged it (`observer/finding.md` contradiction #3: "tree ⊃ live objects"). *(All of the above:
independent artifact observations.)*

## Expected behaviour (contract)

Clarify the intended semantics: either checkpoint-tree entries are removed (or reconciled/marked) when
their owning backup CR is deleted after failure, or the retention is documented as deliberate (with the
chain-derivation caveat).

**Acceptance check.** The relationship between deleted backup CRs, tracker state, and the libvirt
checkpoint tree is specified; a consumer can derive the live chain from the documented surface — e.g.
`virsh checkpoint-list --tree` plus the documented rule yields exactly the set of checkpoints that live
`VirtualMachineBackup` objects and the tracker reference, or the documentation states plainly that the
tree is a superset and must not be used for chain derivation.

**Acceptance criteria (from the reporter draft, preserved):**

- Specified behavior for libvirt checkpoints whose owning backup CR is deleted after a failed copy
  (removed, retained-with-reason, or reconciled).
- If removal is chosen: failed-then-deleted backups leave no tree entry, and subsequent successful
  incrementals still chain and restore correctly.

## Impact, workaround and data safety

- **Functions lost / how an operator notices.** Nothing observed was lost: the chain restored with 0
  failures, the tracker was correct, and the orphan had no effect on the successful incremental's name.
  An operator would notice only by reading the checkpoint tree and comparing it with the objects — the
  divergence is invisible from the product's own status.
- **Blast radius.** Consumers of the libvirt checkpoint tree (tooling that derives chain membership or
  parentage) and future prune/rebase operations that must walk the tree. The backup objects, the
  tracker, restores and the guest are unaffected.
- **Data safety.** **Not at risk** — restore passed with 0 failures, and the orphan does not participate
  in any copy. The risks this ticket names are structural: unbounded tree growth under repeated failed
  attempts (hypothesis), and mis-modelled parentage for tree-only tooling.
- **Workaround / operator runbook.** None identified from this run, and none is recommended: deleting
  checkpoints by hand to remove the orphan would itself be an unsupported operation on a live VM's
  checkpoint tree — which is precisely why the semantics need to be specified first. For anyone who must
  derive the live chain today: use the backup objects' `status.checkpointName` plus the tracker's
  `status.latestCheckpoint`, **not** the libvirt tree.
- **Frequency.** Every backup that fails after checkpoint creation and is then deleted. The r03 run
  produced one; the r04 run's failed attempt died before checkpoint creation and produced none, so the
  rate depends entirely on the failure phase.
- **Unknowns this ticket deliberately does not claim.** Whether the retention is deliberate
  (e.g. because pruning only runs for tracker-advancing backups) or an oversight in the CR-deletion path;
  whether the orphan affects `checkpoint-delete`/rebase/prune later; whether tree parentage is used by
  any restore tooling; and whether orphans accumulate without bound under repeated failures.

## Evidence

**Artifact index.** Paths are as the analysis/draft records them, relative to
`cbt-chaos/scenarios_v2/CBT-F-04/`. The run's full root is sha-pinned in
`runs/20261015-cbtf04-r03/evidence-index.json` (68 files, generated 2026-10-15T12:15:37Z).

| Artifact | What it carries | UTC | Type |
|---|---|---|---|
| `runs/20261015-cbtf04-r03/recovery/checkpoint-tree-post-retry5.txt` | the decisive tree: `root (09-14-05) → 10-35-19 (orphaned) → 10-49-06 (successful)` | 10:58:10Z | raw |
| `runs/20261015-cbtf04-r03/recovery/checkpoint-tree-post-incremental.txt` | the tree at an earlier point in the same run (comparison for the "before/after deletion" reading) | ~10:5xZ | raw |
| `runs/20261015-cbtf04-r03/observer/finding.md` | the observer's flag: contradiction #3, "tree ⊃ live objects" | run window | raw (observer) |
| `runs/20261015-cbtf04-r03/recovery/{incremental-backup-post-retry3.yaml, tracker-post-retry3.yaml}` | the failed object (checkpoint `…-10-35-19`, reason `Backup has failed: No space left on device`) and the tracker unchanged at the full checkpoint — the object side of the divergence before deletion | 10:35:56Z | raw |
| `runs/20261015-cbtf04-r03/recovery/{tracker-post-retry5.yaml, done.json}` | after the retry: tracker at the successful child `10-49-06` (never the orphan), chain restore 10 files / 10,737,418,240 B, 0 failures | 10:50–10:5xZ | raw |
| `runs/20261015-cbtf04-r03/observer/WATCH-LOST` (M4 note) + `observer/watches/vmbackup-all-r03*` | the CR deletion at ~10:41Z captured by the supplementary watch (the main watch had already died; the note records the substitution) | ~10:41Z | raw |
| `runs/20261015-cbtf04-r03/reports/test-run-report.md`, `test-run-result.md` | run verdict and the observation's classification | run window | derived |
| `analysis/20261015-cbtf04-r03-product-flow.md` §3 (Finding 2) and §4 Draft 3 | the analysis of the orphan and the draft (this file's source) | 2026-10-15 | derived (analysis) |
| `analysis/20261015-cbtf04-r04-product-flow.md` §6 (checkpoint-orphan hypothesis) | the narrowing observation: r04's failed attempt died before checkpoint creation and left no tree entry (r04 neither reproduces nor contradicts this) | 2026-10-15 | derived (analysis) |
| `runs/20261015-cbtf04-r03/preflight.json` | GO decision and trigger sha256 `a214796d…` | 09:04:06Z | raw |

**UTC timeline** (setup → precondition → injection → effect → failure → recovery):

| # | Time (UTC), 2026-10-15 | Event | Source |
|---|---|---|---|
| 1 | 09:14:05 → 09:15:15Z | Setup: full backup completes (`Done=True` success); checkpoint `09-14-05` becomes the tree root | run report; tracker watch |
| 2 | 10:35:19Z | **Precondition/effect begins**: retry-3 backup CR created and its checkpoint `10-35-19` created (checkpoint creation precedes the copy) | run analysis §3 |
| 3 | 10:35:56Z | The copy fails (ENOSPC, 29 GiB written); `Done=True` with `Backup has failed: No space left on device`; tracker **not** advanced | `incremental-backup-post-retry3.yaml`; `tracker-post-retry3.yaml` |
| 4 | ~10:41Z | **The divergence's trigger**: the failed CR is deleted (Lead-approved; finalizer completes) — the object-side reference disappears | run analysis §3; `vmbackup-all-r03` watch |
| 5 | 10:48:40 → 10:50:14Z | Successful retry: new checkpoint `10-49-06`, `Done=True` success, tracker advances full → `10-49-06` directly | `tracker-post-retry5.yaml` |
| 6 | 10:58:10Z / 10:59:31Z | **Observation**: tree captured — `root (09-14-05) → 10-35-19 (orphaned) → 10-49-06 (successful)`; the tree strictly contains the live objects and the child's tree-parent is not its bitmap base | `checkpoint-tree-post-retry5.txt`; final live reads |
| 7 | 10:5xZ | **No functional consequence**: cumulative chain restore matches the guest manifest with 0 failed restore and 0 failed hash checks | `done.json`; run report |
| 8 | — | **Recovery**: none performed and none recommended — the semantics must be specified before anyone prunes a live VM's checkpoint tree | run analysis §3 (`Move-to-bugs/` recommendation: keep as an unresolved question) |

**Retained state.** The evidence was preserved whole: the checkpoint trees at two capture times, the
tracker states before/after, the failed object's YAML (its live object was deleted at ~10:41Z with Lead
approval, after capture), and the successful retry's objects. The VM stayed Running with CBT `Enabled`,
including after the failed pass. No checkpoint was deleted to "clean up" the orphan — the orphaned entry
is the evidence, and its removal semantics are the open question.

## Negative results and what would falsify this ticket

- **Refuted: "the orphan broke something."** The successful incremental's checkpoint name, the single
  tracker advancement, and the cumulative chain restore were all correct (0 failed restore and 0 failed
  hash checks). The observer classified it as a consistency observation, not a criterion violation.
- **Refuted: "the tracker or the CRs reference the orphan."** The tracker advanced full → `10-49-06`
  directly, and no live backup object carries `10-35-19` as its checkpoint. The tree is the only surface
  holding it.
- **Refuted: "any failed attempt leaves an orphan."** r04's failed first attempt died during
  initialization, before checkpoint creation, and left **no** tree entry — so the precondition is
  specifically a failure **after** checkpoint creation.
- **Refuted: "the child is genuinely a descendant of the orphan."** The successful copy demonstrably used
  the full checkpoint as its bitmap base (it copied the whole 68 GiB dirty set), so the tree's nesting
  contradicts what the copy actually did.
- **Limits of this evidence (stated, not refuted).** A single observation, one run label, one cluster;
  the CNV/OpenShift and launcher libvirt versions are `not recorded`; the orphan's persistence beyond the
  run's final reads is unknown; no prune/rebase operation was exercised, so the orphan's effect on them is
  untested.
- **Falsifiers.** This ticket is wrong, or a non-issue, if any of the following holds:
  1. The retention is documented as deliberate and the tree is explicitly not a chain-derivation surface
     — then this reduces to a documentation clarification (already the likely outcome).
  2. A second failed-then-deleted backup shows its checkpoint **removed** — that would contradict the
     "pruning only runs on tracker-advancing backups" hypothesis and make this a deletion-path bug.
  3. Tooling that consumes the tree is shown to use the tracker/objects for parentage anyway, so the
     divergence has no consumer — that would remove the practical impact and leave only the unbounded
     growth hypothesis.
  4. The tree shape is shown to be an artifact of how the run read it (e.g. a stale cached listing rather
     than libvirt's live tree) — the two captures 83 seconds apart agree, but a systematic read error
     would still explain both.

## Additional feedback (reporter's notes)

- **Preserved triage questions.** (a) Is the checkpoint retained because pruning only runs on
  tracker-advancing (successful) backups, or is deletion-path cleanup expected to remove it and missed it?
  (b) Does the retained orphan affect `checkpoint-delete`/rebase/prune operations later (e.g. removing the
  full checkpoint while an orphan references it)? (c) Is tree parentage (child-of-orphan) ever used by
  restore tooling, given the tracker/CR chain differs?
- **Smallest experiments that would settle the open points.** (1) Repeat the sequence (fail after
  checkpoint creation → delete the CR → take a successful incremental) and see whether a second orphan
  appears and whether it accumulates — settles the unbounded-growth hypothesis. (2) On a scratch VM,
  attempt a checkpoint-delete/rebase of an *older* checkpoint while an orphan is in the tree — settles
  whether the orphan blocks or misleads maintenance operations. (3) Ask the owner (or read the source) what
  the CR-deletion path is supposed to do with a created-but-unused checkpoint — a documentation answer
  that settles (a).
- **Cross-references.**
  - Same folder: `failed-backup-terminates-done-true-with-failure-reason.md` — the same failed backup
    object's status semantics (its post-checkpoint failure is what creates the orphan).
  - Same folder: `cbt-incremental-copy-size-is-peak-dirty-volume.md` — why that backup failed at all
    (the undersized destination is the deterministic way to produce this precondition).
  - Same folder: `hotplugfailed-lstat-on-successful-detach.md` — the other r02–r04 finding.
  - Source analysis (unchanged apart from the pointer at its head):
    `analysis/20261015-cbtf04-r03-product-flow.md` §3 (Finding 2) and §4 Draft 3 (this draft), plus
    `analysis/20261015-cbtf04-r04-product-flow.md` §6 for the narrowing observation.
  - **Separately and clearly labelled — harness/tooling, not this ticket:** the run lost its main
    `vmbackup` watch before the CR deletion and had to cover it with a supplementary watch
    (`observer/WATCH-LOST`, note M4). That is why the deletion timestamp is approximate (~10:41Z)
    and is a harness-lane observation, not a product finding.
- **Environment-specific notes for the next reproducer.** (a) The checkpoint must be created
  **before** the failure — a destination-capacity failure is the reliable way; an initialization failure
  (as in r04) leaves no checkpoint and therefore no orphan. (b) Read the tree from the launcher's compute
  container (`virsh checkpoint-list --tree`), and capture it **twice** (before and after the deletion) so
  the divergence is provable rather than inferred. (c) Capture the launcher's libvirt/QEMU versions —
  `not recorded` here, and checkpoint pruning semantics are libvirt's. (d) Do not delete the orphan by
  hand: its removal semantics are the question being asked.

## Sanitisation checklist

- [x] No credentials, tokens, kubeconfig contents or private keys — none quoted.
- [x] No private hostnames or absolute host paths — cluster node names are genericised as `<node>`; the
      only path-like strings are `virsh` invocations and container-internal command lines.
- [x] No broad selectors (names or run-scoped labels only) — every command is scoped by the run's exact
      launcher pod, backup, tracker and PVC names.
- [x] No destructive commands other than the documented, scoped workaround — the only deletion described
      is the run's own failed backup CR (captured to YAML first, scoped to that one object, and labelled
      as the recorded action that triggers the divergence); the recovery section explicitly forbids
      deleting checkpoints to clean up the orphan.
- [x] Commands are the ones actually validated (illustrative ones are labelled) — the tree read is the
      recorded shape (launcher `virsh checkpoint-list`), the object reads are the ones the run used, and
      the note above the steps says which command shapes are re-creations and that no injection is
      required.

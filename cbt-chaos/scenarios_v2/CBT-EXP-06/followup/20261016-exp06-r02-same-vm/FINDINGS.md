# Same-VM follow-up for CBT-EXP-06 run 20261016-exp06-r02 — findings

**Status:** completed 2026-10-16 (driver ran 05:34:34Z–05:55:26Z, 1252 s) ·
**Relation to the graded run:** this is a **post-close** experiment on the same
VM; it does not change the closed run's verdict or evidence pack (r02 stays
`BLOCKED`, pack frozen and indexed at `runs/20261016-exp06-r02/`).
**Reference:** `docs/findings/finding-1-backup-cr-livelock.md` (Path A, run
`20261014-exp06-r01`).

## Why it exists

The closed run's own recovery leg could not take a same-VM backup with new
names: the staged interface refuses to add a pass to a lifecycle in a failed
state, and its only documented unblock (`reconcile`) deletes the failed pass's
backup CR **and** PVC — i.e. the evidence the protocol requires preserving.
This driver therefore performed the follow-up against the API directly, using
the same schema as the workflow's own incremental manifest, and recorded the
behaviour finding-1 describes. Human decisions taken before it ran: same-VM
driver on r02's VM; delete the wedged CR **only**, keep its PVC.

Driver: `cbt-chaos/scenarios_v2/CBT-EXP-06/same-vm-followup.sh`
(`bash -n` clean; `--plan` rehearsal exit 0; guards: VMI Running + CBT Enabled,
wedged CR present and non-terminal, tracker present and not deleting, pool free
≥ 25 GiB before any new pass, abort a pass wait below 8 GiB).

## Results

| Leg | What it did | Result | Evidence |
|---|---|---|---|
| F0 | Snapshot the wedged state (read-only) | `vm-incremental-…-p01`: `type` null, no `Done`, no `includedVolumes`; finalizer `backup.kubevirt.io/vmbackup-protection`; target PVC `vm-incremental-pvc-…-p01` **`MountedToPod`** via hotplug pod `hp-volume-gkq77`; 46 controller lines carrying the per-disk bitmap error in the preceding 180 min | `wedged-cr-before-delete.{json,yaml}`, `vmi-before.json`, `hotplug-before.json`, `controller-window.log`, `f0-retry.json` |
| F1 | Create a new source-scoped backup while the wedged one is in progress | **REJECTED at admission**: `The request is invalid: spec.source: VirtualMachineBackup "vm-incremental-20261016-exp06-r02-p01" in progress for source` (apply exit 1). The test backup never existed; its 3 Gi PVC was removed. | `f1-apply.out`, `f1-delete-cr.out` |
| F2 | Operator runbook: delete the wedged CR, keep its PVC | CR disappeared in **3 s** (finalizer released); PVC `vm-incremental-pvc-…-p01` stayed **Bound**; the leaked hotplug volume **detached** | `f2-delete-wedged.out`, `wedged-pvc-after.json`, `hotplug-after-unblock.json`, `vmi-after-unblock.json` |
| F3 | Create a new incremental (`…-p02`, 30 Gi PVC) on the same VM and wait the harness's 20 min | **WEDGED AGAIN**: created 05:35:13Z, still `Initializing=True`/`Progressing=False` with the stale "attaching its target PVC" reason at 05:55Z, `type`/`Done`/`includedVolumes` unset, finalizer held; 1 namespace `BackupError` (`virError(Code=109) … checkpoint inconsiste…`) at 05:46:12Z; **0 events on the CR itself**; its own hotplug mount leaked (`hp-volume-ngsjk`) | `f3-apply.out`, `f3-new-backup.{json,yaml}`, `f3-events-ns.json`, `hotplug-after-unblock.json`, `followup.log` |

## What this establishes

1. **finding-1 Path A is now reproduced three times** (r01's leg B; r02's p01;
   r02's p02), each time with the same signature: no terminal condition, held
   finalizer, stale initializing reason, deterministic per-disk `virError(109)`
   retries, empty CR-scoped event stream.
2. **The VM-wide backup deadlock is not specific to Path B.** finding-1 recorded
   the one-backup-per-source rejection for the deleted-tracker path; F1 shows the
   **corrupt-checkpoint path deadlocks the VM's whole backup capability** the same
   way, with the rejection naming the wedged CR.
3. **The runbook row is validated for this path**: deleting the wedged CR while
   the tracker exists releases the finalizer in seconds and detaches the leaked
   hotplug volume, with no node-level intervention.
4. **The leak recurs on every wedged pass** (F0's `hp-volume-gkq77`, F3's
   `hp-volume-ngsjk`), and the destination PVC stays `Bound` after the CR is
   deleted — an operator has to reclaim it deliberately.
5. **The tracker's stale entry is the mechanism that keeps the VM wedged.** The
   redefined checkpoint declares only `vda` (r02 pack:
   `observer/effect/checkpoint-dumpxml-post.xml`) while the tracker still
   advertises `rootdisk+datadisk` (`tracker-before.json` here,
   `tracker-after.json` after the follow-up), and the new pass is refused against
   that tracker expectation. No new pass can succeed until the tracker is
   repaired or discarded.
6. **The originally hypothesised *silent completed* drop did not occur here**: the
   missing bitmap is caught (loudly) rather than silently omitted; the silent part
   of the defect lives in the checkpoint/tracker metadata, not in a completed
   incremental's `includedVolumes`.

## What remains open (needs a human decision)

- **The tracker-reset leg** (finding-1's matrix: `Delete tracker, then new backup
  → next backup completes type=Full, chain silently discarded`) and, with it, the
  question whether any later pass can complete with the datadisk missing. It
  requires a **new full-backup PVC (~80 GiB)**; the pool holds **40.25 GiB** free,
  so it is capacity-blocked until space is reclaimed.
- Whether the permanent VM-wide deadlock is upstreamed as a first-class product
  finding now (three reproductions) or held for the campaign's ticket merge.

## Live state deliberately left in place

`vm-incremental-…-p02` is left wedged as live evidence of the third
reproduction (snapshotted above); `vm-incremental-pvc-…-p01` remains Bound (its
input PVC, per the approval); the tracker still holds the stale checkpoint; the
VM/VMI are healthy (Running, CBT Enabled); pool free unchanged at 40.25 GiB.
Nothing outside this experiment was deleted, and no run-root artifact was
modified.

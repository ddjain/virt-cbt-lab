# CBT-T-04: Storage-capacity threshold — the free-space floor for a successful CBT backup cycle

**Purpose:** Quantify how much free pool space a full+incremental CBT backup cycle actually needs — the boundary between F-08/I-05-style clean ENOSPC failure and normal operation.
## Workflow
Full backup (then incremental on surviving legs)
## Test Objective / Description
Pre-fill the HostPath pool (/var/hpvolumes/csi on /dev/sdb) so each leg starts with a controlled amount of free space; run the backup cycle; record the largest fill that still succeeds and the smallest that fails. This turns the already-evidenced ENOSPC failure mode (I-04 r01: 0 free → VM PausedIOError, backup stuck) into a measured safety-margin number for engineering.
## Chaos Target
Backup destination capacity (the HPP pool filesystem)
## Chaos Action
Filler pod (fallocate) on hostPath /var/hpvolumes/csi, sized to leave a target free-space floor; removed after the leg
## When to Inject Chaos
Before the backup starts (pre-fill, like I-05's r02 recipe) — the capacity constraint applies throughout the copy
## Injection Signal / Condition
Filler reports target free space reached (df from inside the pod)
## Chaos Duration
Entire backup cycle
## Expected Behavior
Above the true floor: backup succeeds (possibly slower near the boundary). Below: clean failure — backup terminal error "No space left on device", VM may PausedIOError (write path), tracker not advanced. No corruption in either case (F-08 precedent).
## Recovery
Filler pod deleted → space reclaimed (fallocate is transient)
## How to Verify
Backup Done reason; df before/during/after; tracker state; on success: incremental + restore verify; VM state (pause detection via VMI conditions)
## Expected Outcome
A measured floor: "full+incremental cycle needs ~X GiB free; below X it fails cleanly"
## Priority
P2 (campaign-authored)
## Technical Scenario
pvc-scenarios/storage fill (direct fallocate pod — I-05 pre-fill recipe)
## Chaos Phase
Active operation

## Sizing math (from measured runs)

- Full backup writes ~17.5GiB data (1000 × ~18MiB files) as qcow2 into vm-backup-pvc (80GiB PVC, HPP thin-ish on the pool filesystem)
- Incremental p01: ~17.5GiB more (1000 new files)
- Baseline observed usage per full+incr cycle: root PVC ~20GiB + backup PVC ~20GiB + incremental PVC ~20GiB ≈ 60GiB pool usage

## Sweep legs (target free space at backup start; pool has 1.42TiB free post-clean-all)

| Leg | Free floor | Hypothesis |
|---|---|---|
| t04a | 100 GiB | Comfortably above need (~60GiB) → succeeds |
| t04b | 60 GiB | At the estimate → boundary |
| t04c | 40 GiB | Below need → clean ENOSPC failure |

Each leg: fresh RUN_ID, filler sized = current_free − target, verified via pod df before backup launch. PVC requests themselves are 80GiB each — NOTE: HPP pool provisioning may reject PVC creation outright when the pool's free space < sum of requests; observe whether the failure point is PVC admission vs copy-time ENOSPC (both are valid threshold data).

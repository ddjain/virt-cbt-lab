# CBT-O-09: Fill the backup destination PVC to its RBD volume limit — per-volume ENOSPC on ODF

**Purpose:** The ODF-backed F-08/I-05 analog: exhaust the backup destination PVC's OWN volume capacity (the RBD image size the CSI provisioner created) rather than the pool, using the campaign-proven pre-fill recipe, and verify the clean-failure + tracker-hold semantics on the large-odf sizing.

## Workflow

Full and incremental backup

## Test Objective / Description

Pre-create the full-backup destination PVC (80Gi, ocs-storagecluster-ceph-rbd) from the stage's own template, pre-fill it to ~97% with fallocate via a short-lived privileged pod, release it, then run the backup whose ~17.5GiB+overhead copy cannot fit — expect a mid-copy ENOSPC with the I-05 r02 semantics. The incremental variant uses the 30Gi p01 PVC pre-filled to 29G (the exact I-05 r02 recipe on the ODF sizing).

## Chaos Target

Backup destination PVC's RBD volume capacity (vm-backup-pvc-<RUN_ID> 80Gi full / vm-incremental-pvc-<RUN_ID>-p01 30Gi)

## Chaos Action

fallocate pre-fill of the destination PVC before backup creation (concurrent fill is Multi-Attach-blocked during the copy — I-05 r01)

## When to Inject Chaos

Before the backup starts (pre-fill; the capacity constraint applies throughout the copy)

## Injection Signal / Condition

Filler pod Succeeded and volume released (no pod mounts the PVC) before the backup object is created

## Chaos Duration

Permanent for the run (PVC deleted with the run)

## Expected Behavior

Clean failure: Done=True with `Backup has failed: No space left on device` (I-05 r02 verbatim class) ~seconds into the copy; tracker HOLDS the previous checkpoint (VMI alive); VM stays running (unpaused — the ENOSPC is on the destination, not the guest disk); no partial-backup false success.

## Recovery

Fresh destination PVC + retry (API-level pass-02 names per the I-05 recipe, or `make e2e TYPE=recover` for the full variant) succeeds after the failed run.

## How to Verify

Done reason verbatim; tracker state (25×10s samples — the I-05 r02 watch pattern); filler df before/after; recovery backup succeeds; restore verification of the last-good checkpoint.

## Expected Outcome

Confirms the clean-failure semantics and the RWO/Multi-Attach constraint on the ODF large-odf sizing — the per-volume capacity floor companion to O-08's pool-level floor.

## Priority

P2 (semantics already proven on I-05 r02; this re-pins them on the large-odf sizing)

## Technical Scenario

pvc-scenarios semantics via the campaign-proven direct pre-fill pod (krkn's pvc-scenarios needs an attached pod and fails on released backup PVCs — krknctl-bugs/learnings #47; the direct fallocate pod is the sanctioned equivalent)

## Chaos Phase

Operation start

## Sweep / combination matrix

| Leg | Target PVC | Fill | Rationale |
|---|---|---|---|
| o09a | full dest 80Gi | 78G (leave ~2Gi) | Full-copy ENOSPC on the large-odf sizing |
| o09b | incremental p01 30Gi | 29G (leave ~1Gi) | The exact I-05 r02 recipe at ODF sizing — semantics regression |
| o09c | full dest 80Gi | 70G (leave ~10Gi) | Boundary hunt: does ~10Gi slack absorb any of the copy before failing? |

3 legs max. All legs fresh RUN_ID; fill values parameterized (FILL_SIZE_GIB).

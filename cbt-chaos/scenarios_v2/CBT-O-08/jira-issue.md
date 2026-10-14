# CBT-O-08: Shrink the ceph pool quota below the backup size mid-cycle — ODF-native ENOSPC

**Purpose:** The ODF analog of F-08/I-05/T-04 capacity exhaustion: the pool is 105TiB at 0.9% used, so naive filling is infeasible — instead set a ceph pool quota (`ceph osd pool set-quota ocs-storagecluster-cephblockpool max_bytes <N>`) just below what the backup cycle needs, producing a real ceph-side ENOSPC on the RBD write path.

## Workflow

Full and incremental backup

## Test Objective / Description

Before the backup cycle starts, cap the block pool's max_bytes so the pool's existing usage (~292GiB stored, ~871GiB raw) plus the new backup data exceeds the quota mid-copy. The backup's RBD writes should fail with ceph's quota-exceeded error (EDQUOT/ENOSPC class) → clean backup failure. Sweep the quota headroom to find the boundary between success and clean failure.

## Chaos Target

ocs-storagecluster-cephblockpool quota (ceph osd pool set-quota max_bytes)

## Chaos Action

Set pool quota to current-usage + headroom; restore (set-quota max_bytes 0 = unlimited) after the leg

## When to Inject Chaos

Before the backup starts (quota applies throughout the copy; mid-copy set-quota is also ceph-effective immediately — the sweep may use it, but pre-set is deterministic)

## Injection Signal / Condition

Quota confirmed via `ceph osd pool get-quota` before backup creation

## Chaos Duration

Entire backup cycle (removed in a cleanup trap)

## Expected Behavior

Headroom > cycle need: backup succeeds (possibly slower near the boundary). Headroom < need: RBD writes hit quota-exceeded → backup fails cleanly (Done=True with a no-space-class reason per the I-05 r02 precedent: `Backup has failed: No space left on device`), tracker holds the previous checkpoint with VMI alive, VM unpauses/recovers once the quota is lifted. No corruption; no false success.

## Recovery

`ceph osd pool set-quota ocs-storagecluster-cephblockpool max_bytes 0` (unlimited) — MUST run even on trigger abort (trap). Verify pool writable afterwards.

## How to Verify

Quota before/during/after (toolbox); backup Done reason; tracker state (expect FULL checkpoint held if incremental failed, per I-05 r02 semantics); fresh-PVC recovery backup succeeds after quota lift; guest VM state (pause detection via VMI conditions).

## Expected Outcome

A measured quota-headroom floor for the full+incremental cycle on RBD — the ODF-native version of T-04's 80-100GiB HPP floor — plus confirmation of clean-failure semantics.

## Priority

P1

## Technical Scenario

Direct ceph CLI via the rook-ceph-tools pod (no krkn plugin expresses pool quotas; krkn pvc-scenarios fills PVCs, which is O-09's job — this scenario is ceph-native)

## Chaos Phase

Operation start

## Sweep / combination matrix

| Leg | Quota headroom above current usage | Hypothesis |
|---|---|---|
| o08a | 200GiB | Comfortably above the ~60GiB cycle need (3×80/30GiB PVCs, thin) → succeeds |
| o08b | 100GiB | At the boundary — PVC admission may pass but copy hits quota → clean failure |
| o08c | 40GiB | Below need → quota-exceeded early in the full copy |

3 legs max. Quota values computed at run time from live `ceph df` usage (the pool grows as other tenants write); the leg variable is the headroom, not an absolute byte count. RBD images are thin-provisioned: the FULL PVC (80Gi) consumes quota only as blocks are written (~17.5GiB data + qcow2 overhead per cycle stage).

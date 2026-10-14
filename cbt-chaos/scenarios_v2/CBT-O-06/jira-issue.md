# CBT-O-06: Kill OSD pods during the backup copy — sweep the degradation threshold

**Purpose:** With size=3 replication across 54 OSDs, killing OSDs mid-copy should degrade (slower writes, recovery traffic) rather than fail — until enough OSDs die that placement groups lose quorum. Sweep the kill count to find where the RBD-backed copy measurably degrades and where it fails.

## Workflow

Full backup

## Test Objective / Description

Delete N OSD pods (pods rook-ceph-osd-<id>, label app=rook-ceph-osd, namespace openshift-storage) mid-copy, sweeping N. Measure backup duration vs baseline, ceph health transitions (HEALTH_OK → HEALTH_WARN → HEALTH_ERR), and copy failure. Rook's disruptionManagement (managePodBudgets) may pace replacements — OSD replacement is minutes, not seconds.

## Chaos Target

rook-ceph-osd pods in openshift-storage (54 total; label app=rook-ceph-osd)

## Chaos Action

Delete N OSD pods mid-copy (random selection by the plugin; record which OSD IDs died)

## When to Inject Chaos

During the active backup copy (Progressing-by-type gate)

## Injection Signal / Condition

Full backup Progressing == True

## Chaos Duration

Immediate kills; replacement/recovery continues past the copy window (minutes)

## Expected Behavior

Low N: copy completes, possibly slower (remaining OSDs + pg rebalance absorb). Mid N: HEALTH_WARN, degraded objects, copy slower. High N: HEALTH_ERR, some PGs inactive — RBD writes to affected PGs block or error → backup fails cleanly or stalls to the workflow timeout. Never a false success.

## Recovery

Rook reschedules OSD pods automatically (PDB-paced). Ceph backfill restores full replicas over minutes-hours; health returns to HEALTH_OK (verify before the next leg).

## How to Verify

Backup Done reason + duration; ceph health + `ceph osd tree` before/during/after (via rook-ceph-tools pod); osd pod replacement events; follow-up incremental + restore verify on success; pool returns to active+clean before family proceeds.

## Expected Outcome

A measured "N OSDs dead → copy outcome" mapping: the redundancy margin of the backup write path under concurrent OSD loss.

## Priority

P1

## Technical Scenario

pod-scenarios (direct-krkn pod_disruption with label_selector app=rook-ceph-osd, namespace_pattern openshift-storage, kill=N — krknctl's random selection across nodes is acceptable here since any OSD subset is an equivalent sample; record the IDs)

## Chaos Phase

Active operation

## Sweep / combination matrix

| Leg | OSDs killed (N) | Rationale |
|---|---|---|
| o06a | 1 | Single-OSD loss — expect no copy effect (size=3 absorbs) |
| o06b | 5 | Multiple failure domains — HEALTH_WARN, measurable rebalance contention |
| o06c | 12 | ~22% of OSDs — expect PG degradation; seek copy slowdown or failure |

3 legs max. Escalate only to first degradation/failure (T-family rule). Pool must be active+clean and HEALTH_OK before each leg.

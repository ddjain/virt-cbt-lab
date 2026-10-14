# CBT-O-12: Combine OSD kills with in-ceph I/O contention during the backup copy

**Purpose:** X-04-style combined-failure attribution on ODF: simultaneous OSD loss (reduced replica acks + recovery traffic) and heavy concurrent RBD client writes (O-10's mechanism) during the same copy — measure whether the combination fails or degrades where each alone did not, and whether the backup's Done reason attributes the dominant cause correctly.

## Workflow

Full backup

## Test Objective / Description

Apply both O-06's OSD kills (N OSD pods) and O-10's writer pods (W dsync writers on RBD PVCs) during the same copy window. Sweep the combination around the individually-measured no-effect points: if each alone was absorbed, does the combination cross the degradation/failure boundary (superlinear) or is it also absorbed (linear)?

## Chaos Target

Ceph data plane: OSD pods (kills) + shared pool/storage network (writer contention), simultaneously

## Chaos Action

Delete N OSD pods AND start W dsync writer pods at the Progressing gate

## When to Inject Chaos

During the active backup copy (Progressing-by-type gate), both injections within seconds of each other

## Injection Signal / Condition

Full backup Progressing == True

## Chaos Duration

OSD kills immediate (recovery continues past the window); writers self-terminate at 120s

## Expected Behavior

Absorbed (each-alone no-effect points): copy completes, possibly degraded. Crossing: copy slows ≥2× or fails cleanly with an accurate Done reason (X-04 precedent: the reason names the dominant cause). Ceph must recover to HEALTH_OK + active+clean post-leg; no corruption; no false success.

## Recovery

Rook OSD replacement (PDB-paced) + writer self-termination + PVC cleanup; verify health before any further O-leg.

## How to Verify

Backup Done reason + duration vs baseline; OSD dead-count timeline vs writer activity window; ceph health/pg series; attribution analysis (was the failure cause the OSD loss, the contention, or genuinely combined?); follow-up incremental + restore verify on success.

## Expected Outcome

A combined-failure attribution data point on ODF — whether the copy's failure mode under simultaneous data-plane stress is clean and correctly attributed.

## Priority

P2

## Technical Scenario

pod-scenarios (OSD kills, direct-krkn pod_disruption) + direct writer pods (O-10 mechanism) fired at the same gate

## Chaos Phase

Active operation

## Sweep / combination matrix

| Leg | OSDs killed (N) | Writers (W) | Rationale |
|---|---|---|---|
| o12a | 1 | 4 | Both at individually-no-effect levels — interaction probe |
| o12b | 5 | 16 | Mid combination — seek superlinear degradation |
| o12c | 5 | 48 | Contention-heavy combination — seek failure + attribution |

3 legs max; legs built from O-06/O-10's measured points (adjust N/W to sit just below each scenario's individually-observed degradation). Run after O-06 and O-10 have recorded thresholds.

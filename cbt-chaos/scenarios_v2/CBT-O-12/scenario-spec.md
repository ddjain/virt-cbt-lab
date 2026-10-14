# Scenario: O-12 combined OSD kills + in-ceph contention during the copy

## 1. Identity

- **Jira issue:** CBT-O-12 (P2, technical scenario: direct-krkn pod_disruption + direct writer pods)
- **Run family:** ODF combined-failure attribution (X-04 analog)
- **Precedents:** X-04 (combined io-hog + launcher kill — clean dominant-cause attribution); O-06 (OSD sweep); O-10 (writer sweep)

## 2. Objective and hypothesis

**Objective:** does simultaneous data-plane stress (OSD loss + client contention) cross a boundary that each alone does not, and is the failure cleanly attributed?

**Hypothesis:** OSD loss reduces write parallelism and adds recovery I/O; contention consumes the remaining headroom. The combination may be superlinear (degraded/failed where each alone was absorbed). On failure, the Done reason should name a dominant cause (X-04 named VMI death over I/O pressure).

## 3. Design

1. Guards: standard + HEALTH_OK + active+clean + golden-on-RBD; writer pods pre-created idle (O-10 pattern).
2. Background full backup; at the Progressing gate: (a) fire direct-krkn pod_disruption for N OSDs, (b) immediately `oc exec` the W writers (O-10 dsync recipe, 120s).
3. Telemetry: ceph health/osd-perf series; writer logs; backup wall.
4. Post-leg: OSD recovery + writer cleanup; HEALTH_OK + active+clean gate before family end.
5. Follow-up incremental + restore verify on success.

## 4. Target and validated disruption

- **Target:** shared ceph data plane; blast radius cluster-wide (OSD kills) + pool performance (writers). Exclusive-use window required.
- **Sizing:** (N,W) per matrix; N and W chosen from O-06/O-10's measured no-effect/degradation points.

## 5. Verification criteria

- Both injections evidenced inside the copy window (OSD pod deletions + writer START markers with timestamps).
- Outcome verdict NO_EFFECT / DEGRADED / FAILED with duration evidence.
- Attribution: on failure, the Done reason verbatim + event timeline — which cause dominates, and is the reason accurate?
- Ceph recovery: HEALTH_OK + active+clean restored post-leg.
- Tracker advances once; restore verify on success.

## 6. Pre-run guards

Standard; HEALTH_OK + active+clean; golden-on-RBD; no concurrent O-leg; O-06 and O-10 results recorded (the legs' N/W values key off their thresholds).

## 7. Uncertainties

- If O-06/O-10 both ended no-effect at max legs, o12c is the decisive probe; if either already degraded individually, o12a/b suffice and o12c is skipped (budget rule).
- PDB pacing may serialize the N OSD kills across the writer window — record achieved simultaneity from timestamps and judge by actual overlap.

## 8. Evidence

krkn log, writer logs, ceph series, backup outcome + duration, attribution analysis in the run report, trigger-checks.txt.

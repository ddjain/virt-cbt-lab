# CBT-O-01: Rebuild the RHEL9 golden image on RBD and baseline the ODF backup lifecycle

**Purpose:** Establish the ODF/RBD backend for the O-family: rebuild the RHEL9 golden image on ocs-storagecluster-ceph-rbd (CDI cannot cross-class smart-clone from the HPP golden — campaign learning #79), then run one clean full+incremental+restore-verify lifecycle on RBD to record the baseline timings every O-scenario's verdict math depends on.

## Workflow

Full and incremental backup (baseline; no chaos)

## Test Objective / Description

One-time prerequisite plus validation: (a) create DataVolume `rhel9-rbd-golden` (30Gi, ocs-storagecluster-ceph-rbd, registry source from the rhel9-guest imagestream digest), (b) publish DataSource `rhel9-rbd`, (c) run the standard workload (1000 × 15-20MiB) full+incremental+verify cycle with MANIFEST_VARIANT=odf against it, recording full/incremental copy durations, PVC bind times, and the VM's node placement.

## Chaos Target

None (prerequisite + baseline). This is the O-family's equivalent of a fixture run.

## Chaos Action

None. The golden rebuild itself is the action under validation.

## When to Inject Chaos

N/A

## Injection Signal / Condition

N/A

## Chaos Duration

N/A (golden import ~10-30 min one-time; lifecycle ~15-25 min)

## Expected Behavior

DV import Succeeded; DataSource resolvable; VM boots from an RBD root disk; full backup completes with a Done=True/Successfully reason; incremental chains to the full checkpoint; restore verification bit-exact. Copy durations differ from the HPP baseline (52-58s full / 16-17s incremental) — expect the RBD write path to be slower or comparable; record actuals.

## Recovery

N/A

## How to Verify

DV phase Succeeded; DataSource rhel9-rbd references the RBD PVC; run's tracker advances once per backup; restore verification passes; evidence recorded in the run dir (durations, VM node, rbd device visible in launcher's node `/dev/rbd*` during copy).

## Expected Outcome

A reusable RBD-backed rhel9 DataSource and a documented ODF baseline (durations, placement semantics) that O-02…O-12 verdict criteria reference.

## Priority

P1 (unblocks the whole family)

## Technical Scenario

None (fixture) — `make e2e TYPE=full` + `TYPE=incremental` with VM_DATA_SOURCE_NAME=rhel9-rbd, MANIFEST_VARIANT=odf

## Chaos Phase

Setup / prerequisite

## Sweep / combination matrix

| Leg | Variant | Notes |
|---|---|---|
| o01a | rhel9-rbd golden + full+incr+verify | The baseline run; only leg unless it fails |
| o01b (only on o01a anomaly) | repeat o01a with fresh RUN_ID | Distinguishes import flake from systematic |
| o01c (optional) | windows-golden (already RBD) VM_OS=windows baseline | Only if Windows O-scenarios are later desired |

Budget rule: one leg normally; the golden import is not re-run per scenario.

# Scenario: EXP-9 — Windows coverage: node-io-hog during a full backup (CBT-F-09 cross-OS)

## 1. Identity

- **Experiment ID:** EXP-9 (user-mandated Windows coverage; cross-OS corroboration of the F-09 baseline)
- **Same mechanism as CBT-F-09** (krknctl node-io-hog on the HostPath pool path during the full-backup active copy, trigger on the compound active-copy condition), with `VM_OS=windows` (Windows Server 2022 golden image, guest-agent-based workload/mutation/restore verification).

## 2. Objective

Establish the Windows-side behavior of the I/O-contention baseline (duration degradation vs the RHEL baseline, correctness preservation) and collect the Judge-mandated ride-alongs on a Windows guest:
1. **Natural ghost-event rate** (high-cadence events watch): does the "VMI backup status was lost" transient fire with the Windows guest agent? (Localizes the propagation source; free finding either way.)
2. **Guest-unfreeze assertion**: post-backup guest-side write/read (agent exec) — closes the freeze-leak question EXP-2's VMI-level check couldn't.
3. **Destination-size sanity check** (backup duration vs target PVC usage growth vs workload): the proven-cheap silent-corruption discriminator (EXP-7 class).

## 3. Workflow

`make e2e TYPE=full NAME=<RUN_ID> VM_OS=windows MANIFEST_VARIANT=default` + krknctl node-io-hog (same parameters as F-09: 8 workers × 2g × 1m, 90 s, node d38-h18-000-r660, pool path) → planned incremental + restore verification. Observer watches backup/tracker/VMI/events; ride-along measurements extracted from the same streams + a post-run agent-exec write test.

## 4. Measurements / classification

- Same criteria as F-09 (injection validity, Done/success/Full/one checkpoint, tracker advance, VM health, incremental+restore PASS) on Windows.
- Ghost-event presence/absence on the Windows run (vs 7/9 RHEL rate).
- Guest write/read success post-backup (unfreeze proof).
- Target-usage vs workload-size sanity (duration-vs-size plausibility).

## 5. Blast radius / safety

Identical to F-09 (single-node I/O pressure 90 s, run-scoped). Windows setup is slower (~10-15 min boot + OOBE); total ~30-40 min.

## 6. Evidence

`cbt-chaos/scenarios_v2/CBT-EXP-09/runs/<RUN_ID>/`: trigger.log, krknctl.log, hog-pods.yaml, full-backup.yaml, tracker.yaml, observer streams (incl. events for the ghost-event check), guest write-test output.

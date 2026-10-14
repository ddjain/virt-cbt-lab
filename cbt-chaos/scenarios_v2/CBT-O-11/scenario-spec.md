# Scenario: O-11 rook-ceph-operator kill mid-copy

## 1. Identity

- **Jira issue:** CBT-O-11 (P3, technical scenario: pod-scenarios via direct-krkn pod_disruption)
- **Run family:** ODF component-attribution matrix (the control-plane null result)
- **Precedents:** O-02/O-03 (trigger shape); F-03/F-04-class (component-kill null results elsewhere)

## 2. Objective and hypothesis

**Objective:** prove the operator is outside the backup path.

**Hypothesis:** the operator reconciles desired state (DaemonSets, mon cluster membership); the backup's data path (kernel rbd device → OSDs) and attach path (csi plugins) do not consult it. A mid-copy kill is a no-op.

## 3. Design

1. Guards: standard + ceph HEALTH_OK + golden-on-RBD + operator Deployment Available.
2. Background full backup.
3. At Progressing gate: direct-krkn pod_disruption with name_pattern=`^rook-ceph-operator-`, namespace_pattern=openshift-storage, kill=1.
4. Verify replacement Ready; backup outcome; ceph health series; follow-up incremental + restore verify.

## 4. Target and validated disruption

- **Target:** rook-ceph-operator pod (single replica; runs on a storage node, tolerates the storage taint).
- **Blast radius:** paused ceph reconciliation for the replacement window only. No client-facing effect expected.

## 5. Verification criteria

- Injection: operator pod UID changed in window.
- Copy: Done=True/Successfully with duration ≈ O-01 baseline (null result expected — a PASS here is "no effect").
- HEALTH_OK maintained; no new warning events on the vmbackup/PVC objects in the window.
- Tracker advances once; restore verify passes.

## 6. Pre-run guards

Standard; operator Available; HEALTH_OK.

## 7. Uncertainties

- o11b teardown window is sub-second (F-13 measured) — the superset gate applies if that leg is run.
- None material for o11a; this is deliberately the family's cheapest leg.

## 8. Evidence

krkn log, operator pod pre/post, backup outcome + duration, ceph health series, trigger-checks.txt.

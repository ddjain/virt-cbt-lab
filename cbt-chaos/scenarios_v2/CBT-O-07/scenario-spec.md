# Scenario: O-07 kill ceph mon/mgr pods mid-copy

## 1. Identity

- **Jira issue:** CBT-O-07 (P2, technical scenario: pod-scenarios via direct-krkn pod_disruption)
- **Run family:** ODF control-plane disruption (contrast to O-06 data plane)
- **Precedents:** O-06 (same trigger shape, OSD targets); F-12 (leader-election semantics analog)

## 2. Objective and hypothesis

**Objective:** does the copy (or its attach/bookkeeping path) depend on mon quorum or the mgr?

**Hypothesis:** established RBD sessions stream OSD-direct; single mon/mgr kills are no-ops for the copy. A 2-of-3 mon kill stresses quorum — ceph's graceful member removal keeps quorum at 1-of-3 during replacement, but the window is client-visible for new watches (the backup's attach path, if it lands there, could stall).

## 3. Design

1. Guards: standard + ceph HEALTH_OK + quorum 3/3 (ceph quorum_status) + golden-on-RBD.
2. Background full backup.
3. At Progressing gate: direct-krkn pod_disruption with the leg's label_selector (app=rook-ceph-mgr / app=rook-ceph-mon), kill=N, parallel, krkn_pod_recovery_time=1200.
4. Sample `ceph quorum_status` + `ceph health` every 5s during the window.
5. Follow-up incremental + restore verify on success; HEALTH_OK gate before family proceeds.

## 4. Target and validated disruption

- **Target:** mon-a/b/c (Deployment-based on this cluster; labels app=rook-ceph-mon) and mgr-a/b (app=rook-ceph-mgr) in openshift-storage.
- **Blast radius:** cluster-wide ceph control plane for the replacement window. o07c risks temporary quorum loss — all ceph clients cluster-wide. Exclusive-use window required.

## 5. Verification criteria

- Injection: pod deletions + quorum membership deltas evidenced.
- Copy: NO_EFFECT / DEGRADED / FAILED with health-series correlation.
- Post-leg: HEALTH_OK restored before the next O-leg.
- Tracker advances once; restore verify on success.

## 6. Pre-run guards

Standard; HEALTH_OK; quorum 3/3 with all mons in quorum; golden-on-RBD; no concurrent O-leg.

## 7. Uncertainties

- Mon pods are Deployments here (not the classic rook mon StatefulSet/NodeLost model) — replacement cadence is Deployment-speed (~30-60s); quorum shrink window correspondingly short.
- If o07c loses quorum, kubevirt RBD volumes cluster-wide may pause I/O — the VM itself could PausedIOError; classify per the I-04 semantics (clean, recoverable) and stop the sweep.

## 8. Evidence

krkn log; quorum_status/health series; mon/mgr pod pre/post; backup outcome; trigger-checks.txt.

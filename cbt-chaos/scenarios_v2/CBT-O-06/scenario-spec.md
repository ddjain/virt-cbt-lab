# Scenario: O-06 OSD pod kill sweep during the backup copy

## 1. Identity

- **Jira issue:** CBT-O-06 (P1, technical scenario: pod-scenarios via direct-krkn pod_disruption)
- **Run family:** ODF data-plane redundancy sweep
- **Precedents:** T-family sweep methodology; O-02/O-03 (same direct-krkn trigger shape); rook disruptionManagement (managePodBudgets: true on this cluster)

## 2. Objective and hypothesis

**Objective:** the N-OSDs → copy-outcome curve.

**Hypothesis:** size=3 replication over 54 OSDs absorbs small N with no copy effect; degradation appears when rebalance traffic contends with copy writes (mid N); failure requires PG quorum loss across failure domains (high N — deliberately not pursued past o06c).

## 3. Design

1. Guards: standard + ceph HEALTH_OK + all PGs active+clean (ceph pg stat via toolbox) + golden-on-RBD. **Between legs:** wait for active+clean again.
2. Background full backup.
3. At Progressing gate: direct-krkn pod_disruption YAML with label_selector=app=rook-ceph-osd, namespace_pattern=openshift-storage, kill=N, execution=parallel, krkn_pod_recovery_time=1800 (OSD replacement is PDB-paced minutes).
4. During + after: `ceph health`, `ceph osd dump | grep up` snapshots via the rook-ceph-tools pod; record killed OSD IDs from pod_disruption's selection (krkn log prints deleted pod names).
5. Follow-up incremental + restore verify on success.

## 4. Target and validated disruption

- **Target:** random OSD pods (any subset is statistically equivalent — 54 OSDs spread over 18 storage nodes, rack failureDomain).
- **Blast radius:** cluster-wide ceph (all tenants of ocs-storagecluster-cephblockpool). Coordinate with campaign owner: run during exclusive cluster use. Recovery traffic continues past the copy window.
- **Ceph sizing:** 54 OSDs, size=3, min_size computed default (2); pool 292GiB stored / 105TiB raw.

## 5. Verification criteria

- Injection: N pod deletions in window (krkn log deleted-pod lines + osd dump deltas).
- Copy verdict: NO_EFFECT / DEGRADED (≥2× baseline) / FAILED, with ceph health correlation.
- Post-leg: health returns to HEALTH_OK + active+clean before any further O-leg (family ordering rule).
- Tracker advances once; restore verify on success.

## 6. Pre-run guards

Standard; ceph HEALTH_OK AND `ceph pg stat` active+clean; golden-on-RBD; no other O-leg running (shared blast radius).

## 7. Uncertainties

- Rook PDB may pace even 12 kills over minutes (killing more than the disruption budget serially) — if so, o06c's effective simultaneity is lower; record actual deletion timestamps and judge by achieved dead-count at copy end, not requested N.
- pod_disruption's recovery monitor (1800s) may exceed krkn's run — accept monitor-failure rc with event proof (bugs #5 class).
- Ceph's client behavior on degraded-not-inactive PGs is the real unknown: writes may just slow (reduced replica acks) — the most likely o06c outcome.

## 8. Evidence

krkn log, ceph health/osd-dump/pg-stat series, killed-OSD-ID list, backup duration + Done reason, trigger-checks.txt with per-leg verdict.

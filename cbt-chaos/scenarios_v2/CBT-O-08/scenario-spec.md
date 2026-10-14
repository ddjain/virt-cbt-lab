# Scenario: O-08 ceph pool-quota shrink — ODF-native ENOSPC

## 1. Identity

- **Jira issue:** CBT-O-08 (P1, technical scenario: direct ceph CLI via rook-ceph-tools — no krkn plugin covers pool quotas)
- **Run family:** ODF capacity exhaustion
- **Precedents:** I-05 r02 (RBD dest ENOSPC: clean failure, tracker holds FULL, VMI alive); T-04 (HPP capacity floor methodology); F-08 (dest-fill ENOSPC)

## 2. Objective and hypothesis

**Objective:** the ODF-native capacity floor via pool quota, with clean-failure semantics.

**Hypothesis:** ceph enforces pool quotas on write (objects fail with quota-exceeded once max_bytes is hit); the RBD client surfaces it as ENOSPC to QEMU → the backup fails cleanly with a no-space reason, tracker holds, VM recovers after quota lift — the same semantics I-05 r02 proved for per-volume ENOSPC.

## 3. Design

1. Guards: standard + ceph HEALTH_OK + golden-on-RBD + quota currently unlimited (`ceph osd pool get-quota` max_bytes=0) + record current usage (`ceph df -f json` → pools[ocs-storagecluster-cephblockpool].bytes_used).
2. Set quota: `ceph osd pool set-quota ocs-storagecluster-cephblockpool max_bytes $((usage + headroom))`; confirm with get-quota.
3. Install an EXIT trap + explicit cleanup stage that restores `max_bytes 0` — the quota is cluster-global and MUST NOT leak past the run.
4. Run the full lifecycle; on success follow with incremental (the cycle's cumulative usage is what crosses mid-range quotas).
5. Verdict: record Done reason, tracker state (I-05 r02 semantics expected on failure), VM pause events, post-quota-lift recovery backup on a fresh PVC.

## 4. Target and validated disruption

- **Target:** the block pool quota — cluster-global for ALL tenants of ocs-storagecluster-cephblockpool. Exclusive cluster use required during the leg; the quota is the blast radius.
- **Sizing:** current pool usage ~871GiB raw (bytes_used of the pool ~292GiB stored); cycle adds ~60GiB-ish raw consumption across 3 PVCs (80/80/30Gi thin, ~17.5GiB data each stage).

## 5. Verification criteria

- Quota active during the cycle (get-quota snapshots before/mid/after).
- Failure legs: clean terminal failure with a no-space-class Done reason; tracker holds the previous checkpoint (VMI alive); no partial-backup false success; fresh-PVC backup succeeds after quota lift (recovery proof).
- Success legs: normal completion; the headroom that still succeeds is the measured floor.
- Pool writable after cleanup (post-run write probe via toolbox).

## 6. Pre-run guards

Standard; HEALTH_OK; quota unlimited pre-run (a leftover quota from a prior aborted run is a hard abort); exclusive-use coordination.

## 7. Uncertainties

- Ceph quota enforcement point: pool quotas are enforced on new object writes — an in-flight RBD client may buffer some writes before the error surfaces; the failure timestamp vs quota-hit timestamp is evidence, not assumption.
- The VM's own root disk writes also consume the same pool quota — a quota set too tight could ENOSPC the GUEST mid-mutation (I-04 r01 PausedIOError semantics) rather than the backup; the sweep values keep guest headroom in mind (guest mutation ~17.5GiB happens before backup creation).
- Whether the kubevirt backup controller's Done reason names no-space explicitly (I-05 r02 precedent says yes for per-volume; pool-level should surface identically through the RBD client).

## 8. Evidence

get-quota snapshots, ceph df series, vmbackup conditions + events, tracker samples, VMI conditions (pause), recovery-run result, trigger-checks.txt.

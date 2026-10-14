# Scenario: O-10 in-ceph I/O contention sweep during the copy

## 1. Identity

- **Jira issue:** CBT-O-10 (P2, technical scenario: direct RBD-PVC writer pods — krkn's io-hog hostPath mechanism cannot reach ceph)
- **Run family:** ODF I/O contention threshold hunt (T-03 analog)
- **Precedents:** T-03 (sweep methodology, dsync rationale); I-05 filler (privileged pod + PVC mount shape); X-04 (io-hog + attribution)

## 2. Objective and hypothesis

**Objective:** the W → copy-degradation curve for ceph-internal contention.

**Hypothesis:** the backup copy's RBD writes and W writers' dsync writes share OSD IOPS, storage-network bandwidth, and PG locks on the same pool; degradation appears when aggregate writer load saturates the OSD fleet or the network — well above a handful of clients given 54 SSD OSDs, so the interesting range is 16-48.

## 3. Design

1. Guards: standard + ceph HEALTH_OK + golden-on-RBD.
2. Pre-create W PVCs (10Gi, ocs-storagecluster-ceph-rbd) + writer pods BEFORE the backup starts (scheduling latency must not eat the window); writers sleep until released (a marker file / startup gate via `sleep infinity` then exec, or simply start them at the gate).
3. Background full backup; at the Progressing gate, `oc exec` (or create) the writers: `stress-ng --hdd 4 --hdd-bytes 10g --hdd-write-size 1m --hdd-opts dsync --timeout 120` inside each pod against its PVC mount (the T-03 dsync parameters, adapted to ceph-visible writes — the PVC mount IS an RBD filesystem, so dsync forces object writes, not page-cache).
4. Writers run on non-storage worker nodes (nodeSelector on a worker lacking the cluster.ocs.openshift.io/openshift-storage label) — contention target is ceph, not node resources.
5. Telemetry: `ceph osd perf` + `ceph df` deltas during the window; writer logs (bytes); backup wall vs O-01 baseline.
6. Cleanup: delete writer pods + PVCs post-leg; verify HEALTH_OK.

## 4. Target and validated disruption

- **Target:** the shared ceph data plane (pool ocs-storagecluster-cephblockpool).
- **Blast radius:** cluster-wide ceph performance during the window; capacity impact bounded (10Gi × W thin, deleted after).
- **Sizing:** W ∈ {4, 16, 48}; 4 hdd workers per pod → 16-192 concurrent dsync streams.

## 5. Verification criteria

- All W writers Running and writing during the copy window (logs with start/end timestamps + bytes).
- Duration verdict: NO_EFFECT / DEGRADED (≥2× O-01 baseline) / FAILED — with OSD perf correlation.
- Ceph HEALTH_OK preserved (degradation, not damage).
- Tracker advances once; incremental + restore verify on success.

## 6. Pre-run guards

Standard; HEALTH_OK; storage nodes' OSD pods healthy; writer namespace pre-created (krkn hog bug #9 analog — we create pods directly, but namespace hygiene still applies).

## 7. Uncertainties

- Whether 48 writers saturate 54 SSD OSDs at 1m dsync writes — a no-effect ceiling at o10c is a valid result (T-01/T-02 precedent); the OSD perf series will show whether the fleet was actually loaded.
- Writer pods on non-storage nodes route through the same spine — if the network (not OSDs) saturates first, the attribution evidence (osd perf queue counts vs network counters) decides.
- The VM's own root-disk writes share the pool — a PausedIOError on the VM under extreme contention is the I-04 r01 clean-recovery semantics, classified separately (not a backup failure per se).

## 8. Evidence

writer pod logs, PVC list, ceph osd perf/df series, backup wall + Done reason, trigger-checks.txt with leg verdict.

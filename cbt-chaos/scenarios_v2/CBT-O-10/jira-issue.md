# CBT-O-10: Saturate ceph with concurrent RBD client writes — in-ceph I/O contention sweep

**Purpose:** The ODF analog of T-03's same-device I/O sweep: instead of contending on a local disk, contend INSIDE ceph — many concurrent RBD clients writing to the same pool the backup uses, sweeping writer count to find where the RBD-backed copy degrades (≥2× baseline) or fails.

## Workflow

Full backup

## Test Objective / Description

Launch W concurrent writer pods, each with its own RBD PVC on ocs-storagecluster-ceph-rbd, running direct dsync I/O (fio/stress-ng class) during the backup copy. The OSDs, the storage network, and the same pool's PGs are shared with the backup's writes — measure the copy's degradation curve vs W.

## Chaos Target

The ceph data plane: ocs-storagecluster-cephblockpool OSDs + storage network, shared between the backup copy and W concurrent RBD writers

## Chaos Action

W privileged writer pods with dedicated 10Gi RBD PVCs, `stress-ng --hdd`/fio dsync writes, self-terminating at DURATION

## When to Inject Chaos

During the active backup copy (Progressing-by-type gate)

## Injection Signal / Condition

Full backup Progressing == True

## Chaos Duration

120 seconds (RBD writes are not page-cache-absorbed end-to-end — the window must span the whole copy)

## Expected Behavior

Low W: copy unaffected or mildly slower (54 OSDs absorb; the pool is huge). Mid W: OSD/network saturation → copy slowdown ≥2× (DEGRADED). Extreme W: ceph backpressure/queueing → copy stalls or fails cleanly; VM may PausedIOError on its own RBD root disk (classify separately per X-01 semantics). No corruption.

## Recovery

Writers self-terminate at DURATION; PVCs deleted in cleanup; ceph health verified post-leg.

## How to Verify

Backup duration vs O-01 baseline; writer pod logs (bytes written); ceph health + `ceph osd perf`/pool throughput during window; VM state; follow-up incremental + restore verify on success.

## Expected Outcome

A writer-count threshold for copy degradation — the ceph-side sensitivity number T-03 produced for the local-device case.

## Priority

P2

## Technical Scenario

node-io-hog semantics via direct pods on RBD PVCs (the krkn hog image's io variant writes to a hostPath — useless for ceph contention; the campaign-proven direct-pod pattern with PVC mounts is the sanctioned mechanism, mirroring the I-05 filler pod's PVC-mounting shape)

## Chaos Phase

Active operation

## Sweep / combination matrix

| Leg | Writers (W) | Fixed | Rationale |
|---|---|---|---|
| o10a | 4 | 10Gi PVC each, dsync 1m blocks, 120s | Mild — 4 extra clients on 54 OSDs |
| o10b | 16 | same | Mid — measurable OSD/network load |
| o10c | 48 | same | ~1 writer per OSD — saturation seek |

3 legs max, stop at first ≥2× degradation or failure (T-family rule). Writers run on NON-storage nodes where possible (worker label without cluster.ocs.openshift.io/openshift-storage) so the writer pods' own host resources don't confound — the contention target is ceph, not the node.

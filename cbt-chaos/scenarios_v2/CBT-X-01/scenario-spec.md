# Scenario: Apply bounded memory pressure during backup

## 1. Identity

- **Jira issue:** CBT-X-01 — "Apply bounded memory pressure during backup" (P2, technical scenario: node-memory-hog, phase: active operation)
- **Run family:** cross-cutting resource pressure on the CBT worker node during full + incremental backup
- **Precedents:** I-08 (command-trigger gate on Progressing-by-type for precise in-copy injection); I-04/R-02 (hog-pod mechanics on this node; direct injection when krknctl semantics are insufficient)

## 2. Objective and hypothesis

**Jira objective:** measure backup behavior under controlled memory pressure while ensuring the pressure is low enough to avoid intentionally killing the VM; backup may slow down; the launcher VM must NOT be OOM-killed (if it is, that's a launcher-failure classification, not this scenario's result).

**Product questions:**
1. Does bounded memory pressure on the CBT worker node during the copy slow the backup or change its outcome?
2. Does the launcher VM (and its compute container) survive — no OOM kills, restartCount unchanged?
3. Is the data still bit-exact and the tracker consistent, with a clean follow-up pass?

## 3. Design

krknctl node-memory-hog natively supports `--chaos-duration 90 --memory-consumption <pct> --node-selector kubernetes.io/hostname=d38-h18-000-r660 --namespace <ns>` and the triggers group (`--trigger-command`) for gating on active copy. Sizing: node has ~500GiB allocatable with ~61GiB (11%) used — the VM compute container has no memory limit? (verify at trigger time via launcher pod spec) — bounded pressure of 40% (~200GiB) leaves ample headroom and cannot OOM the VM whose RSS is bounded by its configured guest memory (verify from VMI spec). stress-ng vm workers allocate and hold; 90s duration.

Gate: command trigger on the full backup Progressing-by-type (I-08-proven jsonpath), so the hog runs during the copy.

Legs:
1. Full backup with hog active during copy (TYPE=full, hog gated on Progressing).
2. Incremental pass after (clean, no hog) to validate tracker chain + a follow-up clean run (Jira: "clean follow-up run").
3. Verifications: no OOMKill events on the node (node events + kubelet stats), launcher restartCount unchanged, backup Done=True success with type Full, tracker advances exactly once, restore verification bit-exact (workflow's own final-pass verify), hog pod exits after 90s.

krknctl exit status + hog pod logs captured. Memory telemetry: `oc adm top node` snapshots before/during/after.

## 4. Target and validated disruption

**Target:** CBT worker node memory (d38-h18-000-r660).
**Action:** stress-ng vm workers holding ~40% of node memory for 90s.
**Window:** full backup Progressing (copy active).
**Blast radius:** node-local; VM RSS is bounded by guest memory config (~16GiB); node has 500GiB; 40% hold leaves >250GiB free. Other pods on the node: the VM launcher + plugin pods (tens of GiB total).

## 5. Verification criteria

- Hog ran during copy (trigger satisfied → hog pod Running while backup Progressing).
- Backup Done=True success, type Full, duration recorded (vs 52-58s baseline).
- Launcher restartCount unchanged, VMI Running, no OOMKill events.
- Tracker advances exactly once to the full checkpoint.
- Incremental follow-up pass clean; workflow final verification PASS (bit-exact hashes).
- Hog self-terminated at 90s.

## 6. Pre-run guards

- Node memory ≥80% free at start (verified: 11% used).
- VM guest memory from VMI spec recorded (expect ~16GiB).
- HostPath pool ≥300GiB free.
- RUN_ID collision guards.

## 7. Uncertainties

- krknctl node-memory-hog's `--memory-consumption` percentage is of TOTAL node memory; 40% of 503GiB ≈ 201GiB held. Safe margin; if the plugin's own pod is BestEffort it could be OOMKilled by the kernel under pressure — that's the hog failing, not the VM; watch hog pod status.
- Whether the backup slows measurably: copy is page-cache-heavy; memory pressure may actually force writeback earlier. Duration delta is a measurement, not a pass/fail.

## 8. Evidence to capture

krkn log, hog pod logs, `oc adm top node` snapshots, launcher pod status (restartCount, container state), VMI spec memory, backup object + timing, tracker states, workflow verify outputs, node OOM events query.

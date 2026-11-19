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

krknctl node-memory-hog supports `--chaos-duration 90 --memory-consumption <pct> --node-selector kubernetes.io/hostname=<node> --namespace <ns>` plus the triggers group for gating on active copy. **Verified 2026-11-14 (r01): the plugin is deterministically broken on this cluster** — its hog image wrapper (`/stress-ng/run.sh`) writes `hog-jobfile.conf` to a read-only cwd and aborts (`temp-path '.' must be readable and writeable`). Executed run r02 used the user-approved fallback: the same hog image run as a direct privileged pod with an emptyDir working dir (see `runs/20261114-cbtx01-r02/run-report.md`). Sizing: ODF workers have ~512GiB allocatable at 1–6% used; the launcher node is resolved at trigger time (r02: d39-h06-000-r660, worker). VM guest memory is 4Gi (manifest vm-large-odf.yaml); stress-ng `vm 1 / vm-bytes 95% / vm-keep / timeout 90` held ~95% of container-visible node memory (node usage peaked 89% of allocatable), leaving ~25GiB headroom — accepted by the user over the original 40%.

Gate: command trigger on the full backup Progressing-by-type (I-08-proven jsonpath), so the hog runs during the copy.

Legs:
1. Full backup with hog active during copy (TYPE=full, hog gated on Progressing).
2. Incremental pass after (clean, no hog) to validate tracker chain + a follow-up clean run (Jira: "clean follow-up run").
3. Verifications: no OOMKill events on the node (node events + kubelet stats), launcher restartCount unchanged, backup Done=True success with type Full, tracker advances exactly once, restore verification bit-exact (workflow's own final-pass verify), hog pod exits after 90s.

krknctl exit status + hog pod logs captured. Memory telemetry: `oc adm top node` snapshots before/during/after.

## 4. Target and validated disruption

**Target:** CBT worker node memory (launcher node resolved at vm-setup; r02: d39-h06-000-r660, worker).
**Action:** stress-ng vm worker holding ~95% of node memory for 90s (user-approved over the original 40%; ~25GiB headroom remained).
**Window:** active backup copy (PVC Bound + launcher + Done≠True + "Backup started" in launcher logs).
**Blast radius:** node-local; VM RSS bounded by guest memory config (4Gi); other pods on the node: the VM launcher + plugin pods (tens of GiB total). Node MemoryPressure stayed False throughout the executed run.

## 5. Verification criteria

- Hog ran during copy (trigger satisfied → hog pod Running while backup Progressing).
- Backup Done=True success, type Full, duration recorded (vs control-run copy duration; rhel9/large-odf full copy ≈ 64–67s).
- Launcher restartCount unchanged, VMI Running, no OOMKill events.
- Tracker advances exactly once to the full checkpoint.
- Incremental follow-up pass clean; workflow final verification PASS (bit-exact hashes).
- Hog self-terminated at 90s.

## 6. Pre-run guards

- Node memory ≥80% free at start (r02: 6% used).
- VM guest memory from VMI spec recorded (r02: 4Gi).
- Full redo on the same RUN_ID requires deleting the vmbackup + PVC **and the tracker**, else the redo types as Incremental.
- RUN_ID collision guards.

## 7. Uncertainties

- krknctl node-memory-hog's `--memory-consumption` percentage is of TOTAL node memory; 40% of 503GiB ≈ 201GiB held. Safe margin; if the plugin's own pod is BestEffort it could be OOMKilled by the kernel under pressure — that's the hog failing, not the VM; watch hog pod status.
- Whether the backup slows measurably: copy is page-cache-heavy; memory pressure may actually force writeback earlier. Duration delta is a measurement, not a pass/fail.

## 8. Evidence to capture

krkn log, hog pod logs, `oc adm top node` snapshots, launcher pod status (restartCount, container state), VMI spec memory, backup object + timing, tracker states, workflow verify outputs, node OOM events query.

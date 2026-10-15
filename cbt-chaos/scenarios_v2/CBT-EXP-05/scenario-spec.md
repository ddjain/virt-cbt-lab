# Scenario: EXP-5 — Stale-reconcile induction via SIGSTOP/SIGCONT of virt-controller at the backup completion boundary

## 1. Identity

- **Experiment ID:** EXP-5 (adaptive; campaign's 5th experiment)
- **Hypothesis source:** campaign cross-run observation (transient "Backup has failed: VMI backup status was lost" at the success instant, 6/7 runs incl. abort cleanup) + kubevirt source (informer-cache reconcile can hold stale VMI-backup-status views around the cleanup→Done transition) + EXP-3's RV-ordering proof that pod deletion cannot enter the sub-second window. A stopped-and-resumed process is the only cheap mechanism that makes one reconcile span the boundary with stale state.
- **Judge-approved design:** leg0 = instrumented routine backup (organic capture at the observed ~5/6 natural rate, with controller logs — the strongest possible artifact if it fires); legs 1-2 = SIGSTOP at the detach edge, hold 3 s / 2 s, SIGCONT (liveness-probe budget: 8×10 s = 80 s to kill; holds are >25× under).

## 2. Objective / defect hypothesis

A virt-controller reconcile that spans the VMI-state-cleanup→Done boundary with stale cached state emits the observed failure-shaped transient. Determining whether that emission is EVENT-ONLY (misleading monitoring signal; self-heals) or a CONDITION FLIP (terminal state overwritten — a reportable correctness defect for GitOps/condition-watching consumers) is the primary deliverable (C1). Secondary: self-heal behavior (C2) and control criteria (C3).

## 3. Workflow

- **leg0:** fresh VM + full backup, NO injection; high-cadence vmbackup/events watch + controller log capture (--since=10m at leg end).
- **legs 1/2:** fresh VM + full backup with a background watcher: at Progressing=True ∧ reason "detaching backup target pvc" → SIGSTOP pid 1 of the leader container (oc exec — instant, no debug-pod latency) → verify /proc/1/stat state T (fail-closed; resume and abort leg if not) → hold 3 s (leg1) / 2 s (leg2) → SIGCONT → verify state S/R. Then incremental + restore verification on the same VM. Controller restartCount must be unchanged (C3) — else the leg degrades to an EXP-3-style kill and is labeled as such.

## 4. Named criteria

- **C1 (primary):** emission mode of the "VMI backup status was lost" transient — event-only vs condition flip. Evidence: vmbackup conditions resourceVersion at the emission instant (from watch stream, sub-second), any post-Done condition transition, controller log line at the source.
- **C2:** self-heal — post-Done convergence back to Success on subsequent reconciles; how many reconciles.
- **C3 (control):** backup completes Done=True/success; restore hashes clean; controller pod restartCount unchanged across the hold; process resumed (state S/R verified).

## 5. Measurements / classification

- Per leg: SIGSTOP/SIGCONT UTC timestamps, process state verification (T during hold, S/R after), hold duration, detach-edge detection time, full backup terminal state/reason, condition-transition sequence with RVs, controller log window, restartCount, incremental chain + restore hashes.
- **PASS (product resilient):** all legs complete correctly, no condition flip (event-only transients recorded as the known observation). **FAIL (product defect):** any condition flip / persistent non-Success terminal state / restore mismatch. **INVALID:** injection fail-closed or probe-killed controller (leg labeled kill-degraded).

## 6. Blast radius / safety

SIGSTOP of one controller replica's process for 2-3 s (probe budget 80 s — >25× margin); the standby replica continues serving. If the leader is mid-reconcile, the reconcile pauses and resumes — no state is destroyed (unlike pod deletion). Fail-closed: if state T is not verified, the process is resumed immediately and the leg aborts. Run-scoped VMs; shared component is the controller process only.

## 7. Evidence

`cbt-chaos/scenarios_v2/CBT-EXP-05/runs/<RUN_ID>/`: trigger.log, legN-inject-result.txt, legN-final-backup.yaml, legN-events.txt, legN-controller.log; lifecycle JSON under `runs/<RUN_ID>/` (leg0) and `runs/<RUN_ID>-l{1,2}next/`; observer streams.

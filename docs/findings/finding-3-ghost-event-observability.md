# Finding 3: "Backup has failed: VMI backup status was lost" — a two-sided observability defect

**Severity:** Medium (observability/monitoring) · **Class:** misleading event signal · **Reproducible:** PARTIALLY — the spurious-on-success firing is probabilistic (7/9 RHEL runs, NOT deterministic); the sole-signal-on-failure role is deterministic (tied to Finding 2) · No separate bug ticket (folded into Findings 1 & 2 tickets as the observability component)

## 1. Summary

The Warning event `VirtualMachineBackupFailed: "Backup has failed: VMI backup status was lost"` fires at the instant backups complete **successfully** (observed on 7/9 RHEL campaign runs), making event-based monitoring alarm on every healthy backup. Simultaneously — and far worse — this same event is the **only visible trace of real copy failures**: in Finding 2 (EXP-7), the destination ENOSPC surfaced nowhere else in any object, condition, or event. The event is thus two-sided: **spurious-on-success and sole-signal-on-failure**. On Windows (1 run), it did not fire — localizing the mechanism toward the RHEL hotplug/fsfreeze code path.

## 2. Environment

- OpenShift 4.22 / OpenShift Virtualization 4.22.12; RHEL 9 guests (7/9 firing rate) and one Windows Server 2022 guest (0/1)
- All backup types (full and incremental), chaos and non-chaos runs alike

## 3. Scenario IDs where the event was characterized

| Run | Context | Fired? |
|---|---|---|
| 20261014-cbtf09-r04 … cbti04-r04 (4 baselines) | Successful completions under various chaos | Yes (multiple) |
| 20261014-exp05-r01 leg0 (routine, no chaos) | Routine successful backup | **No** (natural-rate sample) |
| 20261014-exp05-r01 r01b leg (archived harness-invalid) | Routine successful backup | **Yes — the decisive organic capture** (event rv 24940364 AFTER terminal Success rv 24940363) |
| 20261014-exp05-r01 legs 1-2 (SIGSTOP 3 s/2 s at completion edge) | Controller process frozen across the boundary | **No** (0/2 under injection) |
| 20261014-exp06-r01 / exp08-r01 | Backup wedges (Findings 1A/1B) | Yes (EXP-8 abort cleanup) |
| 20261014-exp07-r01/2/3 | Silent copy failure (Finding 2) | **Yes — the ONLY failure trace** |
| 20261014-exp09-r01 (Windows) | Successful full + incremental | **No** (0/1 on Windows) |

## 4. How the characterization was injected / captured

No dedicated chaos injection — the event was characterized through the campaign's standard high-cadence observer watches (events field-mode on `involvedObject.name=<backup>`), plus two targeted experiments:

1. **EXP-5 (SIGSTOP→hold→SIGCONT of the virt-controller leader at the completion boundary):** the Judge hypothesized the event stems from a stale-reconcile/informer-propagation race; if so, freezing the controller mid-boundary should induce it. Two legs (3 s and 2 s holds at ~1 s past the detach edge, process state T verified fail-closed, restartCount 0). **Result: the event did NOT fire under injection (0/2)** — the controller process stall is not the trigger.
2. **The organic capture (r01b):** a routine backup with no chaos fired the event; the watch stream's resourceVersion ordering proved it is **EVENT-ONLY**: the event write (rv 24940364) landed after the backup's terminal Success write (rv 24940363), the condition never left Success, and zero post-Done condition rewrites occurred in any campaign lifecycle.

## 5. What was expected vs what happened

- **Expected (hypothesis):** either (a) a condition-flip — a stale reconcile overwriting the terminal Success condition (a real state-corruption defect), or (b) an event-only transient (misleading but harmless signal).
- **What happened: (b) — EVENT-ONLY, proven by RV ordering.** The backup's conditions are always clean; only the event stream lies. However, the "harmless" framing collapsed when EXP-7 showed the same event is the only place a real copy failure leaves a trace — the event is simultaneously noise (on success) and the sole signal (on failure), which is the worst possible observability design: consumers cannot distinguish the two cases.

## 6. Reproducibility

- **Spurious-on-success: PROBABILISTIC, not deterministic** — 7/9 RHEL runs (≈78%), 0/2 under controller-freeze injection, 0/1 on Windows. It cannot be summoned on demand; it was captured organically by continuous watch streams (a polling-based observer would have missed it — proven when the EXP-1 trigger's point-in-time YAML snapshots missed a ~2-min `checkpointRedefinitionRequired` transient that the same run's watch stream caught).
- **Sole-signal-on-failure: DETERMINISTIC** — 3/3 EXP-7 reproductions showed the ENOSPC copy failure surfacing ONLY as this event.

## 7. Mechanism (inference, evidence-bounded)

Consistent with informer-cache propagation delay between the VMI-side backup-status removal and the controller's view around the completion transition. The SIGSTOP legs (0/2) show controller process scheduling alone doesn't trigger it; the Windows absence (0/1) points at the RHEL hotplug/fsfreeze path. [INFERENCE — the exact emission line was never captured in controller logs during an organic fire.]

## 8. Impact

- Event-based monitoring/alerting on `VirtualMachineBackupFailed` produces false alarms on most successful RHEL backups AND cannot be trusted as a failure signal (it fires either way).
- The real fix direction is two-sided: suppress the derivative event when the backup is already terminal, AND surface real copy errors (with their actual reason, e.g. ENOSPC) on the backup CR itself.

## 9. Evidence paths

- Decisive RV-pair: `cbt-chaos/scenarios_v2/CBT-EXP-05/runs/20261014-exp05-r01/observer/full-backup-leg1.jsonl` (terminal rv 24940363) + `events-backup-leg1.jsonl` (event rv 24940364)
- SIGSTOP legs (0/2): same run, legs 1-2 streams + trigger.log (state T/S, restartCount 0)
- Sole-signal-on-failure: `cbt-chaos/scenarios_v2/CBT-EXP-07/runs/20261014-exp07-r{01,02}/observer/` (grep for ENOSPC across all streams = zero; ghost event present)
- Windows absence: `cbt-chaos/scenarios_v2/CBT-EXP-09/runs/20261014-exp09-r01/observer/events-backup.g2.jsonl` (success event only)
- Full characterization in `cbt-chaos/scenarios_v2/CBT-EXP-05/runs/20261014-exp05-r01/test-run-report.md`

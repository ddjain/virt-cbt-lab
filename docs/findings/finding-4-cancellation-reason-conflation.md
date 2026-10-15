# Finding 4: Cancellation-reason conflation — user-initiated abort is indistinguishable from real errors

**Severity:** Minor (monitoring/semantics) · **Class:** misleading terminal reason · **Reproducible:** YES — deterministic, 1/1 attempt (plus corroboration from a second abort path in the same run family) · No separate bug ticket (recorded as a product observation in EXP-2's report; candidate for a low-severity upstream issue)

## 1. Summary

When an operator deletes a backup CR mid-copy (a user-initiated cancellation), the backup terminates with reason **`Backup has failed: backup aborted: Operation canceled`**. The `Backup has failed` prefix makes an intentional cancellation look identical to a genuine failure in any monitoring, alerting, or GitOps pipeline that keys on the terminal reason — without parsing the full reason string, consumers cannot distinguish "an operator canceled this" from "the backup errored."

## 2. Environment

- OpenShift 4.22 / OpenShift Virtualization 4.22.12 (`backup.kubevirt.io/v1alpha1`)
- RHEL 9 VM (1000-file / 17,431 MiB workload), push-mode backup, HostPath storage on `d38-h18-000-r660`

## 3. Scenario ID

EXP-2 (adaptive experiment: backup-CR deletion mid-copy — push-mode abort semantics). Run: `20261014-exp02-r01`.

## 4. How chaos was injected

1. Fresh VM via `make vm-setup` (setup only — no backup yet, so the abort test controls the backup lifecycle directly).
2. Backup CR + target PVC + tracker created via the workflow's own manifest templating (workflow-identical mechanism).
3. Watcher waited for the **active copy** (compound condition `Progressing=True ∧ Done≠True`, 1 s poll); copy start confirmed at 16:01:59Z.
4. Held 20 s (mid-copy; copies run ~53 s), verified still not-Done at the deletion instant (pre-delete object snapshot preserved), then:
   ```
   oc delete vmbackup vm-backup-20261014-exp02-r01 -n vm-cbt-demo
   ```
   (16:02:19Z — copy+20 s.)

## 5. What was expected

The abort path to run cleanly: cancel → volume detach → terminal failed state → object removal. The terminal reason's *wording* was not the hypothesis under test — it emerged as an observation.

## 6. What actually happened

The abort mechanics were textbook-clean (see Finding 1's recovery matrix for the numbers): Aborting phase → hotplug detach in 1 s → terminal state at 16:02:22Z → object fully removed at 16:02:23Z (~3 s total), VMI never paused, tracker untouched, and a same-VM recovery backup (fresh name, `forceFullBackup: true`) later completed and restored byte-identical.

The observation: the terminal condition reason was **`Backup has failed: backup aborted: Operation canceled`** — i.e., a user-initiated cancellation is reported with a failure prefix. Any consumer alerting on `Done=True` reasons matching `Backup has failed*` (the workflow's own failure-oracle uses exactly this pattern — `backup_done_reason_is_failure` in `scripts/common.sh`) will treat operator cancellations as backup failures.

A second datapoint from the same campaign family: the EXP-6 follow-up's CR deletion (a *wedged* backup being cleaned up) and EXP-8's aborts produce the same "Backup has failed"-prefixed cancellation wording — the conflation is systemic to the abort path, not specific to one run.

## 7. Reproducibility

**Deterministic: 1/1** for the primary observation (every mid-copy cancellation produces this exact reason string — the wording is a code constant on the abort path, not a race). The clean-abort *mechanics* (3 s finalizer removal etc.) also reproduced in the EXP-6a and EXP-8 recovery legs.

## 8. Impact

- Monitoring/GitOps consumers cannot distinguish cancellation from error without full reason-string parsing.
- Low severity: no state corruption, no data impact — the backup is correctly canceled and the chain correctly preserved; this is purely a signal-semantics issue.
- Compounds Finding 3: the event stream already cries wolf on success; the reason string cries wolf on cancellation.

## 9. Recommendation

- **Upstream:** a distinct terminal reason prefix for user-initiated aborts (e.g. `Backup canceled: ...`) — a one-line classification change at the abort-path reason constant.
- **Customers (until fixed):** alert on `Done=True` + reason, excluding reasons matching `*Operation canceled` when cancellations are expected in the environment; audit cancellation workflows to use dedicated tooling rather than raw CR deletion if reason-based alerting matters.

## 10. Evidence paths

- `cbt-chaos/scenarios_v2/CBT-EXP-02/runs/20261014-exp02-r01/` — backup-pre-delete.yaml (mid-copy proof: Progressing=True/Done≠False at the deletion instant), trigger.log (action request 16:02:19Z; abort timeline), observer streams (Aborting phase → detach → terminal → DELETED with timestamps), tracker-after-abort.yaml (untouched), target-pvc-residue-recheck.txt (partial data removed; empty dir skeleton only)
- Terminal reason capture: `observer/full-backup.jsonl` (Done=True reason `Backup has failed: backup aborted: Operation canceled` at 16:02:22Z)
- Full narrative: `cbt-chaos/scenarios_v2/CBT-EXP-02/runs/20261014-exp02-r01/test-run-report.md` ("Observation 1")

## 11. Source anchor

kubevirt v1.8.4: push-mode abort path (`DOMAIN_JOB_CANCELLED` → Failed with the abort reason constant) in `pkg/virt-launcher/virtwrap/storage/backup.go` / `pkg/storage/cbt/backup.go` — the "Backup has failed" prefix is shared with genuine failure reasons.

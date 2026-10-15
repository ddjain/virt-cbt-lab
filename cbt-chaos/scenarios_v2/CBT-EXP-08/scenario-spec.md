# Scenario: EXP-8 — Tracker deletion mid-copy (second entry path to the no-deadline wedge)

## 1. Identity

- **Experiment ID:** EXP-8 (WeaknessAnalyst P2-r1, Judge-confirmed compact design)
- **Hypothesis source:** `updateBackupTracker` patches the tracker at completion; a tracker deleted AFTER BackupBegin is never re-checked for existence → 404 → infinite requeue → backup stuck Progressing forever (no deadline). EXP-6 characterized the wedge consequence from checkpoint corruption; this tests the API-side entry path.

## 2. Objective / defect hypothesis

Deleting the tracker ~15 s after observed copy start either wedges the backup (no terminal state; controller requeue loop with tracker-404 in logs) or the backup completes (alternative criterion: classify the tracker's post-state — silently recreated? chain intact?).

## 3. Workflow

Fresh VM → backup created via manifest → watcher: on OBSERVED Progressing=True, hold 15 s, `oc delete vmbackuptracker` (fail-closed: GET must 404) → poll backup to terminal or 15-min stuck threshold → capture controller log window (direct 404 evidence) → recovery: delete the wedged CR (if stuck), then fresh-named backup — does the controller recreate the tracker and complete with consistent checkpoint state?

## 4. Injection

- **Target:** the run's VirtualMachineBackupTracker, mid-copy.
- **Action:** `oc delete vmbackuptracker` at observed-copy-start + 15 s (copy ~53 s).
- **Recovery:** CR deletion (proven) + fresh-named backup with tracker-recreation check.

## 5. Measurements / classification (pre-registered)

- Injection validity: watcher-fired on observed Progressing; tracker GET 404 verified (inject-result.txt).
- **STUCK (wedge reproduced):** no terminal state at 15 min + requeue/404 evidence in controller-window.log. **COMPLETED (alternative):** backup Done; classify tracker post-state (recreated silently / absent / chain intact).
- Recovery: fresh backup Done/type/reason; tracker recreated (yes/no).
- PASS (resilient): backup terminal (either way) with clean recovery. FAIL: wedge from the API-side path (joins the EXP-6 ticket as a second entry).

## 6. Blast radius / safety

Run-scoped: fresh VM, own tracker/backup/PVC. Tracker deletion is the modeled operator action. Recovery proven safe. ~25 min.

## 7. Evidence

`cbt-chaos/scenarios_v2/CBT-EXP-08/runs/<RUN_ID>/`: trigger.log, inject-result.txt, backup-final.yaml, tracker-final.yaml, controller-window.log, recovery-backup.yaml, observer streams.

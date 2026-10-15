# Scenario: EXP-7 — Late-copy ENOSPC on the backup target (succeeded:false silent-corruption class)

## 1. Identity

- **Experiment ID:** EXP-7 (adaptive; WeaknessAnalyst P3, Judge GO with full rigor)
- **Hypothesis source:** kubevirt#17578 (rotten): `HandleBackupJobCompletedEvent` keys off `event.Info.Type == DOMAIN_JOB_COMPLETED` only; the job stats' `succeeded` flag is never inspected. A push copy that fails late (target ENOSPC after checkpoint creation) could complete the job with `succeeded:false` → CR Done=True with partial/no data. T-04 already proved EARLY ENOSPC fails cleanly; the late window is untested.

## 2. Objective / defect hypothesis

A full backup whose target PVC runs out of space at ~60-90% of the copy either (a) fails correctly (terminal Failed/warning — resilient), or (b) completes Done=True with success reason while the target holds a fraction of the expected data — silent corruption, the worst defect class.

## 3. Workflow

- **Leg A (control):** `make vm-setup` (fresh VM, ~17GiB workload) → `make vm-backup` (normal 80Gi target) → record Done/reason + actual target PVC usage (du) — proves the new pre-fill-adjacent machinery and gives the expected-usage baseline.
- **Leg B (surgery):** apply the backup manifest with a 4Gi target PVC named distinctly (`vm-backup-enospc-*`); wait Bound; pre-fill the PV via node-debug `fallocate` (2600Mi filler → ~1500Mi free); wait terminal (20 min); record Done/reason/type; actual PV usage; full file listing.

## 4. Injection

- **Target:** the backup destination PVC's free space (node-local PV).
- **Action:** pre-fill to leave ~1500MiB free against a ~17GiB copy.
- **Window:** the copy's late phase (post-checkpoint — checkpoint creation needs only metadata space).
- **Recovery:** none needed; the backup either fails cleanly or exposes the defect.

## 5. Measurements / classification (Judge-mandated)

- Control: Done=True/success, actual usage ≈ workload size.
- Surgery: Done/reason/type; actual target usage vs expected ~17GiB (usage << expected with Done+success = silent corruption); target file listing (partial qcow2 sizes); if Done=True with success: restore verification per-file (truncation signature).
- **RESILIENT:** terminal failure or warning with real reason. **DEFECT:** Done=True success reason + target holding a fraction of the data.

## 6. Blast radius / safety

Run-scoped: fresh VM, distinct surgery PVC (4Gi, filled with a single fallocate file). The fill is confined to this run's PV — no shared-disk capacity theft (T-04 lesson). Worst case: a failed backup (already characterized in T-04/F-08).

## 7. Evidence

`cbt-chaos/scenarios_v2/CBT-EXP-07/runs/<RUN_ID>/`: trigger.log, legA-full-backup.yaml, legA-target-usage-mib.txt, legB-prefill.txt, legB-backup.yaml, legB-target-usage-mib.txt, legB-target-files.txt, observer streams.

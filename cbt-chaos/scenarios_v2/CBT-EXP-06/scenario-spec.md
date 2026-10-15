# Scenario: EXP-6 — Multi-disk silent disk-drop (lost per-disk checkpoint bitmap)

## 1. Identity

- **Experiment ID:** EXP-6 (adaptive; WeaknessAnalyst P1, Judge-ranked highest EV)
- **Hypothesis source:** kubevirt v1.8.4 (= live CNV 4.22.12) source: `RedefineCheckpoint` probes each disk independently (`findDisksWithCheckpointBitmap`); disks whose qcow2 lost the checkpoint bitmap are silently excluded from the redefined checkpoint (V(3) log only) — all subsequent incrementals complete Done=True WITHOUT that disk. The invalid-checkpoint clearing path only fires when ZERO disks match. All campaign VMs are single-disk — the drop-path is empirically dark.

## 2. Objective / defect hypothesis

A 2-disk VM (rootdisk=vda + datadisk=vdb) whose vdb checkpoint bitmap is removed between a full backup and its incremental (with a VMI restart firing the redefinition path) will produce an incremental that is Done=True with vdb missing from `includedVolumes` and no warning — silent permanent data-protection loss for the dropped volume. Control leg (no surgery) proves the 2-disk harness keeps both disks.

## 3. Workflow

- **Leg A (control):** 2-disk VM via custom manifest (blank 2Gi datadisk DV, ext4 via cloud-init); `make e2e TYPE=full EXISTING_VM` (adopts the VM; full + incremental + restore verify); record `includedVolumes` (must contain rootdisk+datadisk).
- **Leg B (surgery):** resolve the full backup's checkpoint name; find vdb's QEMU node (query-named-block-nodes); verify the bitmap exists on vdb (fail-closed); QMP `block-dirty-bitmap-remove` on vdb only; verify bitmap GONE (fail-closed); hard-restart the VMI (fires checkpoint redefinition); capture tracker volumes + controller redefinition-log window; `make e2e TYPE=incremental`; classify.

## 4. Injection

- **Target:** the checkpoint bitmap of ONE disk (vdb/datadisk) inside the running QEMU instance.
- **Action:** QMP `block-dirty-bitmap-remove` (kubectl exec into the launcher's compute container — the campaign's standard exec surface).
- **Window:** between full completion and incremental creation, with the redefinition fired by VMI restart (EXP-1-proven path).
- **Recovery:** none needed for the VM; the observation IS the outcome.

## 5. Measurements / classification (Judge-mandated)

- Control leg: full backup `includedVolumes` contains both disks (else the 2-disk harness itself is broken — abort).
- QMP fail-closed: bitmap present before removal, absent after (evidence: bitmaps-before/after.json).
- Redefinition evidence: tracker latestCheckpoint volumes after restart (does vdb survive the redefinition?); controller log window.
- Surgery incremental: type/Done/`includedVolumes`. **FAIL (defect)**: Done=True Incremental with datadisk missing from includedVolumes and no warning event. **RESILIENT**: both disks still included, OR the drop is detected (checkpoint cleared → full fallback, warning, or Failed).
- Per-disk restore grading: the harness's restore-verify covers rootdisk (guest workload); vdb content grading documented in the report (vdb carries no workflow workload — the metadata-level includedVolumes check is the primary signal; noted as a limitation).

## 6. Blast radius / safety

Run-scoped: fresh VM, own DVs (2Gi blank + 5Gi clone), own tracker/PVCs. QMP surgery touches only this VM's QEMU instance. Worst case: corrupt checkpoint → 422 → clean full fallback (EXP-1-proven benign). No shared components.

## 7. Evidence

`cbt-chaos/scenarios_v2/CBT-EXP-06/runs/<RUN_ID>/`: trigger.log, legA-full-backup.yaml, bitmaps-before/after.json, qmp-remove-result.txt, tracker-after-restart.yaml, controller-redefinition-window.log, legB-incremental-backup.yaml, observer streams.

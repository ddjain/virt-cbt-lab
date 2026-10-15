# Scenario: EXP-1 — VM restart between full backup and incremental pass (checkpoint redefinition path)

## 1. Identity

- **Experiment ID:** EXP-1 (adaptive, beyond the Jira baseline set)
- **Hypothesis source:** kubevirt source analysis (pkg/virt-handler/cbt.go:119-150, pkg/storage/cbt/backuptracker.go:79-198): when a VMI restarts while a checkpoint exists, virt-handler marks `checkpointRedefinitionRequired`; the controller redefines the checkpoint in libvirt by probing each disk for a usable bitmap; non-422 errors requeue forever; invalid checkpoints are cleared (forcing a full); a partial redefinition can silently drop disks from subsequent incrementals.
- **No existing scenario in the campaign restarts the VM itself** (F-03/04/05/12/13, I-03/06/08 restart controllers/handler/containers; X-02 restarts kubelet).

## 2. Objective / defect hypothesis

After a hard VM restart between a successful full backup and its first incremental pass, the checkpoint-redefinition path must preserve the incremental chain: the incremental must complete as type=Incremental chained to the full's checkpoint, the tracker must settle (no stuck `checkpointRedefinitionRequired`), and restored data must be byte-identical. Failure modes under test: (a) tracker stuck in redefinition (blocks all backups); (b) checkpoint cleared → silent full fallback (`type=Full` on p01); (c) partial bitmap redefinition → incremental that silently covers less data than the full (restore mismatch); (d) excessive redefinition delay.

## 3. Workflow

`make e2e TYPE=full NAME=<RUN_ID>` (clean full) → `oc delete vmi vm-<RUN_ID>` (hard restart; VM object recreates the VMI; tracker persists with latestCheckpoint) → wait VMI Running + CBT Enabled (observe checkpointRedefinitionRequired transitions) → `make e2e TYPE=incremental VM=vm-<RUN_ID>` (1000-file mutation, ~18 GiB) → built-in verification (type/checkpoint-chain/restore hashes). RHEL 9, HostPath variant, node d38-h18-000-r660 (deterministic placement).

## 4. Injection

- **Target:** the run's VMI (`oc delete vmi`) — a hard restart equivalent to a node/launcher crash for the domain, exercised deterministically.
- **Action:** VMI deletion at a controlled point (between backups, checkpoint present on the tracker).
- **Signal:** full backup Done + checkpoint recorded (stage boundary; no race needed — the redefinition path is what's under test, not its timing).
- **Window:** between full completion and incremental creation.
- **Recovery:** automatic (VM object recreates the VMI; virt-handler re-marks CBT; controller redefines the checkpoint).

## 5. Measurements / classification

- Restart-to-Running seconds; CBT return-to-Enabled seconds; `checkpointRedefinitionRequired` observed/cleared (VMI + tracker YAML snapshots preserved).
- p01: `status.type` (Incremental expected; **Full = silent fallback = degradation signal**), Done/reason, checkpoint chain (distinct p01 checkpoint; tracker single advance), duration vs baseline.
- Restore: full-only + cumulative hashes must pass (any mismatch = high-priority correctness finding).
- PASS: incremental completes as Incremental, chain intact, restores pass, tracker settles. DEGRADED/FAIL: any of the failure modes above.

## 6. Blast radius / safety

Run-scoped: only this RUN_ID's VMI/VM is deleted. The VM object persists and recreates it; no other workload touched. Worst case: VM fails to restart (exit 5 with evidence) or incremental fails (exit code preserved; artifacts kept for classification). No shared-resource fault injection.

## 7. Evidence

`cbt-chaos/scenarios_v2/CBT-EXP-01/runs/<RUN_ID>/`: trigger.log, vmi-after-restart.yaml, tracker-after-restart.yaml, incremental-backup.yaml, tracker-final.yaml, vmi-final.yaml, observer streams; lifecycle JSON under `runs/<RUN_ID>/`.

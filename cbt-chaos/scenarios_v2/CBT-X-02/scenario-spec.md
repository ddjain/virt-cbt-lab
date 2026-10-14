# Scenario: Restart the worker node kubelet during a full backup

## 1. Identity

- **Jira issue:** CBT-X-02 — "Restart the worker node kubelet during a full backup" (P3, technical scenario: node-scenarios, phase: active operation)
- **Run family:** node-management disruption during backup copy
- **Precedents:** I-08 (command-trigger Progressing-by-type gate); X-01 (background workflow + armed krkn)

## 2. Objective and hypothesis

**Jira objective:** kubelet restart temporarily affects node management/status reporting without restarting the running VM or interrupting the backup. The test must FIRST validate in dry-run mode because the environment is bare metal.

**Mechanics (source-verified):** krkn `restart_kubelet_scenario` = `oc debug node/<n> -- chroot /host systemctl restart kubelet &` then `wait_for_ready_status`. A kubelet restart does NOT stop containers (container runtime unaffected); running pods keep running; status reporting pauses until kubelet returns; node may briefly report NotReady after the node-monitor-grace-period (~50s default) — a ~5-10s restart usually stays within grace.

**Dry-run validation first (Jira mandate):** confirm on the bare-metal node that `systemctl restart kubelet` (a) returns quickly, (b) node stays Ready (oc observe), (c) a dummy pod keeps running — WITHOUT the backup in flight. The campaign's own `oc debug node` calls (used in every capacity guard) already prove debug-node works on this cluster.

## 3. Design

1. Dry-run leg: restart kubelet on d38-h18-000-r660 via the exact krkn command path (`oc debug node/… systemctl restart kubelet`); observe node Ready status, launcher pods of prior runs unchanged. Record timings.
2. Live leg: background `make e2e TYPE=full` + krkn node-scenarios `restart_kubelet_scenario` gated on the backup's Progressing-by-type (command trigger). kubelet restarts mid-copy.
3. Verifications (Jira): node returns Ready; launcher pod identity AND restartCount unchanged (kubelet restart must not restart containers); backup succeeds (Done=True success, type Full); tracker advances exactly once; restore validation passes (workflow verify on the incremental follow-up).

## 4. Target and validated disruption

**Target:** kubelet on d38-h18-000-r660 (the CBT worker node).
**Action:** systemctl restart kubelet (krkn node-scenarios restart_kubelet_scenario).
**Window:** full backup Progressing.
**Blast radius:** node management plane only; containers keep running; VM unaffected; the backup copy is a launcher-local process.

## 5. Verification criteria

- Dry-run validated (node Ready, no pod restarts) before the live leg.
- Kubelet restart landed during copy (trigger satisfied; krkn log).
- Node Ready before/after; brief NotReady window recorded if any.
- Launcher pod name unchanged + restartCount 0 + no container restart.
- Backup Done=True success, type Full; tracker advances exactly once.
- Follow-up incremental + workflow verification PASS.

## 6. Pre-run guards

Standard RUN_ID/pool guards. Confirm node Ready at start. Dry-run leg is itself the bare-metal validation.

## 7. Uncertainties

- If the kubelet restart takes >50s (node-monitor grace), node flips NotReady and pods get marked Unknown — the VM keeps running but VMI conditions may blip. This is within the scenario's intent (status reporting pauses); record it.
- oc debug node requires the debug namespace — proven working (every capacity guard uses it).

## 8. Evidence

Dry-run observations (node conditions timeline, pod list before/after), krkn log, workflow logs, launcher pod status, backup/tracker states, verify outputs.

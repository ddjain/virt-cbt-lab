# Scenario: Disable the guest agent before an incremental backup

## 1. Identity

- **Jira issue:** CBT-I-07 — "Disable the guest agent before an incremental backup" (P2, technical scenario: no direct Krkn scenario, phase: pre-condition)
- **Run family:** incremental-backup workflow, guest-plane disruption (quiescing unavailable)
- **Precedents:** none in this campaign (first guest-inside-the-VM target). Related docs fact (docs/cbt/03-network.md): a healthy default run saw the full backup start before the agent connected and complete with a quiescing warning — the product treats freeze/thaw as best-effort.

## 2. Objective and hypothesis

**Jira objective:** verify the documented best-effort behavior when the guest agent cannot freeze and thaw the VM filesystem during backup.

**Product questions:**
1. Does the incremental backup COMPLETE (with a warning) rather than fail when the guest agent is stopped (AgentConnected=False)?
2. Is the resulting backup data-correct for the synchronized test data (the mutation completes before the agent is stopped — the workload files are fully written and synced; only the fsfreeze/thaw quiescing is missing)?
3. Is the freeze/thaw attempt visibly downgraded (launcher log shows the agent path failing / warning; backup Done reason may carry a quiescing warning)?
4. Does the agent restart cleanly after the backup (AgentConnected=True again) and does a FOLLOW-UP backup run clean?

## 3. Workflow and mechanics (source- and live-verified)

Two-stage lifecycle: `make e2e TYPE=full` → stop agent → `make e2e TYPE=incremental` → restart agent → follow-up check (RHEL 9, campaign-default variant — set explicitly; I-06 harness lesson).

**Freeze/thaw path (live-verified in this cluster):** the launcher's compute container runs an agent poller (`guest-fsfreeze-status`) and logs "Freezing VMI to capture backup state" (backup.go:181) before the copy and "Thawing VMI after backup job started" (backup.go:194) after. The channel is the QEMU `org.qemu.guest_agent.0` virtio-serial device; the VM's cloud-init installs `qemu-guest-agent` (common.sh GUEST_CLOUD_INIT_PACKAGES). With the agent service stopped in the guest, the poller/channel goes silent → freeze/thaw must fail or be skipped → backup proceeds unquiesced (best-effort).

**Stopping the agent (Jira action, "from inside the VM"):** the workflow's own `guest_ssh` helper (common.sh) runs a command in the guest over the existing ephemeral port-forward + SSH path. RHEL 9: `sudo systemctl stop qemu-guest-agent` (cloud-init installs it; the guest user has passwordless sudo for this). Verification of the disconnected state: VMI condition `AgentConnected=False` (the poller drops it within ~1-2 min) — this is the Jira's stated observable ("Confirm guest-agent disconnected state").

**Recovery:** `sudo systemctl start qemu-guest-agent` → AgentConnected=True (Jira: "Restart the guest agent").

## 4. Target and validated disruption

**Target:** the qemu-guest-agent service inside the VM (guest plane; no cluster resource is touched).

**Action:** after the full stage completes and the VM is ready with no backup in progress (the Jira's injection signal), run `guest_ssh 'sudo systemctl stop qemu-guest-agent'`; wait for VMI `AgentConnected=False` (poll ≤5 min); THEN run `make e2e TYPE=incremental`. The mutation inside the incremental stage completes with the agent ALREADY stopped — the workload files are written and synced (the workflow's mutation helper syncs), so the data on disk is complete; the missing piece is only the crash-consistency freeze/thaw window.

**Injection window:** pre-condition (Jira phase): agent stopped and confirmed disconnected BEFORE the backup object is created.

**Duration:** until the follow-up verification completes (agent restarted after the incremental stage; the Jira says "until guest agent is restarted").

**Blast radius:** single VM's guest agent. No cluster-side resources. The SSH path for the workflow's own mutation commands is UNAFFECTED (SSH ≠ guest-agent channel — docs/cbt/03-network.md separates them; the mutation must still succeed for the test to be meaningful).

## 5. Verification criteria

- Injection validity: `systemctl status qemu-guest-agent` output captured (inactive/dead) + VMI `AgentConnected=False` before the incremental stage starts; launcher agent-poller silence/absence of "Freezing VMI" success for the p01 backup (or explicit freeze failure/warning in launcher log).
- Backup completes with warning, not failure: p01 Done=True; reason either success-with-quiescing-warning or plain success; any FAILURE reason is a finding against the best-effort contract.
- Data correctness: workflow restore verification (full-only + cumulative) — hashes must match (the test data was fully synchronized before the agent was stopped; absence of fsfreeze does not corrupt already-quiesced data at rest; it only widens the in-flight write window, which this workload does not exercise mid-copy).
- Marker presence (Jira: "marker presence"): the pass-1 workload marker files present in the cumulative restore (implicitly verified by the manifest hash match; the workflow's restore checks cover it).
- Clean follow-up backup: after agent restart (AgentConnected=True), a follow-up backup attempt on the same VM completes cleanly (the Jira's "clean follow-up backup") — implemented as the p02 recovery backup at API level (fresh PVC, pass-02 names) AFTER the agent is restarted, expected Incremental chained to the p01 checkpoint.
- VM health: VMI Running/Ready throughout (agent loss must not disturb the VM).
- Product verdict mapping: backup completes (warned or clean) + data correct + agent recovers + follow-up clean → PASS. Backup FAILS because the agent is down (violates best-effort contract) → FAIL with finding.

## 6. Pre-run guards

Standard (RUN_ID collision, resource collision). Assert AgentConnected=True before stopping (the pre-condition must start from a connected agent). Guest SSH reachable (the workflow's own helper handles the port-forward). No krkn needed (Jira: no direct Krkn scenario; the action is a guest-internal service stop via the sanctioned SSH path).

## 7. Uncertainties

- Whether the controller/launcher surfaces an explicit WARNING event for the unquiesced backup (docs observed one on a full backup started pre-agent-connect). If no warning appears AND no freeze attempt is logged, record the observable gap (the freeze may be silently skipped when the agent is disconnected — itself a finding for the "explicitly warned" expectation).
- Whether VMI AgentConnected flips False fast enough to observe before the stage starts (poller cadence ~30-60s; poll up to 5 min).
- RHEL 9 guest: qemu-guest-agent is systemd-managed; `systemctl stop` is sufficient (no need to mask). If the service name differs, discover via `systemctl list-units 'qemu*'` in the guest first.

## 8. Evidence to capture

Observer (read-only): vmbackup full/p01/p02 condition streams, tracker, VM/VMI streams (AgentConnected transitions!), events (label-mode workaround), launcher compute-container log stream (freeze/thaw lines for p01 vs full — the decisive product observable). Trigger: agent stop/start command outputs, AgentConnected polling timeline, stage exits, p01 terminal state/type/checkpoint, restore verification results, p02 outcome. All under `cbt-chaos/scenarios_v2/CBT-I-07/runs/<RUN_ID>/`.

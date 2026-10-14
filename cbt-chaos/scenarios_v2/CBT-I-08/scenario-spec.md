# Scenario: Stop only the backup execution container during an incremental backup

## 1. Identity

- **Jira issue:** CBT-I-08 — "Stop only the backup execution container during an incremental backup" (P2, technical scenario: container-scenarios, phase: active operation)
- **Run family:** incremental-backup workflow, execution-plane container-level interruption (contrast with CBT-I-02's full launcher-POD deletion)
- **Precedents:** CBT-I-02 (launcher-pod delete mid-copy → clean failure + tracker cleared 9s later via CheckpointRedefinitionFailed when VMI dies); CBT-F-01 (launcher kill during FULL); CBT-I-06 (virt-handler kill mid-copy → copy survives, teardown leak finding)

## 2. Objective and hypothesis

**Jira objective:** verify container-level interruption during an incremental copy and compare with complete launcher-pod interruption.

**Product questions:**
1. Does the incremental backup FAIL CLEANLY (Done=True with failure reason) when only the compute container is stopped mid-copy?
2. Does the tracker REMAIN on the previous valid checkpoint (Jira expectation: "tracker should remain on the previous valid checkpoint")? NOTE: I-02 evidence showed the tracker CLEARS (CheckpointRedefinitionFailed → empty) when the VMI dies as part of launcher-pod death. The container-stop path also kills the VMI (virt-launcher-monitor → pod terminates) — so the observable may match I-02 (clearing) rather than the Jira's "remain on previous checkpoint". Either way, the requirement is: no CORRUPTED chain; the next backup must recover per the documented checkpoint-recovery semantics.
3. Does the VM recover automatically (VMI recreated Running, CBT state restored) per the Jira's "Automatic VM recovery"?
4. Same-VM post-chaos backup recovery: a fresh incremental after recovery must chain correctly (Incremental, or a documented checkpoint-recovery full).
5. Data integrity: the FULL artifact (pre-chaos) must restore bit-exact; the failed pass must leave no partial incremental that corrupts a later chain.

## 3. Workflow and mechanics (source- and live-verified)

Two-stage lifecycle: `make e2e TYPE=full` → arm chaos → `make e2e TYPE=incremental` (chaos fires mid-copy via krkn native k8s trigger) → recovery observation → fresh p02 at API level → direct full-only restore verification.

**krkn container-scenarios semantics (source-verified, CRITICAL):**
- `kill_action = "kill " + str(action)` (container_scenario_plugin.py:95), executed via `exec_cmd_in_pod` → `bash -c "kill <N>"` in the target container. So `--action N` means **SIGTERM to PID N**, NOT signal N. The shipped example config uses `action: 1` for etcd.
- In the compute container the PID map is: 1=virt-launcher-monitor, 8=virt-launcher, 24=virtlogd, 25=virtqemud, 99=qemu-kvm (VM-dependent). There is NO PID matching the action number in general — `--action 9` would be `kill 9` = no such process = NO-OP.
- Therefore the meaningful container-stop is **`--action 1`** = SIGTERM to PID 1 (virt-launcher-monitor). With `restartPolicy: Never` (verified live on launcher pods), PID-1 exit terminates the whole pod → kubelet marks the container terminated → virt-controller recreates the VMI (Automatic VM recovery, same as I-02's pod-death path but initiated from INSIDE the container).
- Live pre-validation (accidental, on the i07 launcher): `kill 99` (SIGTERM to qemu-kvm) inside compute → launcher pod replaced (khfmk → h8bg6) within ~2 min, VMI Running again, run objects untouched. This confirms the exec+SIGTERM path works and the recovery machinery is functional.
- krkn's recovery check (`check_failed_containers`) polls `container.ready` for the killed container until `expected_recovery_time` — the killed container's pod TERMINATES (restartPolicy Never), so the pod disappears and `get_pod_info` on the old name will fail; krkn's monitoring snapshot (select_and_monitor by namespace+label) may report unrecovered containers → krkn exit 1 is EXPECTED and acceptable here (the plugin's container-recovery model doesn't fit restartPolicy=Never launchers; recorded as a krknctl-bug/limit note). The trigger must treat krkn exit code as non-authoritative and judge recovery from cluster state (VMI Running again).

**Targeting:** `--namespace vm-cbt-demo --label-selector kubevirt.io=virt-launcher` selects ALL running launchers (6+ from prior runs) — krkn picks a RANDOM pod from the label match. The compute container of the RUN's launcher must be the one killed. Options: (a) rely on `--container-name compute` + random pod (WRONG — random pod, wrong VM); (b) the plugin honors `pod_names` from YAML config (not exposed as a krknctl flag — verified in help output); (c) use a label selector unique to the run's launcher. The launcher pod inherits the VMI's labels; VM template labels are only `cbt-demo: enabled` (shared), BUT the launcher pod carries `vm.kubevirt.io/name: vm-<RUN_ID>` (live-verified on i07's pod). So `--label-selector "vm.kubevirt.io/name=vm-<RUN_ID>"` uniquely selects the run's launcher. WAIT — krkn passes label_selector to `list_pods`; `vm.kubevirt.io/name` is a valid pod label on launcher pods (live-verified). This is the targeting mechanism.

**Injection window:** p01 vmbackup Progressing=True (active copy), krkn native k8s trigger (I-06-proven pattern), 2s poll. Copy window on default variant: 16-21s.

## 4. Target and validated disruption

**Target:** the `compute` container of virt-launcher-<run> (the container that runs virt-launcher-monitor/virtqemud/qemu-kvm — the backup execution plane: the QEMU block-copy runs in qemu-kvm inside this container).

**Action:** SIGTERM to PID 1 (virt-launcher-monitor) inside the compute container mid-copy → container terminates → pod terminates (restartPolicy Never) → VMI dies with it → virt-controller recreates.

**Duration:** immediate (single signal).

**Blast radius:** the run's VM only (unique label selector); no other launcher touched.

## 5. Verification criteria

- Injection validity: krkn log shows the kill executed in the target pod/container at a timestamp INSIDE the p01 copy window (Progressing=True → terminal); pod replacement events; trigger computes target-pod identity before/after.
- Clean failure: p01 reaches a terminal state (Done=True with an explicit failure reason, or the backup object reflects interruption) — NOT an indefinite Progressing hang. (I-02 precedent: "Backup has failed" style reason or the backup completes-if-past-copy; either terminal outcome is acceptable as "fail cleanly" IF no silent wrong data.)
- Tracker: record final tracker state (hold on previous checkpoint, OR the documented I-02-style clearing via CheckpointRedefinitionFailed — the Jira's "remain on previous valid checkpoint" expectation is tested against I-02's observed clearing semantics; whichever occurs, document with events).
- VM recovery: VMI Running again (recreated launcher), CBT state enabled.
- Same-VM post-chaos backup: fresh p02 (API level, fresh PVC) → Incremental chained to a valid checkpoint, or documented checkpoint-recovery full conversion (per CRD semantics when the tracker was cleared); tracker advances to the new backup.
- Data integrity: direct full-only restore verification (I-05/I-06 pattern: workflow's restore-verify-pod rendered with 0 incremental mounts) — FULL must be bit-exact. If p02 Incremental succeeds, cumulative verify via a second pinned/unpinned run as feasible.
- Verdict mapping: clean failure + recovery + correct chain/data → PASS. Silent corruption / wrong data / hang / unrecoverable chain → FAIL.

## 6. Pre-run guards

Standard (RUN_ID collision, resource collision). Assert the run's launcher is Running pre-stage. Capacity guard for default variant (HostPath pool ≥400GiB free — I-04). krkn trigger dry-run with a bogus-name probe (I-06 pattern) to validate trigger wiring before the real stage.

## 7. Uncertainties

- Whether p01 fails (copy interrupted) or completes (if the copy finished before the kill lands — window is 16-21s; krkn trigger poll is 2s + exec latency; either outcome documented; a completed-pass outcome makes the "fail cleanly" criterion N/A and the run pivots to recovery/data validation).
- krkn exit code semantics with restartPolicy=Never (expected 1/"unrecovered"); non-authoritative.
- Whether the tracker clears (I-02 semantics) or holds — both documented; the Jira text says "remain on the previous valid checkpoint", so if it CLEARS, that's a divergence from the Jira's expectation to document (not necessarily a product bug — I-02 already characterized the clearing as CheckpointRedefinitionFailed-driven recovery semantics).

## 8. Evidence to capture

Observer (read-only): launcher pod stream (identity before/after), p01 vmbackup stream, tracker stream, VM/VMI streams, events (both vm-cbt-demo), PVC stream. Trigger: krkn log (kill timestamp + target), p01 terminal state yaml, tracker observations (2-min poll), VMI recovery timeline, p02 outcome, full-only restore verifier log. All under `cbt-chaos/scenarios_v2/CBT-I-08/runs/<RUN_ID>/`.

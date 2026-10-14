# Scenario: Restart the node backup handler during an incremental backup

## 1. Identity

- **Jira issue:** CBT-I-06 — "Restart the node backup handler during an incremental backup" (P1, technical scenario: pod-scenarios, phase: active operation)
- **Run family:** incremental-backup workflow, node-agent disruption (virt-handler pod on the CBT worker node)
- **Precedents:** I-02 (mid-copy launcher kill — different target: the VM's own pod, not the node agent); I-03 (controller-leader kill — control-plane, different component). This is the first node-agent (virt-handler) target. F-02/F-04 killed component pods pre-copy; none targeted virt-handler.

## 2. Objective and hypothesis

**Jira objective:** verify that interruption of the node-level backup handler during bitmap copying does not silently change an incremental backup into an incorrect full backup.

**Product questions:**
1. Does the incremental backup recover (complete correctly, still Incremental) or fail cleanly when virt-handler on the VM's node is deleted mid-copy?
2. Does the backup TYPE stay Incremental (no silent full-conversion)? Any conversion must be explained by checkpoint-recovery behavior (events/conditions), else it is a finding.
3. Does the tracker state remain consistent (checkpoint chain intact; no unexplained CheckpointRedefinitionFailed)?
4. Does the handler restart automatically (DaemonSet) and does restore correctness hold?

## 3. Workflow and mechanics (source-verified)

Two-stage lifecycle: `make e2e TYPE=full` → `make e2e TYPE=incremental` (RHEL 9, MANIFEST_VARIANT=default → HostPath `cbt-demo-hpp`, VM node-pinned to d38-h18-000-r660 by the VM manifest — the CBT worker node where the campaign VMs run).

**virt-handler role in the copy (why this target matters):** virt-handler is the per-node KubeVirt agent. The backup runs in Push mode ("Starting backup for VMI … with mode Push" — virt-controller log, I-05 evidence); the CBT bitmap copy stream is driven from inside the VMI's virt-launcher (qemu), with virt-handler mediating node-level device/hotplug plumbing (the destination PVC hotplug `hp-volume-<id>` runs on the VM's node). Deleting virt-handler mid-copy tests whether the node agent is in the data path or only in the setup path. The copy window on the default variant is 16–21s (baseline band), so the trigger must be armed BEFORE the window and gated by the vmbackup's Progressing condition.

**Handler restart semantics (live-verified):** DaemonSet `virt-handler` in openshift-cnv, desired=28 ready=28; the pod on d38-h18-000-r660 is `virt-handler-7gt6g` (restarted once 7h43m ago — normal). Deletion → DaemonSet recreates on the same node (Jira: "Automatic handler restart"). krkn's pod-scenarios deletes via the API (`kubecli.delete_pod`, `--force` → grace_period_seconds=0) and waits for recovery within `--expected-recovery-time` (default 120s), failing the run if the pod does not come back.

## 4. Target and validated disruption

**Target:** the virt-handler pod on the VM's node (d38-h18-000-r660), namespace openshift-cnv. The VM's virt-launcher pod itself is NOT touched (I-02 covers that); only the node agent is deleted.

**Action:** `krknctl run pod-scenarios` with:
- `--namespace openshift-cnv` (exact namespace, not the default `openshift-.*` regex)
- `--node-names ["d38-h18-000-r660"]` (source-verified: pod selection adds `spec.nodeName=<node>` field selector per named node — only the handler on the CBT node is eligible)
- `--name-pattern virt-handler-.*` (single pod; `--disruption-count 1` default)
- `--force` (grace_period_seconds=0 — immediate interruption, matching the Jira's "Immediate" duration; also avoids a graceful drain that might complete the copy before the kill lands)
- native event trigger gating on the p01 vmbackup: `--trigger-k8s-api-version backup.kubevirt.io/v1alpha1 --trigger-k8s-kind VirtualMachineBackup --trigger-k8s-namespace vm-cbt-demo --trigger-k8s-name vm-incremental-<RUN_ID>-p01 --trigger-k8s-condition "status.conditions.0.status == True"` — source-verified path resolution (dot-path walks dicts/lists; `0` indexes the conditions array; the Progressing condition is at index 0 in this build — live-verified on the I-05 p01 object: `[{Progressing},{Done}]`), `--triggers-interval 2` (fast poll; the copy window is 16–21s), `--triggers-timeout 900`, `--triggers-on-timeout fail`.
- The trigger process is started BEFORE the incremental stage (krkn image startup ~10-15s is absorbed while the stage mutates the guest; per the timing rule, the disruption is gated by Krkn's native trigger, not a host-side watcher).

**Condition/timing:** chaos fires when p01 Progressing=True (active copy, exactly the Jira's injection signal). Post-hoc validity proof: handler pod deletion timestamp and replacement creation INSIDE the p01 Progressing→terminal window (observer pod-timeline + vmbackup condition streams), p01 vmbackup type/checkpoint outcome.

**Blast radius:** one pod on one node, openshift-cnv. Other VMs on d38-h18-000-r660: the campaign's evidence VMs (all paused/closed — their launchers are Running but idle; virt-handler restart briefly interrupts node-agent duties for ALL VMs on the node, which is inherent to the Jira's target). The pre-existing broken `vm-cbt-demo` VMI (NotReady since Oct 8, periodic IOerror pauses) is unaffected by a handler restart (it is already down; its pause events are noise to filter by involvedObject.name).

**Duration:** immediate (single deletion; DaemonSet recreation expected <2 min; krkn verifies recovery within `--expected-recovery-time 120`).

## 5. Verification criteria

- Injection validity: virt-handler pod on d38-h18-000-r660 deleted (and replaced) with timestamps inside the p01 copy window; krkn exit 0 with its recovery check passed; new pod name differs from the old (proof of recreation).
- Backup outcome: p01 reaches a terminal state — either Done=True success (recovered: still type=Incremental, distinct checkpoint chained to the full) or Done=True failure with a stated reason (clean failure). Either is acceptable per the Jira ("recover or fail cleanly").
- NO silent full-conversion: p01 `.status.type` must be Incremental; if any resulting backup is Full, it must be explicitly explained by checkpoint-recovery behavior (events/conditions/tracker) — an unexplained switch is a FAIL finding.
- Tracker consistency: tracker advances exactly once to the p01 checkpoint (on success) or holds the full checkpoint without unexplained clearing (on failure); no `CheckpointRedefinitionFailed` unless explainable.
- Handler recovery: new virt-handler pod Running on the node within 120s (krkn checks; observer verifies independently).
- VM health: VMI stays Running/Ready (virt-handler restart must not evict the VM).
- Restore correctness: workflow verification (17 checks) if the stage completes; on failure, direct full-only verifier (I-05 pattern) + post-chaos same-VM incremental retry at API level (fresh p02 names).
- Post-chaos same-VM backup: p02 (fresh PVC) Incremental chained — proves the checkpoint chain survives the handler interruption.
- Product verdict mapping: recover-or-fail-cleanly + type stays Incremental + tracker consistent + restores correct → PASS. Silent full-conversion without explanation, corrupted chain, or hung backup → FAIL with findings.

## 6. Pre-run guards

Standard (RUN_ID collision, resource-name collision). Node placement: assert the VM's virt-launcher is on d38-h18-000-r660 before arming (read the VMI's status.nodeName; the HostPath variant pins it — if the cluster moved the node pool, resolve the actual node and use it for `--node-names`). Handler precondition: exactly one Running virt-handler on that node; DaemonSet healthy (desired==ready). I-04 capacity guard: HostPath pool ≥400 GiB free (default variant writes to the pool). No `make clean-all`.

## 7. Uncertainties

- Whether virt-handler is actually in the active copy path (vs. only setup): unknown — that is the experiment. If the copy completes unaffected (no slowdown, no failure), that is a legitimate PASS-with-recovery outcome (the handler restart is still proven by pod identity change + timestamps inside the window).
- krkn pod-scenarios `--name-pattern` with `--namespace openshift-cnv` targets only pods matching `virt-handler-.*` on the named node — verified against plugin source (`select_pods_by_name_pattern_and_namespace_pattern` with `spec.nodeName` field selector). Risk: pod list snapshot timing (the pattern resolves at trigger fire, not at process start — source: selection happens in `run` after the trigger gate).
- The trigger condition path `status.conditions.0.status == True`: verified against the live object's condition ORDER (Progressing at index 0). If a future build reorders conditions, the trigger would misfire — acceptable for this build; the observer independently records the full condition stream.
- Trigger uses k8s trigger evaluation `resource_api.get(name=…)` — a NOT-yet-existing vmbackup raises an exception handled as not-satisfied (retried at the poll interval; verified in k8s_trigger.evaluate's try/except → returns False path).

## 8. Evidence to capture

Observer (read-only): vmbackup full/p01 condition streams, tracker stream, VM/VMI streams, events (label-mode workaround; filter involvedObject for this run + virt-handler + node), 5s pod-timeline poll for virt-handler pods on the node (deletion/recreation timestamps + new pod name), krkn pod-scenarios log. Trigger: stage exits, p01 terminal state/type/checkpoint, handler pod old/new names, tracker observations (2-min poll), verdict notes. All under `cbt-chaos/scenarios_v2/CBT-I-06/runs/<RUN_ID>/`.

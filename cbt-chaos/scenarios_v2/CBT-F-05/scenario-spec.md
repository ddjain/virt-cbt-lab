# Scenario: Restart the node virtualization backup handler during a full CBT copy

- **Jira:** CBT-F-05 — Restart the node backup handler during a full backup
- **Priority:** P1
- **Technical scenario:** `pod-scenarios`
- **Chaos phase:** Active operation

## 1. Jira objective and hypothesis

The issue asks whether a node-level virtualization handler interruption during an active full backup is safe. Delete only the `virt-handler` DaemonSet pod on the CBT VM's worker node while the launcher reports that the disk copy has started. The full backup may complete after the handler returns or may terminate with a clear backup-status-lost error; a successful-looking result MUST NOT advance a checkpoint incorrectly. The handler must return through normal DaemonSet reconciliation, and the recovered VM must support a distinct follow-up backup on the same VM.

The issue fields are: workflow **Full backup**; target **virtualization handler on the CBT worker node**; action **delete the virtualization handler pod on the CBT node**; timing **during the active disk-copy period**; signal **full backup is actively copying**; duration **immediate**; recovery **automatic DaemonSet recovery**; verification **handler return, final backup result, tracker consistency, and a clean follow-up backup**; expected outcome **safe handling of node-level control-plane interruption**.

## 2. Evidence and live target resolution

The local and remote worktrees use branch `triage-issue` at commit `2ee04b0`. The active Makefile delegates to `scripts/e2e-stage.sh`, which consumes `TYPE=full`, `TYPE=incremental`, and `TYPE=recover`. `TYPE=full` runs preflight, creates the managed VM/workload, and takes one Full backup; it does not run incremental or restore verification.

Read-only inspection confirmed existing run-scoped CBT VMs/backups and a Running/Ready `virt-handler` selected by the worker node of a live VMI. The new run is isolated by a unique `RUN_ID`; the script derives the new VMI's actual node and resolves the exact Ready handler there at injection time. Existing F01/F02 objects are not eligible targets.

## 3. Workflow and prerequisites

Use a unique run ID and an execution shell with the normal repository prerequisites and host-local `KUBECONFIG_PATH`; never commit a kubeconfig path or value. The active default is the RHEL 9 / `large-odf` profile. The trigger uses a deterministic 8-file, 1-GiB-per-file baseline to widen the copy window; the actual copy duration MUST be measured from launcher logs, not inferred from payload size. The 80-GiB RHEL profile must have capacity for this workload and the full destination.

```sh
RUN_ID=<new-unique-run-id> bash cbt-chaos/scenarios_v2/CBT-F-05/chaos-trigger.sh
```

The trigger invokes the active staged workflow:

```sh
make e2e TYPE=full NAME="$RUN_ID" \
  VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
  NAMESPACE="$NAMESPACE" GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
  GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
  GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"
```

The observer is armed before this command. It attaches only to the run-labeled launcher; the 1-second interval is for pod/log reconnection, never an injection delay.

## 4. Target and validated disruption

**Primary target:** one `virt-handler` pod in namespace `openshift-cnv`, resolved from the CBT VMI's actual `status.nodeName` at the copy signal. The observer verifies its label, node, UID, readiness, the handler DaemonSet readiness, and that the exact full backup is still nonterminal; it then deletes only that pod with `oc`.

**Why this uses direct `oc`:** the run's VM node and exact handler pod do not exist until setup completes. Krkn's target selectors must be supplied when Krkn starts; pre-starting it with a broad handler selector could disrupt an unrelated node, while starting it after the copy signal risks missing the short window. The host-side event observer therefore performs the narrowly scoped `oc` deletion. If this scenario is changed to use Krkn, it must use Krkn's native trigger from process start and must preserve the exact dynamically resolved target without broadening scope.

```sh
oc delete pod "$handler" -n openshift-cnv --wait=false
```

The selector derives from the VMI's actual node and the Ready `virt-handler` pod on that node; it is not a namespace-wide deletion. The observer rechecks the run backup and exact handler UID/readiness immediately before mutation. No Krkn command is part of the active trigger.

## 5. Deterministic injection signal and fallback

The signal is the exact run backup's compute log entry containing both `"backupName":"vm-backup-${RUN_ID}"` and `"msg":"Backup started"`. The observer starts with `--since-time` captured before E2E, so an old launcher log entry cannot trigger the disruption. At the signal it re-reads that exact `VirtualMachineBackup`, resolves the VMI's actual node and its one Ready `virt-handler`, records the pod UID, checks DaemonSet readiness, and revalidates the same UID and nonterminal backup before direct deletion.

Trigger output is saved to `cbt-chaos/scenarios_v2/CBT-F-05/runs/$RUN_ID/trigger.log`. The trigger's freshness guard refuses a `RUN_ID` with existing lifecycle data or evidence, with one allowance: the run's own `runs/$RUN_ID/observer/` directory may exist when a read-only external observer pre-arms watches before the trigger starts; any other pre-existing content under the run directory still blocks the run.


## 6. Pass/fail criteria

A product **pass** requires all applicable checks below, with the actual branch (completion or clear failure) recorded rather than assumed:

- The exact launcher pod/UID, run-specific `Backup started` timestamp, VMI node, exact handler pod/UID, direct `oc delete` result, deletion event, and replacement handler UID are captured.
- The `virt-handler` DaemonSet returns to its expected desired/ready count, and the replacement handler is Ready on the CBT node. No manual handler restart is used.
- The full `VirtualMachineBackup` reaches a settled terminal state. A failure must have a clear reason; a successful result must be `type=Full`, have a non-empty checkpoint and expected root-disk included volume, and must not expose a failed checkpoint as valid.
- Before follow-up, a failed full must leave the prior tracker checkpoint unchanged; a successful full must set latest checkpoint to its reported checkpoint. The VM/VMI recovers, CBT is `Enabled`, and the recovered launcher's checkpoint tree agrees with the tracker.
- Preserve the original full PVC/partial artifact. Do not treat a partial image as a restore source; inspect qcow2 metadata where available.
- If the original full succeeds, attempt a distinct same-VM incremental backup and run chain/restore verification. If the original full fails terminally, the trigger invokes `TYPE=recover` on the same managed VM. That stage creates a new `vm-recovery-full-${RUN_ID}-rNNN` and `vm-recovery-pvc-${RUN_ID}-rNNN` through the existing tracker, then verifies a baseline restore. The original failed resources remain untouched.

A product **fail** includes a false successful backup, tracker/checkpoint advancement from a failed copy, unclear failure reason, handler/VM/CBT recovery failure, partial-artifact acceptance, or incorrect recovery backup/restore. The expected safe-failure branch passes only if the failed original state is consistent and the distinct same-VM recovery succeeds; a blocked recovery is inconclusive.


### Evidence commands

Use the exact run-derived names after the workflow resolves them:

```sh
oc get vmbackup "vm-backup-${RUN_ID}" -n "$NAMESPACE" -o yaml
oc get vmbackuptracker "vm-tracker-${RUN_ID}" -n "$NAMESPACE" -o yaml
oc get vm "vm-${RUN_ID}" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}{"\n"}'
oc get vmi "vm-${RUN_ID}" -n "$NAMESPACE" -o wide
oc get pods -n "$NAMESPACE" -l "vm.kubevirt.io/name=vm-${RUN_ID}" -o wide
oc get ds virt-handler -n openshift-cnv -o wide
oc get pods -n openshift-cnv -l kubevirt.io=virt-handler --field-selector="spec.nodeName=${NODE_NAME}" -o wide
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp
oc exec -n "$NAMESPACE" "$RECOVERED_LAUNCHER_POD" -c compute -- \
  virsh checkpoint-list "${NAMESPACE}_vm-${RUN_ID}" --tree
```

Record full-backup conditions/reason, checkpoint, included volumes, tracker latest checkpoint, destination PVC phase, handler/launcher owner and UID transitions, VM/VMI readiness, and relevant events. The repository's restore verifier checks guest file counts and canonical manifest hashes; it does not by itself prove qcow2 allocation/backing metadata.

## 7. Same-VM follow-up

When the original full succeeds, the supported next stage is `make e2e TYPE=incremental VM="vm-${RUN_ID}"`. If it terminates with failure, the trigger uses `make e2e TYPE=recover VM="vm-${RUN_ID}"`; the recovery stage creates a distinct force-full backup and PVC through the same tracker, and verifies the saved baseline. It requires the saved run metadata, matching VM UID, VM/VMI readiness, CBT Enabled, original failed full/PVC, readable tracker, supported `forceFullBackup` API schema, and unused recovery names. If these checks fail, it reports BLOCKED without creating resources. Neither branch deletes/reuses the original backup or PVC.

## 8. Blast radius, recovery, and conflicts

Only one `virt-handler` pod on the new CBT VMI's node is eligible. The deletion can transiently affect other VMs on that node; the DaemonSet owns recovery. Do not run another node/pod disruption concurrently or use namespace-wide selectors. Preserve failed backup/PVCs and partial artifacts. Never run `make clean-all`.

The read-only inspection confirmed existing CBT runs and a Ready node-local handler; the trigger resolves the new VM's node and exact handler at execution time. Dry-run and readiness are not product evidence: use the per-run trigger log and root lifecycle report to judge the terminal backup branch, tracker/checkpoint, CBT, handler recovery, same-VM follow-up, and restore result. Trigger logs are retained under the scenario's `runs/$RUN_ID/` directory for targeted report pull.

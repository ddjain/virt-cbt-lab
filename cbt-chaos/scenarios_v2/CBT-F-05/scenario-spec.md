# Scenario: Restart the node virtualization backup handler during a full CBT copy

- **Jira:** CBT-F-05 — Restart the node backup handler during a full backup
- **Priority:** P1
- **Technical scenario:** `pod-scenarios`
- **Chaos phase:** Active operation

## 1. Jira objective and hypothesis

The issue asks whether a node-level virtualization handler interruption during an active full backup is safe. Delete only the `virt-handler` DaemonSet pod on the CBT VM's worker node while the launcher reports that the disk copy has started. The full backup may complete after the handler returns or may terminate with a clear backup-status-lost error; a successful-looking result MUST NOT advance a checkpoint incorrectly. The handler must return through normal DaemonSet reconciliation, and the recovered VM must support a distinct follow-up backup on the same VM.

The issue fields are: workflow **Full backup**; target **virtualization handler on the CBT worker node**; action **delete the virtualization handler pod on the CBT node**; timing **during the active disk-copy period**; signal **full backup is actively copying**; duration **immediate**; recovery **automatic DaemonSet recovery**; verification **handler return, final backup result, tracker consistency, and a clean follow-up backup**; expected outcome **safe handling of node-level control-plane interruption**.

## 2. Evidence and live target resolution

The local and execution-host checkouts both report revision `111e3e0`. Their active Makefiles route `make e2e` through `scripts/e2e-stage.sh` and implement `TYPE=full` and `TYPE=incremental`. The full-stage path runs preflight, `vm-setup`, and `vm-backup`; it does not run an incremental pass or restore verification. Therefore this scenario uses the minimum matching workflow, `TYPE=full`, and performs recovery/follow-up verification explicitly afterward.

The live cluster was inspected read-only. Three currently running CBT VMIs reported `changedBlockTracking.state=Enabled` and shared one worker node. The corresponding handler DaemonSet is `openshift-cnv/virt-handler`, with selector label `kubevirt.io=virt-handler`; one matching handler pod on the CBT node was Running and Ready. The DaemonSet reported 28 desired and 28 ready pods. The observed launcher label is `vm.kubevirt.io/name=<VM_NAME>`, and its owner is the matching VMI.

These live observations are evidence of current cluster state, not permanent run inputs. `chaos-trigger.sh` requires a new `RUN_ID`, derives `vm-${RUN_ID}`, resolves that VMI's node at the signal, and resolves the one `virt-handler` pod on that node immediately before invoking Krkn. It refuses an existing checkout run directory or any existing resource containing the run ID. Do not reuse the existing F-01 resources: the live namespace already contains failed full-backup objects for two F-01 runs and a completed recovery run.

No active copy was run or injected during triage. The current observed resources are state/conflict evidence only; the actual backup result, timing, handler replacement identity, and checkpoint behavior remain unobserved until an approved execution.

## 3. Workflow and prerequisites

Use a unique run ID and an execution shell with the normal repository prerequisites and host-local `KUBECONFIG_PATH`; never commit a kubeconfig path or value. The active default is the RHEL 9 / `large-odf` profile. The trigger uses a deterministic 8-file, 1-GiB-per-file baseline to widen the copy window; the actual copy duration MUST be measured from launcher logs, not inferred from payload size. The 80-GiB RHEL profile must have capacity for this workload and the full destination.

```sh
RUN_ID=<new-unique-run-id> bash cbt-chaos/scenarios_v2/CBT-F-05/chaos-trigger.sh
```

The script invokes the active staged workflow as:

```sh
make e2e TYPE=full NAME="$RUN_ID" \
  GUEST_BASE_FILE_COUNT=8 \
  GUEST_FILE_SIZE_MIN_MIB=1024 \
  GUEST_FILE_SIZE_MAX_MIB=1024 \
  KUBECONFIG_PATH="$KUBECONFIG_PATH"
```

The observer is armed before this command. One-second polling is only for discovery/reconnection of the new run's launcher pod; injection is gated on the exact launcher log signal below, never on a fixed sleep, object creation, or a broad `Progressing=True` condition.

## 4. Target and validated disruption

**Primary target:** one `virt-handler` pod in namespace `openshift-cnv`, resolved by the CBT VMI's actual `status.nodeName`, label `kubevirt.io=virt-handler`, and the exact pod name immediately before injection. The observer verifies the label and node; Krkn receives the exact node and name pattern only, because its help says `--name-pattern` applies only when `--pod-label` is omitted. The action is pod deletion performed by Krkn; the observer never mutates the cluster.

**Current Krkn metadata:** the execution host's `krknctl list available` included `pod-scenarios`; `krknctl describe pod-scenarios` defines `--namespace`, `--node-names`, `--pod-label`, `--name-pattern`, `--disruption-count`, `--execution`, `--kill-timeout`, and `--expected-recovery-time`. `krknctl run pod-scenarios --help` also exposes trigger flags, but availability of `oc` inside Krkn's trigger-command container was not established. The host-local observer is therefore the safer event-driven fallback; Krkn still performs the deletion.

The exact runtime command is:

```sh
krknctl run pod-scenarios \
  --namespace openshift-cnv \
  --node-names "$NODE_NAME" \
  --name-pattern "^${HANDLER_POD_NAME}$" \
  --disruption-count 1 \
  --execution serial \
  --kill-timeout 180 \
  --expected-recovery-time 120 \
  --kubeconfig "$KUBECONFIG_PATH" \
  --krkn-kubeconfig /home/krkn/.kube/config
```

The dry-run command used the observed live identity and the same selector/limits:

```sh
krknctl run pod-scenarios --dry-run \
  --namespace openshift-cnv \
  --node-names "$NODE_NAME" \
  --name-pattern "^${HANDLER_POD_NAME}$" \
  --disruption-count 1 \
  --execution serial \
  --kill-timeout 180 \
  --expected-recovery-time 120 \
  --kubeconfig "$KUBECONFIG_PATH" \
  --krkn-kubeconfig /home/krkn/.kube/config
```
Krkn returned `Scenario schema valid`, `All required fields present`, and `Values validated` for the live node/handler values; those host-specific names are omitted from the spec and are resolved dynamically by the script.

## 5. Deterministic injection signal and fallback

The canonical active-copy signal is the `Backup started` line in the run's `virt-launcher` `compute` container log. Repository design documentation explicitly distinguishes this from backup-object creation and says `Progressing=True` is only a broad state check. The observer:

1. waits for the exact run-labeled launcher (`vm.kubevirt.io/name=vm-${RUN_ID}`);
2. records the pre-copy tracker and `virsh checkpoint-list ... --tree` state;
3. follows that launcher compute log and waits for the first exact `Backup started` line;
4. resolves the VMI node and exact current `virt-handler` pod on that node; and
5. invokes the validated, narrowly selected Krkn command.

This is event-driven and has no arbitrary timing substitute. If the launcher signal cannot be observed, the observer fails and no handler pod is deleted. `--trigger-command`/Kubernetes-trigger support is not used because the runtime availability of the required host `oc`/log access inside the Krkn container was not established; a host-local log observer avoids that unvalidated boundary. The Krkn command is started only after the signal, while the observer itself is started before E2E.

## 6. Pass/fail criteria

A product **pass** requires all applicable checks below, with the actual branch (completion or clear failure) recorded rather than assumed:

- The exact launcher pod/UID, `Backup started` timestamp, VMI node, exact handler pod/UID, Krkn result, deletion event, and replacement handler pod/UID are captured.
- The `virt-handler` DaemonSet automatically returns to its expected desired/ready count, and the replacement handler is Ready on the CBT node. No manual handler restart or deletion is used.
- The full `VirtualMachineBackup` reaches a settled terminal state. If it fails, its reason is an explicit backup-status-lost/handler-related or other clear terminal failure; `Done=True` alone is not evidence of success. If it completes, its `status.type` is `Full`, checkpoint is non-empty, included volume is the expected root disk, and its reason is not a terminal failure reason.
- Tracker state matches the settled full result before any follow-up: a failed copy MUST NOT advance `status.latestCheckpoint` or expose a failed checkpoint as valid; a successful full backup has tracker latest equal to its reported checkpoint. The automatic same-VM incremental follow-up may then advance the tracker once to its distinct child checkpoint. Capture tracker snapshots before and after each reconciliation.
- The VMI returns to `Running` and Ready, the VM reports CBT `Enabled`, and the post-recovery launcher checkpoint tree is captured. Do not treat a transient launcher checkpoint as valid solely because it appeared during a copy; compare it with the tracker and terminal backup state.
- The full destination PVC and any partial artifact are preserved. A partial/failed destination is not accepted as a valid restore source. Inspect qcow2 metadata (`qemu-img info` and `qemu-img map --output=json`) where the restore helper is available.
- A distinct post-chaos backup is attempted on the **same recovered VM**, without deleting or reusing the failed backup, tracker, or PVC. Its terminal result, type, reason, checkpoint, tracker update, CBT state, destination PVC, and restore/data result are recorded.

A product **fail** is any false successful backup, checkpoint/tracker advancement from a failed copy, missing/ambiguous terminal reason, handler not returning automatically, VM/CBT not recovering, acceptance of a partial artifact, duplicate/reused follow-up identity, or incorrect follow-up restore/data result. Missing signal or incomplete evidence is inconclusive, not a pass.

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

## 7. Same-VM follow-up and known workflow limitation

If the interrupted full backup settles successfully, the supported next-stage command is:

```sh
make e2e TYPE=incremental VM="vm-${RUN_ID}" KUBECONFIG_PATH="$KUBECONFIG_PATH"
```

Only run it after the saved run metadata, full checkpoint, tracker, VMI Ready state, and CBT Enabled state are confirmed. It creates the next distinct incremental backup/PVC and then, on the final planned pass, performs repository chain/restore verification.
`chaos-trigger.sh` automatically runs this same-VM incremental stage only after the full stage succeeds and the active-copy signal has fired. If the full backup fails, it preserves the failed resources and stops; the distinct-name full-backup recovery remains **BLOCKED** pending an approved manual API path.

If the full backup fails, `scripts/vm-backup.sh` has no backup-name/PVC override: it derives one fixed full backup, tracker, and PVC name from the run ID. Therefore **the active helper cannot safely retry the failed full request**. Preserve those failed resources and request an approved manual API follow-up on the same recovered VM using a new tracker, backup, and PVC identity. Use the selected profile's existing `full-backup` manifest; render its existing placeholders for the original namespace, VM, storage profile, and run labels, while substituting unique names such as `vm-post-chaos-pvc-${RUN_ID}`, `vm-post-chaos-tracker-${RUN_ID}`, and `vm-post-chaos-backup-${RUN_ID}`. Apply the resulting three-object manifest only after approval, and verify the new request's type, terminal reason, checkpoint, tracker, and restore/data result. This manual path's API behavior and permission/storage prerequisites were not live-validated; until approved, mark the same-VM check **BLOCKED**.

A clean new VM lifecycle may supplement this test, but cannot replace the same-VM follow-up.

## 8. Blast radius, recovery, and conflicts

Only one node-local `virt-handler` pod is eligible. The deletion affects node-level virtualization control/reporting and may transiently affect other VM operations on that node; it does not target the launcher, controller, CSI, or other handler pods. The DaemonSet owns recovery. Do not run concurrently with another node/pod disruption, and do not use namespace-wide selectors.

Capture baseline tracker/checkpoint, backup/PVC, VMI/VM, handler DaemonSet/pod, and event evidence before injection because pod replacement can remove logs. Preserve failed backup/PVC resources and partial artifacts until verification is complete. No cleanup, `make resync`, E2E execution, chaos injection, `make clean-all`, or report pull was performed during this triage.

Known conflicts/uncertainties are the absence of an active copy in the inspected live state, the unmeasured copy duration for the widened workload, the unobserved terminal branch after handler deletion, the unvalidated availability of `oc` inside Krkn's trigger container, and the approved manual API prerequisite for a same-VM retry after a failed full. These are explicit execution gates, not expected outcomes.

# Scenario: Restart the backup controller during the active disk copy

- **Jira:** CBT-F-04 — Restart the backup controller during the active disk copy
- **Priority:** P1
- **Technical scenario:** `pod-scenarios`
- **Chaos phase:** Active operation

## 1. Objective and hypothesis

Verify that deleting the current `virt-controller` leader while a full backup is actually copying disk blocks does not interrupt the data-plane copy in the VM's `virt-launcher`; the replacement controller must resume reconciliation, clean up the temporary backup-volume attachment, update the tracker exactly once, and settle the full backup successfully. The final result must be data-correct and restorable, not merely `Done=True`.

The issue's expected architectural separation is a hypothesis, not a live result: QEMU/libvirt copies through the `virt-launcher` compute container, while `virt-controller` coordinates API status, cleanup, and tracker updates.
**Issue fields:** Workflow: Full backup. Target/action: delete the current backup-controller leader pod. Injection window/signal: after the request is accepted and reconciliation begins, before completion; the exact run backup is `Progressing=True` without `Done=True`. Duration: immediate. Recovery: automatic leader election. Verification: new leader, both replicas Ready, exactly one checkpoint/tracker advancement, temporary attachment cleanup, and restore.

## 2. Workflow and prerequisites

The local and active remote checkout are both revision `111e3e0`. Their Makefiles route `make e2e` through `scripts/e2e-stage.sh`; the staged interface consumes `TYPE=full`. `TYPE=full` creates a new managed VM, initializes the deterministic workload, and creates one full backup; it does not run incremental or restore verification. This is the minimum workflow matching the Jira full-backup target:

```sh
RUN_ID=<unique-lowercase-run-id> bash cbt-chaos/scenarios_v2/CBT-F-04/chaos-trigger.sh
```

The script invokes the supported stage as:

```sh
make e2e TYPE=full NAME="$RUN_ID" VM_OS="${VM_OS:-rhel9}" \
  MANIFEST_VARIANT="${MANIFEST_VARIANT:-large-odf}" \
  GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-8}" \
  GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-1024}" \
  GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-1024}"
```

The larger deterministic workload is only a window-widening measure; the exact copy window is established by the launcher timestamps, never assumed from PVC size or object creation time. The test host must provide `make`, `oc`, `jq`, `krknctl`, and its normal host-local `KUBECONFIG_PATH`; the script does not contain a kubeconfig, host path, secret, or cleanup operation. Record the run's VM, launcher, full backup, tracker, and destination PVC names before injection. Do not reuse an existing run or run concurrent lifecycle commands in the same checkout.

After the full stage, the same recovered VM needs a distinct post-chaos backup attempt. When the full backup succeeded and the chaos signal fired, the trigger runs the supported `TYPE=incremental VM=vm-${RUN_ID}` stage; this creates a new backup/PVC identity and performs final chain/restore verification without recreating the VM. If the full backup failed or has no valid checkpoint, the active helper has no unique-name full-retry override; mark the same-VM follow-up **BLOCKED**, preserve original resources, and request an approved manual API recovery path. A clean new `TYPE=all` lifecycle is supplemental only and never replaces the same-VM check.

## 3. Target and disruption

**Component:** the current backup controller leader in `openshift-cnv`. A live read-only inspection found two ready pods, both labeled `kubevirt.io=virt-controller`; the `virt-controller` Lease's `spec.holderIdentity` identified the leader. At inspection time the holder was one exact pod name, and the standby was also Ready. Leader identity is resolved again immediately before deletion; the exact pod name is never guessed or selected by an unscoped controller label alone.

**Target selector at injection:** namespace `openshift-cnv` and an exact name regex `^<Lease.spec.holderIdentity>$`; disruption count `1`. The script first verifies that this exact Lease holder is a Running pod carrying `kubevirt.io=virt-controller`, then passes only the exact name pattern to Krkn. This avoids the `pod-scenarios` behavior where `--name-pattern` is only meaningful when `--pod-label` is omitted, while still grounding the target's controller label before mutation. This excludes `virt-api`, `virt-handler`, and the standby controller.

**Validated Krkn scenario and metadata:** the execution host's registry lists `pod-scenarios`; `krknctl describe pod-scenarios` exposes `--namespace`, `--pod-label`, `--name-pattern`, `--disruption-count`, `--execution`, `--kill-timeout`, and `--expected-recovery-time`. `krknctl run pod-scenarios --help` exposes `--trigger-command` and Kubernetes trigger flags, plus `--dry-run` on `krknctl run`. The exact current-leader selector passed schema validation with:

```sh
krknctl run pod-scenarios --dry-run \
  --kubeconfig "$KUBECONFIG_PATH" \
  --krkn-kubeconfig /home/krkn/.kube/config \
  --namespace openshift-cnv \
  --name-pattern "^${LEADER}$" \
  --disruption-count 1 --execution serial \
  --kill-timeout 180 --expected-recovery-time 120
```

The dry run returned `Scenario schema valid`, `All required fields present`, and `Values validated` for an observed leader-name value; the spec omits that transient pod identity, and the script resolves the current Lease holder at runtime.

Krkn's trigger interfaces can poll Kubernetes conditions or execute a command, but the required signal is a substring in a changing `virt-launcher` log, not a `VirtualMachineBackup` condition. `Progressing=True` and backup-request creation are broad control-plane states and can precede PVC binding, hotplug, and the actual copy. The script therefore uses a host-local, read-only log observer and invokes Krkn only after the exact run backup's `Backup started` line. Krkn performs the deletion; the observer does not mutate resources. This is the safe fallback because availability of `oc`/the required launcher-log access inside Krkn's trigger container was not established. No arbitrary sleep or `Progressing=True` substitute is accepted.

## 4. Deterministic injection timing

**Condition:** for the run-derived full backup, the run-labeled launcher's compute-container log contains both the exact backup name and `msg":"Backup started"` (the observed runtime JSON also records a timestamp and `pos":"backup.go:83"`). This is the active QEMU/libvirt copy boundary. A live successful full backup showed `Backup begin called` followed by `Backup started`; its API object was created earlier and reached `Done=True` later, demonstrating why creation/Progressing are insufficient.

**Arming and watch:** `chaos-trigger.sh` starts the event observer before `make e2e TYPE=full`. It discovers only the launcher selected by `vm.kubevirt.io/name=vm-${RUN_ID}`, follows that compute log, and waits for the exact run backup's `Backup started` line. Before invoking Krkn it rejects an already-terminal backup, resolves Lease `virt-controller`, and verifies the exact holder pod and label. One-second polling is only for launcher discovery/reconnection; the hard deadline is a fail-safe, not a timing-based injection, and no target is touched if the signal is absent.

The live cluster evidence supports this distinction: a full backup log recorded `Backup started` at `18:57:18Z`, while its `VirtualMachineBackup` reached `Done=True` at `18:58:22Z`; status showed `type=Full`, a non-empty checkpoint, and `includedVolumes` containing `rootdisk`/`vda`. A separate observed backup ended with `Done=True` and reason `Backup has failed: VMI backup status was lost`, confirming that the boolean condition alone cannot establish success.

## 5. Expected behavior and pass/fail criteria

**Pass only if all are established:**

- The observer records the exact run-derived launcher pod/UID and the `Backup started` timestamp before disruption. Krkn targets exactly one Lease-holder `virt-controller` pod; its deletion and replacement pod/leader-election evidence are recorded. Both controller replicas return Ready, and a new Lease holder is observed.
- The original full `VirtualMachineBackup` settles `Done=True` with a non-failure reason, `status.type=Full`, non-empty `status.checkpointName`, expected `includedVolumes` (`rootdisk`/`vda`), and no duplicate backup/checkpoint object attributable to the restart. Inspect conditions twice after reconciliation.
- The controller completes cleanup: the temporary backup destination attachment/utility volume is detached, its attachment pod is gone or terminal as appropriate, and the destination PVC remains the intended run PVC and `Bound`. Preserve events before any natural garbage collection.
- Before the same-VM `TYPE=incremental` follow-up, the tracker has exactly one advancement to the original full checkpoint and `latestCheckpoint.name` equals that full backup's checkpoint. The incremental follow-up must then advance it once to a distinct child checkpoint. Capture tracker and launcher checkpoint-tree state before injection, after full reconciliation, and after the incremental stage.
- The VM/VMI remains or returns `Running`, the replacement launcher is Ready, and VM `.status.changedBlockTracking.state` is `Enabled`. The uninterrupted data copy is evidenced by the launcher result, not by controller process survival.
- Restore verification reconstructs the full artifact and matches the baseline workload file count, payload bytes, and canonical manifest hash. Where available, record `qemu-img info` and `qemu-img map --output=json`; file size or `Done=True` alone is insufficient.
- After the original full stage succeeds and an injection signal was recorded, the script attempts a distinct same-VM backup with `make e2e TYPE=incremental VM="vm-${RUN_ID}" KUBECONFIG_PATH="$KUBECONFIG_PATH"`; this creates a new incremental backup/PVC, advances the tracker to a distinct checkpoint, and runs chain/restore verification. If the full backup has no valid checkpoint or the trigger signal was not observed, the follow-up is BLOCKED; preserve original resources and do not retry their names.

**Fail:**

- The wrong pod, more than one controller, a standby rather than the Lease holder, or a pod outside the exact `kubevirt.io=virt-controller`/name scope is disrupted.
- The active-copy signal is absent, the observer times out, or injection is inferred only from backup creation/`Progressing=True`.
- The original backup falsely reports success, has a terminal failure reason, duplicate/replayed checkpoint, missing/incorrect tracker update, wrong type, missing checkpoint, or wrong included volume; cleanup leaves a stale temporary attachment.
- The controller does not fail over, replicas do not recover, the VM/CBT state does not recover, or the original/follow-up artifact fails restore/hash verification. Missing evidence or a blocked distinct-name follow-up is inconclusive/blocked, not a pass.

**Evidence commands (substitute the exact run names and recovered launcher):**

```sh
oc get lease virt-controller -n openshift-cnv -o yaml
oc get pods -n openshift-cnv -l kubevirt.io=virt-controller -o wide --show-labels
oc get vmbackup vm-backup-${RUN_ID} -n "$NAMESPACE" -o yaml
oc get vmbackuptracker vm-tracker-${RUN_ID} -n "$NAMESPACE" -o yaml
oc get vm vm-${RUN_ID} -n "$NAMESPACE" -o yaml
oc get vmi vm-${RUN_ID} -n "$NAMESPACE" -o wide
oc get pvc vm-backup-pvc-${RUN_ID} -n "$NAMESPACE" -o yaml
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp
oc logs -n "$NAMESPACE" <launcher-pod> -c compute
oc exec -n "$NAMESPACE" <recovered-launcher-pod> -c compute -- \
  virsh checkpoint-list "${NAMESPACE}_vm-${RUN_ID}" --tree
```

Also inspect the controller logs around the injection for start/requeue/cleanup/tracker messages, the VMI `backupStatus`, destination PVC and attachment events, and the preserved qcow2 artifact. Run the repository restore verifier only in the completed supported workflow; it checks guest semantics but does not independently prove qcow2 allocation maps.

## 6. Blast radius, recovery, cleanup, and uncertainties

Only one current leader pod in `openshift-cnv` is eligible; controller failover is expected to be automatic and the standby must remain untouched. The controller deletion can delay reconciliation but does not directly stop QEMU in the run's launcher. The shared cluster currently contains multiple unrelated VMs/backups and controller replicas, so the run-derived launcher/log selector and exact Lease-holder selector are mandatory.

Do not run `make clean-all`, delete failed/original backup objects or PVCs, retry by reusing names, or mutate unrelated resources. Preserve original objects, events, controller/launcher logs, tracker/checkpoint state, and attachment evidence before any separately approved cleanup. Krkn's expected-recovery timeout is an observation guard, not proof of product recovery.

Live triage was read-only: cluster access, controller replicas/Lease, runtime logs/status/events, and Krkn registry/help/dry-run were inspected; no E2E or chaos was run. The observed controller image reports the cluster's KubeVirt version context, but downstream patches and timing remain execution uncertainties. The trigger was not live-validated, and availability of `oc` in a Krkn trigger-command container was not established; the host-local observer fallback is intentional. The actual replacement leader, copy duration, terminal outcome, tracker update count, attachment cleanup, and same-VM follow-up result remain unproven until an approved run.

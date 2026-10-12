# Scenario: Stop the launcher during a full CBT backup

- **Jira:** CBT-F-01 — Stop the virtual machine backup process during a full backup
- **Priority:** P1
- **Technical scenario:** `pod-scenarios`
- **Chaos phase:** Active operation

## 1. Objective and hypothesis

Verify that an in-progress full backup fails safely when the VM's `virt-launcher` pod—whose `compute` container runs QEMU/libvirt backup copying—is deleted during the active disk-copy period. The failed backup must not yield a usable checkpoint or advance the tracker's latest checkpoint; the VM must restart and Changed Block Tracking (CBT) must return to Enabled. A later clean backup/restore lifecycle must succeed.

## 2. Workflow and prerequisites

The active checkout's Makefile routes `e2e` through `scripts/e2e-stage.sh`. In checkouts that implement the staged interface, `TYPE=full` creates a new lifecycle, sets up a VM, and performs its full backup. Inspect the active local and remote Makefile/workflow source and `make help` before every run; do not assume checkouts support the same `TYPE` modes.

- Each execution MUST use a unique lifecycle ID, supplied as `RUN_ID` to `chaos-trigger.sh`; the proposed default for this execution is `20261010-cbt-f-01-r08`. Confirm it remains unused in local/remote scenario artifacts and live namespace before execution. The test namespace is `vm-cbt-demo`. The executing shell must have the active checkout's normal prerequisites and host-local `KUBECONFIG_PATH` set; do not place kubeconfig contents or host paths in this artifact. This execution is the Windows variant: the trigger passes `VM_OS=windows` to `make e2e`, which uses the `windows-server-2022` golden DataSource (`vm-cbt-images/windows-golden`, already Succeeded on the configured cluster), a 40Gi cloned root disk, a run-scoped OOBE Secret (requires `WINDOWS_ADMIN_PASSWORD_FILE`), QEMU Guest Agent file operations instead of SSH, and the `windows-*` backup/restore manifests (48Gi full / 30Gi incremental destination PVCs). The baseline workload keeps the configured file count with sizes from the configured range; `GUEST_BASE_FILE_COUNT` and `GUEST_FILE_SIZE_MIN_MIB`/`GUEST_FILE_SIZE_MAX_MIB` are passed through by the trigger when set in its environment. A live Windows launcher pod confirmed `virsh` access in `compute` and the same `Backup started` log line used as the injection signal.
Invocation performed by `chaos-trigger.sh` (per-run OS/workload values are passed through to `make e2e` when exported in the trigger environment):
```sh
make e2e TYPE=full NAME=20261010-cbt-f-01-r08 VM_OS=windows GUEST_FILE_SIZE_MIN_MIB=4 GUEST_FILE_SIZE_MAX_MIB=6 GUEST_EXEC_POLL_ATTEMPTS=900
```
The configured baseline payload widens the active-copy window; its actual copy duration is unmeasured and must be observed, not assumed. The full-only stage is the minimum workflow matching the Jira target. The interrupted run is expected to stop at the failed full-backup stage, so `chaos-trigger.sh` returns nonzero for that expected E2E failure; neither process status alone is the scenario verdict. The workflow's full stage does not itself perform restore verification. After recording recovery on that VM, prove recovery with a separate clean `TYPE=all` lifecycle using a new run ID (same `VM_OS`); this produces a fresh full backup, an incremental backup, and repository restore/data verification. Do not reuse the failed run ID or concurrently run another lifecycle.

## 3. Target and disruption

**Component:** the run's `virt-launcher` pod, specifically its `compute` container. The KubeVirt controller coordinates backup reconciliation but does not copy disk bytes. The active copy starts at the `Backup started` line in the launcher log.

**Narrow selector:** namespace `vm-cbt-demo`; pod label `vm.kubevirt.io/name=vm-${RUN_ID}`; name regex `^virt-launcher-vm-${RUN_ID}-.*$`; disruption count 1. A live launcher inspected during triage had the `vm.kubevirt.io/name` label and was owned by the correspondingly named VMI. The selector is scoped to the unique run rather than the many other VMs present in the namespace.

**Injection mechanism:** `chaos-trigger.sh` follows the exact run launcher's `compute` log from the host and directly deletes that pod with `oc` as soon as `Backup started` appears. The Krkn command was dry-run validated, but launching Krkn only after the signal would add its measured startup delay (about 5–9 seconds), longer than the short copy window. The narrowly scoped `oc delete` therefore preserves the exact run-labeled pod target and avoids that delay; this is an intentional, event-driven fallback, not an arbitrary sleep.

```sh
oc delete pod "$pod" -n "$NAMESPACE" --wait=false
```

The direct mutation is gated by the log event, never by backup-object creation or elapsed time. The observer is armed before E2E and refuses injection if the baseline/tracker preconditions or exact copy signal cannot be established. The full-stage result and actual pod/backup transitions still require live evidence; syntax or a Krkn dry run alone does not validate the injection.

## 4. Pass/fail criteria

**Pass only if all are established:**

- The observer records the exact launcher pod name and UID after `Backup started`; the scoped direct `oc delete` removes that pod, and the run's VMI receives a replacement launcher. Record the corresponding pod event and deletion result.
- The `VirtualMachineBackup` reaches a settled terminal failure with a clear failure reason. `Done=True` alone is not success or failure evidence; inspect its reason and other conditions.
- Capture tracker status and the launcher's libvirt checkpoint tree before injection. This new lifecycle starts without a tracker latest checkpoint; after failure, `status.latestCheckpoint` must still be unset and the backup must not report a usable checkpoint. Record the libvirt tree before and after VM recovery, but do not equate a transient launcher-side checkpoint created during copy with a tracker advancement.
- The VM/VMI returns to Running, the replacement launcher is Ready, and VM `.status.changedBlockTracking.state` returns to `Enabled`.
- Preserve and inspect the failed destination PVC/artifact before any retry. It must not be accepted as a valid recovery point. Record relevant events and launcher/backup status before artifacts or pods disappear.
- A separate clean recovery lifecycle completes a fresh full and incremental backup; the repository's restore verification passes baseline and combined file-set manifest hashes. This validates recovery, not the interrupted artifact.

**Fail:** false successful backup/checkpoint advancement, any checkpoint attributable to the failed copy, VM/CBT not recovering, a partial artifact accepted as restorable, or failure of the clean recovery backup/restore lifecycle. An unavailable signal, missing evidence, or timeout is inconclusive—not a pass.

**Evidence commands** (substitute the exact run resources and launcher pod resolved by the workflow):

```sh
oc get vmbackup vm-backup-20261010-cbt-f-01 -n vm-cbt-demo -o yaml
oc get vmbackuptracker vm-tracker-20261010-cbt-f-01 -n vm-cbt-demo -o yaml
oc get vm vm-20261010-cbt-f-01 -n vm-cbt-demo -o jsonpath='{.status.changedBlockTracking.state}{"\\n"}'
oc get vmi vm-20261010-cbt-f-01 -n vm-cbt-demo -o wide
oc get pods -n vm-cbt-demo -l vm.kubevirt.io/name=vm-20261010-cbt-f-01 -o wide
oc get events -n vm-cbt-demo --sort-by=.lastTimestamp
oc exec -n vm-cbt-demo <replacement-launcher-pod> -c compute -- virsh checkpoint-list vm-cbt-demo_vm-20261010-cbt-f-01 --tree
```

Record the backup's settled `status.type`, conditions/reason, checkpoint name, included volumes, tracker `latestCheckpoint`, pod owner/UID transition, CBT state, and destination PVC phase. On successful follow-up output, inspect full and incremental qcow2 artifacts with `qemu-img info`/`qemu-img map --output=json` when available; repository restore verification checks guest file counts and canonical hashes but does not independently prove qcow2 delta allocation.

## 5. Blast radius, recovery, and limitations

Only the launcher pod owned by this run's VMI is eligible for deletion. Deletion causes that VM to restart and briefly interrupts its guest; other namespace VMs are excluded by both run label and exact run-derived name pattern. The pod disruption is immediate once the log trigger fires. No broad namespace cleanup is part of this scenario.

Capture baseline tracker/checkpoint state and backup/PVC evidence before execution. Allow KubeVirt to recreate the VMI launcher and verify CBT returns to Enabled. Do not delete the failed PVC or clean the namespace during evidence collection. After recovery checks, run a separate new clean full-plus-incremental lifecycle for restore verification. Failed workflow resources remain run-scoped for inspection; cleanup is a separate, explicitly reviewed operation.

Live triage confirmed cluster access, multiple existing VMs and launcher pods, and the launcher label/owner pattern. The active checkout supports `TYPE=full`; the new run's target pod appears only after setup. Krkn registry metadata and schema dry-run were checked, but Krkn is not used for this short-window deletion because its startup can outlast the copy window. Live E2E/disruption, terminal backup reason, checkpoint behavior, and VM/CBT recovery remain unvalidated.

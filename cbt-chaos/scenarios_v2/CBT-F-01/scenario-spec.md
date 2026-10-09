# Scenario: Stop the launcher during a full CBT backup

- **Jira:** CBT-F-01 — Stop the virtual machine backup process during a full backup
- **Priority:** P1
- **Technical scenario:** `pod-scenarios`
- **Chaos phase:** Active operation

## 1. Objective and hypothesis

Verify that an in-progress full backup fails safely when the VM's `virt-launcher` pod—whose `compute` container runs QEMU/libvirt backup copying—is deleted during the active disk-copy period. The failed backup must not yield a usable checkpoint or advance the tracker's latest checkpoint; the VM must restart and Changed Block Tracking (CBT) must return to Enabled. A later clean backup/restore lifecycle must succeed.

## 2. Workflow and prerequisites

The active checkout's Makefile routes `e2e` through `scripts/e2e-stage.sh`. In checkouts that implement the staged interface, `TYPE=full` creates a new lifecycle, sets up a VM, and performs its full backup. Inspect the active local and remote Makefile/workflow source and `make help` before every run; do not assume checkouts support the same `TYPE` modes.

- Each execution MUST use a unique lifecycle ID, supplied as `RUN_ID` to `chaos-trigger.sh`; the active default for this execution is `20261010-cbt-f-01-r02`. Confirm it remains unused in local/remote scenario artifacts and live namespace before execution. The test namespace is `vm-cbt-demo`. The active checkout resolves to `VM_OS=rhel9` and `MANIFEST_VARIANT=large-odf`; the 80Gi root disk has room for the 8Gi baseline payload configured below. The executing shell must have the active checkout's normal prerequisites and host-local `KUBECONFIG_PATH` set; do not place kubeconfig contents or host paths in this artifact.
Invocation performed by `chaos-trigger.sh`:
make e2e TYPE=full NAME=20261010-cbt-f-01-r02 \
  GUEST_BASE_FILE_COUNT=8 \
  GUEST_FILE_SIZE_MIN_MIB=1024 \
  GUEST_FILE_SIZE_MAX_MIB=1024
```
The 8Gi deterministic baseline payload is chosen to widen the active-copy window; its actual copy duration is unmeasured and must be observed, not assumed. The full-only stage is the minimum workflow matching the Jira target. The interrupted run is expected to stop at the failed full-backup stage, so `chaos-trigger.sh` returns nonzero for that expected E2E failure; neither process status alone is the scenario verdict. The workflow's full stage does not itself perform restore verification. After recording recovery on that VM, prove recovery with a separate clean `TYPE=all` lifecycle using a new run ID; this produces a fresh full backup, an incremental backup, and repository restore/data verification. Do not reuse the failed run ID or concurrently run another lifecycle.

## 3. Target and disruption

**Component:** the run's `virt-launcher` pod, specifically its `compute` container. The KubeVirt controller coordinates backup reconciliation but does not copy disk bytes. The active copy starts at the `Backup started` line in the launcher log.

**Narrow selector:** namespace `vm-cbt-demo`; pod label `vm.kubevirt.io/name=vm-${RUN_ID}`; name regex `^virt-launcher-vm-${RUN_ID}-.*$`; disruption count 1. A live launcher inspected during triage had the `vm.kubevirt.io/name` label and was owned by the correspondingly named VMI. The selector is scoped to the unique run rather than the many other VMs present in the namespace.

**Validated Krkn scenario:** `pod-scenarios` (listed by the execution host's `krknctl list available`). `krknctl describe pod-scenarios` confirms `--namespace`, `--pod-label`, `--name-pattern`, and `--disruption-count`; `krknctl run pod-scenarios --help` confirms a Krkn `--trigger-command` trigger. The log condition itself is deterministic, but the trigger command's `oc` availability inside Krkn's runtime was not established. Therefore `chaos-trigger.sh` uses the safer host-local event-observer fallback: it follows logs for only the run-labeled launcher and starts Krkn when that exact log line appears. Krkn still performs the pod deletion; the observer does not mutate cluster resources.

Final Krkn disruption command run by the event observer:

```sh
krknctl run pod-scenarios \
  --namespace vm-cbt-demo \
  --pod-label "vm.kubevirt.io/name=vm-${RUN_ID}" \
  --name-pattern "^virt-launcher-vm-${RUN_ID}-.*$" \
  --disruption-count 1 \
  --krkn-kubeconfig /home/krkn/.kube/config
```

`krknctl run pod-scenarios --dry-run` with these final selectors and kubeconfig configuration returned `Scenario schema valid`, `All required fields present`, and `Values validated`. This confirms schema and parameters, not that the observer/disruption/recovery has been live-tested. The observer is armed before E2E. Its one-second polling is only for run-pod discovery/reconnection; injection is gated on the exact `Backup started` log signal, never on elapsed time or backup object creation. If the log cannot be observed, no substitute signal is acceptable.

## 4. Pass/fail criteria

**Pass only if all are established:**

- The observer prints the exact launcher pod name and UID after the `Backup started` signal. Confirm that UID is deleted and the run's VMI receives a replacement launcher; record the corresponding pod event and Krkn output.
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

Live triage confirmed cluster access, multiple existing VMs and launcher pods, and the launcher label/owner pattern. The active checkout supports `TYPE=full`; the live target for this new run cannot exist until setup creates it. Krkn registry metadata and schema dry-run were validated, but no live E2E or disruption has been run. A Krkn process exit alone is not evidence that chaos landed. Also unresolved until live execution: whether `oc` is available in Krkn's trigger-command environment, the actual log timing, terminal backup reason, checkpoint behavior, and VM/CBT recovery timing.

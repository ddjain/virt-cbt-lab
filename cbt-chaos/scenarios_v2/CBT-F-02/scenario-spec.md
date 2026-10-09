# CBT-F-02: Stop only the backup execution container during a full backup

**Jira issue:** CBT-F-02  
**Priority:** P1  
**Technical scenario:** `container-scenarios`  
**Chaos phase:** Active operation

## Objective and hypothesis

During a **full backup**, stop only the `compute` container in the VM's `virt-launcher` pod while the disk copy is active. Determine whether this produces the same safe failure behavior as stopping the whole launcher pod: the full backup must settle as a terminal failure without advancing the checkpoint, while the VM recovers. The test must also distinguish a container restart in the same pod from a pod replacement.

This is the issue's requested action and target, not an observed product result. No CBT-F-02 live injection was run during triage.
**Issue fields:** Workflow: Full backup. Target/action: signal only the `compute` container in the VM launcher pod. Injection window/signal: while the full backup is actively copying, identified by the run's `Backup started` log entry. Duration: immediate (signal 9). Expected behavior: clean terminal full-backup failure, unchanged checkpoint, and automatic VM/container recovery. Verification: compare pod identity, backup result/reason, tracker/checkpoint, CBT state, then a distinct same-VM backup and restore. Expected outcome: establish whether container-only interruption is handled like a launcher-pod interruption.

## Workflow actually supported

Use a new, unique run ID and the staged full-only workflow:

```bash
NAME=<unique-run-id> NAMESPACE=<workflow-namespace> \
  KUBECONFIG_PATH=<approved-host-local-path> \
  bash cbt-chaos/scenarios_v2/CBT-F-02/chaos-trigger.sh
```

The command above is illustrative: replace both placeholders at invocation time and do not reuse an existing run. `TYPE=full` creates the VM, baseline workload, full-backup PVC/tracker/request, and stops after the full-backup stage; it does not run incremental or restore verification. The issue's full-backup stage therefore matches this minimum workflow. The active local and remote checkout context is revision `111e3e0`; both Makefiles and staged workflow source expose and consume `TYPE=full` and `TYPE=incremental`. The trigger script requires `NAME` so that its selector cannot accidentally match another run.
The script invokes `make e2e TYPE=full NAME="$NAME"` with `VM_OS` defaulting to `rhel9`, `MANIFEST_VARIANT` defaulting to `large-odf`, and an 8-file 1-GiB-per-file baseline (8 GiB total) to widen the copy window. This matches the default 80-GiB RHEL root/full profile; for a different existing profile, pass its documented `VM_OS`/`MANIFEST_VARIANT` overrides. The backup duration is not inferred from payload size; record the actual `Backup started` and terminal timestamps.

The normal full backup uses run-derived names (`vm-backup-<run-id>` and `vm-backup-pvc-<run-id>`). The active workflow does not expose a retry-name/PVC override. A failed full request must remain preserved; do not rerun `make e2e TYPE=full` against the same run or reuse its failed names.

## Target and live evidence

Target the one launcher pod for the selected VM using the exact VM label, and then the `compute` container:

```text
namespace: <workflow-namespace>
label selector: vm.kubevirt.io/name=vm-<run-id>
container: compute
```

The selector is narrow: a live inspection found launcher pods labeled `kubevirt.io=virt-launcher` and `vm.kubevirt.io/name=<vm-name>`, with one `compute` container. The inspected launcher ran on CRI-O; its container ID was reported as `cri-o://…`, and its pod had one compute container. The compute process ran as UID/GID 107 (`qemu`), with PID 1 owned by that same user, so the container scenario's in-container signal path is permission-compatible. The inspected pod also had `runAsNonRoot: true`, dropped all capabilities except `NET_BIND_SERVICE`, and `allowPrivilegeEscalation: false`; no host runtime or privileged node mutation is required by the Krkn path.

The current cluster inventory contained multiple CBT runs, so a broad `kubevirt.io=virt-launcher` selector is unsafe and is intentionally not used. The live inventory also included prior CBT-F-01 resources and failed full backups; those are evidence only and must not be targeted by this scenario.

## Chaos injection

### Validated Krkn scenario and command

The exact selector/action invocation, shown here in dry-run form, is:

```bash
krknctl run container-scenarios \
  --namespace "$NAMESPACE" \
  --label-selector "vm.kubevirt.io/name=vm-${NAME}" \
  --container-name compute \
  --action 9 \
  --disruption-count 1 \
  --expected-recovery-time 60 \
  --kubeconfig "$KUBECONFIG_PATH" \
  --krkn-kubeconfig /home/krkn/.kube/config \
  --dry-run
```

The exact command above was dry-run validated remotely with a unique run-derived label; Krkn returned `Scenario schema valid`, `All required fields present`, and `Values validated`. The trigger script passes these same target/action/kubeconfig arguments without `--dry-run` only when the host-local log observer fires. The API query lives on the executing host, not inside the Krkn container: the runner's `oc`/trigger-command environment was not independently validated, so the script does not assume it is available there.

Krkn's authoritative container-scenario documentation says it uses `oc exec` to run `kill` in the selected container, supports a specific container name, and uses the action value as the kill signal. Thus this is a container-level signal rather than a pod delete. Signal 9 is immediate and intentionally terminates the compute process/container. The pod UID and name must still be checked after recovery; if they change, the observed event was a pod replacement and is not evidence of a same-pod container-only disruption.

### Deterministic timing signal

The observer waits for the selected launcher pod's `compute` log to contain the exact live-copy line:

```text
Backup started
```

The observer is armed before `make e2e TYPE=full` and follows `oc logs --follow` only for the run-labeled launcher pod's `compute` container. It accepts the exact `Backup started` line for `vm-backup-${NAME}` only while the backup is not already Done, then invokes Krkn's container-level signal. One-second polling is limited to launcher discovery/reconnection; injection is event-driven and uses no arbitrary sleep or backup-creation/`Progressing=True` substitute.

Read-only triage found no CBT-F-02 backup actively copying, so the transition was not re-observed for this issue. The signal is grounded in the repository's live-copy design boundary and exact launcher log evidence from the active cluster; the actual disruption/recovery remain unvalidated.

## Pass/fail criteria

### Required product pass

- The disruption is recorded after `Backup started` for the selected run and targets `compute` only.
- The launcher pod name and UID before chaos are captured. After recovery, the VM/VMI is Running/Ready and CBT remains `Enabled`.
- The backup request reaches a terminal `Done=True` state whose reason clearly indicates failure (for example, the implementation's `Backup has failed: ...` reason), not a false successful completion. `Done=True` alone is insufficient.
- The failed full request's checkpoint is not accepted as a new valid tracker checkpoint. The pre-chaos tracker checkpoint (normally empty for a first full backup) is unchanged; no failed/partial copy advances tracker state. Preserve the failed backup object and destination PVC for evidence.
- The compute container recovers, and the pod identity remains the same (same pod name and UID) if this is to be classified as container-only recovery. A changed pod UID/name is a failure of the container-only identity hypothesis and must be reported separately, even if the VM eventually recovers.
- After the failed request, a distinct, approved same-VM full-backup request and destination PVC (new names, failed objects preserved) completes successfully, reports `type=Full`, has a non-empty checkpoint, and advances the tracker only to that successful checkpoint. The recovered VM remains CBT-enabled.
- Restore verification from that successful post-chaos full backup reproduces the pre-chaos baseline workload manifest (file set, byte totals, and hashes).

### Fail

- The targeted selector can match more than the selected VM's launcher pod, or any container other than `compute` is disrupted.
- Chaos starts before the `Backup started` log boundary or after the copy has already completed.
- `Done=True` is reported with a non-terminal/success reason for a disrupted copy, or a failed request advances the tracker/checkpoint.
- The compute container does not recover, CBT is not `Enabled`, the VM/VMI does not recover, or the post-chaos restore differs from the baseline.
- The pod UID/name changes and the run is nevertheless reported as proof of a same-pod container-only disruption.
- The post-chaos same-VM backup reuses the failed backup/PVC identity, silently creates a new VM, or is not performed.

### Verification commands

Use the run-specific names and preserve outputs before any cleanup:

```bash
oc get pod -n "$NAMESPACE" -l "vm.kubevirt.io/name=$VM_NAME" -o json
oc get vmi "$VM_NAME" -n "$NAMESPACE" -o json
oc get vm "$VM_NAME" -n "$NAMESPACE" -o json
oc get vmbackup "$FAILED_BACKUP" -n "$NAMESPACE" -o json
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" -o json
oc get pvc "$FAILED_PVC" -n "$NAMESPACE" -o json
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp
oc logs -n "$LAUNCHER_POD" -c compute
```

Compare `.metadata.uid` and `.metadata.name` for the launcher pod before/after; compare compute `.status.containerStatuses[].containerID`, `.ready`, and `.restartCount`; inspect VM `.status.changedBlockTracking.state`; inspect backup `Done` condition, reason, type, checkpoint, and `includedVolumes`; and inspect tracker `.status.latestCheckpoint`. A successful retry must have a distinct backup/PVC identity and a checkpoint distinct from any invalid/failed result. The repository restore verifier is the required data check once a successful post-chaos full backup exists; do not treat PVC Bound, `Done=True`, or a Krkn exit code as restore proof.

## Same-VM recovery limitation in the active workflow

This artifact deliberately marks the same-VM follow-up **BLOCKED in the current automation**. `scripts/vm-backup.sh` derives fixed names from `RUN_ID` and has no backup/PVC override; the failed full request cannot safely be retried by the supported `TYPE=full` command. An approved manual API path would need to render/apply a new uniquely named full-backup PVC, tracker/request relationship appropriate to the existing VM, and then run the restore verifier against that new successful backup while preserving the failed objects. Until that exact API path, storage sizing, permissions, and verifier inputs are approved and implemented, do not claim the same-VM backup/restore criterion is met. A fresh VM lifecycle is supplemental only and cannot replace it.

## Blast radius, recovery, and conflicts

- Intended blast radius is one `compute` container in one run-owned launcher pod; no pod delete, node action, controller action, or unrelated VM operation is allowed.
- The compute container is the VM's launcher/QEMU process, so the guest may pause or lose power and KubeVirt may recreate the VMI/pod. Capture pod/VMI/VM identity and events before relying on logs; preserve the failed backup/PVC and all run evidence.
- Do not run concurrently with another lifecycle in this checkout. The namespace is shared and currently contains other CBT runs; the run-derived VM label is mandatory.
- Do not run `make clean-all`, delete failed resources, run `make resync`, or mutate the live cluster during triage. If remote checkout edits differ from the local scenario, stop before synchronization; the inspected remote checkout already contains unrelated scenario work.
- Recovery is limited to observing KubeVirt's automatic container/VM recovery. Any same-VM retry and restore requires the approved distinct-resource path described above.
- Krkn dry-run and read-only inspections passed; no live CBT-F-02 injection, E2E, or mutation was performed. Therefore product behavior remains unproven by this triage.

# CBT-F-02: Stop only the backup execution container during a full backup

**Jira issue:** CBT-F-02  
**Priority:** P1  
**Technical scenario:** `container-scenarios`  
**Chaos phase:** Active operation

## Objective and hypothesis

During a **full backup**, stop only the `compute` container in the VM's `virt-launcher` pod while the disk copy is active. Determine whether this produces the same safe failure behavior as stopping the whole launcher pod: the full backup must settle as a terminal failure without advancing the checkpoint, while the VM recovers. The test must also distinguish a container restart in the same pod from a pod replacement.

This was the issue's requested action at spec time. The mechanism is now live-validated; see "Live validation result" below — the container-level SIGTERM (the only in-container signal that works; SIGKILL to PID 1 is a kernel no-op) stops the compute container and produces a pod replacement, not a same-pod container restart.
**Issue fields:** Workflow: Full backup. Target/action: signal only the `compute` container in the VM launcher pod. Injection window/signal: while the full backup is actively copying (live libvirt backup job; the launcher's `Backup started` log entry announces the same boundary). Duration: immediate (container-stop signal; issue originally said signal 9 — see the SIGKILL caveat in "Chaos injection"). Expected behavior: clean terminal full-backup failure, unchanged checkpoint, and automatic VM/container recovery. Verification: compare pod identity, backup result/reason, tracker/checkpoint, CBT state, then a distinct same-VM backup and restore. Expected outcome: establish whether container-only interruption is handled like a launcher-pod interruption.

## Workflow actually supported

Use separate, unique values for the chaos artifact `RUN_ID` and the lifecycle `NAME`:

```bash
RUN_ID=<unique-chaos-artifact-id> NAME=<unique-lifecycle-name> \
  NAMESPACE=<workflow-namespace> KUBECONFIG_PATH=<approved-host-local-path> \
  bash cbt-chaos/scenarios_v2/CBT-F-02/chaos-trigger.sh
```

The active `chaos-trigger.sh` starts the supported full-only lifecycle
(`make e2e TYPE=full NAME=<name>`) and arms krknctl container-scenarios with
event-driven triggers in parallel; Krkn performs the disruption only inside
the active-copy window. The chaos artifact is stored under
`runs/<RUN_ID>/` (action request/result, krkn log, e2e log, post-evidence);
cluster resources are derived from `NAME` (for example, `vm-<NAME>` and
`vm-backup-<NAME>`). Do not reuse either identifier.

The CBT-F-02 workload uses the standard RHEL 9 profile (`VM_OS=rhel9`,
`MANIFEST_VARIANT=large-odf`) with the normal baseline defaults: 8 files,
each 4–12 MiB (55 MiB total for the deterministic default assignment). The
copy window is not inferred from payload size; the trigger detects the live
libvirt backup job directly.

The expected terminal state of the interrupted run: e2e exits nonzero (the
failed full backup is detected by `vm-backup.sh`), krkn exits 0 (container
recovered within `expected-recovery-time`), tracker latestCheckpoint remains
empty, and the failed backup object and destination PVC are retained as
evidence. The supported same-VM recovery stage (`make e2e TYPE=recover
VM=vm-<NAME>`) then proves recovery with a distinct backup/PVC name; it is
separate from the interrupted `TYPE=full` stage.

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

### Active mechanism: krknctl container-scenarios with event-driven triggers

The active `chaos-trigger.sh` delegates both the window detection and the
disruption to Krkn itself through `krknctl run container-scenarios` (validated
live on cloud05, OCP 4.22.15 / KubeVirt, 2026-10-10):

```bash
krknctl run container-scenarios \
  --kubeconfig <host-local kubeconfig copy> \
  --namespace "$NAMESPACE" \
  --label-selector "vm.kubevirt.io/name=vm-${NAME}" \
  --container-name compute \
  --action 1 \
  --disruption-count 1 \
  --expected-recovery-time 300 \
  --trigger-command '<oc exec ... virsh backup-dumpxml poll>' \
  --trigger-expected-rc 0 \
  --triggers-timeout 3600 \
  --triggers-interval 3 \
  --triggers-on-timeout fail
```

Krkn's trigger manager polls this command every 3 seconds; chaos begins only
after it is satisfied, and `on-timeout=fail` guarantees no out-of-window
injection. The trigger command runs inside the krkn-hub container with the
mounted kubeconfig: it resolves the run's launcher pod by the run-scoped label
and runs `virsh backup-dumpxml <namespace>_<vm-name>` in the `compute`
container. That call exits 0 only while a libvirt backup job is actively
running — the same boundary the launcher's `Backup started` log line
announces — and exits nonzero before the copy starts and after it ends, so
the disruption lands inside the live-copy window by construction.

The `--action 1` (SIGTERM) is deliberate and load-bearing:

- Krkn's container kill is `pod exec ... bash -c "kill <action>"` in the
  target container, i.e. a signal to PID 1 (`virt-launcher-monitor`) from
  inside the PID namespace.
- The Linux kernel silently discards `kill -9 1` from inside a PID namespace
  even when SIGKILL is unblocked: the call returns success but the init
  process is unaffected. This is why every prior CBT-F-02 attempt
  (`oc exec ... kill -9 1`, and krkn `--action 9`) recorded a successful
  action request while the compute container kept running and the backup
  completed normally (BLOCKED verdicts).
- SIGTERM is *not* filtered for PID 1: `virt-launcher-monitor` traps it,
  gracefully stops QEMU/libvirt, CRI-O terminates the `compute` container,
  and KubeVirt replaces the launcher pod. Live-validated: kill delivered
  45ms after the trigger satisfied, backup terminal failure ~14s later,
  replacement pod Running ~19s after the kill, VM CBT back to Enabled.

The e2e lifecycle (`make e2e TYPE=full NAME=<name>`) runs in parallel and is
expected to exit nonzero: `vm-backup.sh` detects `Done=True` with the
terminal failure reason `Backup has failed: VMI backup status was lost` and
fails loudly. A zero e2e exit with krkn exit 0 means the disruption was not
effective and the run is INVALID, not a pass.

Historical note: the earlier direct `oc exec ... kill -9 1` trigger and the
krkn-native-v1 script (both removed from this directory) are superseded; the
in-container SIGKILL no-op documented above is the root cause of their
BLOCKED outcomes.

### Live validation result (2026-10-10, run 20261010-cbtf02-v2)

| Check | Observed |
|---|---|
| Trigger satisfied (active backup job) | 14:29:46.515Z |
| Compute container killed (krkn) | 14:29:46.560Z (45ms later) |
| Backup terminal failure | `Done=True` / `Progressing=False`, reason `Backup has failed: VMI backup status was lost` at 14:30:00Z |
| Tracker latestCheckpoint | EMPTY (unchanged; failed backup advanced nothing) |
| Launcher pod | `45smj` (killed) replaced by `mnr5m`, new UID, compute ready |
| VM/VMI after recovery | Running, CBT `Enabled` |
| Same-VM recovery (`make e2e TYPE=recover`) | PASS: forced Full backup verified, baseline restore file set/bytes/hashes match |
| e2e TYPE=full exit | 2 (expected failure path exercised) |
| krkn exit | 0 (scenario PASS, container recovered within expected-recovery-time) |


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

## Same-VM recovery path

After preserving the interrupted full backup, tracker/checkpoint, and destination PVC evidence, use the supported recovery stage against the same managed VM. It checks that the VM/VMI are Ready/Running, CBT is Enabled, the failed full and PVC are retained, the live `forceFullBackup` API schema is supported, and new recovery backup/PVC names are unused. It then creates a distinct full-backup PVC and `VirtualMachineBackup` request against the existing tracker with `forceFullBackup: true`, verifies the new checkpoint/tracker state, and restores the saved baseline workload. If any precondition fails, the recovery is BLOCKED before creating recovery resources; do not improvise an API object or use a new VM as a substitute.

## Blast radius, recovery, and conflicts

- Intended blast radius is one `compute` container in one run-owned launcher pod; no pod delete, node action, controller action, or unrelated VM operation is allowed.
- The compute container is the VM's launcher/QEMU process, so the guest may pause or lose power and KubeVirt may recreate the VMI/pod. Capture pod/VMI/VM identity and events before relying on logs; preserve the failed backup/PVC and all run evidence.
- Do not run concurrently with another lifecycle in this checkout. The namespace is shared; the run-derived VM label and one-target cardinality check are mandatory.
- Before execution, inspect remote target files for edits, synchronize the validated local checkout once, and verify the active trigger matches. Never run `make clean-all`, delete failed resources, or synchronize after the run begins.
- Recovery includes KubeVirt's automatic container/VM recovery and the distinct same-VM full-backup/restore stage described above. A fresh VM lifecycle, if separately run, is supplemental only.
- Historical triage note: prior read-only validation and Krkn dry-run did not perform a live CBT-F-02 injection or E2E; product behavior remained unproven at that time.

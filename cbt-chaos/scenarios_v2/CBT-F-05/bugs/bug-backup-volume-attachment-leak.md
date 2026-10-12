# [Bug]: Backup destination volume stays attached to the VM's node after a virt-handler restart during a full backup, blocking any reader on another node

> Jira-ready draft. Choose **Bug** only for a demonstrated violation of an established contract; choose **Improvement** for an ambiguous contract or requested behavior. Keep CBT product and test-harness issues in separate tickets. Do not invent a Jira key, claim submission, or mark an unproven cause as fact.

| Field | Value |
|---|---|
| Issue type | Bug |
| Owning component | CBT backup hotplug/volume-attachment cleanup path (virt-handler driven) |
| Priority | Proposed High — blocks restore/verification workflows after the disruption; not data corruption. Scenario priority was P1. |
| Status / confidence | Confirmed behavior on two independent runs (RHEL 9 and Windows Server 2022 guests); the defect classification (missing detach vs. legitimate long-lived attachment) is high confidence but the root cause inside the cleanup path is unproven. |
| Related scenario / execution | CBT-F-05 (restart node backup handler during full backup); runs `20261011064508-fuzzy-wolf-6cb9` (RHEL 9) and `20261011-win-f05-r01` (Windows), both 2026-10-11 UTC. |
| Affected versions | OpenShift 4.22.15; OpenShift Virtualization 4.22.12 (kubevirt-hyperconverged-operator.v4.22.12); ODF Ceph RBD (Block for VM disks, Filesystem for backup volumes); guest OS RHEL 9 and Windows Server 2022; oc client not recorded. |

## Description (plain language)
When a `virt-handler` pod is deleted while a full CBT backup is actively copying, the backup itself completes correctly, but the backup destination volume's hotplug cleanup on the VM fails. The volume's node attachment is then never released after the backup completes: the persistent volume stays attached to the node running the source VM indefinitely. Because the volume is RWO (single-node attach), any pod scheduled on a different node that needs to read the backup — for example a restore/verification pod — fails with a Multi-Attach error and cannot start. In both observed runs this blocked data-level restore verification for the full 30-minute wait window.
## Background: how a CBT backup uses storage (for readers new to storage plugins)

Actors:

- **KubeVirt controller** — the control-plane "brain"; creates the `VirtualMachineBackup` object and the backup PVC.
- **`virt-handler`** — KubeVirt's per-node agent (DaemonSet pod on every worker node). It plugs/unplugs disks into the VM and talks to libvirt/QEMU. *This is the pod our chaos scenario deletes.*
- **CSI storage driver** (here ODF/Ceph RBD) — the only component that can physically attach/detach a disk to a server. KubeVirt requests; CSI performs.
- **`VolumeAttachment`** — a Kubernetes record meaning "disk X is currently plugged into server Y". While it exists, no other server may attach the same disk.
- **Backup PVC (RWO)** — the empty disk the backup is written to. `ReadWriteOnce` = attachable to exactly one node at a time.
- **Hotplug** — plugging the backup PVC into the *running* VM so QEMU can copy the disk to it; after the copy it must be unplugged (cleanup/detach).

### Happy flow (no disruption)

```
 STEP 1  Controller creates Backup CR + empty backup PVC
            |
 STEP 2  Controller asks virt-handler (Node A) to hotplug the volume
            |
         virt-handler -> CSI driver attaches disk to Node A
            |
         VolumeAttachment{backupPVC, node=A, attached=true}   <- record created
            |
 STEP 3  QEMU copies VM disk -> backup PVC   ("Backup started" ... copy ... done)
            |
 STEP 4  Backup Done=True; virt-handler unplugs the volume;
         CSI driver detaches; VolumeAttachment DELETED          <- record removed
            |
 STEP 5  Volume is FREE: any pod on ANY node can mount the backup PVC
         (restore, verify, export).                             <- the invariant
```

### Buggy flow (virt-handler restarted during STEP 3)

```
 STEP 3'  virt-handler on Node A is deleted mid-copy (replacement starts ~20s later)
            |
 STEP 4'  Backup finishes (Done=True). Replacement handler attempts the unplug:
            |    HotplugFailed: "failed to mount filesystem hotplug volume"
            |    SyncFailed:    "failed to remove hotplug disk directory"
            |
         The cleanup is one-shot and is NOT retried; nothing asks CSI to detach.
            |
         VolumeAttachment{backupPVC, node=A, attached=true}    <- STAYS FOREVER
            |
 STEP 5'  Node A holds the disk; RWO forbids a second node:

            Node A                          Node B
         +--------------------+       +--------------------------+
         | VM (running)       |       | restore/verify pod       |
         | backup PVC stuck   |       | "I need to READ backup"  |
         | plugged here       |       +------------+-------------+
         +---------+----------+                    |
                   |        RWO = one node         |
                   +-------------- X --------------+
                            Multi-Attach error
         "Volume is already exclusively attached to one node
          and can't be attached to another"
         Verify pod: Pending ... (30 min) ... timeout
```

Why it persists: no component owns a retry. The handler's cleanup attempt failed once, the Backup CR is already terminal/successful, so from the controller's perspective nothing remains to reconcile — the leaked `VolumeAttachment` is invisible to the backup's own status.

What this is NOT: it is not data corruption (backup data intact, `Done=True`, correct checkpoint), and not a backup failure (full and incremental both succeeded after the disruption). It is a leaked storage attachment that blocks any *reader* of the backup volume from another node.

## Steps to reproduce

> Dedicated cluster, new run-scoped names. Prerequisites: OpenShift Virtualization with the CBT backup API enabled; ODF storage classes; a CBT-enabled VM with a guest workload large enough to yield an observable copy window (e.g. 8 files × 1 GiB). Identify the exact target before injecting: resolve the VM's VMI `status.nodeName`, then the single `virt-handler` pod on that node (label `kubevirt.io=virt-handler` plus `spec.nodeName` field selector).

1. Start a full `VirtualMachineBackup` of the CBT VM to a dedicated destination PVC (run-scoped name).
2. Wait for the active-copy signal: the VM's launcher compute-container log line containing the exact backup name and `"msg":"Backup started"`. Backup CR creation alone is not proof of active copying.
3. While the backup is nonterminal, delete the exact node-local handler pod:
   `oc delete pod <virt-handler-pod> -n openshift-cnv --wait=false`
4. Let the backup reach its terminal state (observed: `Done=True`).
5. Read-only inspection of the stuck attachment:
   - `oc get volumeattachment -o json | jq '.items[] | select(.spec.source.persistentVolumeName == "<backup PV name>") | {name: .metadata.name, node: .spec.nodeName, attached: .status.attached}'` — shows `attached: true` on the VM's node, with no detach.
   - `oc get events -n <vm-namespace> --field-selector involvedObject.name=<vm-name>` — shows `HotplugFailed` and `SyncFailed: failed to remove hotplug disk directory` at the backup's completion time.
   - Schedule any pod on a different node mounting that backup PVC — it stays Pending with `FailedAttachVolume` Multi-Attach.

## Actual result


- Windows run `20261011-win-f05-r01`: active-copy signal 13:40:18.303Z; handler `virt-handler-jg4pg` (UID d0cf7d37-43d9-4fd3-8239-c1bd009eec75) deleted on node d38-h18-000-r660 (API deletion timestamp 13:40:31Z); full backup `vm-backup-20261011-win-f05-r01` `Done=True`, reason "Successfully completed VirtualMachineBackup" at 13:40:52Z; at that same second, events `HotplugFailed` ("failed to mount filesystem hotplug volume … lstat /proc/1/root") and `SyncFailed` ("failed to remove hotplug disk directory") were emitted for the backup-target volume. The full PVC's PV (`pvc-01522b2e-bd7a-445a-b674-06037de2e969`) remained `attached: true` on the VM's node via volumeattachment `csi-1dbaa20e…` (verified live after the run). The restore-verification pod (scheduled on node d38-h19-000-r660) stayed Pending on Multi-Attach for the full 1800 s timeout (13:43:16Z–14:15:32Z); no restore result was produced.
- RHEL 9 run `20261011064508-fuzzy-wolf-6cb9`: same scenario; hotplug cleanup failed at backup completion (`HotplugFailed`, `SyncFailed` at 06:55:19Z); the storage attacher logged "already attached" every ~10 minutes with no detach ever requested; the backup volume's attachment was the only leaked backup-volume attachment on the cluster; restore verification blocked the same way for the full window.

### Side-by-side comparison of the two runs

| | RHEL 9 run | Windows run |
|---|---|---|
| Run label | 20261011064508-fuzzy-wolf-6cb9 | 20261011-win-f05-r01 |
| Guest OS | RHEL 9 | Windows Server 2022 |
| Cleanup failure time (UTC) | 06:55:19Z | 13:40:52Z |
| Backup outcome | Done=True, Full, checkpoint OK | Done=True, Full, checkpoint OK |
| HotplugFailed / SyncFailed events | Present | Present |
| VolumeAttachment after completion | attached=true, no detach ever requested (attacher logged "already attached" every ~10 min) | attached=true, verified live post-run |
| Restore verification | Blocked, 30-min timeout | Blocked, 30-min timeout |

Identical failure signature across two guest OSes on the same cluster/build → the defect is in the hotplug-cleanup path, not guest-OS-specific.

The backup, checkpoint, tracker, CBT state, and same-VM incremental follow-up were correct in both runs. All identity/timing observations above were captured by an authenticated, run-scoped read-only watcher plus the API objects, not only by the workflow's own exit status.

## Expected result / requested outcome

After a `VirtualMachineBackup` reaches a terminal state (success or failure), the hotplugged backup destination volume's node attachment should be released (detached), even when the handler pod that manages the hotplug was restarted during the backup. Cleanup failure during the copy should be retried or reconciled by the controller rather than silently abandoned.

Acceptance will be checked by: after a handler restart mid-full-backup and the backup's terminal completion, `oc get volumeattachment` for the backup PV shows no lingering `attached: true` entry on the VM's node (within a bounded reconciliation window), and a pod on a different node can mount the backup PVC and read the backup image.

## Impact and workaround

- Consumer risk: any consumer or automation that reads the backup volume from another node (restore, verification, copy to external storage) is blocked after this disruption pattern. The backup data itself appears intact and the backup CR reports success.
- Frequency/reproducibility: reproduced 2/2 across two guest OSes on the same cluster/build; the trigger condition (handler pod deletion during active copy) is a narrow chaos/maintenance window, not routine operation.
- Blast radius: the affected volume only; other backups on the cluster were unaffected (the RHEL 9 run confirmed it was the only leaked attachment cluster-wide at that time).
- Workaround: none validated. Candidate mitigations (untested): schedule the reader pod on the node holding the attachment, or force the volumeattachment removal. Manual volumeattachment deletion is risky and was not attempted.
- Unknowns: whether the attachment is retained deliberately while the source VM runs, or is simply orphaned by the failed hotplug cleanup; the exact code path that skips the detach.

## Additional information and evidence

- Windows run: `HotplugFailed` / `SyncFailed` events at 2026-10-11T13:40:52Z on the full backup's target volume; volumeattachment `csi-1dbaa20e1c8daff5370ddb1a4303628e25a7bb9fc8c48d6eda2809456fe84559` → PV `pvc-01522b2e-bd7a-445a-b674-06037de2e969`, `attached: true`, node d38-h18-000-r660; restore-verifier events `FailedAttachVolume` Multi-Attach 13:43:16Z, `SuccessfulAttachVolume` for the incremental's volume 13:43:24Z (only the full's volume was stuck). Evidence: `cbt-chaos/scenarios_v2/CBT-F-05/runs/20261011-win-f05-r01/observer/events.jsonl`, `restore-verifier-events.json`, and the run's detailed report.
- RHEL 9 run: identical event signature at 06:55:19Z; storage-attacher "already attached" logs with no detach; only leaked backup-volume attachment on the cluster. Evidence: `cbt-chaos/scenarios_v2/CBT-F-05/runs/20261011064508-fuzzy-wolf-6cb9/test-run-report.md` and run artifacts.
- Contradictory/limiting evidence: in both runs the workflow's restore step failing is expected *given* the stuck attachment; the backup CRs themselves were successful, so this is not a backup-failure bug. Restore/data correctness of the stuck volumes could not be verified (that is the impact). qcow2 metadata was not inspected. Event timestamps are second-granularity.
- Both runs' findings were independently observed by a read-only monitor with authenticated watches; the injection windows were confirmed by the exact backup's "Backup started" log signal, the API deletion timestamp, and the terminal transition times.

## Acceptance criteria

- After a full backup that experienced a virt-handler restart during active copy reaches a terminal state, the backup destination volume's node attachment is released within a bounded, documented reconciliation window.
- A regression test covering the original failure mode: handler deletion during active full copy, backup completes, then a reader pod on a *different* node successfully mounts the backup PVC and reads the backup image.
- No regression for the normal path: handler not disrupted → attachment already released today must remain released.

## Triage questions

- Is a lingering backup-volume attachment while the source VM runs an intentional contract (e.g. for follow-up incrementals) or orphaned state? If intentional, the contract needs a documented release condition.
- Should the hotplug cleanup failure (`SyncFailed: failed to remove hotplug disk directory`) be retried by the controller, or should a terminal backup trigger an independent detach reconciliation?
- Is the `HotplugFailed`/`SyncFailed` at backup-completion time causally tied to the earlier handler restart, or is it an independent cleanup race that also occurs without disruption?

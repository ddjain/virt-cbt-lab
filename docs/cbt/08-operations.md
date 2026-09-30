# 08. Operations and troubleshooting

## Run the supported workflow

```sh
make preflight
make e2e
```

Run one workflow sequence at a time per checkout. The Kubernetes resources have run-derived names, but `state/run-id`, `state/report-id`, and guest hashes are shared local files.

## Observe a run

```sh
oc get vm,vmi,dv,pvc,svc,vmbackup,vmbackuptracker -n "$NAMESPACE"
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp
oc get pvc -n "$NAMESPACE" -o wide
oc get pv -o wide
```

Find the launcher and inspect the backup code path:

```sh
oc get pod -n "$NAMESPACE" -l vm.kubevirt.io/name="$VM_NAME"
oc logs -n "$NAMESPACE" <virt-launcher-pod> -c compute
```

Measure API-recorded backup duration, not wall-clock guesses:

```sh
make monitor VM="$VM_NAME"
```

`monitor.sh` uses Bash associative arrays and therefore requires Bash 4 or newer. Core setup/backup scripts use Bash features available in Bash 3.2, but macOS's system Bash cannot run the monitor unchanged.

## Status checks

```sh
oc get vmbackup -n "$NAMESPACE" -o yaml
oc get vmbackuptracker -n "$NAMESPACE" -o yaml
oc get vm "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.changedBlockTracking.state}{"\n"}'
```

For a valid incremental result, check all of:

- VM CBT state is `Enabled`;
- full backup type is `Full` and `Done=True`;
- incremental backup type is `Incremental` and `Done=True`;
- both checkpoint names are present and different;
- tracker latest checkpoint equals the incremental checkpoint;
- the Done reason is not a terminal `Backup has failed...` reason;
- restore hashes and marker checks pass.

## Deep inspection for CBT and chaos tests

Inspect the tracker recovery flag and the actual libvirt checkpoint tree:

```sh
oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.checkpointRedefinitionRequired}{"\n"}'
LAUNCHER_POD="$(oc get pod -n "$NAMESPACE" \
  -l "vm.kubevirt.io/name=$VM_NAME" -o jsonpath='{.items[0].metadata.name}')"
DOMAIN="${NAMESPACE}_${VM_NAME}"
oc exec -n "$NAMESPACE" "$LAUNCHER_POD" -c compute -- \
  virsh checkpoint-list "$DOMAIN" --tree
```

The expected tree after one full and one incremental backup is one full checkpoint with one incremental child. Compare the tree to the CR `checkpointName` values and tracker `latestCheckpoint.name`.

For artifact-level inspection, run `qemu-img info` and `qemu-img map --output=json` from the restore-helper pod against the mounted qcow2 files. The current automated verifier does not assert backing-file metadata or allocation maps; add those observations to a chaos report when the claim is “CBT produced a delta,” not merely “the restored guest data is correct.”

## Read the relevant installed API contract

```sh
oc explain virtualmachinebackup.spec --recursive
oc explain virtualmachinebackup.status --recursive
oc explain virtualmachinebackuptracker.status --recursive
oc get kubevirt -n openshift-cnv -o yaml
oc get crd virtualmachinebackups.backup.kubevirt.io -o yaml
```

For a live copy, use the launcher log line `Backup started` as the trigger boundary. CR creation includes PVC binding and hotplug setup; it is not the start of QEMU block-copy. Use the specific backup name when matching logs.

## Live-cluster storage and network checks

```sh
oc get storageclass cbt-demo-hpp -o yaml
oc get hostpathprovisioner cbt-demo-hpp -o yaml
oc get pvc -n "$NAMESPACE" -o wide
oc get pv -o wide
oc get network.config.openshift.io cluster -o yaml
oc get vmi "$VM_NAME" -n "$NAMESPACE" -o yaml
```

The cloud05 audit observed HPP's pool and all CBT PVCs on one node. A `Pending` PVC can therefore be a first-consumer/scheduling problem even when total reported PV capacity looks large.

Cloud05 produced both `VirtualMachineBackupCompletedSuccessfully` and `VirtualMachineBackupFailed: Backup has failed: VMI backup status was lost` events for some runs, while the final object state was successful in other cases. This is why the scripts inspect terminal conditions and reasons and then restore data. When investigating a failure, preserve the object YAML and event timeline before cleanup; an event alone cannot establish final artifact correctness.

## Reports

Each workflow creates `report/run_<UTC timestamp>/` with:

- stage JSON fragments;
- merged `report.json`;
- `virt-launcher` log, when available;
- restore-verification pod log, when available.

```sh
jq . report/run_*/report.json
```

`state/` is transient workflow state. `report/` intentionally survives `make clean-all`.

## Common symptoms

| Symptom | First checks |
|---|---|
| Golden image import stuck | `oc get dv debian-golden -n vm-cbt-images`; CDI importer logs; HTTPS egress |
| Root or backup PVC Pending | `oc get events`; HPP CSI/pool pods; storage pool capacity; node affinity |
| CBT is not Enabled | `IncrementalBackup` gate, VM `cbt-demo=enabled` label, KubeVirt selector configuration |
| Guest SSH retries | VM/VMI Ready/Running, Service endpoints, cloud-init/sshd, guest key |
| Freeze warning | VMI `AgentConnected`, virt-launcher guest-agent logs, backup Done reason |
| Incremental type is wrong | tracker latest checkpoint, full backup terminal state, backup conditions |
| Hotplug warning | attachment pod events, `VolumeMountedToPod`, final backup status |
| Restore pod rejected | helper image, privileged permission, host `/dev` policy, PVC scheduling |
| Hash mismatch | report/run mixing, concurrent checkout use, stale state files, actual restore pod log |

Do not classify a backup from a transient warning event alone. Compare settled status, reason, checkpoint, destination artifact, and restored data.
## Source-aware diagnosis

Use the [v1.8.4 source reference](12-kubevirt-source-reference.md) when classifying a signal. The controller uses rate-limited queues and finalizers; the launcher has backup-name/start-time idempotency checks; tracker redefinition distinguishes retryable `503` from invalid-checkpoint `422`; and `Done=True` can carry a failure reason. These implementation details explain why events, status, and artifacts must be captured together.

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

# Scenario: 04-vmi-restart-between-backups

**QE Chaos Matrix ref:** row #4 in `cclm-chaos/chaos-plan.md` §G (Priority: P0)

## 1. Title
Restart the VMI between full completion and incremental start to test `checkpointRedefinitionRequired`.

## 2. Description
Targets the `vm-cbt-demo` VMI between full-backup completion and incremental-backup start, before the
guest mutation step (`chaos-plan.md` §E injection point 3). Tests the virt-handler-owned
`checkpointRedefinitionRequired` recovery path (`chaos-plan.md` §D, "Checkpoint redefinition after VMI
restart") — the single highest-value untested question this investigation surfaced (`chaos-plan.md` §H
concrete false positives table).

## 3. Chaos Injection

**Primary (krknctl):**

Validated against `krknctl describe kubevirt-outage` / `krknctl run kubevirt-outage --help` (real
scenario tag is `kubevirt-outage`, not `kubevirt_vm_outage`; there is no `--disable-auto-restart` flag —
the confirmed flags are `--namespace` (required), `--vm-name`, `--label-selector`, `--timeout`,
`--kill-count`). Live VM/VMI confirmed on <target-host>: `virtualmachine.kubevirt.io/vm-cbt-demo` /
`virtualmachineinstance.kubevirt.io/vm-cbt-demo` in namespace `vm-cbt-demo`, `runStrategy` causes
auto-recreation on delete (observed `Running`/`Ready=True` state).

```bash
krknctl run kubevirt-outage \
  --namespace vm-cbt-demo \
  --vm-name vm-cbt-demo \
  --kill-count 1 \
  --kubeconfig /path/to/cluster/kubeconfig
```

**Secondary (oc, only if krknctl cannot do this):**
```
# Not needed — kubevirt-outage covers VMI deletion/restart directly.
```

> `--kubeconfig` must point at `/path/to/cluster/kubeconfig` on <target-host>; `krknctl` is not installed on <target-host>
> itself (confirmed), so run this from a host with `krknctl` and a securely-transferred kubeconfig copy,
> or install `krknctl` on <target-host> directly.

> krknctl is first priority. Fall back to `oc` only when documented and justified above.

## 4. Injection Timing

**Deterministic condition:** `VirtualMachineBackupTracker.status.latestCheckpoint.name` equals the full
backup's checkpoint name, and no incremental `VirtualMachineBackup` CR exists yet.

**How we watch for it:** no krknctl `--trigger` mechanism exists (confirmed, see scenario 01 §4).
`chaos-trigger.sh` polls `oc get vmbackuptracker hello-tracker -n vm-cbt-demo -o
jsonpath='{.status.latestCheckpoint.name}'` until it matches the known full-backup checkpoint name and
confirms no incremental `VirtualMachineBackup` object exists yet, then fires the `krknctl run
kubevirt_vm_outage` command from §3.

## 5. Expected Behavior / Pass-Fail Criteria

**Pass:**
- After restart, the subsequent incremental backup still reports `type=Incremental`.
- Artifact is still delta-sized (not full-copy-sized).
- `virsh checkpoint-list --tree` still shows the expected parent→child relationship.
- Tier-B restore test still matches expected hashes.

**Fail:**
- Incremental backup silently degrades to a full-sized copy while still labeled `Incremental`.
- `virsh checkpoint-list --tree` shows a broken chain or the tracker references a checkpoint that no
  longer exists in libvirt.

**Verification commands:** `oc get vmbackuptracker -o yaml` (`checkpointRedefinitionRequired` field),
`virsh checkpoint-list --tree`, `qemu-img info`/`qemu-img map` on the incremental artifact for
backing-file/cluster-count comparison, Tier-B restore test per `chaos-plan.md` §H.

## 6. Special Notes
Deliberately restart between backups, not during a copy, to isolate the checkpoint-redefinition
question from the copy-interruption question tested in scenario 01. This is marked UNKNOWN in
`chaos-plan.md` — SOURCE only documents that virt-handler *should* redefine the checkpoint; whether it
actually does so correctly under this scenario is what this test answers.

## 7. Reproducibility

All commands from §3 and the watch logic from §4 must be captured in
`cclm-chaos/scenarios/04-vmi-restart-between-backups/chaos-trigger.sh` so the scenario can be re-run
identically in the future. This spec describes intent; the script is the executable source of truth for
the exact invocation.

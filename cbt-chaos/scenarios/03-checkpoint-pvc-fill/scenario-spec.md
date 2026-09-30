# Scenario: 03-checkpoint-pvc-fill

**QE Chaos Matrix ref:** row #3 in `cbt-chaos/chaos-plan.md` §G (Priority: P0)

## 1. Title
Fill/stress the CBT checkpoint-bearing persistent-state PVC to test checkpoint-chain integrity.

## 2. Description
Targets `persistent-state-for-vm-cbt-demo-*` — the dedicated per-VMI PVC holding the qcow2 overlay with
the actual libvirt dirty-bitmap/checkpoint chain, distinct from both the root-disk PVC and the
backup-destination PVCs (`chaos-plan.md` §A.1, "Correction of a prior assumption"). This PVC was not
identified in the prior 2026-09-29 plan and is the highest-novelty untested failure boundary in
`chaos-plan.md` §D ("CBT checkpoint persistence").

## 3. Chaos Injection

**Primary (krknctl):**

Validated against `krknctl describe pvc-scenarios` / `krknctl run pvc-scenarios --help` (real scenario
tag is `pvc-scenarios`. `chaos-trigger.sh` resolves the checkpoint PVC from the
target virt-launcher pod's `persistent-state-for-*` volume, so the generated suffix
is never hardcoded.
The target backup is selected with `TARGET_BACKUP=full|incremental`.

```bash
krknctl run pvc-scenarios \
  --namespace vm-cbt-demo \
  --pvc-name <resolved-checkpoint-pvc> \
  --fill-percentage 95 \
  --duration 60 \
  --kubeconfig /path/to/cluster/kubeconfig
```

**Secondary (oc, only if krknctl cannot do this):**
```
# Not needed — pvc-scenarios covers PVC fill directly regardless of which PVC is targeted.
```

> `--kubeconfig` must point at `/path/to/cluster/kubeconfig` on <target-host>; `krknctl` is not installed on <target-host>
> itself (confirmed), so run this from a host with `krknctl` and a securely-transferred kubeconfig copy,
> or install `krknctl` on <target-host> directly.

> krknctl is first priority. Fall back to `oc` only when documented and justified above.

## 4. Injection Timing

**Deterministic condition:** `VirtualMachineBackup` created and
`conditions[?(@.type=="Progressing")].status==True`, i.e. a checkpoint write is in flight.

**How we watch for it:** `chaos-trigger.sh` resolves the current checkpoint PVC
before starting krknctl, then uses krknctl's native `--trigger-command` to wait for
the target backup's `Progressing=True` condition. Timeout behavior is `fail`, not
silent skip.

## 5. Expected Behavior / Pass-Fail Criteria

**Pass:**
- `virsh checkpoint-list --tree` before/after shows the checkpoint chain remains intact and consistent
  with the `VirtualMachineBackupTracker.status.latestCheckpoint`.
- Any checkpoint-write failure surfaces as a terminal non-`Done` condition, not a silently accepted
  `Done=True`.

**Fail:**
- `Done=True` is reported while `virsh checkpoint-list --tree` shows a broken/missing parent-child
  relationship, or the tracker's `latestCheckpoint` no longer matches the real libvirt checkpoint tree.

**Verification commands:** `virsh checkpoint-list <domain> --tree` (via `oc exec` into virt-launcher,
read-only) before and after; `oc get vmbackuptracker -o yaml`; Tier-B restore test per `chaos-plan.md`
§H — also explicitly compare pre/post `virsh checkpoint-list` tree structure, not just backup CR status.

## 6. Special Notes
UNKNOWN outcome — no prior evidence either way (`chaos-plan.md` §H concrete false positives table).
Verify with `virsh checkpoint-list --tree` before/after, not just the backup CR status, since the CR
could report success while the checkpoint tree itself is corrupted.

## 7. Reproducibility

All commands from §3 and the watch logic from §4 must be captured in
`cbt-chaos/scenarios/03-checkpoint-pvc-fill/chaos-trigger.sh` so the scenario can be re-run identically
in the future. This spec describes intent; the script is the executable source of truth for the exact
invocation.

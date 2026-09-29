# Scenario: 03-checkpoint-pvc-fill

**QE Chaos Matrix ref:** row #3 in `cclm-chaos/chaos-plan.md` §G (Priority: P0)

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
tag is `pvc-scenarios`). Live PVC name observed on <target-host>: `persistent-state-for-vm-cbt-demo-mcp88`
(`1489Gi`, `cbt-demo-hpp` StorageClass, `Bound`) — **the `-mcp88` hash suffix is generated per VMI
create/restart and must be re-resolved before each run**, e.g.:
```bash
oc get pvc -n vm-cbt-demo -o name | grep persistent-state-for-vm-cbt-demo
```

```bash
krknctl run pvc-scenarios \
  --namespace vm-cbt-demo \
  --pvc-name persistent-state-for-vm-cbt-demo-mcp88 \
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

**How we watch for it:** no krknctl `--trigger` mechanism exists (confirmed, see scenario 01 §4).
`chaos-trigger.sh` polls `oc get vmbackup <name> -n vm-cbt-demo -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}'`
until it reads `True`, then fires the `krknctl run pvc_scenarios` command from §3.

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
`cclm-chaos/scenarios/03-checkpoint-pvc-fill/chaos-trigger.sh` so the scenario can be re-run identically
in the future. This spec describes intent; the script is the executable source of truth for the exact
invocation.

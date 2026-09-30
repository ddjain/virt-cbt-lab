# Scenario: 05-virt-controller-pod-kill-post-done

**QE Chaos Matrix ref:** row #5 in `cbt-chaos/chaos-plan.md` §G (Priority: P1)

## 1. Title
Kill a virt-controller replica immediately after `Done=True` to test the reconcile-duplicate-call race
under leader failover.

## 2. Description
Targets a virt-controller replica in `openshift-cnv` immediately after a `VirtualMachineBackup` first
reaches `Done=True` (`chaos-plan.md` §E injection point 4). `chaos-plan.md` §C already observed a benign
`resourceVersion`-conflict duplicate-begin-call race, masked only by virt-launcher's own idempotency
guard (backup name + start time + `completed:true`). This scenario stresses that same guard under a
harder failure (replica kill / leader failover) to see if a stale-view retry can produce a second,
conflicting checkpoint for the same name.

## 3. Chaos Injection

**Primary (krknctl):**

Validated against `krknctl describe pod-scenarios` / `krknctl run pod-scenarios --help` (real scenario
tag is `pod-scenarios`; the pod-selector flag is `--pod-label`, not `--label-selector` — `pod-scenarios`
does have a separate `--node-label-selector` for targeting by node, which is not what we want here).
Confirmed live on <target-host>: two `virt-controller` replicas in `openshift-cnv`, both labeled
`kubevirt.io=virt-controller` (`virt-controller-6447f6bcff-67f5m`, `virt-controller-6447f6bcff-rnlc9`).

```bash
krknctl run pod-scenarios \
  --namespace openshift-cnv \
  --pod-label kubevirt.io=virt-controller \
  --disruption-count 1 \
  --kubeconfig /path/to/cluster/kubeconfig
```

**Secondary (oc, only if krknctl cannot do this):**
```
# Not needed — pod-scenarios covers a direct pod kill and supports label-based pod selection.
```

> `--namespace` defaults to the regex `openshift-.*`, which happens to match `openshift-cnv`, but pass it
> explicitly for clarity/reproducibility. `--kubeconfig` must point at `/path/to/cluster/kubeconfig` on <target-host>;
> `krknctl` is not installed on <target-host> itself (confirmed), so run this from a host with `krknctl` and a
> securely-transferred kubeconfig copy, or install `krknctl` on <target-host> directly. With 2 replicas and
> `--disruption-count 1`, the surviving replica should keep serving reconciles — this is intentional, to
> test the failover/duplicate-reconcile race described in §2, not a full control-plane outage.

> krknctl is first priority. Fall back to `oc` only when documented and justified above.

## 4. Injection Timing

**Deterministic condition:** `VirtualMachineBackup.status.conditions[?(@.type=="Done")].status` just
transitioned to `True` (the first observed transition, not a later poll).

**How we watch for it:** no krknctl `--trigger` mechanism exists (confirmed, see scenario 01 §4).
`chaos-trigger.sh` polls `oc get vmbackup <name> -n vm-cbt-demo -o
jsonpath='{.status.conditions[?(@.type=="Done")].status}'` in a tight loop and fires the `krknctl run
pod_disruption_scenarios` command from §3 on the very first read of `True`.

## 5. Expected Behavior / Pass-Fail Criteria

**Pass:**
- Only one terminal checkpoint per backup name is ever created.
- The tracker's `latestCheckpoint` never regresses or duplicates across the controller restart.

**Fail:**
- A second, conflicting checkpoint is created for the same backup name.
- `oc logs virt-controller` shows a duplicate reconcile that is not caught by virt-launcher's
  idempotency guard (i.e. it is accepted as a new backup rather than rejected as already completed).

**Verification commands:** `oc get vmbackup -o yaml` conditions history, `oc get vmbackuptracker -o
yaml`, `oc logs -l kubevirt.io=virt-controller` for duplicate/conflicting reconciles.

## 6. Special Notes
Control-plane correctness scenario, not guest-data correctness — no Tier-B restore check applies here.

## 7. Reproducibility

All commands from §3 and the watch logic from §4 must be captured in
`cbt-chaos/scenarios/05-virt-controller-pod-kill-post-done/chaos-trigger.sh` so the scenario can be
re-run identically in the future. This spec describes intent; the script is the executable source of
truth for the exact invocation.

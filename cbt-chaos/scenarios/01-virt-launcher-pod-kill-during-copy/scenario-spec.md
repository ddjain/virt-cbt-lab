# Scenario: 01-virt-launcher-pod-kill-during-copy

**QE Chaos Matrix ref:** row #1 in `cbt-chaos/chaos-plan.md` §G (Priority: P0)

## 1. Title
Kill virt-launcher mid live block-copy to test whether `Done=True` can ever cover a truncated backup artifact.

## 2. Description
Targets the virt-launcher compute container (QEMU) during the live block-copy window of a full or
incremental backup (`chaos-plan.md` §B step 5 / §E injection point 1). This is the only window with
sustained state mutation to the backup artifact; interrupting it directly tests the "Live block-copy
window" row in `chaos-plan.md` §D — the single most direct way to test whether `Done=True` can ever be
reached over an incomplete/corrupt artifact.

## 3. Chaos Injection

**Primary timing path (`chaos-trigger-v2.sh`, krknctl native trigger):**
Validated against `krknctl describe pod-scenarios` / `krknctl run pod-scenarios --help` (real scenario
tag is `pod-scenarios`, not `pod_disruption_scenarios`). Real virt-launcher pod observed on <target-host>:
`virt-launcher-vm-cbt-demo-rg6tj` in `vm-cbt-demo` — use `--name-pattern` rather than the exact pod name
since a new pod is created on every VMI (re)start.

```bash
krknctl run pod-scenarios \
  --namespace vm-cbt-demo \
  --name-pattern virt-launcher-vm-cbt-demo- \
  --disruption-count 1 \
  --kubeconfig /path/to/cluster/kubeconfig

```
`chaos-trigger-v2.sh` starts krknctl before E2E and adds
`--trigger-k8s-api-version backup.kubevirt.io/v1alpha1`,
`--trigger-k8s-kind VirtualMachineBackup`, the run-specific backup name, and
`--triggers-on-timeout fail`. The native trigger fires at CR creation and the
already-running krkn process then deletes the matching virt-launcher pod.

**Historical precision fallback used by `chaos-trigger.sh` (oc):**
```bash
oc delete pod "$pod_name" -n "$NAMESPACE" --wait=false
```

> Justification for falling back to `oc` (per AGENTS.md's "fall back to `oc` only when documented and
> justified"): `krknctl run` was measured live twice (runs `chaos01-0930-1013` and `chaos01-0930-1021`)
> and its own container startup — image pull, signature verification, python framework init — took
> 5-9s from invocation to the actual pod delete. This backend's full backup lifecycle (creation to
> `Done=True`) is ~5s and its incremental lifecycle is ~3s, so krknctl's startup cost alone exceeds the
> entire injection window regardless of how fast the trigger detects the backup starting. A direct
> `oc delete pod` has no comparable startup cost between detection and the kill. `krknctl`'s own pod-kill
> is itself a standard (non-forced) delete — confirmed via `oc get events`, which showed `Killing`/
> `Gracefully deleting pod` for the krknctl-issued kill — so a plain `oc delete pod` (no
> `--grace-period=0`/`--force`) reproduces the same failure mode, just without the container startup tax.
> This sacrifices krknctl's own recovery-time telemetry (`waiting up to 120 seconds for pod recovery...`)
> for injection precision; recovery can still be observed manually via `oc get events`/`oc get pod -w`
> after the kill if needed.

> `--namespace` defaults to the regex `openshift-.*`, which would NOT match `vm-cbt-demo` — it must be
> passed explicitly. `--kubeconfig` must point to `/path/to/cluster/kubeconfig` on <target-host> (confirmed via
> `/path/to/cbt-setup/.env: KUBECONFIG_PATH=/path/to/cluster/kubeconfig`); `krknctl` itself is not installed on
> <target-host> (confirmed: `command -v krknctl` failed there), so this must be run from a host with `krknctl`
> installed and a securely-transferred copy of that kubeconfig, or `krknctl` must be installed on
> <target-host> directly — do not copy the kubeconfig off <target-host> casually, it is a cluster-admin credential.

## 4. Injection Timing

**Deterministic condition:** the target `VirtualMachineBackup` object is created in the namespace.

**How we watch for it:** The reusable v2 script launches krknctl before E2E,
absorbing its measured 5-9s startup cost while vm-setup runs. Its native
Kubernetes trigger polls the run-specific `VirtualMachineBackup` name every
0.5s; once the object exists, the same krkn process selects the
`virt-launcher-vm-<RUN_NAME>-*` pod and deletes it. `--triggers-on-timeout fail`
prevents a missed object from being reported as a successful no-op.

The older `chaos-trigger.sh` retains the direct `oc get vmbackup -w` plus
`oc delete pod` fallback for cases where krknctl is unavailable or a direct
sub-second kill is required. Its fallback is documented because invoking
krknctl only after detection misses this backend's measured ~5s full / ~3s
incremental lifecycle.

## 5. Expected Behavior / Pass-Fail Criteria

**Pass:**
- The backup CR reaches a terminal state that is either `Done=True` with a complete, valid artifact,
  or a genuine failed/non-Done terminal state — never `Done=True` over truncated bytes.
- `virsh checkpoint-list --tree` after recovery still shows the expected checkpoint relationship.
- Tier-B restore test (full-only and full+incremental reconstructions) matches expected hashes if the
  backup that was interrupted is later retried successfully.

**Fail:**
- `Done=True` is set while the destination PVC content is truncated/corrupt (verified via `qemu-img
  info`/`qemu-img map`).
- The backup silently restarts as a full copy when an incremental copy was intended, without being
  reported as such.

**Verification commands:** see `chaos-plan.md` §H layers 1-5. Never rely on a single `Done=True` read
or the presence/absence of a `Warning` event alone (`chaos-plan.md` §B/§H document a real transient
`Warning...Failed` event on a genuinely successful backup).

## 6. Special Notes
Run against a realistically-sized disk (not the tiny demo disk) so the live-copy window is long enough
to reliably hit with a poll loop — the observed full-backup copy on the demo disk was only ~17.5s.
Compounds with scenario `09-node-stop-start-during-copy` (node-level variant of the same window);
understand this scenario first before running 09.

## 7. Reproducibility

All commands from §3 and the watch logic from §4 must be captured in
`cbt-chaos/scenarios/01-virt-launcher-pod-kill-during-copy/chaos-trigger.sh` so the scenario can be
re-run identically in the future. This spec describes intent; the script is the executable source of
truth for the exact invocation.

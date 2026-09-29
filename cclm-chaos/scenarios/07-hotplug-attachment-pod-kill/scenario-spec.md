# Scenario: 07-hotplug-attachment-pod-kill

**QE Chaos Matrix ref:** row #7 in `cclm-chaos/chaos-plan.md` §G (Priority: P1)

## 1. Title
Kill the `hp-volume-*` hotplug attachment pod before `VolumeMountedToPod` to test the hotplug-attach
retry bound.

## 2. Description
Targets the short-lived `hp-volume-*` attachment pod KubeVirt creates to hotplug the backup destination
PVC into the running VMI, before `VolumeMountedToPod` is reached (`chaos-plan.md` §E injection point 2).
This window is already flaky without any injected chaos (`HotplugFailed` events observed in
`chaos-plan.md` §B step 2, self-healed via retry); this scenario tests whether that retry has a real
bound or can wedge the backup CR indefinitely — the "Hotplug-attach race" row in `chaos-plan.md` §D.

## 3. Chaos Injection

**Primary (krknctl):**

Validated against `krknctl describe pod-scenarios` / `krknctl run pod-scenarios --help` (real scenario
tag is `pod-scenarios`). No `hp-volume-*` pod exists on <target-host> outside the brief hotplug-attach window
itself (`oc get pods -n vm-cbt-demo` shows only the virt-launcher pod at rest) — this confirms the
attachment pod is genuinely transient and the injection window is as narrow as `chaos-plan.md` §D
describes.

```bash
krknctl run pod-scenarios \
  --namespace vm-cbt-demo \
  --name-pattern hp-volume- \
  --disruption-count 1 \
  --kubeconfig /path/to/cluster/kubeconfig
```

**Secondary (oc, only if krknctl cannot do this):**
```
# Not needed — pod-scenarios covers a direct pod kill and supports regex name-pattern matching.
```

> `--kubeconfig` must point at `/path/to/cluster/kubeconfig` on <target-host>; `krknctl` is not installed on <target-host>
> itself (confirmed), so run this from a host with `krknctl` and a securely-transferred kubeconfig copy,
> or install `krknctl` on <target-host> directly. Because the `hp-volume-*` pod is so short-lived, the polling
> loop in `chaos-trigger.sh` §4 must be tight (sub-second) or this scenario may simply miss the window.

> krknctl is first priority. Fall back to `oc` only when documented and justified above.

## 4. Injection Timing

**Deterministic condition:** `VirtualMachineBackup` CR created and an `hp-volume-*` attachment pod
exists for the target PVC but is not yet `Running`/`VolumeMountedToPod`.

**How we watch for it:** no krknctl `--trigger` mechanism exists (confirmed, see scenario 01 §4).
`chaos-trigger.sh` polls `oc get pod -n vm-cbt-demo -l ... --field-selector status.phase!=Running` (or
watches `oc get events` for the attachment pod's `SuccessfulCreate` event without a following
`VolumeMountedToPod`), then fires the `krknctl run pod_disruption_scenarios` command from §3.

## 5. Expected Behavior / Pass-Fail Criteria

**Pass:**
- Attachment eventually succeeds (existing retry heals it), or `VirtualMachineBackup` fails to a
  terminal, non-`Done` state within a bounded time.

**Fail:**
- The backup CR is left in an indefinitely pending `Progressing` state with repeated `HotplugFailed`
  events and no bound on retry attempts/time.

**Verification commands:** `oc get vmbackup -o yaml` (`Progressing` condition), `oc get events` for
repeat `HotplugFailed` reasons and their count/timespan.

## 6. Special Notes
No bytes have been copied yet at this stage, so no artifact-correctness/Tier-B claim applies —
verification is purely about the `Progressing` condition and `oc get events`, not an indefinite pending
state.

## 7. Reproducibility

All commands from §3 and the watch logic from §4 must be captured in
`cclm-chaos/scenarios/07-hotplug-attachment-pod-kill/chaos-trigger.sh` so the scenario can be re-run
identically in the future. This spec describes intent; the script is the executable source of truth for
the exact invocation.

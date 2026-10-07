# Scenario: 07-hotplug-attachment-pod-kill

**QE Chaos Matrix ref:** row #7 in `cbt-chaos/chaos-plan.md` §G (Priority: P1)

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
itself (`oc get pods -n vm-cbt-demo` shows only the virt-launcher pod at rest). This confirms the
attachment pod is genuinely transient and the injection window is as narrow as `chaos-plan.md` §D
describes.

For an incremental target, set `INCREMENTAL_PASS` (default `1`); the trigger
selects the corresponding `vm-incremental-pvc-<RUN_NAME>-pNN` attachment.

```bash
krknctl run pod-scenarios \
  --namespace vm-cbt-demo \
  --name-pattern hp-volume- \
  --disruption-count 1 \
  --kubeconfig /path/to/cluster/kubeconfig
```

**Secondary (oc, justified fallback):**
```
# `hp-volume-*` is shorter-lived than the measured krknctl startup path.
# chaos-trigger.sh resolves the exact pod by its target PVC and uses:
oc delete pod "$attachment_pod" -n "$NAMESPACE" --wait=false
```

> krknctl remains the primary command for normal pod disruptions, but this
> boundary is too short to launch it after detection. The fallback is limited
> to the exact target attachment pod and confirms deletion before exiting.

> krknctl is first priority. Fall back to `oc` only when documented and justified above.

## 4. Injection Timing

**Deterministic condition:** `VirtualMachineBackup` CR created and an `hp-volume-*` attachment pod
exists for the target PVC but is not yet `Running`/`VolumeMountedToPod`.

**How we watch for it:** `chaos-trigger.sh` uses a tight read-only `oc get pod -o json`
poll loop to identify the non-Running `hp-volume-*` pod carrying the run's target
PVC, then issues the documented direct delete fallback. This avoids a second
krknctl startup after the event and fails if the delete is not confirmed.

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
`cbt-chaos/scenarios/07-hotplug-attachment-pod-kill/chaos-trigger.sh` so the scenario can be re-run
identically in the future. This spec describes intent; the script is the executable source of truth for
the exact invocation.

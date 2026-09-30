# Scenario: 06-incremental-copy-storage-throttle

**QE Chaos Matrix ref:** row #6 in `cbt-chaos/chaos-plan.md` §G (Priority: P1)

## 1. Title
Throttle I/O on the incremental backup destination PVC to widen the reconcile-duplicate race window.

## 2. Description
Targets `hello-incremental-output` PVC during the live block-copy window of an incremental backup
(`chaos-plan.md` §E injection point 1, slow variant). The observed incremental copy completes in ~5ms
under normal conditions (`chaos-plan.md` §C step 4), too fast for the reconcile-duplicate race (§C) to
matter in practice. Throttling widens this window deterministically and reversibly, without an outright
failure, to test whether a slow-but-not-failed copy lets that race produce a real conflict.

## 3. Chaos Injection

**Primary (krknctl):**

Validated against `krknctl describe storage-throttle` / `krknctl run storage-throttle --help` (real
scenario tag is `storage-throttle`, not `storage_throttle_scenarios`; `--duration` is a **string** with
unit suffix, e.g. `30s`, not a bare number; `--namespace` is required with default `default`). Live PVC
confirmed on <target-host>: `hello-incremental-output` in `vm-cbt-demo`. This scenario auto-resolves the
mounting pod from `--pvc-name` via a privileged helper pod that applies cgroup throttling.

```bash
krknctl run storage-throttle \
  --namespace vm-cbt-demo \
  --pvc-name hello-incremental-output \
  --throttle-type iops \
  --write-iops 5 \
  --duration 30s \
  --kubeconfig /path/to/cluster/kubeconfig
```

**Secondary (oc, only if krknctl cannot do this):**
```
# Not needed — storage-throttle covers PVC-scoped cgroup throttling directly.
```

> `--kubeconfig` must point at `/path/to/cluster/kubeconfig` on <target-host>; `krknctl` is not installed on <target-host>
> itself (confirmed), so run this from a host with `krknctl` and a securely-transferred kubeconfig copy,
> or install `krknctl` on <target-host> directly. `--write-iops 5` is deliberately aggressive (well below the
> flag's own default of 50) to reliably widen the ~5ms observed incremental-copy window from
> `chaos-plan.md` §C into something a polling script can interact with.

> krknctl is first priority. Fall back to `oc` only when documented and justified above.

## 4. Injection Timing

**Deterministic condition:** virt-launcher log shows `"Backup started"` for the incremental backup
name, `Done` not yet `True`.

**How we watch for it:** no krknctl `--trigger` mechanism exists (confirmed, see scenario 01 §4).
`chaos-trigger.sh` polls `oc logs -f <virt-launcher-pod> -c compute | grep -m1 "Backup started"` for the
incremental backup name, then fires the `krknctl run storage_throttle_scenarios` command from §3.

## 5. Expected Behavior / Pass-Fail Criteria

**Pass:**
- The widened copy window does not produce a genuine double-checkpoint or corrupted artifact, even if
  duplicate `"Backup begin called"` log lines are observed (matching the already-benign behavior in
  `chaos-plan.md` §C).

**Fail:**
- A duplicate begin call under the widened window is accepted as a second backup attempt rather than
  rejected by virt-launcher's idempotency guard, producing conflicting checkpoints/artifacts.

**Verification commands:** same as scenario 01 (§5), plus explicit timing correlation with any
duplicate `"Backup begin called"` log lines in virt-launcher/virt-controller logs during the throttle
window.

## 6. Special Notes
Run only after scenarios `01-virt-launcher-pod-kill-during-copy` and
`05-virt-controller-pod-kill-post-done` are understood individually, since this combines the live-copy
window with the reconcile-duplicate race.

## 7. Reproducibility

All commands from §3 and the watch logic from §4 must be captured in
`cbt-chaos/scenarios/06-incremental-copy-storage-throttle/chaos-trigger.sh` so the scenario can be
re-run identically in the future. This spec describes intent; the script is the executable source of
truth for the exact invocation.

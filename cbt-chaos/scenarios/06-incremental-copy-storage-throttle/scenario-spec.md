# Scenario: 06-incremental-copy-storage-throttle

**QE Chaos Matrix ref:** row #6 in `cbt-chaos/chaos-plan.md` §G (Priority: P1)

## 1. Title
Throttle I/O on the incremental backup destination PVC to widen the reconcile-duplicate race window.

## 2. Description
Targets the pass-specific incremental backup PVC during the live block-copy
window. The pass is selected with `INCREMENTAL_PASS` (default `1`); the
throttle widens the reconcile-duplicate race window without forcing failure.

## 3. Chaos Injection

**Primary (krknctl):**

Validated against `krknctl describe storage-throttle` / `krknctl run storage-throttle --help` (real
scenario tag is `storage-throttle`, not `storage_throttle_scenarios`; `--duration` is a string
with a unit suffix such as `30s`. The reusable trigger derives
`vm-incremental-pvc-<RUN_NAME>-pNN` and resolves the target pod from that PVC.
Set `INCREMENTAL_PASS=2` (or another pass number) to target that pass's PVC; the default is pass 1.

```bash
krknctl run storage-throttle \
  --namespace vm-cbt-demo \
  --pvc-name vm-incremental-pvc-<RUN_NAME>-p01 \
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

**How we watch for it:** `chaos-trigger.sh` starts krknctl before E2E and uses
krknctl's native `--trigger-command` to read the target virt-launcher compute log
for the incremental backup's `"Backup started"` line while `Done` is not `True`.
The trigger timeout is fail-closed, so a missed live-copy boundary is not reported
as a successful throttle run.

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

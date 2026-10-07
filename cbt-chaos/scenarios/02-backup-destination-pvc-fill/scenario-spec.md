# Scenario: 02-backup-destination-pvc-fill

**QE Chaos Matrix ref:** row #2 in `cbt-chaos/chaos-plan.md` §G (Priority: P0)

## 1. Title
Fill the backup-destination PVC during live block-copy to test clean-failure vs silent truncation.

## 2. Description
Targets the run-scoped `vm-backup-pvc-<RUN_NAME>` PVC or a pass-specific
`vm-incremental-pvc-<RUN_NAME>-pNN` PVC during the live block-copy window.
The incremental pass is selected with `INCREMENTAL_PASS` (default `1`).

## 3. Chaos Injection

**Primary (krknctl):**

Validated against `krknctl describe pvc-scenarios` / `krknctl run pvc-scenarios --help` (real scenario
tag is `pvc-scenarios`, not `pvc_scenarios`). The trigger derives the full PVC
or the incremental PVC for `INCREMENTAL_PASS`; `--namespace` has no default.

```bash
krknctl run pvc-scenarios \
  --namespace vm-cbt-demo \
  --pvc-name vm-backup-pvc-<RUN_NAME> \
  --fill-percentage 95 \
  --duration 60 \
  --kubeconfig /path/to/cluster/kubeconfig
```
`chaos-trigger.sh` also passes `--trigger-command`, `--triggers-interval`,
`--triggers-timeout`, and `--triggers-on-timeout fail`; these flags keep a missed
boundary from becoming a false-positive successful chaos run.

Set `TARGET_BACKUP=incremental` and `INCREMENTAL_PASS=2` to target pass 2.
`TARGET_PVC` can override the derived name.

**Secondary (oc, only if krknctl cannot do this):**
```
# Not needed — pvc-scenarios covers PVC fill directly and confirms --pvc-name/--namespace flags.
```

> `--kubeconfig` must point at `/path/to/cluster/kubeconfig` on <target-host>; `krknctl` is not installed on <target-host>
> itself (confirmed), so run this from a host with `krknctl` and a securely-transferred kubeconfig copy,
> or install `krknctl` on <target-host> directly.

> krknctl is first priority. Fall back to `oc` only when documented and justified above.

## 4. Injection Timing

**Deterministic condition:** same as scenario 01 — virt-launcher log shows `"Backup started"` for the
target backup, `Done` not yet `True`.

**How we watch for it:** `chaos-trigger.sh` starts krknctl before E2E and uses
krknctl's native `--trigger-command` to query the target virt-launcher compute log for
the target backup's `"Backup started"` line while `Done` is still not `True`. This is
the exact in-container live-copy signal; the large profile is recommended because the
measured krknctl startup cost is otherwise material relative to the fast backend.

## 5. Expected Behavior / Pass-Fail Criteria

**Pass:**
- Capacity exhaustion during copy causes the backup to fail to a terminal error condition, not
  `Done=True`.

**Fail:**
- `Done=True` is reached while the destination PVC's actual written bytes are less than expected
  (compare `.status.capacity` and real `qemu-img info` output against the source disk size).

**Verification commands:** `oc get vmbackup -o yaml` conditions, PVC `.status.capacity`, `qemu-img
info`/`qemu-img map` on the destination artifact; Tier-B restore test per `chaos-plan.md` §H.

## 6. Special Notes
Target PVC differs between full (`hello-full-output`) and incremental (`hello-incremental-output`)
runs — confirm the live PVC name on cluster before filling in §3. Local hostpath storage sizing may
need to be adjusted to make filling practical within a reasonable `DURATION`.

## 7. Reproducibility

All commands from §3 and the watch logic from §4 must be captured in
`cbt-chaos/scenarios/02-backup-destination-pvc-fill/chaos-trigger.sh` so the scenario can be re-run
identically in the future. This spec describes intent; the script is the executable source of truth
for the exact invocation.

# Scenario: 02-backup-destination-pvc-fill

**QE Chaos Matrix ref:** row #2 in `cclm-chaos/chaos-plan.md` §G (Priority: P0)

## 1. Title
Fill the backup-destination PVC during live block-copy to test clean-failure vs silent truncation.

## 2. Description
Targets `hello-full-output` / `hello-incremental-output` PVCs (local hostpath storage) during the live
block-copy window. Tests whether capacity exhaustion mid-copy produces a terminal error condition or
lets `Done=True` be reached over a truncated file — the "Backup destination capacity" row in
`chaos-plan.md` §D, currently UNKNOWN/untested.

## 3. Chaos Injection

**Primary (krknctl):**

Validated against `krknctl describe pvc-scenarios` / `krknctl run pvc-scenarios --help` (real scenario
tag is `pvc-scenarios`, not `pvc_scenarios`). Both target PVCs confirmed live on <target-host> in `vm-cbt-demo`:
`hello-full-output` and `hello-incremental-output` (both `1489Gi`, `cbt-demo-hpp` StorageClass, `Bound`).
`--namespace` is a required flag with no default.

```bash
krknctl run pvc-scenarios \
  --namespace vm-cbt-demo \
  --pvc-name hello-full-output \
  --fill-percentage 95 \
  --duration 60 \
  --kubeconfig /path/to/cluster/kubeconfig
```

Swap `--pvc-name hello-incremental-output` for the incremental-backup variant of this scenario.

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

**How we watch for it:** no krknctl `--trigger` mechanism exists (confirmed, see scenario 01 §4).
`chaos-trigger.sh` polls `oc logs -f <virt-launcher-pod> -c compute | grep -m1 "Backup started"` for the
target backup name, then fires the `krknctl run pvc_scenarios` command from §3.

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
`cclm-chaos/scenarios/02-backup-destination-pvc-fill/chaos-trigger.sh` so the scenario can be re-run
identically in the future. This spec describes intent; the script is the executable source of truth
for the exact invocation.

# Scenario: 10-node-io-hog-during-copy

**QE Chaos Matrix ref:** row #10 in `cbt-chaos/chaos-plan.md` §G (Priority: P3)

## 1. Title
Generic node I/O hog during live block-copy as a coarse cross-check of the storage-throttle scenario.

## 2. Description
Targets the whole node hosting the HPP (hostpath-provisioner) storage during the live block-copy window,
using generic node-wide I/O contention rather than the PVC-scoped throttle used in scenario
`06-incremental-copy-storage-throttle`. Lower fidelity than scenario 06 since it stresses the whole node
instead of the one relevant PVC; kept only as a coarse cross-check once scenario 06 is understood.

## 3. Chaos Injection

**Primary (krknctl):**

Validated against `krknctl describe node-io-hog` / `krknctl run node-io-hog --help` (real scenario tag
is `node-io-hog`, not `hog_scenarios`/`io-hog.yml` — that was a Krkn-core `SCENARIO_FILE` reference, not
a krknctl-hub scenario tag). There is no `--node-name` flag; targeting a specific node requires
`--node-selector` with a real, discriminating label. Live node hosting virt-launcher confirmed on
<target-host>: `<target-node>`, labeled `kubernetes.io/hostname=<target-node>`.

```bash
krknctl run node-io-hog \
  --namespace vm-cbt-demo \
  --node-selector kubernetes.io/hostname=<target-node> \
  --chaos-duration 30 \
  --kubeconfig /path/to/cluster/kubeconfig
```

**Secondary (oc, only if krknctl cannot do this):**
```
# Not needed — node-io-hog covers node-scoped I/O contention directly via a hostPath-mounted pod.
```

> `--kubeconfig` must point at `/path/to/cluster/kubeconfig` on <target-host>; `krknctl` is not installed on <target-host>
> itself (confirmed), so run this from a host with `krknctl` and a securely-transferred kubeconfig copy,
> or install `krknctl` on <target-host> directly. `--node-mount-path` defaults to `/root`; confirm this path
> is writable/relevant on the HPP-hosting node before relying on the default.

> krknctl is first priority. Fall back to `oc` only when documented and justified above.

## 4. Injection Timing

**Deterministic condition:** same as scenario 01 — virt-launcher log shows `"Backup started"` for the
target backup, `Done` not yet `True`.

**How we watch for it:** no krknctl `--trigger` mechanism exists (confirmed, see scenario 01 §4).
`chaos-trigger.sh` polls `oc logs -f <virt-launcher-pod> -c compute | grep -m1 "Backup started"` for the
target backup name, resolves the HPP-hosting node name, then fires the `krknctl run hog_scenarios`
command from §3.

## 5. Expected Behavior / Pass-Fail Criteria

**Pass:** same as scenario 01 — backup reaches either a genuine terminal error state or a clean,
complete `Done=True`, never `Done=True` over corrupted/truncated data.

**Fail:** same as scenario 01.

**Verification commands:** same as scenario 01 (§5) — `chaos-plan.md` §H layers 1-5.

## 6. Special Notes
Lowest priority in the matrix. Run only after scenario `06-incremental-copy-storage-throttle` to compare
whole-node I/O contention against PVC-scoped throttling for the same live-copy window.

## 7. Reproducibility

All commands from §3 and the watch logic from §4 must be captured in
`cbt-chaos/scenarios/10-node-io-hog-during-copy/chaos-trigger.sh` so the scenario can be re-run
identically in the future. This spec describes intent; the script is the executable source of truth for
the exact invocation.

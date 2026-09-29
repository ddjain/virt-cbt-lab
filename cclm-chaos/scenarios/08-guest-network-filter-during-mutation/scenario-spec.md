# Scenario: 08-guest-network-filter-during-mutation

**QE Chaos Matrix ref:** row #8 in `cclm-chaos/chaos-plan.md` §G (Priority: P2)

## 1. Title
Block SSH (TCP/22) to the guest during the guest-mutation step to test the SSH retry loop's failure
mode.

## 2. Description
Targets the VM's own tap0 interface inside the virt-launcher netns during the guest-mutation step
between full and incremental backups (`vm-cbt-backup.sh` step 2 / `common.sh:guest_ssh`). This is the
guest-mutation SSH path, not the backup-copy path itself — the backup copy is local-node I/O using
QEMU's local `file` blockdev driver, not NBD-over-network (`chaos-plan.md` §F) — so this scenario
deliberately targets a different dependency than scenarios 01-07.

## 3. Chaos Injection

**Primary (krknctl):**

Validated against `krknctl describe vmi-network-filter` / `krknctl run vmi-network-filter --help`. Real
flags are `--vmi-name` (not `--vm-name`), `--ports`/`--protocols` (plural, comma-separated, not
`--port`/`--protocol`), `--chaos-duration` (not `--duration`), and **`--ingress`/`--egress` are both
required booleans with no default** — both must be passed explicitly. Blocking inbound SSH to the guest
means filtering **ingress** traffic to the VMI; egress should stay unfiltered so the guest can still
reach the outside world. Live VMI confirmed on <target-host>: `vm-cbt-demo` in namespace `vm-cbt-demo`.

```bash
krknctl run vmi-network-filter \
  --namespace vm-cbt-demo \
  --vmi-name vm-cbt-demo \
  --ingress true \
  --egress false \
  --ports 22 \
  --protocols tcp \
  --chaos-duration 30 \
  --kubeconfig /path/to/cluster/kubeconfig
```

**Secondary (oc, only if krknctl cannot do this):**
```
# Not needed — vmi-network-filter covers selective port/protocol blocking on the VMI's own interface
# directly (it auto-detects the interface from the binding mode).
```

> `--kubeconfig` must point at `/path/to/cluster/kubeconfig` on <target-host>; `krknctl` is not installed on <target-host>
> itself (confirmed), so run this from a host with `krknctl` and a securely-transferred kubeconfig copy,
> or install `krknctl` on <target-host> directly.

> krknctl is first priority. Fall back to `oc` only when documented and justified above.

## 4. Injection Timing

**Deterministic condition:** `guest_ssh` in `common.sh` is about to be invoked for the post-full-backup
guest mutation (i.e. immediately before the append-marker-line step runs).

**How we watch for it:** no krknctl `--trigger` mechanism exists (confirmed, see scenario 01 §4). Since
this condition is driven by the pipeline script's own execution order rather than a cluster-observable
state, `chaos-trigger.sh` should be invoked from a wrapper around the pipeline's guest-mutation step
(or by watching for the `oc port-forward` process `vm-cbt-backup.sh`/`common.sh` spins up for the guest
SSH session) immediately before that step runs, then fire the `krknctl run vmi-network-filter` command
from §3.

## 5. Expected Behavior / Pass-Fail Criteria

**Pass:**
- The script exits non-zero with an actionable stderr message once the retry budget (30 attempts,
  per `common.sh:guest_ssh`) is exhausted.

**Fail:**
- The script hangs indefinitely past its own retry budget or past other scripts' `oc wait` timeouts,
  with no clear error surfaced.

**Verification commands:** script exit code and stderr only — no backup-artifact or Tier-B data check
applies to this path.

## 6. Special Notes
Tests whether `common.sh`'s 30-attempt port-forward retry loop fails closed with a clear, actionable
error rather than hanging past other scripts' `oc wait` timeouts elsewhere.

## 7. Reproducibility

All commands from §3 and the watch logic from §4 must be captured in
`cclm-chaos/scenarios/08-guest-network-filter-during-mutation/chaos-trigger.sh` so the scenario can be
re-run identically in the future. This spec describes intent; the script is the executable source of
truth for the exact invocation.

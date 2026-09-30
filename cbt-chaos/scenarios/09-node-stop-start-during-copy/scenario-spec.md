# Scenario: 09-node-stop-start-during-copy

**QE Chaos Matrix ref:** row #9 in `cbt-chaos/chaos-plan.md` §G (Priority: P2)

## 1. Title
Stop/start the node hosting virt-launcher during live block-copy — combined pod+storage+checkpoint
loss.

## 2. Description
Targets the node hosting the virt-launcher pod, the hotplugged destination PVC, and the persistent-state
(checkpoint) PVC simultaneously, during the live block-copy window (`chaos-plan.md` §E injection point
1, harder node-level variant). Combines the failure modes probed individually in scenarios
`01-virt-launcher-pod-kill-during-copy` and `03-checkpoint-pvc-fill`, since all three are pinned to the
same node's local hostpath storage (`chaos-plan.md` §D).

## 3. Chaos Injection

**Primary (krknctl; credentials required at run time):**

Validated against `krknctl describe node-scenarios` / `krknctl run node-scenarios --help` (real
scenario tag is `node-scenarios`; `--action node_stop_start_scenario` and
`--cloud-type bm` are valid. The reusable script resolves the virt-launcher
node and targets it with the discriminating
`--label-selector kubernetes.io/hostname=<target-node>` because this krknctl
version rejects the `--node-name` validator even though help advertises it.
Bare-metal stop/start still requires real BMC credentials supplied only through
the environment:

```bash
krknctl run node-scenarios \
  --action node_stop_start_scenario \
  --label-selector kubernetes.io/hostname=<target-node> \
  --cloud-type bm \
  --bmc-user <REQUIRES OPERATOR-SUPPLIED IPMI CREDENTIAL — DO NOT COMMIT> \
  --bmc-password <REQUIRES OPERATOR-SUPPLIED IPMI CREDENTIAL — DO NOT COMMIT> \
  --bmc-address <REQUIRES OPERATOR-SUPPLIED IPMI/BMC ADDRESS FOR <target-node>> \
  --kubeconfig /path/to/cluster/kubeconfig
```

**Secondary (oc, only if krknctl cannot do this):**
```
# Not needed for command syntax — node-scenarios covers bare-metal stop/start via --cloud-type bm.
# The blocker is credential availability, not tooling capability.
```

> Before running: obtain the Scale Lab BMC/IPMI username, password, and address for host
> `<target-node>` through whatever secrets-management process this team uses (do not hardcode them in
> this repo). `--kubeconfig` must point at `/path/to/cluster/kubeconfig` on <target-host>; `krknctl` is not installed
> on <target-host> itself (confirmed), so run this from a host with `krknctl` and a securely-transferred
> kubeconfig copy, or install `krknctl` on <target-host> directly.

> krknctl is first priority. Fall back to `oc` only when documented and justified above.

## 4. Injection Timing

**Deterministic condition:** same as scenario 01 — virt-launcher log shows `"Backup started"` for the
target backup, `Done` not yet `True`.

**How we watch for it:** `chaos-trigger.sh` resolves the target node before
starting krknctl, then uses krknctl's native `--trigger-command` to read the
target virt-launcher compute log for `"Backup started"` while `Done` is not
`True`. Trigger timeout is fail-closed. The BMC credentials remain runtime-only.

## 5. Expected Behavior / Pass-Fail Criteria

**Pass:** same as scenario 01, evaluated after the node returns — the backup either reaches a genuine
terminal error state or a clean, complete `Done=True`, never `Done=True` over corrupted/truncated data;
the checkpoint chain (`virsh checkpoint-list --tree`) remains consistent or is correctly redefined per
scenario 04's `checkpointRedefinitionRequired` path.

**Fail:** same as scenarios 01 and 03 (truncated artifact reported as `Done=True`, or a corrupted
checkpoint chain silently accepted).

**Verification commands:** same as scenarios 01 and 03 combined — `chaos-plan.md` §H layers 1-5, plus
`virsh checkpoint-list --tree` before/after.

## 6. Special Notes
Run only after scenarios `01-virt-launcher-pod-kill-during-copy` and `03-checkpoint-pvc-fill` are
individually understood, so effects can be correctly attributed to pod loss vs storage loss vs
checkpoint-chain loss rather than conflated. This is the hardest and least isolated scenario in the
matrix — treat results as a compounded cross-check, not a substitute for 01/03.

## 7. Reproducibility

All commands from §3 and the watch logic from §4 must be captured in
`cbt-chaos/scenarios/09-node-stop-start-during-copy/chaos-trigger.sh` so the scenario can be re-run
identically in the future. This spec describes intent; the script is the executable source of truth for
the exact invocation.

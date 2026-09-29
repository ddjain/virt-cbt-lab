# Scenario: 01-virt-launcher-pod-kill-during-copy

**QE Chaos Matrix ref:** row #1 in `cclm-chaos/chaos-plan.md` §G (Priority: P0)

## 1. Title
Kill virt-launcher mid live block-copy to test whether `Done=True` can ever cover a truncated backup artifact.

## 2. Description
Targets the virt-launcher compute container (QEMU) during the live block-copy window of a full or
incremental backup (`chaos-plan.md` §B step 5 / §E injection point 1). This is the only window with
sustained state mutation to the backup artifact; interrupting it directly tests the "Live block-copy
window" row in `chaos-plan.md` §D — the single most direct way to test whether `Done=True` can ever be
reached over an incomplete/corrupt artifact.

## 3. Chaos Injection

**Primary (krknctl):**

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

**Secondary (oc, only if krknctl cannot do this):**
```
# Not needed — pod-scenarios covers a direct pod kill and was confirmed to support --name-pattern.
```

> `--namespace` defaults to the regex `openshift-.*`, which would NOT match `vm-cbt-demo` — it must be
> passed explicitly. `--kubeconfig` must point to `/path/to/cluster/kubeconfig` on <target-host> (confirmed via
> `/path/to/cbt-setup/.env: KUBECONFIG_PATH=/path/to/cluster/kubeconfig`); `krknctl` itself is not installed on
> <target-host> (confirmed: `command -v krknctl` failed there), so this must be run from a host with `krknctl`
> installed and a securely-transferred copy of that kubeconfig, or `krknctl` must be installed on
> <target-host> directly — do not copy the kubeconfig off <target-host> casually, it is a cluster-admin credential.

> krknctl is first priority. Fall back to `oc` only when documented and justified above.

## 4. Injection Timing

**Deterministic condition:** virt-launcher compute container log for the target backup name shows
`"Backup started"` and the `VirtualMachineBackup` has not yet reached
`conditions[?(@.type=="Done")].status==True`.

**How we watch for it:** krknctl has no built-in event/trigger flag (confirmed against the krknctl docs
in `/Users/darjain/projects/krkn-chaos/website/content/en/docs/krknctl/` — only
`--detached`/`--dry-run`/`--kubeconfig`/`--alerts-profile`/`--metrics-profile` and the
`graph`/`random`/`query-status` subcommands exist, no `--trigger`). `chaos-trigger.sh` polls
`oc logs -f <virt-launcher-pod> -c compute | grep -m1 "Backup started"` for the target backup name,
then immediately fires the `krknctl run` command from §3.

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
`cclm-chaos/scenarios/01-virt-launcher-pod-kill-during-copy/chaos-trigger.sh` so the scenario can be
re-run identically in the future. This spec describes intent; the script is the executable source of
truth for the exact invocation.

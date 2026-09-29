# Scenario: <scenario-name>

**QE Chaos Matrix ref:** row #<N> in `cclm-chaos/chaos-plan.md` §G (Priority: <P0/P1/P2/P3>)

## 1. Title
<One line: what CBT behavior this scenario is testing and why.>

## 2. Description
<2-4 sentences: the component under stress, the CBT backup operation in flight
(full or incremental, and which lifecycle window from chaos-plan.md §B/§C/§E),
and what correctness question it is answering. Reference the specific
Failure Boundary row from chaos-plan.md §D this scenario targets.>

## 3. Chaos Injection

**Primary (krknctl):**

Run `krknctl list available` to confirm the exact scenario tag (real tags are hyphenated, e.g.
`pod-scenarios`, `pvc-scenarios`, `kubevirt-outage`, `storage-throttle`, `vmi-network-filter`,
`node-scenarios`, `node-io-hog` — not the `SCENARIO_TYPE`-style underscored names sometimes seen in
Krkn-core docs, e.g. NOT `pod_disruption_scenarios`/`kubevirt_vm_outage`/`storage_throttle_scenarios`).
Then run `krknctl describe <scenario>` and `krknctl run <scenario> --help` to get the real flag names
and enum choices before filling this in — flag names are not always intuitive (e.g. `pod-scenarios` uses
`--pod-label`, not `--label-selector`; `vmi-network-filter` uses `--vmi-name`, not `--vm-name`, and
`--ports`/`--protocols` plural). Record the actual invocation with real parameter values read from the
live cluster — real pod name/pattern, namespace, PVC name, node name, etc. No unresolved placeholders at
execution time, and always pass `--kubeconfig` explicitly (do not rely on flag defaults for `--namespace`
either — several scenarios default to a regex like `openshift-.*` or to `default`, which will silently
miss your real target namespace).

```bash
<validated krknctl invocation>
```

**Secondary (oc, only if krknctl cannot do this):**
```
<oc command(s). Only use this path if no krknctl scenario in krkn-hub covers the
required action, and state explicitly here why krknctl was insufficient.>
```

> krknctl is first priority. Fall back to `oc` only when documented and justified above. Note that
> `krknctl` itself may not be installed on the target cluster's bastion/jump host — confirm with
> `command -v krknctl` and, if absent, run krknctl from a separate host with a securely-transferred
> kubeconfig copy (never commit or casually copy a cluster-admin kubeconfig).

## 4. Injection Timing

**Deterministic condition:** <the exact observable condition to watch for — a specific
virt-launcher log line, a CR condition transition, an event reason — taken from the
Injection Condition column of chaos-plan.md §G for this row. Avoid arbitrary `sleep`.>

**How we watch for it:** <krknctl has no built-in event/trigger flag — confirmed against
the krknctl docs in /Users/darjain/projects/krkn-chaos/website/content/en/docs/krknctl/
(only --detached/--dry-run/--kubeconfig/--alerts-profile/--metrics-profile and the
graph/random/query-status subcommands exist, no --trigger). State the poll mechanism
implemented in chaos-trigger.sh — e.g. a bash loop polling `oc get ... -o jsonpath=...`
or `oc logs -f <pod> -c <container> | grep -m1 <pattern>` until the condition is met,
then firing the krknctl/oc command from §3.>

## 5. Expected Behavior / Pass-Fail Criteria

**Pass:**
- <bullet list of concrete, checkable conditions>

**Fail:**
- <bullet list of concrete, checkable conditions>

**Verification commands:** <exact oc/qemu-img/virsh commands used to check backup
metadata, artifact, checkpoint tree, and Tier-B restore/data correctness — reference
chaos-plan.md §H layers 1-5. Never rely on a single `Done=True` read or a `Warning`
event alone — see chaos-plan.md §B/§H for why.>

## 6. Special Notes
<Anything scenario-specific: known flaky behavior already observed without chaos
(e.g. the hotplug-attach race or the reconcile-duplicate-call race in chaos-plan.md
§B/§C), blast radius/cleanup concerns, dependencies on other scenarios, UNKNOWN items
being probed, whether this scenario should only be run after a lower-numbered one is
understood (e.g. node-level scenarios compound with pod/PVC-level ones).>

## 7. Reproducibility

All commands from §3 and the watch logic from §4 must be captured in
`cclm-chaos/scenarios/<scenario-name>/chaos-trigger.sh` so the scenario can be
re-run identically in the future. This spec describes intent; the script is the
executable source of truth for the exact invocation.

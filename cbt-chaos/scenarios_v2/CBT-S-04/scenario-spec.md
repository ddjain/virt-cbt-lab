# Scenario: CBT-S-04 — Storage-path network fault on three nodes while many backups copy

**Status:** PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW
**Planning reference:** scale campaign experiment E4; adapted from CBT-O-04 (Ceph-port blackout) and CBT-O-05 (latency/loss). Shared contract: `CBT-S-00`; trigger/proof mechanics: `CBT-S-01`; node selection rule: `CBT-S-02`.

Use heading titles when linking this spec; do not depend on section numbers.

## Title

Prove that a bounded loss or degradation of node→Ceph connectivity on a subset of nodes stalls or slows only the backups copying through those nodes, ends in clean terminal states, and never yields false success or tracker corruption.

## Description

The backup copy writes to the replica-1 RBD pool through the kernel rbd client on the VM's node (O-04: QEMU writes through the kernel block device; msgr2 acks traverse `ovn-k8s-mp0`). This spec applies O-04/O-05's single-VM mechanics to 3 nodes at once with N backups in flight.

**Legs (phase B peak first; phase D after the full leg passes):**

| Leg | Fault | Duration |
|---|---|---|
| S-04a | Ceph msgr port blackout (drop, ingress+egress) on 3 nodes | 60 s (decision pending, see Description risk) |
| S-04b1 | egress latency 100 ms on 3 nodes | 120 s (O-05) |
| S-04b2 | egress latency 500 ms on 3 nodes | 120 s (O-05) |

Pilot 10 → target 100 each. Loss legs (O-05 `loss`) are out of scope until a result justifies them.

**Risk to decide at approval (not resolved by this spec):** the same OSD ports serve the size-3 root-disk pool and the backup pool, so a blackout on a node also stalls root-disk I/O of every VM on that node (≈60 per node fleet-wide), not only backups. 60 s is chosen to stay under typical guest I/O timeout thresholds but that is unproven; a hung or remounted-read-only guest is a possible outcome and is graded as an observation, not hidden. Latency legs have the same exposure at lower severity.

## Chaos Injection

**Target and fault:** 3 nodes selected by the CBT-S-02 node rule, plus: none of the 3 hosts a mon (blackout includes mon ports only if a mon were present, so mons are excluded rather than relied on). Interface `ovn-k8s-mp0` only; kubelet/API use `br-ex` and must stay reachable; each node must stay `Ready`.

**Port set (blackout):** explicit, non-empty list only (never `ports: []`: krknctl-bugs #11 is node-destructive and leaks permanently). The list is the OSD daemon port set resolved at plan time from `ceph osd dump` (public and cluster addrs of OSDs) plus the mon msgr2 port 3300; O-04's `3300,6800-6803` blocks only the first sockets and is not representative at 86 OSDs, so the list is computed, saved, hashed in the approval, and its coverage compared against the per-node OSD addrs in preflight. [UNVERIFIED] the access path (ceph toolbox) and whether `--ports` accepts a list of that size.

**Command metadata:** `krknctl v0.14.2-beta`; `krknctl describe/run --help` for `node-network-filter` (`--chaos-duration`, `--node-name`, `--namespace`, `--ingress`, `--egress`, `--interfaces`, `--ports`, `--protocols`) and `network-chaos` (`--traffic-type`, `--duration`, `--node-name` (comma-separated names allowed), `--interfaces`, `--egress` dictionary, `--execution`, `--wait-duration`). `--dry-run` must validate each rendered command. Read `cbt-chaos/krknctl-bugs.md` #7 (rule leak when a target container restarts mid-chaos) and #11 before approval.

**Primary:** native krkn scenarios gated by the CBT-S-01 trigger.
- S-04a: `node-network-filter` is single-node per invocation (`--node-name`), so 3 parallel invocations, one per node, same trigger, same `--chaos-duration`; fire-time skew between them (≤ trigger interval + startup) is recorded. Fallback if skew is unacceptable: a single direct-krkn `node_network_filter` list-of-configs as in O-04, same parameters.
- S-04b: single `network-chaos` run: `--traffic-type egress --node-name "$A,$B,$C" --interfaces [ovn-k8s-mp0] --egress '{latency: 100ms}' --duration 120 --execution parallel --wait-duration 240` (flag formats per installed help; the 500 ms leg changes only the latency value).

Example (one node, S-04a):
```sh
krknctl run node-network-filter --kubeconfig "$KUBECONFIG_PATH" \
  --node-name "$NODE" --namespace <pre-created-helper-ns> \
  --ingress true --egress true --interfaces ovn-k8s-mp0 \
  --ports "$PORT_LIST" --protocols tcp --chaos-duration 60 \
  --trigger-command "$(cat trigger/condition.sh)" --trigger-expected-rc 0 \
  --triggers-mode all_of --triggers-interval 1 \
  --triggers-timeout 2700 --triggers-on-timeout fail
```
The helper namespace is pre-created by `run.sh` (krknctl does not create namespaces; bug #9) and removed only by `run.sh` after rule-removal is proven.

**Exception, only if needed:** none anticipated.

**Reusable command:** `CHAOS_RUN_ID=<id> LEG=<A|B1|B2> STAGE=<pilot|target> PHASE=<F|I> KUBECONFIG_PATH=<approved-kubeconfig> bash cbt-chaos/scenarios_v2/CBT-S-04/run.sh --plan|--execute`.

## Injection Timing

Per CBT-S-01 (peak condition, `T_ARM`, post-hoc proof). The fault duration (60/120 s) must fit inside the baseline phase window from CBT-S-00; if the window is shorter than the fault duration the leg's meaning is "fault spans the remainder" and the approval states that explicitly.

## Effect and Blast-Radius Evidence

**Machine effect check (fail closed):** (a) rule/qdisc present during the window: for S-04a the iptables rules on the node's host netns for each listed port; for S-04b `tc qdisc show dev ovn-k8s-mp0` shows netem with the configured delay (read-only `oc debug node/…` or equivalent approved read path); (b) data-plane effect: node→OSD write rate for in-radius backups stalls (S-04a) or slows (S-04b) relative to the baseline for the same VMs; (c) **rules removed** after the window: no leftover rules/qdisc (bug #7/#11 guard), node `Ready`, kubelet/API reachable throughout. A leftover rule is an immediate stop: record, alert the Lead, never leave the node degraded.

**Blast-radius proof:** before/after node Ready state for all nodes; rule/qdisc inventory on the 3 targets and on 3 control nodes (must be unchanged); root-pool PG states; in-radius VM set; guest I/O error indicators (VMI conditions, launcher logs) for in-radius VMs.

**Evidence scope:** group id, T_ARM, fire time per node, node names, port list, helper pod UIDs, rule-removal timestamps.

## Expected Behavior / Pass-Fail Criteria

R1–R7 from CBT-S-00. Suite-specific (failures tolerated, terminal within 30 min, no false success, 100% pass on one retry):

| Requirement | Expected product behavior | Evidence / check | Mandatory? |
|---|---|---|---|
| S04-1 | fault proven present for the whole intended duration and fully removed afterwards; nodes stay Ready | effect checks (a)–(c) | yes (INVALID otherwise) |
| S04-2 | out-of-radius VMs: 100% `PASS`, durations within the baseline distribution | grader + S-00 timeline | yes |
| S04-3 | in-radius backups: each `PASS` or `FAILED-CLEAN`, terminal within 30 min | grader | yes |
| S04-4 | zero `FALSE-SUCCESS`, zero `TRACKER-DRIFT` | grader + physical check | yes |
| S04-5 | 100% of non-`PASS` VMs `PASS` on one retry | retry grade | yes |
| S04-6 | in-radius VMs not left with a guest filesystem remounted read-only or a restarted VMI (observation; any occurrence is reported with raw evidence) | VMI/launcher logs, guest check on sample | yes (reported; verdict per Lead and Analyst) |
| S04-7 | latency legs: record copy-duration inflation vs baseline (measurement; a no-effect result is valid, O-05) | timeline | no |

**Terminal verdicts / same-VM verification:** per CBT-S-00. INVALID additionally for: rules not proven present during the window, rules left behind, non-target node affected, empty port list.

## Execution and Approval

Per CBT-S-00/CBT-S-01. Additional approval items: the computed port list, the 3 node names and racks, durations, explicit acceptance of root-disk I/O exposure on those nodes, and the rule-leak abort procedure. Rollback owner: `run.sh` verifies rule removal and, if krkn failed to remove rules, performs only the approved removal of exactly the rules it created (recorded argv); it never reboots nodes or touches other rules. Preflight adds: krknctl-bugs #7/#11 reviewed; `--dry-run` valid; read access to the node netns/tc state confirmed.

## Reproducibility and Outputs

Per CBT-S-00. `pre-run/targets.json` holds nodes, ports and OSD-address coverage.

## Handoff and Follow-up

Per CBT-S-00. **Uncertainties:** port-set coverage and list-size support; whether guests tolerate a 60 s root-disk stall at ~60 VMs/node; parallel-invocation skew; whether egress-only latency affects the kernel rbd client's ack path enough to matter (no-effect is possible).

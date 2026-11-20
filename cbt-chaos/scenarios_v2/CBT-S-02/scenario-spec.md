# Scenario: CBT-S-02 — Restart virt-handler on three nodes while many backups are in flight

**Status:** PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW
**Planning reference:** scale campaign experiment E2; adapted from CBT-F-05 / CBT-I-06 (virt-handler restart during full / incremental) and CBT-I-02. Shared contract: `CBT-S-00`; trigger templates and post-hoc injection proof: `CBT-S-01` (peak condition, `T_ARM` filter, `N`, `PREFIX`). Only differences are stated here.

Use heading titles when linking this spec; do not depend on section numbers.

## Title

Prove that restarting the node agent (virt-handler) on a subset of nodes mid-backup affects only backups on those nodes, never corrupts checkpoints, and leaves other nodes' backups unaffected.

## Description

virt-handler is the per-node agent that talks to each VM's launcher (SyncVMI) and reports VMI/backup status. At roughly 60 VMIs per node (fleet-wide), a handler restart drops and re-establishes launcher sockets for every VM on the node; a 100-VM group touches most nodes, so the question is the *containment*: backups on the 3 target nodes may be delayed or fail cleanly, all others must be unchanged.

**Legs:** S-02-F (phase B, peak), S-02-I (phase D, peak). Pilot (10 VMs) then target (100 VMs) each. Single restart per window.

## Chaos Injection

**Target and fault:** the `virt-handler` pods (namespace `openshift-cnv`, label `kubevirt.io=virt-handler`) on exactly 3 named nodes, one pod per node, deleted in parallel (graceful delete; `--force` not set).

**Node selection rule (fixed at plan time, hashed into the approval):** from the VMIs of the group's VM range (explicit `--offset` makes it known before the run) take the 3 nodes with the most group VMs, ties broken by node name; reject and re-pick a node that hosts a `rook-ceph-mon` pod, a `virt-controller`/`virt-api`/`virt-operator` pod, or the arm host; the 3 nodes must be in 3 distinct racks (rack label to be verified in preflight; unverified at spec time). Record the per-node count of group VMs (the **in-radius VM set**) — R5 compares in-radius to out-of-radius.

**Command metadata:** `krknctl v0.14.2-beta`; `pod-scenarios` flags per CBT-S-01, plus `--node-names` (format `["a","b","c"]`) and `--execution parallel`; `--pod-label kubevirt.io=virt-handler`. `--dry-run` must validate the rendered command.

**Primary:** native command trigger, Pattern A.

**Reusable command:**

```sh
CHAOS_RUN_ID=<id> LEG=<F|I> STAGE=<pilot|target> KUBECONFIG_PATH=<approved-kubeconfig> \
  bash cbt-chaos/scenarios_v2/CBT-S-02/run.sh --plan|--execute
```
```sh
krknctl run pod-scenarios --kubeconfig "$KUBECONFIG_PATH" \
  --namespace openshift-cnv --pod-label kubevirt.io=virt-handler \
  --node-names "[\"$NODE_A\",\"$NODE_B\",\"$NODE_C\"]" \
  --disruption-count 3 --execution parallel \
  --kill-timeout 180 --expected-recovery-time 180 \
  --trigger-command "$(cat trigger/condition.sh)" --trigger-expected-rc 0 \
  --triggers-mode all_of --triggers-interval 1 \
  --triggers-timeout 2700 --triggers-on-timeout fail
```
(The condition is the CBT-S-01 peak condition without the Lease clause.)

## Injection Timing

Per CBT-S-01 (peak condition, `T_ARM`, arm-before-run, post-hoc proof that ≥50% of backups had `Backup started` and no Done at fire time). Bounds identical to CBT-S-01.

## Effect and Blast-Radius Evidence

**Machine effect check:** each of the 3 handler pods: old UID gone, new UID Running/Ready, node unchanged; DaemonSet desired = ready again. Raw outputs + timestamps.

**Blast-radius proof:** before/after inventory of all virt-handler pods (name, UID, restartCount): exactly 3 changed; all other `openshift-cnv`/`openshift-storage` pods unchanged; in-radius VM set recorded; VMs on non-target nodes unchanged in phase/launcher UID.

**Evidence scope:** group id, T_ARM, fire time, 3 node names, 3 handler UIDs, in-radius VM set.

## Expected Behavior / Pass-Fail Criteria

R1–R7 from CBT-S-00. Suite-specific:

| Requirement | Expected product behavior | Evidence / check | Mandatory? |
|---|---|---|---|
| S02-1 | all 3 handlers replaced and Ready within `expected-recovery-time` | handler pod inventory | yes |
| S02-2 | out-of-radius VMs: 100% `PASS`, completion times within the baseline distribution | grader + S-00 timeline | yes |
| S02-3 | in-radius VMs: zero failed backups is the target; any failure must be `FAILED-CLEAN` and recover on one retry | grader | R1/R4 yes; zero-failure target yes (per decision) |
| S02-4 | no in-radius VM lost its launcher/VMI (no VMI restart, UID same) and CBT stays `Enabled` | VMI/VM JSON | yes |
| S02-5 | no stale attachment/hp-volume pods for group backups at the terminal deadline | pod/VA inventory | yes |
| S02-6 | SyncVMI errors confined to target nodes' VMs and ceasing after recovery | handler logs, `prom-sweep.sh` | yes |

**Terminal verdicts / same-VM verification:** per CBT-S-00 and CBT-S-01 (pre-retry snapshot, then retry). INVALID additionally if any non-target handler restarted or the node rule was violated.

## Execution and Approval

Per CBT-S-00/CBT-S-01. Rollback: DaemonSet reconciliation only; never delete or scale the DaemonSet, never restart other handlers. Preflight adds: node rule evaluated and printed (counts per node, racks, exclusions); `--dry-run` valid.

## Reproducibility and Outputs

Per CBT-S-00. Node names resolved at plan time are written to `runs/<attempt>/pre-run/targets.json` and hashed in `approval.json`.

## Handoff and Follow-up

Per CBT-S-00. Follow-up candidates (unexecuted drafts only if findings justify): launcher kill on a subset (adapts I-02) and kubelet restart on 3 nodes (adapts X-02). **Uncertainties:** whether a handler restart at ~60 VMs/node triggers a SyncVMI storm that outlasts the recovery window; rack label name; whether 3 nodes cover enough group VMs at pilot size (10 VMs may land on fewer than 3 nodes; if so the pilot node rule is "all nodes hosting group VMs, max 3").

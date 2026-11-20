# Scenario: CBT-S-05 — CPU, memory and I/O pressure on three nodes while many backups copy

**Status:** PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW
**Planning reference:** scale campaign experiment E5; adapted from CBT-F-09 (I/O contention), CBT-F-10 (CPU pressure), CBT-X-01 (memory pressure), CBT-T-01..03 (hog threshold hunts). Shared contract: `CBT-S-00`; trigger/proof mechanics: `CBT-S-01`; node rule: `CBT-S-02`.

Use heading titles when linking this spec; do not depend on section numbers.

## Title

Prove that resource pressure on a subset of nodes slows but does not break in-flight backups, with no false success or tracker corruption, and bound the pressure level at which degradation appears.

## Description

Backup copy work runs in the VM's launcher (QEMU/libvirt) on its node; the controller and handler run elsewhere or alongside. With ~60 VMs per node, node pressure also hits the guests. Legs (one pressure type per run; pilot 10 → target 100; phase B first, phase D after):

| Leg | Fault | Proven reference values (re-verify) |
|---|---|---|
| S-05c | `node-cpu-hog` | F-10: `--cpu-percentage 60 --cores 32` on a 112-CPU node, 90 s |
| S-05m | `node-memory-hog` | X-01/T-02: `--memory-consumption 40%` of node memory (about 200 GiB on a 503 GiB node), 90 s |
| S-05i | `node-io-hog` | F-09 post-fix image: `--io-workers`, `--io-write-bytes`, `--node-mount-path` as validated there |

**Expectation to test, not assume:** the backup data path goes over the network to RBD, so a node-local `node-io-hog` may produce no measurable effect on copy time (no-effect is a valid result, as in O-05); in-Ceph contention (CBT-O-10) is the storage-side analogue and is a follow-up, not this spec. CPU and memory hogs act on QEMU/launcher/handler/guests directly and are expected to matter more.

**Sizing at scale (open):** the reference values were validated on one node with one VM; at ~60 VMs per node the same hog is heavier relative to the workload. Per-node CPU count and memory are read at plan time and the percentages are scaled so the hog's absolute consumption equals the validated reference (not the percentage); the exact numbers are fixed and hashed at approval, and pilot results may reduce, not raise, them. Threshold hunting (increasing steps) is explicitly out of scope; it would be a separate T-series draft.

## Chaos Injection

**Target and fault:** one hog per selected node on 3 nodes chosen by the CBT-S-02 node rule (no mon, no CNV control-plane pod, distinct racks), duration 90 s unless the reference differs. Hog pods and namespace are pre-created by `run.sh` where needed (krknctl-bugs #9) and removed by krkn at the end; `node-selector kubernetes.io/hostname=<node>` per node (instantiated one container per selected node).

**Command metadata:** `krknctl v0.14.2-beta`; `krknctl run node-cpu-hog|node-memory-hog|node-io-hog --help` flags: cpu `--chaos-duration --cores --cpu-percentage --namespace --node-selector --number-of-nodes --image`; memory `--chaos-duration --memory-workers --memory-consumption --namespace --node-selector`; io `--chaos-duration --io-block-size --io-workers --io-write-bytes --node-mount-path --namespace --node-selector`. krknctl-bugs #13 records that `node-memory-hog` works in the `default` namespace on this version (earlier #1/#9/#10 were not reproduced there); each hog is probed in preflight: pod reaches Running, log shows workers dispatched without `Read-only file system`, node Ready.

**Primary:** native krknctl hog gated by the CBT-S-01 trigger. Because `--node-selector` takes one `<label>=<value>`, three invocations (one per node, hostname selector) run in parallel; recorded fire skew as in CBT-S-04.

```sh
krknctl run node-cpu-hog --kubeconfig "$KUBECONFIG_PATH" \
  --namespace default --node-selector "kubernetes.io/hostname=$NODE" \
  --cpu-percentage "$CPU_PCT" --cores "$CORES" --chaos-duration 90 \
  --trigger-command "$(cat trigger/condition.sh)" --trigger-expected-rc 0 \
  --triggers-mode all_of --triggers-interval 1 \
  --triggers-timeout 2700 --triggers-on-timeout fail
```
(memory/io legs substitute the scenario and its own flags.)

**Exception, only if needed (Pattern C):** if a preflight probe shows the installed hog plugin cannot start on the target node (F-10 r01 / X-01 r02 class), the fallback is the F-10/X-01 approach: the same pinned krkn hog image run as a privileged pod pinned to the node with the `/dev/shm` writable-workdir workaround, owned by `run.sh` under the same condition, identity, bounded-wait and effect rules. The probe result and the exact missing capability are recorded; the exception is not used merely because a trigger is missing.

**Reusable command:** `CHAOS_RUN_ID=<id> LEG=<C|M|I> STAGE=<pilot|target> PHASE=<F|I> KUBECONFIG_PATH=<approved-kubeconfig> bash cbt-chaos/scenarios_v2/CBT-S-05/run.sh --plan|--execute`.

## Injection Timing

Per CBT-S-01 (peak condition, `T_ARM`, post-hoc proof). Hog duration must fit the baseline phase window (CBT-S-00 B3); otherwise the approval states the fault spans the remainder of the phase.

## Effect and Blast-Radius Evidence

**Machine effect check:** during the window the node shows the intended load by a read-only measure: CPU usage (node metrics) for S-05c near the reference, `MemAvailable` drop for S-05m (reference: MemAvailable fell to the requested target within ~15 s), disk write rate on the mount path for S-05i. Hog pod UID, node, Running interval, exit status, and removal are recorded; krknctl exit 0 alone is not proof.

**Blast-radius proof:** before/after pod inventory (hog pods only added, then removed); node conditions (Ready, MemoryPressure, DiskPressure, PIDPressure) for the 3 targets and all other nodes; no OOM kills or evictions of launcher/handler pods outside the declared targets; in-radius VM set recorded.

**Evidence scope:** group id, T_ARM, fire time per node, node names, hog pod UIDs, load samples.

## Expected Behavior / Pass-Fail Criteria

R1–R7 from CBT-S-00. Suite-specific (failures tolerated, terminal within 30 min, no false success, 100% pass on one retry):

| Requirement | Expected product behavior | Evidence / check | Mandatory? |
|---|---|---|---|
| S05-1 | hog load proven present for the window and fully removed; nodes stay Ready | effect + node conditions | yes (INVALID otherwise) |
| S05-2 | out-of-radius VMs: 100% `PASS`, durations within baseline distribution | grader + S-00 timeline | yes |
| S05-3 | in-radius backups: `PASS` or `FAILED-CLEAN`, terminal within 30 min | grader | yes |
| S05-4 | zero `FALSE-SUCCESS`, zero `TRACKER-DRIFT` | grader + physical check | yes |
| S05-5 | 100% of non-`PASS` VMs `PASS` on one retry | retry grade | yes |
| S05-6 | no launcher/VMI restart or eviction caused by the hog outside tolerated freeze/thaw warnings (F-10: warnings acceptable, hard VMI failure is not) | VMI, launcher logs, events | yes |
| S05-7 | record copy-duration inflation per leg and per node role (measurement; no-effect is valid for S-05i) | timeline | no |

**Terminal verdicts / same-VM verification:** per CBT-S-00. INVALID additionally for: hog not running on the declared nodes, load not reaching the reference, hog affecting non-target nodes.

## Execution and Approval

Per CBT-S-00/CBT-S-01. Additional approval items: node names, per-node absolute load values, hog image digest, `default`-namespace use or pre-created namespace, the Pattern C fallback rule. Rollback: krkn removes the hog pods; `run.sh` verifies removal and deletes only hog pods/namespace it created. Never touch other namespaces.

## Reproducibility and Outputs

Per CBT-S-00. Node CPU/memory facts and the scaled hog values are saved in `pre-run/targets.json`.

## Handoff and Follow-up

Per CBT-S-00. Follow-ups (unexecuted drafts only if findings justify): threshold-hunt at scale (adapts T-01..03), in-Ceph I/O contention (adapts O-10/O-12), combined faults. **Uncertainties:** per-node scaling of hog values at ~60 VMs/node; whether `node-io-hog` on a local path affects an RBD-backed copy at all; whether the cpu/io hog plugins are as healthy as memory-hog on this registry (probe).

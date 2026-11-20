# Scenario: CBT-S-01 — Kill the virt-controller leader while many backups are in flight

**Status:** PROPOSED — UNEXECUTED — PENDING HUMAN REVIEW
**Planning reference:** scale campaign experiment E1; adapted from CBT-F-04 (leader kill mid-copy), CBT-EXP-03 and CBT-EXP-12 (completion-boundary races). Shared contract: `CBT-S-00` (grading classes, R1–R7, evidence, approval flow).
**Jira conditions:** none yet (see CBT-S-00).

Use heading titles when linking this spec; do not depend on section numbers.

## Title

Prove that a single virt-controller leader loss, landing while N backups are copying or completing, delays but never breaks any backup and never corrupts tracker state, because the data plane lives in each VM's launcher and a standby controller resumes reconciliation.

## Description

At scale one controller serializes the reconciliation of N `VirtualMachineBackup` objects and N tracker updates. F-04 proved the single-VM case on one VM; this spec asks whether failover under N concurrent backups loses a completion, duplicates a tracker advance, or leaves an attachment behind. The hypothesis (from F-04) that QEMU/libvirt copy continues in the launcher while the controller is gone is a hypothesis, not a result.

**Legs (one injection per run, each its own group run):**

| Leg | Phase | Fire point |
|---|---|---|
| S-01-FP | full (B) | peak: ≥50% of full backups `Progressing=True`, not attaching, not Done |
| S-01-FB | full (B) | boundary: ≥80% of full backups Done and at least one not Done |
| S-01-IP | incremental (D) | peak (same condition, `vm-incremental-` prefix) |
| S-01-IB | incremental (D) | boundary (same condition, `vm-incremental-` prefix) |

Order: S-01-FP pilot (10 VMs) → target (100 VMs) → S-01-FB → S-01-IP → S-01-IB (each pilot then target; a leg's target is run only after its pilot is INVALID-free). Initial state: baseline (`CBT-S-00`) PASS at the same size.

## Chaos Injection

**Target and fault:** the `virt-controller` Lease holder in `openshift-cnv`, exactly one pod, one deletion. The holder is resolved at plan time, again at arm time, and revalidated (name + UID + Running + label `kubevirt.io=virt-controller` + a Ready standby present) immediately before the action. At survey time the holder was `virt-controller-7b7755d5d5-9l8g2` on d38-h07 and the standby on d38-h09; never reuse those names. Exclusions: virt-api, virt-operator, virt-handler, the standby controller.

**Command metadata:** `krknctl v0.14.2-beta` (re-verify). `pod-scenarios` flags checked via `krknctl run pod-scenarios --help`: `--namespace`, `--name-pattern`, `--pod-label`, `--disruption-count`, `--execution`, `--kill-timeout`, `--expected-recovery-time`, `--force`, plus the TRIGGERS group (`--trigger-command`, `--trigger-expected-rc`, `--triggers-mode`, `--triggers-timeout`, `--triggers-interval`, `--triggers-on-timeout`). `--pod-label` is omitted deliberately: with a pod label supplied the installed `pod-scenarios` ignores `--name-pattern` (F-04 §7). `--dry-run` must return schema/required/values valid for the resolved command.

**Primary:** native krkn command trigger (Pattern A), armed before `fleet-e2e.sh run`.

**Exception, only if needed:** none anticipated.

**Reusable command:**

```sh
CHAOS_RUN_ID=<id> LEG=<FP|FB|IP|IB> STAGE=<pilot|target> \
  KUBECONFIG_PATH=<approved-kubeconfig> \
  bash cbt-chaos/scenarios_v2/CBT-S-01/run.sh --plan|--execute
```

The injection itself (rendered by `inject.sh` with `LEADER` resolved live):

```sh
krknctl run pod-scenarios \
  --kubeconfig "$KUBECONFIG_PATH" \
  --namespace openshift-cnv --name-pattern "^${LEADER}$" \
  --disruption-count 1 --execution serial \
  --kill-timeout 180 --expected-recovery-time 120 \
  --trigger-command "$(cat trigger/condition.sh)" --trigger-expected-rc 0 \
  --triggers-mode all_of --triggers-interval 1 \
  --triggers-timeout 2700 --triggers-on-timeout fail
```

`--triggers-on-timeout fail` (installed enum `skip|fail|run_anyway`): never skip or fire blind.

## Injection Timing

**Deterministic condition:** evaluated on the live objects of the current group only. Because the fleet reset deletes the previous group's backups and the trigger is armed before the run starts, stale objects must not count: every selection filters `metadata.creationTimestamp >= T_ARM` (rendered by `run.sh` as the arm instant, saved decoded next to the evidence). `N` is the group VM count (10 or 100). Templates (placeholders `@…@` rendered by `run.sh`; no backslashes anywhere, krkn collapses them; single poll must stay under krkn's 30 s per-poll cap, a single `oc get vmbackup -o json` for ≤100 objects is expected to take ~1–2 s, to be measured in pilot):

Peak (FP/IP):
```bash
oc get vmbackup -n vm-cbt-demo -o json | jq -e --arg p "@PREFIX@" --arg t "@T_ARM@" --argjson n @N@ '[.items[] | select((.metadata.name | startswith($p)) and (.metadata.creationTimestamp >= $t))] as $b | ($b | map(select(any(.status.conditions[]?; .type == "Progressing" and .status == "True" and ((.reason // "") | test("attached to VMI") | not)) and (any(.status.conditions[]?; .type == "Initializing" and .status == "True") | not) and (any(.status.conditions[]?; .type == "Done" and .status == "True") | not))) | length) as $c | ($b | length) >= $n and $c >= ($n / 2)' >/dev/null && test "$(oc get lease virt-controller -n openshift-cnv -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)" = "@LEADER@"
```

Boundary (FB/IB):
```bash
oc get vmbackup -n vm-cbt-demo -o json | jq -e --arg p "@PREFIX@" --arg t "@T_ARM@" --argjson n @N@ '[.items[] | select((.metadata.name | startswith($p)) and (.metadata.creationTimestamp >= $t))] as $b | ($b | map(select(any(.status.conditions[]?; .type == "Done" and .status == "True"))) | length) as $d | ($b | length) >= $n and $d >= ($n * 0.8) and $d < $n' >/dev/null && test "$(oc get lease virt-controller -n openshift-cnv -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)" = "@LEADER@"
```

`PREFIX` is `vm-backup-` (full) or `vm-incremental-` (incremental). The peak condition is a control-plane approximation of "copying": `Progressing=True` alone is not proof of copy (F-04). Therefore R7 requires a **post-hoc proof**: from every group launcher's compute log (read-only, after the run) reconstruct, per backup, `Backup started` time; the injection is VALID only if at the recorded fire time at least 50% (peak) of the N backups had `Backup started` and no Done. Below that → INVALID and the leg is re-armed with a corrected condition under fresh approval.

**Arming and handoff:** `run.sh` arms `inject.sh` in its own process group, waits for the `waiting for triggers` marker in the krkn action log, then starts the group run (phase A workload starts after the marker). For IP/IB the same armed injector is created with `PREFIX=vm-incremental-`; it cannot fire during phase B because no incremental backups exist yet and `T_ARM` excludes older objects.

**Trigger implementation:** installed native command trigger; base64-embedded condition as in F-04 §7; decoded copy saved to `runs/<attempt>/trigger/condition.sh`; the logged command (`[0] command trigger:`) is compared with the intended text before the run proceeds (backslash/quoting trap, CBT-F-13 r02).

**Bounds:** arm-ready 600 s; group run 45 min; native trigger timeout 2700 s; krkn join 900 s; observation window after action: until group terminal + 30 min terminal deadline; whole attempt 3 h. Window-fit check: S-01-IP/IB depend on the baseline's incremental wall (B3 in CBT-S-00); if the baseline incremental window is under ~30 s the legs are redesigned (offset-from-copy-start pattern) before approval, not after.

**Condition-before-action evidence:** at fire time, saved raw: the vmbackup JSON snapshot the condition evaluated (count of selected objects, per-state counts), Lease JSON, the killed pod JSON (name, UID, node), both controller pods before action, UTC timestamps, exact krkn argv, krkn start/end/exit.

## Effect and Blast-Radius Evidence

**Machine effect check:** killed pod UID gone and a replacement pod with a new UID exists; Lease `holderIdentity` changes from the armed holder (observed ≥1 transition) and stabilizes; both replicas Ready again. Query output and timestamps saved; exit 0 of krknctl is not proof.

**Blast-radius proof:** before/after inventory of all pods in `openshift-cnv` (name, UID, restartCount) and `openshift-storage` OSD/mon pods: only the one controller pod differs. Count of group vmbackups in each state at fire time. Excluded objects (standby controller, virt-api, virt-handler pods, other-group objects) unchanged.

**Evidence scope:** group id, T_ARM, fire time, killed pod UID, leader before/after, vmbackup/tracker UIDs of the group, launcher pods of the group.

## Expected Behavior / Pass-Fail Criteria

Requirement rows R1–R7 from CBT-S-00 apply unchanged. Suite-specific bars and expectations:

| Requirement | Expected product behavior | Evidence / check | Mandatory? |
|---|---|---|---|
| S01-1 | exactly one Lease holder transition within the observation window; both controller pods Ready | Lease + pods snapshots | yes |
| S01-2 | zero failed backups: every backup `PASS` (target 0% failure, per decision) | `grade.tsv` | yes |
| S01-3 | tracker advanced exactly once per backup, to that backup's checkpoint; no duplicate or replayed checkpoint | tracker snapshots before / after | yes |
| S01-4 | no stale hotplug attachment: every `hp-volume-*` pod and VolumeAttachment of group backups released by the terminal deadline | pod/VA inventory | yes |
| S01-5 | no VM lost CBT: `.status.changedBlockTracking.state=Enabled` for all group VMs | VM JSON | yes |
| S01-6 | delayed completion is acceptable; record per-backup completion delay versus baseline timeline (measurement, not a bar) | timeline vs S-00 | no |
| S01-7 | SyncVMI error rate returns to baseline within the window; no controller restart loop | `prom-sweep.sh`, controller logs | yes |

**Verification:** per CBT-S-00 (grader classes, physical check, `fleet-verify.sh`). A failed backup caused by the kill is a FAIL of S01-2 even if it is `FAILED-CLEAN` and retry passes; retry success is graded under R4 separately.

**Terminal verdicts:** as CBT-S-00 (BLOCKED / INVALID / FAIL / INCONCLUSIVE / PASS). INVALID covers: wrong or standby pod killed, more than one pod killed, fire condition not proven by post-hoc launcher timeline, trigger fired from a stale pre-arm object.

**Post-chaos same-VM backup verification:** required for any non-`PASS` VM: snapshot failed objects to `runs/<attempt>/pre-retry/`, then `fleet-e2e.sh run --retry <group> --only-failed`; verify type, terminal reason, checkpoint/tracker advancement, CBT Enabled. If the retry path cannot run without losing the snapshot → BLOCKED.

## Execution and Approval

Per CBT-S-00. Stage table specialization:

| Stage / purpose | Exact existing command | Owner | Readiness handoff | Deadline / exit handling |
|---|---|---|---|---|
| Plan | `run.sh --plan` (resolves LEADER, node/VM inventory, renders trigger, runs `krknctl run pod-scenarios --dry-run`) | run.sh | plan files + dry-run OK | 5 min |
| Arm | `inject.sh` (setsid) | run.sh | `waiting for triggers` marker | 10 min |
| Group | `cbt-scale/fleet-e2e.sh run …` | run.sh | wrapper log | 45 min |
| Evidence | post-hoc launcher-log timeline, grader, verify, prom sweep | Lead/run.sh | group DONE | 15 min |

**Process and rollback ownership / Approval bundle:** per CBT-S-00. Rollback: none required (Deployment recreates the pod); do not delete the standby or touch virt-operator.

**Preflight before costly pipeline:** per CBT-S-00, plus: Lease holder is a Running `virt-controller` pod with a Ready standby; `--dry-run` valid; trigger precheck replayed on baseline vmbackup JSON — positive and negative cases (B4).

## Reproducibility and Outputs

Per CBT-S-00. Attempt ids never reused; legs and stages recorded in `run.json`.

## Handoff and Follow-up

Per CBT-S-00. Proposed follow-up only if single-kill PASSES: repeated kills (3 kills, 30 s apart) as `CBT-S-01R` (draft, unexecuted). Known-defect regressions (EXP-10, EXP-11, EXP-13) are out of scope for this campaign by decision.

**Uncertainties:** peak condition is an approximation (see post-hoc proof); the poll duration with 100 objects is unmeasured; whether the controller loss at scale produces delayed vs failed backups is unproven.

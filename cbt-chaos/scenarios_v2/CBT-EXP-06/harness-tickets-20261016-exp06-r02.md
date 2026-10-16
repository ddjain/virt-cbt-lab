# Harness tickets — CBT-EXP-06 run `20261016-exp06-r02`

- Run: `20261016-exp06-r02` (scenario `CBT-EXP-06`), verdict **BLOCKED**, closed. This file is a **post-close** deliverable: nothing under `runs/20261016-exp06-r02/` is modified.
- Companion document: `analysis/20261016-exp06-r02-improvements.md` (exact, copy-pasteable diffs; referenced below as **M1/M2/M3/M4-x**). **No fix has been applied.**
- Severity: `critical` (invalidates the verdict / destroys evidence) · `high` (forces REJECT or blocks the run's question) · `medium` (misleads a reader or a future run) · `low` (cosmetic or self-announcing).
- Every ticket states the observed fact with its artifact, then the fix. Labels: **observed** vs **[INFERENCE]**.

| id | class | severity | twice-rule | target | diff |
|---|---|---|---|---|---|
| H-01 | `evaluator-out-of-shape` | high | **MANDATORY (3rd occurrence)** | `cbt-chaos/scenario-verdict.sh`, `scenario-check-sets.tsv` | M1 |
| H-02 | `evidence-index-hash-drift` | medium | **MANDATORY (2nd occurrence)** | `cbt-chaos/pack-validate.sh`, `evidence-index.sh`, team SKILL, checker contracts | M2 |
| H-03 | `injection-pre-state-not-independently-witnessed` | high | no (1st) | observer template + per-run contract + trigger + `capture-pre.sh` | M3 |
| H-04 | `no-pass-adding-path-preserves-failed-evidence` | high | no (1st) | `scripts/vm-cbt-{extend,reconcile}.sh`, `docs/vm-cbt-workflow.md` | design options (§H-04) |
| H-05 | `trigger-exit-status-hardcoded` | low | no | `chaos-trigger.sh:528` | M1-c / M4-b |
| H-06 | `observer-gate-double-counts-ready-files` | low | no | `chaos-trigger.sh:145-164` (+ `pids.json` 5-of-7) | M4-a |
| H-07 | `observer-false-negative-claim` | medium | no | `cbt-chaos/contracts/observer.md` | M3-a (negative-claims rule) |
| H-08 | `summary-vm-state-semantics` | medium | no | `scripts/write-run-summary.sh:161-164` + evaluator consumer | M4-f |
| H-09 | `preflight-capacity-wrong-filesystem` | high | no (1st for this run; class known since 2026-10-13) | `cbt-chaos/contracts/preflight.md`, preflight SKILL, `chaos-trigger.sh` | M4-d |
| H-10 | `platform-version-not-captured` | medium | no | `cbt-chaos/contracts/preflight.md`, preflight SKILL | M4-e |
| H-11 | `followup-driver-phantom-cleanup-claim` | low | no | `same-vm-followup.sh:185-197` | M4-c |
| H-12 | `non-terminal-object-has-no-recorded-outcome` | high | no | `chaos-trigger.sh:494-535`, `scripts/common.sh:1037,1046` | M1-c |
| H-13 | `ledger-truncated-by-run-root-push` | medium | no (2nd for the sync class this run: in-run + post-close) | team SKILL (sync rule) | M4-g |
| H-14 | `harness-doc-asserts-a-deletion-the-code-refuses` | low | no | `same-vm-followup.sh` header, `reject-reasons.tsv` wording, recovery contract template | §H-14 |

---

## H-01 — `evaluator-out-of-shape` · severity **high** · **MANDATORY (twice-rule, 3rd occurrence)**

**Observed.** `verdict-evaluator.json`: `{"verdict":"FAIL","verdict_reason":"failing checks: injection-signal"}`, exit 1, from a scenario whose acceptance criteria the table does not express. The Lead recorded it verbatim rather than softening it: `checkers/verdict.json#sub_verdicts.deterministic_evaluator.applicability` — "injection-signal requires an active-copy signal this scenario does not have by design, backup-interrupted expects a failed FULL backup whereas here the full succeeded and the INCREMENTAL is the affected pass, and cbt-recovered reads a lifecycle verify check that never ran."

**Evidence.** `verdict-evaluator.json`; `checkers/verdict.json#sub_verdicts.deterministic_evaluator`; `cbt-chaos/scenario-verdict.sh:167-179` (fixed id table), `:360-470` (`check_injection_signal`), `:590-650` (`check_backup_interrupted`), `:717-798` (`check_cbt_recovered`), `:956-963` (fixed dispatch); `tests/test-scenario-verdict.sh:178-184` (asserts the fixed 8-id list); the run itself emits no outcome record for the affected pass (`trigger/run-notes.md#anomalies 4`; `trigger.log:157-158`).

**Twice-rule trail.** `.agents/skills/cbt-chaos-team/cbt-chaos-team-learnings.md` (2026-10-16): "three failure classes reached ≥2 occurrences across these runs: **evaluator-out-of-shape (HV1)** … the Scenario Improver must then produce the exact diff and the human must approve or explicitly decline it; nothing was applied." Prior runs cited there: CBT-F-01 r04, CBT-I-01 r01.

**Fix.** M1 in the improvements doc: a fixed-text check-set registry (`cbt-chaos/scenario-check-sets.tsv`; `default` byte-identical to today's table, `CBT-EXP-06` mapped to the surgery family), check-set resolution in `scenario-verdict.sh` with fail-closed `UNKNOWN` for any id without an implementation, three new checks (`injection-pre-state`, `injection-effect`, `affected-pass-outcome`), the trigger change that makes `affected-pass-outcome` readable (`terminal`/`waited_seconds`/`pass_wait_bound_seconds`; plus `trigger/surgery-target.json` from M3), and the offline tests (including the regression that the frozen r02 pack must stop returning `FAIL`). **Measured** (improvements doc §1.7): applied to a scratch copy and run against the frozen pack, the CBT-EXP-06 set returns `INCONCLUSIVE` with `injection-effect=PASS` (per-disk contrast proven), `injection-pre-state=UNKNOWN` (the 48-row census), `affected-pass-outcome=UNKNOWN` (the pack predates the new fields) and `cbt-recovered=UNKNOWN` — while `--check-set default` still returns `FAIL`, so the legacy family is untouched. That is aligned with the human `BLOCKED` instead of contradicting it.

**Flag.** MANDATORY — needs an explicit human approve/decline; if declined, the decline must be recorded in the learnings file (the class is now 3 occurrences).

---

## H-02 — `evidence-index-hash-drift` · severity **medium** · **MANDATORY (twice-rule, 2nd occurrence)**

**Observed.** `checkers/evidence-sufficiency.json#limitations/5`: "…`ledger.jsonl` is listed as 23171 bytes / sha256 `a59a1686ddff...` but is 27415 bytes / sha256 `e9813f30ba21...` (the index predates later ledger appends)." Same in `#false_positive_risks/10`. Raised as a finding in this run; it was a **reject reason** in `cbt-chaos/scenarios_v2/CBT-F-04/reject-reasons.tsv` (`20261015-cbtf04-r03 … evidence-index-hash-drift … ledger appended after index generation, indexed sha256 stale`).

**Second facet, observed post-close (new).** The workstation mirror is inconsistent with the remote and with itself: local `ledger.jsonl` 37 lines / 33686 B vs remote 42 lines / 38628 B; local `evidence-index.json` is the 151-file pre-checker index (`generated_utc 2026-10-16T05:00:36Z`) vs the remote's 157-file `05:56:30Z` index; and `bash cbt-chaos/pack-validate.sh cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02` fails 5 ways (`state.json phase 'verdict' != last ledger phase 'checked'`; hash mismatch + "index is stale" for both `ledger.jsonl` and `state.json`).

**Root cause.** Structural, not careless: the pre-checker index is generated, then the Lead keeps appending ledger lines (checker verdicts, verdict, report revisions, close) while the checkers grade. `pack-validate.sh:3-5` says "run before spawning checkers", so its exit 0 at spawn time cannot see a *later* append.

**Fix.** M2 in the improvements doc: `pack-validate.sh --freeze` (validate, then record index+ledger sha256/sizes into `checkers/pack-freeze.json`) and `--verify-freeze` (fail on any drift, checked *before* the ordinary rules so a moved pack is always named); `evidence-index.sh` excludes the freeze record from the index; team SKILL rule 2a rewritten as the exact command sequence (`evidence-index.sh` → `pack-validate.sh --freeze` → spawn) with "no ledger append until every checker of the phase returns"; and the same requirement written into each `cbt-chaos/contracts/check-*.md` so the checkers themselves run `--verify-freeze` first and last — which is the load-bearing part, since rules 3-4 already detected this drift but were never re-run. A closing failure becomes `pack-mutated-during-grading` (re-grade), never a finding. **Measured** (improvements doc §2.7): on a scratch copy the freeze/verify pair is exit 0 on a consistent pack and exit 1 with `ledger.jsonl changed since the freeze … the index was generated before the ledger's last append for this phase` after a single appended ledger line; `--freeze` refuses (exit 1, writes nothing) on an invalid pack. The same run independently confirmed the **remote** pack is consistent (42 ledger lines, 157 indexed files, all hashes matching) while the workstation mirror is not.

**Flag.** MANDATORY — human approve/decline.

---

## H-03 — `injection-pre-state-not-independently-witnessed` · severity **high**

**Observed.** The run's mandated pre-state witness does not exist: `observer/effect/qmp-bitmaps-pre.json` absent; 0 of 48 rows of `observer/effect/pre-bitmap-history.jsonl` report `target_present=true` (39 `not_ready` to 04:28:13Z, 3 `exec_failed` at 04:28:23/33/44Z, 6 `ok` post-removal with an empty bitmap list, first at 04:28:54Z). The bitmap was removed at 04:28:21Z. Both blind checkers rejected on this single gap (`checkers/injection-validity.json`, `checkers/evidence-sufficiency.json#criteria.1`), which by policy forced `BLOCKED`.

**Evidence + mechanism (observed, three independent causes).**

1. Cadence: `observer/effect/capture-pre.sh:79` `sleep 10` against a ~10 s fail-closed window.
2. Wrong source: `capture-pre.sh:23` gates on the tracker's `status.latestCheckpoint.name`, visible at 04:28:19Z, while libvirt created the checkpoint at 04:27:24Z (`observer/PRESERVED.json#bitmap_present_before_removal.gap_explanation`).
3. Read path: `capture-pre.sh:28` execs into the launcher `compute` container, which is replaced by the restart.

Compounding contract defect: the per-run observer contract mandates these artifacts **at the ARMED handoff**, when the VM and the checkpoint do not yet exist — unsatisfiable as written, so the worker substituted a sampling loop. The generic template (`cbt-chaos/contracts/observer.md:72-77`) mandates only the checkpoint-tree capture.

**Fix.** M3: two-stage witness in the observer template (ARMED = selectors only; window = blocking read + `observer/effect/PRE-READY`), the rendezvous in the trigger (`trigger/surgery-target.json` published before the mutation, removal refused until a ≤60 s-old witness exists, else exit 7), the `contracts/trigger.md` rule, and the v2 `capture-pre.sh` loop (handshake-driven cadence, libvirt/handshake-side checkpoint resolution, stop on observed removal). Also the negative-claims rule (see H-07).

**Definition of done.** Re-run: `qmp-bitmaps-pre.json` names the checkpoint; `PRE-READY` within 60 s of `qmp-remove-result.txt`'s mtime; `PRE-STATE WITNESS:` appears in the trigger log before `Bitmap … confirmed on vdb. Removing`.

---

## H-04 — no pass-adding path preserves the failed pass's evidence · severity **high**

**Observed.** `recovery/step3-extend.log`: `Cannot extend VM vm-20261016-exp06-r02: lifecycle status is verification_failed; run TYPE=verify VM=vm-20261016-exp06-r02 successfully before extending.` (exit 2); `recovery/recovery-report.json#steps[2]` = `branch: REFUSED-BY-WORKFLOW`, `created:false`; no `-p02` object or PVC. Criterion C5 was therefore `UNKNOWN` **by construction**, and the same-VM follow-up had to be run outside the workflow (human-approved).

**Code (observed).** `scripts/vm-cbt-extend.sh:122-135` refuses any status except `complete`; `scripts/vm-cbt-extend.sh:22-40` (`check_target_resources_absent`) refuses while the target pass's CR/PVC exist; `scripts/vm-cbt-backup.sh:35-39` requires `incremental_ready`; `scripts/vm-cbt-reconcile.sh:51-61` refuses to reconcile **until the operator has already deleted** the failed CR *and* PVC; the deletion is a documented manual step (`docs/vm-cbt-workflow.md:96-99`). **Correction to the run's own wording:** `reject-reasons.tsv` row 3 and `same-vm-followup.sh:5-7` say reconcile "deletes the failed pass's backup CR and PVC" — no code deletes anything (`scripts/vm-cbt-reconcile.sh:13-14`: "this script never deletes anything"); the human/operator does, as the doc's step 1 requires. The practical consequence is identical and equally bad: the only route to a new pass destroys the evidence the recovery contract forbids destroying.

**Fix (options — the trade-off is a human decision, so no diff is proposed).**
1. *Preferred*: a `TYPE=extend` variant that first writes a preserved copy of the failed pass (CR manifest + PVC manifest + status) into `recovery/` and records `evidence_snapshot:` in `run.json`, then allows the extension while the failed CR/PVC are still present (new pass name from `EXTEND_TO_PASS`).
2. *Minimal*: make the reconcile gate accept an operator-supplied evidence snapshot path (`EVIDENCE_SNAPSHOT=<file>`) as the precondition for `incremental_failed`+target-absent, so the deletion is acknowledged evidence-preserving rather than implicit.
3. *Cheapest*: the harness performs the same-VM follow-up through an explicit, documented direct-API path (as r02's follow-up did, with approval), and C5's contract text is amended to say so — leaving the workflow behaviour unchanged but no longer claiming C5 is reachable through it.

**Also required either way.** Fix the wording in H-14 and in any recovery contract that repeats it.

---

## H-05 — `trigger-exit-status-hardcoded` · severity **low**

**Observed.** `trigger/exit-statuses.json` → `"control_full_status": 0` is a literal inside the writer's jq program (`chaos-trigger.sh:519-532`, the literal at `:528`); the real shell variable exists (`:257`, `:259`), is logged (`:261` "Leg A full+incremental+verify status: 0"), and aborts on non-zero (`:264-266`), but is never passed to jq. Self-reported: `trigger/run-notes.md#anomalies 2`; corroborated by `checkers/verdict.json#harness_findings[7]`. The evaluator reads this family of fields, so a hardcoded success is a false attestation (here it happens to be true only because a non-zero status aborts before the write).

**Fix.** M4-b (same jq invocation as M1-c): `--argjson control_status "$control_full_status"` + `control_full_status: $control_status`.

---

## H-06 — observer gate double-counts ready files · severity **low**

**Observed.** `trigger.log:88` / `:93`: `OBSERVER GATE (pre-surgery): 14 ready file(s) verified live via …/observer/ARMED.` for 7 watches (7 `*.ready` files; `observer/ARMED` lists the same 7 — `observer/ARMED.json:13` self-documents the overlap). Code: `chaos-trigger.sh:145` seeds from `ARMED.required_ready_files`, `:146-148` appends the same files from the `*.ready` glob with no dedup, `:164` prints `${#ready_files[@]}`. Self-reported `trigger/run-notes.md#anomalies 1`; `checkers/verdict.json#harness_findings[8]`. Benign for this run (the Lead independently verified PIDs), but the number is the gate's only quantitative output.

**Related, same surface (observed).** `observer/watches/pids.json` enumerates 5 of 7 streams (`checkers/evidence-sufficiency.json#criteria/7` flag 1).

**Fix.** M4-a: dedupe the union (`sort -u`) before counting. For `pids.json`, add "`ARMED.required_ready_files` and `pids.json` must enumerate the same set" to the observer contract's PRESERVED checklist.

---

## H-07 — observer's false negative claim about the virt-handler log · severity **medium**

**Observed.** `observer/finding.md:69` says "…no virt-handler line…" about the drop, while the run's own captured `observer/effect/virt-handler-window.log` holds 20 such lines (the analysis §2 records 20 `lifecycle.go:375` lines carrying the same `virError(Code=109) … for disk 'vdb'` text, first 04:29:29.102506Z). Flagged twice by the grading side: `checkers/verdict.json#harness_findings[9]`, `checkers/evidence-sufficiency.json#false_positive_risks/9`. The observer's evidence contradicts its own summary — a reader who trusts `finding.md` would conclude the drop was silent in the node-side handler too.

**Fix.** M3-a's negative-claims rule: any "no X" statement must carry `observer/effect/negatives.json` `{claim, command, paths[], window_utc, count}`. No artifact is edited (the pack is frozen).

---

## H-08 — `write-run-summary.sh` reports a CBT state that was never verified · severity **medium**

**Observed (code).** `scripts/write-run-summary.sh:161-164`: `vm_state` is `"Enabled"`/`"NotEnabled"` only if `report.verification.checks[]` contains `vm_cbt_is_enabled`; otherwise `"PENDING"` — a word that sits next to `cbt.status` and reads as a CBT state, while the script performs no live read at all (its inputs are `run.json` + `report.json`). The consumer degrades silently: `cbt-chaos/scenario-verdict.sh:731-733` reads `.cbt.vm_state` and `check_cbt_recovered` accepts only the literal `"Enabled"`, else `UNKNOWN`.

**Premise correction (observed).** In this run the field is **`"Enabled"`**, not `PENDING`, in both on-disk summaries (`runs/20261016-exp06-r02/summary.json`, `recovery/summary.json.after`), because the verify stage wrote its fragment before failing (`runs/20261016-exp06-r02/fragments/verify.json`: `vm_cbt_is_enabled: passed=true`). `checkers/verdict.json#harness_findings[6]` ("reports cbt.vm_state=PENDING when the lifecycle verification never ran, which … pushed the evaluator's cbt-recovered check to UNKNOWN") is therefore **not reproducible against the pack as delivered**; [INFERENCE] it refers to an intermediate `summary.json` snapshot that was regenerated in place. The defect is real in code, latent in this run; the *claim* about this run should be corrected in the findings text.

**Fix.** M4-f: emit `"UNVERIFIED"` + `vm_state_source` instead of `"PENDING"`, and let the evaluator corroborate an unverified state from the observer's own live read (`observer/effect/post-vmi-cbt.json` → `status.changedBlockTracking.state`).

---

## H-09 — preflight capacity measured on the pool's parent filesystem · severity **high**

**Observed.** `preflight/GO-NO-GO.json#capacity`: `"filesystem": "/dev/sda4 (xfs) mounted /var/hpvolumes"`, `free_gib 309.53`, `measured_with: "oc exec -n openshift-cnv hostpath-provisioner-csi-w5x4k -c hostpath-provisioner -- df -B1 /cbt-demo-pool-data-dir"`; `preflight/report.md:24` repeats it and its "cross-check" (`df -B1 /host/var/hpvolumes`) re-measures the same parent. The PVCs live in the nested `/var/hpvolumes/csi` = `/cbt-demo-pool-data-dir/csi` on `/dev/sdb`: real free 140.0 GiB at 04:19Z (`ledger.jsonl` ev 14) and 40.25 GiB by 05:35Z (`followup/20261016-exp06-r02-same-vm/f3-result.json#pool_free_before_bytes 43215937536`). Error: ~170 GiB overstated; the margin table (`margin_gib 234.53`) was fiction. `checkers/verdict.json#harness_findings[4]`; the same class is already canonical (`cbt-chaos/scenarios_v2/CBT-I-04/chaos-trigger.sh:104`, `.agents/skills/cbt-chaos-run/cbt-chaos-run-learnings.md:77` — "stat /var/hpvolumes/csi … NOT /var/hpvolumes (the parent on /dev/sda4 shows wrong free space — masked a 98%-full pool once)"), and this scenario's own follow-up driver measures it correctly (`same-vm-followup.sh:71-80`).

**Why it matters beyond the number.** Together with the ~2.5× low write estimate (`checkers/verdict.json#harness_findings[5]`: the rootdisk clone fully materialises 80 GiB and the full-backup PVC holds a fully allocated ~80 GiB qcow2), the bad measurement is what made the forced-full same-VM alternative unaffordable *after* the fact, and it is what currently blocks the follow-up's tracker-reset leg.

**Fix.** M4-d: the preflight template and worker skill must name the exact command and the nested path (and record `filesystem` as device **and** mount), with the floor judged on that filesystem; plus the in-run floor guard for this scenario's trigger (it has none today — `grep` for `capacity|free|df |space` over `chaos-trigger.sh` = 0 matches, while siblings guard at 300-400 GiB).

---

## H-10 — platform version never captured · severity **medium**

**Observed.** `preflight/GO-NO-GO.json` has no `clusterversion`, no KubeVirt `status.observedVersion`, no launcher image digest; the only version-shaped facts are the CSV name and pod labels ("csv kubevirt-hyperconverged-operator.v4.22.12 = spec's live CNV 4.22.12" in the `environment_tools_feature_gate_namespace` check, `observer/effect/baseline-cnv-pods.json:112`) and `virsh --version -> 11.10.0`. The trigger captures nothing either (`grep -nE 'version|csv|clusterversion' chaos-trigger.sh` = 0 matches). Yet the scenario's hypothesis asserts a version **pair** (`scenario-spec.md:6`; `chaos-trigger.sh:3`: "source-verified kubevirt v1.8.4 = live CNV 4.22.12") and nothing verifies `1.8.4`. Consequence recorded by the report checker: `checkers/report-fidelity.json` — "The OpenShift version row is explicitly UNKNOWN rather than filled with a plausible value."

**Fix.** M4-e: a mandatory `platform_versions` block in the preflight contract + skill (ClusterVersion, KubeVirt `observedVersion`, CSV, launcher image), and a report rule that a versioned hypothesis cites that block, not the spec's claim.

---

## H-11 — follow-up driver reports a phantom CR removal · severity **low**

**Observed.** `followup/20261016-exp06-r02-same-vm/followup.log:9-10` are adjacent and contradictory: `F1 test backup was NOT admitted (rejected): see f1-apply.out` then `F1 cleanup: test CR removed in 0s (runbook row: delete wedged CR with tracker present -> works).` The apply was rejected at admission (`f1-apply.out`: `The request is invalid: spec.source: VirtualMachineBackup "vm-incremental-20261016-exp06-r02-p01" in progress for source`, exit 1) so the CR never existed; `f1-delete-cr.out` contains only a PVC deletion. Mechanism: `same-vm-followup.sh:188-190`'s wait loop breaks on the first `oc get` (CR absent) and the `else` branch (`:195`) asserts the runbook row.

**Fix.** M4-c: only claim the runbook row when a CR existed immediately before the delete, and record the not-exercised case explicitly.

---

## H-12 — a non-terminal product object has no recorded outcome · severity **high**

**Observed.** `make e2e TYPE=incremental` returned after `20m 35s` with `error: timed out waiting for the condition on virtualmachinebackups/vm-incremental-20261016-exp06-r02-p01` (`trigger/trigger.log:143-152`); the harness marked the pass `failed` (`run.json#current_incremental_pass.status`, `failed_at 04:49:27Z`) while the CR itself carries no failure, no `type`, no `Done` (`trigger/legB-incremental-backup.yaml#status`; `observer/FINAL.json#runtime_checks_at_final_utc.p01`). The trigger read the CR once and printed `type=? Done=? includedVolumes=?` (`trigger.log:158`); `trigger/run-notes.md#anomalies 4` records 0 grep matches for any classification line. The 20-minute bound is a literal (`scripts/common.sh:1037,1046` `--timeout=20m`), and the workflow's watcher terminates only on `Done=True` (`scripts/common.sh:1024-1027`) with no `Failed` branch. Effect: a stall and a detected failure are indistinguishable in the trigger's artifacts, which is one of the reasons the affected pass's criterion graded `UNKNOWN`.

**Fix.** M1-c: record `terminal`, `waited_seconds` and `pass_wait_bound_seconds` in `trigger/exit-statuses.json`, and emit a `STALLED NON-TERMINAL: …` line; the evaluator's `affected-pass-outcome` check (M1-b) then has something modelled to read. Optional follow-on: make the bound a variable (`BACKUP_DONE_TIMEOUT`, default `20m`).

---

## H-13 — run-root pushed from the workstation truncates the ledger / leaves a stale mirror · severity **medium**

**Observed (in-run).** `ledger.jsonl` ev 3 (`ledger_recovered`): "ledger.jsonl was truncated when the Lead pushed the local (empty) ledger over the remote one" — six events lost and re-appended as reconstructions (`reject-reasons.tsv` row 7). **Observed (post-close, new):** the workstation mirror of this run diverges from the remote — 37 vs 42 ledger lines, pre-checker 151-file index vs the 157-file one, and `pack-validate.sh` fails 5 ways locally (see H-02's second facet). `sync.sh` itself is safe (`sync.sh:92-93` excludes `cbt-chaos/scenarios_v2/*/runs/`), so the loss came from a hand-rolled rsync in both cases.

**Fix.** M4-g: team SKILL rule — never push a run root (only `make pull-reports`, remote → local, after `closed`), and require `cbt-chaos/pack-validate.sh <pulled run-root>` exit 0 on the mirror; "if it fails, the mirror is not evidence — re-pull, never re-push".

---

## H-14 — harness prose asserts a deletion the code refuses to perform · severity **low**

**Observed.** `same-vm-followup.sh:5-7` and `reject-reasons.tsv` row 3 state that the staged interface's "only documented unblock (`reconcile`) deletes the failed pass's backup CR and PVC". The code says the opposite: `scripts/vm-cbt-reconcile.sh:13-14` — "the caller must delete them first, preserving evidence out-of-band; this script never deletes anything" — and `:51-61` refuses until they are already gone; `docs/vm-cbt-workflow.md:96-99` puts the deletion in the operator's hands. The wrong claim survived into the run's reject index and the follow-up's own header, i.e. the next reader inherits a false model of who destroys evidence.

**Fix.** Correct the wording at every reuse site (recovery-contract template, `docs/vm-cbt-workflow.md`, any future `reject-reasons.tsv` line, the follow-up driver header) to: "requires the operator to delete the failed pass's CR **and** PVC before reconciling (the script never deletes; the workflow offers no pass-adding path that preserves them)". Add a rule: any claim about what a script does must cite the script (file:line), the same way a claim about product behaviour must cite an artifact.

---

## Not harness tickets (for the product / bug track)

- **P1 non-terminal stall** and **P2 silent per-disk checkpoint drop + tracker divergence**: recorded in `checkers/verdict.json#product_findings` and `analysis/20261016-exp06-r02.md` §5.1, with 3 reproductions of the livelock now available (`docs/findings/finding-1-backup-cr-livelock.md` Path A; r02 `p01`; follow-up `p02`). The harness tickets above only stop the harness from hiding it.
- **The `Code=113` guest fsfreeze failure on `/mnt/datadisk`** (P4 in the analysis): unresolved by this run; needs a guest/mount decision before the next control leg can be called cleanly frozen.

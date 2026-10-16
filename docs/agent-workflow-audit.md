# Agent workflow audit — capability matrix, delegation map, baselines

Phase 0 deliverable of `virt-cbt-lab-consolidated-agent-improvement-plan.md`
(plan §5 "script audit deliverable", §10 Phase 0, §11 metrics).

Audit date: 2026-10-16. Method: read-only inspection of the checkout at
`0398433` (`perf(e2e): cut e2e wall time ~40% and consolidate pipeline
stages`) plus the execution host's `runs/` artifacts. Every claim cites a file
and line. Where a claim comes from a run artifact it cites the run id and log.

This document is the shared contract the skills link to instead of restating
the Makefile. Keep it current when stages, exit codes, or artifacts change.

**Authority:** the skills under `.agents/skills/` are normative — they carry the
rules an agent must follow (stage selection, deterministic-first policy,
verdict rules, guards, budgets). This document is descriptive reference: the
current capability matrix, delegation map and measured baselines those skills
point at. When the two disagree, the skill is right and this file is stale.

## 1. How a run is driven

```sh
make help            # human-readable commands and constraints
make stage-list      # machine-readable stage table (TSV: stage, target, args, purpose)
make preflight       # read-only readiness gate; run before any individual stage
make e2e TYPE=<all|full|incremental|extend|recover|verify|reconcile> [VM=vm-<id>] [NAME=<id>]
make run-summary RUN_ID=<id>   # deterministic verdict from run artifacts
```

`make` includes `.env`; direct script execution requires exporting it first.

Three interfaces must not be confused:

| Interface | Owner | Notes |
|---|---|---|
| Individual Make targets (`vm-setup`, `vm-backup`, …) | `Makefile` → `scripts/stage.sh <stage>` | Single stage; runs preflight automatically for mutating stages |
| `make e2e TYPE=…` | `scripts/e2e-stage.sh` | Sequence of targets + lock + verdict/summary; **not** the same as the stage table |
| Scenario chaos trigger | `cbt-chaos/scenarios_v2/<id>/chaos-trigger.sh` | Owns injection + its own exit arbitration; *not* a verdict |

`TYPE=full` ends `INCOMPLETE` by design (`scripts/e2e-stage.sh:597-606`): the
lifecycle is incomplete until incremental passes are added. A non-zero `make
e2e` in a chaos scenario can be the expected outcome; the verdict comes from
artifacts, never from the exit status alone.

## 2. Capability matrix

"R" = read-only with respect to the cluster, "M" = mutating.

| Entry point | Purpose | Inputs | Outputs | Exit codes | R/W | Retry / timeout / cleanup | Test | Proves — does NOT prove | **Skill / agent that invokes it** |
|---|---|---|---|---|---|---|---|---|---|
| `make preflight` → `stage.sh preflight` → `./preflight` (`Makefile:33-34`, `stage.sh:302`) | Readiness gate (7 sections) | `.env`, kubeconfig, `VM_OS` | stdout summary, no artifacts | 0 READY, 1 NOT READY, 2 usage/internal (`preflight:421-427,30-33`) | R | none; `mktemp -d` + EXIT trap | none (only a policy stub in `test-stage-dispatch.sh:102-109`) | Prerequisites only — **not** that a backup will succeed | `cbt-chaos-preflight-worker` (GO/NO-GO), Lead in `cbt-chaos-run` / `cbt-chaos-team` |
| `make vm-setup` / `make windows-vm-setup` (`Makefile:47-49,131-132`) | Create lifecycle + baseline workload | `VM_OS`, `MANIFEST_VARIANT`, `GUEST_*`, `RUN_ID`/`NAME` | `runs/<id>/{run.json,workload-manifest.json,fragments/setup.json,logs/workflow.log}`, cluster VM/DV/svc | 0, 1 (CBT not enabled), 2 (bad/duplicate id) | M | `oc wait dv/pvc/vm --timeout=20m` (`vm-setup.sh:18-19,32-34,78-80`); guest-SSH loop 30 attempts (`common.sh:746-813`); no cleanup on failure | adoption path only (`test-existing-vm-adoption.sh`) | VM exists, CBT `Enabled`, baseline written+hashed — not that a backup exists | Lead in `cbt-chaos-run`; stage choice by `cbt-chaos-issue-triage` |
| `make vm-backup RUN_ID=<id>` (`Makefile:52-54`) | Full backup + tracker + CBT enable | existing `runs/<id>/run.json` (else exit 2, `stage.sh:263-274`) | `run.json`, `fragments/full-backup.json` | 0, 1 backup failed (`vm-backup.sh:103-107`), 2 no lifecycle | M | `oc wait vmbackup … Done --timeout=20m` + 2 s watcher (`common.sh:1031-1054`) | `test-vm-backup-failure-recording.sh` | Full backup `Done=True` with a good reason — not restorability | Lead in `cbt-chaos-run`; the scenario `chaos-trigger.sh` runs it for a full-backup leg |
| `make vm-cbt-backup RUN_ID=<id>` | One incremental pass | lifecycle at `incremental_ready`, pass count matches plan (`vm-cbt-backup.sh:14-22`) | `fragments/*`, `run.json` | 0, 1 (plan complete → use `TYPE=extend`; wrong state) | M | tracker poll 20 × 1 s (`:47-60`); backup wait as above | fake-make orchestration only | Guest mutation + inventory match, backup Done, tracker advanced — not restore | Lead in `cbt-chaos-run` |
| `make vm-cbt-extend RUN_ID=<id> EXTEND_TO_PASS=N` | Add one planned pass | `EXTEND_TO_PASS` 2..99 (`stage.sh:276-288`) | `run.json` plan | 0, 1 | M | none | `test-vm-cbt-extend.sh` | Plan arithmetic + resource-absence guard — does not run a backup | Lead in `cbt-chaos-run` (only when the planned lifecycle requires one more pass) |
| `make vm-cbt-recover RUN_ID=<id>` | Same-VM forced full through the existing tracker + baseline restore | failed full recorded in `run.json` | `run.json recovery.attempts[]`, fragments | 0, 1, `blocked` ⇒ e2e exit 3 (`e2e-stage.sh:496-505,648`) | M | bounded pre-recovery readiness wait (`RECOVERY_READY_TIMEOUT_SECONDS`, default 300 s: VM Ready + VMI Running + CBT Enabled) then PVC `--timeout=20m` (`vm-cbt-recover.sh:274-275`); tracker poll 30 × 2 s (`:318-323`) | `test-vm-cbt-recover.sh` | One recovery attempt's terminal status (+ baseline restore) | `cbt-chaos-recovery-worker` (Lead-authorized), Lead in `cbt-chaos-run` |
| `make vm-cbt-reconcile RUN_ID=<id>` | Reset failed incremental → `incremental_ready` | failed pass + deleted resources | `run.json` status | 0 / 1 | M | none documented | none | Tracker/state reconcile | Lead in `cbt-chaos-run` (state-machine exit from a failed incremental) |
| `make vm-cbt-verify RUN_ID=<id>` | CBT chain + restore verification, merges `report.json` | existing lifecycle | `report.json`, `summary.json`, `logs/*` | 0, 1 (`vm-cbt-verify.sh:186`) | R on API, M on artifacts, creates/deletes pod | verifier pod poll 1 s ≤1800 s (`restore-lib.sh:15,95-101`), pod deleted on RETURN trap | `test-restore-failure-propagation.sh`, `test-restore-timeout.sh` | Chain + SHA-256 restore match — **not** qcow2 allocation maps | Lead in `cbt-chaos-run`; `cbt-chaos-evidence-checker` reads its `report.json`/`summary.json` |
| `make vm-cbt-restore-test RUN_ID=<id>` | Disk reconstruction only | `RESTORE_HELPER_IMAGE` (else exit 1, `restore-lib.sh:17-22`) | `fragments/restore-test.json`, pod log | 0 / 1 | M (pod) / R (API) | as above | mock-level only | Reconstructed file sets/hashes | `cbt-chaos-recovery-worker`, Lead in `cbt-chaos-run` |
| `make monitor RUN_ID=<id>` | API-recorded backup timings | `run.json` | `fragments/backup-timings.json`, `run.json .backup_timings` | 0, 1 usage/missing lifecycle/failed backup (`monitor.sh:17-32,244-247`), 2 timeout (`monitor.sh:231-242`) | R cluster / M artifacts | poll 2 s; bounded by `MONITOR_TIMEOUT_SECONDS` (default 1800, 0 unbounded) (`monitor.sh:68-78,223-226`) | `test-monitor-planned-backups.sh`, `test-monitor-timeout.sh` | Durations are `lastTransitionTime(Done) − creationTimestamp`, whole-second resolution | `cbt-chaos-observer-worker` (timings), Lead (per-leg duration) |
| `make run-summary RUN_ID=<id>` | Deterministic verdict from artifacts | readable `run.json` | `runs/<id>/summary.json` | 0, 1 missing `run.json`, 2 bad id | R | atomic tmp+mv (`write-run-summary.sh:26-27,246-247`) | `test-run-summary.sh` | Compact verdict + evidence fields — not disk/qcow2 inspection | Lead in `cbt-chaos-run`, `cbt-chaos-evidence-checker`, `cbt-chaos-report-writer` |
| `make stage-list` | Machine-readable stage table | none (no kubeconfig) | TSV on stdout | 0 | R | none | `test-stage-dispatch.sh:159-205` | The documented interface | every skill that selects a stage (§12.1) |
| `make e2e [TYPE=…]` | Pipeline orchestrator | `TYPE`, `VM`/`NAME` (`e2e-stage.sh:345-362`) | `workflow.log` (`Step timing:` lines), `summary.json`, boxed verdict | 0, child code, 2 validation, 3 BLOCKED (`:648`) | M | checkout lock `state/e2e.lock` + EXIT trap (`:379-397`) | `test-incremental-passes.sh`, `test-vm-cbt-recover.sh` | Pipeline outcome — not the product verdict | Lead in `cbt-chaos-run`; scenario triggers built by `cbt-chaos-issue-triage`; `cbt-chaos-team` for a matrix leg |
| `make clean-all` | Delete managed resources | namespace; E2E lock must be free | deletions | 0, 1 (lock held / PVs unreclaimed) | M destructive | `oc delete --wait --timeout=10m`; PV poll 60 × 2 s | none | Explicit cleanup only; **never** routine triage | none — explicit human/ops action only (`cbt-chaos-run`, `cbt-chaos-issue-triage` and the role skills prohibit it) |
| `make density-setup` / `density-status` | VM pool create / fleet view | `DENSITY_VM_COUNT`, `POOL`, `VM_OS` | pool VMs with `virt-cbt-lab/*` labels | 0 / 1 | M / R | readiness poll 30 s, default 240 min (`density-lib.sh:111-129`) | `test-density-setup.sh`, `test-density-status.sh` | Pool state read from the cluster, no local metadata | `make density-status` is read-only pool context for the Lead; `density-setup` is ops-only |
| `cbt-chaos/watch-resource.sh` | Authenticated single-resource watch + readiness gate | 6 args, kubeconfig, optional `WATCH_MAX_SECONDS` (`:41-45`) | `<out>.jsonl`, `.baseline.json`, `.stderr`, `<ready>` marker | 0 (killed), 1 preflight/auth/startup/watch ended, 2 usage/invalid `WATCH_MAX_SECONDS`, 3 `WATCH_MAX_SECONDS` reached, 127 no `oc` (`:5-8`) | R | 10 × 0.1 s startup health check; never reconnects; revokes readiness on exit; self-terminates at `WATCH_MAX_SECONDS` (default 0 = no bound, `:101-113`) | `test-chaos-watch-resource.sh` | A watch was armed in an authenticated child — not that a future signal will be observed | `cbt-chaos-observer-worker` |
| `cbt-chaos/scenario-verdict.sh` (new) | Deterministic scenario verdict from artifacts | scenario dir, run ids | JSON verdict + per-check statuses | 0 PASS, 1 other verdict, 2 usage | R | none; missing evidence ⇒ UNKNOWN | `test-scenario-verdict.sh` | Criterion-level verdict from recorded evidence — not physical qcow2 allocation | Lead in `cbt-chaos-run`/`cbt-chaos-team`; `cbt-chaos-injection-checker`, `cbt-chaos-evidence-checker`, `cbt-chaos-report-writer` |
| **Scenario chaos trigger** — `cbt-chaos/scenarios_v2/<id>/chaos-trigger.sh` (plus the optional `run-<id>.sh` driver for CBT-F-01, next row) | Arm the observer, detect the active-copy signal, execute the one approved disruption, preserve every exit status (`:442`; arbitration tail `:455-457`) | `RUN_ID` (fallback derived from the current UTC time so a forgotten id cannot silently reuse an existing run, `:30`), lifecycle `NAME`/`LIFECYCLE_ID` (`:31`), `KUBECONFIG_PATH` (never printed or persisted — the planned argv carries a placeholder substituted only at exec time, `:36-37,43,52-56,170-172`); `--plan` rehearses without contacting the cluster (`:46-167`, incl. the pre-armed-directory rule at `:97-134`) | `cbt-chaos/scenarios_v2/<id>/runs/<RUN_ID>/trigger/{command.txt,action-request.json,effect-check.json,exit-statuses.json,trigger.log}` (`:35,233,249-251,386,442`) | 0 clean; 1 collision/local-guard failure (`:138,176,181,188`) or the E2E unexpectedly succeeding after an injection was requested (`:455`); 2 usage/unknown arg (`:22`) | M (cluster: deletes the launcher pod) + R checks | observer deadline 3600 s waiting for baseline+signal (`:160,342`); no cleanup of its own | `test-cbt-f-01-injection-evidence.sh`, `test-trigger-plan-rehearsal.sh` | An attempt was made and recorded — **not** that the injection was valid or that the target was the correct component; the evaluator decides that | `cbt-chaos-trigger-worker` |
| **CBT-F-01 driver** — `cbt-chaos/scenarios_v2/CBT-F-01/run-cbt-f-01.sh` | Run the three contractual legs in contract order (interrupted full, same-VM recovery, clean lifecycle), record one timing line per leg (including the evaluator leg), then invoke the evaluator | `RUN_ID`/`KUBECONFIG_PATH` required (`:21-22`); `CLEAN_RUN_ID` derived (`:25-26`); `TRIGGER_SCRIPT` overridable for offline runs (`:32`) | `runs/<RUN_ID>/driver-timings.json` (`.legs[]`), `verdict.json`, `driver.log` (`:30,79-88,137-145`) | 2 usage/missing command (`:37-43`); otherwise the evaluator's status — 0 only for PASS (`:147`) | M (drives mutating legs) | no timeout of its own; legs 2-4 record status and never abort the driver so the verdict is always produced (`:124-127`) | `test-cbt-f-01-driver.sh` | The scenario ran in contract order and the evaluator's verdict is recorded — not the physical qcow2 result | Lead in `cbt-chaos-run` |
| **Evidence index generator** — `cbt-chaos/evidence-index.sh <run-root>` | Regenerate the Lead-owned manifest the checkers grade against: every file under the run root with its sha256 and byte count (the index itself, any `evidence-index.json*` temp and `.git` excluded) | `<run-root>` holding `ledger.jsonl`/`state.json`; run id read from `state.json .run_id`, else the directory name | `<run-root>/evidence-index.json` (atomic `tmp`+`mv`), `{"schema_version","run_id","generated_utc","files":{path:{sha256,bytes}}}`; progress line on stdout | 0 written; 1 absent/unreadable run root, no files, or a hashing failure; 2 usage; 127 missing `jq`/`find`/`sha256sum`+`shasum` | R | writes one file; refuses an empty index | `test-evidence-index.sh` | Index integrity and ordering only — it does not judge whether the indexed evidence is sufficient, and it must run after every writer stops (`pack-validate.sh` rules 3-5 enforce "index is the last write") | Lead in `cbt-chaos-team`, before spawning checkers |
| **Run-ledger helpers** — `cbt-chaos/ledger-append.sh`, `cbt-chaos/pack-validate.sh <run-root>` | Append-only validated ledger write (jq-escaped; refuses a line that does not parse, `ledger-append.sh:52-60`); pack pre-flight validation before checkers spawn (ledger JSON validity, state/ledger phase agreement, indexed sha256s, index-vs-file mtimes; `pack-validate.sh:12-30`) | `<ledger.jsonl> <actor> <event> <phase> [detail] [ref...]`, where `phase` may be `-` to omit that field (`ledger-append.sh:9-10`); `<run-root>` containing `ledger.jsonl`/`state.json`/`evidence-index.json` | one appended JSON line + `ledger-append: ok`; pack report on stdout/stderr (`pack-validate.sh:44`) | ledger-append 0/1/2 (`:16,53,60`); pack-validate 0 valid / 1 failures / 2 usage (`:17-19`) | M (ledger) / R (pack) | none | none | A write is valid JSON and the pack is internally consistent — not that the evidence is sufficient or the verdict is right | Lead in `cbt-chaos-team` |
| **Contract generator** — `cbt-chaos/contract-gen.sh <scenario-id> <run-root>` | Substitute `__RUN_ID__`-style tokens (`__VM_NAME__`, `__FULL_BACKUP__`, `__TRACKER__`, `__NAMESPACE__`, …) from `cbt-chaos/contracts/*.md` into per-run role contracts | scenario id, run root; `NAMESPACE`/`CTRL_NAMESPACE`/`REMOTE_HOST`/`REMOTE_DIR` defaults (`:30-35`) | `<run-root>/contracts/<role>.md` (`:36-49`) | 0 written / 2 usage (`:17-18`) | M (artifacts only, no cluster contact) | none | none | Contract issuance is one templated command — the templates are CBT-F-04 worded (G11), so they are not a documented cross-scenario contract | Lead in `cbt-chaos-team` |
| **Shared stage helpers** — `scripts/run-id.sh`, `scripts/dotenv.sh`, `scripts/workload-manifest.sh` | Identity resolution/validation (`run-id.sh:5-12`), `.env` loading without executing the file (`dotenv.sh:3-14`), workload manifest + hash generation (`workload-manifest.sh:1-12`) | sourced by the calling stage script; `.env` path; `REPORT_DIR` | derived run/resource names; exported environment defaults; `workload-manifest.json` + sha256s | the sourcing shell's status (no independent exit contract) | R (no cluster contact) / M when it writes the manifest | none | exercised indirectly by the stage tests | Shared plumbing the stage scripts depend on — not an entry point an agent invokes directly | none — invoked by the stage scripts, not by a skill |
| **Windows profile scripts** — `scripts/windows-vm-setup.sh`, `windows-golden-image-setup.sh`, `windows-oobe-secret.sh`, `windows-guest-agent.sh` (+ the `.ps1`/`.tmpl` payloads) | Build and seed the Windows profile: golden image, shared OOBE secret, guest-agent command transport, Windows VM + baseline workload | `WINDOWS_ISO_PATH`, `WINDOWS_ADMIN_PASSWORD_FILE`, `GUEST_*`, `MANIFEST_VARIANT` (`Makefile:128-132`) | Windows VM/DV/svc, `runs/<id>/*`, golden-image artifacts | as the `windows-*` targets (0 / 1) | M | `GUEST_EXEC_POLL_ATTEMPTS` retry budget absorbs a guest-agent outage during Windows boot (`windows-guest-agent.sh:8-13`) | none targeted at the agentic flow | A Windows VM exists and its baseline is written — this profile is **outside the agentic CBT flow** (the Windows variant is a separate, much slower configuration; see §3) | the `windows-*` Make targets; no skill in the CBT flow |
| **Density scripts** — `scripts/density-setup.sh`, `density-status.sh`, `density-lib.sh` | Pool create (kube-burner bare VMs, `density-setup.sh:4-8`) / read-only fleet view (grouped funnel, `density-status.sh:4-7`) / shared label + readiness helpers (`density-lib.sh:1-9`) | `DENSITY_VM_COUNT`, `POOL`, `VM_OS`; cluster labels `virt-cbt-lab/*` | pool VMs with `virt-cbt-lab/*` labels; funnel rows/JSON on stdout | 0 / 1 | M (setup) / R (status) | readiness poll 30 s, default 240 min (`density-lib.sh:111-129`) | `test-density-setup.sh`, `test-density-status.sh` | Pool state read from the cluster (no local metadata) — not that a pool VM is backup-ready | `make density-status` is read-only pool context for the Lead; `density-setup` is ops-only |

Input conventions: non-`make` stages accept `RUN_ID` or `VM=vm-<id>`
(`stage.sh:167-189`); `setup` also accepts `NAME=` (`:191-205`);
`STAGE_DRY_RUN=true` resolves identity and prints the exact argv without
touching the cluster (`:404-441`); `STAGE_SKIP_PREFLIGHT=true` skips the
automatic preflight for mutating stages (`:520-525`) and is prohibited by the
skills unless a reviewed workflow justifies it.

## 3. Where wall clock actually goes

Measured from `runs/<id>/logs/workflow.log` (`Step timing:` lines written by
`run_profiled_make`, `scripts/e2e-stage.sh:321-343`).

| Leg | Command | RHEL 9 observed | Windows observed |
|---|---|---|---|
| Interrupted leg | `make e2e TYPE=full NAME=<id>` | 113 s setup + 24 s backup (`runs/20261012-cbtf01-r01`) | 2133 s setup + 27 s backup (`runs/20261010-cbt-f-01-r08`) |
| Same-VM recovery | `make e2e TYPE=recover VM=vm-<id>` | 175 s | 110 s |
| Clean lifecycle | `make e2e TYPE=all NAME=<new>` | 572 s (setup 107 + full 76 + incremental 147 + verify/restore 242) | 574 s in one attempt; 4310 s in another (incremental mutation failed, exit 141) |
| Fastest recent full lifecycle | `make e2e TYPE=all` | 20:11:41 → 20:18:05 ≈ 6.4 min (`runs/20261015201141-bright-tiger-c824`; full 73 s, incremental 19 s) | — |
| Iteration 1 of this change set | driver leg 1 (`chaos-trigger.sh`) | 21:03:00 → 21:05:04 = **124 s** (setup 98 s to the backup apply, copy window opens 21:04:50, signal 21:04:51, pod replaced by 21:05:10, backup terminal 21:05:03) | — |
| Iteration 1 leg 2 | `make e2e TYPE=recover` | **blocked in 2 s** — the VM was still restarting (`vm_ready`/`vmi_running`/`cbt_enabled` failed at 21:05:06, replacement Ready 21:05:10) | — |

Dominant costs, in order: VM boot + guest readiness, the full copy itself,
restore-verification (242 s), incremental guest mutation, and — in the Windows
variant — a guest-agent outage that the setup stage absorbs with a
`GUEST_EXEC_POLL_ATTEMPTS` retry budget (`runs/20261010-cbt-f-01-r08`: 32 min
of `QEMU Guest Agent status query failed … attempt N/900`).

Non-harness time in the recorded Windows run: observers stopped 18:41, the
scenario report was written at 19:16 — ≈35 min of agent-side work after the
test was terminal. That is the part the plan's "script-first report /
one monitor agent / bounded evidence analysis" rules target.

## 4. Delegation map (as implemented today)

| Agent | Spawned when | Contract | Mutating? | Handoffs |
|---|---|---|---|---|
| read-only monitoring subagent | before the trigger, after `make resync` (`SKILL.md:126`) | scenario id, objective/window from the issue+spec, `RUN_ID`, namespace, resolved selector, expected component, observed query, log locations; verifies the target itself from the spec | no (writes raw output under the run's `observer/`) | `ARMED` → `PRESERVED` → `FINAL` |
| focused skeptical reviewer | only for a novel, high-impact, or contradictory result (`SKILL.md:222`) | criteria + evidence, not told the parent's preferred verdict | no | none |

Everything else the plan's §4 table lists as "keep as a capability" is either
an existing script (verification, summary) or, on `main`, a real skill.

**The team topology exists.** `main` carries the full tree under
`.agents/skills/` (PR #32, `ab93fbe`): 17 skills / ≈2000 lines, including
`cbt-chaos-team` (332 lines, the Lead orchestrator) and 13 role skills
(preflight/observer/trigger/recovery workers, three blind checkers, report
writer, run analyst, scenario improver, flow analyst, variation decider,
krkn preparer). This audit's first pass saw only two skills because the
checkout predated that consolidation — a reminder to resolve "the repo" from a
fetched `main`, not from a stale working tree.

That changes the reading of plan §4: its spawn-reduction advice is **actionable
rather than obsolete**. The 13 roles are judgement/observation roles that must
stay, but every repeated operational check they might perform should route to a
script or Make target instead, and the Lead's own policy (interface, smallest
stage, deterministic-first, spawn economy, timings, guards, bounded work) must
match the single-agent skill. Both are now stated explicitly: see
`cbt-chaos-team/SKILL.md` → "Lead operating policy (stage-aware,
deterministic-first)" and the deterministic-verdict reconciliation in its
execution sequence.

## 5. Gaps found (each is either fixed in this change set or flagged)

| # | Gap | Evidence | Disposition |
|---|---|---|---|
| G1 | Criterion "launcher pod replaced after injection" is printed to stderr only and never affects an artifact or exit status | `chaos-trigger.sh:37-41,59-66` | Fixed: trigger writes `trigger/{action-request,effect-check,exit-statuses}.json` |
| G2 | "Tracker did not advance after the interrupted full" is recorded but never asserted | `vm-cbt-recover.sh:108,182,199,240` | Fixed: asserted by `scenario-verdict.sh` check `tracker-not-advanced` |
| G3 | No deterministic scenario verdict; PASS/FAIL/INVALID/INCONCLUSIVE/BLOCKED exist only as prose | `SKILL.md` verdict sections; no evaluator script | Fixed: `cbt-chaos/scenario-verdict.sh` + `tests/test-scenario-verdict.sh` |
| G4 | Per-stage wall clock lives only as free text in `workflow.log`; `summary.json` has no phase timings | `e2e-stage.sh:334-338`; `write-run-summary.sh` has no `phases` key | Fixed: `.stage_timings` + `.total_elapsed_seconds` persisted, `phases` surfaced |
| G5 | Local `.claude/skills/*` symlinks were broken against this checkout because the worker skills were not present in the tree, while the two live skills hard-referenced `krkn-scenario` / `cbt-chaos-krkn-preparer` as if they must exist | `.claude/skills/` (untracked); `cbt-chaos-run/SKILL.md:88`; `cbt-chaos-issue-triage/SKILL.md:63,65` | Fixed twice over: the skill tree is consolidated under `.agents/skills/` (upstream `ab93fbe`, PR #32), and both live skills now phrase those dependencies conditionally ("if the active harness provides it, otherwise …"), so a missing skill degrades to a documented fallback instead of a dead reference |
| G6 | `make help` advertises `make e2e TYPE=reconcile` but the TYPE validation rejects it (branch unreachable) | `Makefile:156`; `e2e-stage.sh:345-362,487-493` | Fixed: `reconcile` accepted end to end |
| G7 | Skills require only `make help`; `make stage-list`, the `STAGE_SKIP_PREFLIGHT` prohibition, the deterministic verdict and the shared audit doc were missing | `SKILL.md:83`; plan §12 | Fixed in the runner, triage and team (`cbt-chaos-team`) skills |
| G8 | Skills demand a `--plan` trigger rehearsal that no trigger implemented | `cbt-chaos-issue-triage/SKILL.md:98,107`; `tests/test-trigger-plan-rehearsal.sh` | Fixed for the scenarios this review backs: CBT-F-01 (with the pre-armed-directory rule), CBT-I-01 and CBT-F-03 gained `--plan`; the remaining legacy triggers still lack it (per-scenario backfill, see the not-executed record) |
| G9 | `monitor.sh` waits unbounded for planned-but-never-run backups | `monitor.sh:69,210,224`; `tests/test-monitor-timeout.sh` | Fixed: `MONITOR_TIMEOUT_SECONDS` (default 1800; `0` = unbounded opt-in), expiry prints the outstanding backups and exits **2** (`:231-242`); flag F9 fixed |
| G10 | No test refuses destructive `make clean-all` during triage; `./preflight` itself is never executed by a test | `clean-all.sh:6-12`; `test-stage-dispatch.sh:102-109` | Flagged: needs a live-cluster or stubbed preflight harness |
| G11 | `cbt-chaos/contracts/*` are CBT-F-04 worded; `contract-gen.sh` substitutes only `__RUN_ID__` tokens | `contracts/observer.md:5`; `contract-gen.sh:44-54` | Flagged (do not link them as a cross-scenario contract) |
| G12 | Same-VM recovery was invoked ~15 s after the launcher was deleted and blocked on `precondition failed: vm_ready / vmi_running / cbt_enabled`, because the VM is still restarting at that moment | live run `20261016-cbt-f-01-r01`: pod deleted 21:04:51Z, replacement Ready 21:05:10Z, recovery invoked 21:05:06Z → `recovery.attempts[0].blocked_reasons` | Fixed: bounded pre-recovery readiness wait in `vm-cbt-recover.sh` (`RECOVERY_READY_TIMEOUT_SECONDS`), covered by `tests/test-vm-cbt-recover.sh` (fast path + bounded timeout) |

## 6. Prioritized change list (this iteration)

1. `cbt-chaos/scenario-verdict.sh` + `tests/test-scenario-verdict.sh` — G3, G2.
2. CBT-F-01 trigger evidence artifacts + `--plan` + `--since-time` signal gate — G1, G8.
3. `scripts/e2e-stage.sh` + `scripts/write-run-summary.sh` phase timings; `TYPE=reconcile` — G4, G6.
4. Both skills: `make stage-list`, smallest-stage policy, preflight-bypass prohibition, audit-doc link, `--plan`, deterministic-verdict step, dead-reference removal — G5, G7.
5. `docs/agent-workflow-flag.md` — disputes and scoped-out plan items.

Acceptance for each item is recorded in the change itself (offline test or
`bash -n` + a dry run); the live acceptance for the flow is one CBT-F-01
execution judged by `scenario-verdict.sh` and its wall clock.

## 7. Baselines for the plan's §14 before/after report

| Metric | Before | How measured |
|---|---|---|
| CBT-F-01 wall clock (RHEL 9) | ≈14.7 min of harness legs (137 s + 175 s + 572 s, `runs/20261012-cbtf01-r01`) | `logs/workflow.log` `Step timing:` lines |
| CBT-F-01 wall clock (Windows) | ≈76 min end-to-end (`runs/20261010-cbt-f-01-r08`), dominated by a 32 min guest-agent stall + ≈35 min agent-side work after the test was terminal | workflow log + artifact mtimes |
| Agent spawns per scenario run | 1 monitor + conditional reviewer (skill); campaign history shows far more | skill text + `history://` |
| Verdict authority | LLM prose only | no evaluator script existed |
| Stage timings in `summary.json` | absent | `write-run-summary.sh` |

## 8. Per-run metrics (plan §11 "Measure per run")

What a run can and cannot be measured on today. Read every number from the
recorded artifact — do not restate it from memory, and do not claim a metric
the harness does not instrument.

| Metric | Where it is recorded | How to read it |
|---|---|---|
| End-to-end and per-stage wall clock | `runs/<id>/run.json .stage_timings`, `.total_elapsed_seconds`; `runs/<id>/summary.json .phases`; per-leg `cbt-chaos/scenarios_v2/<id>/runs/<RUN_ID>/driver-timings.json` | `jq` on those keys |
| Agent spawns | the session's agent handles; not persisted by the harness | counted from the session |
| Model calls / tokens | **not measurable** — the harness records no token or model-call telemetry (see `docs/agent-workflow-flag.md` F4) | — |
| Repeated source reads, API queries, evidence collections | not instrumented | narrative only; do not claim a number |
| Make target chosen, and whether it was the narrowest valid one | `ledger.jsonl` stage events; `summary.json .last_invocation.stage` | compare against `make stage-list` and the scenario's acceptance criterion |
| Retries / timeouts and their reason | `runs/<id>/logs/workflow.log`; `monitor.sh` exit 2 timeout message; `run.json .recovery.attempts[]` | `grep`/`jq` |
| Injection validity and evidence completeness | the `cbt-chaos/scenario-verdict.sh` JSON checks | `jq '.checks[]'` |
| Verdict correctness against fixture ground truth | `tests/test-scenario-verdict.sh` cases (PASS / INVALID / INCONCLUSIVE / FAIL / wrong-target / stale-signal) | run `make test` |
| Recovery and cleanup success | `run.json .recovery.attempts[].status`, `.restore.status` | `jq` |
| New validated failure modes / coverage | `docs/findings/`, the scenario's `bugs/`, the skills' `*-learnings.md` | file inspection |

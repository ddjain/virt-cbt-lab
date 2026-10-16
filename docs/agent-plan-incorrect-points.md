# Points in the agent improvement plan that are not correct as written

Review round: 2026-10-16, against the working tree at
`/Users/darjain/projects/redhat-chaos/cbt-setup`.
Subject: `virt-cbt-lab-consolidated-agent-improvement-plan.md`.

This file is the **skip list** for that review. Each entry is a plan point that
is factually wrong for this checkout, internally inconsistent, or unverifiable
with the tooling that exists here. Per the review instruction, an entry in this
file is *not* implemented: the evidence shows the point cannot hold, so
implementing it literally would damage the workflow. Everything the plan asks
that *does* hold is implemented and recorded in
`docs/agent-workflow-report.md` (before/after record) and
`docs/agent-workflow-audit.md` (capability matrix, per-run metrics).

Where an entry duplicates an item in `docs/agent-workflow-flag.md`
(the earlier "items I do not accept as written" record), the flag id is named so
the two files cannot drift apart.

Status legend: **CONTRADICTS-REPO** (premise false here), **UNMEASURABLE**
(the harness cannot produce the datum), **UNSAFE-IF-LITERAL**, **SCOPED-OUT**
(true but needs a harness this repository does not have).

---

## P1 — §2 "Never default to `make e2e` / `TYPE=all`" (UNSAFE-IF-LITERAL)

- **Plan:** §2, bolded: "**Never default to `make e2e` / `TYPE=all` for each
  chaos experiment.** … execute only the stage needed by the current hypothesis".
- **Contradiction:** CBT-F-01's own acceptance criterion 6 requires a separate
  clean `TYPE=all` lifecycle on a new run ID, and the interrupted leg is
  `make e2e TYPE=full` by design
  (`cbt-chaos/scenarios_v2/CBT-F-01/scenario-spec.md` criterion 6;
  `chaos-trigger.sh` leg 1).
- **Why skipping the literal rule matters:** an agent obeying it would refuse or
  "optimise away" a step the scenario's PASS criteria depend on, producing a
  false INVALID — a worse failure than an extra stage.
- **Implemented instead:** "the smallest valid stage **that satisfies the
  current acceptance criterion**", with the exception stated in
  `cbt-chaos-run` and `cbt-chaos-team`. See flag F1.

## P2 — §2's stage table implies stages are freely re-runnable (CONTRADICTS-REPO)

- **Plan:** §2 "Relevant Make targets" table: `make vm-backup RUN_ID=<id>`,
  `make vm-cbt-backup RUN_ID=<id>`, … as a general "preferred command shape".
- **Contradiction:** the stages are state-machine transitions, not idempotent
  commands — `vm-cbt-backup.sh` exits 1 when the plan is complete ("use
  `TYPE=extend`") or the lifecycle is in the wrong state, and `stage.sh` exits 2
  without `runs/<id>/run.json`. A second full backup on a completed lifecycle is
  not a supported transition.
- **Implemented instead:** the matrix and every skill require reading
  `runs/<id>/run.json` state (plus `make stage-list`) before selecting a stage,
  and treat a stage rejection as a lifecycle-state error rather than a product
  failure. See flag F2.

## P3 — §11 "Agent spawns/model calls where measurable" and §14 "agent calls" (UNMEASURABLE)

- **Plan:** §11 "Measure per run: … Agent spawns/model calls where measurable";
  §14 "Before/after duration, unnecessary full-E2E count, agent calls…".
- **Why it cannot hold:** the harness records no token or model-call telemetry.
  The only deterministic timings it produces are the per-stage wall clock
  (`e2e-stage.sh` `Step timing:` lines, persisted as `run.json .stage_timings`
  and `summary.json .phases`) and the backup timings derived from the API.
- **Implemented instead:** wall clock per stage/leg plus counted agent spawns;
  token accounting is a manual session observation, never a claimed metric. The
  audit document's per-run metrics section states this explicitly. See flag F4.

## P4 — §11 "Start with 10–20 realistic tasks" as an evaluation suite (SCOPED-OUT)

- **Plan:** §11 "Start with 10–20 realistic tasks based on existing manual checks
  and known failures", §10 Phase 2 "Cover at least: [11 negative cases]",
  "Use fixtures/mocks for evaluator and dispatch tests".
- **Why it cannot hold here:** those are tasks for an *agent-eval* harness — a
  scripted environment that presents a task to an agent and scores its behaviour.
  This repository has hermetic shell tests (`tests/`, 19 scripts via `make test`)
  and no agent-eval harness, no fake cluster, and no fake preflight. Building one
  is a project, not a review step.
- **Implemented instead:** every negative case that a deterministic evaluator can
  own is now a real fixture case (missing injection evidence, RUN_ID mismatch,
  wrong-target injection, mismatched/attributed checkpoint evidence, absent
  observer, stale-signal timing contradiction — `tests/test-scenario-verdict.sh`).
  The cases that need a fake cluster or a fake preflight are listed under
  "Not executed" below rather than claimed. See flag F5.

## P5 — §12 "the shared audit/contract document" cannot be `cbt-chaos/contracts/*` (AMBIGUOUS → wrong target)

- **Plan:** §12 "Link to `make help`, `make stage-list`, and the shared
  audit/contract document."
- **Why the obvious reading fails:** `cbt-chaos/contracts/*.md` are the
  CBT-F-04 campaign's per-run contracts; they are worded for that scenario and
  `contract-gen.sh` substitutes only `__RUN_ID__`-style tokens, so the scenario
  identity inside them stays F-04. Linking them as "the shared contract" would
  point every skill at another scenario's artifact.
- **Implemented instead:** the shared contract is
  `docs/agent-workflow-audit.md` (stage semantics, exit codes, artifacts,
  per-run metrics), and every skill links to it. The F-04 worded contracts stay
  flagged for parameterisation. See flag F7.

## P6 — §5's script inventory cannot be one matrix row per chaos trigger (CONTRADICTS-REPO)

- **Plan:** §5 "Read all scripts involved in … chaos trigger … Include all
  scripts called by the current lead/skills".
- **Why the literal form fails:** there are ~54 scenario directories under
  `cbt-chaos/scenarios_v2/` and each carries its own `chaos-trigger.sh` (plus
  variants such as `chaos-trigger-r01b.sh` and `guest-churn.sh`). A per-file
  matrix row would be a ~70-row table of near-identical rows, most of them for
  scenarios the flow cannot currently run, and it would rot on the next trigger
  edit.
- **Implemented instead:** one row for the **trigger contract** (inputs,
  artifacts, exit codes, what it proves and does not prove, invoking role) plus a
  row for the one scenario driver that exists (`run-cbt-f-01.sh`). The row states
  the variants exist and are scenario-owned. See `docs/agent-workflow-audit.md`
  §2.

## P7 — §7/§11 verdict-contract gaps found while implementing (reported, not "plan errors")

These are findings about the *evidence*, discovered by implementing §7's
"missing mandatory evidence cannot PASS" and "the injecting agent cannot be the
sole authority" as deterministic rules. They are recorded here because they were
**not** visible in the plan:

- The evaluator previously accepted an injection supported only by the injector's
  own artifacts (no observer handoff marker or watch stream) as PASS. Now that
  combination is UNKNOWN ⇒ INCONCLUSIVE.
- The evaluator previously accepted `effect-check.json` as proof that the
  intended pod was removed without comparing it to the pod the signal named, so a
  wrong-target injection could PASS. A provably different pod is now INVALID.
- The evaluator previously ignored the observer arming instant, so a stale
  `Backup started` line from an earlier backup on a long-lived pod was
  indistinguishable from an in-window signal. Contradictory timing is now
  UNKNOWN ⇒ INCONCLUSIVE.
- The validated CBT-F-01 run `20261016-cbt-f-01-r03` still returns PASS with all
  eight checks under the tightened rules (re-verified from its on-disk
  artifacts), so these rules were tightened without invalidating the validated
  run.

---

## Not executed (plan §14 requires this record)

| Plan item | Why it was not executed | What would make it executable |
|---|---|---|
| §11 negative case: `make clean-all` refused during triage | `clean-all.sh` is destructive across the namespace; the refusal is agent policy, and testing it needs a fake cluster or an interception harness. `make clean-all` was **not** run in this round. | a fake-cluster/interception fixture, or a confirmation gate on `clean-all.sh` (a behaviour change to a human-facing destructive command, deliberately not made) |
| §11 negative case: unhealthy preflight ⇒ BLOCKED | `./preflight` is never executed by any test; `test-stage-dispatch.sh` stubs it with `exit 0`. A real run needs a cluster that is *not* ready. | a preflight fake or a documented NOT-READY cluster |
| §11 negative case: cleanup failure | cleanup failure needs a cluster that refuses deletion. | fake cluster |
| §11 negative case: experiment-budget stop | the budget is agent-contract text; observation requires an agent-eval harness. | agent-eval harness (P4) |
| §11 metrics: model calls/tokens | not measurable in this harness (P3). | harness telemetry |
| §10 Phase 5 "expand to more scenarios one at a time" beyond the pod/container gate | only two scenarios were executed end to end (CBT-F-01, CBT-I-01) with the full team protocol; **CBT-F-03** (restart the backup controller during a full backup) was prepared but not run: its trigger gained a verified `--plan` rehearsal mode and its full contract set (`preflight`, `observer`, `trigger`, three checkers, `report-writer`) is written under `cbt-chaos/scenarios_v2/CBT-F-03/runs/20261016-cbt-f-03-r01/contracts/`, with no run root, no cluster resources and no verdict. The review's requirement was 2–3 runs, and the two executed runs already exercised every changed harness and skill surface. | executing it needs a GO preflight (including the `virt-controller` standby-replica precondition) and the 15–20-minute window |
| Windows CBT-F-01 variant | a separate, much slower configuration (a 32-minute guest-agent stall is recorded in `runs/20261010-cbt-f-01-r08`); the plan's time gate is measured on RHEL 9. | its own budget and a root-caused guest-agent outage |

## Harness observations found during the review (not plan points, not fixed)

- `cbt-chaos/team` and `issue-triage` skill copies: `.claude/skills/cbt-chaos-run`,
  `.claude/skills/cbt-chaos-issue-triage`, `.pi/skills/cbt-chaos-run` and
  `.pi/skills/krkn-scenario` resolve to the `.agents/skills/` sources. `.pi/skills`
  has no `cbt-chaos-issue-triage` and `.claude/skills` has no `krkn-scenario`, so
  a harness that loads skills from those roots sees a different set. Left as-is:
  pointing them at the wrong tree is a harness decision, not a plan item.
- `.claude/skills/.bak/cbt-chaos-issue-triage-drifted-copy/SKILL.md` is a retired
  17.4 KB copy. Unreferenced by any live entry; left in place rather than deleted
  (deleting another author's backup is not part of this review).
- `.agents/skills/cbt-chaos-team/cbt-chaos-team-learnings.md` is empty ("none yet
  — populated by learning closeout after the first team run"). The team run in
  the E2E round below is the first opportunity to populate it.
- `cbt-chaos/scenarios_v2/<id>/reject-reasons.tsv` (the twice-rule index) exists
  for CBT-F-04 only. The index is created at learning closeout, so this is
  expected until more runs close out.
- The plan's §5 path `cbt-chaos/checkers/evidence-sufficiency.json` does not
  exist; the real artifact is `checkers/evidence-sufficiency.json` at the
  repository root (scenario-relative in the run records).
- The repo-wide shell check (`find . -name '*.sh' | xargs bash -n`, the command in
  `AGENTS.md`) fails on one **archived run artifact**:
  `cbt-chaos/scenarios_v2/CBT-F-10/runs/20261014-cbtf10-r04/observer/collector.sh:34`
  (an unquoted `jsonpath={...}` argument). It is a write-once evidence file from a
  closed run that predates this review (untouched in `git status`), so it was
  deliberately not edited; editing it would rewrite recorded evidence.

## Harness findings from the validation runs (2026-10-16)

The plan's own validation (two full team runs of `scenarios_v2` scenarios through
the `cbt-chaos-team` protocol) produced findings that are about the harness, not
about the plan's text. They are recorded here because the plan's §11 asks for
exactly this kind of agent-process observation, and because a fix direction is
known for each.

- **HV1 — the deterministic evaluator implements one scenario's shape as if it
  were generic.** Run against CBT-I-01 (a VMI restart between the full and the
  incremental stage), `cbt-chaos/scenario-verdict.sh` returned **INVALID** with
  the reason "the injected condition was never exercised", because it expects
  CBT-F-01's artifacts (`trigger/action-request.json`, `effect-check.json`), a
  *failed* full backup, and a same-VM recovery attempt; none of those exist in
  this scenario by design, and the run's own injection was independently
  evidenced (the observer's own VMI stream shows the UID changing
  `b203235a…` → `29dfe33c…`). A script that returns a confidently wrong verdict
  outside its scenario shape is worse than no script: it can only be overturned
  by prose, which the verdict contract forbids. **Fix direction:** give the
  evaluator a declared scenario shape that selects the applicable check set, and
  return `NOT_APPLICABLE`/`INCONCLUSIVE` — never `INVALID` — for checks outside
  its model.
- **HV2 — the run-root pull clobbers Lead-owned state.** `make pull-reports`
  plus a targeted `rsync` of the scenario run directory restored
  `ledger.jsonl`/`state.json` from the execution host and silently reverted the
  Lead's post-push events (preflight, armed, executing, notes) because those
  files existed only on the workstation. The audit trail had to be re-appended
  from the Lead's records (`ledger.jsonl` carries a `ledger_note` describing
  it). **Fix direction:** the Lead must write the ledger on the authoritative
  side, or the pull must exclude Lead-owned files (`ledger.jsonl`,
  `state.json`, `evidence-index.json`).
- **HV3 — a per-run contract can silently drop a mandate the template already
  makes.** CBT-F-01's spec requires the launcher's libvirt checkpoint tree
  *before injection and after VM recovery*; the parameterised contract template
  `cbt-chaos/contracts/observer.md` already requires that capture, but the
  run-specific observer contract written for `20261016-cbt-f-01-r04` narrowed the
  observer to "read-only, no `oc exec`" and dropped it. The run was then graded
  INSUFFICIENT on that criterion and landed BLOCKED. The same class produced a
  second, smaller instance in the I-01 run: its hand-authored
  `contracts/check-injection.md`/`contracts/check-evidence.md` point the checkers
  at "§4 criteria", while I-01's criteria live in §5 (the *template*
  `cbt-chaos/contracts/check-evidence.md` correctly says §5). Those two contracts
  are closed-run artifacts and were deliberately **not** edited (contracts are
  immutable after acceptance; the checkers read the spec and cited §5 in their
  verdicts, so nothing was misgraded). **Fix direction:** generate per-run
  contracts from the template (the repo has `cbt-chaos/contract-gen.sh`) instead
  of authoring them from scratch, and keep the capture owner explicit.
- **HV4 — agent-launched long-running commands are observable only with a
  detached launch.** A trigger worker's first launch self-refused (its own
  `pgrep` pattern matched its wrapper command line), and its relaunch — detached
  with `setsid`/`nohup` — survived the tool's 60-second backgrounding, while a
  foreground-style launch appeared to have done nothing when the Lead probed
  minutes later. The Lead's own duplicate launch was then correctly refused by
  the trigger's collision guard (no mutation). **Fix direction:** state the
  detached-launch requirement in the trigger contract, and use
  `pgrep -f '[c]haos-trigger[.]sh'`-style patterns that cannot self-match.
- **HV5 — watchers must be bounded and stopped before the pack is frozen.**
  `WATCH_MAX_SECONDS` (added in this review) worked, but a scenario run's pack
  cannot be frozen while its watchers are still appending; the observer must
  stop them first. In the CBT-F-01 run the observer's late `FINAL` also delayed
  the freeze. A poll loop with a bash arithmetic test fed by a multi-line `jq`
  value silently defeated its own early exit and delayed the `PRESERVED`
  handoff by 6 m 22 s (self-reported and fixed in the next run, where the same
  handoff landed 14 s after the request).
- **HV6 — clock/timestamp discipline.** The execution host's clock agrees with
  the workstation's (checked: 4 s apart), but `REMOTE_DIR` from the local `.env`
  is *not* exported into an `ssh` session; a worker that used `"$REMOTE_DIR"` in
  a remote command wrote its artifact to `/root/cbt-chaos/...` instead of the
  checkout. The artifact was recovered, and the lesson is to pass the directory
  explicitly in every remote command.
- **HV7 — `ssh host cat file > local` is not a pull.** When the remote read
  fails, the local redirect truncates the local file to zero bytes; the
  subsequent push then destroys the remote copy. Use `rsync` (which skips an
  absent source) for every artifact transfer. This cost one preflight artifact
  (recovered) during the validation runs.
- **HV8 — the non-monotonic pod `deletionTimestamp` was an observation artefact,
  not a defect — resolved by the I-01 flow analyst from the Kubernetes source.**
  Two runs' observers reported the same UID carrying a *decreasing*
  `deletionTimestamp` across increasing resourceVersions and honestly labelled it
  unexplained. The analyst traced it to the apiserver's
  `rest.BeforeDelete` grace-period rewrite (`delTS = old − old_grace + new_grace`)
  and reproduced the observed values exactly (01:39:06 + 60 s = 01:40:06 with
  grace 60, then − 60 s + 0 = 01:39:16 with grace 0); the upstream issue is
  closed `not-planned` ("working as intended"). No ticket, no harness defect —
  the anomaly was watch-stream semantics, and the observers' use of container
  `finishedAt` as the corroborating instant was the right instinct. Recorded here
  so a future observer does not re-open it: **`deletionTimestamp` in a watch
  stream is not monotonic — do not use it as the deletion instant.**
- **Hardcoded infrastructure names in committed scenario triggers (pre-existing; one instance fixed here):** `cbt-chaos/scenarios_v2/CBT-I-01/chaos-trigger.sh` carried a committed `HOG_NODE="<node-name>"` default for a placement-guard log line, which `AGENTS.md` forbids ("Do not hardcode private hostnames or absolute host paths into committed files"). It is now `HOG_NODE="${HOG_NODE:-}"` and the log line prints `<unset>` when the variable is not set — the expected node belongs in the run environment, not the repository. The remaining `scenarios_v2` triggers were **not** audited for *node-name* defaults (that backfill is per-scenario work); the tracked-tree sweep for the execution-host name and remote checkout paths is documented in the next entry and found two further triggers carrying them (`cbt-chaos/scenarios_v2/CBT-F-02/chaos-trigger.sh`, `cbt-chaos/scenarios_v2/CBT-EXP-07/chaos-trigger-r03.sh`).
- **Execution-host naming: a pre-existing repo-wide convention, not a defect of
  this review.** `AGENTS.md` forbids environment-specific internal hostnames and
  paths in committed files, but the repository already ships the demo host's name
  as a documented convention: `cbt-chaos/contract-gen.sh` defaults `REMOTE_HOST`
  to it, an audit page under `docs/cbt/` is indexed
  by `docs/cbt/README.md`, and three committed paths carry the name in their
  **filename** — that audit page, a VM backup/restore plan under `docs/oadp/`,
  and a validation summary under `validation/`. Scope measured
  2026-10-16: **88 occurrences across 27 tracked files** contain that name and
  **26 occurrences across 10 tracked files** contain the remote checkout path;
  six further files in `cbt-chaos/scenarios_v2/CBT-F-04/analysis/` carry one or
  both (four already tracked/committed from an earlier session — the r02/r03
  analyses — and two untracked r04 files). Nothing here was sanitized: renaming
  the three files and rewriting ~30 files plus their cross-references is a
  repo-wide refactor of an existing convention, so it is the user's decision —
  and the user has decided (2026-10-16): the hostname is acceptable, the bar is
  that no key, secret or credential be exposed. No sanitising pass is planned;
  the entry is kept as the record of the sweep and of that disposition. This
  review's own additions were scanned
  for the host name, internal paths and credential strings: **no leaks**, and the
  review's commit added no such content. A secret scan of the tracked tree found
  no key material: no `.env`/`keys/`/kubeconfig/`*.pem`/`*.key` file is tracked,
  and the only `Authorization: Bearer` occurrence writes a runtime token into a
  mode-600 `mktemp` file.

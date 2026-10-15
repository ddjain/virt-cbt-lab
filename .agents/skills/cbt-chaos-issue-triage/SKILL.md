---
name: cbt-chaos-issue-triage
description: >
  Triage a CBT Chaos v2 test by reading its Jira issue under
  cbt-chaos/scenarios_v2/<scenario_id>/jira-issue.md, checking the actual
  cluster and the active virt-cbt-lab workflow, validating the chaos injection
  with the krkn-scenario skill, and generating a detailed scenario-spec.md plus
  a minimal chaos-trigger.sh. Use for designing or preparing a v2 scenario;
  do not execute E2E or inject chaos unless separately requested.
user_invocable: true
arguments:
  - name: scenario_id
    description: Exact CBT scenario ID, e.g. CBT-F-01 or CBT-I-03.
    required: true
---

# CBT Chaos v2 Issue Triage

Plan one CBT Chaos v2 test from its Jira issue through implementation-ready scenario artifacts. The exact issue, active workflow source, live cluster, and current Krkn registry are the evidence sources. This triage skill designs and statically validates the scenario (syntax, Krkn `--dry-run`, read-only signal/target confirmation); it does not itself execute a live E2E/chaos run. When the generated trigger needs to be validated live, hand it off to the `cbt-chaos-run` skill, which implements the actual execution protocol (armed observer, watch-health gating, preserve-before-recover, same-VM recovery check). Never clean the cluster with `make clean-all`.

## Safety and scope

- Read the repository's `AGENTS.md` instructions first if they are not already in context.
- This skill does not run `make e2e` or inject live chaos itself. It performs read-only cluster inspection to resolve targets/signals, and static validation of generated artifacts (`bash -n`, Krkn `--dry-run`). When the scenario's timing/target cannot be resolved from existing cluster state, or the generated trigger needs live validation, invoke the `cbt-chaos-run` skill with the scenario ID rather than driving `make e2e`/chaos injection directly from triage. Never run `make clean-all`; never remove unrelated resources or broadly clean the namespace.
- Read-only cluster inspection is the default for triage. Do not assume a command is incremental merely because Make accepted `TYPE=incremental`.
- Treat kubeconfigs, `.env`, guest keys, and credentials as secrets. Do not read their contents, print them, copy them off the host, or include their paths/values in committed scenario documentation. Resolve the target host, remote checkout, and kubeconfig from the user's current request or the documented `REMOTE_HOST`, `REMOTE_DIR`, and `KUBECONFIG_PATH` configuration. Never hardcode environment-specific hostnames or absolute paths in generated docs/scripts.
- Before every remote E2E/chaos validation (performed via `cbt-chaos-run`, not this skill), run `make resync` from the local checkout so the configured remote host has the validated latest scripts/spec. First confirm `REMOTE_HOST`/`REMOTE_DIR`, then check for conflicting remote edits with a dry-run diff before pushing, e.g. `ssh "$REMOTE_HOST" diff -rq "$REMOTE_DIR" .` scoped to the files you changed, or `rsync -an --itemize-changes` reusing `sync.sh`'s exclude list against the remote target; stop and ask if it shows unexpected remote-side changes. `make resync` excludes credentials and `.env`. Do not run it after the current test starts or completes; use `make pull-reports` to return artifacts.
- If the host or cluster is unreachable, or a required target cannot be identified safely, stop before claiming the scenario is cluster-validated. Ask for the missing access/output or provide only the supported local analysis, clearly naming the blocker.

## Phase 1 — Resolve the issue

1. Validate `{{ scenario_id }}` exactly against `cbt-chaos/scenarios_v2/{{ scenario_id }}/jira-issue.md`. Do not guess a similarly named directory or create a missing issue.
2. Read the complete issue file and, where useful, its matching row in `cbt-chaos/scenarios_v2/cbt-chaos-test-plan-v2.csv`. Extract every field: workflow, objective, target, action, injection window and signal, duration, expected behavior, recovery, verification, outcome, priority, technical scenario, and phase.
3. Identify any conflict between what the issue requests and what the CBT implementation or cluster can actually exercise. At the beginning, ask one focused batch of follow-up questions before planning or mutating the cluster only if, after reading the issue, CSV row, and available repo/cluster state, at least one of the following is still genuinely undetermined: which workflow (full vs. incremental vs. other staged mode) applies, which resource/component is the target, or what the issue's expected outcome actually is. Do not ask about anything derivable from the issue, repository, or cluster; proceed directly to planning once those three are each resolvable from available evidence.

## Phase 2 — Determine the workflow that will actually run

Inspect the checked-out `Makefile`, `scripts/e2e-stage.sh` when present, `scripts/run-id.sh`, and workflow scripts relevant to the issue. Read `docs/vm-cbt-workflow.md`, `docs/cbt/01-overview.md`, and `docs/cbt/06-incremental-backup.md` to understand the lifecycle/checkpoint contract; consult `docs/cbt/10-chaos-test-design.md` for injection boundaries and the relevant component/storage/source/independent-verification docs as needed. Also inspect the remote checkout's corresponding Makefile/help when E2E will run there. Never assume local and remote checkouts are the same revision. Treat docs as background; active source and live evidence win.

Use source, not Make's acceptance of an arbitrary variable, to determine the contract:

- `make e2e` means whatever the active checkout's `e2e` target actually does. In the current local framework, the default `TYPE=all` creates a new lifecycle, performs a full backup and planned incremental pass(es), and verifies the chain/restore.
- Use the staged command matching the Jira workflow rather than running the full demo by default:
  ```sh
  make e2e TYPE=full
  make e2e TYPE=incremental VM=vm-my-existing-run
  ```
  `TYPE=full` creates a fresh run ID when `NAME`/`VM` is omitted, sets up a new VM, and takes one full backup. `TYPE=incremental` requires the exact existing managed VM (`VM=vm-<run-id>`) and its valid `runs/<run-id>/run.json`; it adds the next planned incremental pass and does not recreate the VM. Replace the safe illustrative VM name with the run's actual `VM_NAME` only after confirming its saved lifecycle state and remaining pass count.
- These mode rules are version-dependent. The currently observed remote checkout has an older Makefile whose `e2e` target always runs preflight and the complete demo; it does not implement `TYPE` or `NAME`. GNU Make can accept an unused `TYPE=incremental` assignment without changing that target. Recheck the actual remote source every invocation. Never issue or document a `TYPE=incremental` command as valid unless the active checkout's code consumes `TYPE` and the required VM metadata exists.
- For a new full lifecycle use an explicit unique `NAME`/run ID only if the active framework supports it. For incremental work, use the existing managed `VM` and confirm pass state. Do not target an existing VM by name alone when it has no valid run metadata.
- Choose `make e2e`/`TYPE=all` only when the issue requires a new full-plus-incremental lifecycle and final chain/restore verification; use `TYPE=full` or `TYPE=incremental VM=...` when the issue targets one stage. If an incremental test needs a known successful full base, confirm the base and tracker before choosing that existing run.

## Phase 3 — Inspect the actual cluster

Resolve the SSH target and kubeconfig from the current request/configuration. Run inspection commands on that host, using its kubeconfig in place; do not copy the kubeconfig to the local machine. Confirm access with a read-only identity/version query, then inspect only resources needed for this issue:

- Namespace existence and relevant VM/VMI, `VirtualMachineBackup`, tracker, PVC, pod, event, and storage resources.
- Actual labels, owner references, node placement, controller/handler/CSI pod identity, and current readiness needed to select a narrow target.
- Existing run/resource names and workflow state needed to avoid targeting another test or a stale object.

The live CBT namespace may contain multiple VMs and backup resources. Derive exact selectors from the current objects and the issue's chosen run ID; never use an unscoped pod match or guessed label. Record only the evidence required to justify the target. Do not persist secrets or unnecessary host-specific values in the scenario spec.

If the scenario's signal is not observable from the available API/logs, do not substitute an arbitrary sleep. Report the observable gap and ask for an acceptable signal or monitoring source.

When timing or object selection cannot be resolved from existing cluster state, invoke the `cbt-chaos-run` skill to run the issue-appropriate supported full or incremental E2E with a unique run ID and capture the actual transition and exact object via its observer; do not drive that E2E/chaos run directly from this skill. Use the resulting observed evidence to build the event query. Never run concurrent E2E lifecycles in the same checkout; never clean the cluster afterward with `make clean-all`.

## Phase 4 — Validate the Krkn injection

Delegate the command-building work to the `cbt-chaos-krkn-preparer` role when it is available (team-mode triage): pass the extracted disruption intent (target, action, window/signal, duration, blast radius) and consume its returned validated argv, dry-run evidence, and trigger analysis as the Phase 5 trigger input. When operating standalone without the team, perform the equivalent procedure yourself as described below, following the `krkn-scenario` skill for flag accuracy:

1. Check `command -v krknctl`, run `krknctl list available`, and invoke the `krkn-scenario` skill for the selected disruption.
2. Query `krknctl describe <tag>` and `krknctl run <tag> --help` for exact flags and trigger support. Prefer the documented event-driven trigger arguments (for example `--trigger-command` or `--trigger-k8s-*` when present) over time-based injection. Do not guess a `trigger-chaos` subcommand or option; use the actual CLI help/skill metadata.
3. Identify the exact object and condition to monitor from the Jira signal and live observations. Build a query that becomes true at the intended phase, not merely when a request is created if the issue requires active copying. Confirm the query runs in an environment with the required API/CLI access.
4. Use the live namespace, labels, object identity, duration, and target details. Prefer narrow selectors and pass the kubeconfig explicitly through the approved host-local path.
5. Run `krknctl run <tag> --dry-run ...` with the exact parameters before live injection. Dry-run proves the command/configuration is valid; it does not prove live injection timing. When the query/timing needs live validation, hand off to the `cbt-chaos-run` skill to execute the issue-specific E2E and the event-driven Krkn injection and confirm the query fired at the intended transition and the target was actually disrupted.
6. Prefer Krkn for the disruption. If its scenario or event interface cannot perform the required action/timing, use a narrowly scoped `oc` or `kubectl` mutation from the event observer instead. Document why Krkn was insufficient, the exact observed condition and targeted resource, and the fallback command; never replace an event with an arbitrary sleep or broaden the blast radius.

**Timing rule:** whenever the injector is `krknctl`, the disruption MUST be gated by Krkn's native event trigger (`--trigger-command`, `--trigger-k8s-*`, or the exact supported equivalent). A host-side/custom Bash observer that waits for the event and then starts Krkn is not reliable for a short window: Krkn image startup and initialization can outlast it. Start Krkn early with its native trigger so startup is absorbed before the condition. A custom event observer followed by a direct `oc`/`kubectl` mutation is acceptable when Krkn cannot preserve the exact target or timing; document that reason. A custom script is not a substitute for Krkn's native trigger when the script still uses `krknctl` to inject.

The current cluster has been observed to provide `krknctl` and a registry containing common pod, container, PVC, node, network, and KubeVirt scenarios. This is only a snapshot: recheck availability and metadata for every triage.

## Phase 5 — Select the minimum workflow and generate artifacts

Create/update only these files in the issue's existing directory:

- `cbt-chaos/scenarios_v2/<scenario_id>/scenario-spec.md`
- `cbt-chaos/scenarios_v2/<scenario_id>/chaos-trigger.sh`

Do not edit the Jira issue or CSV as part of triage. Use `cbt-chaos/template/scenario-spec-template.md` as a structural reference, adapting it to v2. The spec must include:

1. Jira issue ID/title and the exact objective/hypothesis.
2. Chosen workflow invocation, active checkout/revision context, VM/run prerequisites, and why that mode matches the issue.
3. Target component and narrowly resolved cluster selectors; exact validated Krkn scenario/tag and full command with `--dry-run` evidence.
4. Deterministic injection signal, supported trigger mechanism, when to arm it relative to E2E, and limitations. No arbitrary sleep as a substitute for the signal.
5. Concrete pass/fail criteria from the issue; the exact metadata, checkpoint/tracker, artifact, VM/CBT, restore, recovery, or event checks needed for its stated objective. For backup-disruption tests, include a post-chaos backup attempt on the same recovered VM using a distinct backup/PVC identity while preserving failed resources; treat a clean new-VM lifecycle as supplemental only.
6. Blast radius, prerequisites, recovery/cleanup, known state conflicts, and any unresolved uncertainty. Do not claim an expected outcome as observed fact.

Keep `chaos-trigger.sh` minimal: Bash shebang and strict mode; resolve the repository root; set only required run/workflow values; start an event-driven Krkn command before E2E when its trigger semantics require it; run the exact supported full or incremental `make e2e` command; wait for both processes and propagate failures. Every generated trigger MUST support a `--plan` self-rehearsal mode: given the same arguments, it resolves RUN_ID/lifecycle NAME, the exact target selector, and the full action and workflow commands, prints them, and exits 0 without executing anything — preflight runs this mode live before any GO. Prefer Krkn to perform the disruption. If Krkn cannot target the required resource or timing, use a narrowly scoped `oc`/`kubectl` event observer and mutation instead, documenting why. Add only process cleanup needed if E2E exits early. Avoid general-purpose wrappers, duplicate cluster discovery logic, fixed sleeps, hidden broad defaults, and unrelated recovery automation. Do not include secrets. Preserve executable mode or document `bash chaos-trigger.sh` if the tool cannot set it.

For remote validation, run `make resync` from the local checkout after scenario files pass syntax/Krkn dry-run checks and before starting any E2E/chaos process. Verify the selected remote script matches the validated local script. Do not copy credentials.

If neither Krkn nor a narrowly scoped `oc`/`kubectl` event-driven fallback can meet the issue's timing and target, do not generate a misleading trigger; explain the gap and ask for a decision.

## Phase 6 — Verify the generated files

- Read both generated files back and confirm every Jira requirement is represented in the spec and the target/action/workflow are consistent.
- Run `bash -n cbt-chaos/scenarios_v2/<scenario_id>/chaos-trigger.sh` and Krkn `--dry-run` for the final invocation. Also run the trigger's `--plan` mode with representative arguments and confirm it prints the resolved target, selector, and full commands and exits 0 without executing anything; record its sha256 for the run's `evidence-index.json`.
- When the live event query and disruption need validation, invoke the `cbt-chaos-run` skill rather than running the scenario directly from triage; it observes the exact signal, injection timestamp, target event/state change, backup result, tracker/checkpoint, CBT/VM recovery, and restore/data checks required by the issue. A successful Krkn process exit alone is not proof that chaos landed.

- After `cbt-chaos-run` completes (including non-zero exits), run `make pull-reports` from the local checkout. It pulls the remote root `runs/` tree only; also use a targeted, quoted `rsync` to pull the selected `cbt-chaos/scenarios_v2/<scenario_id>/runs/<RUN_ID>/` folder to the matching local folder. Verify local JSON and observer evidence are present and parseable. Do not run `make resync` after the run.
- Confirm no kubeconfig/credential content, private hostnames, or environment-specific absolute paths were added.
- Never run `make clean-all`. Report the command/workflow actually used, live evidence and outcome, generated files, validation performed, and any unproven behavior.

## Clarifying questions

Ask in one concise batch when cluster evidence cannot resolve a materially different choice, such as full versus incremental workflow, whether a non-equivalent trigger is acceptable, or which pre-existing VM/run to reuse. Do not ask for facts available from the issue, Makefile, live cluster, or Krkn metadata. If the requested workflow is unsupported by the active remote checkout, do not silently update it or substitute a different run; explain and ask whether the user wants the checkout updated or a supported existing command used.

## Triage learnings

When resolving CBT issues, designing scenario artifacts, or troubleshooting triage validation, refer to [`cbt-chaos-issue-triage-learnings.md`](cbt-chaos-issue-triage-learnings.md). Read it only when doing triage or troubleshooting triage validation; do not load unrelated run learnings. After triage, add a dated, evidence-backed learning there only when it can improve future triage. Keep issue-specific decisions in the scenario artifacts; omit secrets and private environment details.
## Product scope and finding separation

The product question is whether CBT full and incremental backups behave correctly under the specified disruption: terminal backup status/reason, checkpoint and tracker state, VM CBT recovery, and restored data. For backup-disruption scenarios, include a post-chaos backup attempt on the same recovered VM in the product criteria; a fresh VM lifecycle is supplemental and does not replace same-VM recovery validation. The workflow, trigger, report writer, and monitoring helpers are test machinery. Keep their failures separate from the CBT product verdict and call them out separately in the final response.

## Learning closeout

Before the final response to triage, ask the user: “Did this triage reveal an important, reusable workflow/process lesson worth recording?”

- If the user says yes, check the existing triage learning file for duplicates. Append one concise, dated, evidence-backed entry only when the lesson is generic and actionable; keep issue-specific results in that issue's artifacts.
- If the user says no, or the observation is not a substantial reusable improvement, do not add an entry.
- Use the existing learning file only. Do not create another `.md` file; ask before creating one if no suitable file exists.
- If a learning warrants a main skill change, propose the exact additions/updates/removals and wait for user confirmation before editing a `SKILL.md`.
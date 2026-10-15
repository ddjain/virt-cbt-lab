# Scenario Improvements — CBT-F-04 run 20261015-cbtf04-r02

Post-run scenario-improver output. Scope: weaknesses in the **test itself**
(spec, trigger, launch discipline, checker gap) proven by this run's closed
artifacts. Proposals only — nothing applied. Trigger diffs are Lead-approvable
between runs; spec edits are human-gated.

Run context: verdict **PASS WITH FINDINGS** (state.json; ledger.jsonl
`run_closed`), with one harness finding (trigger abort via env leak) and one
human-approved repair (run.json). All artifact citations below are under
`runs/20261015-cbtf04-r02/` unless prefixed.

## 1. Weakness list

### W1 — Trigger accepts a leaked launch environment; workload sizing silently overridable
- **Evidence:** `trigger/exit-statuses.json` `abort_cause` and
  `workload_env_actual` (GUEST_BASE_FILE_COUNT=1000, MIN/MAX=15/20 MiB) vs
  `workload_env_intended_script_defaults` (8 × 1024 MiB);
  `trigger/trigger.log:10-14` prints the leaked values in the pipeline
  configuration block; `trigger/trigger.log:50` shows the resulting baseline
  "1000 files · 17431 MiB"; `observer/finding.md` Contradiction 3; ledger
  `preserved_accepted` (harness finding classified) and
  `run_json_repaired`.
- **Why it matters:** the spec's 8×1024 MiB workload is a **window-widening
  measure** (scenario-spec.md §2). The leak shrank the copy window to
  ~65 s (`observer/finding.md`: Backup started 06:48:50.467Z → Done 06:49:55Z);
  with a slower cluster the copy could have completed before the observer
  resolved the Lease holder, turning the run into a zero-injection
  near-miss (spec §5 Fail: "active-copy signal absent"). The r02 injection
  landed only because observer resolution was fast enough. The trigger's
  `${VAR:-default}` pattern (chaos-trigger.sh:9-11) is a defaulting, not a
  pinning, mechanism — any inherited env silently wins.
- **Fix:** trigger diff below (Lead tier): abort with exit 3 before any
  mutation if any workload env differs from spec values; `unset` incidental
  GUEST_* extras. Plus spec edit (human tier) making the clean-launch
  contract explicit.

### W2 — Trigger abort loses all stage outcomes; run.json left stale; human repair required
- **Evidence:** `trigger/exit-statuses.json` `overall`/`make_e2e_full`/
  `observer_internal`/`incremental_followup` — all "interrupted"/"never
  started", ".exit_code never written"; ledger `human_gate_approval` and
  `run_json_repaired` (repair to status=incremental_ready from live CR
  values, replicating scripts/vm-backup.sh:108-119 schema);
  `observer/finding.md` Contradiction 1 (recovery/summary.json reports
  PENDING vs live Done=True — artifact of the repair).
- **Why it matters:** the trigger records nothing incrementally; exit codes
  exist only in the final `exit "$status"` calls (chaos-trigger.sh:122-136).
  Any kill (worker abort, host crash, timeout) between stages leaves the
  lifecycle run.json pointing at a stage the cluster has already passed —
  here it forced a mid-run human gate (07:09Z, ~10 min of dead time) and a
  state file that contradicts recovery evidence (Contradiction 1). This is
  exit-code-conflation-adjacent (skill checklist (b)): no durable
  per-stage record exists anywhere.
- **Fix:** trigger diff below — `record_stage` writes
  `trigger/stage-outcomes.jsonl` incrementally (started/exited per stage);
  harness ticket H2 for the worker-skill side (contract should require
  preserving it and the Lead should index it).

### W3 — Launch/contract discipline: sourcing `.env` wholesale is unguarded and undocumented
- **Evidence:** `contracts/trigger.md:27` instructs the exact launch command
  (`cd /root/virt-cbt-lab && RUN_ID=... KUBECONFIG_PATH=<from .env> bash
  chaos-trigger.sh ...`) but nowhere states the environment must otherwise be
  clean; `trigger/exit-statuses.json` `abort_cause` records the launch sourced
  `/root/virt-cbt-lab/.env` wholesale with `set -a`. `command.txt` shows the
  command itself was faithful — the leak was purely environmental.
- **Why it matters:** the contract text as written *invites* the failure: the
  natural way to "get the host-local kubeconfig from .env" is to source the
  whole file, which is exactly what happened. A trigger-side guard (W1) is
  the hard backstop, but the contract/spec should say "clean env, only
  RUN_ID and KUBECONFIG_PATH" so the worker never relies on the backstop.
- **Fix:** spec edit (human tier) adding the launch-env contract; harness
  ticket H1 to fix the trigger-worker skill/contract template across
  scenarios.

### W4 — Report-fidelity checker citation 1 was a false positive (workload path not in *chaos-run* artifacts)
- **Evidence:** `checkers/report-fidelity.json` (rev 2) prior_citations[0]:
  "/home/cbt-demo/cbt-workload stated as fact without run-scoped evidence" —
  disposition `overturned-with-evidence`, found verbatim in lifecycle
  `fragments/setup.json:7`, `report.json`, `workload-manifest.json`; ledger
  `checker_reject_verified` ("citation INVALID, no edit needed") and
  `checker_verdicts` at 09:20Z.
- **Why it matters:** the checker graded only the chaos-run artifact tree and
  treated the lifecycle checkout's `runs/<id>/` fragments (a different
  directory owned by `make e2e`) as out of scope, generating a REJECT
  citation that consumed a Lead verification cycle and forced a report
  revision loop (two revisions: 09:05Z → 09:20Z). Same class could recur for
  any statement sourced from lifecycle artifacts (workflow.log,
  virt-launcher.log — which the *valid* citations 2-3 used from the same
  tree, inconsistently).
- **Fix:** harness ticket H3 — checker contract must enumerate the run's full
  evidence universe (chaos-run tree **and** the lifecycle `runs/<id>/`
  fragments/logs it is allowed to read) before grading "no run-scoped
  evidence" claims.

### W5 (minor) — No pre-injection observer-side checkpoint-tree capture; qemu-img evidence absent
- **Evidence:** `observer/finding.md` Evidence gaps: "No qemu-img info /
  qemu-img map capture anywhere"; "no observer-side pre-injection tree
  capture" (tree is RecoveryWorker evidence only). Spec §5 requires "Where
  available, record qemu-img info/map" — "where available" made it skippable.
- **Why it matters:** does not invalidate the PASS (restore/hash checks were
  0-failure, `recovery/summary.json`), but the pre-injection vs post tree
  comparison leans on a single writer. Low priority; noted for the Variation
  Decider / next contract, no mandatory edit proposed beyond the ticket.
- **Fix:** harness ticket H4 (observer contract: capture launcher
  checkpoint-tree pre-injection alongside the existing pre-full snapshot).

## 2. Proposed trigger diff (Lead-approvable)

Against `cbt-chaos/scenarios_v2/CBT-F-04/chaos-trigger.sh` (sha256
9a084ad3…9490, per `preflight.json` trigger-checksum-parity).
`bash -n` verified exit 0; the env-guard block smoke-tested: exits 3 under
the exact r02 leak signature (GUEST_BASE_FILE_COUNT=1000/15/20), passes on
clean env; `record_stage` smoke-tested output format. No `krknctl`
invocation is modified, so no Krkn Command Preparer input is required.

```diff
--- chaos-trigger.sh.orig	2026-10-15 13:59:26.172022000 +0530
+++ chaos-trigger.sh.new	2026-10-15 14:01:45.762671547 +0530
@@ -2,6 +2,7 @@
 set -euo pipefail
 
 ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
+SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
 RUN_ID="${RUN_ID:?set RUN_ID to a unique lowercase workflow run id}"
 NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
 VM_OS="${VM_OS:-rhel9}"
@@ -21,6 +22,42 @@
 command -v krknctl >/dev/null || { printf 'krknctl is required\n' >&2; exit 2; }
 command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 2; }
 export KUBECONFIG="$KUBECONFIG_PATH"
+
+# --- Workload-env hardening (proposed after run 20261015-cbtf04-r02) -----------
+# That run's launch sourced a checkout-wide .env wholesale, leaking
+# GUEST_BASE_FILE_COUNT=1000 / 15-20 MiB sizing over the spec's 8 x 1024 MiB
+# (trigger/exit-statuses.json: abort_cause). The spec's documented launch env
+# is RUN_ID (required) plus KUBECONFIG_PATH only. If the inherited environment
+# carries any non-spec workload value, abort before any mutation (exit 3).
+if [[ "${GUEST_BASE_FILE_COUNT}" != "8" \
+   || "${GUEST_FILE_SIZE_MIN_MIB}" != "1024" \
+   || "${GUEST_FILE_SIZE_MAX_MIB}" != "1024" \
+   || "${MANIFEST_VARIANT}" != "large-odf" \
+   || "${VM_OS}" != "rhel9" ]]; then
+  printf 'Refusing to run: workload env differs from the spec-documented values (possible .env leak).\n' >&2
+  printf 'Expected: GUEST_BASE_FILE_COUNT=8 GUEST_FILE_SIZE_MIN_MIB=1024 GUEST_FILE_SIZE_MAX_MIB=1024 MANIFEST_VARIANT=large-odf VM_OS=rhel9\n' >&2
+  printf 'Effective: GUEST_BASE_FILE_COUNT=%s GUEST_FILE_SIZE_MIN_MIB=%s GUEST_FILE_SIZE_MAX_MIB=%s MANIFEST_VARIANT=%s VM_OS=%s\n' \
+    "$GUEST_BASE_FILE_COUNT" "$GUEST_FILE_SIZE_MIN_MIB" "$GUEST_FILE_SIZE_MAX_MIB" "$MANIFEST_VARIANT" "$VM_OS" >&2
+  printf 'Launch with a clean environment: only RUN_ID and KUBECONFIG_PATH set.\n' >&2
+  exit 3
+fi
+# Incidental GUEST_* extras this script does not pin must not reach the make
+# children either (r02 also leaked GUEST_INCREMENTAL_FILE_COUNT/PASSES).
+unset GUEST_INCREMENTAL_FILE_COUNT GUEST_INCREMENTAL_PASSES
+
+# --- Incremental stage-outcome recording (proposed after 20261015-cbtf04-r02) --
+# That run's abort killed the trigger before any stage outcome reached disk,
+# leaving run.json stale and forcing a human-approved repair (ledger.jsonl
+# run_json_repaired). Record each stage outcome as it happens so an abort at
+# any point leaves a durable per-stage record next to the trigger artifacts.
+record_stage() {
+  local stage="$1" status="$2"
+  local out="${EXIT_STATUS_FILE:-$SCRIPT_DIR/runs/$RUN_ID/trigger/stage-outcomes.jsonl}"
+  mkdir -p "$(dirname "$out")"
+  printf '{"stage": "%s", "status": "%s", "utc": "%s"}\n' \
+    "$stage" "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$out"
+}
+
 if [[ -e "$ROOT_DIR/runs/$RUN_ID" ]]; then
   printf 'Run ID %s already exists in this checkout\n' "$RUN_ID" >&2
   exit 1
@@ -96,6 +133,7 @@
 observe_copy_and_disrupt &
 observer_pid=$!
 
+record_stage make_e2e_full started
 if make e2e TYPE=full NAME="$RUN_ID" \
   VM_OS="$VM_OS" \
   NAMESPACE="$NAMESPACE" \
@@ -108,6 +146,7 @@
 else
   e2e_status=$?
 fi
+record_stage make_e2e_full "exited:$e2e_status"
 
 if [[ ! -e "$SIGNAL_FILE" ]]; then
   kill "$observer_pid" 2>/dev/null || true
@@ -118,6 +157,7 @@
   observer_status=$?
 fi
 observer_pid=""
+record_stage observer "exited:$observer_status"
 
 if ((e2e_status != 0)); then
   exit "$e2e_status"
@@ -125,11 +165,13 @@
 if [[ ! -e "$SIGNAL_FILE" ]]; then
   exit "$observer_status"
 fi
+record_stage make_e2e_incremental started
 if make e2e TYPE=incremental VM="$VM_NAME" KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
   followup_status=0
 else
   followup_status=$?
 fi
+record_stage make_e2e_incremental "exited:$followup_status"
 if ((observer_status != 0)); then
   exit "$observer_status"
 fi
```

Design notes for the Lead's review:
- The guard runs **after** the `RUN_ID`/`KUBECONFIG_PATH`/tool checks but
  **before** the run-dir and cluster-resource existence checks — a leaked
  env aborts with zero cluster interaction, so a clean relaunch with a new
  RUN_ID is not blocked by guard dirs (unlike r02, where replay was blocked:
  `trigger/exit-statuses.json` `replay_blocked_by`).
- Deliberate choice: **abort, not override.** A silent pin would mask the
  leak class; an explicit exit 3 makes the launch defect visible in
  `trigger.log` line 1 and teaches the correct launch contract.
- `NAMESPACE` remains overridable (it is identity, not workload sizing), but
  is covered by the spec text edit below requiring deliberate declaration.
- `record_stage` writes inside the scenario's `runs/<RUN_ID>/trigger/`
  (chaos-run tree, contract-owned by the trigger worker), **not** the
  lifecycle `runs/<RUN_ID>/` that `make e2e` owns — avoiding a single-writer
  violation. `EXIT_STATUS_FILE` lets the trigger-worker contract redirect it
  if the run root differs.
- If the Lead prefers the smaller diff, the env-guard block (W1) and the
  `record_stage` additions (W2) are independent; both `bash -n` clean
  separately.

## 3. Proposed spec edits (human gate)

**Edit S1 — §2, after the launch command block (line 33 vicinity), add:**

> The trigger must be launched with a clean environment: only `RUN_ID`
> (required) and `KUBECONFIG_PATH` (plus a deliberate `NAMESPACE` override)
> may be set. Do not source the checkout-wide `.env` or any other
> environment file into the trigger's environment; extract the kubeconfig
> path (e.g. `KUBECONFIG_PATH="$(grep -E '^KUBECONFIG_PATH=' .env | cut -d= -f2-)"`)
> rather than sourcing the file. The trigger pins the spec's workload
> sizing (`GUEST_BASE_FILE_COUNT=8`, `GUEST_FILE_SIZE_MIN_MIB=1024`,
> `GUEST_FILE_SIZE_MAX_MIB=1024`, `MANIFEST_VARIANT=large-odf`,
> `VM_OS=rhel9`) and aborts before any mutation if the inherited
> environment carries different values — run 20261015-cbtf04-r02 lost its
> scripted incremental stage to exactly this leak.

**Edit S2 — §2, after the incremental-follow-up paragraph (line 35 vicinity), add:**

> The trigger records each stage outcome incrementally to
> `runs/<RUN_ID>/trigger/stage-outcomes.jsonl` (one JSON line per stage
> start/exit). If the trigger dies or is killed at any point, this file —
> not the lifecycle `run.json` — is the authoritative record of which
> stages the script itself completed; the Lead reconciles `run.json` from
> live cluster state against it before any repair.

**Edit S3 — §5, tighten the restore bullet (line 76), replace "Where available, record":**

> Record `qemu-img info` and `qemu-img map --output=json` on the preserved
> backup artifact after the full stage and again after the incremental
> stage; if the recovered launcher lacks `qemu-img`, record the absence and
> the reason. File size or `Done=True` alone is insufficient.

(Rationale W5: "where available" let r02 skip it entirely —
`observer/finding.md` Evidence gaps.)

## 4. Harness-ticket drafts

**H1 — Trigger-launch env contract must forbid wholesale `.env` sourcing**
- **Component:** `cbt-chaos-trigger-worker` skill + trigger-contract template.
- **Problem:** r02's launch sourced `/root/virt-cbt-lab/.env` with `set -a`
  to obtain `KUBECONFIG_PATH`, leaking workload env into the trigger
  (`trigger/exit-statuses.json` abort_cause). The contract's own instruction
  "KUBECONFIG_PATH=<host-local kubeconfig from .env>"
  (`contracts/trigger.md:27`) invites this.
- **Proposed change:** skill/contract template requires: (a) launch command
  runs under `env -i`-style clean env or explicitly enumerates the two
  permitted variables; (b) kubeconfig extracted by parsing, never sourcing;
  (c) worker must assert before launch that no `GUEST_*` variable is set.
- **Acceptance:** a contract following the template cannot reproduce the
  r02 leak; worker assertion catches it pre-launch.
- **Evidence:** `runs/20261015-cbtf04-r02/trigger/exit-statuses.json`,
  `contracts/trigger.md:26-29`, ledger `preserved_accepted`.

**H2 — Trigger stage outcomes must be durable before exit-code reliance**
- **Component:** trigger scripts pattern + `cbt-chaos-trigger-worker` skill.
- **Problem:** r02's abort left `.exit_code` never written, run.json stale
  (PENDING vs live Done=True), forcing a human gate + repair
  (`trigger/exit-statuses.json`, ledger `human_gate_approval`,
  `run_json_repaired`; `observer/finding.md` Contradiction 1).
- **Proposed change:** skill requires trigger scripts to append per-stage
  started/exited records to `trigger/stage-outcomes.jsonl` (this scenario's
  diff in §2 implements it); worker must preserve and reference that file in
  `exit-statuses.json`; Lead adds it to `evidence-index.json`.
- **Acceptance:** killing a trigger at any point leaves a machine-readable
  record of completed stages; no mid-run human repair needed for state
  reconciliation.
- **Evidence:** `runs/20261015-cbtf04-r02/trigger/exit-statuses.json`,
  ledger lines 10-11.

**H3 — Report-fidelity checker must enumerate the full evidence universe before "no evidence" citations**
- **Component:** `cbt-chaos-report-checker` skill + check-report contract
  template.
- **Problem:** r02 citation 1 ("/home/cbt-demo/cbt-workload not evidenced")
  was a false positive — the path is verbatim in the lifecycle tree
  (`fragments/setup.json:7`, `report.json`, `workload-manifest.json`) which
  the checker didn't treat as citable, while citations 2-3 used
  `logs/workflow.log` from the same tree. Cost: one REJECT, one Lead
  verification pass, one report revision (ledger `checker_reject_verified`,
  `checker_verdicts` 09:20Z; `checkers/report-fidelity.json` rev 2
  prior_citations[0]).
- **Proposed change:** the checker contract must list every directory the
  report may lawfully cite (chaos-run tree **and** the lifecycle
  `runs/<id>/` fragments/logs, as declared by the Lead); a "no run-scoped
  evidence" citation requires a negative search across that enumerated
  universe, recorded in the verdict.
- **Acceptance:** re-grading r02's original revision against the fixed
  contract yields citations 2-3 only.
- **Evidence:** `runs/20261015-cbtf04-r02/checkers/report-fidelity.json`,
  ledger lines 17-18.

**H4 — Observer should capture pre-injection checkpoint tree**
- **Component:** `cbt-chaos-observer-worker` skill / observer contract
  template.
- **Problem:** the launcher checkpoint-tree state before injection exists
  only as RecoveryWorker post-hoc evidence; the observer's pre-full snapshot
  set omitted it (`observer/finding.md` Evidence gaps), so the "exactly one
  checkpoint advancement" chain comparison has a single-writer weakness.
- **Proposed change:** when the spec's §5 requires checkpoint-tree capture
  "before injection", the observer contract adds it to the arming-time
  snapshot set (read-only `virsh checkpoint-list` is unavailable to the
  observer — capture the tracker CR + vmbackup checkpoint fields instead,
  matching the post-incremental snapshot schema).
- **Acceptance:** next run's observer finding has a pre-injection
  checkpoint-state row with an artifact citation.
- **Evidence:** `runs/20261015-cbtf04-r02/observer/finding.md` (Evidence
  gaps), `recovery/checkpoint-tree.txt` (single-source tree evidence).

## 5. Repeat-failure escalation (twice-rule)

The Lead did not provide a scenario-level `reject-reasons.tsv` with prior
counts in this run's handoff, and per skill rules I did not open other runs'
artifacts; from this run alone no failure class reaches ≥2 occurrences.
**Flag for the Lead:** if the env-leak/launch-discipline class (W1/W3) or
the lost-exit-code class (W2) appears in any prior CBT run's indexed
reasons, the §2 trigger diff and tickets H1/H2 become mandatory under the
twice-rule and should be recorded as approved-or-declined in the ledger.

## 6. Candidate lessons for closeout

1. A `${VAR:-default}` in a trigger is a defaulting mechanism, not a
   workload pin — any inherited environment silently overrides it; triggers
   must assert or pin spec-load-bearing values before mutation
   (`trigger/exit-statuses.json`: `workload_env_actual` vs
   `workload_env_intended_script_defaults`).
2. Exit codes that exist only at final `exit` are lost to any mid-run kill;
   durable incremental stage records are the difference between an
   automatic reconcile and a human gate (`trigger/exit-statuses.json`
   `overall`; ledger `run_json_repaired`).
3. "Get X from the .env file" in a worker contract will be implemented as
   `set -a; source .env` by someone, eventually — contracts must specify
   parse-don't-source for multi-variable env files
   (`contracts/trigger.md:27`; `trigger/exit-statuses.json` abort_cause).
4. A citation checker whose evidence universe is narrower than the
   writer's produces false-positive REJECTs and burns a revision loop
   (`checkers/report-fidelity.json` prior_citations[0], disposition
   overturned-with-evidence).
5. Spec language of the form "where available, record X" degrades to
   "never recorded" — require recording the absence instead
   (`observer/finding.md`: no qemu-img info/map captured anywhere).

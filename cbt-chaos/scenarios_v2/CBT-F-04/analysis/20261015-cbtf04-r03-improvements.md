# Scenario Improvements — CBT-F-04 run 20261015-cbtf04-r03

Post-run scenario-improver output. Scope: weaknesses in the **test itself**
(spec, trigger, worker skills, harness workflow, evidence discipline) proven
by this run's closed artifacts. Proposals only — nothing applied. The trigger
diff is Lead-approvable between runs; spec and SKILL.md edits are
human-gated.

Run context: verdict **PASS WITH FINDINGS** (state.json phase=closed;
ledger.jsonl `run_closed` 15:55:30Z; trigger sha256
`a214796df0d0395833f23d9de07ef9d5a7888d5d1fcbef7bb4779926488d837b` per
state.json and preflight). Recovery from harness-side incremental failures
consumed 5 attempts, 4 Lead state interventions and 2 human gates
(ledger `plan_amended` → `recovery_complete`). Artifacts cited below are under
`runs/20261015-cbtf04-r03/` unless prefixed; files not present in the local
copy are cited via their ledger `refs` entries (they live in the cloud05 run
root).

## 1. Weakness list

### W1 — Incremental-pass sizing is not pinned; `make -include .env` leaks it even under a clean launch env *(mandatory — twice-rule, see §5)*
- **Evidence:** ledger 12:05:30Z `plan_amended`: "spec gap recorded for
  improver: trigger/spec pin baseline sizing but not incremental-pass sizing,
  so checkout .env GUEST_INCREMENTAL_FILE_COUNT=1000 leaked into the plan via
  make -include .env (distinct from env-leak class: this occurred WITH
  clean-env launch)" — refs `runs/20261015-cbtf04-r03/run.json`,
  `workload-manifest.json` (`incremental_file_count_per_pass` 1000→2
  amendment, originals preserved as `.pre-amend-*`). Downstream damage chain:
  attempt-1 guest ENOSPC (66 partial `incremental-01-*.dat` files deleted via
  SSH port-forward, ledger 12:05Z human gate); the write-then-delete churn
  left ~66 GiB of dirty blocks in the CBT bitmap (hypothesis CONFIRMED,
  ledger 14:12Z `recovery_complete`: rbd-du 68 GiB used vs 3 GiB logical);
  retry-3 destination ENOSPC on the 30Gi PVC ("No space left on device",
  launcher backup.go:332, ledger 12:58Z `same_vm_recovery_hard_stop`, refs
  `recovery/incremental-followup-retry3.log`,
  `recovery/launcher-r03-incremental-failure-context.log`). The r02
  env-guard + clean-env launch (chaos-trigger.sh:25-45) closed the
  *launch-environment* vector but not the *Makefile include* vector: the
  checkout Makefile's `-include .env` re-injects `GUEST_*` values inside
  `make e2e`, where the trigger's `unset` cannot reach.
- **Why it matters:** the 1000×1 GiB plan vs ~66 GiB guest free space turned
  the scripted same-VM follow-up into a 5-attempt, 4-intervention recovery
  (~2 h of cluster time, 2 human gates); it also contaminated the evidence
  for product Finding 1 (the 68 GiB dirty-block carryover the report cites
  was partly *harness-induced* churn, not the planned 3 GiB mutation —
  reports/test-run-report.md §CBT product findings, Finding 1). Worst case
  the same gap produces a false BLOCKED verdict on the same-VM criterion
  (spec §5) purely from harness mis-sizing.
- **Fix:** trigger diff §2 (Lead tier) — extend the env guard to
  `GUEST_INCREMENTAL_FILE_COUNT`/`GUEST_INCREMENTAL_PASSES`, and pin both on
  the argv of **both** `make e2e` invocations (command-line assignments
  override anything an included `.env` sets — verified, see §2 notes).
  Spec edit S1 (human tier). Ticket H5 for checkout-side visibility.

### W2 — Trigger-worker liveness probe self-matches its own command line → rogue unapproved lifecycle
- **Evidence:** ledger 11:12Z `harness_incident`: the worker's probe
  `bash -c pgrep -f "make e2e" ...` matched its *own* command line, "fell
  through to success branch, sourced .env wholesale (third occurrence of
  env-leak class), launched rogue unapproved make e2e (TYPE=all, run-id
  20261015091633-silent-wolf-4eb4, PID 1468693) that holds the checkout E2E
  lock and blocked the r03 incremental stage (exit 2)" — refs
  `trigger/trigger.log.raw`, `trigger/stage-outcomes.jsonl`. Containment:
  ledger 11:25:30Z `human_gate_approval` and 11:26Z `rogue_lifecycle_resolved`
  (rogue had run to completion; scoped cleanup of vm/vmi/dv/4×pvc/
  vmbackup×2/tracker/ssh-svc). The clean-env guard held for the *actual*
  trigger launch (same ledger line: "8 files 8192 MiB baseline") — the worker
  bypassed it by launching its own command outside the contract.
- **Why it matters:** this is the exact class the harness exists to prevent:
  an unapproved, unobserved full lifecycle (TYPE=all, a different run-id) ran
  against the shared cluster, consumed cluster resources, held the E2E lock
  (blocking the scripted follow-up), and required a human gate plus scoped
  cleanup. It is a three-way defect: (a) probe self-match (false liveness
  success), (b) success-branch fall-through executing a *new* command rather
  than reporting, (c) the new command sourced `.env` wholesale — re-committing
  the env-leak class a third time.
- **Fix:** worker-skill edit, human gate (ticket H1). Not fixable in the
  trigger script; the trigger's own guard behaved correctly.

### W3 — `incremental_failed` with `total==1` is a workflow dead-end; recovery needed 4 Lead interventions
- **Evidence:** ledger 12:40Z `run_json_status_reset`: "Retry-2 blocked by
  lifecycle state gate (incremental_failed with total=1 has no supported
  transition; TYPE=recover preconditions only admit a FAILED full, r03 full
  SUCCEEDED; CBT-I-02 lesson inapplicable because r03 tracker intact at full
  checkpoint — failure was pre-backup)" — Lead executed a user-approved
  manual `run.json` status reset (`incremental_failed`→`incremental_ready`,
  original preserved as `run.json.pre-status-reset-20261015T103413Z`).
  Recurred: 3rd reset at 13:20Z (with approved failed-CR+PVC deletion and a
  temporary 30Gi→100Gi manifest edit, `manifests/incremental-backup-large-odf.yaml`),
  4th reset at 13:55Z (`guest_baseline_rolled_back`, after the retry-4
  inventory gate found a 10-file guest vs the 8-file baseline,
  `recovery/retry4-inventory-mismatch.txt`). Total: plan amendment + 4 status
  resets + guest rollback + failed-artifact deletion + manifest edit, across
  2 human gates (12:05Z, 13:20Z).
- **Why it matters:** every intervention was a hand-edited state mutation
  outside any supported path — each one is a chance to corrupt the run record
  (mitigated only by the Lead's `.pre-*` originals) and burns Lead/human
  time. The dead-end is structural: the workflow has no transition for
  "incremental failed before any checkpoint advancement, tracker intact at
  the full checkpoint" — precisely the recoverable case.
- **Fix:** ticket H2 (supported retry path in the checkout workflow) + spec
  edit S3 (declare the retry contract so the Lead is not inventing one
  mid-run). The reusable read-only restore-verifier pod the Lead improvised
  for qemu-img capture (ledger 14:45Z) is ticketed separately as H4.

### W4 — Evidence-index ordering: ledger appends after index generation caused two checker REJECT loops
- **Evidence:** ledger 14:45Z `checker_reject_verified`: evidence-sufficiency
  REJECT, citation-2 "ledger/state hash drift classified bookkeeping
  artifact, index regenerated (63 files)"; 15:05Z `evidence_gap_documented`:
  "This is the LAST indexing action; evidence-index.json regenerated (65
  files) after all evidence writes"; 15:35Z `checker_verdicts`:
  "evidence-sufficiency PASS rev4 after 3 revision loops". Root mechanism:
  the Lead appended ledger lines (evidence-gap documentation, corrections)
  after the index was generated, so the indexed ledger checksum went stale
  and the pack-integrity gate REJECTed. The close honored the rule
  deliberately (15:55:30Z `run_closed`: "Ordering rule honored: this is the
  FINAL ledger append; evidence-index.json regenerated after it as the last
  write") — but it was applied from memory, not from any contract text.
- **Why it matters:** each drift cost a checker revision loop (3 loops this
  run) and, in the worst case, ships a closed run whose indexed evidence
  checksums do not match the pack. The rule "index regeneration is the
  literal last write, after every ledger append" exists only as tribal
  knowledge.
- **Fix:** ticket H3 — codify the ordering rule in the team skill and make
  the checkers enforce it mechanically (index mtime/checksum vs ledger
  tail), so the close cannot silently violate it.

## 2. Proposed trigger diff (Lead-approvable)

Against `cbt-chaos/scenarios_v2/CBT-F-04/chaos-trigger.sh` (current sha256
`a214796d…` per state.json/preflight). **Verified:** `bash -n` exit 0 on both
base and patched script; guard smoke matrix (clean env → rc 0 with pins
2/1; leaked `GUEST_INCREMENTAL_FILE_COUNT=1000` → rc 3; leaked
`GUEST_INCREMENTAL_PASSES=3` → rc 3; leaked `GUEST_BASE_FILE_COUNT=1000` →
rc 3; explicitly correct values → rc 0); make-override proof: with a
checkout `.env` containing `GUEST_INCREMENTAL_FILE_COUNT=1000` and a
`-include .env` Makefile, `make show` yields 1000 but
`make show GUEST_INCREMENTAL_FILE_COUNT=2 GUEST_INCREMENTAL_PASSES=1`
yields 2/1 — command-line assignments beat the included file, which is the
mechanism this diff relies on. **No `krknctl` invocation is added or
modified, so no Krkn Command Preparer input is required.**

```diff
--- chaos-trigger.sh	2026-10-15 (sha256 a214796d…)
+++ chaos-trigger.sh	(proposed after run 20261015-cbtf04-r03)
@@ -32,11 +32,13 @@
    || "${GUEST_FILE_SIZE_MIN_MIB}" != "1024" \
    || "${GUEST_FILE_SIZE_MAX_MIB}" != "1024" \
    || "${MANIFEST_VARIANT}" != "large-odf" \
-   || "${VM_OS}" != "rhel9" ]]; then
+   || "${VM_OS}" != "rhel9" \
+   || "${GUEST_INCREMENTAL_FILE_COUNT:-2}" != "2" \
+   || "${GUEST_INCREMENTAL_PASSES:-1}" != "1" ]]; then
   printf 'Refusing to run: workload env differs from the spec-documented values (possible .env leak).\n' >&2
-  printf 'Expected: GUEST_BASE_FILE_COUNT=8 GUEST_FILE_SIZE_MIN_MIB=1024 GUEST_FILE_SIZE_MAX_MIB=1024 MANIFEST_VARIANT=large-odf VM_OS=rhel9\n' >&2
-  printf 'Effective: GUEST_BASE_FILE_COUNT=%s GUEST_FILE_SIZE_MIN_MIB=%s GUEST_FILE_SIZE_MAX_MIB=%s MANIFEST_VARIANT=%s VM_OS=%s\n' \
-    "$GUEST_BASE_FILE_COUNT" "$GUEST_FILE_SIZE_MIN_MIB" "$GUEST_FILE_SIZE_MAX_MIB" "$MANIFEST_VARIANT" "$VM_OS" >&2
+  printf 'Expected: GUEST_BASE_FILE_COUNT=8 GUEST_FILE_SIZE_MIN_MIB=1024 GUEST_FILE_SIZE_MAX_MIB=1024 MANIFEST_VARIANT=large-odf VM_OS=rhel9 GUEST_INCREMENTAL_FILE_COUNT=2 GUEST_INCREMENTAL_PASSES=1\n' >&2
+  printf 'Effective: GUEST_BASE_FILE_COUNT=%s GUEST_FILE_SIZE_MIN_MIB=%s GUEST_FILE_SIZE_MAX_MIB=%s MANIFEST_VARIANT=%s VM_OS=%s GUEST_INCREMENTAL_FILE_COUNT=%s GUEST_INCREMENTAL_PASSES=%s\n' \
+    "$GUEST_BASE_FILE_COUNT" "$GUEST_FILE_SIZE_MIN_MIB" "$GUEST_FILE_SIZE_MAX_MIB" "$MANIFEST_VARIANT" "$VM_OS" "${GUEST_INCREMENTAL_FILE_COUNT:-<unset>}" "${GUEST_INCREMENTAL_PASSES:-<unset>}" >&2
   printf 'Launch with a clean environment: only RUN_ID and KUBECONFIG_PATH set.\n' >&2
   exit 3
 fi
@@ -44,6 +46,15 @@
 # children either (r02 also leaked GUEST_INCREMENTAL_FILE_COUNT/PASSES).
 unset GUEST_INCREMENTAL_FILE_COUNT GUEST_INCREMENTAL_PASSES
 
+# --- Incremental-pass sizing pin (added after run 20261015-cbtf04-r03) --------
+# A clean launch env does not close the checkout Makefile's -include .env
+# path: that run leaked GUEST_INCREMENTAL_FILE_COUNT=1000 from .env into the
+# incremental plan despite the clean-env launch (ledger plan_amended), causing
+# guest ENOSPC (attempt-1) and destination ENOSPC (retry-3). Make command-line
+# assignments override anything an included .env sets, so pin them on argv.
+GUEST_INCREMENTAL_FILE_COUNT="2"
+GUEST_INCREMENTAL_PASSES="1"
+
 # --- Incremental stage-outcome recording (added after run 20261015-cbtf04-r02) -
 # That run's abort killed the trigger before any stage outcome reached disk,
 # leaving run.json stale and forcing a human-approved repair (ledger.jsonl
@@ -140,6 +151,8 @@
   GUEST_BASE_FILE_COUNT="$GUEST_BASE_FILE_COUNT" \
   GUEST_FILE_SIZE_MIN_MIB="$GUEST_FILE_SIZE_MIN_MIB" \
   GUEST_FILE_SIZE_MAX_MIB="$GUEST_FILE_SIZE_MAX_MIB" \
+  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
+  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
+  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
   e2e_status=0
 else
@@ -165,7 +178,10 @@
   exit "$observer_status"
 fi
 record_stage make_e2e_incremental started
-if make e2e TYPE=incremental VM="$VM_NAME" KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
+if make e2e TYPE=incremental VM="$VM_NAME" \
+  GUEST_INCREMENTAL_FILE_COUNT="$GUEST_INCREMENTAL_FILE_COUNT" \
+  GUEST_INCREMENTAL_PASSES="$GUEST_INCREMENTAL_PASSES" \
+  KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
   followup_status=0
 else
   followup_status=$?
```

Design notes for the Lead's review:
- **Three layers, one class:** (1) the guard now also aborts (exit 3) if the
  *launch env* carries non-spec incremental values — same r02 pattern, now
  closed for these two variables; (2) `unset` still strips them from the
  child environment; (3) the argv pin defeats the `-include .env` vector
  inside make, which (1)+(2) cannot reach. All three are needed: (1) makes
  the leak visible, (3) makes it ineffective.
- **The pin goes on both make invocations.** r03's `run.json` carried
  `guest.incremental_file_count_per_pass=1000` from the *full* stage (the
  lifecycle plan is written there), so pinning only the incremental line
  would leave the plan mis-sized.
- **Values 2 files / 1 pass** match the r03 amended, human-approved plan
  (ledger 12:05:30Z: hash-deterministic `incremental-01-000001.dat` /
  `-000002.dat`, 1 GiB each). If the Variation Decider chooses different
  next-run sizing, change the pin constants together with spec edit S1 —
  the trigger and spec must not disagree.
- `GUEST_INCREMENTAL_PASSES` is pinned to `1` and pinned on argv for
  symmetry/visibility even though the spec's follow-up is single-pass; the
  guard would catch a leaked `GUEST_INCREMENTAL_PASSES` from `.env` either
  way (it was among r02's leaked variables per chaos-trigger.sh:43-45).

## 3. Proposed spec edits (human gate)

**Edit S1 — §2, extend the documented make invocation and the pin paragraph
(lines 26-45 vicinity).** Update the documented command to:

```sh
make e2e TYPE=full NAME="$RUN_ID" VM_OS="${VM_OS:-rhel9}" \
  MANIFEST_VARIANT="${MANIFEST_VARIANT:-large-odf}" \
  GUEST_BASE_FILE_COUNT="${GUEST_BASE_FILE_COUNT:-8}" \
  GUEST_FILE_SIZE_MIN_MIB="${GUEST_FILE_SIZE_MIN_MIB:-1024}" \
  GUEST_FILE_SIZE_MAX_MIB="${GUEST_FILE_SIZE_MAX_MIB:-1024}" \
  GUEST_INCREMENTAL_FILE_COUNT=2 GUEST_INCREMENTAL_PASSES=1
```

and append to the clean-launch paragraph (after "…lost its scripted
incremental stage to exactly this leak."):

> A clean launch environment does not close the checkout Makefile's
> `-include .env` path: run 20261015-cbtf04-r03 launched clean yet its
> incremental plan came out as 1000 files (checkout `.env`
> `GUEST_INCREMENTAL_FILE_COUNT=1000`), causing guest ENOSPC, a
> dirty-block carryover, and a destination ENOSPC retry before a
> human-approved amendment to 2 files. The trigger therefore pins the
> incremental-pass sizing (`GUEST_INCREMENTAL_FILE_COUNT=2`,
> `GUEST_INCREMENTAL_PASSES=1`) on the command line of **both** `make e2e`
> invocations — make command-line assignments override included-file
> values — and aborts (exit 3) if the inherited environment carries
> different values for them.

**Edit S2 — §2, incremental-follow-up paragraph (line 47 vicinity), add
after the BLOCKED sentence:**

> The incremental destination PVC must be sized against the *peak dirty
> volume* the copy may carry (change tracking retains blocks from writes to
> guest files that are later deleted between checkpoints), not the logical
> data change; record the sizing rationale with the run. An undersized
> destination failing with `No space left on device` is a harness-caused
> failure and must be labeled as such, never counted against the product.

(Rationale W1: r03's 30Gi destination held a 3 GiB logical change but ~68 GiB
of dirty blocks — reports/test-run-report.md Finding 1; ledger 12:58Z.)

**Edit S3 — §2, after the stage-outcomes paragraph (line 54 vicinity), add:**

> If the same-VM incremental stage fails *before any tracker advancement*
> (tracker still at the full checkpoint, no child checkpoint recorded), the
> failure is retryable on the same VM without a new lifecycle: delete the
> failed backup object and its destination PVC (checkpoint names are
> timestamp-suffixed, so a recreated object cannot collide), reset the
> lifecycle run record to `incremental_ready`, and re-run the stage. The
> supported workflow currently lacks this transition (its recover
> preconditions admit only a FAILED full); until harness ticket H2 lands,
> the reset is a Lead-executed, human-gated procedure that must preserve the
> original run record (`.pre-status-reset-*` suffix) and verify the tracker
> against the full checkpoint before re-arming.

(Rationale W3: ledger 12:40Z documents the dead-end and the improvised,
4-times-repeated procedure.)

## 4. Harness-ticket drafts

**H1 — Worker liveness probes must not self-match; probe failure must never execute a fallback command**
- **Component:** `cbt-chaos-trigger-worker` SKILL.md (human gate) + trigger
  contract template.
- **Problem:** r03's trigger worker probed liveness with
  `bash -c pgrep -f "make e2e"`, which matched the probe's own command line;
  the success-branch fall-through sourced `.env` wholesale and launched an
  unapproved `make e2e TYPE=all` rogue lifecycle
  (20261015091633-silent-wolf-4eb4, PID 1468693) that held the E2E lock and
  blocked the r03 incremental stage (ledger 11:12Z `harness_incident`;
  11:25:30Z/11:26Z human gate + scoped cleanup).
- **Proposed change:** skill rule: (a) process-match probes must exclude the
  probing shell itself (match on a recorded PID via `kill -0`, or
  `pgrep -f` output filtered by `$$`/`$PPID` and the worker's own argv, or
  an anchored pattern that cannot match the probe command line); (b) a
  probe's failure branch may only *report* — it must never source env files
  or start any command not in the contract; (c) workers never source
  checkout `.env` (re-affirm r02's H1 rule — this incident is its third
  violation).
- **Acceptance:** a worker following the skill cannot reproduce the
  self-match; a dead trigger process results in a report to the Lead, not a
  new lifecycle.
- **Evidence:** ledger 11:12Z (`trigger/trigger.log.raw`,
  `trigger/stage-outcomes.jsonl`), 11:26Z `rogue_lifecycle_resolved`.

**H2 — Supported retry path for `incremental_failed` with `total==1` and tracker intact at the full checkpoint**
- **Component:** virt-cbt-lab checkout workflow (`make e2e` state machine /
  `TYPE=recover` preconditions).
- **Problem:** `incremental_failed` with `total==1` has no supported
  transition (recover admits only a FAILED full); r03 required 4 Lead-executed
  `run.json` status resets, a guest rollback, a failed-CR/PVC deletion, and a
  temporary manifest edit across 2 human gates (ledger 12:40Z, 12:58Z,
  13:20Z, 13:55Z).
- **Proposed change:** extend the workflow's recover preconditions to admit
  `incremental_failed` when the tracker's `latestCheckpoint` still equals
  the recorded full checkpoint (failure pre-backup): transition to
  `incremental_ready`, drop `current_incremental_pass`, and require live
  tracker verification before re-arming. Keep the operator-visible audit
  (preserve original record with suffix) that the Lead improvised.
- **Acceptance:** the r03 retry sequence (amend plan → reset → re-run stage)
  completes with zero manual state-file edits.
- **Evidence:** ledger 12:40Z `run_json_status_reset`
  (`runs/20261015-cbtf04-r03/run.json` +
  `run.json.pre-status-reset-20261015T103413Z`), 13:20Z, 13:55Z.

**H3 — Evidence-index regeneration must be the literal last write; checkers enforce it mechanically**
- **Component:** `cbt-chaos-team` skill (close procedure) +
  evidence-sufficiency checker contract.
- **Problem:** ledger appends after index generation made the indexed ledger
  checksum stale and caused two checker REJECT/revision loops this run
  (ledger 14:45Z citation-2 "ledger/state hash drift", 15:05Z regeneration to
  65 files, 15:35Z "PASS rev4 after 3 revision loops"); the ordering rule was
  honored at close only from memory (15:55:30Z `run_closed`).
- **Proposed change:** (a) team-skill close procedure: after the FINAL ledger
  append, regenerate `evidence-index.json` as the last write, and never
  append to the ledger afterwards (corrections become a new close cycle);
  (b) checker contract: the pack-integrity check verifies the index against
  the *current* ledger tail (regenerate-and-compare), so drift is caught
  before verdict rather than as a citation.
- **Acceptance:** a run closed per the procedure passes pack-integrity on
  the first checker pass; deliberately appending after regeneration yields a
  REJECT naming the ordering rule.
- **Evidence:** ledger 14:45Z, 15:05Z, 15:35Z, 15:55:30Z.

**H4 — Reusable read-only qemu-img evidence-capture pattern (restore-helper pod)**
- **Component:** observer/recovery contract templates +
  `cbt-chaos-observer-worker` skill.
- **Problem:** preserved backup artifacts live on detached destination PVCs,
  unreachable read-only from the launcher; every in-run qemu-img attempt hit
  only 0-byte detached hotplug stubs (observer/finding.md §criterion 6,
  "qemu-img binary present and info/map executed, but only on detached
  0-byte hotplug stubs"; ledger 11:25Z `preserved_accepted`), and closing the
  gap required the Lead to improvise a temporary restore-helper pod mounting
  both backup PVCs readOnly (ledger 14:45Z, ref
  `recovery/qemu-img-preserved-artifacts.txt`).
- **Proposed change:** standardize the improvised pattern as a contract
  option: a temporary pod mounting the run's backup PVCs `readOnly: true`,
  running `qemu-img info` + `qemu-img map --output=json`, with the pod spec
  and output captured as run evidence; document the known limitation that a
  backing-file chain resolving to the live launcher disk still cannot be
  mapped this way (spec §5/S3 fallback stands, ledger 15:05Z).
- **Acceptance:** next run captures `qemu-img info/map` on the preserved
  full artifact without Lead improvisation; the incremental chain-map
  limitation is recorded with its fallback corroboration as in r03.
- **Evidence:** observer/finding.md (criterion 6, Missing observations),
  ledger 14:45Z, 15:05Z.

**H5 — Checkout e2e stages must log effective `GUEST_*` workload sizing at stage start**
- **Component:** virt-cbt-lab checkout workflow (`scripts/e2e-stage.sh` /
  stage logging).
- **Problem:** the 1000-file incremental plan was invisible until the guest
  hit ENOSPC — nothing in the stage output showed that `-include .env` had
  overridden the intended sizing; the leak was diagnosed only from the
  guest's 66 partial files and the run.json amendment (ledger 12:05:30Z).
- **Proposed change:** each e2e stage prints its effective workload plan
  (base count/sizes, incremental count/passes, source of each value: argv /
  .env / default) as the first workflow.log lines.
- **Acceptance:** reproducing the r03 leak shows
  `GUEST_INCREMENTAL_FILE_COUNT=1000 (source: .env)` in the stage log line 1,
  detectable by the observer or Lead before any mutation.
- **Evidence:** ledger 12:05:30Z `plan_amended` (refs `run.json`,
  `workload-manifest.json`).

## 5. Repeat-failure escalation (twice-rule)

The env-leak class has now reached **three occurrences** — above the ≥2
threshold — making the closing edit **mandatory** (approved or explicitly
declined with a reason recorded in the ledger):

1. Learning 2026-10-13 CBT-I-06 (r01) — provided in the Lead's handoff.
2. r02: launch sourced `.env` wholesale, abort_cause in
   `trigger/exit-statuses.json`; closed by the r02 env-guard + spec S1
   (analysis/20261015-cbtf04-r02-improvements.md W1/W3, applied for r03).
3. r03: two new vectors of the same class — (a) the trigger worker's rogue
   launch re-sourced `.env` (ledger 11:12Z, "third occurrence of env-leak
   class"), and (b) the *spec gap* documented at 12:05:30Z:
   `make -include .env` leaked `GUEST_INCREMENTAL_FILE_COUNT=1000` **despite**
   the clean-env launch — the r02 fix closed only the launch-env vector.

**Mandatory diffs:** the §2 trigger diff (Lead tier) closes vector (b) at
the trigger; ticket H1 (human gate) closes vector (a) at the worker skill;
spec edit S1 (human gate) documents the complete contract. Per the
twice-rule the human must either approve these or record a declined reason
in the ledger.

Note: the scenario-level `reject-reasons.tsv` carries only the two r02
report-fidelity classes (report-presents-reconstructed-command-as-run,
unsourced-precise-time-claim); neither recurred in r03 (report-fidelity
PASS on first revision, ledger 15:55Z), so no other class is escalated.

## 6. Candidate lessons for closeout

1. A clean launch environment does not sanitize the *build system*: a
   Makefile `-include .env` re-injects variables inside every `make` child,
   beyond any launch-env guard — pin load-bearing values on the make argv,
   which overrides included files (ledger 12:05:30Z `plan_amended`; §2
   override proof).
2. A `pgrep -f` liveness probe matches the prober's own command line;
   probes must exclude self and their failure branch must only report —
   otherwise a dead process becomes an unapproved new lifecycle
   (ledger 11:12Z `harness_incident`).
3. CBT tracks writes, not liveness: write-then-delete churn between
   checkpoints inflates an incremental to peak dirty volume, so destination
   sizing must use dirty-volume headroom, not logical change (ledger 14:12Z
   `recovery_complete`; reports/test-run-report.md Finding 1).
4. A workflow state machine without a transition for "failed before
   checkpoint, tracker intact" converts every pre-backup failure into
   repeated human-gated state-file surgery (ledger 12:40Z, 13:20Z, 13:55Z —
   four resets).
5. Any write to the ledger after evidence-index generation invalidates the
   pack's checksums; index regeneration must be the literal last write of
   the close, enforced by the checker rather than remembered by the Lead
   (ledger 14:45Z → 15:05Z → 15:35Z, three revision loops).
6. Preserved backup artifacts on detached PVCs are invisible to read-only
   in-pod inspection; a readOnly-mount helper pod is the repeatable capture
   pattern (ledger 14:45Z; observer/finding.md criterion 6).

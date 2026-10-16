# Scenario Improvements — CBT-F-01 run `20261016-cbt-f-01-r04`

Post-run scenario-improver output. Scope: weaknesses in the **test itself**
(spec, trigger, driver, per-run contracts, worker behaviour, evaluator
coverage, evidence discipline) proven by this run's closed artifacts.
**Proposals only — nothing is applied by this document.** Spec and skill edits
are human-gated; the trigger/driver diffs are Lead-approvable between runs.

Run context (read from the closed pack, not restated from memory):

- Run verdict **BLOCKED (evidence sufficiency)**, deterministic core **PASS**
  (`state.json` `.verdict=BLOCKED`, `.deterministic_core=PASS`;
  `ledger.jsonl` `run_closed`). The deterministic evaluator returned PASS 8/8
  (`verdict.json` `.verdict=PASS`, `.checks[].status`; recorded sha256
  `dba29ae4…`), and the evidence-sufficiency checker REJECTed spec-4.3
  (`checkers/evidence-sufficiency.json` `.reject_reasons[0]`).
- Wall clock: driver legs 148 s + 50 s + 380 s + 1 s = 579 s
  (`driver-timings.json` `.legs[]`; `trigger/stage-outcomes.jsonl`).
- Script hashes for the diffs below: `chaos-trigger.sh` sha256
  `4e6e35f7c1c2f592d662e64034e1faf66b97665f35b3ba346b774139a502dc24`,
  `run-cbt-f-01.sh` sha256
  `e0dbd7e11aa06ee722ebb553abc9a7786c4cb27c6dd494e26109f89a2b67f667`.
- Paths below are relative to the scenario dir
  `cbt-chaos/scenarios_v2/CBT-F-01/` unless prefixed; artifacts inside the run
  are under `runs/20261016-cbt-f-01-r04/`.

---

## 0. The mandatory item in one line

Spec §4 bullet 3 requires the launcher's libvirt checkpoint tree **before
injection and after VM recovery**
(`scenario-spec.md:47`, evidence command `scenario-spec.md:63`). No writer owns
the *post-recovery* capture, the trigger only ever writes the pre-injection one
(`trigger/trigger.log:9`), and `scenario-verdict.sh` does not model the
criterion at all (its 8 check ids, `scenario-verdict.sh:167-178`, contain no
checkpoint-tree check). The result is the exact failure this run closed on: a
script PASS that is narrower than a spec PASS.

---

## 1. Weakness list

### W1 — spec-4.3 libvirt checkpoint tree: **no writer owns the post-recovery capture** *(mandatory)*

- **Symptom (artifact + field).** The only checkpoint-tree record anywhere in
  the frozen pack is `runs/20261016-cbt-f-01-r04/trigger/trigger.log` line 9 —
  `Pre-backup checkpoint tree (exit=0, lines=0; empty is expected on a fresh
  lifecycle):` — preceded by four `Checkpoint tree capture failed (exit=1,
  lines=0); retrying on the next poll.` lines (`trigger/trigger.log` lines
  4-7). No post-injection / post-recovery capture exists in any pack file. The
  checker recorded this as `checkers/evidence-sufficiency.json`
  `.missing_evidence[0]` and `.reject_reasons[0]`; the observer states it
  explicitly: `observer/finding.md` "Gap — no `oc exec` (read-only)" ("the
  libvirt checkpoint tree … was not performed"), corroborated by
  `observer/FINAL` (its `files_written` list has no checkpoint-tree file).
- **Root cause (established, not a hypothesis).** Two independent harness
  choices, both visible in files:
  1. The trigger captures the tree **only once, pre-injection**, inside
     `observe_copy_then_disrupt()`
     (`chaos-trigger.sh:357-358`, logged at `:372`). Its
     `verify_launcher_disruption_and_recovery()`
     (`chaos-trigger.sh:281-333`) proves the replacement launcher is Ready and
     writes `effect-check.json`, but never re-captures the tree.
  2. The **per-run observer contract banned the query**: "Read-only: no `oc
     delete/apply/patch/exec`" (`runs/…r04/contracts/observer.md:65`), and its
     observation sequence never mentions the checkpoint tree
     (`contracts/observer.md:46-58`). So the one writer that is positioned after
     recovery was told not to run `oc exec`.
- **Hypothesis (labelled).** The Lead hand-authored this run's observer
  contract rather than generating it from the scenario's template. The
  *parameterized* template `cbt-chaos/contracts/observer.md` **already mandates
  exactly this capture** — lines 72-75: "before injection, capture the
  checkpoint-tree state via the launcher compute container (`virsh
  checkpoint-list --tree`) into `watches/checkpoint-tree-pre.txt` …; capture
  again at PRESERVED into `evidence-terminal/checkpoint-tree-post.txt`" — but
  the per-run contract (`runs/…r04/contracts/observer.md`) is CBT-F-01 worded,
  cites `docs/agent-workflow-audit.md` and `watch-resource.sh`, and contains
  neither the capture rule nor `__`-tokens, i.e. it was not produced by
  `contract-gen.sh` from that template. `contract-gen.sh:41-49` writes
  `CBT-F-04 run __RUN_ID__`-headed contracts (the template header is
  `contracts/observer.md:1`), which this file is not. Causally: the mandate
  existed in the template and was dropped when the contract was written by
  hand.
  - Supporting evidence that the spec intended the post capture to run on the
    *recovered* launcher, not the pre-injection one: the spec's own evidence
    command is `oc exec … <replacement-launcher-pod> … --tree`
    (`scenario-spec.md:63`) — it names the replacement pod. So the spec is
    internally consistent; only the harness failed to execute it.
- **Why it matters.** This is the whole verdict. The run produced a complete,
  independently-corroborated injection and recovery but could not establish
  one §4 criterion, so it closed BLOCKED and could not be graded PASS. It also
  silently passed the same way in r03 (`ledger.jsonl` `verdict` line:
  "r03 passed on the same gap because it ran without an evidence checker"), so
  the gap is a *repeat* failure class hidden by evaluator under-coverage (W2).

> ### Recommendation for the fix set: **(b) — the Trigger Worker captures before *and* after**
>
> **Recommended option: (b)**, with (d)+(e) below as the companion work.
>
> | | (a) observer captures pre + post | **(b) trigger captures pre + post (recommended)** | (c) narrow the spec to tracker evidence |
> |---|---|---|---|
> | Change surface | per-run observer contract (which today has **no scenario-owned template** — see H5), plus flipping its `no oc exec` ban (`contracts/observer.md:65`), plus a capture step after recovery | **one file**: `chaos-trigger.sh` — the pre capture already exists, only the post capture is missing | spec `scenario-spec.md:47` + `:63` only |
> | Evidence lands in | `observer/watches/` (not enumerated as machine-checkable in spec §2 line 23) | `trigger/` — the directory spec §2 line 23 already declares "deterministic and machine-checkable", and which the evaluator already reads | — |
> | Timing | couples to the observer's late-`PRESERVED` bug (W5): the template says "capture again at PRESERVED", and this run's PRESERVED was 6m22s late | reuses the trigger's existing wait for the replacement launcher Ready inside `verify_launcher_disruption_and_recovery()` (`chaos-trigger.sh:285-318`) — the capture happens exactly at VM recovery, no new wait | — |
> | Independence | stronger: an independent witness for a spec criterion | the injector writes it, but the checkpoint tree is a read-only environmental fact and spec-4.3 states no independence requirement (injection independence is spec-4.1, separately satisfied) | — |
> | Verdict impact | satisfies spec-4.3 if PRESERVED also lands | satisfies spec-4.3 with the least new coordination | discards the guest-side half of the criterion |
>
> (b) is the smallest coherent fix because the trigger already holds the only
> code path that (i) resolves the *replacement* launcher's name+uid
> (`chaos-trigger.sh:298-309`, `replacement_name`/`replacement_uid`), (ii)
> waits for it to be Ready inside the recovery window (`:318`), and (iii) writes
> atomically into `trigger/` (the dir the evaluator and checkers already grade).
> (a) is *strictly stronger* on independence and should be composed later once
> H5 gives CBT-F-01 a scenario-owned observer contract — but it is a larger
> change today and it inherits W5's late-handoff risk. (c) is not recommended:
> the spec is internally consistent, the guest-side checkpoint is precisely the
> thing §4.3 exists to distinguish from tracker advancement, and narrowing
> would delete real signal to make a REJECT go away.

### W2 — `scenario-verdict.sh` does not model spec-4.3, so its PASS reads as a spec PASS

- **Symptom (artifact + field).** `verdict.json` `.verdict="PASS"`,
  `.verdict_reason="injection independently evidenced, the interrupted full
  backup failed cleanly, CBT recovered, and restore/clean-lifecycle checks
  passed"` with **8/8** checks PASS — while
  `checkers/evidence-sufficiency.json` `.verdict="REJECT"` on the same run. The
  evaluator's check set is `scenario-verdict.sh:167-178`: `run-id-consistency`,
  `injection-signal`, `launcher-replacement`, `backup-interrupted`,
  `tracker-not-advanced`, `cbt-recovered`, `same-vm-recovery`,
  `clean-lifecycle`. `tracker-not-advanced` covers the **tracker** half of
  §4.3 only; there is no check for the libvirt-tree half, and nothing in the
  script's header states the omission (`scenario-verdict.sh:44-57` lists the
  checks; `:60-76` the verdict rules) — the header claims "Missing mandatory
  evidence can therefore never yield PASS" (`:76`), which is true only over the
  modelled checks.
- **Root cause (established).** The evaluator was written against the tracker
  half of §4.3 (audit gap G2 → check `tracker-not-advanced`,
  `docs/agent-workflow-audit.md` §5 G2) and predates the trigger writing any
  tree artifact at all (`docs/agent-workflow-audit.md` §5 G1/G3). No artifact
  of the tree's shape existed for it to read, so the criterion was never
  modelled. The ledger records the resulting disagreement as a known harness
  finding (`ledger.jsonl` `verdict` line: "the evaluator does not model the
  spec criterion, so its PASS is narrower than the spec's PASS").
- **Why it matters.** A machine PASS that is narrower than the written
  criterion is the most dangerous artifact the harness can emit: the run under
  analysis was only saved by an *additional* LLM evidence checker that the
  r03 run did not have. The contract in the script's own header invites the
  misread.
- **Fix:** §3 (evaluator diff). Owner: harness (`cbt-chaos/scenario-verdict.sh`)
  + a `tests/test-scenario-verdict.sh` case.

### W3 — `--plan` and the live collision guard encode the same policy twice and disagree / lose the refusal

- **Symptom (artifact + field).** A duplicate trigger launch this run
  "refused harmlessly on the trigger's collision guard" (given; the guard's two
  implementations are visible in the script): the `--plan` branch classifies the
  whole scenario run dir entry-by-entry
  (`chaos-trigger.sh:91-138`: allows `contracts|observer|trigger`, allows
  `recovery|checkers|reports` only when empty, allows
  `ledger|state|evidence-index|preflight`, refuses anything else), whereas the
  **live** branch (`chaos-trigger.sh:175-179`) refuses only if the *lifecycle*
  run dir exists or `trigger/` is non-empty, and then does the live-resource
  check (`:181-188`). The driver has a *third* phrasing of the same idea
  (`run-cbt-f-01.sh:60-75`: refuses if `runs/<RUN_ID>` exists, if
  `trigger/` is non-empty, or if `driver-timings.json|verdict.json|driver.log`
  exists). Three files/locations, three different rules.
- **Root cause (established).** Guard logic was added per-surface (audit G1/G8
  added `--plan`; preflight check 6 cites `chaos-trigger.sh:80-163` and check 5
  cites `chaos-trigger.sh:92-135` + `run-cbt-f-01.sh:52-71` as the documented
  guards — `preflight.json` checks 5 and 6 `evidence[]`), with no shared
  helper. Consequences visible/foreseeable from that divergence:
  (i) a stray file in the scenario run dir passes the live guard but fails
  `--plan`; (ii) the refusal is stderr-only (`chaos-trigger.sh:177-179`,
  `:94-95`) — a refused *duplicate* attempt leaves **no artifact**, so a reader
  of the closed pack cannot tell it happened (this run's pack has no record of
  the duplicate launch anywhere; `find` + `grep` over the pack for
  `refus|already exists|collision` returns nothing).
- **Hypothesis (labelled).** The refusal was "harmless" only because the
  duplicate was refused; had the two guards disagreed in the other direction
  (live guard more permissive than `--plan`), the duplicate would have
  re-entered `observe_copy_then_disrupt` and re-armed a second log-follow +
  delete against a run already in flight.
- **Why it matters.** The guard is the last barrier against a second injection
  into a live run; it should be one function, and its firing should be an
  evidence event.
- **Fix:** H2 ticket. Owner: Lead (guard code lives in the scenario-owned
  `chaos-trigger.sh` and `run-cbt-f-01.sh`).

### W4 — trigger-worker launch probe self-matched (`pgrep -f`), third occurrence of the class

- **Symptom.** "The trigger worker's first launch self-refused on a
  self-matching `pgrep`" (given). The scenario trigger itself contains no
  `pgrep` (`chaos-trigger.sh` — none), so the self-match was in the *worker's*
  launch/liveness guard, not the script.
- **Root cause (hypothesis, labelled).** Identical to the CBT-F-04 r03
  `harness_incident` class: `pgrep -f "<pattern>"` matches the probing shell's
  own command line. In F-04 that fell *through* to the success branch and
  launched a rogue unapproved lifecycle
  (`scenarios_v2/CBT-F-04/analysis/20261015-cbtf04-r03-improvements.md`
  W2/H1 — "the worker's probe `bash -c pgrep -f "make e2e" ...` matched its
  *own* command line"); here the same defect self-refused instead. Same defect,
  opposite sign of the failure — this time it was safe, by luck.
- **Why it matters.** It is the **third** occurrence of the probe-self-match
  class (F-04 r03 incident + its H1 ticket + this run), so under the twice-rule
  it is a mandatory close. A guard whose result depends on whether the probe
  text appears in its own argv cannot be trusted in either direction.
- **Fix:** H1 ticket. Owner: `cbt-chaos-trigger-worker` SKILL.md (human gate).

### W5 — late `PRESERVED` (6 m 22 s) from the observer's own poll-loop bug

- **Symptom (artifact + field).** `observer/PRESERVED` `.utc=2026-10-16T01:19:00Z`
  — 6 m 22 s after leg 1 became terminal (`observer/finding.md`, interrupted
  backup `lastTransitionTime=2026-10-16T01:12:38Z`) and after the retry began
  (`runs/…r04/run.json` `recovery.attempts[0].started_at=01:12:53Z`;
  `checkers/evidence-sufficiency.json` `false_positives_checked` "Late
  preservation write"). The observer self-reports the mechanism in
  `observer/finding.md` "Cadence effect on the handoffs": a 3 s copy-window poll
  contained "a bash arithmetic test fed by a multi-line `jq` result, which
  errored every iteration and defeated its early exit", so the leg-1 stream
  data surfaced only at the loop's 300 s cap (~01:16:17Z).
- **Root cause (established, self-reported).** The observer's wait loop
  silently tolerated a test error every iteration instead of failing loudly, so
  a broken early-exit degraded to a full-timeout wait. Streams stayed
  continuous and nothing was destroyed (`observer/FINAL` `.remaining_pids=[]`,
  all `watches/*.helper.stderr` 0 bytes), so this is a latency/handoff defect,
  not a data-loss one — but the "preserve-before-recover" handoff the observer
  contract is built around (`contracts/observer.md:54-55`) was 6 m 22 s late,
  past the start of recovery.
- **Related (same run, same window):** the driver runs the evaluator as its
  leg 4/4 (`run-cbt-f-01.sh:82-90`) *before* the observer's `FINAL` exists, so
  the pack had to be re-frozen after the observer's re-write (`ledger.jsonl`
  `observer_final_after_verdict`, `pack_refrozen`). Grading should not race the
  observer's final handoff.
- **Fix:** H3 ticket. Owner: `cbt-chaos-observer-worker` SKILL.md + the
  parameterized observer contract template `cbt-chaos/contracts/observer.md`
  (human gate); driver-ordering item owner Lead (scenario-owned driver).

### W6 — CBT-F-01 has no scenario-owned observer/trigger contract (the dropped mandate, H5)

- **Symptom (artifact + field).** Compare `chaos-trigger.sh`-adjacent
  `cbt-chaos/contracts/observer.md:72-75` (mandates the checkpoint-tree capture)
  against `runs/…r04/contracts/observer.md:46-58,65` (no capture; bans
  `oc exec`). The run's contract does not carry the template's mandate.
- **Root cause (hypothesis, labelled).** The scenario directory ships no
  `observer.md`/`trigger.md` template of its own; `contract-gen.sh:41-49`
  substitutes the CBT-F-04-worded `cbt-chaos/contracts/*.md`, which the audit
  already flags as not a cross-scenario contract (`docs/agent-workflow-audit.md`
  §5 G11: "`cbt-chaos/contracts/*` are CBT-F-04 worded; `contract-gen.sh`
  substitutes only `__RUN_ID__` tokens … Flagged (do not link them as a
  cross-scenario contract)"). So each CBT-F-01 run's contract is hand-written
  and can silently drop a template rule — which is what happened to W1.
- **Why it matters.** This is the mechanism that let a *template-mandated*
  evidence rule vanish. Fixing W1 in the trigger removes the dependence on the
  observer for this criterion, but the structural gap remains for every other
  criterion.
- **Fix:** H5 ticket. Owner: Lead/`cbt-chaos-team` (scenario contract issuance).

### Additional observations (recorded, no ticket required by this ticket)

- **Non-monotonic `deletionTimestamp` (unexplained).** Same pod uid
  `8fa3ecb1-…` carries `2026-10-16T01:13:26Z` in
  `observer/watches/pods-vm.jsonl` events rv 27101685/27101692/27101917 and
  `2026-10-16T01:12:38Z` in rv 27101925 + DELETED rv 27101926
  (`observer/finding.md` "Gap — unexplained pod field"; ledger
  `harness_finding`). The disappearance instant is independently corroborated,
  so no criterion was graded on it; flag as an API/recording anomaly for the
  KubeVirt side, not a scenario defect.
- **Bookkeeping defect in the recovery-restore checks.**
  `runs/…r04/report.json` `recovery.attempts[0].restore.checks[1]`
  `recovery_attempt_selected` records expected `r001` with actual `''` and
  passed (`checkers/evidence-sufficiency.json` `false_positives_checked`). The
  empty actual is a population defect in the report; the attempt identity is
  pinned by neighbouring checks. Worth a checkout-side ticket if it recurs.
- **Empty embedded raw-status fields.** `runs/…r04/fragments/full-backup.json`
  `evidence.vm_backup_status.full` is null and
  `runs/…r04-clean/report.json` `evidence.vm_backup_status` is
  `{full:null, incrementals:{pass_01:null}}` (same checker section). No
  criterion graded on them; the snapshots should be populated or removed.
- **Ledger overwrite on run-root pull.** `ledger.jsonl` `ledger_note` (line 3):
  "pulling the run root from the execution host overwrote the Lead-side
  `ledger.jsonl` and `state.json` with the stale copies pushed before the run,
  because they existed only on the workstation. Events after `contract_issued`
  are re-appended below from the Lead's own records". A Lead-owned append-only
  record was silently replaced by a stale push — promoted to ticket H4 because
  it corrupts the audit trail.

---

## 2. Proposed trigger diff — option (b), Lead-approvable

Against `cbt-chaos/scenarios_v2/CBT-F-01/chaos-trigger.sh` (sha256 `4e6e35f7…`).
Three hunks: a helper, the post-recovery call site, and routing the existing
pre-injection capture through the helper so both captures land as
machine-checkable JSON. No `krknctl` invocation is added or modified, so no
Krkn Command Preparer input is required. **`bash -n` acceptance is stated with
the item's acceptance check (§5).**

```diff
@@ -277,9 +277,32 @@
 # `oc delete --wait=false` only proves the delete request was accepted, not that
 # the launcher pod was actually removed or that KubeVirt replaced it; this check
 # independently confirms the effect and logs it as informational evidence only
 # (it never changes the trigger's exit status, which stays governed by the
 # existing backup-outcome logic below).
+
+# Read-only guest query required by spec §4 bullet 3: the launcher-side libvirt
+# checkpoint tree, captured before injection and again after VM recovery. The
+# tree may legitimately be empty on a fresh lifecycle, so the *exit status* --
+# not the line count -- is what proves the capture happened; the JSON sidecar
+# is the machine-checkable artifact (a failed capture is never silently an empty
+# tree). Prints the raw tree on stdout; returns the oc exec status.
+capture_checkpoint_tree() { # <phase: pre|post> <pod>
+  local phase="$1" pod="$2" uid tree status=0 lines utc
+  uid="$(oc get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
+  utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
+  tree="$(oc exec -n "$NAMESPACE" "$pod" -c compute -- \
+    virsh checkpoint-list "${NAMESPACE}_${VM_NAME}" --tree 2>/dev/null)" || status=$?
+  lines="$(printf '%s\n' "$tree" | awk 'NF { count++ } END { print count + 0 }')"
+  log "Checkpoint tree ($phase, launcher $pod, UTC $utc): exit=$status, lines=$lines."
+  write_json "$EVIDENCE_DIR/checkpoint-tree-${phase}.json" \
+    --arg phase "$phase" --arg pod "$pod" --arg pod_uid "$uid" --arg utc "$utc" \
+    --argjson exit "$status" --argjson lines "$lines" --arg tree "$tree" \
+    '{phase:$phase, pod:$pod, pod_uid:$pod_uid, utc:$utc, exit:$exit, lines:$lines, tree:$tree}'
+  printf '%s\n' "$tree"
+  return "$status"
+}
+
 verify_launcher_disruption_and_recovery() {
```

```diff
@@ -315,6 +338,11 @@
   if [[ "$old_pod_gone" == true && "$replacement_ready" == true ]]; then
     within_120s=true
     log "Independent effect check: launcher pod $old_pod (UID $old_uid) was replaced and the new launcher is Ready (${elapsed}s)."
+    # Spec §4 bullet 3: record the tree again on the recovered launcher, which
+    # is the write no writer owned (run 20261016-cbt-f-01-r04 closed BLOCKED for
+    # exactly this). A non-zero capture is preserved with its exit, never dropped.
+    capture_checkpoint_tree post "$replacement_name" >/dev/null \
+      || log "Post-recovery checkpoint-tree capture failed (launcher $replacement_name); recorded with its non-zero exit."
   else
     log "Independent effect check: could not confirm launcher-pod replacement/readiness within 120s (old_pod_gone=$old_pod_gone, replacement_ready=$replacement_ready); treat the injection effect as unverified beyond the delete request."
   fi
```

```diff
@@ -355,8 +383,7 @@
         baseline_status=0
-        baseline_tree="$(oc exec -n "$NAMESPACE" "$pod" -c compute -- \
-          virsh checkpoint-list "${NAMESPACE}_${VM_NAME}" --tree 2>/dev/null)" || baseline_status=$?
+        baseline_tree="$(capture_checkpoint_tree pre "$pod")" || baseline_status=$?
         baseline_lines="$(printf '%s\n' "$baseline_tree" | awk 'NF { count++ } END { print count + 0 }')"
```

Optional fourth hunk (keeps the `--plan` text truthful; changing it changes the
rehearsal-stdout hash recorded by `preflight.json` check 6, which is expected
and fine):

```diff
@@ -151,6 +151,9 @@
   printf '     launcher and require vm-tracker-%s to be absent; refuse to inject otherwise.\n' "$RUN_ID"
+  printf '     The same read-only query is repeated on the recovered launcher after the\n'
+  printf '     replacement is Ready (spec §4 bullet 3), into trigger/checkpoint-tree-pre.json\n'
+  printf '     and trigger/checkpoint-tree-post.json.\n'
```

Design notes for the Lead's review:

- **Why route the pre capture through the helper too.** The pre capture today is
  logged only into `trigger.log` (`chaos-trigger.sh:372`). Routing it through the
  helper adds the machine-checkable `checkpoint-tree-pre.json` without changing
  the retry/gate semantics: the helper's return status is still the `oc exec`
  status, so a failed capture still retries and still refuses to look like a
  fresh VM's empty tree (`chaos-trigger.sh:361-364`). The caller's
  `baseline_lines`/`baseline_tree` are derived exactly as before.
- **Post capture runs once, inside the existing recovery wait.** It fires on the
  `old_pod_gone && replacement_ready` branch (`chaos-trigger.sh:315-318`), i.e.
  at the same instant the effect check already declares recovery — no new wait,
  no new deadline. `replacement_name`/`replacement_uid` are in scope
  (`chaos-trigger.sh:298-309`).
- **Interactions to watch.** If a future run makes the post capture mandatory for
  exit status, keep it informational first (as written: a failure is logged, not
  fatal), because the trigger's exit arbitration must stay governed by the
  backup outcome (`chaos-trigger.sh` arbitration block). The *evaluator* (W2) is
  where a missing capture should become a non-PASS.
- **Spec alignment.** The pre capture is on the *pre-injection* launcher (`$pod`
  before the signal, `chaos-trigger.sh:357`), the post capture on the
  *replacement* — matching `scenario-spec.md:47` ("before and after VM
  recovery") and the spec's own evidence command naming
  `<replacement-launcher-pod>` (`scenario-spec.md:63`).

---

## 3. Proposed evaluator diff — ticket (d)

### 3a. Guaranteed-minimal: state the non-coverage so a PASS cannot be read as a spec PASS

Against `cbt-chaos/scenario-verdict.sh`. This alone satisfies the "contract
should state explicitly that it does not model the libvirt tree" half of (d) and
is safe with or without the trigger diff.

```diff
@@ -56,6 +56,14 @@
 #   clean-lifecycle      the clean lifecycle summary is PASS with verified restore
 #                        hashes (NOT_APPLICABLE without --clean-lifecycle-run)
+#
+# NOT modelled (deliberate): the libvirt checkpoint-tree half of spec §4
+# bullet 3. This script can only see the *tracker* half (check
+# tracker-not-advanced). Without trigger/checkpoint-tree-{pre,post}.json it
+# cannot establish whether the guest-side tree was captured before injection or
+# on the recovered launcher, so a PASS here is a PASS over the checks above and
+# is NOT a spec PASS. Criterion-level sufficiency is the evidence checker's
+# call; this script never claims it.
 #
 # Verdict rules (deterministic):
```

Optional companion (removes the invitation to over-read the reason string),
same file, the PASS branch at `:1000-1001`:

```diff
   else
     verdict='PASS'
-    verdict_reason='injection independently evidenced, the interrupted full backup failed cleanly, CBT recovered, and restore/clean-lifecycle checks passed'
+    verdict_reason='script checks passed (injection independently evidenced, the interrupted full backup failed cleanly, CBT recovered, and restore/clean-lifecycle checks passed); this is not a spec PASS - see the NOT-modelled note'
   fi
```

### 3b. Stronger: model the criterion (requires the §2 trigger diff to land first)

Add a check `checkpoint-tree-captured` that reads the two new artifacts. Missing
⇒ `UNKNOWN` ⇒ the verdict is capped at `INCONCLUSIVE` by the existing rule
(`scenario-verdict.sh:993-995`), which is exactly the "missing mandatory
evidence never yields PASS" invariant the header promises.

```diff
@@ -172,6 +172,8 @@
     'backup-interrupted' 'the interrupted full backup is terminal and failed (type=Full, Done=True, failure reason, PVC retained)' \
     'tracker-not-advanced' 'the tracker held no checkpoint at failure and none is attributed to the interrupted copy' \
+    'checkpoint-tree-captured' 'trigger/checkpoint-tree-{pre,post}.json each record a launcher-side virsh checkpoint-list capture with exit=0 (the tree may be empty; the exit status proves the capture ran)' \
     'cbt-recovered' 'VM CBT state is Enabled and the VM/VMI is Running after recovery' \
```

```diff
@@ -713,6 +715,36 @@
   fi
 }

+# 5b. checkpoint-tree-captured (spec §4 bullet 3, libvirt half). See the
+# NOT-modelled note in the header: this check is what turns that note into
+# coverage once the trigger writes the two artifacts.
+check_checkpoint_tree() {
+  local expected='trigger/checkpoint-tree-{pre,post}.json each record a launcher-side virsh checkpoint-list capture with exit=0'
+  local missing=() bad=() ok=() phase f exitc
+  for phase in pre post; do
+    f="$TRIGGER_DIR/checkpoint-tree-${phase}.json"
+    if [[ ! -f "$f" ]]; then missing+=("checkpoint-tree-${phase}.json"); continue; fi
+    exitc="$(jq -r '.exit // empty' "$f" 2>/dev/null || true)"
+    if [[ "$exitc" == "0" ]]; then ok+=("checkpoint-tree-${phase}.json"); else bad+=("$phase(exit=${exitc:-<absent>})"); fi
+  done
+  if ((${#missing[@]} > 0)); then
+    add_check checkpoint-tree-captured UNKNOWN "$expected" \
+      "no checkpoint-tree capture(s): ${missing[*]}" "${ok[@]}"
+  elif ((${#bad[@]} > 0)); then
+    add_check checkpoint-tree-captured FAIL "$expected" \
+      "capture present but not a successful read: ${bad[*]}" "${ok[@]}"
+  else
+    add_check checkpoint-tree-captured PASS "$expected" \
+      "pre and post captures both exit=0; post captured on the recovered launcher" "${ok[@]}"
+  fi
+}
+
 # 6. cbt-recovered
```

```diff
@@ -960,6 +992,7 @@
 check_backup_interrupted
 check_tracker_not_advanced
+check_checkpoint_tree
 check_cbt_recovered
```

Acceptance for (d): with the §2 trigger diff unapplied, the evaluator emits
`checkpoint-tree-captured UNKNOWN` and a verdict of at most `INCONCLUSIVE` on a
run shaped like r04 (never PASS); with it applied and both artifacts present,
`PASS`. Owner: harness maintainer, with a fixture case in
`tests/test-scenario-verdict.sh` (an r04-shaped fixture with the two trigger
tree files absent must assert non-PASS).

---

## 4. Harness-ticket drafts

**H1 — worker launch/liveness probes must not self-match; the guard's failure branch may only report**
- **Component:** `cbt-chaos-trigger-worker` SKILL.md (human gate).
- **Problem:** this run's trigger worker "self-refused on a self-matching
  `pgrep`" (given) — the same defect class as CBT-F-04 r03, where
  `bash -c pgrep -f "make e2e"` matched its own command line and fell through to
  launching a rogue unapproved lifecycle
  (`scenarios_v2/CBT-F-04/analysis/20261015-cbtf04-r03-improvements.md` W2/H1).
  That ticket is still open, and this makes the class a **third** occurrence.
- **Proposed change:** (a) process-match probes must exclude the probing shell
  (match a recorded PID via `kill -0`, or filter `pgrep -f` output by `$$`/`$PPID`
  and the worker's own argv, or use an anchored pattern that cannot match the
  probe command line); (b) a guard's failure branch may only *report* — never
  source env files or start any command outside the contract; (c) workers never
  source checkout `.env`.
- **Acceptance:** a worker following the skill cannot reproduce a self-match in
  either direction (neither a false refusal nor a false liveness success), and
  the recorded `pgrep` invocation, when run, does not list its own process.
- **Evidence:** given deviation for run `20261016-cbt-f-01-r04`; class precedent
  `docs/agent-workflow-audit.md` §4 and the F-04 r03 `harness_incident` ledger
  line cited in that analysis. (No first-party artifact of the self-refusal is
  in this run's pack — the refusal was stderr-only, which is part of why it
  should be made recorder-visible.)

**H2 — one collision guard for the run identity; refusals must be recorded evidence**
- **Component:** scenario-owned `chaos-trigger.sh` + driver `run-cbt-f-01.sh`,
  and the shared guard helper behind them (Lead tier).
- **Problem:** the same "is this RUN_ID already in flight?" policy exists in
  three places with three different rules — `chaos-trigger.sh:91-138`
  (`--plan`, entry-classified), `chaos-trigger.sh:175-188` (live: only
  lifecycle-dir + non-empty `trigger/`), `run-cbt-f-01.sh:60-75` (driver:
  lifecycle dirs + non-empty `trigger/` + three named prior outputs) — and the
  refusal is stderr-only (`chaos-trigger.sh:177-179`, `:94-95`). A duplicate
  launch this run was refused, but the pack holds no trace of it (`grep` of the
  pack for `refus|already exists|collision` returns nothing), and a stray file
  in the scenario run dir passes the live guard while failing `--plan`. The
  guards are documented as the preflight's collision evidence
  (`preflight.json` check 5 `evidence[]` cites `chaos-trigger.sh:92-135` +
  `run-cbt-f-01.sh:52-71`; check 6 cites `chaos-trigger.sh:80-163`).
- **Proposed change:** extract a single `assert_run_id_clear <run-id>` helper
  used by `--plan`, the live trigger and the driver (one rule set); on refusal,
  write `trigger/refusal.json` `{run_id, utc, rule, offending_entries[], mode}`
  before exiting, so the refusal is auditable from the closed pack.
- **Acceptance:** a second launch against a live run writes `refusal.json` and
  exits non-zero without contacting the cluster; the `--plan` and live paths
  make the same allow/refuse decision on the same directory state (a fixture
  matrix of pre-armed / partial-output / complete-run directories yields
  identical verdicts).
- **Evidence:** given deviation (duplicate launch refused harmlessly);
  `chaos-trigger.sh:91-138`, `:175-188`; `run-cbt-f-01.sh:60-75`;
  `preflight.json` checks 5-6.

**H3 — observer waits must fail loudly, and grading must not race the observer's final handoff**
- **Component:** `cbt-chaos-observer-worker` SKILL.md + parameterized template
  `cbt-chaos/contracts/observer.md` (human gate); driver leg order (Lead tier).
- **Problem:** `observer/PRESERVED` `.utc=2026-10-16T01:19:00Z` was 6 m 22 s
  after leg-1 terminal (`observer/finding.md`, interrupted backup
  `lastTransitionTime=01:12:38Z`) and after the retry began
  (`runs/…r04/run.json` `recovery.attempts[0].started_at=01:12:53Z`), because a
  3 s poll loop's bash arithmetic test was "fed by a multi-line `jq` result,
  which errored every iteration and defeated its early exit"
  (`observer/finding.md` "Cadence effect on the handoffs"). Separately, the
  driver runs the evaluator as leg 4/4 (`run-cbt-f-01.sh:82-90`) before the
  observer's `FINAL` exists, forcing a post-verdict pack re-freeze
  (`ledger.jsonl` `observer_final_after_verdict`, `pack_refrozen`).
- **Proposed change:** (a) template rule: every wait loop must assert the exit
  status of its own test/command and fail (or re-arm explicitly) rather than
  silently iterate to its cap; a "no change" result must be distinguishable from
  an error result; (b) driver: gate the evaluator leg on the observer's
  `PRESERVED` marker (or document that `PRESERVED` is a pre-grade requirement)
  so the deterministic verdict never grades a pack the observer has not finished
  handing off.
- **Acceptance:** a deliberately broken test value inside a wait loop causes the
  loop to exit early with a non-zero status (not loop to its cap); a run whose
  observer is slow still reaches `PRESERVED` before the verdict leg starts.
- **Evidence:** `observer/finding.md` "Cadence effect on the handoffs";
  `observer/PRESERVED` `.utc`; `runs/…r04/run.json`
  `recovery.attempts[0].started_at`; `ledger.jsonl`
  `observer_final_after_verdict`, `pack_refrozen`; `run-cbt-f-01.sh:82-90`.

**H4 — the Lead-owned ledger/state must never be overwritten by a run-root pull**
- **Component:** `cbt-chaos-team` close procedure / the run-root pull step
  (human gate).
- **Problem:** `ledger.jsonl` `ledger_note` (line 3): pulling the run root from
  the execution host "overwrote the Lead-side `ledger.jsonl` and `state.json`
  with the stale copies pushed before the run, because they existed only on the
  workstation. Events after `contract_issued` are re-appended below from the
  Lead's own records." An append-only audit trail was silently replaced and had
  to be reconstructed from memory.
- **Proposed change:** the pull must exclude Lead-owned state
  (`ledger.jsonl`, `state.json`, `evidence-index.json`), or the Lead must append
  on the authoritative side; reconstructing a ledger from memory is not an
  acceptable recovery. Add a `pack-validate`-style check that the ledger's
  event count is monotonic across a pull.
- **Acceptance:** a pull against a run with Lead-side events after the last push
  leaves the local `ledger.jsonl` byte-identical to the Lead's version.
- **Evidence:** `ledger.jsonl` `ledger_note`.

**H5 — CBT-F-01 needs a scenario-owned observer/trigger contract; a template mandate must not be droppable**
- **Component:** scenario contract issuance (`contract-gen.sh` /
  `cbt-chaos/contracts/*`) and the Lead's contract-issuance procedure (human
  gate).
- **Problem:** the parameterized template already required the checkpoint-tree
  capture (`cbt-chaos/contracts/observer.md:72-75`) but the run's contract
  (`runs/…r04/contracts/observer.md:46-58,65`) dropped it and banned `oc exec` —
  the direct cause of W1. `contract-gen.sh:41-49` emits `CBT-F-04`-worded
  contracts (template header `contracts/observer.md:1`), and the audit already
  flags the template set as not a cross-scenario contract
  (`docs/agent-workflow-audit.md` §5 G11).
- **Proposed change:** give CBT-F-01 a scenario-owned `observer.md`/`trigger.md`
  contract (or make `contract-gen.sh` scenario-aware) whose rules are derived
  from `scenario-spec.md §4`, and add a contract-generation check that every
  spec §4 criterion has a corresponding mandate name in the generated
  contract.
- **Acceptance:** generating CBT-F-01's contracts yields an observer contract
  that names all six §4 criteria, including the libvirt checkpoint tree; a
  criterion present in the spec but absent from the contract fails the check.
- **Evidence:** `cbt-chaos/contracts/observer.md:72-75` vs
  `runs/…r04/contracts/observer.md:46-58,65`; `contract-gen.sh:41-49`;
  `docs/agent-workflow-audit.md` §5 G11.

---

## 5. Acceptance summary (what proves each fix)

| Item | Owner | Acceptance check |
|---|---|---|
| W1 trigger post-recovery capture (§2 diff) | Lead (between runs) | `bash -n chaos-trigger.sh` exit 0; on the next live run `trigger/checkpoint-tree-post.json` exists with `.exit=0` and `.pod_uid` equal to `effect-check.json` `.replacement_pod.uid`, and `trigger/checkpoint-tree-pre.json` exists with `.exit=0` |
| W1 spec §2 evidence-list edit (§5 S1) | human (gated) | spec line 23 enumerates both tree artifacts; a reader can map §4.3 to a named machine-checkable file |
| W2 evaluator non-coverage note (§3a) | harness | `scenario-verdict.sh --help`/header states the omission; a fixture with no tree artifacts still yields at most `INCONCLUSIVE` under §3b, and a PASS is never captioned as a spec PASS |
| W2 evaluator check (§3b) | harness + `tests/test-scenario-verdict.sh` | fixture without the two artifacts ⇒ `checkpoint-tree-captured UNKNOWN` and non-PASS; fixture with both ⇒ `PASS` |
| W3 collision guard (H2) | Lead | same directory state ⇒ identical `--plan` and live decisions; a duplicate launch writes `trigger/refusal.json` and exits non-zero |
| W4 pgrep self-match (H1) | trigger-worker skill owner (gated) | the recorded probe invocation does not match its own process; neither false refusal nor false liveness success |
| W5 late PRESERVED (H3) | observer-worker skill + template (gated); driver order (Lead) | a broken wait-loop test exits early non-zero; a slow observer still reaches `PRESERVED` before the verdict leg |
| W6 / H5 contract issuance | Lead / `cbt-chaos-team` | generated CBT-F-01 observer contract names all six §4 criteria |
| H4 ledger overwrite | `cbt-chaos-team` | a pull leaves the Lead's `ledger.jsonl` intact |

---

## 6. Proposed spec edits (human gate)

**Edit S1 — `scenario-spec.md` line 23 (the §2 machine-checkable trigger-evidence
enumeration).** Add the two tree artifacts to the list so the criterion maps to
an indexed file.

Before (fragment, end of line 23):

> … `exit-statuses.json` (`e2e_status`, `observer_status`,
> `expectation: "e2e_nonzero_expected"`, UTC) and `trigger.log` (the trigger's
> stderr lines, mirrored).

After:

> … `exit-statuses.json` (`e2e_status`, `observer_status`,
> `expectation: "e2e_nonzero_expected"`, UTC), `checkpoint-tree-pre.json` and
> `checkpoint-tree-post.json` (`phase`, `pod`, `pod_uid`, `utc`, `exit`, `lines`,
> `tree` — the launcher-side libvirt checkpoint tree read with
> `virsh checkpoint-list --tree`, captured on the pre-injection launcher and
> again on the recovered launcher) and `trigger.log` (the trigger's stderr
> lines, mirrored).

**Edit S1a — note on the unchanged criterion line.** §4 bullet 3
(`scenario-spec.md:47`) is **not** changed by option (b); the requirement already
reads "Record the libvirt tree before and after VM recovery", and the §4
evidence command (`scenario-spec.md:63`) already targets
`<replacement-launcher-pod>`. This edit only names the artifacts that satisfy it.
*(Had option (c) been chosen, the change would be to line 47 — strike the
checkpoint-tree sentence — and to line 63 — delete the `oc exec … virsh
checkpoint-list` command. That is the human-gated path we recommend against.)*

> **HUMAN GATE:** spec edits are human-gated and require explicit sign-off; S1
> must not be applied by an agent. Under the twice-rule (W1 recurred from r03,
> W4 is the class's third occurrence) the human must either approve S1 + the §2
> trigger diff + H1 or record a declined reason in `ledger.jsonl`.

---

## 7. Twice-rule escalation

- **W1 (spec-4.3 libvirt tree)** — this is the **second** consecutive run closed
  on the same criterion (r03: `ledger.jsonl` "r03 passed on the same gap because
  it ran without an evidence checker"; r04: REJECT). ≥2 ⇒ the closing edit is
  **mandatory**: the §2 trigger diff (Lead tier) + S1 (human) + the §3b
  evaluator check (harness).
- **W4 (probe self-match)** — F-04 r03 incident + its still-open H1 ticket + this
  run = **three** occurrences ⇒ mandatory close (H1, human gate).
- **W2 (evaluator under-coverage)** — manifest in every run that lacks an
  evidence checker (r03 and r04 both) and now the direct cause of a
  BLOCKED-vs-PASS disagreement ⇒ mandatory close (the §3a note is the floor;
  §3b is the target).

---

## 8. Candidate lessons for closeout

1. A criterion that no writer owns is a criterion the run cannot pass: the spec
   required the libvirt tree before injection *and after recovery*, the trigger
   owned only "before", the observer contract banned `oc exec`, and no third
   writer existed — so a complete, well-evidenced injection closed BLOCKED
   (§2; `checkers/evidence-sufficiency.json` `.reject_reasons[0]`).
2. An evaluator that does not model a criterion converts its own PASS into a
   claim stronger than its evidence: the fix is not more prose but either a check
   or an explicit non-coverage statement, so script PASS ≠ spec PASS (§3;
   `verdict.json` `.verdict_reason`).
3. A template mandate is not a contract: a rule present in
   `cbt-chaos/contracts/observer.md:72-75` vanished from the run's hand-authored
   contract, because CBT-F-01 has no scenario-owned contract template (W6/H5).
4. The same guard written three times will eventually disagree: `--plan`, live,
   and driver collision checks encode one policy in three rules, and a refusal
   that only reaches stderr is not evidence (W3/H2).
5. A `pgrep -f` probe matches its own command line; the class has now failed
   *open* (F-04 rogue lifecycle) and *closed* (this run's self-refusal) — it is
   unusable as a liveness primitive until it excludes self (W4/H1).
6. A wait loop that swallows a test error is a wait loop that will run to its cap
   on the one iteration that matters (W5/H3: the 6 m 22 s late `PRESERVED`).
7. Lead-owned append-only state must not live somewhere a run-root pull can
   overwrite it; reconstructing a ledger from memory is not audit (H4).

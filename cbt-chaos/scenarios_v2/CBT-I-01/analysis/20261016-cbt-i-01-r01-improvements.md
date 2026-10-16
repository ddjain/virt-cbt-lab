# Scenario Improvements — CBT-I-01 run `20261016-cbt-i-01-r01`

Scope: weaknesses in the **test** and the **harness** that this run exposed — spec, trigger,
evaluator, observer coverage, evidence pinning. Product findings and next-run parameter choices are
out of scope (product-flow / variation-decider own those).

**Proposals only — nothing in this document is applied.** Gates used below:

| Gate | Meaning |
|---|---|
| **Lead** | trigger-script and run-contract diffs; the Lead approves and applies them between runs |
| **human** | `scenario-spec.md`, `.agents/skills/**`, `docs/**`, `tests/**` — always require the human (the run's own team skill: spec and SKILL.md diffs are human-gated) |

Run under analysis is **closed** and read-only: `verdict.json` `.verdict="PASS"`, both blind checkers
PASS, `verdict.json` `.verdict` of the *evaluator* `INVALID` already recorded as **HV1**
(`docs/agent-plan-incorrect-points.md:186-199`) and **not re-litigated** here — item (a) only turns HV1
into a concrete diff.

## 0. The four items in one line each

| # | Symptom (artifact + field) | Root cause | Owner / gate | Acceptance |
|---|---|---|---|---|
| **I-1** (a) | `verdict.json` `.verdict="INVALID"`, `.verdict_reason="the injected condition was never exercised: injection-signal=UNKNOWN launcher-replacement=UNKNOWN while the full backup succeeded"` — every §5 criterion is modelled by **zero** of the script's 8 checks | The evaluator implements the interrupted-full shape (CBT-F-01) as if generic (HV1); nothing declares the scenario's shape, so a caller cannot select the applicable check set, and the `clean-lifecycle` cap is shape-blind too | harness (`cbt-chaos/scenario-verdict.sh`) + `cbt-chaos-run` SKILL.md + audit row; **human** for skill/audit, harness for the script | `tests/test-scenario-verdict.sh` grades an I-01-shaped fixture `PASS` with no extra flag; a shape-misdeclared fixture yields `INCONCLUSIVE` with the out-of-shape checks `NOT_APPLICABLE` and **no** check ever carrying `INVALID`; `make test` green |
| **I-2** (b) | `trigger/` is **empty** (`ls` shows no entries); the window proof exists only as prose in `trigger.log:78-81` | The per-run trigger contract assigned the artifacts to the **trigger worker**, but the per-stage data (full-stage exit code, delete request instant, uid before/after) lives only inside `chaos-trigger.sh`; the Lead ran the script directly, so nothing translated it to JSON. §5 criterion 1 is therefore carried by the observer alone | `chaos-trigger.sh` (Lead), run trigger contract (Lead), spec §5.1 (human) | a real run writes `trigger/{action-request.json,effect-check.json,stage-outcomes.jsonl,exit-statuses.json,command.txt}`; the new evaluator check `injection-window` reads `trigger/action-request.json` and returns `UNKNOWN` ⇒ verdict ≤ `INCONCLUSIVE` when it is missing |
| **I-3** (c) | `observer/watches/pods-vm.jsonl`: `deletionTimestamp` **regresses** as rv rises — `01:40:06Z` at rv 27132652/27132660/27132852, then `01:39:16Z` at rv 27132861/27132862 (tombstone) | **Establishment, not hypothesis:** `deletionTimestamp` is a deletion **deadline** (`now + gracePeriodSeconds`) and `deletionGracePeriodSeconds` moves 60 → 0 across the same series, i.e. a second DELETE with a shorter grace period legitimately rewrote it backwards. Identical in CBT-F-01 r04 (`01:13:26Z`/grace 60 → `01:12:38Z`/grace 0). Second occurrence ⇒ twice-rule | `.agents/skills/cbt-chaos-observer-worker/SKILL.md` (**human**, mandatory) + run observer contract (Lead) + ticket **HT-1** | the rule is in the skill; the observer's next pack states the termination instant from `containerStatuses[compute].state.terminated.finishedAt` and records the rv-ordered `deletionTimestamp`/`deletionGracePeriodSeconds` series as the explanation |
| **I-4** (d) | Observer `finding.md` bounds section: "No `oc exec` / libvirt access (read-only role)"; run observer contract carries no checkpoint-tree capture | **No `oc exec` is needed for §5 criterion 2** — the redefinition evidence already exists without it (`runs/20261016-cbt-i-01-r01/logs/virt-launcher.log:1304,1308,1309`, `uid`= the post-restart VMI uid). The real defect is that the *template* mandate (`cbt-chaos/contracts/observer.md:72-75`, `virsh checkpoint-list --tree`) was dropped by the per-run contract (**HV3** recurrence) and that the log line is not hash-pinned by any index | spec §7 + §5.2 evidence-of-record (human), observer contract clause (Lead), evidence pinning (Lead/harness) | `scenario-spec.md` names the launcher-log line as redefinition evidence of record; that artifact (or a hash-pinned projection of it) is inside an index the checkers verify; the exec question is answered in writing with the residual still bounded |

---

## 1. (a) HV1 — the evaluator cannot grade CBT-I-01 and returns a confidently wrong `INVALID`

### 1.1 Symptom

`runs/20261016-cbt-i-01-r01/verdict.json`:

- `.verdict="INVALID"`, `.verdict_reason="the injected condition was never exercised: injection-signal=UNKNOWN launcher-replacement=UNKNOWN while the full backup succeeded (Successfully completed VirtualMachineBackup)"`.
- `.checks[]` = the 8 ids printed by `cbt-chaos/scenario-verdict.sh:167-177`. Five are meaningless for this
  scenario by construction: `injection-signal` and `launcher-replacement` expect an active-copy pod-delete
  signal this trigger never emits; `backup-interrupted` expects a **failed** full backup while I-01
  *requires* the full backup to succeed; `same-vm-recovery` expects a recovery attempt this shape does
  not have; `clean-lifecycle` expects a second lifecycle this shape does not have.
- The stated reason is factually contradicted by the run's own evidence: the observer's name-scoped VMI
  stream shows the UID change `b203235a…` → `29dfe33c…` (`observer/watches/vmi.jsonl:34-35`), and
  `state.json` records `"evaluator":"INVALID (inapplicable, HV1)"`.

### 1.2 Root cause (established)

1. The check set is a fixed list of CBT-F-01-shaped checks (`scenario-verdict.sh:956-963`) with no notion
   of a scenario shape, and nothing in the repo declares one — not the scenario directory, not the
   invocation (`cbt-chaos-run` SKILL.md:229-232 passes only `--scenario-dir/--run-id/--lifecycle-run/
   --clean-lifecycle-run/--json`).
2. The verdict rule that produced `INVALID` (`:985-989`) is correct **inside** the interrupted-full
   shape (a successful full + no injection evidence = the injection never happened) and is the very
   behaviour pinned by `tests/test-scenario-verdict.sh:238-239`. Out of shape it is an unfounded claim.
3. A **second, independent** defect in the same block: `clean-lifecycle` `NOT_APPLICABLE` caps the verdict
   at `INCONCLUSIVE` (`:996-998`) with no shape condition, so even after the check set is fixed an I-01
   run could never reach `PASS`.

### 1.3 Diff A1 — declared scenario shape in `cbt-chaos/scenario-verdict.sh`

Shape resolution order: `--scenario-shape` value → first non-empty line of
`<scenario-dir>/harness-shape` → `interrupted-full` (today's behaviour, so every existing caller and
test is unchanged). An unrecognised shape token is a usage error (exit 2) — never a silent fallback.

**A1.1 — header usage block** (file `cbt-chaos/scenario-verdict.sh`, lines 9-12 and 22-24):

```diff
 # Usage:
 #   cbt-chaos/scenario-verdict.sh --scenario-dir DIR --run-id ID \
 #       [--lifecycle-run NAME] [--clean-lifecycle-run NAME] [--json PATH] \
-#       [--list-checks] [--help]
+#       [--scenario-shape SHAPE] [--list-checks] [--help]
@@
 #   --list-checks             print check ids + descriptions as TSV, read
 #                             nothing, exit 0
+#   --scenario-shape SHAPE    which scenario shape the check set is selected
+#                             from (default: the first line of
+#                             <scenario-dir>/harness-shape, else
+#                             interrupted-full). Modelled shapes:
+#                               interrupted-full         CBT-F-01 (and today's
+#                                                        default)
+#                               vmi-restart-between-stages CBT-I-01
+#                             An unmodelled shape is a usage error (exit 2).
+#                             Checks outside the shape are reported
+#                             NOT_APPLICABLE, never FAIL/UNKNOWN, and never
+#                             INVALID.
 #   --help                    print usage, exit 0
```

**A1.2 — `usage()` text** (lines 119-127):

```diff
     '  --json PATH                  also write the JSON verdict to PATH' \
+    '  --scenario-shape SHAPE       scenario shape selecting the check set' \
+    '                               (default: <scenario-dir>/harness-shape, else' \
+    '                               interrupted-full; see --help)' \
     '  --list-checks                print check ids + descriptions as TSV' \
```

**A1.3 — argument parsing** (lines 146-165):

```diff
 json_path=''
+scenario_shape=''
 list_checks=false
 
 while (($# > 0)); do
   case "$1" in
-    --scenario-dir|--run-id|--lifecycle-run|--clean-lifecycle-run|--json)
+    --scenario-dir|--run-id|--lifecycle-run|--clean-lifecycle-run|--json|--scenario-shape)
@@
         --json) json_path="$2" ;;
+        --scenario-shape) scenario_shape="$2" ;;
       esac
```

**A1.4 — shape registry, before the `--list-checks` early exit** (insert after line 165):

```diff
 done
 
+# A scenario declares its shape in <scenario-dir>/harness-shape (one token); the
+# flag overrides it and exists for tests. The default keeps the historical
+# behaviour: the check set below is the interrupted-full shape.
+resolve_scenario_shape() {
+  local declared='' canonical=''
+  if [[ -n "$scenario_shape" ]]; then
+    declared="$scenario_shape"
+  elif [[ -n "$scenario_dir" && -f "$scenario_dir/harness-shape" ]]; then
+    declared="$(head -n1 "$scenario_dir/harness-shape" 2>/dev/null | tr -d '[:space:]' || true)"
+  fi
+  [[ -n "$declared" ]] || declared='interrupted-full'
+  case "$declared" in
+    interrupted-full|CBT-F-01) canonical='interrupted-full' ;;
+    vmi-restart-between-stages|CBT-I-01) canonical='vmi-restart-between-stages' ;;
+    *) canonical='' ;;
+  esac
+  if [[ -z "$canonical" ]]; then
+    usage_err "unmodelled --scenario-shape: $declared (modelled: interrupted-full, vmi-restart-between-stages)"
+  fi
+  printf '%s' "$canonical"
+}
+
+# check-id → the shapes that model it. A check absent from the current shape is
+# reported NOT_APPLICABLE and is never counted as FAIL/UNKNOWN, so an out-of-model
+# check can never fabricate an INVALID/INCONCLUSIVE verdict.
+declare -A CHECK_SHAPES=(
+  [run-id-consistency]='interrupted-full vmi-restart-between-stages'
+  [injection-signal]='interrupted-full'
+  [launcher-replacement]='interrupted-full'
+  [backup-interrupted]='interrupted-full'
+  [tracker-not-advanced]='interrupted-full'
+  [cbt-recovered]='interrupted-full'
+  [same-vm-recovery]='interrupted-full'
+  [clean-lifecycle]='interrupted-full'
+  [injection-window]='vmi-restart-between-stages'
+  [vmi-restart]='vmi-restart-between-stages'
+  [incremental-type-recorded]='vmi-restart-between-stages'
+  [incremental-chain-correct]='vmi-restart-between-stages'
+  [restore-verified]='vmi-restart-between-stages'
+)
+
+SCENARIO_SHAPE="$(resolve_scenario_shape)"
+shape_models() { [[ " ${CHECK_SHAPES[$1]:-} " == *" $SCENARIO_SHAPE "* ]]; }
+
 list_check_table() {
   printf '%s\t%s\n' \
```

**A1.5 — `list_check_table()` becomes shape-scoped** (replaces lines 167-182). `--list-checks` with no
shape must print exactly today's list and order (pinned by `tests/test-scenario-verdict.sh` "(e)"); the
descriptions move into an associative map plus a fixed emission order, because a one-shot `printf` list
cannot be filtered:

```diff
-list_check_table() {
-  printf '%s\t%s\n' \
-    'run-id-consistency' 'lifecycle run.json run_id/vm_name match --run-id and no artifact path references another run' \
-    'injection-signal' 'trigger evidence records an active-copy signal naming the exact launcher pod and its UID' \
-    'launcher-replacement' 'trigger effect-check.json proves the old pod UID disappeared and a replacement launcher became Ready' \
-    'backup-interrupted' 'the interrupted full backup is terminal and failed (type=Full, Done=True, failure reason, PVC retained)' \
-    'tracker-not-advanced' 'the tracker held no checkpoint at failure and none is attributed to the interrupted copy' \
-    'cbt-recovered' 'VM CBT state is Enabled and the VM/VMI is Running after recovery' \
-    'same-vm-recovery' 'the same-VM recovery attempt succeeded and its restore comparison matched the baseline' \
-    'clean-lifecycle' 'the separate clean lifecycle summary is PASS with verified restore hashes'
-}
-
-if [[ "$list_checks" == true ]]; then
-  list_check_table
-  exit 0
-fi
+declare -A CHECK_DESCRIPTIONS=(
+  [run-id-consistency]='lifecycle run.json run_id/vm_name match --run-id and no artifact path references another run'
+  [injection-signal]='trigger evidence records an active-copy signal naming the exact launcher pod and its UID'
+  [launcher-replacement]='trigger effect-check.json proves the old pod UID disappeared and a replacement launcher became Ready'
+  [backup-interrupted]='the interrupted full backup is terminal and failed (type=Full, Done=True, failure reason, PVC retained)'
+  [tracker-not-advanced]='the tracker held no checkpoint at failure and none is attributed to the interrupted copy'
+  [cbt-recovered]='VM CBT state is Enabled and the VM/VMI is Running after recovery'
+  [same-vm-recovery]='the same-VM recovery attempt succeeded and its restore comparison matched the baseline'
+  [clean-lifecycle]='the separate clean lifecycle summary is PASS with verified restore hashes'
+  [injection-window]='trigger/action-request.json proves the VMI deletion was requested after the full backup was Done with a recorded checkpoint and before the incremental object existed'
+  [vmi-restart]='trigger/effect-check.json proves the VMI was recreated with a different UID, became Ready, and its launcher pod was replaced'
+  [incremental-type-recorded]='trigger/stage-outcomes.jsonl records the pass-1 backup Done=True with an explicit type (Incremental or Full) whose duration is consistent with that type'
+  [incremental-chain-correct]='the pass-1 checkpoint is distinct from the full checkpoint, the tracker holds it, and the lifecycle chain checks passed'
+  [restore-verified]='lifecycle report.json/summary.json show the full-only and cumulative restore hashes PASS with zero failed checks'
+)
+
+# Fixed emission order, filtered to the modelled shape.
+CHECK_ORDER=(
+  run-id-consistency injection-signal launcher-replacement backup-interrupted
+  tracker-not-advanced cbt-recovered same-vm-recovery clean-lifecycle
+  injection-window vmi-restart incremental-type-recorded incremental-chain-correct
+  restore-verified
+)
+
+list_check_table() {
+  local id
+  for id in "${CHECK_ORDER[@]}"; do
+    shape_models "$id" || continue
+    printf '%s\t%s\n' "$id" "${CHECK_DESCRIPTIONS[$id]}"
+  done
+}
+
+if [[ "$list_checks" == true ]]; then
+  list_check_table
+  exit 0
+fi
```

**A1.6 — evaluation dispatch and verdict gating** (lines 956-1002):

```diff
 printf '%-22s %-14s %s\n' 'check' 'status' 'detail' >&2
-check_run_id_consistency
-check_injection_signal
-check_launcher_replacement
-check_backup_interrupted
-check_tracker_not_advanced
-check_cbt_recovered
-check_same_vm_recovery
-check_clean_lifecycle
+# Runs <fn> only when the current shape models <id>; otherwise records
+# NOT_APPLICABLE with the reason, so an out-of-model check can never be read as
+# a FAIL/UNKNOWN and can never produce INVALID.
+run_check() { # <check-id> <function>
+  if shape_models "$1"; then
+    "$2"
+  else
+    add_check "$1" NOT_APPLICABLE \
+      "check is not modelled for scenario shape $SCENARIO_SHAPE" \
+      "not evaluated: ${CHECK_DESCRIPTIONS[$1]}" "$SCENARIO_SHAPE"
+  fi
+}
+
+run_check run-id-consistency      check_run_id_consistency
+run_check injection-signal        check_injection_signal
+run_check launcher-replacement    check_launcher_replacement
+run_check backup-interrupted      check_backup_interrupted
+run_check tracker-not-advanced    check_tracker_not_advanced
+run_check cbt-recovered           check_cbt_recovered
+run_check same-vm-recovery        check_same_vm_recovery
+run_check clean-lifecycle         check_clean_lifecycle
+run_check injection-window        check_injection_window
+run_check vmi-restart             check_vmi_restart
+run_check incremental-type-recorded check_incremental_type_recorded
+run_check incremental-chain-correct check_incremental_chain_correct
+run_check restore-verified        check_restore_verified
 
 blocked_evidence="$(detect_blocked)"
 verdict=''
 verdict_reason=''
 if [[ -n "$blocked_evidence" ]]; then
   verdict='BLOCKED'
   verdict_reason="observer/preflight recorded a blocked environment: $blocked_evidence"
 else
   fail_ids=()
   unknown_ids=()
   for i in "${!CHECK_IDS[@]}"; do
     case "${CHECK_STATUSES[$i]}" in
       FAIL) fail_ids+=("${CHECK_IDS[$i]}") ;;
       UNKNOWN) unknown_ids+=("${CHECK_IDS[$i]}") ;;
     esac
   done
   c2="$(status_of injection-signal)"
   c3="$(status_of launcher-replacement)"
-  if [[ -n "$WRONG_TARGET" ]]; then
+  if shape_models injection-signal && [[ -n "$WRONG_TARGET" ]]; then
     verdict='INVALID'
     verdict_reason="the injection targeted the wrong resource: the signal named launcher pod UID $WRONG_TARGET, but a different pod was removed"
-  elif [[ ( "$c2" == "FAIL" || "$c2" == "UNKNOWN" ) &&
+  elif shape_models injection-signal &&
+       [[ ( "$c2" == "FAIL" || "$c2" == "UNKNOWN" ) &&
         ( "$c3" == "FAIL" || "$c3" == "UNKNOWN" ) &&
         "$FULL_BACKUP_SUCCEEDED" == true ]]; then
     verdict='INVALID'
     verdict_reason="the injected condition was never exercised: injection-signal=$c2 launcher-replacement=$c3 while the full backup succeeded (${FULL_BACKUP_REASON})"
   elif ((${#fail_ids[@]} > 0)); then
     verdict='FAIL'
     verdict_reason="failing checks: ${fail_ids[*]}"
   elif ((${#unknown_ids[@]} > 0)); then
     verdict='INCONCLUSIVE'
     verdict_reason="missing mandatory evidence: ${unknown_ids[*]}"
-  elif [[ "$(status_of clean-lifecycle)" == "NOT_APPLICABLE" ]]; then
+  elif shape_models clean-lifecycle && [[ "$(status_of clean-lifecycle)" == "NOT_APPLICABLE" ]]; then
     verdict='INCONCLUSIVE'
     verdict_reason='no --clean-lifecycle-run supplied (clean-lifecycle NOT_APPLICABLE); verdict capped at INCONCLUSIVE'
   else
     verdict='PASS'
-    verdict_reason='injection independently evidenced, the interrupted full backup failed cleanly, CBT recovered, and restore/clean-lifecycle checks passed'
+    verdict_reason="every check modelled for scenario shape $SCENARIO_SHAPE passed (out-of-shape checks are NOT_APPLICABLE and are not part of this verdict)"
   fi
 fi
```

and the JSON gains the shape (so a reader can never mistake the scope), lines 1005-1012:

```diff
 output="$(jq -cn \
   --arg scenario "$scenario_name" \
   --arg run_id "$run_id" \
+  --arg scenario_shape "$SCENARIO_SHAPE" \
   --arg verdict "$verdict" \
   --arg reason "$verdict_reason" \
   --argjson checks "$checks_json" \
-  '{schema_version: 1, scenario: $scenario, run_id: $run_id, verdict: $verdict,
+  '{schema_version: 1, scenario: $scenario, run_id: $run_id,
+    scenario_shape: $scenario_shape, verdict: $verdict,
     verdict_reason: $reason, checks: $checks}')"
```

**A1.7 — the five I-01 checks** (insert after `check_clean_lifecycle`, i.e. after line 918; all inputs are
JSON — the trigger's own artifacts plus the lifecycle summary — so the evaluator never has to parse the
run dir's `*.yaml`):

```diff
+# --------------------------------------------------------------------------
+# Shape: vmi-restart-between-stages (CBT-I-01). Spec §5 criteria 1-5.
+# Inputs: trigger/action-request.json, trigger/effect-check.json,
+#         trigger/stage-outcomes.jsonl, lifecycle report.json/summary.json,
+#         lifecycle fragments/backup-timings.json. Never the run dir's YAML:
+#         the trigger writes JSON projections so this script stays a pure JSON
+#         reader.
+# --------------------------------------------------------------------------
+LC_TIMINGS_JSON="$(jq_doc "$LC_DIR/fragments/backup-timings.json")"
+
+# One stage line from trigger/stage-outcomes.jsonl: <stage> → compact JSON {}.
+stage_outcome() { # <stage>
+  jq -sc --arg stage "$1" '[.[] | select((.stage // "") == $stage)] | last // {}' \
+    "$TRIGGER_DIR/stage-outcomes.jsonl" 2>/dev/null || printf '{}'
+}
+
+# 1. injection-window — spec §5 criterion 1 (window + order of the two stages).
+check_injection_window() {
+  local expected='trigger/action-request.json: full Done + checkpoint recorded before the VMI delete request, no incremental object at the request, and the incremental object created after it'
+  local evidence=("$ACTION_REQUEST" "$TRIGGER_DIR/stage-outcomes.jsonl" "$LC_TIMINGS")
+  if [[ ! -s "$ACTION_REQUEST" ]]; then
+    add_check injection-window UNKNOWN "$expected" \
+      "trigger/action-request.json is absent or empty (the trigger records no window proof)" "${evidence[@]}"
+    return 0
+  fi
+  local actual
+  actual="$(jq -r --argjson req "$(jq_doc "$ACTION_REQUEST")" '
+    ($req.window // {}) as $w
+    | if (($req.utc_action_request // "") | length) == 0 then "no utc_action_request recorded"
+      elif (($w.full_checkpoint_name // "") | length) == 0 then "no full checkpoint recorded at the request"
+      elif (($w.full_done_status // "") != "True") then "full backup not Done at the request"
+      elif ($w.incremental_object_present_at_request // null) != false then "an incremental object already existed at the request"
+      else "complete" end' 2>/dev/null || printf 'unparseable action-request.json')"
+  if [[ "$actual" != "complete" ]]; then
+    add_check injection-window FAIL "$expected" "$actual" "${evidence[@]}"
+    return 0
+  fi
+  local req_epoch done_epoch created_epoch
+  req_epoch="$(utc_epoch "$(jq -r '.utc_action_request // ""' <<<"$(jq_doc "$ACTION_REQUEST")")")"
+  done_epoch="$(utc_epoch "$(jq -r '.window.full_done_utc // ""' <<<"$(jq_doc "$ACTION_REQUEST")")")"
+  created_epoch="$(utc_epoch "$(stage_outcome incremental | jq -r '.created_utc // ""')")"
+  if [[ -n "$done_epoch" && -n "$req_epoch" ]] && ((done_epoch > req_epoch)); then
+    add_check injection-window FAIL "$expected" \
+      "the delete request ($(jq -r '.utc_action_request' <<<"$(jq_doc "$ACTION_REQUEST")")) precedes full Done (window order inverted)" "${evidence[@]}"
+  elif [[ -n "$created_epoch" && -n "$req_epoch" ]] && ((created_epoch <= req_epoch)); then
+    add_check injection-window FAIL "$expected" \
+      "the incremental object was created before/at the delete request (window order inverted)" "${evidence[@]}"
+  else
+    add_check injection-window PASS "$expected" \
+      "delete request recorded after full Done with checkpoint recorded and before the incremental object" "${evidence[@]}"
+  fi
+}
+
+# 2. vmi-restart — spec §5 criterion 1 (independent effect: restart identity).
+check_vmi_restart() {
+  local expected='trigger/effect-check.json: new VMI UID differs from the old, the new VMI became Ready, and the launcher pod was replaced'
+  local evidence=("$EFFECT_CHECK" "$OBSERVER_DIR" "$RUN_DIR/vmi-recreated.yaml")
+  if [[ ! -s "$EFFECT_CHECK" ]]; then
+    add_check vmi-restart UNKNOWN "$expected" \
+      "trigger/effect-check.json is absent or empty (no trigger-side restart proof)" "${evidence[@]}"
+    return 0
+  fi
+  local doc; doc="$(jq_doc "$EFFECT_CHECK")"
+  local old new ready replaced
+  old="$(jq -r '.old_uid // "" | tostring' <<<"$doc")"
+  new="$(jq -r '.new_uid // "" | tostring' <<<"$doc")"
+  ready="$(jq -r 'if (.new_ready // false) then "true" else "false" end' <<<"$doc")"
+  replaced="$(jq -r 'if (.launcher_replaced // false) then "true" else "false" end' <<<"$doc")"
+  if [[ -z "$old" || -z "$new" ]]; then
+    add_check vmi-restart UNKNOWN "$expected" "effect-check.json records no old/new VMI UID" "${evidence[@]}"
+  elif [[ "$old" == "$new" ]]; then
+    add_check vmi-restart FAIL "$expected" "the VMI UID did not change ($old): no restart occurred" "${evidence[@]}"
+  elif [[ "$ready" != true || "$replaced" != true ]]; then
+    add_check vmi-restart FAIL "$expected" \
+      "UID changed, but new_ready=$ready launcher_replaced=$replaced" "${evidence[@]}"
+  else
+    add_check vmi-restart PASS "$expected" \
+      "UID $old → $new, new VMI Ready, launcher pod replaced" "${evidence[@]}"
+  fi
+}
+
+# 3. incremental-type-recorded — spec §5 criteria 2 and 5 (type + explicit reason
+#    + a duration consistent with the recorded type; uses only this run's own
+#    two durations, so it needs no external baseline band).
+check_incremental_type_recorded() {
+  local expected='the pass-1 backup is Done=True with type Incremental or Full and a recorded reason; an Incremental is shorter than this run''s full backup and a Full is not'
+  local evidence=("$TRIGGER_DIR/stage-outcomes.jsonl" "$LC_TIMINGS")
+  local line full_line type done reason seconds full_seconds
+  line="$(stage_outcome incremental)"; full_line="$(stage_outcome full)"
+  if [[ "$line" == '{}' || -z "$line" ]]; then
+    add_check incremental-type-recorded UNKNOWN "$expected" \
+      "trigger/stage-outcomes.jsonl has no incremental stage line" "${evidence[@]}"
+    return 0
+  fi
+  type="$(jq -r '.type // .backup_type // ""' <<<"$line")"
+  done="$(jq -r '.done_status // ""' <<<"$line")"
+  reason="$(jq -r '.done_reason // ""' <<<"$line")"
+  seconds="$(jq -r '.seconds // empty' <<<"$line")"
+  full_seconds="$(jq -r '.seconds // empty' <<<"$full_line")"
+  if [[ "$type" != Incremental && "$type" != Full ]]; then
+    add_check incremental-type-recorded FAIL "$expected" \
+      "the pass-1 backup type is '$type' (explicitly Incremental or Full required)" "${evidence[@]}"
+  elif [[ "$done" != True || -z "$reason" ]]; then
+    add_check incremental-type-recorded FAIL "$expected" \
+      "type=$type but Done=$done reason='$reason' (terminal Done=True with a reason required)" "${evidence[@]}"
+  elif [[ -n "$seconds" && -n "$full_seconds" ]] &&
+       [[ "$type" == Incremental ]] && ((seconds >= full_seconds)); then
+    add_check incremental-type-recorded FAIL "$expected" \
+      "recorded type=Incremental but its ${seconds}s duration is not shorter than this run's full backup (${full_seconds}s): the type is not credible" "${evidence[@]}"
+  else
+    add_check incremental-type-recorded PASS "$expected" \
+      "type=$type, Done=True, reason recorded, ${seconds:-?}s vs full ${full_seconds:-?}s" "${evidence[@]}"
+  fi
+}
+
+# 4. incremental-chain-correct — spec §5 criterion 3 (one new checkpoint, chain valid).
+check_incremental_chain_correct() {
+  local expected='the pass-1 checkpoint is distinct from the full checkpoint, the tracker holds the pass-1 checkpoint, and the lifecycle chain checks passed'
+  local evidence=("$TRIGGER_DIR/stage-outcomes.jsonl" "$ACTION_REQUEST" "$LC_REPORT")
+  local line full_cp incr_cp tracker_cp chain_ok
+  line="$(stage_outcome incremental)"
+  if [[ "$line" == '{}' || -z "$line" ]]; then
+    add_check incremental-chain-correct UNKNOWN "$expected" \
+      "trigger/stage-outcomes.jsonl has no incremental stage line" "${evidence[@]}"
+    return 0
+  fi
+  full_cp="$(jq -r '.window.full_checkpoint_name // ""' <<<"$(jq_doc "$ACTION_REQUEST")")"
+  incr_cp="$(jq -r '.checkpoint_name // ""' <<<"$line")"
+  tracker_cp="$(jq -r '.tracker_checkpoint_after // ""' <<<"$line")"
+  chain_ok="$(jq -r '
+    [(.verification.checks // [])[] | select(.name == "incremental_pass_01_checkpoint_is_distinct"
+                                            or .name == "tracker_matches_final_incremental_checkpoint")]
+    | if length == 2 and all(.[]; .passed == true) then "true" else "false" end' <<<"$LC_REPORT_JSON" 2>/dev/null || printf 'false')"
+  if [[ -z "$incr_cp" ]]; then
+    add_check incremental-chain-correct FAIL "$expected" "the pass-1 checkpoint is not recorded" "${evidence[@]}"
+  elif [[ -n "$full_cp" && "$incr_cp" == "$full_cp" ]]; then
+    add_check incremental-chain-correct FAIL "$expected" \
+      "the pass-1 checkpoint equals the full checkpoint ($incr_cp): no new checkpoint" "${evidence[@]}"
+  elif [[ -n "$tracker_cp" && "$tracker_cp" != "$incr_cp" ]]; then
+    add_check incremental-chain-correct FAIL "$expected" \
+      "the tracker holds '$tracker_cp', not the pass-1 checkpoint '$incr_cp'" "${evidence[@]}"
+  elif [[ "$chain_ok" != true ]]; then
+    add_check incremental-chain-correct FAIL "$expected" \
+      "lifecycle report.json does not carry both chain checks passed (distinct + tracker match)" "${evidence[@]}"
+  else
+    add_check incremental-chain-correct PASS "$expected" \
+      "pass-1 checkpoint $incr_cp distinct from the full checkpoint, tracker matches, lifecycle chain checks passed" "${evidence[@]}"
+  fi
+}
+
+# 5. restore-verified — spec §5 criteria 2 and 4 (data content correct per restore).
+check_restore_verified() {
+  local expected='lifecycle summary.json: restore hashes PASS (full-only and cumulative) with zero failed restore/hash checks and lifecycle complete; report.json verification.overall_passed=true'
+  local evidence=("$LC_SUMMARY" "$LC_REPORT")
+  local actual
+  actual="$(jq -r '
+    if (.restore_hashes.status // "") != "PASS" then "restore_hashes.status=\(.restore_hashes.status // "<absent>")"
+    elif (.restore_hashes.failed_restore_check_count // -1) != 0 then "failed_restore_check_count=\(.restore_hashes.failed_restore_check_count)"
+    elif (.restore_hashes.failed_hash_check_count // -1) != 0 then "failed_hash_check_count=\(.restore_hashes.failed_hash_check_count)"
+    elif (.lifecycle.state // "") != "complete" then "lifecycle.state=\(.lifecycle.state // "<absent>")"
+    else "complete" end' <<<"$LC_SUMMARY_JSON" 2>/dev/null || printf 'unparseable summary.json')"
+  if [[ "$actual" != complete ]]; then
+    add_check restore-verified FAIL "$expected" "$actual" "${evidence[@]}"
+  elif [[ "$(jq -r 'if (.verification.overall_passed // false) then "true" else "false" end' <<<"$LC_REPORT_JSON")" != true ]]; then
+    add_check restore-verified FAIL "$expected" \
+      "report.json verification.overall_passed is not true" "${evidence[@]}"
+  else
+    add_check restore-verified PASS "$expected" \
+      "full-only and cumulative restore hashes PASS, zero failed checks, lifecycle complete" "${evidence[@]}"
+  fi
+}
+
 # 7. cbt-recovered
```

and the state/lifecycle-path block gains the timings path, lines 207-220:

```diff
 LC_SUMMARY="$LC_DIR/summary.json"
+LC_TIMINGS="$LC_DIR/fragments/backup-timings.json"
```

**A1.8 — the declared input list in the header** (lines 25-32) gains the new trigger artifact and the
lifecycle timings file, plus the artifact-shape documentation of the new artifacts (after line 113, the
`trigger/effect-check.json` shape block, which stays for the interrupted-full shape):

```diff
 # Read-only inputs (nothing else is read):
 #   <scenario-dir>/runs/<run-id>/trigger/*        injection evidence
 #   <scenario-dir>/runs/<run-id>/observer/*       optional corroboration
-#   <root>/runs/<lifecycle-run>/{run.json,report.json,summary.json}
+#   <root>/runs/<lifecycle-run>/{run.json,report.json,summary.json,
+#                                fragments/backup-timings.json}
 #   <root>/runs/<clean-lifecycle-run>/summary.json
 # Nothing is written except the optional --json PATH.
+#
+# Shape vmi-restart-between-stages reads only JSON:
+#   trigger/action-request.json  .utc_action_request, .window.full_backup,
+#                                .window.full_type, .window.full_done_status,
+#                                .window.full_done_utc, .window.full_checkpoint_name,
+#                                .window.incremental_object_present_at_request
+#   trigger/effect-check.json    .old_uid, .new_uid, .new_ready,
+#                                .launcher_replaced, .old_launcher_pod, .new_launcher_pod
+#   trigger/stage-outcomes.jsonl one JSON object per stage as it finishes; the
+#                                `incremental` line carries .status, .seconds,
+#                                .created_utc, .checkpoint_name, .type, .done_status,
+#                                .done_reason, .tracker_checkpoint_after
```

**A1.9 — the shape declaration file** (new file, scenario level; added by the Lead once, not per run):

```diff
+ cbt-chaos/scenarios_v2/CBT-I-01/harness-shape
+----------------------------------------------------------------------
+vmi-restart-between-stages
```

(One token, one line. Existing scenarios need no file: the default is `interrupted-full`, which is why
CBT-F-01 and the frozen `tests/test-scenario-verdict.sh` continue to behave identically.)

### 1.4 Diff A2 — `cbt-chaos-run` states which scenarios the evaluator covers *(human gate)*

File `.agents/skills/cbt-chaos-run/SKILL.md` (§ "Deterministic verdict (mandatory)", lines 229-234):

```diff
 cbt-chaos/scenario-verdict.sh --scenario-dir <scenario-dir> --run-id <RUN_ID> \
   --lifecycle-run <NAME> [--clean-lifecycle-run <CLEAN_NAME>] [--json <PATH>]
 ```
 
+**Coverage — the shape must be declared, and the default is one shape only.** The evaluator selects its
+check set from a declared scenario shape: `--scenario-shape SHAPE`, else the first line of
+`<scenario-dir>/harness-shape`, else the default `interrupted-full` (the interrupted-full-backup
+shape used by CBT-F-01 — a *failed* full backup, a same-VM recovery attempt, and a separate clean
+lifecycle). A scenario whose criteria do not have that shape **must** declare its own shape (today
+`vmi-restart-between-stages`, CBT-I-01) or the evaluator will grade the wrong criteria. Checks outside
+the declared shape are reported `NOT_APPLICABLE`; an unmodelled shape is a usage error (exit 2), never a
+verdict. A check id in the output that your scenario's spec does not name is a sign the shape is
+declared wrong — fix the declaration, do not re-read the verdict as prose.
+
 It exits 0 only when the verdict is `PASS`, and writes JSON containing the verdict plus per-check statuses;
```

### 1.5 Diff A3 — audit capability row *(human gate)*

File `docs/agent-workflow-audit.md:67` (the `scenario-verdict.sh` row), two cells:

```diff
-| `cbt-chaos/scenario-verdict.sh` (new) | Deterministic scenario verdict from artifacts | scenario dir, run ids | JSON verdict + per-check statuses | 0 PASS, 1 other verdict, 2 usage | R | none; missing evidence ⇒ UNKNOWN | `test-scenario-verdict.sh` | Criterion-level verdict from recorded evidence — not physical qcow2 allocation | Lead in `cbt-chaos-run`/`cbt-chaos-team`; `cbt-chaos-injection-checker`, `cbt-chaos-evidence-checker`, `cbt-chaos-report-writer` |
+| `cbt-chaos/scenario-verdict.sh` (new) | Deterministic scenario verdict from artifacts, **per declared scenario shape** | scenario dir, run ids, `--scenario-shape` (else `<scenario-dir>/harness-shape`, else `interrupted-full`) | JSON verdict (`scenario_shape` included) + per-check statuses (`NOT_APPLICABLE` for out-of-shape checks) | 0 PASS, 1 other verdict, 2 usage/unknown shape | R | none; missing evidence ⇒ UNKNOWN; unmodelled shape ⇒ exit 2, never a verdict | `test-scenario-verdict.sh` (per-shape cases) | Criterion-level verdict **for the declared shape only** — not physical qcow2 allocation, and not the criteria of a shape the scenario did not declare | Lead in `cbt-chaos-run`/`cbt-chaos-team`; `cbt-chaos-injection-checker`, `cbt-chaos-evidence-checker`, `cbt-chaos-report-writer` |
```

### 1.6 Diff A4 — evaluator tests *(human gate)*

`tests/test-scenario-verdict.sh`: the fixture helper gains an I-01 kind and three cases are added. Sketch
of the acceptance-relevant case (fixture = successful full + one incremental + tracker + restore PASS, no
recovery attempt, no clean lifecycle, `trigger/action-request.json`, `trigger/effect-check.json`,
`trigger/stage-outcomes.jsonl` present, scenario dir containing `harness-shape`):

```diff
+# --- (g1) a declared I-01 shape is graded, not declared invalid -----------------
+printf 'vmi-restart-between-stages\n' > "$SCENARIO_DIR/harness-shape"
+write_lifecycle "$RUN_ID" vmi-restart
+write_i01_trigger_artifacts "$RUN_ID"
+stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" 2>/dev/null)" && verdict_status=0 || verdict_status=$?
+[[ "$verdict_status" -eq 0 ]] ||
+  fail "an I-01-shaped run with declared shape must exit 0 (PASS), got status $verdict_status"
+[[ "$(jq -r '.verdict' <<<"$stdout_out")" == "PASS" ]] ||
+  fail "declared I-01 shape must yield PASS, got $(jq -r '.verdict' <<<"$stdout_out")"
+[[ "$(jq -r '[.checks[] | select(.status == "INVALID")] | length' <<<"$stdout_out")" == "0" ]] ||
+  fail "no check may ever carry status INVALID"
+[[ "$(jq -r '.scenario_shape' <<<"$stdout_out")" == "vmi-restart-between-stages" ]] ||
+  fail "the verdict document must name the shape it graded"
+
# --- (g2) a shape misdeclaration can never produce INVALID ----------------------
+# An interrupted-full-shaped run whose shape is declared as I-01: the F-01-only
+# checks must be NOT_APPLICABLE (not UNKNOWN, not FAIL), the I-01 checks must be
+# UNKNOWN for want of artifacts, and the verdict must be INCONCLUSIVE — never the
+# "injected condition was never exercised" INVALID that an out-of-model check set
+# would fabricate.
+write_lifecycle "$RUN_ID" failed            # the existing interrupted-full fixture
+rm -f "$SCENARIO_DIR/harness-shape"         # no declaration: the flag decides
+stdout_out="$("$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" \
+  --scenario-shape vmi-restart-between-stages 2>/dev/null)" && verdict_status=0 || verdict_status=$?
+[[ "$(jq -r '.verdict' <<<"$stdout_out")" == "INCONCLUSIVE" ]] ||
+  fail "out-of-shape checks must yield INCONCLUSIVE, got $(jq -r '.verdict' <<<"$stdout_out")"
+[[ "$(jq -r '[.checks[] | select(.id == "injection-signal")][0].status' <<<"$stdout_out")" == "NOT_APPLICABLE" ]] ||
+  fail "an out-of-shape check must be NOT_APPLICABLE"
+[[ "$(jq -r '[.checks[] | select(.id == "injection-window")][0].status' <<<"$stdout_out")" == "UNKNOWN" ]] ||
+  fail "a missing in-shape artifact must be UNKNOWN, not NOT_APPLICABLE"
+[[ "$(jq -r '[.checks[] | select(.status == "INVALID")] | length' <<<"$stdout_out")" == "0" ]] ||
+  fail "no check may ever carry status INVALID"
+
+# --- (g3) an unknown shape is a usage error, not a verdict ---------------------
+usage_status=0
+"$VERDICT" --scenario-dir "$SCENARIO_DIR" --run-id "$RUN_ID" --scenario-shape nonsense >/dev/null 2>&1 || usage_status=$?
+[[ "$usage_status" -eq 2 ]] || fail "an unmodelled shape must exit 2, got $usage_status"
```

The existing cases (a) … (f) must keep passing unchanged — in particular `(d)`'s
"a successful full backup with no injection evidence must be INVALID" (`tests/test-scenario-verdict.sh:238-239`)
and `(e)`'s fixed `--list-checks` order, both of which describe the default shape.

### 1.7 Acceptance for I-1

- `make test` green, with `(g1)`/`(g2)`/`(g3)` above present.
- Re-graded on this run's frozen artifacts: `scenario-verdict.sh --scenario-dir
  cbt-chaos/scenarios_v2/CBT-I-01 --run-id 20261016-cbt-i-01-r01` emits
  `.scenario_shape="vmi-restart-between-stages"`, seven of the eight F-01 checks `NOT_APPLICABLE` (only
  `run-id-consistency` is modelled in both shapes), and a
  verdict that is not `INVALID` (with the run's artifacts as they are — empty `trigger/` — it is
  `INCONCLUSIVE` on `injection-window`/`vmi-restart`/`incremental-*`; after the I-2 trigger diff lands it
  is `PASS`).
- Owner: harness maintainer; gates: script = none (Lead-approved), `cbt-chaos-run` SKILL.md +
  audit + tests = **human**.

> **Note on naming:** HV1's own text asks for `NOT_APPLICABLE`/`INCONCLUSIVE` "instead of INVALID for
> out-of-model checks". Diff A1 delivers exactly that; `INVALID` survives only as an in-shape verdict
> (both its branches are now gated on `shape_models injection-signal`), so the F-01 semantics that
> `tests/test-scenario-verdict.sh:(d)` pins are preserved.

---

## 2. (b) the trigger wrote no `trigger/` artifacts — §5 criterion 1 rests on the observer alone

### 2.1 Symptom (artifact + field)

- `runs/20261016-cbt-i-01-r01/trigger/` is **empty**: no `action-request.json`, no `effect-check.json`,
  no `exit-statuses.json`, no `command.txt`, no `stage-outcomes.jsonl`.
- The evidence-index for the run lists 55 files; the only trigger-related entries are
  `contracts/trigger.md` and `trigger.log` — the trigger's own stdout capture,
  which contains the window proof as prose only: `trigger.log:78-79`
  ("UTC action request: delete VMI … at 2026-10-16T01:39:06Z … old uid b203235a…") and `trigger.log:81`
  (new uid `29dfe33c…`, new launcher pod `…-zp4kv`).
- `runs/20261016-cbt-i-01-r01/state.json`/`ledger.jsonl` do not record the full stage's exit code either
  (the report notes this at `reports/test-run-report.md:144`).
- Consequence: §5 criterion 1 ("VMI deleted after full stage exit … new VMI UID differs … launcher pod
  replaced") is carried **entirely** by one writer class — the observer's watch streams. The checkers
  graded it PASS, but every citation is `observer/watches/*` or the trigger's prose log
  (`checkers/injection-validity.json` `.criteria[].evidence[]`).

### 2.2 Root cause (established)

The run's trigger contract assigns the artifacts to the **trigger worker**
(`runs/20261016-cbt-i-01-r01/contracts/trigger.md`, "Outputs you own … `trigger/exit-statuses.json` —
`{"stage":"full|vmi-delete|incremental","status":N,"seconds":N}` per stage you can attribute") while the
data required to produce them exists only inside `chaos-trigger.sh`: the per-stage exit codes and wall
times (`chaos-trigger.sh:147-160`, `:225-234`), the delete request instant (`:178-182`) and the UID
before/after (`:174-175`, `:189-209`). The worker sees one aggregate exit status of one command.
The contract therefore names an owner that cannot observe the data; when the Lead ran the trigger
directly this time, the standard artifacts were never produced at all. This is a **single-writer
defect**, not a discipline failure.

### 2.3 Diff B1 — `cbt-chaos/scenarios_v2/CBT-I-01/chaos-trigger.sh` *(Lead gate)*

The trigger becomes the single writer of its own evidence, exactly as CBT-F-01's trigger does
(`cbt-chaos/scenarios_v2/CBT-F-01/chaos-trigger.sh:219-228` `write_json`, `:322` `effect-check.json`,
`:386` `action-request.json`, `:442` `exit-statuses.json`). Artifact names are the ones the run contract
already declares, so the contract/action stays recognisable.

**B1.1 — paths and one helper** (lines 43-44):

```diff
 FULL_BACKUP_NAME="vm-backup-${RUN_ID}"
 EVIDENCE_DIR="$ROOT_DIR/cbt-chaos/scenarios_v2/CBT-I-01/runs/$RUN_ID"
+TRIGGER_DIR="$EVIDENCE_DIR/trigger"
+INCREMENTAL_NAME="vm-incremental-${RUN_ID}-p01"
+
+# Writes one jq-built JSON object atomically (tmp+mv). Evidence writes are never
+# fatal: the scenario's exit status must not depend on artifact bookkeeping.
+write_trigger_json() { # <path> <jq -n args...>
+  local path="$1"; shift
+  local payload tmp
+  payload="$(jq -n "$@" 2>/dev/null)" || { printf 'Warning: jq could not build %s; continuing.\n' "$path" >&2; return 0; }
+  tmp="$(mktemp "$TRIGGER_DIR/.$(basename "$path").XXXXXX" 2>/dev/null)" || return 0
+  if printf '%s\n' "$payload" >"$tmp" && mv -f "$tmp" "$path"; then return 0; fi
+  rm -f "$tmp" 2>/dev/null || true
+}
```

**B1.2 — stage timing + the `--plan` promise** (lines 104, 143-147). The collision guard stays ahead of
every write, so a second launch still refuses before touching `trigger/`:

```diff
-  printf 'evidence written by a real run (nothing is written by --plan): %s/\n' "$EVIDENCE_DIR"
+  printf 'evidence written by a real run (nothing is written by --plan):\n'
+  printf '  %s/{full-backup.yaml,incremental-backup.yaml,tracker.yaml,vmi-recreated.yaml,injection.log,trigger.log}\n' "$EVIDENCE_DIR"
+  printf '  %s/trigger/{action-request.json,effect-check.json,stage-outcomes.jsonl,exit-statuses.json,command.txt}\n' "$TRIGGER_DIR"
@@
 mkdir -p "$EVIDENCE_DIR"
+mkdir -p "$TRIGGER_DIR"
 exec > >(tee -a "$EVIDENCE_DIR/trigger.log") 2>&1
+
+# The trigger records its own argv (kubeconfig redacted) and every stage exit
+# code: the worker contract cannot observe per-stage statuses, so the process
+# that owns the data owns the artifact.
+printf 'RUN_ID=%s KUBECONFIG_PATH=<redacted> bash %s\n' \
+  "$RUN_ID" "$(basename "${BASH_SOURCE[0]}")" > "$TRIGGER_DIR/command.txt" 2>/dev/null || true
+
+stage_log() { # <stage> <status> <seconds> <extra jq args...>
+  local stage="$1" status="$2" seconds="$3"; shift 3
+  local line
+  line="$(jq -cn --arg stage "$stage" --argjson status "$status" --argjson seconds "$seconds" \
+    --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$@" \
+    '{stage:$stage, status:$status, seconds:$seconds, utc:$utc}' 2>/dev/null)" || return 0
+  printf '%s\n' "$line" >> "$TRIGGER_DIR/stage-outcomes.jsonl" 2>/dev/null || true
+}
+
+# Installed here — after every collision guard, before the first mutation — so
+# every exit path from this point records one terminal JSON document, while
+# --plan and a refused launch still write nothing. A stage that never ran simply
+# has no line in stage-outcomes.jsonl: the stages array is built from that file,
+# never from variables an early abort left unset.
+write_exit_statuses() { # <exit-code>
+  local stages='[]'
+  if [[ -s "$TRIGGER_DIR/stage-outcomes.jsonl" ]]; then
+    stages="$(jq -sc '.' "$TRIGGER_DIR/stage-outcomes.jsonl" 2>/dev/null || printf '[]')"
+  fi
+  write_trigger_json "$TRIGGER_DIR/exit-statuses.json" \
+    --arg run_id "$RUN_ID" \
+    --arg expectation 'stages_nonzero_is_failure' \
+    --argjson exit_code "${1:-0}" \
+    --argjson stages "$stages" \
+    --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
+    '{run_id:$run_id, scenario:"CBT-I-01", expectation:$expectation,
+      exit_code:$exit_code, stages:$stages, utc:$utc}'
+}
+trap 'write_exit_statuses "$?"' EXIT
+
+# Initialised before the first stage so the trap body can never trip `set -u`.
+full_status=0; full_seconds=0
+followup_status=0; followup_seconds=0
+followup_start=0; delete_start=0
```

**B1.3 — stage 1 timing and the window proof + `action-request.json`** (lines 146-184):

```diff
 # --- Stage 1: full backup (checkpoint recorded on exit) -------------------
+full_start=$SECONDS
 if make e2e TYPE=full NAME="$RUN_ID" \
@@
   full_status=$?
 fi
+full_seconds=$((SECONDS - full_start))
 if ((full_status != 0)); then
+  stage_log full "$full_status" "$full_seconds" --arg note 'aborted before VMI deletion'
   printf 'Full stage failed (%d); aborting before VMI deletion.\n' "$full_status" >&2
   exit "$full_status"
 fi
@@
   exit 1
 fi
+
+# Window proof for spec §5 criterion 1: the full backup is Done with its
+# checkpoint recorded and no incremental object exists — recorded as JSON before
+# the action is requested, so the window cannot be re-narrated afterwards.
+full_type="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
+  -o jsonpath='{.status.type}' 2>/dev/null || true)"
+full_done_status="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
+  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
+full_done_utc="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
+  -o jsonpath='{.status.conditions[?(@.type=="Done")].lastTransitionTime}' 2>/dev/null || true)"
+full_checkpoint="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
+  -o jsonpath='{.status.checkpointName}' 2>/dev/null || true)"
+tracker_before="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
+  -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || true)"
+incremental_present_before=false
+if oc get vmbackup "$INCREMENTAL_NAME" -n "$NAMESPACE" -o name >/dev/null 2>&1; then
+  incremental_present_before=true
+fi
+observer_armed_utc=''
+if [[ -s "$EVIDENCE_DIR/observer/ARMED" ]]; then
+  observer_armed_utc="$(jq -r '.utc // ""' "$EVIDENCE_DIR/observer/ARMED" 2>/dev/null || true)"
+fi
 
 # --- Stage 2: the disruption — delete the VMI between the stages ----------
@@
 printf 'UTC action request: delete VMI %s at %s (full checkpoint recorded, no incremental backup exists).\n' \
   "$VMI_NAME" "$injection_requested_utc" >&2
+write_trigger_json "$TRIGGER_DIR/action-request.json" \
+  --arg run_id "$RUN_ID" \
+  --arg namespace "$NAMESPACE" \
+  --arg vm "$VM_NAME" \
+  --arg vmi "$VMI_NAME" \
+  --arg vmi_uid_before "${old_uid:-}" \
+  --arg launcher_pod_before "${old_launcher:-}" \
+  --arg full_backup "$FULL_BACKUP_NAME" \
+  --arg full_type "$full_type" \
+  --arg full_done_status "$full_done_status" \
+  --arg full_done_utc "$full_done_utc" \
+  --arg full_checkpoint_name "$full_checkpoint" \
+  --arg tracker_checkpoint_before "$tracker_before" \
+  --argjson incremental_object_present_at_request "$incremental_present_before" \
+  --arg utc_action_request "$injection_requested_utc" \
+  --arg utc_observer_armed "$observer_armed_utc" \
+  '{run_id:$run_id, scenario:"CBT-I-01", target_kind:"VirtualMachineInstance",
+    namespace:$namespace, vm:$vm, vmi:$vmi,
+    vmi_uid_before:$vmi_uid_before, launcher_pod_before:$launcher_pod_before,
+    window:{full_backup:$full_backup, full_type:$full_type,
+      full_done_status:$full_done_status, full_done_utc:$full_done_utc,
+      full_checkpoint_name:$full_checkpoint_name,
+      tracker_checkpoint_before:$tracker_checkpoint_before,
+      incremental_object_present_at_request:$incremental_object_present_at_request},
+    utc_action_request:$utc_action_request,
+    utc_observer_armed:$utc_observer_armed}'
+delete_start=$SECONDS
 oc delete vmi "$VMI_NAME" -n "$NAMESPACE" --wait=false \
   >"$EVIDENCE_DIR/injection.log" 2>&1
+delete_status=$?
 printf 'VMI deletion issued at %s (old uid %s, old launcher %s).\n' \
```

and the full stage's outcome line, written after the window reads above (it carries the fields the I-01
checks consume: `.status .seconds .created_utc .type .done_status .done_reason .checkpoint_name`), is a
separate hunk inserted at the end of the stage-1 block:

```diff
 observer_armed_utc=''
 if [[ -s "$EVIDENCE_DIR/observer/ARMED" ]]; then
   observer_armed_utc="$(jq -r '.utc // ""' "$EVIDENCE_DIR/observer/ARMED" 2>/dev/null || true)"
 fi
+full_created_utc="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
+  -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
+full_done_reason="$(oc get vmbackup "$FULL_BACKUP_NAME" -n "$NAMESPACE" \
+  -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
+stage_log full "$full_status" "$full_seconds" --arg type "$full_type" \
+  --arg done_status "$full_done_status" --arg done_reason "$full_done_reason" \
+  --arg checkpoint_name "$full_checkpoint" --arg created_utc "$full_created_utc" \
+  --arg tracker_checkpoint_after "$full_checkpoint"
 
 # --- Stage 2: the disruption — delete the VMI between the stages ----------
```

(The `incremental` line's `.tracker_checkpoint_after` comes from the incremental `stage_log` in B1.5.)

**B1.4 — `effect-check.json` after the recreation wait** (lines 205-216):

```diff
 new_launcher="$(oc get pods -n "$NAMESPACE" -o name 2>/dev/null \
   | grep "virt-launcher-${VMI_NAME}-" | head -1 || true)"
 printf 'VMI recreated: new uid %s (old %s), new launcher %s (old %s), Ready at %s.\n' \
   "$new_uid" "$old_uid" "${new_launcher:-unknown}" "${old_launcher:-unknown}" \
   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
+
+# Independent effect proof for spec §5 criterion 1, written by the injector but
+# *about* objects it re-read from the API (the observer's own streams remain the
+# independent corroboration, so the injector is never the sole authority).
+old_uid_gone=false
+if [[ -n "$old_uid" ]] && [[ -z "$(oc get vmi "$VMI_NAME" -n "$NAMESPACE" \
+    -o jsonpath='{.metadata.uid}' 2>/dev/null | grep -F "$old_uid" || true)" ]]; then
+  old_uid_gone=true
+fi
+write_trigger_json "$TRIGGER_DIR/effect-check.json" \
+  --arg run_id "$RUN_ID" \
+  --arg namespace "$NAMESPACE" \
+  --arg vmi "$VMI_NAME" \
+  --arg old_uid "$old_uid" \
+  --arg new_uid "$new_uid" \
+  --arg old_launcher_pod "$old_launcher" \
+  --arg new_launcher_pod "$new_launcher" \
+  --argjson old_uid_gone "$old_uid_gone" \
+  --argjson new_ready true \
+  --argjson launcher_replaced "$([[ -n "$new_launcher" && "$new_launcher" != "$old_launcher" ]] && printf true || printf false)" \
+  --arg ready_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
+  '{run_id:$run_id, namespace:$namespace, target_kind:"VirtualMachineInstance",
+    vmi:$vmi, old_uid:$old_uid, new_uid:$new_uid, old_uid_gone:$old_uid_gone,
+    new_ready:$new_ready, old_launcher_pod:$old_launcher_pod,
+    new_launcher_pod:$new_launcher_pod, launcher_replaced:$launcher_replaced,
+    ready_utc:$ready_utc}'
+stage_log vmi-delete "$delete_status" "$((SECONDS - delete_start))" \
+  --arg old_uid "$old_uid" --arg new_uid "$new_uid" \
+  --arg old_launcher_pod "$old_launcher" --arg new_launcher_pod "$new_launcher"
```

**B1.5 — the incremental stage's outcome line** (lines 218-246; `exit-statuses.json` itself is written by
the B1.2 trap, on this path as on every other):

```diff
 followup_status=0
+followup_start=$SECONDS
 for ((pass = 1; pass <= planned_passes; pass++)); do
@@
 done
-if ((followup_status != 0)); then exit "$followup_status"; fi
+followup_seconds=$((SECONDS - followup_start))
+if ((followup_status != 0)); then
+  # The stage failed: record what is known, then exit with the real code (the
+  # EXIT trap writes exit-statuses.json; the missing outcome fields are simply
+  # absent, never invented).
+  stage_log incremental "$followup_status" "$followup_seconds" --arg note 'stage failed'
+  exit "$followup_status"
+fi
 
 # Record the resulting backup type (incremental vs documented full fallback)
 # as the primary scenario observation.
-incr_name="vm-incremental-${RUN_ID}-p01"
-incr_type="$(oc get vmbackup "$incr_name" -n "$NAMESPACE" \
+incr_name="$INCREMENTAL_NAME"
+incr_type="$(oc get vmbackup "$incr_name" -n "$NAMESPACE" \
   -o jsonpath='{.status.type}' 2>/dev/null || true)"
+incr_done_status="$(oc get vmbackup "$incr_name" -n "$NAMESPACE" \
+  -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)"
+incr_done_reason="$(oc get vmbackup "$incr_name" -n "$NAMESPACE" \
+  -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || true)"
+incr_checkpoint="$(oc get vmbackup "$incr_name" -n "$NAMESPACE" \
+  -o jsonpath='{.status.checkpointName}' 2>/dev/null || true)"
+incr_created_utc="$(oc get vmbackup "$incr_name" -n "$NAMESPACE" \
+  -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
+tracker_after="$(oc get vmbackuptracker "$TRACKER_NAME" -n "$NAMESPACE" \
+  -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || true)"
 printf 'RESULTING BACKUP TYPE for %s after VMI restart: %s\n' \
   "$incr_name" "${incr_type:-unknown}" >&2
+stage_log incremental "$followup_status" "$followup_seconds" \
+  --arg type "$incr_type" --arg done_status "$incr_done_status" \
+  --arg done_reason "$incr_done_reason" --arg checkpoint_name "$incr_checkpoint" \
+  --arg created_utc "$incr_created_utc" --arg tracker_checkpoint_after "$tracker_after"
 oc get vmbackup "$incr_name" -n "$NAMESPACE" -o yaml >"$EVIDENCE_DIR/incremental-backup.yaml" 2>/dev/null || true
 
 printf 'Follow-up incremental passes completed (%s).\n' "$planned_passes" >&2
+
+# exit-statuses.json is already written by the EXIT trap installed in B1.2, so
+# this exit path needs no bookkeeping of its own.
 exit 0
```

(The `full_status`/`full_seconds`/`followup_status`/`followup_seconds` variables are initialised
immediately after the trap is installed — `full_status=0 full_seconds=0 followup_status=0
followup_seconds=0` plus `followup_start=0` and `delete_start=0` — so an early abort cannot trip `set -u`,
and a stage that never ran is simply absent from `stage-outcomes.jsonl`.)

### 2.4 Diff B2 — contract and spec *(both gates)*

**B2.1 — run trigger contract** (`runs/<run>/contracts/trigger.md`; per-run, Lead; the *template* under
`cbt-chaos/contracts/` is human-gated):

```diff
-- `trigger/exit-statuses.json` — `{"stage":"full|vmi-delete|incremental","status":N,"seconds":N}` per stage you can attribute.
-- `trigger/stage-outcomes.jsonl` — one line per stage as it finishes.
+- `trigger/*` is now written **by `chaos-trigger.sh` itself** (`trigger/action-request.json`,
+  `trigger/effect-check.json`, `trigger/stage-outcomes.jsonl`, `trigger/exit-statuses.json`,
+  `trigger/command.txt`): the per-stage exit codes and the UID-before/after exist only inside the
+  script, so the script is their single writer (a worker cannot observe them).
+- You own only: `trigger/console.full.log` (the complete console capture, materialised after the run
+  exits). Never rewrite a `trigger/*.json` written by the script.
```

**B2.2 — spec §5 criterion 1 evidence-of-record** (`scenario-spec.md:34`; **human gate**):

```diff
-- Injection validity: VMI deleted after full stage exit (full Done + checkpoint recorded) and before incremental object creation; new VMI UID differs from the old (proof of restart); launcher pod replaced.
+- Injection validity: VMI deleted after full stage exit (full Done + checkpoint recorded) and before
+  incremental object creation; new VMI UID differs from the old (proof of restart); launcher pod
+  replaced. Evidence of record: `trigger/action-request.json` (window: full Done status/instant,
+  checkpoint name, tracker checkpoint, `incremental_object_present_at_request=false`, action-request
+  instant) and `trigger/effect-check.json` (old/new VMI UID, readiness, launcher replacement),
+  corroborated by the observer's own name-scoped `vmi`/`pods` watch streams. Neither the injector nor
+  the observer may be the sole authority for their own claim: if one of the two artifact sets is
+  missing the criterion is **unproven**, not PASS.
```

### 2.5 Acceptance for I-2

- `--plan` still writes nothing (byte-identical `--plan` output except the new evidence-path lines).
- A real run (any future I-01 run) leaves `trigger/` holding the five artifacts; `pack-validate.sh`
  passes; `evidence-index.sh` indexes them.
- Re-graded with Diff A1 applied: `injection-window`, `vmi-restart`,
  `incremental-type-recorded`, `incremental-chain-correct`, `restore-verified` all `PASS` and the verdict
  is `PASS` (exit 0). On this frozen run, with `trigger/` empty, the same checks must be `UNKNOWN` ⇒
  `INCONCLUSIVE` — that gap is *enforced*, not narrated (no `pack-validate.sh` change is needed for this:
  the evaluator's `UNKNOWN` already caps the verdict at `INCONCLUSIVE`).
- Owner: Lead (trigger + contract); spec edit: **human**.

---

## 3. (c) non-monotonic `deletionTimestamp` — root cause established, two runs

### 3.1 Symptom (artifact + field)

`runs/20261016-cbt-i-01-r01/observer/watches/pods-vm.jsonl`, old launcher pod
`virt-launcher-vm-…-tb228` (uid `d07f057a-…`), in rv order:

| rv | type | phase | `deletionTimestamp` | `deletionGracePeriodSeconds` |
|---|---|---|---|---|
| 27132652 | MODIFIED | Running | `01:40:06Z` | 60 |
| 27132660 | MODIFIED | Running | `01:40:06Z` | 60 |
| 27132852 | MODIFIED | Succeeded (compute `finishedAt` `01:39:15Z`) | `01:40:06Z` | 60 |
| 27132861 | MODIFIED | Succeeded | `01:39:16Z` | 0 |
| 27132862 | DELETED (tombstone) | Succeeded | `01:39:16Z` | 0 |

The value moves **backwards** while rv rises. Recurrence, CBT-F-01 r04
(`cbt-chaos/scenarios_v2/CBT-F-01/runs/20261016-cbt-f-01-r04/observer/watches/pods-vm.jsonl`, recorded
as O1 in that run's analysis): rv 27101685/27101692/27101917 → `01:13:26Z`/grace 60, then
rv 27101925 + tombstone 27101926 → `01:12:38Z`/grace 0.

For scale in I-01, the *VMI* delete was requested at `01:39:06Z` (rv 27132651,
`metadata.deletionTimestamp=01:39:06Z`, `deletionGracePeriodSeconds: 0` —
`observer/watches/vmi.jsonl:29-34`, quoted in `checkers/injection-validity.json` `.criteria[target]`),
and the pod's grace-60 deadline `01:40:06Z` sits exactly 60 s after it.

### 3.2 Root cause (established, both runs, read from the packs)

`metadata.deletionTimestamp` is the deletion **deadline** (`now + gracePeriodSeconds`), not the instant of
the delete request; when a second DELETE arrives with a *shorter* grace period the API server legitimately
rewrites the deadline **backwards** and `deletionGracePeriodSeconds` changes with it. In both occurrences
`deletionGracePeriodSeconds` moves 60 → 0 across exactly the transition where the timestamp regresses,
and the regressed value equals the container's real termination instant to the second
(I-01 `finishedAt 01:39:15Z` → tombstone `01:39:16Z`; F-01 `finishedAt 01:12:37Z` → tombstone
`01:12:38Z`). The first delete carries the pod's `spec.terminationGracePeriodSeconds: 60`; the second,
grace-0 delete is the teardown that actually stops the pod.

*Labelled as [INFERENCE], unused by this proposal:* the second delete in I-01 is most plausibly
virt-handler/virt-controller finishing the VMI removal after the domain exited; the packs do not record
who issued it, and nothing here depends on it.

**This is not a Kubernetes defect.** Nothing is wrong with the API server: the harness read a deadline as
if it were a monotonic request instant, and a checker later treated the (correct) regression as a
citation error — which is exactly what happened in F-01 r04, where a report-fidelity REJECT was produced
by blaming the wrong rv/phase for this series (`20261016-cbt-f-01-r04-improvements.md:130`, hypothesis
`H7`).

### 3.3 Why it matters

It has already cost a revision loop (F-01 r04 H7) and it is the kind of anomaly a checker can read as a
contradiction in the injection proof. Left unnamed, the third occurrence will look like new corruption.
The safe convention is already the one I-01's observer chose by instinct: use
`containerStatuses[compute].state.terminated.finishedAt` (or the replacement's `creationTimestamp`) as the
termination instant, and keep the rv-ordered series as the explanation.

### 3.4 Diff C1 — observer skill rule *(human gate, mandatory under the twice-rule)*

`.agents/skills/cbt-chaos-observer-worker/SKILL.md`, after the "Record distinct UTC times for …" bullet
(lines 65-67):

```diff
 - Record distinct UTC times for: armed, scenario signal, action request,
   observed target effect, backup/recovery transitions. State clock
   uncertainty when timestamps cannot support subsecond ordering.
+- `metadata.deletionTimestamp` is a deletion **deadline** (`now +
+  gracePeriodSeconds`), not the instant of the delete request, and the API server
+  legitimately rewrites it *backwards* when a later DELETE carries a shorter grace
+  period — `metadata.deletionGracePeriodSeconds` changes with it (60 → 0). Never
+  assert a disappearance instant from a `deletionTimestamp` series that is not
+  monotonic in resourceVersion order: use the container's
+  `status.containerStatuses[].state.terminated.finishedAt` (or the replacement
+  object's `metadata.creationTimestamp`) and record the rv-ordered
+  `deletionTimestamp`/`deletionGracePeriodSeconds` pair as the explanation.
+  Occurrences: CBT-F-01 r04 (`pods-vm.jsonl` rv 27101917 `01:13:26Z` grace 60 →
+  rv 27101926 `01:12:38Z` grace 0) and CBT-I-01 r01 (`pods-vm.jsonl` rv 27132852
+  `01:40:06Z` grace 60 → rv 27132862 `01:39:16Z` grace 0).
```

### 3.5 Diff C2 — run observer contract clause *(Lead gate)*

`runs/<run>/contracts/observer.md` (I-01's is at `…/contracts/observer.md:35-51`, the "Observe
independently" list):

```diff
    - the VMI's UID **before** the deletion and the new UID after recreation,
      with the instant of each (or an explicit time bound if you only have one);
+     the old launcher pod's termination instant must come from
+     `status.containerStatuses[compute].state.terminated.finishedAt`, not from
+     `metadata.deletionTimestamp` — the latter is a deadline that the API server
+     rewrites backwards on a shorter-grace second delete (see the observer skill);
+     if you quote the `deletionTimestamp` series, quote both it and
+     `deletionGracePeriodSeconds` in rv order;
```

### 3.6 Harness ticket **HT-1** and the smallest reproduction

See §6.1. The reproduction is two commands over the two **already frozen** packs (zero cluster time) plus
an optional 30-second live confirmation.

### 3.7 Acceptance for I-3

- The skill rule and the contract clause are present; the next observer pack that reports a pod
  termination cites `finishedAt` as the instant and both fields in rv order (reviewable in
  `observer/finding.md` "Bounds and gaps").
- Ticket HT-1 is filed with the two pack citations.
- Owner: observer-worker skill (**human**), contract (Lead), ticket (harness backlog).

---

## 4. (d) `oc exec` and guest-side checkpoint evidence — not needed by §5; a template mandate was dropped

### 4.1 The question, answered from the artifacts

Does §5 criterion 2 ("if Incremental, it must be genuinely incremental (changed blocks vs full — data
content correct per restore)") need the observer to `oc exec` into the launcher for
`virsh checkpoint-list`? **No.** Two independent reasons, both from this run:

1. **The decisive test in the criterion is the restore result**, and the harness produces it without any
   exec: `runs/20261016-cbt-i-01-r01/report.json` `.verification.overall_passed=true` with 17/17 checks
   including `incremental_pass_01_checkpoint_is_distinct` and
   `tracker_matches_final_incremental_checkpoint`; `summary.json` `.restore_hashes
   ={status:PASS, full_only:PASS, incremental_prefixes:PASS, all:PASS,
   failed_restore_check_count:0, failed_hash_check_count:0, algorithm:SHA-256}`.
2. **The redefinition evidence §7 names already exists without exec** — in the lifecycle's own launcher
   capture `runs/20261016-cbt-i-01-r01/logs/virt-launcher.log`:

   | line | `msg` | `checkpointName` | `uid` | `timestamp` |
   |---|---|---|---|---|
   | 1304 | `Redefining checkpoint` | `vm-backup-…-2026-10-16_01-38-09` | — | `01:39:20.703916Z` |
   | 1308 | `Checkpoint redefined successfully with 1 disks` | `vm-backup-…-2026-10-16_01-38-09` | — | `01:39:20.735245Z` |
   | 1309 | `Checkpoint … redefined successfully` | `vm-backup-…-2026-10-16_01-38-09` | `29dfe33c-…` | `01:39:20.735277Z` |
   | 1364 | `Generating incremental backup vm-incremental-…-p01 from checkpoint: vm-backup-…_01-38-09` | — | — | `01:40:38.054177Z` |

   Line 1309 carries the **post-restart** VMI UID (`29dfe33c-…` = the recreated instance), 4.7 s after
   recreation and 75 s before the incremental object existed; line 1364 states the incremental's base
   checkpoint explicitly. That is precisely §7's "checkpoint redefinition evidence", obtained with
   `oc logs` (a read this observer could already do) — not `oc exec`.

### 4.2 What is actually broken

- **§7's ownership claim is false.** `scenario-spec.md:47` says "the observer captures launcher logs and
  events for the redefinition evidence". The run-specific observer contract
  (`runs/20261016-cbt-i-01-r01/contracts/observer.md`) mandates no launcher-log capture and no exec, and
  the observer's `finding.md` bounds section correctly says so ("No `oc exec` / libvirt access"). The
  capture that exists is the *lifecycle pipeline's*, not the observer's.
- **A template mandate was silently dropped — HV3's class recurring.** The parameterised template
  `cbt-chaos/contracts/observer.md:72-75` *requires* "before injection, capture the checkpoint-tree state
  via the launcher compute container (`virsh checkpoint-list --tree`) into
  `watches/checkpoint-tree-pre.txt` … capture again at PRESERVED into
  `evidence-terminal/checkpoint-tree-post.txt`". That is the exec-based capture, and the per-run contract
  dropped it — exactly the mechanism recorded as **HV3** (a per-run contract narrowing a template
  mandate; `docs/agent-plan-incorrect-points.md:209-217`), and it is the second occurrence of that class.
- **The cited redefinition log is not hash-pinned.** `runs/20261016-cbt-i-01-r01/evidence/` is empty and no
  index covers the lifecycle run dir; the scenario pack's `evidence-index.json` has 55 entries, all under
  the scenario run dir. Yet `checkers/injection-validity.json` `.criteria[independent-effect].evidence[]`
  cites `runs/20261016-cbt-i-01-r01/logs/virt-launcher.log`, and its own
  `.false_positives_checked` claims "sha256 of every cited pack file equals evidence-index.json" — true
  for *pack* files only. If the launcher log is to be the evidence of record for redefinition, it must be
  inside an index the checkers verify.

### 4.3 Diff D1 — spec: name the evidence of record *(human gate)*

`cbt-chaos/scenarios_v2/CBT-I-01/scenario-spec.md:47`:

```diff
-- Checkpoint redefinition details live in virt-launcher logs (libvirt domain events) and the vmbackup controller logs; the observer captures launcher logs and events for the redefinition evidence.
+- Checkpoint redefinition details live in the lifecycle's own virt-launcher capture
+  (`runs/<RUN_ID>/logs/virt-launcher.log`) and the vmbackup controller logs.
+  **Evidence of record for redefinition** is that log's `Redefining checkpoint` /
+  `Checkpoint redefined successfully with 1 disks` / `Checkpoint <name> redefined
+  successfully` entries whose `uid` equals the **post-restart** VMI UID, plus the
+  `Generating incremental backup <pass> from checkpoint: <full checkpoint>` entry
+  — i.e. the redefinition is proven against the full checkpoint by the component
+  that performs it, not by the observer. The copy of that log used as evidence
+  MUST be hash-pinned (copied into the scenario pack's indexed set, or indexed in
+  the lifecycle run's own index) before the checkers grade. The observer's
+  contribution is corroboration (checkpointName/tracker/UID streams), not this
+  capture.
```

and criterion 2 (`:35`) gains the operative-test sentence so the residual is explicit at the criterion:

```diff
-- CBT recovery: pass-1 backup `Done=True`; its type recorded (Incremental or Full fallback) with the reason; if Incremental, it must be genuinely incremental (changed blocks vs full — data content correct per restore) — a silent wrong-content incremental is FAIL.
+- CBT recovery: pass-1 backup `Done=True`; its type recorded (Incremental or Full fallback) with the
+  reason; if Incremental, it must be genuinely incremental — checkpoint redefined against the full
+  checkpoint (evidence of record per §7) and the restored data content correct — a silent wrong-content
+  incremental is FAIL. The criterion's operative test is the restore comparison; block-extent
+  incrementality (which blocks were copied) is **not** provable from any artifact this harness
+  captures and is explicitly out of scope (a qcow2 allocation map would be required).
```

### 4.4 Diff D2 — observer contract clause (Lead gate), and the exec decision

Two options; the recommendation is **D2a** (no exec), with D2b kept as the conditional if libvirt-level
XML is wanted:

**D2a (recommended, no new capability)** — add to `runs/<run>/contracts/observer.md`:

```diff
    - the final chain/restore verification result.
+   - the redefinition evidence of record (spec §7): cite the **lifecycle** launcher
+     capture `runs/<RUN_ID>/logs/virt-launcher.log` — the
+     `Checkpoint <full-checkpoint> redefined successfully` entry whose `uid` equals
+     the post-restart VMI UID, and the
+     `Generating incremental backup <pass> from checkpoint: <full checkpoint>` entry.
+     Read it read-only at PRESERVED/FINAL; if it is not readable from your host at
+     that moment, record that as a gap — do not attempt `oc exec`.
```

**D2b (conditional; needs a human RBAC decision)** — if libvirt-level proof is required later, the exec
must be exactly this and nothing else:

```diff
+   - ONE read-only exec is authorised on this run's own launcher pod, recorded in
+     `watches/` with its argv: `oc exec -n vm-cbt-demo -c compute
+     <virt-launcher-…> -- virsh checkpoint-list --tree` (and
+     `virsh checkpoint-dumpxml --name <checkpoint>`); before injection and again at
+     PRESERVED. No other exec, no writes, no state change; a failed exec is a gap,
+     never a substitute for the API evidence.
```

**Decision: D2a. Why not exec for this scenario:** the template mandate's *purpose* (a second source for
redefinition) is already met by the launcher log; `virsh checkpoint-list` adds libvirt XML, which §5 does
not require; and exec is a privileged verb on a mutating path for an observer whose contract is
"read-only". The real fix for the recurring dropped-mandate class is to stop authoring per-run observer
contracts by hand or to state the drop explicitly (see HT-3) — not to grant exec.

**Labeled hypothesis (never verified here), recorded so the residual is not re-litigated:** block-extent
incrementality would need a qcow2 allocation map (`qemu-img map`, or `qemu-img measure` on the destination
image) read from the *backup/restore* side, not from the launcher — so even granting exec into
virt-launcher would **not** close the §5.2 residual. It stays bounded regardless of this decision.

### 4.5 Diff D4 — pin the cited lifecycle artifacts *(Lead gate)*

Minimal: copy the two lifecycle artifacts the checkers actually cite into the indexed set at pack-freeze
time — `runs/<RUN_ID>/logs/virt-launcher.log` and `runs/<RUN_ID>/run.json` — into
`cbt-chaos/scenarios_v2/CBT-I-01/runs/<RUN_ID>/lifecycle-cited/`, and re-run
`cbt-chaos/evidence-index.sh <scenario-run-root>` before `pack-validate.sh`. (Alternative: extend
`cbt-chaos/evidence-index.sh` to index a second root. The copy is smaller and keeps one index.)

### 4.6 Acceptance for I-4

- `scenario-spec.md` §5.2 and §7 name the evidence of record and state the residual at the criterion
  (human gate).
- The next run's `observer/finding.md` cites the launcher-log redefinition entry with the post-restart
  UID, and the copy it cites is inside `evidence-index.json` (verify with
  `jq -r '.files | keys[]' <scenario-run>/evidence-index.json`).
- No exec capability is required; if D2b is ever adopted, the exec argv and its raw output are in
  `observer/watches/`.
- Owner: spec (**human**), contracts/evidence packing (Lead).

---

## 5. Repeat-failure escalation (twice-rule)

Three classes now have ≥2 occurrences; per the scenario-improver skill their skill/spec diffs are
**mandatory** (the human either approves each or declines in writing, recorded in the ledger).

| Class | Occurrence 1 | Occurrence 2 (this run) | Mandatory diff |
|---|---|---|---|
| **Non-monotonic `deletionTimestamp` read as an anomaly** | CBT-F-01 r04 O1 (`20161016-cbt-f-01-r04-improvements.md` O1; wrong rv/phase attribution caused a report-fidelity REJECT, H7) | I-01 r01 `observer/finding.md` bounds section; series in §3.1 | **Diff C1** (§3.4) + **Diff C2** (§3.5) + HT-1 |
| **A per-run contract silently drops a template mandate** | CBT-F-01 r04 (the libvirt checkpoint tree, **HV3**, `docs/agent-plan-incorrect-points.md:209-217`) | I-01 r01: the same template mandate (`cbt-chaos/contracts/observer.md:72-75`) is absent from this run's observer contract, and §7 still claims the observer captured it | **Diff D1** (§4.3) + **Diff D2a** (§4.4) + HT-3 |
| **The deterministic evaluator's verdict is narrower or wrong outside its shape** | CBT-F-01 r04 W2 (`20261016-cbt-f-01-r04-improvements.md:121-152`: a PASS narrower than the spec's PASS) | I-01 r01 **HV1** (`verdict.json` `.verdict=INVALID`; `state.json` `.evaluator`) | **Diff A1-A4** (§1) + HT-2 |

---

## 6. Harness-ticket drafts

### 6.1 HT-1 — `deletionTimestamp` is a deadline, not an instant; the observer layer must stop treating it as monotonic

- **Component:** `cbt-chaos-observer-worker` skill / observer contracts / (optionally)
  `cbt-chaos/watch-resource.sh` docs.
- **Problem:** two runs' pod streams regress `metadata.deletionTimestamp` as `resourceVersion` rises
  (I-01 r01 rv 27132852 `01:40:06Z` grace 60 → rv 27132862 `01:39:16Z` grace 0; F-01 r04 rv 27101917
  `01:13:26Z` grace 60 → rv 27101926 `01:12:38Z` grace 0). Each occurrence consumed analysis time, and the
  first caused a report-fidelity REJECT for a mis-attributed citation.
- **Root cause:** the field is the deletion *deadline*; a later DELETE with a shorter grace period
  rewrites it backwards and moves `deletionGracePeriodSeconds` with it. Not an API defect, and not
  reproducible-failure material for the product — a harness interpretation defect.
- **Smallest reproduction (zero cluster time, both packs are frozen):**

  ```sh
  for f in cbt-chaos/scenarios_v2/CBT-I-01/runs/20261016-cbt-i-01-r01/observer/watches/pods-vm.jsonl \
           cbt-chaos/scenarios_v2/CBT-F-01/runs/20261016-cbt-f-01-r04/observer/watches/pods-vm.jsonl; do
    jq -c 'select(.object.metadata.deletionTimestamp != null)
           | {rv:.object.metadata.resourceVersion, ts:.object.metadata.deletionTimestamp,
              grace:.object.metadata.deletionGracePeriodSeconds,
              fin:(.object.status.containerStatuses[]? | select(.name=="compute")
                   | .state.terminated.finishedAt)}' "$f"
  done
  ```

  Expect, in each stream: two rvs with grace 60 and a later rv with grace 0 whose `ts` is *smaller* and
  equals `fin` (+1 s).

  **Optional live confirmation (~30 s, must not run in `vm-cbt-demo` during a scenario run):**

  ```sh
  oc run grace-probe -n <scratch-ns> --image=<pinned-test-image> --restart=Never --command -- sleep 600
  oc wait --for=jsonpath='{.status.phase}'=Running pod/grace-probe -n <scratch-ns> --timeout=120s
  cbt-chaos/watch-resource.sh <scratch-ns> pod name grace-probe /tmp/grace-probe.jsonl /tmp/grace-probe.ready &
  sleep 5
  oc delete pod grace-probe -n <scratch-ns> --wait=false                    # deadline = now+60, grace 60
  sleep 5
  oc delete pod grace-probe -n <scratch-ns> --grace-period=0 --wait=false   # deadline rewritten, grace 0
  sleep 30
  jq -c 'select(.object.metadata.deletionTimestamp != null)
         | {ts:.object.metadata.deletionTimestamp, grace:.object.metadata.deletionGracePeriodSeconds}' /tmp/grace-probe.jsonl
  ```
- **Triage suggestion:** do not file against Kubernetes. Fix the reading: (i) the skill rule (Diff C1);
  (ii) the observer contracts (Diff C2); (iii) optionally teach `cbt-chaos/pack-validate.sh` (or the
  observers' `FINAL` self-check) to flag a non-monotonic `deletionTimestamp` series as an *explained
  anomaly* with the `deletionGracePeriodSeconds` pair, so no future checker mistakes it for corruption.
  Escalate to CNV/KubeVirt only if a live probe ever shows a regression with *identical* grace values —
  that would be a genuine rv-ordering violation.
- **Owner:** harness (skill is human-gated).

### 6.2 HT-2 — the deterministic evaluator must select its check set from a declared scenario shape

- **Component:** `cbt-chaos/scenario-verdict.sh`, `cbt-chaos-run` skill, audit matrix,
  `tests/test-scenario-verdict.sh`.
- **Problem:** on CBT-I-01 the evaluator returned `INVALID` with a factually false reason, because it
  applies the CBT-F-01 check set to every scenario (HV1, `docs/agent-plan-incorrect-points.md:186-199`);
  the same defect already produced a too-narrow PASS on CBT-F-01 r04 (W2). A machine verdict that is
  confidently wrong outside its shape can only be overturned by prose, which the verdict contract forbids.
- **Fix:** Diff A1-A4 in §1 — declared shape (`<scenario-dir>/harness-shape` or
  `--scenario-shape`), check sets per shape, `NOT_APPLICABLE` for out-of-shape checks, `INVALID` and the
  `clean-lifecycle` cap gated to the shapes that model them, `scenario_shape` in the output document,
  per-shape test cases.
- **Acceptance:** §1.7 (test cases `(g1)`/`(g2)`/`(g3)`; re-grading this run's frozen pack yields a shape
  named verdict that is not `INVALID`).
- **Owner:** harness maintainer; skill/audit/tests human-gated.

### 6.3 HT-3 — scenario evidence artifacts must be written by the process that owns the data

- **Component:** CBT-I-01 `chaos-trigger.sh`, the trigger-contract template, and every scenario whose
  per-run contract assigns JSON artifacts to the trigger *worker*.
- **Problem:** this run's `trigger/` is empty. The contract asked the worker for
  `trigger/exit-statuses.json` (per-stage status+seconds) and `trigger/stage-outcomes.jsonl`, data that
  exists only inside `chaos-trigger.sh` (`:147-160`, `:178-182`, `:189-209`, `:225-234`). When the Lead
  ran the trigger directly, the standard artifacts vanished and §5 criterion 1 was left to the observer
  alone.
- **Fix:** Diff B1 + B2 (§2). Generalisable rule for the template: an artifact is owned by the process
  that observes its fields; aggregate-exit-only owners may own only the aggregate.
- **Acceptance:** §2.5 — a real run produces all five trigger artifacts; the evaluator's `injection-window`
  is `UNKNOWN` (⇒ verdict ≤ `INCONCLUSIVE`) when `trigger/action-request.json` is absent.
- **Owner:** Lead (script + contract), template + spec human-gated.

---

## 7. Candidate lessons for closeout

Each cites the artifact that proves it.

1. **A deterministic verdict must carry the shape it graded.** `verdict.json` said `INVALID` on a run both
   blind checkers passed; `state.json` `.evaluator="INVALID (inapplicable, HV1)"`. A verdict document
   without `.scenario_shape` cannot be defended or refuted mechanically. (§1)
2. **Assign an artifact to the process that can observe its fields.** `trigger/` empty while
   `trigger.log:78-81` held the data the contract wanted as JSON. (§2)
3. **`deletionTimestamp` is a deadline.** Two runs' `pods-vm.jsonl` regress it as rv rises because a
   shorter-grace second delete rewrote it; `deletionGracePeriodSeconds` 60 → 0 is the tell, and the
   container's `finishedAt` is the instant to quote. (§3)
4. **Prefer the component that performs an action as the witness that it happened.** The redefinition is
   proven by `virt-launcher.log:1309` (`uid` = post-restart VMI) — no exec, no observer-level libvirt
   access needed. (§4.1)
5. **"Hash-pinned evidence" must include every artifact the checkers cite.** The lifecycle launcher log
   was cited by `checkers/injection-validity.json` while `runs/<id>/evidence/` was empty and the pack
   index covered only the scenario run dir. (§4.2)
6. **State a bounded residual at the criterion, not in the analysis.** §5.2's operative test is the
   restore comparison; block-extent incrementality needs a qcow2 map no artifact captures. (§4.3)

---

## 8. Gate summary (who applies what)

| Diff | File | Gate |
|---|---|---|
| A1 | `cbt-chaos/scenario-verdict.sh` | Lead approves/applies (harness script) |
| A1.9 | `cbt-chaos/scenarios_v2/CBT-I-01/harness-shape` (new) | Lead |
| A2 | `.agents/skills/cbt-chaos-run/SKILL.md` | **human** |
| A3 | `docs/agent-workflow-audit.md` row 67 | **human** |
| A4 | `tests/test-scenario-verdict.sh` | **human** |
| B1 | `cbt-chaos/scenarios_v2/CBT-I-01/chaos-trigger.sh` | Lead |
| B2.1 | `runs/<run>/contracts/trigger.md` (and the `cbt-chaos/contracts/` template) | Lead (template: **human**) |
| B2.2 | `cbt-chaos/scenarios_v2/CBT-I-01/scenario-spec.md` §5.1 | **human** |
| C1 | `.agents/skills/cbt-chaos-observer-worker/SKILL.md` | **human** (mandatory) |
| C2 | `runs/<run>/contracts/observer.md` | Lead |
| D1 | `scenario-spec.md` §5.2 + §7 | **human** |
| D2a/D2b | `runs/<run>/contracts/observer.md` | Lead (D2b also human: RBAC) |
| D4 | evidence packing/indexing at freeze | Lead |

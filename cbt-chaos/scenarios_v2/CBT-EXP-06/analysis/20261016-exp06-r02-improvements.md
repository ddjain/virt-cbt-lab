# Scenario / harness improvements — CBT-EXP-06 run `20261016-exp06-r02`

- Author: `ScenarioImprover` (post-close, read-only on the pack; nothing applied).
- Closed run: `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02` (verdict **BLOCKED**, frozen).
- Inputs read: the closed pack (`trigger/`, `observer/`, `checkers/`, `recovery/`, `preflight/`, `ledger.jsonl`, `evidence-index.json`), the run's pre-close analysis (`analysis/20261016-exp06-r02.md`), the same-VM follow-up (`followup/20261016-exp06-r02-same-vm/`), the scenario contract (`scenario-spec.md`, `chaos-trigger.sh`), the harness (`cbt-chaos/{scenario-verdict.sh,evidence-index.sh,pack-validate.sh,ledger-append.sh,contracts/*}`, `scripts/{write-run-summary.sh,vm-cbt-*.sh,common.sh}`, `.agents/skills/cbt-chaos-{team,preflight-worker,observer-worker}/`), and the two `reject-reasons.tsv` indexes.
- **Nothing in this document has been applied.** Every diff is a proposal awaiting human approval; the twice-rule items (§1, §2) are MANDATORY by the team contract and are flagged for an explicit approve/decline.
- Labels: **observed** = read from a cited artifact; **[INFERENCE]** = my reading, not an artifact fact.

Artifact convention: paths are relative to the scenario directory unless prefixed (`runs/…` = the closed run root, `scripts/…`, `cbt-chaos/…` = the repo).

---

## 0. Summary of proposals

| id | class | occurrences | severity | target file(s) | mandatory |
|---|---|---|---|---|---|
| **M1** | `evaluator-out-of-shape` | 3 (CBT-F-01 r04, CBT-I-01 r01, here) | high | `cbt-chaos/scenario-check-sets.tsv` (new), `cbt-chaos/scenario-verdict.sh`, `chaos-trigger.sh`, `tests/test-scenario-verdict.sh` | **YES** |
| **M2** | `evidence-index-hash-drift` | 2 (CBT-F-04 r03, here) | medium | `cbt-chaos/pack-validate.sh`, `cbt-chaos/evidence-index.sh`, `.agents/skills/cbt-chaos-team/SKILL.md`, `cbt-chaos/contracts/check-*.md` | **YES** |
| **M3** | `injection-pre-state-not-independently-witnessed` | 1 | high | `cbt-chaos/contracts/observer.md` (template), `cbt-chaos/contracts/trigger.md`, `chaos-trigger.sh`, scenario `observer/effect/capture-pre.sh` (v2) | no |
| M4-a | observer gate double-counts ready files | 1 | low | `chaos-trigger.sh` | no |
| M4-b | `exit-statuses.json#control_full_status` hardcoded 0 | 1 | low | `chaos-trigger.sh` | no |
| M4-c | follow-up driver reports a phantom CR removal | 1 | low | `same-vm-followup.sh` | no |
| M4-d | preflight capacity measured on the parent filesystem | 1 | high | `cbt-chaos/contracts/preflight.md`, `.agents/skills/cbt-chaos-preflight-worker/SKILL.md`, `chaos-trigger.sh` (in-run floor) | no |
| M4-e | platform version never captured | 1 | medium | `cbt-chaos/contracts/preflight.md`, preflight SKILL | no |
| M4-f | `write-run-summary.sh` says `PENDING` for an unverified CBT state | 1 (code path; not in this run's summary — see §5) | medium | `scripts/write-run-summary.sh`, `cbt-chaos/scenario-verdict.sh` | no |
| M4-g | run-root sync can truncate the ledger / leave a stale mirror | 2 (r02 pre-flight, r02 post-close) | medium | `.agents/skills/cbt-chaos-team/SKILL.md` | no |

---

## 1. MANDATORY — M1 `evaluator-out-of-shape`

### 1.1 What happened (observed)

`verdict-evaluator.json` → `{"verdict":"FAIL","verdict_reason":"failing checks: injection-signal"}`, exit 1. The Lead recorded the applicability limitation rather than softening it (`checkers/verdict.json#sub_verdicts.deterministic_evaluator.applicability`):

> "The evaluator's fixed check table is written for the interrupted-FULL-backup / launcher-pod-kill family: injection-signal requires an active-copy signal this scenario does not have by design, backup-interrupted expects a failed FULL backup whereas here the full succeeded and the INCREMENTAL is the affected pass, and cbt-recovered reads a lifecycle verify check that never ran."

Code side (observed, `cbt-chaos/scenario-verdict.sh`):

- `:167-179` `list_check_table()` prints one fixed 8-id list; `:240` `JQ_DEFS`; `:956-963` the eight `check_*` calls are a hardcoded dispatch sequence.
- `:360-470` `check_injection_signal()` requires `active_copy` (a launcher `Backup started` line) plus a launcher pod **UID**; a per-disk QMP bitmap removal has no launcher pod to name.
- `:590-650` `check_backup_interrupted()` requires the *full* backup to be `type=Full` + `Done=True` + a failure reason + a retained PVC; in EXP-06 the full is the healthy control leg and the affected object is an *incremental*.
- `:717-798` `check_cbt_recovered()` needs `report.json verification.checks[vm_cbt_is_enabled|vmi_running]`; the verify stage's fragment exists in this run but a scenario whose verification never runs has no such input.

Scenario side (observed): the trigger has no concept of the family either — it emits no outcome record for the affected pass at all (`chaos-trigger.sh:505-518` are one-shot reads; `trigger.log:157-158` "SURGERY INCREMENTAL RESULT: type=? Done=? includedVolumes=?"; `trigger/run-notes.md#anomalies 4`: 0 grep matches for any classification line).

Prior occurrences (twice-rule trail): `.agents/skills/cbt-chaos-team/cbt-chaos-team-learnings.md` 2026-10-16 — "three failure classes reached ≥2 occurrences across these runs: **evaluator-out-of-shape (HV1)** … Per the team contract the Scenario Improver must then produce the exact diff and the human must approve or explicitly decline it; nothing was applied."

### 1.2 Design of the fix

Add a **check-set registry** (fixed text in the repo, never a run artifact) plus the three checks a surgery family needs. Rules that make it safe:

1. A run's check set comes from the registry row for `basename(scenario_dir)`, else the `default` row; `--check-set` overrides by name. A scenario cannot invent its own set from inside its evidence pack.
2. An id named by a set but **not implemented** in the evaluator is reported `UNKNOWN` (fail-closed) — naming an unimplemented check can only cap the verdict at `INCONCLUSIVE`, never widen it.
3. The default row is byte-identical to today's table, so every existing scenario's verdict is unchanged.

### 1.3 Diff M1-a — new file `cbt-chaos/scenario-check-sets.tsv`

```diff
--- /dev/null
+++ b/cbt-chaos/scenario-check-sets.tsv
@@
+# scenario-verdict.sh check sets.
+# Format: <check-set key>\t<comma-separated check ids, fixed order>
+# A scenario whose directory name has no row here falls back to `default`.
+# Every id must be implemented by cbt-chaos/scenario-verdict.sh (see
+# `--list-checks`); an id with no implementation is reported UNKNOWN
+# (fail-closed), so a check set can only narrow a verdict, never widen it.
+default	run-id-consistency,injection-signal,launcher-replacement,backup-interrupted,tracker-not-advanced,cbt-recovered,same-vm-recovery,clean-lifecycle
+CBT-EXP-06	run-id-consistency,injection-pre-state,injection-effect,affected-pass-outcome,cbt-recovered,same-vm-recovery,clean-lifecycle
```

Rationale for the CBT-EXP-06 row: `injection-signal`/`launcher-replacement` do not exist in a bitmap-surgery scenario; `backup-interrupted` inverts (the full is the control leg); `tracker-not-advanced` is the opposite of this scenario's premise (the tracker *does* hold a checkpoint — that divergence is the finding). The seven retained/new ids are: run identity, the pre-state witness, the per-disk effect, the affected pass's outcome, CBT recovery, same-VM follow-up, clean lifecycle.

### 1.4 Diff M1-b — `cbt-chaos/scenario-verdict.sh`

**Hunk 1 — header docs (`:34-52`), keep `--list-checks` truthful**

```diff
@@
-Checks (fixed ids, fixed order):
+# Checks: implementations with fixed ids and fixed behaviour. Which ids are
+# evaluated for a run comes from a check set (cbt-chaos/scenario-check-sets.tsv:
+# the row for the scenario directory name, else `default`), overridable with
+# --check-set NAME / --check-set-file PATH. An id named by a set with no
+# implementation is UNKNOWN (fail-closed) and can never yield PASS.
@@
 #   cbt-recovered        CBT returned to Enabled and the VM/VMI is Running after
 #                        recovery
+#   injection-pre-state  a non-injector witness shows the named checkpoint bitmap
+#                        present on the target disk before the removal
+#   injection-effect     the target disk lost exactly the named bitmap while a
+#                        sibling disk of the same guest kept its bitmap
+#   affected-pass-outcome
+#                        the affected pass has a modelled outcome: a terminal
+#                        condition with its volumes, or a recorded non-terminal
+#                        stall past the wait bound
 #   same-vm-recovery     the same-VM recovery attempt succeeded and its restore
 #                        comparison matched the baseline (count/bytes/hash)
```

**Hunk 2 — usage (`:121-132`)**

```diff
@@ usage()
     '  --clean-lifecycle-run NAME   separate clean lifecycle to compare against' \
     '  --json PATH                  also write the JSON verdict to PATH' \
     '  --list-checks                print check ids + descriptions as TSV' \
+    '  --list-check-sets            print the check-set registry as TSV' \
+    '  --check-set NAME             check set from cbt-chaos/scenario-check-sets.tsv (default: the scenario id, else `default`)' \
+    '  --check-set-file PATH        alternate check-set registry (same TSV shape)' \
     '  --help                       print this usage' \
```

**Hunk 3 — variables and argument parsing (`:137-165`)**

```diff
@@
 scenario_dir=''
 run_id=''
 lifecycle_run=''
 clean_lifecycle_run=''
 json_path=''
 list_checks=false
+check_set=''
+check_set_file=''
+list_check_sets=false
 
 while (($# > 0)); do
   case "$1" in
-    --scenario-dir|--run-id|--lifecycle-run|--clean-lifecycle-run|--json)
+    --scenario-dir|--run-id|--lifecycle-run|--clean-lifecycle-run|--json|--check-set|--check-set-file)
       (($# >= 2)) || usage_err "$1 requires a value"
       case "$1" in
         --scenario-dir) scenario_dir="$2" ;;
         --run-id) run_id="$2" ;;
         --lifecycle-run) lifecycle_run="$2" ;;
         --clean-lifecycle-run) clean_lifecycle_run="$2" ;;
         --json) json_path="$2" ;;
+        --check-set) check_set="$2" ;;
+        --check-set-file) check_set_file="$2" ;;
       esac
       shift 2
       ;;
     --list-checks) list_checks=true; shift ;;
+    --list-check-sets) list_check_sets=true; shift ;;
     --help|-h) usage; exit 0 ;;
     *) usage_err "unknown argument: $1" ;;
   esac
 done
```

**Hunk 4 — `list_check_table()` (`:167-179`) gains the three new ids**

```diff
@@ list_check_table()
     'backup-interrupted' 'the interrupted full backup is terminal and failed (type=Full, Done=True, failure reason, PVC retained)' \
     'tracker-not-advanced' 'the tracker held no checkpoint at failure and none is attributed to the interrupted copy' \
+    'injection-pre-state' 'a non-injector witness shows the named checkpoint bitmap present on the target disk before the removal' \
+    'injection-effect' 'the target disk lost exactly the named bitmap while a sibling disk of the same guest kept its bitmap' \
+    'affected-pass-outcome' 'the affected pass has a modelled outcome: a terminal condition with its volumes, or a recorded non-terminal stall past the wait bound' \
     'cbt-recovered' 'VM CBT state is Enabled and the VM/VMI is Running after recovery' \
```

**Hunk 5 — check-set registry plumbing** (insert directly after the existing `--list-checks` exit block, i.e. after `:184`, and before `[[ -n "$scenario_dir" ]]`)

```diff
@@
 if [[ "$list_checks" == true ]]; then
   list_check_table
   exit 0
 fi
+
+# The registry is repository text, not run evidence: a run cannot widen its own
+# evaluation from the pack it is graded on.
+CHECK_SET_FILE_DEFAULT="$SCRIPT_DIR/scenario-check-sets.tsv"
+
+list_check_sets() {
+  local file="${check_set_file:-$CHECK_SET_FILE_DEFAULT}"
+  [[ -r "$file" ]] || usage_err "check-set registry is not readable: $file"
+  awk -F'\t' '!/^#/ && NF >= 2 { printf "%s\t%s\n", $1, $2 }' "$file"
+}
+
+if [[ "$list_check_sets" == true ]]; then
+  list_check_sets
+  exit 0
+fi
```

**Hunk 6 — resolve the set** (insert immediately before `RUN_DIR="$scenario_dir/runs/$run_id"`, so it runs after the `scenario_dir`/jq validation)

```diff
@@
+has_check_set() { # <key>
+  awk -F'\t' -v k="$1" '!/^#/ && NF >= 2 && $1 == k { found = 1 } END { exit !found }' "$CHECK_SET_FILE"
+}
+
+CHECK_SET_FILE="${check_set_file:-$CHECK_SET_FILE_DEFAULT}"
+CHECK_SET_KEY="${check_set:-$(basename "${scenario_dir%/}")}"
+if ! has_check_set "$CHECK_SET_KEY"; then
+  [[ -z "$check_set" ]] || usage_err "--check-set $check_set is not defined in $CHECK_SET_FILE"
+  CHECK_SET_KEY='default'
+  has_check_set "$CHECK_SET_KEY" || usage_err "check-set registry $CHECK_SET_FILE has no 'default' row"
+fi
+mapfile -t CHECK_SET_IDS < <(
+  awk -F'\t' -v k="$CHECK_SET_KEY" '!/^#/ && NF >= 2 && $1 == k {
+    n = split($2, ids, ",")
+    for (i = 1; i <= n; i++) { gsub(/^[ \t]+|[ \t]+$/, "", ids[i]); if (ids[i] != "") print ids[i] }
+  }' "$CHECK_SET_FILE")
+((${#CHECK_SET_IDS[@]} > 0)) || usage_err "check set '$CHECK_SET_KEY' resolved to no checks"
+printf 'check set %s: %d checks from %s\n' "$CHECK_SET_KEY" "${#CHECK_SET_IDS[@]}" "$CHECK_SET_FILE" >&2
+
 RUN_DIR="$scenario_dir/runs/$run_id"
```

**Hunk 7 — dispatch through the set (`:956-963`)**

```diff
@@
 printf '%-22s %-14s %s\n' 'check' 'status' 'detail' >&2
-check_run_id_consistency
-check_injection_signal
-check_launcher_replacement
-check_backup_interrupted
-check_tracker_not_advanced
-check_cbt_recovered
-check_same_vm_recovery
-check_clean_lifecycle
+
+# Implementation table. An id named by the resolved set but absent here is
+# UNKNOWN (fail-closed): a typo or an unimplemented id caps the verdict at
+# INCONCLUSIVE instead of silently disappearing from the evaluation.
+run_check() {
+  case "$1" in
+    run-id-consistency) check_run_id_consistency ;;
+    injection-signal) check_injection_signal ;;
+    launcher-replacement) check_launcher_replacement ;;
+    backup-interrupted) check_backup_interrupted ;;
+    tracker-not-advanced) check_tracker_not_advanced ;;
+    injection-pre-state) check_injection_pre_state ;;
+    injection-effect) check_injection_effect ;;
+    affected-pass-outcome) check_affected_pass_outcome ;;
+    cbt-recovered) check_cbt_recovered ;;
+    same-vm-recovery) check_same_vm_recovery ;;
+    clean-lifecycle) check_clean_lifecycle ;;
+    *)
+      add_check "$1" UNKNOWN 'the check id has an implementation in this evaluator' \
+        "check id '$1' is named by check set '$CHECK_SET_KEY' ($CHECK_SET_FILE) but scenario-verdict.sh does not implement it" \
+        "$CHECK_SET_FILE"
+      ;;
+  esac
+}
+
+for check_id in "${CHECK_SET_IDS[@]}"; do
+  run_check "$check_id"
+done
```

**Hunk 8 — the three new checks** (insert after `check_backup_interrupted()`'s closing brace, i.e. before the `# 5. tracker-not-advanced` banner at `:654`)

```diff
@@
+# --------------------------------------------------------------------------
+# 4b. injection-pre-state — the target-state precondition, witnessed by someone
+#     other than the injector.
+# --------------------------------------------------------------------------
+# A missing witness is UNKNOWN, never PASS and never FAIL: with no observation
+# there is nothing to contradict, and the evaluator must not reach a negative
+# conclusion by absence alone. Which witness counts is a contract question
+# (contracts/check-injection.md item 4), not an evaluator question.
+check_injection_pre_state() {
+  local expected='a non-injector witness shows the named checkpoint bitmap present on the target disk before the removal'
+  local target_file="$TRIGGER_DIR/surgery-target.json"
+  local pre_bitmaps="$OBSERVER_DIR/effect/qmp-bitmaps-pre.json"
+  local pre_nodes="$OBSERVER_DIR/effect/qmp-nodes-pre.json"
+  local history="$OBSERVER_DIR/effect/pre-bitmap-history.jsonl"
+  local evidence=("$ACTION_REQUEST" "$target_file" "$pre_bitmaps" "$pre_nodes" "$history")
+
+  local checkpoint node
+  checkpoint="$(jq -r '.checkpoint // ""' <<<"$(jq_doc "$target_file")")"
+  node="$(jq -r '.qemu_node // ""' <<<"$(jq_doc "$target_file")")"
+  if [[ -z "$checkpoint" ]]; then
+    checkpoint="$(jq -r '.surgery_target.checkpoint // .checkpoint // ""' <<<"$(jq_doc "$ACTION_REQUEST")")"
+  fi
+  if [[ -z "$checkpoint" && -s "$TRIGGER_DIR/bitmaps-before.json" ]]; then
+    checkpoint="$(jq -r '.[0].name // ""' <<<"$(jq_doc "$TRIGGER_DIR/bitmaps-before.json")")"
+  fi
+
+  if [[ -s "$pre_bitmaps" ]] &&
+     jq -e --arg name "$checkpoint" '.[]? | select(.name == $name)' "$pre_bitmaps" >/dev/null 2>&1; then
+    add_check injection-pre-state PASS "$expected" \
+      "observer read names the checkpoint bitmap ${checkpoint} on node ${node:-<unnamed>}" "${evidence[@]}"
+    return 0
+  fi
+
+  if [[ -s "$history" ]]; then
+    local rows present
+    rows="$(wc -l < "$history" | tr -d ' ')"
+    present="$(jq -rs '[.[]? | select(.target_present == true)] | length' "$history" 2>/dev/null || printf 0)"
+    if ((present > 0)); then
+      add_check injection-pre-state PASS "$expected" \
+        "observer pre-capture history has ${present} row(s) with target_present=true (${rows} rows total)" "${evidence[@]}"
+      return 0
+    fi
+    add_check injection-pre-state UNKNOWN "$expected" \
+      "no observer row observed the target bitmap before the removal (${rows} rows: $(jq -rs '[.[]? | .result] | group_by(.) | map("\(length)x\(.[0])") | join(", ")' "$history" 2>/dev/null || printf 'unreadable'))" \
+      "${evidence[@]}"
+    return 0
+  fi
+
+  if [[ -s "$TRIGGER_DIR/bitmaps-before.json" ]]; then
+    add_check injection-pre-state UNKNOWN "$expected" \
+      'the only pre-removal read is injector-authored (trigger/bitmaps-before.json); the injector may not be the sole authority for its own injection' \
+      "${evidence[@]}" "$TRIGGER_DIR/bitmaps-before.json"
+  else
+    add_check injection-pre-state UNKNOWN "$expected" \
+      'no pre-removal bitmap read exists in trigger/ or observer/' "${evidence[@]}"
+  fi
+}
+
+# --------------------------------------------------------------------------
+# 4c. injection-effect — per-disk specificity of the removal.
+# --------------------------------------------------------------------------
+check_injection_effect() {
+  local expected='the target disk lost exactly the named bitmap while a sibling disk of the same guest kept its bitmap'
+  local obs_nodes="$OBSERVER_DIR/effect/qmp-nodes-post.json"
+  local trig_nodes="$TRIGGER_DIR/query-named-block-nodes-after.json"
+  local nodes_json=''
+  if [[ -s "$obs_nodes" ]]; then nodes_json="$obs_nodes"
+  elif [[ -s "$trig_nodes" ]]; then nodes_json="$trig_nodes"
+  else
+    add_check injection-effect UNKNOWN "$expected" \
+      'no post-removal QEMU node inventory exists' "$obs_nodes" "$trig_nodes"
+    return 0
+  fi
+
+  local target_file="$TRIGGER_DIR/surgery-target.json"
+  local checkpoint disk
+  checkpoint="$(jq -r '.checkpoint // .surgery_target.checkpoint // ""' <<<"$(jq_doc "$target_file")")"
+  [[ -n "$checkpoint" ]] ||
+    checkpoint="$(jq -r '.checkpoint // .surgery_target.checkpoint // ""' <<<"$(jq_doc "$ACTION_REQUEST")")"
+  disk="$(jq -r '.disk // .surgery_target.disk // ""' <<<"$(jq_doc "$target_file")")"
+  [[ -n "$disk" ]] ||
+    disk="$(jq -r '.surgery_target.disk // .disk // ""' <<<"$(jq_doc "$ACTION_REQUEST")")"
+
+  # Per-disk specificity: the target disk's `-format` node must have lost the
+  # checkpoint while ANOTHER disk's node still carries it (the same checkpoint
+  # name is registered once per disk). Keys are quoted: `.dirty-bitmaps` parses
+  # as a subtraction, not as a key lookup.
+  local info
+  info="$(jq -c --arg name "$checkpoint" --arg disk "$disk" '
+    ((.return // .) | if type == "array" then . else [] end) as $nodes |
+    ($nodes | map(select((.file // "") | test("/cbt/[^/]+\\.qcow2$")))
+           | map({ node: (."node-name" // ""), file: (.file // ""),
+                   names: ((."dirty-bitmaps" // []) | map(.name)) })) as $disks |
+    ($disks | map(select((.node | test("-format$"))))) as $format_disks |
+    (if ($format_disks | length) > 0 then $format_disks else $disks end) as $candidates |
+    ($candidates | map(select((.file // "") | test("/cbt/" + (if $disk == "" then "[^/]+" else $disk end) + "\\.qcow2$")))) as $target |
+    ($candidates | map(select((.file // "") | test("/cbt/" + (if $disk == "" then "[^/]+" else $disk end) + "\\.qcow2$") | not))) as $siblings |
+    { target_present: ([$target[] | select(.names | index($name))] | length > 0),
+      target_nodes: [$target[].node],
+      sibling_nodes: [$siblings[].node],
+      siblings_with_checkpoint: ([$siblings[] | select(.names | index($name))] | length) }' \
+    <<<"$(jq_doc "$nodes_json")")"
+
+  local target_present siblings_with_checkpoint target_nodes sibling_nodes
+  target_present="$(jq -r '.target_present' <<<"$info")"
+  siblings_with_checkpoint="$(jq -r '.siblings_with_checkpoint' <<<"$info")"
+  target_nodes="$(jq -r '.target_nodes | join(",")' <<<"$info")"
+  sibling_nodes="$(jq -r '.sibling_nodes | join(",")' <<<"$info")"
+
+  if [[ "$target_present" == "true" ]]; then
+    add_check injection-effect FAIL "$expected" \
+      "the named bitmap is still present on the target disk's node(s) [${target_nodes:-<none matched>}] in $nodes_json" "$nodes_json"
+  elif ((siblings_with_checkpoint > 0)); then
+    add_check injection-effect PASS "$expected" \
+      "target node(s) [${target_nodes:-<none matched>}] lost ${checkpoint} while sibling node(s) [${sibling_nodes:-<none>}] kept it (source: $nodes_json)" "$nodes_json"
+  else
+    add_check injection-effect UNKNOWN "$expected" \
+      "the target bitmap is gone, but no sibling node in $nodes_json still carries the checkpoint, so the removal's per-disk specificity is unproven" "$nodes_json"
+  fi
+}
+
+# --------------------------------------------------------------------------
+# 4d. affected-pass-outcome — the affected pass must have a modelled outcome.
+# --------------------------------------------------------------------------
+# Modelled outcomes: terminal Done=True (with its included volumes), terminal
+# done=False (the detected-and-failed path), or a non-terminal object recorded
+# past its wait bound. The status expresses *shape*, not product quality: which
+# of those is good news is the scenario spec's and the checkers' call.
+check_affected_pass_outcome() {
+  local expected='the affected pass has a modelled outcome: a terminal condition with its volumes, or a recorded non-terminal stall past the wait bound'
+  local es="$TRIGGER_DIR/exit-statuses.json"
+  local evidence=("$es" "$TRIGGER_DIR/legB-incremental-backup.yaml" "$TRIGGER_DIR/run-notes.md" "$TRIGGER_DIR/trigger.log")
+  if [[ ! -s "$es" ]]; then
+    add_check affected-pass-outcome UNKNOWN "$expected" \
+      'no trigger/exit-statuses.json: the affected pass recorded no outcome' "${evidence[@]}"
+    return 0
+  fi
+
+  local info terminal done type reason volumes waited bound name
+  info="$(jq -c '{
+      name: (.surgery_incremental.name // ""),
+      terminal: (.surgery_incremental.terminal // null),
+      type: (.surgery_incremental.type // ""),
+      done: (.surgery_incremental.done // ""),
+      reason: (.surgery_incremental.reason // ""),
+      volumes: (.surgery_incremental.included_volumes // ""),
+      waited: (.surgery_incremental.waited_seconds // null),
+      bound: (.pass_wait_bound_seconds // null) }' <<<"$(jq_doc "$es")")"
+  terminal="$(jq -r '.terminal' <<<"$info")"
+  type="$(jq -r '.type' <<<"$info")"
+  done="$(jq -r '.done' <<<"$info")"
+  reason="$(jq -r '.reason' <<<"$info")"
+  volumes="$(jq -r '.volumes' <<<"$info")"
+  waited="$(jq -r '.waited' <<<"$info")"
+  bound="$(jq -r '.bound' <<<"$info")"
+  name="$(jq -r '.name' <<<"$info")"
+
+  if [[ "$terminal" == "true" && "$done" == "True" ]]; then
+    add_check affected-pass-outcome PASS "$expected" \
+      "terminal ${type:-<no type>} Done=True volumes=\"${volumes:-<none>}\" (${name:-<unnamed>})" "${evidence[@]}"
+  elif [[ "$terminal" == "true" ]]; then
+    add_check affected-pass-outcome PASS "$expected" \
+      "terminal done=${done:-<absent>} type=${type:-<absent>} reason=\"${reason:-<none>}\" (detected-and-failed path, ${name:-<unnamed>})" "${evidence[@]}"
+  elif [[ "$terminal" == "false" && "$waited" =~ ^[0-9]+$ && "$bound" =~ ^[0-9]+$ && "$waited" -ge "$bound" ]]; then
+    add_check affected-pass-outcome PASS "$expected" \
+      "stalled non-terminal after ${waited}s of a ${bound}s bound: modelled outcome = non-terminal stall (no type, no Done, no includedVolumes)" "${evidence[@]}"
+  else
+    add_check affected-pass-outcome UNKNOWN "$expected" \
+      "the affected pass's outcome is not modelled: terminal=${terminal} waited=${waited} bound=${bound} (the trigger must record surgery_incremental.terminal/_waited_seconds and pass_wait_bound_seconds)" "${evidence[@]}"
+  fi
+}
+
```

### 1.5 Diff M1-c — `chaos-trigger.sh` must record the outcome M1-b reads (`:494-535`)

The evaluator cannot read what the trigger never writes (that is exactly this run's `type=? Done=? includedVolumes=?`). Two small changes:

```diff
@@ stage 5, at the `make e2e TYPE=incremental` call (`:496-502`)
+# The affected pass must end in a recorded outcome. The workflow's own bound is
+# the only bound there is (`scripts/common.sh:1037,1046` --timeout=20m), so the
+# trigger measures the stage against it and records whether the object ever
+# reached a terminal condition.
+PASS_WAIT_BOUND_SECONDS=1200
+incr_started_s="$(date -u +%s)"
 if make e2e TYPE=incremental VM="$VM_NAME" NAMESPACE="$NAMESPACE" \
   VM_OS="$VM_OS" MANIFEST_VARIANT="$MANIFEST_VARIANT" \
   KUBECONFIG_PATH="$KUBECONFIG_PATH"; then
   incr_status=0
 else
   incr_status=$?
 fi
+incr_waited_s=$(( $(date -u +%s) - incr_started_s ))
```

```diff
@@ the `jq -nc` that writes exit-statuses.json (`:519-532`)
   jq -nc \
     --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg run_id "$RUN_ID" \
     --arg checkpoint "$CHECKPOINT_NAME" --arg control_volumes "$control_volumes" \
+    --argjson control_status "$control_full_status" \
     --arg incr_name "$INCR_NAME" --arg incr_type "${incr_type:-}" --arg incr_done "${incr_done:-}" \
     --arg incr_reason "${incr_reason:-}" --arg incr_message "${incr_message:-}" \
     --arg incr_volumes "$incr_volumes" --arg tracker_volumes "${TRACKER_VOLUMES:-}" \
-    --argjson status "$incr_status" \
+    --argjson status "$incr_status" --argjson waited "$incr_waited_s" \
+    --argjson bound "$PASS_WAIT_BOUND_SECONDS" \
     '{utc_result_recorded: $utc, run_id: $run_id, checkpoint: $checkpoint,
       control_full_included_volumes: $control_volumes,
-      control_full_status: 0,
+      control_full_status: $control_status,
+      pass_wait_bound_seconds: $bound,
       surgery_incremental: {name: $incr_name, status: $status, type: $incr_type, done: $incr_done,
-        reason: $incr_reason, message: $incr_message, included_volumes: $incr_volumes},
+        reason: $incr_reason, message: $incr_message, included_volumes: $incr_volumes,
+        terminal: (($incr_done == "True") or ($incr_done == "False")), waited_seconds: $waited},
       tracker_volumes_after_redefinition: $tracker_volumes}' \
   >"$TRIGGER_DIR/exit-statuses.json"
 if [[ "$incr_done" == True && "$incr_type" == Incremental ]]; then
   if [[ "$incr_volumes" != *datadisk* ]]; then
     printf 'DEFECT CONFIRMED: incremental Done=True WITHOUT datadisk (silent disk drop) — includedVolumes=%s\n' \
       "$incr_volumes" >&2
   elif [[ "$incr_volumes" == *datadisk* && "$incr_volumes" == *rootdisk* ]]; then
     printf 'RESILIENT: incremental still includes both disks (%s).\n' "$incr_volumes" >&2
   fi
+elif [[ "$incr_done" != "True" && "$incr_done" != "False" ]]; then
+  if (( incr_waited_s >= PASS_WAIT_BOUND_SECONDS )); then
+    printf 'STALLED NON-TERMINAL: %s had no terminal condition after %ss (bound %ss); type=%s done=%s includedVolumes=%s — recorded as an outcome, not a timeout.\n' \
+      "$INCR_NAME" "$incr_waited_s" "$PASS_WAIT_BOUND_SECONDS" "${incr_type:-?}" "${incr_done:-?}" "${incr_volumes:-?}" >&2
+  else
+    printf 'NON-TERMINAL (inside the wait bound): %s type=%s done=%s\n' \
+      "$INCR_NAME" "${incr_type:-?}" "${incr_done:-?}" >&2
+  fi
 fi
```

(The `control_status` half of this hunk is M4-b — the same `jq -nc` carries both, so apply them together.)

### 1.6 Diff M1-d — offline tests (`tests/test-scenario-verdict.sh`)

The existing test already builds a throwaway root and symlinks the real script (`tests/test-scenario-verdict.sh:23-26`), asserts the 8-id default list and all-PASS (`:178-184`), and asserts the degraded `cbt-recovered` case (`:220-222`). Add:

1. `--list-check-sets` → prints exactly the two registry rows; read-only, exit 0.
2. `--list-checks` → contains `injection-pre-state`, `injection-effect`, `affected-pass-outcome`; still contains all 8 legacy ids.
3. **CBT-EXP-06 regression fixture** (copy the frozen r02 artifacts into the fixture root: `trigger/{action-request.json,bitmaps-before.json,bitmaps-after.json,query-named-block-nodes-after.json,exit-statuses.json,legB-incremental-backup.yaml}`, `observer/effect/{qmp-nodes-post.json,qmp-nodes-post-late.json,pre-bitmap-history.jsonl}`, and the lifecycle `runs/<id>/{run.json,report.json,summary.json}`) → assert, as measured in §1.7: `(.checks | length) == 7`; `([.checks[].id] | index("injection-signal")) == null`; `injection-effect == "PASS"`; `injection-pre-state == "UNKNOWN"`; `affected-pass-outcome == "UNKNOWN"`; `verdict == "INCONCLUSIVE"`; **`verdict != "FAIL"`**. This is the twice-rule regression: the frozen r02 pack must stop producing `FAIL`.
4. Same fixture with `--check-set default` → assert `verdict == "FAIL"` and `failing_check == "injection-signal"`, i.e. the legacy family is untouched.
5. Fail-closed: a temp registry declaring one unknown id → that id is `UNKNOWN` with a detail naming the registry path, and the verdict is `INCONCLUSIVE` (never `PASS`).
6. `--check-set bogus` → exit 2; a registry with no `default` row and no matching scenario row → exit 2.
7. `affected-pass-outcome` matrix (4 fixtures on `exit-statuses.json` alone): terminal Done=True both disks → PASS; terminal done=False + failure reason → PASS; `terminal=false`, `waited=1235`, `bound=1200` → PASS; `terminal=false` with no `pass_wait_bound_seconds` → UNKNOWN.
8. `injection-effect` contrast: post inventory where the target node still holds the bitmap → FAIL; where no sibling bitmap exists → UNKNOWN.
9. `run-id-consistency`, `tracker-not-advanced`, `same-vm-recovery`, `clean-lifecycle` are unchanged: assert no new file reads are introduced for the default set (the existing fixture must still pass verbatim).

### 1.7 Effect if M1 were applied to this run's frozen pack

**Measured, not predicted.** I applied hunks M1-a + M1-b to a scratch copy of `cbt-chaos/scenario-verdict.sh` (`bash -n` clean), pointed it at the frozen run root through symlinks, and ran it. Verbatim stdout of the check table (this is now an observed result against the real pack, not an inference):

```
check set CBT-EXP-06: 7 checks from .../scenario-check-sets.tsv
run-id-consistency     PASS           run.json run_id=20261016-exp06-r02 vm_name=vm-20261016-exp06-r02; ...
injection-pre-state    UNKNOWN        no observer row observed the target bitmap before the removal (48 rows: 3xexec_failed, 39xnot_ready, 6xok)
injection-effect       PASS           target node(s) [libvirt-2-format] lost vm-backup-20261016-exp06-r02-2026-10-16_04-27-24 while sibling node(s) [libvirt-4-format] kept it (source: observer/effect/qmp-nodes-post.json)
affected-pass-outcome  UNKNOWN        the affected pass's outcome is not modelled: terminal=null waited=null bound=null (the trigger must record surgery_incremental.terminal/_waited_seconds and pass_wait_bound_seconds)
cbt-recovered          UNKNOWN        cbt=true vmi_running=null (sources: report.json verification.vm_cbt_is_enabled)
same-vm-recovery       UNKNOWN        no same-VM recovery attempt recorded in the lifecycle run.json
clean-lifecycle        NOT_APPLICABLE no --clean-lifecycle-run supplied
VERDICT                INCONCLUSIVE   missing mandatory evidence: injection-pre-state affected-pass-outcome cbt-recovered same-vm-recovery
```

with the legacy set on the same pack (`--check-set default`) still returning `FAIL` / `injection-signal`, i.e. the change is confined to scenarios that opt in. Notes on the three UNKNOWNs:

- `injection-pre-state` UNKNOWN reproduces the run's own C2 BLOCKED mechanically, with the row census that caused it — exactly what the two blind checkers concluded, from a deterministic script.
- `affected-pass-outcome` UNKNOWN is the frozen pack's honest state (the trigger recorded nothing); after M1-c it becomes PASS naming the stall.
- `cbt-recovered` UNKNOWN here is the M4-f gap (`vmi_running=null`): r02's verify fragment carries `vm_cbt_is_enabled` but no running check, and the evaluator has no fallback. M4-f's observer-corroboration hunk fixes exactly this (the pack holds `observer/effect/post-vmi-now.json` `.status.phase=Running` and `observer/effect/post-vmi-cbt.json` `.changedBlockTracking.state=Enabled`); the test should pin that.
- `same-vm-recovery` UNKNOWN and `clean-lifecycle` NOT_APPLICABLE are structural for this scenario and intentionally kept in the set: they encode, mechanically, that the workflow offers no pass-adding path (H-04) and that no clean comparison lifecycle exists. A scenario that cannot reach `PASS` until the workflow can add a pass is the correct signal, not a reason to drop the constraints.

Net effect: **`INCONCLUSIVE` instead of `FAIL`** — the machine-readable statement "the injected condition was exercised per-disk; its pre-state was never independently witnessed; the affected object's outcome was not recorded" — aligned with the human `BLOCKED` instead of contradicting it.

---

## 2. MANDATORY — M2 `evidence-index-hash-drift`

### 2.1 What happened (observed)

`checkers/evidence-sufficiency.json#limitations/5`:

> "evidence-index.json verification: 151/151 listed files exist; 150 hash-match; `ledger.jsonl` is listed as 23171 bytes / sha256 `a59a1686ddff...` but is 27415 bytes / sha256 `e9813f30ba21...` (the index predates later ledger appends)."

Also `#false_positive_risks/10`; raised as a finding, not a reject, in this run. Same class as a **reject reason** in `cbt-chaos/scenarios_v2/CBT-F-04/reject-reasons.tsv` (`20261015-cbtf04-r03 … evidence-index-hash-drift … ledger appended after index generation, indexed sha256 stale`). Root cause: the Lead appended ledger lines (checker verdicts, verdict reconciliation, report revisions, close) *after* generating the pre-checker index at 05:00:36Z, while the checkers graded at 05:07-05:09Z — nothing gated the ordering, because `pack-validate.sh` is only "run before spawning checkers" (`pack-validate.sh:3-5`) and a *later* append is invisible to a gate that already exited 0.

Second facet, observed today: the workstation mirror of the closed run is internally inconsistent. `bash cbt-chaos/pack-validate.sh cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02` on this checkout → **5 failures** (`state.json phase 'verdict' != last ledger phase 'checked'`, `hash mismatch: ledger.jsonl`, `index is stale … ledger.jsonl`, `hash mismatch: state.json`, `index is stale … state.json`), `indexed files verified: 151`; the remote root holds 42 ledger lines / a 157-file index generated 05:56:30Z, the workstation copy 37 lines / the 151-file pre-checker index. The mirror is therefore not evidence — see M4-g.

### 2.2 Design of the fix

Make the ordering **checkable at the two moments that matter** instead of merely instructed: the Lead *freezes* the pack after the index and after the last ledger append for the phase; every checker *verifies* that freeze as its first and last action.

Honest scope of what each part adds:
- Today's `pack-validate.sh` rules 3-4 (indexed sha256 + index-vs-file mtime) already detect this drift **if re-run** — and it was exactly the re-run that never happened: it was run once, before the spawn, and the offending append came later. So the load-bearing change is the *checker-side re-validation* (first **and** last action), not a new rule.
- The freeze record's own value: it pins the hashes the grade is based on (`index_sha256`, `ledger_sha256`, sizes, `generated_utc`), so a checker can state what it graded, and a mismatch is attributable ("the index predates the last ledger append") instead of being an unattributed hash difference.
- A freeze mismatch is a hard failure on the checker side (never a finding): the pack moved under the grade.

### 2.3 Diff M2-a — `cbt-chaos/pack-validate.sh` gains `--freeze` / `--verify-freeze`

```diff
@@ usage / header
-Usage: pack-validate.sh <run-root>
+Usage: pack-validate.sh [--freeze|--verify-freeze] <run-root>
@@
-Exit codes: 0 = pack valid; 1 = validation failed (see stderr);
-            2 = usage error.
+Exit codes: 0 = pack valid (and, for --verify-freeze, the freeze matched);
+            1 = validation failed (see stderr); 2 = usage error.
+
+Modes:
+  (default)        validate only.
+  --freeze         validate, then write <run-root>/checkers/pack-freeze.json
+                   recording evidence-index.json's and ledger.jsonl's sha256 +
+                   sizes and the index's generated_utc. The Lead runs this
+                   immediately before spawning checkers, after the phase's last
+                   ledger append.
+  --verify-freeze  validate, then fail if either file no longer matches the
+                   freeze. Each checker runs this as its FIRST action and again
+                   immediately before writing its verdict; a failure on the
+                   second run means the pack moved while it was grading.
@@
-if [[ $# -ne 1 ]]; then
-  printf 'usage: %s <run-root>\n' "$0" >&2
+mode='validate'
+case "${1:-}" in
+  --freeze|--verify-freeze) mode="${1#--}"; shift ;;
+esac
+if [[ $# -ne 1 ]]; then
+  printf 'usage: %s [--freeze|--verify-freeze] <run-root>\n' "$0" >&2
   exit 2
 fi
 
 ROOT="$1"
 failures=0
 fail() { printf 'pack-validate: FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
+
+# hash_file PATH -- sha256 of PATH via whichever tool exists.
+hash_file() {
+  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
+  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
+  fi
+}
```

```diff
@@ tail
+# --- freeze: the mechanical gate for index/ledger ordering -------------------
+FREEZE="$ROOT/checkers/pack-freeze.json"
+
+write_freeze() {
+  mkdir -p "$ROOT/checkers"
+  local tmp="$FREEZE.tmp.$$"
+  jq -cn \
+    --arg utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
+    --arg index_sha "$(hash_file "$INDEX")" \
+    --argjson index_bytes "$(wc -c < "$INDEX" | tr -d ' ')" \
+    --arg index_utc "$(jq -r '.generated_utc // ""' "$INDEX")" \
+    --arg ledger_sha "$(hash_file "$LEDGER")" \
+    --argjson ledger_bytes "$(wc -c < "$LEDGER" | tr -d ' ')" \
+    --argjson indexed "$(jq -r '.files | length' "$INDEX")" \
+    '{schema_version: 1, frozen_utc: $utc, index_sha256: $index_sha,
+      index_bytes: $index_bytes, index_generated_utc: $index_utc,
+      ledger_sha256: $ledger_sha, ledger_bytes: $ledger_bytes,
+      indexed_files: $indexed}' > "$tmp" && mv -f "$tmp" "$FREEZE"
+}
+
+verify_freeze() {
+  if [[ ! -s "$FREEZE" ]]; then
+    fail "no pack freeze at $FREEZE; the Lead must run 'pack-validate.sh --freeze <run-root>' after the phase's last ledger append and before spawning checkers"
+    return 0
+  fi
+  local want_index want_ledger now_index now_ledger
+  want_index="$(jq -r '.index_sha256' "$FREEZE")"
+  want_ledger="$(jq -r '.ledger_sha256' "$FREEZE")"
+  now_index="$(hash_file "$INDEX")"
+  now_ledger="$(hash_file "$LEDGER")"
+  [[ "$now_index" == "$want_index" ]] ||
+    fail "evidence-index.json changed since the freeze (frozen $want_index, now $now_index)"
+  [[ "$now_ledger" == "$want_ledger" ]] ||
+    fail "ledger.jsonl changed since the freeze (frozen $want_ledger, now $now_ledger): the index was generated before the ledger's last append for this phase"
+}
+
+# In --verify-freeze mode the freeze is checked FIRST, so a pack that moved under
+# a grade is always reported, even when the ordinary rules also fail.
+if [[ "$mode" == "verify-freeze" ]]; then
+  verify_freeze
+fi
+
 if (( failures > 0 )); then
   printf 'pack-validate: %s failure(s). Fix and re-run before spawning checkers.\n' "$failures" >&2
   exit 1
 fi
-printf 'pack-validate: OK\n'
+case "$mode" in
+  freeze)
+    write_freeze
+    printf 'pack-validate: OK (freeze written: %s)\n' "$FREEZE"
+    ;;
+  verify-freeze)
+    printf 'pack-validate: OK (freeze verified; index %s, ledger %s bytes)\n' \
+      "$(jq -r '.index_sha256' "$FREEZE" | cut -c1-12)" "$(jq -r '.ledger_bytes' "$FREEZE")"
+    ;;
+  *)
+    printf 'pack-validate: OK\n'
+    ;;
+esac
```

### 2.4 Diff M2-b — keep the freeze record out of the index (`cbt-chaos/evidence-index.sh`)

The freeze is written *after* the index, so it must not be indexed (otherwise every freeze makes the index stale):

```diff
@@
 while IFS= read -r -d '' file; do
   rel="${file#"$root"/}"
-  [[ "$rel" == "evidence-index.json" ]] && continue
+  case "$rel" in
+    evidence-index.json|checkers/pack-freeze.json) continue ;;  # index + phase-gate record, not evidence
+  esac
   if [[ ! -s "$file" ]]; then
@@
-done < <(find "$root" -type f -not -path '*/.git/*' -not -name 'evidence-index.json*' -print0 | LC_ALL=C sort -z)
+done < <(find "$root" -type f -not -path '*/.git/*' -not -name 'evidence-index.json*' \
+              -not -path "$root/checkers/pack-freeze.json" -print0 | LC_ALL=C sort -z)
```

```diff
@@ header doc of evidence-index.sh
-# The index is the manifest checkers grade against: every evidence file under the
-# run root with its sha256 and size. It must be the LAST write of the run (see
-# cbt-chaos/pack-validate.sh rules 3-4), so run this only after every agent has
-# finished writing, and append all ledger lines before it.
+# The index is the manifest checkers grade against: every evidence file under the
+# run root with its sha256 and size. It must be the LAST evidence write of the
+# PHASE (see cbt-chaos/pack-validate.sh rules 3-4 and --freeze), so run this only
+# after every agent has finished writing and after the phase's last ledger
+# append. checkers/pack-freeze.json is a gate record, not evidence, and is
+# deliberately excluded.
```

### 2.5 Diff M2-c — checklist change, `.agents/skills/cbt-chaos-team/SKILL.md`

Replace rule 2a (`SKILL.md:253-260`) so the ordering is a command sequence, not an admonition:

```diff
@@
-2a. **Index ordering (mechanical, checker-enforced).** The evidence index is
-   valid only if it is the LAST write: append every ledger line (including
-   `run_closed` and any post-close approval records) FIRST, then regenerate
-   `evidence-index.json`, then write nothing further to any indexed file.
-   Run `cbt-chaos/pack-validate.sh <run-root>` before spawning checkers —
-   it checks ledger JSON validity, state/ledger phase agreement, indexed
-   sha256s, and index-vs-file mtimes, so ordering violations surface in
-   seconds instead of costing checker revision loops (two rejects in run
-   20261015-cbtf04-r03 came solely from post-index ledger appends).
+2a. **Index ordering (mechanical, checker-enforced).** The evidence index is
+   valid only if it is the LAST evidence write OF THE PHASE: append every ledger
+   line for that phase FIRST, then regenerate `evidence-index.json`, then freeze
+   it, then write nothing further to any indexed file until every checker of
+   that phase has returned. Exactly this sequence, immediately before the
+   checker spawn (`<run-root>` = the run directory):
+   `cbt-chaos/evidence-index.sh <run-root> && cbt-chaos/pack-validate.sh --freeze <run-root>`.
+   `--freeze` validates (ledger JSON validity, state/ledger phase agreement,
+   indexed sha256s, index-vs-file mtimes) and records the index/ledger sha256 in
+   `checkers/pack-freeze.json`, so a ledger append after the index becomes
+   detectable instead of merely discouraged.
+   Each checker runs `cbt-chaos/pack-validate.sh --verify-freeze <run-root>` as
+   its FIRST action and again immediately before writing its verdict, and
+   records both exit codes plus `pack-freeze.json#index_sha256` in its output.
+   A closing failure means the pack moved under the grade: re-freeze, re-spawn
+   that checker, and record the re-run as a harness finding.
+   Rationale: post-index ledger appends cost a reject in 20261015-cbtf04-r03
+   and reappeared as a measured 23171-vs-27415-byte index drift in
+   20261016-exp06-r02, where the run carried no gate that could have caught it.
```

Append to step 6 (`SKILL.md:305-313`, the checker-spawn step):

```diff
@@
 6. Spawn the three Checkers in parallel (blind contracts). On all verdicts,
+   Before spawning: `cbt-chaos/evidence-index.sh <run-root>` then
+   `cbt-chaos/pack-validate.sh --freeze <run-root>`; no ledger append until all
+   three have returned. A checker whose closing `--verify-freeze` fails has
+   graded a moved pack — re-freeze and re-spawn it (harness finding, not a
+   product finding).
```

### 2.6 Diff M2-d — the checker contract template

Insert into each of `cbt-chaos/contracts/check-injection.md`, `check-evidence.md`, `check-report.md` (one wording, three files), in `## Rules`:

```diff
@@
 ## Rules
+- **Pack gate (do this first and last).** Run
+  `cbt-chaos/pack-validate.sh --verify-freeze <run-root>` as your first action:
+  if it exits non-zero, record verdict `BLOCKED` with reason
+  `pack-freeze-mismatch` and stop — you cannot grade a pack that is not the one
+  the Lead froze. Immediately before writing your output, run it again and
+  record both exit codes and `checkers/pack-freeze.json#index_sha256` in your
+  JSON. A failure on the second run is `pack-mutated-during-grading`: report it
+  as a reject reason, never as a pass.
```

### 2.7 Measured behaviour of the M2 gate (applied to a scratch copy, not the repo)

I applied M2-a to a scratch copy of `pack-validate.sh` (`bash -n` clean) and ran it against (a) a read-only pull of the **remote** run root and (b) the inconsistent workstation copy:

| step | command | result (observed) |
|---|---|---|
| validate the remote pack | `pack-validate.sh <copy>` | `ledger lines checked: 42` · `indexed files verified: 157` · `pack-validate: OK` — an independent confirmation that the **remote** pack is internally consistent |
| freeze it | `pack-validate.sh --freeze <copy>` | exit 0 · `OK (freeze written: …/checkers/pack-freeze.json)` |
| verify, clean | `pack-validate.sh --verify-freeze <copy>` | exit 0 · `OK (freeze verified; index 282cb4e18e31, ledger 38628 bytes)` |
| append one ledger line, then verify | `… --verify-freeze <copy>` | exit **1** · `FAIL: ledger.jsonl changed since the freeze (frozen c0561ce8…, now 67c686c8…): the index was generated before the ledger's last append for this phase` — the r02 class, named |
| freeze a broken pack | `pack-validate.sh --freeze <workstation copy>` | exit **1**, no freeze written — the gate never freezes an invalid pack |

After M2 the equivalent per-phase check is `--verify-freeze` exit 0 both before and after each checker; on the workstation mirror a plain `pack-validate.sh <pulled run-root>` must also exit 0 (it currently exits 1 — see M4-g).

---

## 3. `injection-pre-state-not-independently-witnessed` (1 occurrence — in scope, not mandatory)

### 3.1 What happened (observed)

`checkers/injection-validity.json` + `reject-reasons.tsv` row 1: contract item 1 (`contracts/check-injection.md`: "Confirm from the observer's own QMP queries (`observer/effect/qmp-bitmaps-pre.json`, `qmp-bitmaps-post.json`)") was unsatisfiable in this run: `observer/effect/qmp-bitmaps-pre.json` does not exist and 0 of 48 rows of `observer/effect/pre-bitmap-history.jsonl` report `target_present=true`. Three independent causes, all in the artifact:

1. **Cadence vs window.** `observer/effect/capture-pre.sh:79` `sleep 10` against a removal at `04:28:21Z`; the loop's first `ok` read is `04:28:54Z` (`pre-bitmap-history.jsonl`), i.e. post-removal.
2. **Gating on the wrong source.** `capture-pre.sh:23` reads the checkpoint from the tracker's `status.latestCheckpoint.name`, which only appeared at `04:28:19Z`, while libvirt created the checkpoint at `04:27:24Z` (`observer/PRESERVED.json#bitmap_present_before_removal.gap_explanation`: "my loop was 'not_ready' with an empty checkpoint name for every sample up to 04:28:13Z, even though libvirt created the checkpoint at 04:27:24Z"). ~55 s of usable lead time was thrown away.
3. **Read path dies in the window.** `capture-pre.sh:28` execs into the launcher `compute` container (`kubectl exec … -- virsh qemu-monitor-command`), and the three samples inside the window are `exec_failed` (04:28:23/33/44Z) because the VMI restart replaces that pod (`chaos-trigger.sh:366` uses the same path for the removal — it survives only because it precedes the restart).

Compounding contract defect (observed): the run's observer contract tells the worker to record these artifacts **at the ARMED handoff** (`contracts/observer.md`: "ARMED — … Also independently verify, before the action, that the datadisk is present in the domain and that the bitmap named by the tracker's `status.latestCheckpoint.name` exists … Record … into `observer/effect/qmp-nodes-pre.json`, and the target node's `dirty-bitmaps` array into `observer/effect/qmp-bitmaps-pre.json`") — but at ARMED time the VM does not exist and the checkpoint is not yet created, so the mandate is unsatisfiable exactly when it is written. That is why the worker substituted a sampling loop. The generic template (`cbt-chaos/contracts/observer.md`) mandates only the checkpoint-tree capture (`watches/checkpoint-tree-pre.txt`), so the unbuildable requirement was hand-authored per run.

### 3.2 Design of the fix (rendezvous, two stages, no cadence)

- **Stage 1 (ARMED):** resolve and record *selectors* only — the domain name, the disk alias, the rule that selects the target node (`node-name` ending `-format` with `file` ending `/cbt/<disk>.qcow2`), and the fact that the checkpoint name will be taken from the destroyer's handshake. No bitmap claim.
- **Stage 2 (window):** the destroyer publishes `trigger/surgery-target.json` as soon as it has resolved the target, **then blocks** on the observer's witness; the observer reads in a tight loop (0.2 s once the handshake exists) and writes the mandated artifact + `observer/effect/PRE-READY` (containing the capture UTC). The destroyer refuses a witness older than 60 s and aborts (retryable) rather than proceeding unwitnessed.
- The witness is a precondition *of the injection*, so a missing witness must stop the mutation, not merely degrade the grade.

### 3.3 Diff M3-a — template `cbt-chaos/contracts/observer.md` (so every scenario inherits it)

```diff
@@ ## Rules (after the checkpoint-tree bullet, `:72-77`)
 - Per spec S3 and observer-skill rule (H4): once the launcher exists and
   before injection, capture the checkpoint-tree state via the launcher
   compute container (`virsh checkpoint-list --tree`) into
   `watches/checkpoint-tree-pre.txt` (record the command and raw output);
   capture again at PRESERVED into `evidence-terminal/checkpoint-tree-post.txt`.
   Also attempt `qemu-img info` on the backup artifact where the recovered
   launcher provides it; if unavailable, record the absence and reason in
   your finding.
+- **Destroyer-style pre-state witness (two stages, never a cadence).** When the
+  injection destroys state that must be proven present beforehand, periodic
+  sampling is not evidence. Stage 1, at ARMED: resolve and record the
+  *selectors* only — the target's post-action identity (e.g. the `-format` QEMU
+  node whose file ends `/cbt/<disk>.qcow2`) and how it will be resolved; claim
+  nothing about a state that cannot exist yet. Stage 2, in the destroyer's own
+  window: read the target state as soon as the destroyer's handshake file
+  (`trigger/surgery-target.json`, naming checkpoint + node + disk) exists, with
+  no sleep between attempts, and write it to the contract's mandated artifact
+  (`observer/effect/<target>-pre.json`) plus a rendezvous marker
+  `observer/effect/PRE-READY` containing the capture UTC. Keep reading until the
+  destroyer's action is observed on the target, so the post-state is captured
+  by the same loop. Never resolve the target from a projection that lags the
+  real object (the tracker advertised the r02 checkpoint 55 s after libvirt
+  created it) and never back-fill a pre-state from the destroyer's files: a
+  missed pre-read is a witness gap to report, not a value to copy.
+- **Negative claims need a positive search record.** "No `<X>` line/exists/
+  occurred" is admissible only with the command, the paths and the window it was
+  searched over, written to `observer/effect/negatives.json`
+  (`{claim, command, paths[], window_utc, count}`). Run 20261016-exp06-r02:
+  `observer/finding.md` claimed "no virt-handler line" while the captured
+  `observer/effect/virt-handler-window.log` holds 20 of them.
```

### 3.4 Diff M3-b — the destroyer side: `cbt-chaos/contracts/trigger.md` (after step 3)

```diff
@@
 3. The trigger itself gates the Krkn deletion on the launcher `Backup started`
    signal and Lease-holder verification. Capture the moment the script prints
    its action lines (`Active-copy signal:`, `Deleting current controller leader
+4. Handshake with the observer before any destructive step. Publish the resolved
+   target to `trigger/surgery-target.json` (`{utc, checkpoint, disk, qemu_node}`)
+   the moment it is resolved and before the mutation, then block (bounded, then
+   abort) until `observer/effect/PRE-READY` exists and the artifact it names
+   contains the target value; reject a witness older than 60 s and fail closed
+   (exit 7) otherwise. A run whose pre-state only the injector saw is a REJECT
+   for the injection checker (runs 20261016-exp06-r02), so aborting is cheaper
+   than grading it.
```

### 3.5 Diff M3-c — `chaos-trigger.sh`: publish the target and gate the removal

Insert immediately before `printf 'Bitmap %s confirmed on vdb. Removing …'` (`:365`):

```diff
@@ after the fail-closed bitmap assert (`:356-364`)
+# Publish the resolved surgery target so the observer can resolve the same
+# checkpoint/node before the removal, without waiting for the tracker's (later)
+# projection, and block the removal until the observer's own pre-read exists.
+printf '{"utc":"%s","checkpoint":"%s","disk":"datadisk","qemu_node":"%s"}\n' \
+  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CHECKPOINT_NAME" "$VDB_NODE" \
+  >"$TRIGGER_DIR/surgery-target.json"
+
+WITNESS_MAX_AGE_SECONDS=60
+WITNESS_WAIT_SECONDS=120
+
+require_pre_state_witness() {
+  local ready="$EVIDENCE_DIR/observer/effect/PRE-READY"
+  local pre="$EVIDENCE_DIR/observer/effect/qmp-bitmaps-pre.json"
+  local deadline=$(( $(date -u +%s) + WITNESS_WAIT_SECONDS ))
+  local captured captured_s
+  while :; do
+    if [[ -s "$ready" && -s "$pre" ]] &&
+       jq -e --arg name "$CHECKPOINT_NAME" '.[]? | select(.name == $name)' "$pre" >/dev/null 2>&1; then
+      captured="$(tr -d '\n' < "$ready")"
+      captured_s="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$captured" +%s 2>/dev/null || true)"
+      if [[ -n "$captured_s" ]] && (( $(date -u +%s) - captured_s <= WITNESS_MAX_AGE_SECONDS )); then
+        printf 'PRE-STATE WITNESS: observer read %s at %s (age %ss, checkpoint %s).\n' \
+          "$pre" "$captured" "$(( $(date -u +%s) - captured_s ))" "$CHECKPOINT_NAME" >&2
+        return 0
+      fi
+    fi
+    if (( $(date -u +%s) >= deadline )); then
+      printf 'FAIL-CLOSED: no observer pre-state witness for %s within %ss (wanted %s naming %s); refusing to remove the bitmap.\n' \
+        "$CHECKPOINT_NAME" "$WITNESS_WAIT_SECONDS" "$ready" "$pre" >&2
+      return 1
+    fi
+    sleep 1
+  done
+}
+
+require_pre_state_witness || exit 7
 printf 'Bitmap %s confirmed on vdb. Removing (QMP block-dirty-bitmap-remove).\n' "$CHECKPOINT_NAME" >&2
```

Note: the observer's read path (launcher `compute` exec) is still valid here — the witness is taken *before* the restart. Node-side resolution (`oc debug node/… virsh`) would additionally survive a launcher flap; that is a hardening follow-on, not required by this gate.

### 3.6 Diff M3-d — scenario `observer/effect/capture-pre.sh` (the v2 loop)

The run's script is scenario evidence, not repo text; the *template* fix lives in the observer contract (M3-a) and the worker skill should carry the reference loop. Proposed replacement of the loop (diff against the closed run's copy; the same script should be regenerated from the updated contract for the next run):

```diff
@@
-  ck="$(oc get vmbackuptracker "vm-tracker-${RUN}" -n "$NS" -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || true)"
+  ck="$(oc get vmbackuptracker "vm-tracker-${RUN}" -n "$NS" -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || true)"
+  # The destroyer's handshake is authoritative: it carries the checkpoint it
+  # actually resolved, before the removal (the tracker lagged libvirt by ~55 s
+  # in r02: libvirt 04:27:24Z, tracker 04:28:19Z).
+  if [[ -r "$RUNROOT/trigger/surgery-target.json" ]]; then
+    ck="$(jq -r '.checkpoint // ""' "$RUNROOT/trigger/surgery-target.json" 2>/dev/null || true)"
+  fi
@@
   printf '{"utc":"%s","incremental_object":"%s",%s}\n' "$utc" "$incr" "${res#\{}" >> "$HIST"
+  # Rendezvous marker: created the first time the mandated pre-read exists.
+  if [[ -s "$EFF/qmp-bitmaps-pre.json" && ! -e "$EFF/PRE-READY" ]]; then
+    printf '%s\n' "$utc" > "$EFF/PRE-READY"
+  fi
   case "$res" in *'"target_present": true'*) present_seen=1;; esac
@@
   if (( incr_seen >= 2 )); then printf 'stop=incremental_object_present utc=%s\n' "$utc" >> "$STATUS"; break; fi
+  # Stop once the destroyer's action is observed on the target node: the removal
+  # precedes the incremental object and must be captured by this same loop.
+  if [[ $present_seen -eq 1 && "$res" == *'"bitmap_names": []'* ]]; then
+    printf 'stop=target_bitmap_removed utc=%s\n' "$utc" >> "$STATUS"; break
+  fi
@@
-  sleep 10
+  # Cadence is set by the destroyer's handshake, not by a fixed period: idle at
+  # 1 s until the target is published, then read back-to-back until the
+  # destroyer's action is observed (a 10 s period against a ~10 s fail-closed
+  # window is what lost the r02 pre-state).
+  if [[ -s "$RUNROOT/trigger/surgery-target.json" ]]; then sleep 0.2; else sleep 1; fi
```

### 3.7 Definition of done for M3

A re-run's `observer/effect/qmp-bitmaps-pre.json` exists and contains `{name: <checkpoint>, recording: true}`; `observer/effect/PRE-READY` exists and its UTC is within 60 s of `trigger/qmp-remove-result.txt`'s mtime; and the trigger log carries `PRE-STATE WITNESS:` before `Bitmap … confirmed on vdb. Removing`. If no handshake arrives, the trigger exits 7 **before** the removal and the run is INVALID, not BLOCKED-on-evidence.

---

## 4. Small in-scope fixes

### 4.1 M4-a — observer gate double-counts ready files (`chaos-trigger.sh:145-164`; `run-notes.md#anomalies 1`; `checkers/verdict.json#harness_findings[8]`)

Observed: `OBSERVER GATE (pre-surgery): 14 ready file(s)` for 7 watches (`trigger.log:88`, `:93`); `observer/ARMED.json:13` self-documents the overlap.

```diff
@@ require_observer_armed()
   mapfile -t ready_files < <(jq -r '.required_ready_files[]? // empty' "$armed" 2>/dev/null)
   shopt -s nullglob
-  ready_files+=("$EVIDENCE_DIR/observer/watches/"*.ready)
+  local -a glob_ready=("$EVIDENCE_DIR/observer/watches/"*.ready)
   shopt -u nullglob
+  if ((${#glob_ready[@]})); then ready_files+=("${glob_ready[@]}"); fi
+  # The ARMED list and the watches glob overlap by design; count each unique
+  # ready file once (r02 logged "14 ready file(s)" for 7 watches).
+  if ((${#ready_files[@]})); then
+    mapfile -t ready_files < <(printf '%s\n' "${ready_files[@]}" | LC_ALL=C sort -u)
+  fi
```

Related, same gate family (observed): `observer/watches/pids.json` enumerates only 5 of 7 streams (`checkers/evidence-sufficiency.json#criteria/7` flag 1) — the observer contract already requires "selector → PID + ready file" for every watch; add `observer/ARMED` ↔ `pids.json` set equality to the PRESERVED checklist (contract text, no code).

### 4.2 M4-b — `control_full_status` is a literal 0 (`chaos-trigger.sh:528`)

Observed: the shell variable is real (`:257-259`, logged at `:261`, and a non-zero value aborts at `:264-266`), but the JSON field is a literal; `exit-statuses.json` therefore *always* says `0`. The evaluator reads this class of field (`scenario-verdict.sh` `full_backup_record`), so a hardcoded success is a false attestation. Fix: diff already given in **M1-c** (`--argjson control_status "$control_full_status"` + `control_full_status: $control_status`). If a non-zero control status aborts before the file is written (as `run-notes.md#anomalies 2` says), then the field is provably always 0 — which is precisely why it must be derived or removed, never asserted. Alternative minimal fix if the field is to stay: write it from the *log line* by making the log line itself the source (`control_full_status: $control_status` is still the right shape).

### 4.3 M4-c — the follow-up driver reports a phantom CR removal (`same-vm-followup.sh:185-197`; `followup.log:9-10`)

Observed: `F1 apply exit=1` with `The request is invalid: spec.source: VirtualMachineBackup "vm-incremental-20261016-exp06-r02-p01" in progress for source`; the very next line prints `F1 cleanup: test CR removed in 0s (runbook row: delete wedged CR with tracker present -> works).` and `f1-delete-cr.out` contains only a PVC deletion. The claim is false and, worse, is the only "runbook validated" statement the F1 leg produces.

```diff
@@ F1 cleanup (`:185-197`)
-  # Cleanup: this driver's own test objects. Deleting a wedged CR with the tracker present is the runbook step.
-  f1_delete_start="$(date -u +%s)"
-  oc delete vmbackup "$TEST_CR" -n "$NAMESPACE" --ignore-not-found --wait=false > "$FOLLOWUP_DIR/f1-delete-cr.out" 2>&1 || true
-  for _ in $(seq 1 60); do
-    oc get vmbackup "$TEST_CR" -n "$NAMESPACE" >/dev/null 2>&1 || break
-    sleep 2
-  done
-  if oc get vmbackup "$TEST_CR" -n "$NAMESPACE" >/dev/null 2>&1; then
-    printf 'F1 cleanup: test CR still present after 120s (finalizer not released).\n'
-  else
-    printf 'F1 cleanup: test CR removed in %ss (runbook row: delete wedged CR with tracker present -> works).\n' "$(( $(date -u +%s) - f1_delete_start ))"
-  fi
+  # Cleanup: this driver's own test objects. Deleting a CR with the tracker
+  # present is the runbook step -- but only a CR that was actually ADMITTED can
+  # exercise it. r02's apply was rejected at admission and the driver still
+  # claimed "removed in 0s (runbook row ... -> works)".
+  if ! oc get vmbackup "$TEST_CR" -n "$NAMESPACE" >/dev/null 2>&1; then
+    printf 'F1 cleanup: no test CR ever existed (apply exit %s); the runbook row was NOT exercised.\n' \
+      "$f1_apply_status" | tee -a "$FOLLOWUP_DIR/f1-delete-cr.out"
+  else
+    f1_delete_start="$(date -u +%s)"
+    oc delete vmbackup "$TEST_CR" -n "$NAMESPACE" --ignore-not-found --wait=false > "$FOLLOWUP_DIR/f1-delete-cr.out" 2>&1 || true
+    for _ in $(seq 1 60); do
+      oc get vmbackup "$TEST_CR" -n "$NAMESPACE" >/dev/null 2>&1 || break
+      sleep 2
+    done
+    if oc get vmbackup "$TEST_CR" -n "$NAMESPACE" >/dev/null 2>&1; then
+      printf 'F1 cleanup: test CR still present after 120s (finalizer not released).\n'
+    else
+      printf 'F1 cleanup: test CR removed in %ss (runbook row: delete the wedged CR with the tracker present -> works).\n' "$(( $(date -u +%s) - f1_delete_start ))"
+    fi
+  fi
```

### 4.4 M4-d — capacity measured on the wrong filesystem (`preflight/GO-NO-GO.json#capacity`, `contracts/preflight.md:50-62`)

Observed: `free_gib 309.53` on `/dev/sda4 (xfs) mounted /var/hpvolumes`, measured with `df -B1 /cbt-demo-pool-data-dir`; the volumes live in the nested `/var/hpvolumes/csi` = `/cbt-demo-pool-data-dir/csi` on `/dev/sdb` (real free at 04:19Z: 140.0 GiB — `ledger.jsonl` ev 14 — and 40.25 GiB by 05:35Z, `followup/…/f3-result.json#pool_free_before_bytes 43215937536`). The repo already knows the rule (`.agents/skills/cbt-chaos-run/cbt-chaos-run-learnings.md:77`: "Pool guard must stat /var/hpvolumes/csi (the /dev/sdb mount), NOT /var/hpvolumes (parent on /dev/sda4 shows wrong free space — masked a 98%-full pool once)"), and the scenario's own follow-up driver measures it correctly (`same-vm-followup.sh:71-80`, `POOL_DATA_DIR="/cbt-demo-pool-data-dir/csi"`). The *template* has the defect (no command) and the per-run contract inherited it.

```diff
@@ cbt-chaos/contracts/preflight.md, item 7
-7. Capacity headroom (mandatory): destination storage class for the
-   `large-odf` manifest variant must fit the planned full backup (8 × 1 GiB
-   guest files ⇒ multi-GiB PVC plus snapshot overhead) AND the follow-up
-   incremental. Inspect the storage class capacity/PV headroom (e.g. ceph
-   `ceph df` equivalents via `oc` on the ODF cluster if available, or StorageCluster
-   status) and the manifest's PVC request in
-   `manifests/full-backup-large-odf.yaml`
-   (and incremental equivalent) — verify requested sizes and that the backend
-   has headroom. Prior incident: 8 GiB backup PVC exhausted by the Full so the
-   incremental failed `No space left on device`. NO-GO on insufficient headroom.
+7. Capacity headroom (mandatory, fail-closed, on the filesystem that actually
+   backs the destination StorageClass — never its parent mount):
+   - HostPath-PV variant (`cbt-demo-hpp`): the volumes are on the NESTED PV data
+     dir, not the pool's parent hostPath. The pool is `/var/hpvolumes` on
+     `/dev/sda4` but the PVCs are under `/var/hpvolumes/csi` (=
+     `/cbt-demo-pool-data-dir/csi` inside the CSI pod, `/dev/sdb`). Measuring
+     the parent overstated free space by ~170 GiB in run 20261016-exp06-r02
+     (309.53 GiB reported vs 140.0 GiB real, 40.25 GiB by the end). Mandatory
+     command, recorded verbatim in the check's `command` field:
+     `oc exec -n __CTRL_NAMESPACE__ "$(oc get pods -n __CTRL_NAMESPACE__ -o name | grep hostpath-provisioner-csi | head -1 | cut -d/ -f2)" -c hostpath-provisioner -- df -B1 /cbt-demo-pool-data-dir/csi`
+   - ODF/ceph variant: `ceph df` equivalents via `oc` on the ODF cluster, or
+     `StorageCluster` status; name the pool filesystem/mount in `filesystem`.
+   Judge the measured bytes against the manifest PVC requests in
+   `manifests/full-backup-<variant>.yaml` (and the incremental equivalent) AND
+   against what the run will really write: a clone DataVolume materialises the
+   full disk and a backup PVC holds a fully allocated qcow2 (r02 wrote ~2.5× the
+   estimate). Report `filesystem` with the device AND mount, state the margin,
+   and NO-GO below the floor (300 GiB for a campaign-sized run, otherwise
+   ≥ 2× the planned writes).
+   Prior incidents: an 8 GiB backup PVC exhausted by the Full so the incremental
+   failed `No space left on device`; the parent-filesystem measurement above.
```

```diff
@@ .agents/skills/cbt-chaos-preflight-worker/SKILL.md, item 7
-7. **Capacity headroom (mandatory)**: destination PVC must fit the planned
-   full AND its follow-up incremental. Prior starvation: an 8 GiB backup PVC
-   was exhausted by the Full, so the required Incremental failed with
-   `No space left on device`. Inspect requested vs used capacity and expected
-   incremental size; NO-GO on insufficient headroom.
+7. **Capacity headroom (mandatory, fail-closed, correct filesystem)**: measure
+   the filesystem that backs the destination StorageClass, never its parent
+   hostPath. For the HPP pool that is the nested `/cbt-demo-pool-data-dir/csi`
+   (on `/dev/sdb`), NOT `/var/hpvolumes` (on `/dev/sda4`) — the parent
+   overstated free space by ~170 GiB in run 20261016-exp06-r02. Record the exact
+   command in the check's `command` field:
+   `oc exec -n openshift-cnv "$(oc get pods -n openshift-cnv -o name | grep hostpath-provisioner-csi | head -1 | cut -d/ -f2)" -c hostpath-provisioner -- df -B1 /cbt-demo-pool-data-dir/csi`.
+   The destination PVC must fit the planned full AND its follow-up incremental,
+   counting a fully materialising clone DataVolume and a fully allocated backup
+   qcow2 (r02 wrote ~2.5× its estimate). Prior starvation: an 8 GiB backup PVC
+   was exhausted by the Full, so the incremental failed with `No space left on
+   device`. Report device + mount in `filesystem`; NO-GO on insufficient
+   headroom.
```

In-run guard for this scenario (the trigger has none — observed, `grep` over `chaos-trigger.sh` for `capacity|free|df |space` = 0 matches, while siblings guard at 300-400 GiB: `CBT-I-04/chaos-trigger.sh:103-114`, `CBT-I-06:75-80`, `CBT-R-01:60-63`, `CBT-R-02/03:61-64`):

```diff
@@ chaos-trigger.sh, before the control leg (`:244`)
+# Fail-closed capacity floor on the filesystem that backs the PVCs, measured
+# where they live (never the pool's parent hostPath). A run that cannot afford
+# its own full pass cannot answer its own question.
+POOL_DATA_DIR="/cbt-demo-pool-data-dir/csi"
+POOL_FLOOR_GIB="${POOL_FLOOR_GIB:-100}"   # this scenario needs ~100 GiB for a fresh full
+pool_free_gib() {
+  local pod
+  pod="$(oc get pods -n openshift-cnv -o name 2>/dev/null | grep hostpath-provisioner-csi | head -1 | cut -d/ -f2)"
+  [[ -n "$pod" ]] || return 1
+  oc exec -n openshift-cnv "$pod" -c hostpath-provisioner -- df -B1 "$POOL_DATA_DIR" 2>/dev/null |
+    tail -1 | awk -v f="$POOL_FLOOR_GIB" '{printf "%d", $4/1024/1024/1024}'
+}
+free_now_gib="$(pool_free_gib || echo 0)"
+printf 'Pool filesystem %s has %s GiB free (floor %s GiB).\n' "$POOL_DATA_DIR" "$free_now_gib" "$POOL_FLOOR_GIB" >&2
+if (( free_now_gib < POOL_FLOOR_GIB )); then
+  printf 'FAIL-CLOSED: pool free %s GiB < floor %s GiB; refusing to start.\n' "$free_now_gib" "$POOL_FLOOR_GIB" >&2
+  exit 8
+fi
```

### 4.5 M4-e — platform version never captured

Observed: `preflight/GO-NO-GO.json` has no `clusterversion`, no KubeVirt `status.observedVersion`, no image digest; the worker did record the CSV name (`#checks[environment_tools_feature_gate_namespace]`: "csv kubevirt-hyperconverged-operator.v4.22.12 = spec's live CNV 4.22.12") and `virsh --version -> 11.10.0`, but the scenario's hypothesis asserts a *pair* (`scenario-spec.md:6`, `chaos-trigger.sh:3`: "source-verified kubevirt v1.8.4 = live CNV 4.22.12") and nothing in the pack verifies `1.8.4`. The report checker flagged the consequence (`checkers/report-fidelity.json`: "The OpenShift version row is explicitly UNKNOWN rather than filled with a plausible value") — i.e. the gap is honest but avoidable.

```diff
@@ cbt-chaos/contracts/preflight.md, append after item 8
+9. Platform version fingerprint (mandatory). Record into a `platform_versions`
+   object in the GO/NO-GO payload:
+   - OpenShift: `oc get clusterversion version -o jsonpath='{.status.desired.version}'`
+   - KubeVirt: `oc get kubevirt -A -o jsonpath='{.items[0].status.observedVersion}'`
+     and the CSV name (`oc get csv -n __CTRL_NAMESPACE__ -o name`)
+   - the virt-launcher image actually used by the target namespace:
+     `oc get pod <launcher> -n vm-cbt-demo -o jsonpath='{.spec.containers[?(@.name=="compute")].image}'`
+   A scenario whose hypothesis names a product version must have that version
+   confirmed here, and the report must cite this object instead of the spec's
+   claim. Run 20261016-exp06-r02 captured only the CSV name, so the report could
+   not check the "kubevirt v1.8.4" half of its own hypothesis.
```

### 4.6 M4-f — `write-run-summary.sh` emits `PENDING` for an unverified CBT state

Observed code path (`scripts/write-run-summary.sh:161-164`):

```jq
      vm_state: (if check($checks; "vm_cbt_is_enabled") == true then "Enabled"
                 elif check($checks; "vm_cbt_is_enabled") == false then "NotEnabled"
                 else "PENDING" end),
```

Any run whose verify stage never wrote `vm_cbt_is_enabled` reports `cbt.vm_state=PENDING`, which reads as a CBT state word next to `status`. The consumer degrades silently (`scenario-verdict.sh:731-733` reads `.cbt.vm_state`; `check_cbt_recovered` only accepts `"Enabled"` and otherwise falls through to `UNKNOWN`). **Premise correction for this run:** r02's `summary.json` (and `recovery/summary.json.after`) both read `cbt.vm_state="Enabled"` because the verify stage did write its fragment before failing (`runs/20261016-exp06-r02/fragments/verify.json`: `vm_cbt_is_enabled: passed=true`); the `PENDING` variant claimed in `checkers/verdict.json#harness_findings[6]` is **not reproducible against the two on-disk summaries** — the defect is real in code but did not fire here. [INFERENCE from the analysis §H7(a): the claim refers to an intermediate snapshot regenerated in place.]

```diff
@@ scripts/write-run-summary.sh
-      vm_state: (if check($checks; "vm_cbt_is_enabled") == true then "Enabled"
-                 elif check($checks; "vm_cbt_is_enabled") == false then "NotEnabled"
-                 else "PENDING" end),
+      # A CBT state is only known when the verify stage actually read the live
+      # VM. "PENDING" reads as a state and was consumed as one downstream
+      # (cbt-chaos/scenario-verdict.sh#cbt-recovered); say what is true instead.
+      vm_state: (if check($checks; "vm_cbt_is_enabled") == true then "Enabled"
+                 elif check($checks; "vm_cbt_is_enabled") == false then "NotEnabled"
+                 else "UNVERIFIED" end),
+      vm_state_source: (if check($checks; "vm_cbt_is_enabled") == null
+                        then "report.verification.checks[vm_cbt_is_enabled]:absent"
+                        else "report.verification.checks[vm_cbt_is_enabled]" end),
```

Consumer side (so an unverified state is not merely renamed but actually re-sourced from the run's own observer evidence):

```diff
@@ cbt-chaos/scenario-verdict.sh, near the TRIGGER_DIR/OBSERVER_DIR assignment
+OBSERVER_VMI_CBT="$OBSERVER_DIR/effect/post-vmi-cbt.json"
+OBSERVER_VMI_NOW="$OBSERVER_DIR/effect/post-vmi-now.json"
@@ cbt-chaos/scenario-verdict.sh, check_cbt_recovered() -- after the cbt/running
@@ decisions and before `local actual=...`
+  # The observer's own live read of this run's VMI is admissible corroboration
+  # when the lifecycle verify stage never ran (or never wrote the check). Both
+  # artifacts are observer-authored summaries of raw reads taken inside the
+  # window; without them an unverified state stays UNKNOWN.
+  if [[ "$cbt" == "true" || "$running" == "true" ]]; then
+    :
+  else
+    local observer_cbt observer_phase
+    observer_cbt="$(jq -r '.changedBlockTracking.state // .status.changedBlockTracking.state // ""' \
+      <<<"$(jq_doc "$OBSERVER_VMI_CBT")")"
+    observer_phase="$(jq -r '.status.phase // ""' <<<"$(jq_doc "$OBSERVER_VMI_NOW")")"
+    if [[ "$observer_cbt" == "Enabled" ]]; then
+      cbt=true
+      sources+=('observer/effect/post-vmi-cbt.json#changedBlockTracking.state=Enabled')
+    fi
+    if [[ "$observer_phase" == "Running" ]]; then
+      running=true
+      sources+=('observer/effect/post-vmi-now.json#status.phase=Running')
+    fi
+  fi
```

### 4.7 M4-g — run-root sync: one direction, and validate the mirror

Observed today (this checkout vs the remote): `cbt-chaos/scenarios_v2/CBT-EXP-06/runs/20261016-exp06-r02/ledger.jsonl` — workstation 37 lines / 33686 B, remote 42 lines / 38628 B; `evidence-index.json` — workstation the pre-checker 151-file index (`generated_utc 2026-10-16T05:00:36Z`), remote the 157-file `05:56:30Z` one; and `pack-validate.sh` fails 5 ways on the workstation copy. The r02 in-run occurrence of the same class is recorded in `ledger.jsonl` ev 3 (`ledger_recovered`: the Lead's scaffold rsync pushed the empty local ledger over the remote one, six events lost; also `reject-reasons.tsv` row 7). `sync.sh` itself is safe (it excludes `cbt-chaos/scenarios_v2/*/runs/`, `sync.sh:92-93`), so the loss came from a hand-rolled rsync.

```diff
@@ .agents/skills/cbt-chaos-team/SKILL.md, new rule after 2a
+2b. **Run-root sync (mechanical).** A run root is never PUSHED from the
+   workstation: `sync.sh` already excludes `cbt-chaos/scenarios_v2/*/runs/`, so
+   any bare `rsync` of a run root is a defect — the r02 in-run push truncated
+   `ledger.jsonl` and six events had to be re-appended (recorded as
+   `ledger_recovered` in `ledger.jsonl`), and the post-close mirror is stale
+   again (workstation 37 ledger lines + the 151-file pre-checker index vs the
+   remote's 42 lines + the 157-file index). After `closed`: `make pull-reports`
+   (remote → local, one direction only), then run
+   `cbt-chaos/pack-validate.sh <pulled run-root>` and require exit 0. If it
+   fails, the mirror is not evidence — re-pull it; never re-push over it.
```

---

## 5. Deliberately NOT proposed

- **The non-terminal stall itself is a product finding, not a harness defect** (`docs/findings/finding-1-backup-cr-livelock.md`, 3 reproductions: r01 leg B, r02 p01, r02 follow-up p02). The harness proposals above (M1-c, M4-d, the same-VM pass path) only stop the *harness* from hiding it. Two product-side gaps are recorded in the run's own verdict and are for the bug/upstream track, not for this document: the missing terminal `Failed` condition, and the tracker/checkpoint divergence (`observer/effect/checkpoint-dumpxml-post.xml` = `vda` only vs `trigger/tracker-after-restart.yaml` = `rootdisk datadisk`).
- **`observer/finding.md`'s "no virt-handler line" claim** is covered by the negative-claims rule in M3-a rather than by a code change; the artifact is frozen and must not be edited.
- **The 20-minute literal `--timeout=20m`** (`scripts/common.sh:1037,1046`) is left alone: M1-c makes the outcome recorded against that bound, which is what was missing. Making it a variable is a separate, optional change (`BACKUP_DONE_TIMEOUT`, default 20m) — recommended but out of scope here.
- **The staged interface's inability to add a same-VM pass without destroying the failed pass** (`scripts/vm-cbt-extend.sh:122-135` refuses from `verification_failed`; `scripts/vm-cbt-reconcile.sh:51-61` refuses until the operator has deleted the failed CR **and** PVC; the deletion is a documented manual step, `docs/vm-cbt-workflow.md:96-99` — *no code deletes anything*, `scripts/vm-cbt-reconcile.sh:13-14`) is a workflow-design change with a product-evidence trade-off (whether a snapshot-then-delete path is acceptable). It is proposed in the harness-tickets file as `H-04` with options, not as a diff, because the choice is the human's. Note also that the same-VM follow-up driver's own header (`same-vm-followup.sh:5-7`) and `reject-reasons.tsv` row 3 describe reconcile as doing the deletion, which the code contradicts — that wording should be corrected wherever it is reused.
- **Nothing under `runs/20261016-exp06-r02/` was or will be modified**; the harness-changes delta for r02 (`harness-changes/20261016-exp06-r02-trigger.diff`) is the instrumented copy's provenance and stays as-is; every diff above targets the current repo/scenario files that the *next* run will use.

## 6. Approval needed (nothing applied)

| item | decision requested |
|---|---|
| M1 (mandatory, 3rd occurrence) | approve the check-set registry + evaluator hunks + trigger outcome record + tests, or decline and record the decline in the learnings file |
| M2 (mandatory, 2nd occurrence) | approve the freeze gate (`pack-validate.sh --freeze/--verify-freeze`) + SKILL rule 2a/2b + checker contract clause |
| M3 | approve the two-stage pre-state witness (observer template + trigger rendezvous + capture-pre v2) |
| M4-a…M4-g | approve as a batch, or itemise |

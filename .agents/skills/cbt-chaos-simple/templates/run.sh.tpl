#!/usr/bin/env bash
# cbt-chaos-simple — run template (MUTATING; instantiate per run, only after
# the user approves the exact injector command). Pattern: arm injector first
# (the trigger absorbs setup time and fires inside the copy window), then run
# the make pipeline stage, then a bounded join of both exit codes.
set -uo pipefail

# ==== CONFIG (fill per run) ====
SCENARIO_ID="CBT-F-08"
RUN_ID="20261111-<scenario>-r01"
NS="vm-cbt-demo"
CHECKOUT="/root/v2/virt-cbt-lab"
EVDIR="$CHECKOUT/cbt-chaos/scenarios_v2/$SCENARIO_ID/runs/$RUN_ID"
# Stage under attack and its names (full: vm-backup-<id>; incremental pNN:
# vm-incremental-<id>-pNN — keep in sync with precheck.sh.tpl):
STAGE="full"                                   # full | incremental
backup_name_for() { printf 'vm-backup-%s' "$1"; }          # adjust for incremental
pvc_name_for()    { printf 'vm-backup-pvc-%s' "$1"; }      # adjust for incremental
# Pipeline invocation (profile env must match the fresh control run):
E2E_ARGS=(TYPE="$STAGE" NAME="$RUN_ID" VM_OS=rhel9 MANIFEST_VARIANT=large-odf NAMESPACE="$NS"
  GUEST_BASE_FILE_COUNT=1000 GUEST_FILE_SIZE_MIN_MIB=15 GUEST_FILE_SIZE_MAX_MIB=20
  GUEST_INCREMENTAL_FILE_COUNT=1000 GUEST_INCREMENTAL_PASSES=1)
# Windows profile: VM_OS=windows + GUEST_EXEC_POLL_ATTEMPTS=450 (OOBE ~20 min;
# 1000/pass on 60Gi ODF root, 200/pass on 40Gi HPP root with MANIFEST_VARIANT=large).

cd "$CHECKOUT" || exit 2
set -a; . ./.env; set +a
export KUBECONFIG="${KUBECONFIG_PATH:-$KUBECONFIG}"
mkdir -p "$EVDIR"

# minimal collision guard (stage.sh has its own; this avoids a wasted armed run)
if oc get vm "vm-$RUN_ID" -n "$NS" >/dev/null 2>&1; then
  echo "refusing: vm-$RUN_ID already exists"; exit 2
fi

# Compound trigger (live-proven; keep identical to precheck.sh.tpl).
printf -v trigger_cmd "test \"\$(oc get pvc %s -n %s -o jsonpath='{.status.phase}' 2>/dev/null)\" = Bound && pod=\$(oc get pod -n %s -l vm.kubevirt.io/name=vm-%s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && test -n \"\$pod\" && test \"\$(oc get vmbackup %s -n %s -o jsonpath='{.status.conditions[?(@.type==\"Done\")].status}' 2>/dev/null)\" != True && oc logs -n %s \"\$pod\" -c compute --tail=2000 2>/dev/null | grep -F -- %s | grep -F -- 'Backup started'" \
  "$(pvc_name_for "$RUN_ID")" "$NS" "$NS" "$RUN_ID" "$(backup_name_for "$RUN_ID")" "$NS" "$NS" "$(backup_name_for "$RUN_ID")"
printf '%s\n' "$trigger_cmd" > "$EVDIR/trigger-command.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$EVDIR/armed.utc"

# ==== INJECTOR (replace with EXACTLY the user-approved command) ====
# Default: krknctl pvc-scenarios fill (live-proven on ODF rhel9 + windows).
#   --fill-percentage: ODF dedicated dest 95; HPP shared pool 99 (95 is INVALID
#     there — the backup would succeed) + mandatory post-terminal kraken.tmp removal.
#   --triggers-timeout: must exceed setup (Linux 1800; Windows OOBE 3600).
#   --duration 120 is plenty (the backup dies ~10s into the copy).
# oc/kubectl fallbacks (only for faults krknctl cannot express, user-approved):
#   put the approved script/command here; if it embeds its own trigger polling,
#   drop --trigger-command from the pattern and document why in the report.
nohup krknctl run pvc-scenarios \
  --namespace "$NS" \
  --pvc-name "$(pvc_name_for "$RUN_ID")" \
  --fill-percentage 95 \
  --duration 120 \
  --trigger-command "$trigger_cmd" \
  --trigger-expected-rc 0 \
  --triggers-interval 3 \
  --triggers-timeout 3600 \
  --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG_PATH" > "$EVDIR/krknctl.log" 2>&1 &
KRKN_PID=$!
echo "$KRKN_PID" > "$EVDIR/krknctl.pid"
echo "injector armed pid=$KRKN_PID at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

make e2e "${E2E_ARGS[@]}" 2>&1 | tee "$EVDIR/e2e-$STAGE.log"
MAKE_RC=${PIPESTATUS[0]}
echo "$MAKE_RC" > "$EVDIR/make-$STAGE.rc"
echo "MAKE_RC=$MAKE_RC at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Bounded join: a fill-confirmed injector needs ~hold + ~90s post-run after make
# ends; an injector still waiting on its trigger (never fired) is aborted rather
# than hanging. Injector rc=1 AFTER a confirmed fault is expected when the target
# pod is gone at cleanup time (r06 learning) — not a chaos failure.
waited=0
while kill -0 "$KRKN_PID" 2>/dev/null && (( waited < 420 )); do sleep 5; waited=$((waited+5)); done
if kill -0 "$KRKN_PID" 2>/dev/null && grep -q "Filesystem PVC fill" "$EVDIR/krknctl.log"; then
  while kill -0 "$KRKN_PID" 2>/dev/null && (( waited < 900 )); do sleep 5; waited=$((waited+5)); done
fi
if kill -0 "$KRKN_PID" 2>/dev/null; then
  kill -TERM "$KRKN_PID" 2>/dev/null; sleep 5
  kill -KILL "$KRKN_PID" 2>/dev/null
  KRKN_RC=124
else
  wait "$KRKN_PID"; KRKN_RC=$?
fi
echo "$KRKN_RC" > "$EVDIR/injector.rc"
date -u +%Y-%m-%dT%H:%M:%SZ > "$EVDIR/ended.utc"
echo "DONE MAKE_RC=$MAKE_RC INJECTOR_RC=$KRKN_RC (injector rc 1 on cleanup is expected when the backup fails)"
echo "Next: verify per SKILL.md step 6 (pipeline verdict + signature + spot checks), then report."

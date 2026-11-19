#!/usr/bin/env bash
# cbt-chaos-simple — injector skeleton with the post-arm trigger round-trip guard
# (CBT-F-13 r02/r03 learnings). Instantiate per run; run on cloud05.
#
# Guard: krkn collapses backslashes in --trigger-command (r02), so after krknctl
# starts, the command it logged must equal the command we built. The logged line is
#   "  [0] command trigger: '<cmd>' (expected rc=0)<ANSI reset>"
# so strip the prefix and everything from "' (expected rc=" on — a "$"-anchored
# strip fails because of the trailing ANSI reset (r03: the guard killed a good run).
set -uo pipefail
export KUBECONFIG=/root/mno/kubeconfig

# ==== CONFIG (fill per run) ====
RUN="<run-id>"
SCENARIO_ID="<CBT-F-NN>"
CHECKOUT=/root/v2/virt-cbt-lab
HERE="$CHECKOUT/cbt-chaos/scenarios_v2/$SCENARIO_ID/runs/$RUN"
D="$HERE/evidence"; mkdir -p "$D"
# build_trigger <run> [args...] must print the trigger text (see templates/trigger-library.md);
# it MUST NOT contain backslashes.
. "$HERE/trigger-lib.sh"
TRIG="$(build_trigger "$RUN")"
printf '%s\n' "$TRIG" > "$D/trigger-command.txt"
if printf '%s' "$TRIG" | grep -q '\\'; then echo "FAIL: backslash in trigger" >&2; exit 1; fi

# Target pinning with pod-scenarios: namespace + --name-pattern ONLY (no --pod-label —
# krkn gives the label precedence and ignores the name pattern, r04).
TARGET_ARGS=(--namespace "<ns>" --name-pattern "^<pod-name>\$")

date -u +%FT%TZ > "$D/armed.utc"
(
  for _ in $(seq 1 60); do grep -qF "[0] command trigger:" "$D/krknctl.log" 2>/dev/null && break; sleep 1; done
  got=$(grep -F "[0] command trigger:" "$D/krknctl.log" | head -1 | sed "s/^ *\[0\] command trigger: '//; s/' (expected rc=0).*$//")
  if [ "$got" = "$TRIG" ]; then
    echo "TRIGGER-ROUNDTRIP: identical" > "$D/trigger-roundtrip.txt"
  else
    { echo "TRIGGER-ROUNDTRIP: MISMATCH"; printf '%s\n' "$got"; } > "$D/trigger-roundtrip.txt"
    kill "$KRKN_PID" 2>/dev/null     # PID, never pkill -f (hangs/kills own shell)
  fi
) &
krknctl run <plugin> "${TARGET_ARGS[@]}" \
  --trigger-command "$TRIG" --trigger-expected-rc 0 \
  --triggers-interval 1 --triggers-timeout 1800 --triggers-on-timeout fail \
  --kubeconfig "$KUBECONFIG" > "$D/krknctl.log" 2>&1 &
KRKN_PID=$!      # krknctl itself (not a tee) so the guard can kill it; watch live with: tail -f "$D/krknctl.log"
wait "$KRKN_PID"; echo "$?" > "$D/krknctl.rc"; date -u +%FT%TZ > "$D/ended.utc"

# After the run: confirm which object was actually hit (krknctl.log "Force deleting pod <name>")
# and compare with the pre-chaos target. Wrong object = invalid run, record it, do not grade it.

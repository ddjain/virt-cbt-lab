#!/usr/bin/env bash
# fleet-verify.sh — Layer-1 object-level fleet validation + run report for a
# fleet group. Cross-checks the wrapper's verdict against live cluster state
# (never driver logs): per-vmbackup Done reasons, tracker latestCheckpoint,
# and emits $SCALE_STATE_DIR/groups/<group-id>/run-report.md.
#
# Usage: KUBECONFIG=... cbt-scale/fleet-verify.sh <group-id> [start-UTC] [end-UTC]
#   start/end (optional): run window for the Prometheus sweep + report timeline.
# Exit: 0 = all VMs pass, 1 = failures, 2 = usage/missing state.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Code lives in cbt-scale/ (tracked); runtime state and evidence live in
# SCALE_STATE_DIR (default: <repo>/artifacts, gitignored).
SCALE_STATE_DIR="${SCALE_STATE_DIR:-$ROOT_DIR/artifacts}"; export SCALE_STATE_DIR
cd "$ROOT_DIR"
: "${KUBECONFIG:?export KUBECONFIG}"
GID="${1:?group id required}"
S_EPOCH="${2:-}"; E_EPOCH="${3:-}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
GF="$SCALE_STATE_DIR/groups/$GID.yaml"
[[ -f "$GF" ]] || { echo "no group manifest at $GF" >&2; exit 2; }
OUT="$SCALE_STATE_DIR/groups/$GID"
mkdir -p "$OUT"

pass=0; fail=0
: > "$OUT/verify.tsv"
while IFS=$'\t' read -r vm _ _ _ _; do
  [[ "$vm" == "vm" ]] && continue; vm="${vm#vm-}"
  full=$(oc get vmbackup -n "$NAMESPACE" "vm-backup-$GID-$vm" \
    -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || echo missing)
  incr=$(oc get vmbackup -n "$NAMESPACE" "vm-incremental-$GID-$vm-p01" \
    -o jsonpath='{.status.conditions[?(@.type=="Done")].reason}' 2>/dev/null || echo missing)
  cp=$(oc get vmbackuptracker -n "$NAMESPACE" "vm-tracker-$GID-$vm" \
    -o jsonpath='{.status.latestCheckpoint.name}' 2>/dev/null || echo missing)
  verdict=pass
  [[ "$full" == "Successfully completed VirtualMachineBackup" ]] || verdict="full:$full"
  [[ "$incr" == "Successfully completed VirtualMachineBackup" ]] || verdict="${verdict};incr:$incr"
  [[ "$cp" == "vm-incremental-$GID-$vm-p01-"* ]] || verdict="${verdict};tracker:$cp"
  if [[ "$verdict" == "pass" ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$vm" "$full" "$incr" "$cp" "$verdict" >> "$OUT/verify.tsv"
done < "$GF"
total=$((pass+fail))
echo "verify: $pass/$total pass, $fail fail (live cluster state)"

# storage snapshot row for the report
snap="$(bash "$ROOT_DIR/cbt-scale/storage-snapshot.sh" "post-verify-$GID" 2>/dev/null | tail -1 || true)"

# Prometheus sweep if window given
PROM_NOTE="(window not provided — skipped)"
if [[ -n "$S_EPOCH" && -n "$E_EPOCH" ]]; then
  if bash "$ROOT_DIR/cbt-scale/prom-sweep.sh" "$S_EPOCH" "$E_EPOCH" "$OUT/run-report.md" \
     > "$OUT/prom-sweep.log" 2>&1; then PROM_NOTE="sweep PASS (see prom-sweep.log)"; \
  else PROM_NOTE="sweep reported findings (see prom-sweep.log)"; fi
fi

# report
{
  echo "# Fleet scale run report — group $GID"
  echo ""
  echo "## Fleet verdict (Layer 1, live cluster state)"
  echo "- PASS $pass/$total"$( ((fail>0)) && echo ", FAIL $fail" || true )
  echo "- Per-VM evidence: verify.tsv (full/incr Done reasons + tracker checkpoint)"
  [[ -n "$snap" ]] && echo "- Storage: $snap"
  echo "- Prometheus (Layer 2): $PROM_NOTE"
  echo ""
  if ((fail>0)); then
    echo "## Failures (verbatim)"
    awk -F'\t' '$5!="pass"{print "- "$1": "$5}' "$OUT/verify.tsv"
    echo ""
  fi
  echo "## Evidence"
  echo "- $SCALE_STATE_DIR/groups/$GID.yaml (+ .summary), verify.tsv, prom-sweep.log"
  echo "- $OUT/rhel/summary.txt, $OUT/rhl/summary.txt, $OUT/win/summary.txt, driver logs in those dirs"
  echo "- Wrapper log: grep the fleet-e2e.sh invocation that created this group"
} > "$OUT/run-report.md"
echo "report: $OUT/run-report.md"
(( fail == 0 )) || exit 1

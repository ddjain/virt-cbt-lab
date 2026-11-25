#!/usr/bin/env bash
# fleet-timings.sh — deterministic timing record + failure triage for a fleet
# group run. Replaces the manual post-run steps:
#   - stage timestamps (reset / GC / drive start-end) from wrapper-timings.tsv
#   - per-family driver walls + "requests applied" times from <os>/summary.txt
#   - per-backup created→Done durations (min/max/avg) from vmbackup objects
#   - cross-family concurrency check (applied timestamps within 10s)
#   - storage deltas from storage.csv (pre-run-<group> vs post-run-<group>)
#   - failure triage with classification, including the "backup service
#     completed but the vmbackup object never transitioned" case (VMI event
#     "already executed ... completed: true" on a stuck Initializing object)
#
# Usage: KUBECONFIG=... cbt-scale/fleet-timings.sh <group-id>
# Writes $SCALE_STATE_DIR/groups/<group-id>/timings.md and timings.tsv.
# Evidence tool: always exits 0 on success (verdicts come from fleet-verify.sh),
# 2 on usage/missing state.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCALE_STATE_DIR="${SCALE_STATE_DIR:-$ROOT_DIR/artifacts}"; export SCALE_STATE_DIR
cd "$ROOT_DIR"
# shellcheck source=cbt-scale/lib-naming.sh
source "$ROOT_DIR/cbt-scale/lib-naming.sh"
: "${KUBECONFIG:?export KUBECONFIG}"
GID="${1:?group id required}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
GF="$SCALE_STATE_DIR/groups/$GID.yaml"
[[ -f "$GF" ]] || { echo "no group manifest at $GF" >&2; exit 2; }
OUT="$SCALE_STATE_DIR/groups/$GID"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

# ---------- vm -> family map (from the group's per-OS sub-manifests) ----------
: > "$TMP.fam"
for f in rhel rhl win; do
  [[ -f "$OUT/$f.manifest" ]] && tail -n +2 "$OUT/$f.manifest" | cut -f1 \
    | awk -v fam="$f" '{print $1 "\t" fam}' >> "$TMP.fam"
done

# ---------- per-backup durations (one bulk fetch, indexed by object name) ----------
vmb_json="$(oc get vmbackup -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')"
jq -r --arg g "$GID" '
  .items[] | select(.metadata.name | contains($g))
  | [ .metadata.name, .metadata.creationTimestamp,
      ([.status.conditions[]? | select(.type=="Done" and .status=="True")
        | .lastTransitionTime] | first // "")
    ] | @tsv' <<<"$vmb_json" \
| while IFS=$'\t' read -r name created done; do
    # object name -> vm (rid = segment after the group id; strip -pNN for incr)
    rest="${name#*-$GID-}"; rid="${rest%-p[0-9]*}"
    phase=full; [[ "$name" == vm-incremental-* ]] && phase=incr
    fam=$(awk -F'\t' -v vm="vm-$rid" '$1==vm{print $2}' "$TMP.fam")
    [[ -n "$fam" ]] || fam=other
    dur=""
    if [[ -n "$done" ]]; then
      dur=$(TZ=UTC awk -v a="$created" -v b="$done" 'BEGIN{
        ta=mktime(gensub(/[-T:]/," ","g",substr(a,1,19))); tb=mktime(gensub(/[-T:]/," ","g",substr(b,1,19)));
        print tb-ta}')
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "vm-$rid" "$fam" "$phase" "$created" "$done" "$dur"
  done > "$OUT/timings.tsv"

# ---------- failure triage (VMs whose group result != pass) ----------
: > "$OUT/triage.tsv"
while IFS=$'\t' read -r vm state full_b incr_b result; do
  [[ "$vm" == "vm" || "$result" == "pass" ]] && continue
  cls="other (see verify.tsv)"
  if grep -q "No space left on device" <<<"$result"; then
    cls="pvc-full (backup PVC too small for the data written)"
  elif grep -qE "Failed freezing guest filesystem|Failed to unfreeze" <<<"$result"; then
    cls="guest-fsfreeze-warning (backup completed, quiesce flaked)"
  else
    # stuck-object check: no Done on the incremental + backup service already
    # reported the command completed (VMI BackupError event)
    ev=$(oc get events -n "$NAMESPACE" --field-selector involvedObject.name="$vm" -o json 2>/dev/null \
      | jq -r '.items[].message' 2>/dev/null | grep -m1 "already executed" || true)
    if [[ -n "$ev" ]]; then
      cls="object-stuck (backup service reports completed:true; vmbackup never transitioned)"
    fi
  fi
  cond=$(oc get vmbackup -n "$NAMESPACE" "$(scale_incr_name "$GID" "$vm" 1)" -o json 2>/dev/null \
    | jq -r '.status.conditions[]? | "\(.type)=\(.status) reason=\(.reason)"' 2>/dev/null | tr '\n' '; ' || true)
  printf '%s\t%s\t%s\n' "$vm" "$cls" "$cond" >> "$OUT/triage.tsv"
done < "$GF"

# ---------- assemble timings.md ----------
{
  echo "# Timing record — group $GID (UTC)"
  echo ""
  echo "## Stage timestamps (wrapper)"
  echo ""
  if [[ -f "$OUT/wrapper-timings.tsv" ]]; then
    echo "| Stage | UTC |"
    echo "|---|---|"
    awk -F'\t' '{printf "| %s | %s |\n", $2, $1}' "$OUT/wrapper-timings.tsv"
  else
    echo "_no wrapper-timings.tsv (run predates stage recording; see the wrapper log)_"
  fi
  echo ""
  echo "## Driver phase walls + wave-apply times (per family)"
  echo ""
  echo "| Family | Full applied | Full wall | Incr applied | Incr wall |"
  echo "|---|---|---|---|---|"
  for f in rhel rhl win; do
    s="$OUT/$f/summary.txt"; [[ -f "$s" ]] || continue
    fa=$(grep -m1 "all full backup requests applied" "$s" | awk '{print $1}')
    fw=$(grep -m1 "full phase wall" "$s" | awk '{print $4}')
    ia=$(grep -m1 "all incremental backup requests applied" "$s" | awk '{print $1}')
    iw=$(grep -m1 "incr phase wall" "$s" | awk '{print $4}')
    echo "| $f | ${fa:--} | ${fw:--} | ${ia:--} | ${iw:--} |"
  done
  echo ""
  # concurrency: spread of the families' full-apply times (same run, same day)
  spread=$(for f in rhel rhl win; do
      s="$OUT/$f/summary.txt"; [[ -f "$s" ]] || continue
      grep -m1 "all full backup requests applied" "$s" | awk '{print $1}'
    done | awk 'BEGIN{FS=":"} {t=$1*3600+$2*60+$3; if(NR==1||t<mn)mn=t; if(NR==1||t>mx)mx=t} END{if(NR>1) print mx-mn; else print 0}')
  if [[ "$spread" -le 10 ]]; then
    echo "Concurrency: CONFIRMED — full waves applied within ${spread}s across families."
  else
    echo "Concurrency: NOT CONFIRMED — full-wave apply spread is ${spread}s across families (families ran staggered)."
  fi
  echo ""
  echo "## Per-backup durations (creationTimestamp → Done lastTransitionTime)"
  echo ""
  echo "| Family/phase | n | min | max | avg |"
  echo "|---|---|---|---|---|"
  awk -F'\t' '$6!="" && $6!~/-/ {
      key=$2"-"$3; n[key]++; if(!(key in mn)||$6<mn[key])mn[key]=$6; if($6>mx[key])mx[key]=$6; sum[key]+=$6
    } END { for (k in n) printf "| %s | %d | %ds | %ds | %.1fs |\n", k, n[k], mn[k], mx[k], sum[k]/n[k] }' "$OUT/timings.tsv"
  echo ""
  awk -F'\t' '$6==""{c++} END{if(c>0) printf "_%d backup object(s) without a Done condition — excluded from durations (see triage)_\n", c}' "$OUT/timings.tsv"
  echo ""
  echo "## Storage deltas (storage.csv: pre-run-$GID → post-run-$GID)"
  echo ""
  pre=$(grep -F "pre-run-$GID," "$SCALE_STATE_DIR/storage.csv" | tail -1)
  post=$(grep -F "post-run-$GID," "$SCALE_STATE_DIR/storage.csv" | tail -1)
  if [[ -n "$pre" && -n "$post" ]]; then
    echo "| Metric | Pre | Post | Delta |"
    echo "|---|---|---|---|"
    awk -F',' -v pre="$pre" -v post="$post" 'BEGIN{
      split(pre,p); split(post,q)
      m["raw_used_gib"]=4; m["pool_stored_gib"]=5; m["rbd_n"]=7; m["rbd_gib"]=8
      for (k in m) { i=m[k]; d=q[i]-p[i]; printf "| %s | %s | %s | %+d |\n", k, p[i], q[i], d }
    }'
  else
    echo "_storage.csv rows pre-run-$GID / post-run-$GID not found_"
  fi
  echo ""
  if [[ -s "$OUT/triage.tsv" ]]; then
    echo "## Failure triage (classification + live object conditions)"
    echo ""
    echo "| VM | Classification | Incremental object conditions (live) |"
    echo "|---|---|---|"
    awk -F'\t' '{printf "| %s | %s | %s |\n", $1, $2, $3}' "$OUT/triage.tsv"
    echo ""
    echo "Classification key: pvc-full = destination PVC genuinely exhausted;"
    echo "guest-fsfreeze-warning = backup completed with a quiesce warning;"
    echo "object-stuck = backup service reports the command completed but the"
    echo "vmbackup object never transitioned (data likely saved, object stale);"
    echo "other = inspect verify.tsv + conditions manually."
    echo ""
  fi
  echo "## Evidence"
  echo "- timings.tsv (per-backup rows), triage.tsv, verify.tsv, storage.csv,"
  echo "  wrapper-timings.tsv, <family>/summary.txt"
} > "$OUT/timings.md"
echo "timings: $OUT/timings.md"

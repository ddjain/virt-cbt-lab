#!/usr/bin/env bash
set -euo pipefail
# Simple poller: VM backup fleet status for the scale run. Read-only.
# Usage: scale-status.sh <pool-id> [interval-seconds]

if [[ $# -lt 1 ]]; then
  printf 'usage: %s <pool-id> [interval-seconds]\n' "$0" >&2
  exit 2
fi
POOL="${1:?}"
INTERVAL="${2:-10}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
: "${KUBECONFIG:?export KUBECONFIG first}"

while :; do
  stats="$(oc get vmbackup -n "$NAMESPACE" -o json 2>/dev/null | jq -r "
    def fam(\$prefix):
      [.items[] | select(.metadata.name | test(\"^\" + \$prefix))] |
      [ (length),
        ([.[] | .status.conditions[]? | select(.type==\"Done\" and .status==\"True\")] | length),
        ([.[] | .status.conditions[]? | select(.type==\"Progressing\" and .status==\"True\")] | length),
        ([.[] | .status.conditions[]? | select(.reason | startswith(\"Backup has failed\"))] | length) ];
    [ fam(\"vm-backup-$POOL-\") + fam(\"vm-incremental-$POOL-\") ] | flatten | join(\" \")")"

  if [[ -z "$stats" ]]; then
    printf '%s oc/jq failed\n' "$(date +%H:%M:%S)"; sleep "$INTERVAL"; continue
  fi
  read -r f_tot f_done f_prog f_fail i_tot i_done i_prog i_fail <<<"$stats"

  # pending = total - done - in-progress (not yet started or between states)
  f_pend=$(( f_tot - f_done - f_prog )); (( f_pend < 0 )) && f_pend=0
  i_pend=$(( i_tot - i_done - i_prog )); (( i_pend < 0 )) && i_pend=0

  vm_line="$(oc get vm -n "$NAMESPACE" -l "virt-cbt-lab/pool=$POOL" -o json 2>/dev/null | jq -r '[(.items | length), ([.items[]? | .status.ready // false] | map(select(.)) | length)] | join(" ")')"
  read -r vm_total vm_ready <<<"$vm_line"

  printf '%s  FULL: %s/%s done, %s in-progress, %s pending, %s failed  |  INCR: %s/%s done, %s in-progress, %s pending, %s failed  |  VMs ready %s/%s\n' \
    "$(date +%H:%M:%S)" \
    "$f_done" "$f_tot" "$f_prog" "$f_pend" "$f_fail" \
    "$i_done" "$i_tot" "$i_prog" "$i_pend" "$i_fail" \
    "${vm_ready:-?}" "${vm_total:-?}"

  if (( f_tot > 0 && i_tot > 0 )) && (( f_done + f_fail >= f_tot && i_done + i_fail >= i_tot )); then
    printf 'ALL TERMINAL — full: %s ok / %s failed, incr: %s ok / %s failed\n' "$f_done" "$f_fail" "$i_done" "$i_fail"
    break
  fi
  sleep "$INTERVAL"
done

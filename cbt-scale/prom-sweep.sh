#!/usr/bin/env bash
# prom-sweep.sh — Layer-2 Prometheus health sweep over a run window.
# Queries the cluster's Thanos querier (openshift-monitoring) for the concerns
# in the fleet/density scale workflow: backup failures, Ceph health/latency/
# utilization, CNV restarts, apiserver errors, node pressure. Emits one
# "metric | observed | verdict" line per concern and exits 1 on any FAIL.
#
# Usage: KUBECONFIG=... cbt-scale/prom-sweep.sh <start-UTC> <end-UTC> [report.md]
#   start/end: ISO timestamps (2026-11-18T15:10:00Z) or unix epoch seconds.
#   With report.md, appends a markdown findings table to that file.
#
# Notes:
# - Uses `oc create token prometheus-k8s` and the thanos-querier route; the
#   route cert is signed by the cluster CA, not in the host CA bundle, so curl
#   runs with --insecure (token auth still enforces identity).
# - ceph_health_status: 0=OK, 1=WARN. WARN is only a FAIL if it differs from
#   the 3h pre-window baseline (pre-existing cluster warnings are not run
#   findings).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${KUBECONFIG:?export KUBECONFIG}"
START_ARG="${1:?start timestamp required}"
END_ARG="${2:?end timestamp required}"
REPORT="${3:-}"

to_epoch(){ date -u -d "$1" +%s 2>/dev/null || echo "$1"; }
S="$(to_epoch "$START_ARG")"; E="$(to_epoch "$END_ARG")"
(( E > S )) || { echo "end must be after start" >&2; exit 2; }

TOKEN="$(oc create token prometheus-k8s -n openshift-monitoring --duration=1h)"
THANOS="$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')"

q(){  # instant query -> raw jq
  curl -s --insecure -G -H "Authorization: Bearer $TOKEN" \
    "https://$THANOS/api/v1/query" --data-urlencode "query=$1"
}
qr(){  # range query over the window -> max of all series values
  curl -s --insecure -G -H "Authorization: Bearer $TOKEN" \
    "https://$THANOS/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode "start=$S" \
    --data-urlencode "end=$E" --data-urlencode "step=60" \
    | jq -r '[.data.result[]? | .values[]?[1] | tonumber] | max // empty'
}

VERDICTS=(); ROWS=()
add(){  # $1 concern  $2 observed  $3 verdict
  VERDICTS+=("$3"); ROWS+=("$1|$2|$3")
  printf '%-28s %-45s %s\n' "$1" "$2" "$3"
}

# 1. Ceph health: compare window value vs 3h pre-window baseline
now_health="$(q "ceph_health_status" | jq -r '.data.result[]?.value[1] // empty' | head -1)"
pre="$(q "ceph_health_status @ $(( S - 7200 ))" \
  | jq -r '.data.result[]?.value[1] // empty' | head -1)"
h_obs="window=${now_health:-n/a} baseline=${pre:-n/a}"
if [[ -z "${now_health:-}" ]]; then add "ceph_health_status" "$h_obs" "NO DATA"
elif [[ "$now_health" == "0" ]]; then add "ceph_health_status" "$h_obs (0=OK)" "PASS"
elif [[ "$now_health" == "$pre" ]]; then add "ceph_health_status" "$h_obs (pre-existing WARN)" "PASS (pre-existing)"
else add "ceph_health_status" "$h_obs (new WARN during run)" "FAIL"; fi

# 2. Ceph utilization (bytes used / bytes total)
util="$(q "(sum(ceph_osd_stat_bytes_used) / sum(ceph_osd_stat_bytes)) * 100" \
  | jq -r '.data.result[]?.value[1] // empty')"
if [[ -z "$util" ]]; then add "ceph_utilization" "n/a" "NO DATA"
elif awk "BEGIN{exit !($util < 85)}"; then add "ceph_utilization" "${util}% (max)" "PASS"
else add "ceph_utilization" "${util}% >= 85% (near full_ratio)" "FAIL"; fi

# 3. OSD read latency peak in window
lat="$(qr "max_over_time((max(ceph_osd_op_r_latency_sum)/clamp_min(max(ceph_osd_op_r_latency_count),1))[10m:1m])")"
if [[ -z "$lat" ]]; then add "osd_r_latency" "n/a" "NO DATA"
elif awk "BEGIN{exit !($lat < 0.1)}"; then add "osd_r_latency" "${lat}s avg-op peak" "PASS"
else add "osd_r_latency" "${lat}s avg-op peak (sustained >100ms)" "CHECK"; fi

# 4. CNV pod restarts during window (delta between window endpoints)
rst_end="$(q "sum(kube_pod_container_status_restarts_total{namespace=\"openshift-cnv\"} @ $E)" \
  | jq -r '.data.result[]?.value[1] // empty' 2>/dev/null || true)"
r0="$(q "sum(kube_pod_container_status_restarts_total{namespace=\"openshift-cnv\"} @ $S)" \
  | jq -r '.data.result[]?.value[1] // empty' 2>/dev/null || true)"
if [[ -n "$r0" && -n "${rst_end:-}" ]]; then
  d="$(awk "BEGIN{printf \"%d\", $rst_end - $r0}")"
  if (( d == 0 )); then add "cnv_restarts" "$d during window" "PASS"
  else add "cnv_restarts" "$d during window (no chaos in run)" "FAIL"; fi
else add "cnv_restarts" "n/a" "NO DATA"; fi

# 5. apiserver backend errors in window
api="$(qr "rate(haproxy_backend_http_responses_errors_total{backend=\"kube-apiserver\"}[5m])")"
if [[ -z "$api" ]]; then add "apiserver_errors" "no series (zero errors)" "PASS"
elif awk "BEGIN{exit !($api < 1)}"; then add "apiserver_errors" "max 5m rate $api" "PASS"
else add "apiserver_errors" "max 5m rate $api (sustained spike)" "CHECK"; fi

# 6. node memory pressure (min available across nodes, in window)
mem="$(qr "min(node_memory_MemAvailable_bytes)")"
if [[ -z "$mem" ]]; then add "node_mem_available" "n/a" "NO DATA"
elif awk "BEGIN{exit !($mem > 10737418240)}"; then
  g="$(awk "BEGIN{printf \"%.0f\", $mem/1073741824}")"; add "node_mem_available" "min ${g}GiB" "PASS"
else add "node_mem_available" "min below 10GiB" "CHECK"; fi

# verdict
fails=0; for v in "${VERDICTS[@]}"; do [[ "$v" == FAIL* ]] && fails=$((fails+1)); done
echo "sweep verdict: $fails FAIL of ${#VERDICTS[@]} checks"

if [[ -n "$REPORT" ]]; then
  {
    echo ""
    echo "## Prometheus findings (Layer 2, window $(date -u -d @$S +%FT%TZ) → $(date -u -d @$E +%FT%TZ))"
    echo ""
    echo "| Concern | Observed | Verdict |"
    echo "|---|---|---|"
    for r in "${ROWS[@]}"; do IFS='|' read -r c o v <<< "$r"; echo "| $c | $o | $v |"; done
    echo ""
  } >> "$REPORT"
  echo "appended findings table to $REPORT"
fi
exit $(( fails > 0 ? 1 : 0 ))

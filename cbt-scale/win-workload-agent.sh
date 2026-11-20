#!/usr/bin/env bash
# win-workload-agent.sh — Windows guest mutation via QEMU guest-agent.
# Sourced by scale-driver2.sh. No SSH needed in the Windows image.
# NOTE: no `set -e` here — the driver's retry loops handle failures.

agent_exec() {  # $1 vm-name $2 powershell-command  (prints decoded stdout)
  local pod domain reply pid i req streq
  pod="$(oc get pod -n "$NAMESPACE" -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$1" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || return 1
  [[ -n "$pod" ]] || return 1
  domain="${NAMESPACE}_${1}"
  req="$(jq -nc --arg cmd "$2" \
    '{"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-NoProfile","-NonInteractive","-Command",$cmd],"capture-output":true}}')"
  reply="$(oc exec -n "$NAMESPACE" "$pod" -c compute -- \
    virsh --quiet qemu-agent-command "$domain" "$req" --timeout 60 2>/dev/null)" || return 1
  pid="$(printf '%s' "$reply" | jq -r '.return.pid // empty')"
  [[ -n "$pid" ]] || return 1
  i=0
  while (( i++ < 60 )); do
    streq="$(jq -nc --argjson p "$pid" \
      '{"execute":"guest-exec-status","arguments":{"pid":$p}}')"
    reply="$(oc exec -n "$NAMESPACE" "$pod" -c compute -- \
      virsh --quiet qemu-agent-command "$domain" "$streq" --timeout 30 2>/dev/null)" || return 1
    if [[ "$(printf '%s' "$reply" | jq -r '.return.exited')" == "true" ]]; then
      printf '%s' "$reply" | jq -r '.return."out-data" // empty' \
        | python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))'
      # surface PowerShell errors (err-data) on stderr for diagnosis
      printf '%s' "$reply" | jq -r '.return."err-data" // empty' \
        | python3 -c 'import base64,sys; sys.stderr.buffer.write(base64.b64decode(sys.stdin.read()))' >&2 || true
      return "$(printf '%s' "$reply" | jq -r '.return.exitcode // 1')"
    fi
    sleep 2
  done
  return 1
}

win_workload_ps() {  # $1 vm-name $2 mode (baseline|incr)
  local vm="$1" mode="$2" itemsVar items_json ps
  if [[ "$mode" == baseline ]]; then itemsVar=baseline_items; else itemsVar=incr_items; fi
  items_json="$(printf '%s\n' ${!itemsVar} | tr -d '\047' \
    | jq -Rn '[inputs | split("|") | {name: .[0], size: (.[1]|tonumber)}]' | jq -c .)"
  ps="\$items = '$items_json' | ConvertFrom-Json;"
  ps+=" \$WD = 'C:\cbt-data\workload'; New-Item -ItemType Directory -Force -Path \$WD | Out-Null;"
  ps+=" foreach (\$i in \$items) { \$p = Join-Path \$WD \$i.name; if (-not (Test-Path \$p)) { \$fs=[System.IO.File]::OpenWrite(\$p); \$fs.SetLength(\$i.size); \$fs.Close() } };"
  if [[ "$mode" == incr ]]; then
    ps+=" \$t = Join-Path \$WD '$MOD_NAME';"
    ps+=" if (Test-Path \$t) { \$b = New-Object byte[] $MOD_SIZE; (New-Object Random(42)).NextBytes(\$b); [System.IO.File]::WriteAllBytes(\$t, \$b) };"
  fi
  ps+=" (Get-ChildItem \$WD | Measure-Object -Sum Length).Sum"
  agent_exec "$vm" "$ps"
}

is_win_vm() { [[ "$1" == *-win-* || "$1" == vm-*win* ]]; }

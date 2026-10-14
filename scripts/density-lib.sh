#!/usr/bin/env bash
# Shared density-pool helpers. Sourced library — no top-level code.
# Requires scripts/common.sh (ROOT_DIR, RUNS_ROOT_DIR, oc_cmd, RUN_LABEL_*).

density_pool_file() {
  printf '%s/density/%s/pool.json' "$ROOT_DIR" "$1"
}

density_latest_pool() {
  local pool latest="" latest_created="" created
  [[ -d "$ROOT_DIR/density" ]] || {
    printf 'No density pools found under density/; run make density-setup first.\n' >&2
    return 1
  }
  for pool in "$ROOT_DIR/density"/*/; do
    [[ -f "${pool}pool.json" ]] || continue
    pool="${pool%/}"
    pool="${pool##*/}"
    created="$(jq -r '.created_at // empty' "$(density_pool_file "$pool")")"
    if [[ -z "$latest_created" || "$created" > "$latest_created" ]]; then
      latest="$pool"
      latest_created="$created"
    fi
  done
  [[ -n "$latest" ]] || {
    printf 'No density pools found under density/; run make density-setup first.\n' >&2
    return 1
  }
  printf '%s' "$latest"
}

# Emit one JSON document describing a pool's funnel on stdout:
# {pool, os_profile, namespace, passes, total, vms:[{run_id, vm_name,
#  state: missing|creating|ready, full, incrementals:[...]}]}.
# VM state and backup states come from the cluster; pool.json only supplies
# the expected run ID list (VMs kube-burner has not created yet).
# Backup state: "-" absent, "running" Done missing/not True, "failed" Done True
# with a "Backup has failed" reason (backup_done_reason_is_failure
# semantics), "done" otherwise.
density_status_json() {
  local pool="$1" pool_file passes namespace total
  local vm_json_file backup_json_file
  pool_file="$(density_pool_file "$pool")"
  passes="$(jq -r '.incremental_passes' "$pool_file")"
  namespace="$(jq -r '.namespace' "$pool_file")"
  total="$(jq -r '.vm_count' "$pool_file")"
  # Pass cluster JSON via files, not --argjson: with many VMs the list blob
  # exceeds the kernel's per-argument limit (MAX_ARG_STRLEN, 128 KiB) and
  # execve fails with E2BIG ("Argument list too long").
  vm_json_file="$(mktemp)"
  backup_json_file="$(mktemp)"
  if ! oc_cmd get vm -n "$namespace" -l "$RUN_LABEL_POOL_KEY=$pool" -o json \
      >"$vm_json_file" 2>/dev/null; then
    printf '{"items":[]}' >"$vm_json_file"
  fi
  if ! oc_cmd get vmbackup -n "$namespace" -l "$RUN_LABEL_SELECTOR" -o json \
      >"$backup_json_file" 2>/dev/null; then
    printf '{"items":[]}' >"$backup_json_file"
  fi
  jq -n \
    --arg pool "$pool" \
    --arg os_profile "$(jq -r '.os_profile' "$pool_file")" \
    --arg namespace "$namespace" \
    --argjson passes "$passes" \
    --argjson total "$total" \
    --argjson expected "$(jq -c '.run_ids' "$pool_file")" \
    --slurpfile vms "$vm_json_file" \
    --slurpfile backups "$backup_json_file" \
    '
    def backup_state($name):
      ([$backups[0].items[]? | select(.metadata.name == $name)] | first) as $b
      | if $b == null then "-"
        else ([$b.status.conditions[]? | select(.type == "Done")] | first) as $c
          | if $c == null then "running"
            elif $c.status != "True" then "running"
            elif ($c.reason // "") | startswith("Backup has failed") then "failed"
            else "done"
            end
        end;
    [ $expected[] as $rid
      | ([$vms[0].items[]? | select(.metadata.labels[$rid_key_label] == $rid)] | first) as $vm
      | {
          run_id: $rid,
          vm_name: ("vm-" + $rid),
          state: (if $vm == null then "missing"
                  elif $vm.status.ready == true then "ready"
                  else "creating" end),
          full: backup_state("vm-backup-" + $rid),
          incrementals: [ range(1; $passes + 1)
            | tostring as $s
            | backup_state("vm-incremental-" + $rid + "-p" +
                ("0" * (2 - ($s | length))) + $s)]
        }
    ]
    | {pool: $pool, os_profile: $os_profile, namespace: $namespace,
       passes: $passes, total: $total, vms: .}
    ' --arg rid_key_label "$RUN_LABEL_RUN_ID_KEY"
  local status=$?
  rm -f "$vm_json_file" "$backup_json_file"
  return "$status"
}

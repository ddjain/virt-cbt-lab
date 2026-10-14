#!/usr/bin/env bash
# Shared density-pool helpers. Sourced library — no top-level code.
# Requires scripts/common.sh (ROOT_DIR, RUNS_ROOT_DIR, oc_cmd, RUN_LABEL_*).
#
# Pool state is derived entirely from the cluster: VMs carry
# virt-cbt-lab/pool + virt-cbt-lab/run-id labels and os-profile /
# manifest-variant / incremental-passes annotations, so no local pool
# metadata is kept. A pool exists exactly while at least one of its VMs
# exists on the cluster.

density_pool_file() {
  printf '%s/density/%s/pool.json' "$ROOT_DIR" "$1"
}

# Print the most recently created pool present on the cluster (VM
# creationTimestamp of the pool's newest VM), or fail with a message.
density_latest_pool() {
  local latest
  latest="$(oc_cmd get vm -n "$NAMESPACE" -l "$RUN_LABEL_POOL_KEY" \
    -o jsonpath='{range .items[*]}{.metadata.labels.virt-cbt-lab/pool}{"\n"}{end}' 2>/dev/null \
    | sort -u | tail -1 || true)"
  [[ -n "$latest" ]] || {
    printf 'No density pools found in namespace %s; run make density-setup first.\n' \
      "$NAMESPACE" >&2
    return 1
  }
  printf '%s' "$latest"
}

# Emit one JSON document describing a pool's funnel on stdout:
# {pool, os_profile, namespace, passes, total, vms:[{run_id, vm_name,
#  state: creating|ready, full, incrementals:[...]}]}.
# Everything — the expected run IDs, VM states, and backup states — is read
# live from the cluster. Backup state: "-" absent, "running" Done missing/not
# True, "failed" Done True with a "Backup has failed" reason
# (backup_done_reason_is_failure semantics), "done" otherwise.
density_status_json() {
  local pool="$1" passes namespace total
  local vm_json_file backup_json_file
  passes="${DENSITY_INCREMENTAL_PASSES:-4}"
  namespace="$NAMESPACE"
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
    --arg namespace "$namespace" \
    --argjson passes "$passes" \
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
    ([$vms[0].items[]? | .metadata.annotations["virt-cbt-lab/incremental-passes"] // empty]
      | if length == 0 then 4 else (.[0] | tonumber) end) as $passes
    | [ $vms[0].items[]?
        | .metadata.labels[$rid_key_label] as $rid
        | {
            run_id: $rid,
            vm_name: .metadata.name,
            state: (if .status.ready == true then "ready" else "creating" end),
            full: backup_state("vm-backup-" + $rid),
            incrementals: [ range(1; $passes + 1)
              | tostring as $s
              | backup_state("vm-incremental-" + $rid + "-p" +
                  ("0" * (2 - ($s | length))) + $s)]
          }
        | select(.run_id != null)
      ]
    | sort_by(.run_id)
    | {pool: $pool, os_profile: ([$vms[0].items[]? | .metadata.annotations["virt-cbt-lab/os-profile"] // empty] | if length == 0 then "-" else .[0] end),
       namespace: $namespace, passes: $passes, total: length, vms: .}
    ' --arg rid_key_label "$RUN_LABEL_RUN_ID_KEY"
  local status=$?
  rm -f "$vm_json_file" "$backup_json_file"
  return "$status"
}

# Count VMs currently present on the cluster for a pool (stdout, integer).
# Used by density-setup's readiness wait instead of local metadata.
density_pool_vm_count() {
  local pool="$1" count
  count="$(oc_cmd get vm -n "$NAMESPACE" -l "$RUN_LABEL_POOL_KEY=$pool" \
    -o jsonpath='{.items}' 2>/dev/null | jq 'length' || echo 0)"
  printf '%s' "${count:-0}"
}

# Wait until all count VMs of a pool report .status.ready == true.
density_wait_for_ready() {
  local pool="$1" expected="$2" timeout_minutes="${3:-240}"
  local deadline ready_count status_json
  deadline=$(( $(date +%s) + timeout_minutes * 60 ))
  while :; do
    status_json="$(density_status_json "$pool")"
    ready_count="$(jq '[.vms[] | select(.state == "ready")] | length' <<<"$status_json")"
    workflow_progress "created $ready_count/$expected"
    if ((ready_count == expected)); then
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      printf 'Pool %s still creating after %s minutes; check make density-status POOL=%s.\n' \
        "$pool" "$timeout_minutes" "$pool" >&2
      return 1
    fi
    sleep 30
  done
}

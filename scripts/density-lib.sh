#!/usr/bin/env bash
# Shared density-pool helpers. Sourced library — no top-level code.
# Requires scripts/common.sh (ROOT_DIR, RUNS_ROOT_DIR, oc_cmd, RUN_LABEL_*).
#
# Pool state is derived entirely from the cluster: VMs carry
# virt-cbt-lab/pool + virt-cbt-lab/run-id labels and os-profile /
# manifest-variant / incremental-passes annotations, so no local pool
# metadata is kept. A pool exists exactly while at least one of its VMs
# exists on the cluster.

# Emit one JSON document describing a group of VMs' funnel on stdout:
# {pool, os_profile, namespace, passes, total, vms:[{run_id, vm_name,
#  state: creating|ready, full, incrementals:[...]}]}.
# $1 = group label; $2 = `oc get vm -o json` items document for the group.
# Backup state: "-" absent, "running" Done missing/not True, "failed" Done
# True with a "Backup has failed" reason (backup_done_reason_is_failure
# semantics), "done" otherwise.
density_status_json() {
  local group="$1" vms_json="$2"
  local backup_json_file
  # Pass cluster JSON via files, not --argjson: with many VMs the list blob
  # exceeds the kernel's per-argument limit (MAX_ARG_STRLEN, 128 KiB) and
  # execve fails with E2BIG ("Argument list too long").
  backup_json_file="$(mktemp)"
  if ! oc_cmd get vmbackup -n "$NAMESPACE" -l "$RUN_LABEL_SELECTOR" -o json \
      >"$backup_json_file" 2>/dev/null; then
    printf '{"items":[]}' >"$backup_json_file"
  fi
  jq -n \
    --arg pool "$group" \
    --arg namespace "$NAMESPACE" \
    --slurpfile vms <(printf '%s' "$vms_json") \
    --slurpfile backups "$backup_json_file" \
    --arg rid_key_label "$RUN_LABEL_RUN_ID_KEY" \
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
    '
  local status=$?
  rm -f "$backup_json_file"
  return "$status"
}

# Print a group's funnel: header line, TOTAL/CREATING/CREATED/FULL/INCn
# summary, then one row per VM. $1 = group label; $2 = VM items JSON.
density_print_funnel() {
  local group="$1" vms_json="$2"
  local status_json passes total ready_count os_profile
  status_json="$(density_status_json "$group" "$vms_json")"
  os_profile="$(jq -r '.os_profile' <<<"$status_json")"
  passes="$(jq -r '.passes' <<<"$status_json")"
  total="$(jq -r '.total' <<<"$status_json")"
  ready_count="$(jq '[.vms[] | select(.state == "ready")] | length' <<<"$status_json")"

  printf '\nPool: %s  OS: %s  Namespace: %s  Incremental passes: %s\n' \
    "$group" "$os_profile" "$NAMESPACE" "$passes"
  printf 'TOTAL=%s CREATING=%s CREATED=%s FULL=%s' \
    "$total" "$((total - ready_count))" "$ready_count" \
    "$(jq '[.vms[] | select(.full == "done")] | length' <<<"$status_json")"
  for ((pass = 1; pass <= passes; pass++)); do
    printf ' INC%s=%s' "$pass" \
      "$(jq --argjson pass "$pass" '[.vms[] | select(.incrementals[$pass - 1] == "done")] | length' <<<"$status_json")"
  done
  printf '\n\n'

  printf '%-34s %-9s %-8s' 'RUN_ID' 'VM_STATE' 'FULL'
  for ((pass = 1; pass <= passes; pass++)); do
    printf ' %-8s' "INC$pass"
  done
  printf '\n'
  while IFS= read -r row; do
    run_id="$(jq -r '.run_id' <<<"$row")"
    vm_state="$(jq -r '.state' <<<"$row")"
    printf '%-34s %-9s %-8s' "$run_id" "$vm_state" "$(jq -r '.full' <<<"$row")"
    for ((pass = 1; pass <= passes; pass++)); do
      printf ' %-8s' "$(jq -r --argjson pass "$pass" '.incrementals[$pass - 1]' <<<"$row")"
    done
    printf '\n'
  done < <(jq -c '.vms[]' <<<"$status_json")
}

# Wait until all count VMs of a pool report .status.ready == true.
# Queries the cluster by pool label; used by density-setup.
#
# Repair loop (scale spin-up hardening, 2026-11-22): with hundreds of
# concurrent boots two failure modes strand VMs in "creating":
#   a) PausedIOError — qemu hit a transient root-disk IO error and libvirt
#      paused the guest; a virt-launcher pod delete (hard reboot) recovers
#      it reliably. Seen concentrated on a single node whose virt-handler
#      had broken client-cert rotation (SyncVMI deadline storms).
#   b) root PVC clone stuck Pending — CDI never spawned a populator pod
#      for the DataVolume; deleting the PVC so CDI re-enqueues the clone
#      unblocks the boot.
# Every REPAIR_INTERVAL minutes without ready-count progress, one repair
# pass runs, at most REPAIR_MAX_ROUNDS per wait. The wait still fails after
# timeout; callers decide whether a partial fleet is acceptable.
density_repair_pass() {  # $1 pool; prints acted-on VMs to stderr
  local pool="$1" vms_json
  vms_json="$(oc_cmd get vm -n "$NAMESPACE" -l "$RUN_LABEL_POOL_KEY=$pool" -o json 2>/dev/null || true)"
  [[ -n "$vms_json" ]] || return 0
  # a) paused VMs -> delete their virt-launcher pods (hard reboot)
  oc_cmd get vmi -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r '.items[]
        | select((.metadata.labels["virt-cbt-lab/pool"] // "") == "'"$pool"'")
        | select([.status.conditions[]? | select(.type == "Paused" and .status == "True")] | length > 0)
        | .metadata.name' \
    | while IFS= read -r vm; do
        oc_cmd get pods -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null \
          | { grep "^virt-launcher-${vm}-" || true; } \
          | while IFS= read -r pod; do
              oc_cmd delete pod "$pod" -n "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
              printf 'repair: reboot %s (PausedIOError)\n' "$vm" >&2
            done
      done
  # b) not-ready VMs with Pending root PVC -> delete the PVC so CDI re-enqueues the clone
  jq -r '.items[] | select(.status.ready != true) | .metadata.name' <<<"$vms_json" \
    | while IFS= read -r vm; do
        phase="$(oc_cmd get pvc "vm-disk-${vm}" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        if [[ "$phase" == "Pending" ]]; then
          oc_cmd delete pvc "vm-disk-${vm}" -n "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
          printf 'repair: reclone %s (root PVC Pending)\n' "$vm" >&2
        fi
      done
}

density_wait_for_ready() {
  local pool="$1" expected="$2" timeout_minutes="${3:-240}"
  local repair_interval="${REPAIR_INTERVAL:-10}"
  local repair_max="${REPAIR_MAX_ROUNDS:-6}"
  local deadline ready_count status_json vms_json last_ready last_change now round
  deadline=$(( $(date +%s) + timeout_minutes * 60 ))
  last_ready=-1; last_change=$(date +%s); round=0
   while :; do
     vms_json="$(oc_cmd get vm -n "$NAMESPACE" -l "$RUN_LABEL_POOL_KEY=$pool" -o json 2>/dev/null || true)"
     status_json="$(density_status_json "$pool" "$vms_json")"
     ready_count="$(jq '[.vms[] | select(.state == "ready")] | length' <<<"$status_json")"
     workflow_progress "created $ready_count/$expected"
     if ((ready_count == expected)); then
       return 0
     fi
    now=$(date +%s)
    if (( ready_count != last_ready )); then
      last_ready=$ready_count; last_change=$now
    fi
    if (( round < repair_max )) && (( now - last_change >= repair_interval * 60 )); then
      round=$((round + 1))
      printf 'Pool %s stalled at %s/%s for %s min; repair pass %s/%s\n' \
        "$pool" "$ready_count" "$expected" "$repair_interval" "$round" "$repair_max" >&2
      density_repair_pass "$pool" || true
      last_change=$now
    fi
     if (( $(date +%s) >= deadline )); then
       printf 'Pool %s still creating after %s minutes; check make density-status POOL=%s.\n' \
         "$pool" "$timeout_minutes" "$pool" >&2
       return 1
     fi
     sleep 30
   done
}

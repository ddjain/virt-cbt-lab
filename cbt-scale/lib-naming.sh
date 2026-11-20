#!/usr/bin/env bash
# lib-naming.sh — single source of truth for fleet-group backup object names.
# Sourced by scale-driver2.sh (creates objects), fleet-e2e.sh and
# fleet-verify.sh (look them up / reset them). Never build these names inline.
#
# Convention (matches the run-id convention VM=vm-<rid>, objects=vm-*-<rid>):
#   VM vm-fleet-rhl-0001 in group G has rid fleet-rhl-0001 and object id
#   G-fleet-rhl-0001, giving
#     vm-backup-G-fleet-rhl-0001
#     vm-incremental-G-fleet-rhl-0001-p01
#     vm-tracker-G-fleet-rhl-0001
#     vm-backup-pvc-G-fleet-rhl-0001 / vm-incremental-pvc-G-fleet-rhl-0001-pNN

# scale_rid <vm-or-rid>: fleet VM name -> rid (idempotent).
scale_rid() { printf '%s' "${1#vm-}"; }

# scale_obj_id <group> <vm-or-rid>
scale_obj_id() { printf '%s-%s' "$1" "$(scale_rid "$2")"; }

# scale_full_name / scale_incr_name / scale_tracker_name <group> <vm-or-rid> [pass]
scale_full_name() { printf 'vm-backup-%s' "$(scale_obj_id "$1" "$2")"; }
scale_incr_name() { printf 'vm-incremental-%s-p%02d' "$(scale_obj_id "$1" "$2")" "${3:-1}"; }
scale_tracker_name() { printf 'vm-tracker-%s' "$(scale_obj_id "$1" "$2")"; }

# scale_group_object_regex <group> <vm>...: anchored ERE matching exactly this
# group's backups, trackers and backup PVCs for the given VMs, as a name (no
# kind prefix). Used to scope destructive resets to one group.
scale_group_object_regex() {
  local g="$1" vm alt="" id; shift
  for vm in "$@"; do
    id="$(scale_obj_id "$g" "$vm")"
    alt+="${alt:+|}$id"
  done
  printf '^(vm-backup-|vm-incremental-|vm-tracker-|vm-backup-pvc-|vm-incremental-pvc-)(%s)(-p[0-9]+)?$' "$alt"
}

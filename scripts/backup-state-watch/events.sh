#!/usr/bin/env bash
# Source module: namespace events for the watched VM (hotplug attachment
# pods, volume mount/unmount).
# Emits: HOTPLUG_POD_CREATED, HOTPLUG_POD_DELETED, VOLUME_MOUNTED,
#        VOLUME_UNMOUNTED.
# Requires from main: NAMESPACE, VM_NAME. Requires lib.sh.

events_start() {
  start_stream events.txt get events -n "$NAMESPACE" -w --watch-only -o \
    jsonpath='{.reason}{"\t"}{.involvedObject.name}{"\t"}{.message}{"\n"}'
}

events_scan() {
  while IFS= read -r line; do [[ -n "$line" ]] && handle_event_line "$line"; done < <(new_lines events.txt)
}

handle_event_line() {
  local IFS=$'\t'
  # shellcheck disable=SC2206
  local parts=($1)
  ((${#parts[@]} >= 3)) || return 0
  local reason="${parts[0]}" object="${parts[1]}" message="${parts[2]}"
  local vol backup
  case "$reason" in
    VolumeMountedToPod | VolumeUnMountedFromPod)
      vol="$(grep -o 'Volume [^ ]* has been' <<<"$message" | cut -d' ' -f2)"
      [[ "$vol" == *-backup-target-pvc ]] || return 0
      backup="${vol%-backup-target-pvc}"
      is_watched_backup "$backup" || return 0
      if [[ "$reason" == VolumeMountedToPod ]]; then
        print_checkpoint "$backup" VOLUME_MOUNTED "$message"
      else
        print_checkpoint "$backup" VOLUME_UNMOUNTED "$message"
      fi
      ;;
    SuccessfulCreate | SuccessfulDelete)
      [[ "$object" == "$VM_NAME" ]] || return 0
      [[ "$message" == *"attachment pod"* ]] || return 0
      vol="$(grep -o 'for volume [^,]*' <<<"$message" | cut -d' ' -f3-)"
      [[ "$vol" == *-backup-target-pvc ]] || return 0
      backup="${vol%-backup-target-pvc}"
      is_watched_backup "$backup" || return 0
      if [[ "$reason" == SuccessfulCreate ]]; then
        print_checkpoint "$backup" HOTPLUG_POD_CREATED "$message"
      else
        print_checkpoint "$backup" HOTPLUG_POD_DELETED "$message"
      fi
      ;;
  esac
}

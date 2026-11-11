#!/usr/bin/env bash
# Source module: virt-launcher pod log (backup begin, guest freeze, thaw,
# local copy finish). Best-effort: without log access the other modules'
# checkpoints still fire.
# Emits: BACKUP_REQUESTED, GUEST_FROZEN, COPY_STARTED, COPY_FINISHED_LOCAL.
# Requires from main: NAMESPACE, VM_NAME. Requires lib.sh.

launcher_start() {
  local launcher_pod
  launcher_pod="$(oc_cmd get pods -n "$NAMESPACE" \
    -l kubevirt.io=virt-launcher,vm.kubevirt.io/name="$VM_NAME" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$launcher_pod" ]]; then
    start_stream launcher.log logs "pod/$launcher_pod" -n "$NAMESPACE" \
      -f --timestamps --since=1s
  else
    : >"$STREAM_DIR/launcher.log"
  fi
}

launcher_scan() {
  while IFS= read -r line; do [[ -n "$line" ]] && handle_launcher_line "$line"; done < <(new_lines launcher.log)
}

handle_launcher_line() {
  local line="$1" backup msg
  backup="$(grep -o '"backupName":"[^"]*"' <<<"$line" | cut -d'"' -f4)"
  [[ -z "$backup" ]] && return 0
  msg="$(grep -o '"msg":"[^"]*"' <<<"$line" | cut -d'"' -f4)"
  case "$msg" in
    "Backup begin called")
      print_checkpoint "$backup" BACKUP_REQUESTED "virt-launcher begin called" ;;
    "Freezing VMI to capture backup state")
      print_checkpoint "$backup" GUEST_FROZEN "guest filesystems frozen for state capture" ;;
    "Thawing VMI after backup job started")
      print_checkpoint "$backup" COPY_STARTED "VMI thawed; copy job running" ;;
    "Backup has been completed successfully")
      print_checkpoint "$backup" COPY_FINISHED_LOCAL "virt-launcher copy finished" ;;
  esac
}

#!/usr/bin/env bash
# Source module: VirtualMachineBackup CR conditions, type, checkpoint name.
# Emits: BACKUP_INITIALIZING, VOLUME_ATTACHING, COPY_IN_PROGRESS,
#        CHECKPOINT_RECORDED, BACKUP_COMPLETED, BACKUP_FAILED,
#        BACKUP_TARGET_DETACHING.
# Requires from main: NAMESPACE. Requires lib.sh.

vmbackup_start() {
  start_stream vmbackup.txt get vmbackup -n "$NAMESPACE" -w -o \
    jsonpath='{.metadata.name}{"|"}{.status.type}{"|"}{.status.conditions[?(@.type=="Initializing")].status}{"|"}{.status.conditions[?(@.type=="Initializing")].reason}{"|"}{.status.conditions[?(@.type=="Progressing")].status}{"|"}{.status.conditions[?(@.type=="Progressing")].reason}{"|"}{.status.conditions[?(@.type=="Done")].status}{"|"}{.status.conditions[?(@.type=="Done")].reason}{"|"}{.status.checkpointName}{"\n"}'
}

vmbackup_scan() {
  while IFS= read -r line; do handle_vmbackup_line "$line"; done < <(new_lines vmbackup.txt)
}

handle_vmbackup_line() {
  local IFS='|'
  # shellcheck disable=SC2206
  local parts=($1)
  ((${#parts[@]} >= 9)) || return 0
  local backup="${parts[0]}" ctype="${parts[1]}" init_st="${parts[2]}" \
    init_reason="${parts[3]}" prog_st="${parts[4]}" prog_reason="${parts[5]}" \
    done_st="${parts[6]}" done_reason="${parts[7]}" cp="${parts[8]}"
  is_watched_backup "$backup" || return 0
  [[ "$init_st" == "True" ]] && \
    print_checkpoint "$backup" BACKUP_INITIALIZING "${init_reason:-attaching backup target}"
  case "$prog_reason" in
    "attaching backup target"* | *"is being attached to VMI"*)
      print_checkpoint "$backup" VOLUME_ATTACHING "$prog_reason" ;;
    "detaching backup target"*)
      print_checkpoint "$backup" BACKUP_TARGET_DETACHING "$prog_reason" ;;
  esac
  if [[ "$prog_st" == "True" && "$done_st" == "False" ]]; then
    print_checkpoint "$backup" COPY_IN_PROGRESS "backup is in progress (type=${ctype:-unknown})"
  fi
  [[ -n "$cp" ]] && print_checkpoint "$backup" CHECKPOINT_RECORDED "checkpoint $cp"
  if [[ "$done_st" == "True" ]]; then
    if [[ "$done_reason" == "Backup has failed"* ]]; then
      print_checkpoint "$backup" BACKUP_FAILED "$done_reason"
    else
      print_checkpoint "$backup" BACKUP_COMPLETED "${done_reason:-Done}"
    fi
    terminal[$backup]=1
  fi
}

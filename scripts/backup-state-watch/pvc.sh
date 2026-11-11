#!/usr/bin/env bash
# Source module: output PVC phase transitions.
# Emits: PVC_BOUND.
# Requires from main: NAMESPACE, FULL_BACKUP_NAME, FULL_BACKUP_PVC_NAME,
# RUN_ID. Requires lib.sh.

pvc_start() {
  start_stream pvc.txt get pvc -n "$NAMESPACE" -w -o \
    jsonpath='{.metadata.name}{"|"}{.status.phase}{"\n"}'
}

pvc_scan() {
  while IFS= read -r line; do handle_pvc_line "$line"; done < <(new_lines pvc.txt)
}

handle_pvc_line() {
  local pvc phase backup
  pvc="${1%%|*}"
  phase="${1##*|}"
  [[ "$phase" == "Bound" ]] || return 0
  if [[ "$pvc" == "$FULL_BACKUP_PVC_NAME" ]]; then
    print_checkpoint "$FULL_BACKUP_NAME" PVC_BOUND "output PVC $pvc Bound"
  elif [[ "$pvc" == "vm-incremental-pvc-${RUN_ID}-p"* ]]; then
    # vm-incremental-pvc-<run>-pNN -> vm-incremental-<run>-pNN
    backup="vm-incremental-${pvc#vm-incremental-pvc-}"
    is_watched_backup "$backup" && \
      print_checkpoint "$backup" PVC_BOUND "output PVC $pvc Bound"
  fi
}

#!/usr/bin/env bash
# =============================================================================
# REFERENCE ONLY — not executable as-is: contains <RUN_ID> placeholders and
# stacked conditions separated only by blank lines. Copy the individual
# condition you need (or the compound) into your --trigger-command after
# substituting the variables. Human-facing docs: trigger-library.md.
#
# CBT chaos trigger-command library (krknctl --trigger-command, Option 1).
# One multi-line bash condition per backup-state-watch checkpoint. Each
# condition is designed to be passed verbatim as krknctl --trigger-command
# (multi-line is supported: rendered as a YAML `inline: |-` block and executed
# with subprocess.run(shell=True) inside the krkn container, which ships
# oc + jq + bash and KUBECONFIG=/home/krkn/.kube/config).
#
# Hard constraints (verified live 2026-11-11, krkn image 7b2b29ed1be6):
#   - 30s hard timeout PER POLL (subprocess timeout) — every condition below
#     runs in ~1-2s.
#   - Exit 0 = condition satisfied (chaos fires); any other exit = keep polling.
#   - Shell quoting must survive: krknctl CLI -> TRIGGER_COMMAND env ->
#     envsubst YAML literal block -> bash -c. Use ONLY single-quoted strings
#     and \$-free jq programs as below; no single quotes inside single quotes.
#   - Existence guards are built into every object-based condition (oc
#     --ignore-not-found + jq null checks) — the r02 trap.
#
# Substitution variables (replace before use):
#   NS=vm-cbt-demo  RUN=<run-id>  BACKUP=<vm-backup-...|vm-incremental-...-pNN>
#   PVC=<vm-backup-pvc-...|vm-incremental-pvc-...-pNN>  POD=<virt-launcher-...>
#   TRACKER=vm-tracker-<run-id>  VM=vm-<run-id>
#
# =============================================================================
NS=vm-cbt-demo; RUN=<RUN_ID>; BACKUP=vm-backup-$RUN; PVC=vm-backup-pvc-$RUN
POD=<virt-launcher-pod>; TRACKER=vm-tracker-$RUN; VM=vm-$RUN

# -----------------------------------------------------------------------------
# 1. PVC_BOUND — output PVC Bound (full or incremental dest)
#    source: scripts/backup-state-watch/pvc.sh
# -----------------------------------------------------------------------------
oc get pvc "$PVC" -n "$NS" --ignore-not-found -o json | jq -e '.status.phase == "Bound"' >/dev/null

# -----------------------------------------------------------------------------
# 2. BACKUP_INITIALIZING — vmbackup exists, Initializing=True, not Done
#    (backup target PVC being attached to VMI; the pre-copy startup window)
#    source: scripts/backup-state-watch/vmbackup.sh
# -----------------------------------------------------------------------------
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e '.metadata.name != null and ([.status.conditions[]? | select(.type == "Initializing" and .status == "True")] | length) == 1 and ([.status.conditions[]? | select(.type == "Done" and .status == "True")] | length) == 0' >/dev/null

# -----------------------------------------------------------------------------
# 3. VOLUME_ATTACHING — vmbackup Progressing reason mentions attach
#    source: vmbackup.sh case "attaching backup target"
# -----------------------------------------------------------------------------
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e 'any(.status.conditions[]?; (.reason // "") | test("is being attached to VMI"))' >/dev/null

# -----------------------------------------------------------------------------
# 4. COPY_IN_PROGRESS — Progressing=True, Done≠True
#    source: vmbackup.sh
# -----------------------------------------------------------------------------
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e '([.status.conditions[]? | select(.type == "Progressing" and .status == "True")] | length) == 1 and ([.status.conditions[]? | select(.type == "Done" and .status == "True")] | length) == 0' >/dev/null

# -----------------------------------------------------------------------------
# 5. BACKUP_COMPLETED — Done=True with a non-failure reason
#    source: vmbackup.sh
# -----------------------------------------------------------------------------
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e '([.status.conditions[]? | select(.type == "Done" and .status == "True")] | length) == 1 and ((.status.conditions[]? | select(.type == "Done") | .reason // "") | startswith("Backup has failed") | not)' >/dev/null

# -----------------------------------------------------------------------------
# 6. BACKUP_FAILED — Done=True with terminal failure reason (signature check
#    for fail-expected scenarios; append the scenario signature to test())
#    source: vmbackup.sh
# -----------------------------------------------------------------------------
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e 'any(.status.conditions[]?; .type == "Done" and .status == "True" and ((.reason // "") | startswith("Backup has failed")))' >/dev/null

# -----------------------------------------------------------------------------
# 7. CHECKPOINT_RECORDED — checkpointName set on the vmbackup
#    source: vmbackup.sh
# -----------------------------------------------------------------------------
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e '.status.checkpointName != null and .status.checkpointName != ""' >/dev/null

# -----------------------------------------------------------------------------
# 8. BACKUP_TARGET_DETACHING — Progressing reason mentions detaching
#    source: vmbackup.sh case "detaching backup target"
# -----------------------------------------------------------------------------
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e 'any(.status.conditions[]?; (.reason // "") | test("detaching backup target"))' >/dev/null

# -----------------------------------------------------------------------------
# 9. LAUNCHER_SCHEDULED — launcher pod exists and has spec.nodeName
#    (the r03 guard; combine with 2/3/4 via a compound condition)
#    source: r03 learning
# -----------------------------------------------------------------------------
test -n "$(oc get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"

# -----------------------------------------------------------------------------
# 10. BACKUP_REQUESTED — "Backup begin called" in launcher compute logs
#     source: launcher.sh (log-based)
#     NOTE: greps the whole log; add --since for fresh runs if needed
# -----------------------------------------------------------------------------
oc logs "$POD" -n "$NS" -c compute --tail=5000 2>/dev/null | grep -F '"backupName":"'"$BACKUP"'"' | grep -qF '"msg":"Backup begin called"'

# -----------------------------------------------------------------------------
# 11. GUEST_FROZEN — "Freezing VMI to capture backup state" in launcher logs
#     source: launcher.sh (log-based)
# -----------------------------------------------------------------------------
oc logs "$POD" -n "$NS" -c compute --tail=5000 2>/dev/null | grep -F '"backupName":"'"$BACKUP"'"' | grep -qF '"msg":"Freezing VMI to capture backup state"'

# -----------------------------------------------------------------------------
# 12. COPY_STARTED — "Thawing VMI after backup job started" in launcher logs
#     (thaw == copy job running; the live copy begins here)
#     source: launcher.sh (log-based)
# -----------------------------------------------------------------------------
oc logs "$POD" -n "$NS" -c compute --tail=5000 2>/dev/null | grep -F '"backupName":"'"$BACKUP"'"' | grep -qF '"msg":"Thawing VMI after backup job started"'

# -----------------------------------------------------------------------------
# 13. COPY_FINISHED_LOCAL — "Backup has been completed successfully" in logs
#     source: launcher.sh (log-based)
# -----------------------------------------------------------------------------
oc logs "$POD" -n "$NS" -c compute --tail=5000 2>/dev/null | grep -F '"backupName":"'"$BACKUP"'"' | grep -qF '"msg":"Backup has been completed successfully"'

# -----------------------------------------------------------------------------
# 14. TRACKER_ADVANCED — tracker latestCheckpoint matches the backup prefix
#     source: tracker.sh
# -----------------------------------------------------------------------------
oc get vmbackuptracker "$TRACKER" -n "$NS" --ignore-not-found -o json | jq -e --arg b "$BACKUP" '(.status.latestCheckpoint.name // "") | startswith($b)' >/dev/null

# -----------------------------------------------------------------------------
# 15. HOTPLUG_POD_CREATED — SuccessfulCreate attachment-pod event for the
#     backup's target PVC (events age out ~1h; use while fresh)
#     source: events.sh
# -----------------------------------------------------------------------------
oc get events -n "$NS" -o json 2>/dev/null | jq -e --arg vm "$VM" --arg vol "$BACKUP-backup-target-pvc" 'any(.items[]; .reason == "SuccessfulCreate" and .involvedObject.name == $vm and ((.message // "") | contains("attachment pod")) and ((.message // "") | contains($vol)))' >/dev/null

# -----------------------------------------------------------------------------
# 16. VOLUME_MOUNTED — VolumeMountedToPod event for the backup target PVC
#     source: events.sh
# -----------------------------------------------------------------------------
oc get events -n "$NS" -o json 2>/dev/null | jq -e --arg vol "$BACKUP-backup-target-pvc" 'any(.items[]; .reason == "VolumeMountedToPod" and ((.message // "") | contains($vol)))' >/dev/null

# -----------------------------------------------------------------------------
# 17. VOLUME_UNMOUNTED — VolumeUnMountedFromPod event for the target PVC
#     source: events.sh
# -----------------------------------------------------------------------------
oc get events -n "$NS" -o json 2>/dev/null | jq -e --arg vol "$BACKUP-backup-target-pvc" 'any(.items[]; .reason == "VolumeUnMountedFromPod" and ((.message // "") | contains($vol)))' >/dev/null

# -----------------------------------------------------------------------------
# 18. HOTPLUG_POD_DELETED — SuccessfulDelete attachment-pod event
#     source: events.sh
# -----------------------------------------------------------------------------
oc get events -n "$NS" -o json 2>/dev/null | jq -e --arg vm "$VM" --arg vol "$BACKUP-backup-target-pvc" 'any(.items[]; .reason == "SuccessfulDelete" and .involvedObject.name == $vm and ((.message // "") | contains("attachment pod")) and ((.message // "") | contains($vol)))' >/dev/null

# -----------------------------------------------------------------------------
# COMPOUND (the F-11 r03-style startup trigger, proven live):
# BACKUP_INITIALIZING + LAUNCHER_SCHEDULED
# -----------------------------------------------------------------------------
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e '.metadata.name != null and ([.status.conditions[]? | select(.type == "Initializing" and .status == "True")] | length) == 1 and ([.status.conditions[]? | select(.type == "Done" and .status == "True")] | length) == 0' >/dev/null && test -n "$(oc get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"

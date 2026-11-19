# CBT chaos trigger-command library

One tested multi-line bash condition per backup checkpoint, for use as
`krknctl --trigger-command` (Option 1 pattern). Every condition was validated
live against a completed run on 2026-11-11 (positive and negative cases) plus
a krknctl round-trip.

## How to use

1. Pick the checkpoint your scenario injects at (see the table).
2. Copy its condition; substitute the variables:
   - `NS` (namespace, `vm-cbt-demo`), `RUN` (run ID),
   - `BACKUP` (`vm-backup-<RUN>` for full, `vm-incremental-<RUN>-pNN` for pass NN),
   - `PVC` (`vm-backup-pvc-<RUN>` / `vm-incremental-pvc-<RUN>-pNN`),
   - `POD` (the launcher pod — resolve after `make vm-setup` in staged runs),
   - `TRACKER` (`vm-tracker-<RUN>`), `VM` (`vm-<RUN>`).
3. Combine conditions by chaining with `&&` (all must hold) — see the
   compound example.
4. Precheck: run the exact command via `bash -c` on cloud05 against live
   objects (both negative cases must yield rc≠0) before arming —
   the r02/r05 learning.

## Hard constraints (verified in krkn image `7b2b29ed1be6`)

- Multi-line `--trigger-command` is supported (rendered as YAML `inline: |-`,
  executed via `subprocess.run(shell=True)` in the container).
- **30 s hard timeout per poll** — every condition here runs ~1-2 s.
- Container ships `oc`, `kubectl`, `jq`, `bash`; `KUBECONFIG` preset to the
  mounted kubeconfig.
- Quoting must survive CLI → env → YAML → bash: use the library's style
  (double quotes outside, jq program in single quotes, no nested single
  quotes).

## Checkpoint conditions

Variables header (define or inline the values):

```bash
NS=vm-cbt-demo; RUN=<run-id>; BACKUP=vm-backup-$RUN; PVC=vm-backup-pvc-$RUN
POD=<virt-launcher-pod>; TRACKER=vm-tracker-$RUN; VM=vm-$RUN
```

### 1. PVC_BOUND — output PVC Bound

```bash
oc get pvc "$PVC" -n "$NS" --ignore-not-found -o json | jq -e '.status.phase == "Bound"' >/dev/null
```

### 2. BACKUP_INITIALIZING — backup startup window (pre-copy)

vmbackup exists, `Initializing=True` (backup target PVC attaching to VMI),
not Done. Measured window ~11 s on rhel9/large-odf — pair with a 1 s
`--triggers-interval`.

```bash
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e '.metadata.name != null and ([.status.conditions[]? | select(.type == "Initializing" and .status == "True")] | length) == 1 and ([.status.conditions[]? | select(.type == "Done" and .status == "True")] | length) == 0' >/dev/null
```

### 3. VOLUME_ATTACHING — target PVC being attached to the VMI

```bash
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e 'any(.status.conditions[]?; (.reason // "") | test("is being attached to VMI"))' >/dev/null
```

### 4. COPY_IN_PROGRESS — live copy running

```bash
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e '.metadata.name != null and ([.status.conditions[]? | select(.type == "Progressing" and .status == "True")] | length) == 1 and ([.status.conditions[]? | select(.type == "Done" and .status == "True")] | length) == 0' >/dev/null
```

### 5. BACKUP_COMPLETED — Done=True, success reason

```bash
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e '([.status.conditions[]? | select(.type == "Done" and .status == "True")] | length) == 1 and ((.status.conditions[]? | select(.type == "Done") | .reason // "") | startswith("Backup has failed") | not)' >/dev/null
```

### 6. BACKUP_FAILED — Done=True, terminal failure reason

Append the scenario's failure signature with `test(...)` when the scenario
spec names one.

```bash
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e 'any(.status.conditions[]?; .type == "Done" and .status == "True" and ((.reason // "") | startswith("Backup has failed")))' >/dev/null
```

### 7. CHECKPOINT_RECORDED — checkpointName set

```bash
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e '.status.checkpointName != null and .status.checkpointName != ""' >/dev/null
```

### 8. BACKUP_TARGET_DETACHING — target PVC detaching

```bash
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e 'any(.status.conditions[]?; (.reason // "") | test("detaching backup target"))' >/dev/null
```

### 9. LAUNCHER_SCHEDULED — r03 guard (pod exists, node assigned)

Combine with 2/3/4 via `&&` so krkn's helper pod lands on a real node.

```bash
test -n "$(oc get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
```

### 10. BACKUP_REQUESTED — "Backup begin called" in launcher logs

```bash
oc logs "$POD" -n "$NS" -c compute --tail=5000 2>/dev/null | grep -F '"backupName":"'"$BACKUP"'"' | grep -qF '"msg":"Backup begin called"'
```

### 11. GUEST_FROZEN — guest filesystems frozen for state capture

```bash
oc logs "$POD" -n "$NS" -c compute --tail=5000 2>/dev/null | grep -F '"backupName":"'"$BACKUP"'"' | grep -qF '"msg":"Freezing VMI to capture backup state"'
```

### 12. COPY_STARTED — VMI thawed, copy job running

```bash
oc logs "$POD" -n "$NS" -c compute --tail=5000 2>/dev/null | grep -F '"backupName":"'"$BACKUP"'"' | grep -qF '"msg":"Thawing VMI after backup job started"'
```

### 13. COPY_FINISHED_LOCAL — virt-launcher copy finished

```bash
oc logs "$POD" -n "$NS" -c compute --tail=5000 2>/dev/null | grep -F '"backupName":"'"$BACKUP"'"' | grep -qF '"msg":"Backup has been completed successfully"'
```

### 14. TRACKER_ADVANCED — tracker latestCheckpoint belongs to BACKUP

Set `BACKUP` to the newest backup name (full, or the incremental pass being
watched) — the tracker points at the *latest* checkpoint only.

```bash
oc get vmbackuptracker "$TRACKER" -n "$NS" --ignore-not-found -o json | jq -e --arg b "$BACKUP" '(.status.latestCheckpoint.name // "") | startswith($b)' >/dev/null
```

### 15. HOTPLUG_POD_CREATED — attachment pod created for the target PVC

Events age out (~1 h) — only use while fresh, or switch to the equivalent
PVC/vmbackup object condition for older evidence.

```bash
oc get events -n "$NS" -o json 2>/dev/null | jq -e --arg vm "$VM" --arg vol "$BACKUP-backup-target-pvc" 'any(.items[]; .reason == "SuccessfulCreate" and .involvedObject.name == $vm and ((.message // "") | contains("attachment pod")) and ((.message // "") | contains($vol)))' >/dev/null
```

### 16. VOLUME_MOUNTED — target PVC mounted into the launcher

```bash
oc get events -n "$NS" -o json 2>/dev/null | jq -e --arg vol "$BACKUP-backup-target-pvc" 'any(.items[]; .reason == "VolumeMountedToPod" and ((.message // "") | contains($vol)))' >/dev/null
```

### 17. VOLUME_UNMOUNTED — target PVC unmounted from the launcher

```bash
oc get events -n "$NS" -o json 2>/dev/null | jq -e --arg vol "$BACKUP-backup-target-pvc" 'any(.items[]; .reason == "VolumeUnMountedFromPod" and ((.message // "") | contains($vol)))' >/dev/null
```

### 18. HOTPLUG_POD_DELETED — attachment pod deleted

```bash
oc get events -n "$NS" -o json 2>/dev/null | jq -e --arg vm "$VM" --arg vol "$BACKUP-backup-target-pvc" 'any(.items[]; .reason == "SuccessfulDelete" and .involvedObject.name == $vm and ((.message // "") | contains("attachment pod")) and ((.message // "") | contains($vol)))' >/dev/null
```

### COMPOUND — startup-window trigger (F-11 r03 pattern, live-proven)

BACKUP_INITIALIZING **and** LAUNCHER_SCHEDULED:

```bash
oc get vmbackup "$BACKUP" -n "$NS" --ignore-not-found -o json | jq -e '.metadata.name != null and ([.status.conditions[]? | select(.type == "Initializing" and .status == "True")] | length) == 1 and ([.status.conditions[]? | select(.type == "Done" and .status == "True")] | length) == 0' >/dev/null && test -n "$(oc get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
```

## Copy-window compound (F-08 pattern, live-proven)

PVC Bound **and** launcher exists **and** backup not Done **and** the exact
backup's "Backup started" line in launcher logs:

```bash
test "$(oc get pvc "$PVC" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" = Bound && pod=$(oc get pod -n "$NS" -l vm.kubevirt.io/name="$VM" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && test -n "$pod" && test "$(oc get vmbackup "$BACKUP" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null)" != True && oc logs -n "$NS" "$pod" -c compute --tail=2000 2>/dev/null | grep -F -- "$BACKUP" | grep -F -- 'Backup started'
```

## Offset-from-copy-start compound (CBT-F-13 r05, live-proven)

For phases too short to poll (copy-complete → Done is sub-second): fire a fixed
number of seconds after the launcher's `Backup started` line, while the copy is
still `Progressing`. Set `OFFSET` from the control run's copy duration minus
krkn's ~7 s `pod-scenarios` selection latency. Optionally gate on a
Lease holder (`LEADER`) so a rotation aborts the trigger.

No backslashes anywhere — krkn collapses them. The fractional seconds are
removed by slicing (`.timestamp[0:19]`), not by regex.

```bash
out=$(oc get vmbackup "$BACKUP" -n "$NS" -o json 2>/dev/null) && test -n "$out" && printf '%s' "$out" | jq -e '([.status.conditions[]? | select(.type == "Done" and .status == "True")] | length) == 0 and ([.status.conditions[]? | select(.type == "Progressing" and .status == "True")] | length) == 1' >/dev/null && test "$(oc get lease virt-controller -n openshift-cnv -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)" = "$LEADER" && pod=$(oc get pod -n "$NS" -l vm.kubevirt.io/name="$VM" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && test -n "$pod" && oc logs -n "$NS" "$pod" -c compute --tail=5000 2>/dev/null | grep -F '"backupName":"'"$BACKUP"'"' | grep -F '"msg":"Backup started"' | head -1 | jq -e '(now - ((.timestamp[0:19] + "Z") | fromdateiso8601)) >= '"$OFFSET" >/dev/null
```

Drop the Lease clause for non-controller targets. Validate with the offset set to
`0` (rc=0 on a terminal backup's start line) and `99999999` (rc=1).

## Notes

- Log-based conditions (10-13) grep the pod's whole retained log; for a
  fresh backup in a long-lived VM, add `--since=1h` to `oc logs`.
- Event-based conditions (15-18) depend on event retention.
- The single-backup conditions all embed the existence guard
  (`--ignore-not-found` + `metadata.name != null` where object presence is
  required) — the r02 trap stays closed.
- krkn collapses backslashes in `--trigger-command`: a regex escape in jq/grep
  becomes a compile error and the trigger never fires, with no log line
  (CBT-F-13 r02). Check the logged command (`[0] command trigger:`) against
  the intended text.

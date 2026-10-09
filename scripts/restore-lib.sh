#!/usr/bin/env bash
# Helpers for scripts/vm-cbt-restore-test.sh: run a short-lived pod that
# reconstructs guest disks from the backup PVCs (qemu-img rebase/convert)
# and reads the guest file from ext4 (Debian), XFS (RHEL 9), or NTFS (Windows), without
# booting a second VM.
set -euo pipefail

# RESTORE_POD_NAME is derived from the current run ID by common.sh's
# set_resource_names (via load_run_id/new_run_id).
# No default: this image must provide qemu-img and util-linux (see
# images/restore-helper/Dockerfile), plus ntfs-3g for Windows restores. Build
# it and set RESTORE_HELPER_IMAGE in .env to your pushed reference.
# shellcheck disable=SC2034
RESTORE_HELPER_IMAGE="${RESTORE_HELPER_IMAGE:-}"
RESTORE_VERIFY_TIMEOUT_SECONDS=1800

require_restore_helper_image() {
  if [[ -z "$RESTORE_HELPER_IMAGE" ]]; then
    printf 'RESTORE_HELPER_IMAGE is not set. Build images/restore-helper/Dockerfile, push it, and set RESTORE_HELPER_IMAGE in .env.\n' >&2
    return 1
  fi
}

delete_restore_pod() {
  oc_cmd delete pod "$RESTORE_POD_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null
}

run_restore_verify_pod() {
  local full_pvc="$1" restore_manifest snippet_dir volumes_file mounts_file rendered
  local index pass pvc
  shift
  local -a incremental_pvcs=("$@")
  RESTORE_POD_PHASE=unknown
  if [[ "$VM_OS" == windows ]]; then
    restore_manifest="$ROOT_DIR/manifests/windows-restore-verify-pod.yaml"
  else
    restore_manifest="$ROOT_DIR/manifests/restore-verify-pod.yaml"
  fi

  delete_restore_pod
  snippet_dir="$(mktemp -d)"
  volumes_file="$snippet_dir/incremental-volumes.yaml"
  mounts_file="$snippet_dir/incremental-mounts.yaml"
  rendered="$snippet_dir/pod.yaml"
  cleanup_restore() {
    local status=$?
    trap - RETURN
    delete_restore_pod
    rm -rf "$snippet_dir"
    return "$status"
  }
  trap cleanup_restore RETURN

  : > "$volumes_file"
  : > "$mounts_file"
  for ((index = 0; index < ${#incremental_pvcs[@]}; index++)); do
    printf -v pass '%02d' "$((index + 1))"
    pvc="${incremental_pvcs[$index]}"
    printf '    - name: incremental-p%s\n      persistentVolumeClaim:\n        claimName: %s\n        readOnly: true\n' \
      "$pass" "$pvc" >> "$volumes_file"
    printf '        - name: incremental-p%s\n          mountPath: /backups/incrementals/p%s\n          readOnly: true\n' \
      "$pass" "$pass" >> "$mounts_file"
  done
  awk -v volumes_file="$volumes_file" -v mounts_file="$mounts_file" '
    /^[[:space:]]*#[[:space:]]__INCREMENTAL_VOLUMES__[[:space:]]*$/ {
      while ((getline line < volumes_file) > 0) print line
      close(volumes_file)
      next
    }
    /^[[:space:]]*#[[:space:]]__INCREMENTAL_MOUNTS__[[:space:]]*$/ {
      while ((getline line < mounts_file) > 0) print line
      close(mounts_file)
      next
    }
    { print }
  ' "$restore_manifest" > "$rendered"

  workflow_action "oc apply restore verifier $RESTORE_POD_NAME with full PVC $full_pvc and ${#incremental_pvcs[@]} ordered incremental PVC(s)"
  sed \
    -e "s|__POD_NAME__|$RESTORE_POD_NAME|g" \
    -e "s|__NAMESPACE__|$NAMESPACE|g" \
    -e "s|__FULL_PVC__|$full_pvc|g" \
    -e "s|__HELPER_IMAGE__|$RESTORE_HELPER_IMAGE|g" \
    -e "s|__WORKLOAD_DIR__|$RESTORE_WORKLOAD_MOUNT_DIR|g" \
    -e "s|__INCREMENTAL_COUNT__|${#incremental_pvcs[@]}|g" \
    -e "s|__RUN_ID__|$RUN_ID|g" \
    -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
    -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
    -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
    "$rendered" | oc_cmd apply -f - >/dev/null

  local phase='' attempt
  local timeout_minutes=$((RESTORE_VERIFY_TIMEOUT_SECONDS / 60))
  workflow_progress "Waiting for pod/$RESTORE_POD_NAME to reach Succeeded or Failed (timeout ${timeout_minutes}m)"
  for ((attempt = 1; attempt <= RESTORE_VERIFY_TIMEOUT_SECONDS; attempt++)); do
    phase="$(oc_cmd get pod "$RESTORE_POD_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.phase}' 2>/dev/null || echo '')"
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    if ((attempt % 30 == 0)); then
      workflow_progress "Restore-verification pod remains ${phase:-unknown} after ${attempt}s"
    fi
    sleep 1
  done
  RESTORE_POD_PHASE="${phase:-unknown}"

  if [[ "$phase" != Succeeded ]]; then
    if [[ "$phase" == Failed ]]; then
      printf 'Restore-verify pod failed (phase Failed); logs follow.\n' >&2
    else
      printf 'Restore-verify pod did not reach Succeeded within %s seconds (current phase: %s); logs follow.\n' \
        "$RESTORE_VERIFY_TIMEOUT_SECONDS" "$RESTORE_POD_PHASE" >&2
    fi
    oc_cmd logs "pod/$RESTORE_POD_NAME" -n "$NAMESPACE" >&2 || true
    collect_pod_log "$RESTORE_POD_NAME" "restore-verify-pod.log"
    return 1
  fi

  collect_pod_log "$RESTORE_POD_NAME" "restore-verify-pod.log"
  oc_cmd logs "pod/$RESTORE_POD_NAME" -n "$NAMESPACE"
}

# Read a "KEY=value" line out of the pod log captured by run_restore_verify_pod.
restore_log_field() {
  local log="$1" key="$2"
  sed -n "s/^${key}=//p" <<<"$log" | tail -n1
}

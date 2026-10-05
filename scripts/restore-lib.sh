#!/usr/bin/env bash
# Helpers for scripts/vm-cbt-restore-test.sh: run a short-lived pod that
# reconstructs guest disks from the backup PVCs (qemu-img rebase/convert)
# and reads the guest file from ext4 (Debian) or NTFS (Windows), without
# booting a second VM.
set -euo pipefail

# RESTORE_POD_NAME is derived from the current run ID by common.sh's
# set_resource_names (via load_run_id/new_run_id).
# No default: this image must provide qemu-img and util-linux (see
# images/restore-helper/Dockerfile), plus ntfs-3g for Windows restores. Build
# it and set RESTORE_HELPER_IMAGE in .env to your pushed reference.
# shellcheck disable=SC2034
RESTORE_HELPER_IMAGE="${RESTORE_HELPER_IMAGE:-}"

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
  local full_pvc="$1" incremental_pvc="$2" restore_manifest
  if [[ "$VM_OS" == windows ]]; then
    restore_manifest="$ROOT_DIR/manifests/windows-restore-verify-pod.yaml"
  else
    restore_manifest="$ROOT_DIR/manifests/restore-verify-pod.yaml"
  fi

  delete_restore_pod
  trap delete_restore_pod RETURN

  workflow_action "oc apply -f $restore_manifest (pod $RESTORE_POD_NAME mounts $full_pvc and $incremental_pvc read-only)"
  sed \
    -e "s|__POD_NAME__|$RESTORE_POD_NAME|g" \
    -e "s|__NAMESPACE__|$NAMESPACE|g" \
    -e "s|__FULL_PVC__|$full_pvc|g" \
    -e "s|__INCREMENTAL_PVC__|$incremental_pvc|g" \
    -e "s|__HELPER_IMAGE__|$RESTORE_HELPER_IMAGE|g" \
    -e "s|__WORKLOAD_DIR__|$RESTORE_WORKLOAD_MOUNT_DIR|g" \
    -e "s|__RUN_ID__|$RUN_ID|g" \
    -e "s|__MANAGED_BY_KEY__|$RUN_LABEL_MANAGED_BY_KEY|g" \
    -e "s|__MANAGED_BY_VALUE__|$RUN_LABEL_MANAGED_BY_VALUE|g" \
    -e "s|__RUN_ID_LABEL_KEY__|$RUN_LABEL_RUN_ID_KEY|g" \
    "$restore_manifest" | oc_cmd apply -f -

  workflow_action "Waiting for pod/$RESTORE_POD_NAME to reach phase Succeeded or Failed (timeout 10m)"
  local phase='' attempt
  for ((attempt = 1; attempt <= 600; attempt++)); do
    phase="$(oc_cmd get pod "$RESTORE_POD_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.phase}' 2>/dev/null || echo '')"
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 1
  done

  if [[ "$phase" != Succeeded ]]; then
    printf 'Restore-verify pod ended in phase %s (expected Succeeded); logs follow.\n' "${phase:-unknown}" >&2
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

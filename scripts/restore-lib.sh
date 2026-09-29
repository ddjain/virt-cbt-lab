#!/usr/bin/env bash
# Helpers for scripts/vm-cbt-restore-test.sh: run a short-lived pod that
# reconstructs the guest disk from the backup PVCs (qemu-img rebase/convert)
# and reads the guest file with `btrfs restore`, without booting a second VM.
set -euo pipefail

RESTORE_POD_NAME="hello-restore-verify"
# No default: this image must provide qemu-img and btrfs-progs (see
# images/restore-helper/Dockerfile). Build it and set RESTORE_HELPER_IMAGE in
# .env to your pushed reference; there is no generic public image that
# reliably reads a btrfs guest filesystem, since that needs userspace
# `btrfs restore` rather than a mountable kernel module.
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
  local full_pvc="$1" incremental_pvc="$2"

  delete_restore_pod
  trap delete_restore_pod RETURN

  workflow_action "oc apply -f manifests/restore-verify-pod.yaml (pod $RESTORE_POD_NAME mounts $full_pvc and $incremental_pvc read-only)"
  sed \
    -e "s|__POD_NAME__|$RESTORE_POD_NAME|g" \
    -e "s|__NAMESPACE__|$NAMESPACE|g" \
    -e "s|__FULL_PVC__|$full_pvc|g" \
    -e "s|__INCREMENTAL_PVC__|$incremental_pvc|g" \
    -e "s|__HELPER_IMAGE__|$RESTORE_HELPER_IMAGE|g" \
    -e "s|__HELLO_FILE__|$GUEST_HELLO_FILE|g" \
    -e "s|__MARKER_LINE__|$CBT_INCREMENTAL_MARKER_LINE|g" \
    "$ROOT_DIR/manifests/restore-verify-pod.yaml" | oc_cmd apply -f -

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
    return 1
  fi

  oc_cmd logs "pod/$RESTORE_POD_NAME" -n "$NAMESPACE"
}

# Read a "KEY=value" line out of the pod log captured by run_restore_verify_pod.
restore_log_field() {
  local log="$1" key="$2"
  sed -n "s/^${key}=//p" <<<"$log" | tail -n1
}

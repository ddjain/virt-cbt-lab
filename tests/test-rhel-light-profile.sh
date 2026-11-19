#!/usr/bin/env bash
set -euo pipefail
# Offline: VM_OS=rhel9-light resolves right-sized PVCs and its own DataSource,
# honors RHEL_LIGHT_* overrides, never inherits rhel9's VM_DATA_SOURCE_NAME or
# INCREMENTAL_PVC_SIZE, and leaves the rhel9 profile untouched.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/bin/oc"
chmod +x "$TEST_TMP/bin/oc"
PATH="$TEST_TMP/bin:$PATH"
export PATH
unset KUBECONFIG KUBECONFIG_PATH VM_OS MANIFEST_VARIANT VM_DATA_SOURCE_NAME INCREMENTAL_PVC_SIZE \
  RHEL_LIGHT_ROOT_SIZE RHEL_LIGHT_FULL_BACKUP_SIZE RHEL_LIGHT_INCREMENTAL_PVC_SIZE \
  RHEL_LIGHT_DATA_SOURCE_NAME RHEL_LIGHT_DATA_SOURCE_NAMESPACE \
  GUEST_BASE_FILE_COUNT GUEST_INCREMENTAL_FILE_COUNT GUEST_INCREMENTAL_PASSES \
  GUEST_FILE_SIZE_MIN_MIB GUEST_FILE_SIZE_MAX_MIB || true

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Defaults are the measured right-sized profile, on both backends.
for variant in large-odf large; do
  (
    VM_OS=rhel9-light MANIFEST_VARIANT="$variant"
    source "$ROOT_DIR/scripts/common.sh"
    [[ "$LARGE_MANIFEST_DISK_SIZE" == 10Gi ]] || fail "root $LARGE_MANIFEST_DISK_SIZE ($variant)"
    [[ "$FULL_BACKUP_DISK_SIZE" == 12Gi ]] || fail "full $FULL_BACKUP_DISK_SIZE ($variant)"
    [[ "$INCREMENTAL_PVC_SIZE" == 2Gi ]] || fail "incremental $INCREMENTAL_PVC_SIZE ($variant)"
    [[ "$VM_DATA_SOURCE_NAME" == rhel9-light && "$VM_DATA_SOURCE_NAMESPACE" == vm-cbt-images ]] \
      || fail "data source $VM_DATA_SOURCE_NAME/$VM_DATA_SOURCE_NAMESPACE ($variant)"
    [[ "$GUEST_LINUX_GROUP" == wheel && "$GUEST_SSHD_SERVICE" == sshd ]] || fail "guest settings ($variant)"
  )
done

# The ODF large manifests (not Debian's) are selected, like rhel9.
(
  VM_OS=rhel9-light MANIFEST_VARIANT=large-odf
  source "$ROOT_DIR/scripts/common.sh"
  [[ "$(manifest_path vm)" == "$ROOT_DIR/manifests/vm-large-odf.yaml" ]] || fail "manifest_path vm"
)

# rhel9-only settings must not leak into the light profile, and overrides win.
(
  VM_OS=rhel9-light VM_DATA_SOURCE_NAME=rhel9-rbd INCREMENTAL_PVC_SIZE=50Gi
  RHEL_LIGHT_ROOT_SIZE=12Gi RHEL_LIGHT_FULL_BACKUP_SIZE=14Gi RHEL_LIGHT_INCREMENTAL_PVC_SIZE=3Gi
  RHEL_LIGHT_DATA_SOURCE_NAME=custom-light RHEL_LIGHT_DATA_SOURCE_NAMESPACE=custom-ns
  source "$ROOT_DIR/scripts/common.sh"
  [[ "$LARGE_MANIFEST_DISK_SIZE" == 12Gi && "$FULL_BACKUP_DISK_SIZE" == 14Gi ]] || fail "size overrides"
  [[ "$INCREMENTAL_PVC_SIZE" == 3Gi ]] || fail "INCREMENTAL_PVC_SIZE leaked: $INCREMENTAL_PVC_SIZE"
  [[ "$VM_DATA_SOURCE_NAME" == custom-light && "$VM_DATA_SOURCE_NAMESPACE" == custom-ns ]] \
    || fail "data source override: $VM_DATA_SOURCE_NAME/$VM_DATA_SOURCE_NAMESPACE"
)
(
  VM_OS=rhel9-light VM_DATA_SOURCE_NAME=rhel9-rbd
  source "$ROOT_DIR/scripts/common.sh"
  [[ "$VM_DATA_SOURCE_NAME" == rhel9-light ]] || fail "rhel9 VM_DATA_SOURCE_NAME inherited"
)

# rhel9 stays 80/90/30 on the same variant.
(
  VM_OS=rhel9 MANIFEST_VARIANT=large-odf
  source "$ROOT_DIR/scripts/common.sh"
  [[ "$LARGE_MANIFEST_DISK_SIZE" == 80Gi && "$FULL_BACKUP_DISK_SIZE" == 90Gi && "$INCREMENTAL_PVC_SIZE" == 30Gi ]] \
    || fail "rhel9 sizes changed"
)

# The workload-fit guard accepts the demo workload, rejects one sized for the
# 80Gi profile (the failure seen on the first cluster run), and follows the root size.
(
  VM_OS=rhel9-light
  source "$ROOT_DIR/scripts/common.sh"
  check_rhel_light_workload_fits || fail "guard rejected the default demo workload"
)
(
  VM_OS=rhel9-light GUEST_BASE_FILE_COUNT=1000 GUEST_INCREMENTAL_FILE_COUNT=1000
  GUEST_FILE_SIZE_MIN_MIB=15 GUEST_FILE_SIZE_MAX_MIB=20
  source "$ROOT_DIR/scripts/common.sh"
  if check_rhel_light_workload_fits 2>"$TEST_TMP/guard.err"; then fail "guard accepted a 1000x20MiB workload on a 10Gi root"; fi
  grep -q 'exceeds' "$TEST_TMP/guard.err" || fail "guard gave no actionable message"
)
(
  VM_OS=rhel9-light GUEST_BASE_FILE_COUNT=100 GUEST_INCREMENTAL_FILE_COUNT=1 GUEST_FILE_SIZE_MAX_MIB=100
  source "$ROOT_DIR/scripts/common.sh"
  if check_rhel_light_workload_fits 2>/dev/null; then fail "10000MiB accepted on a 10Gi root"; fi
  RHEL_LIGHT_ROOT_SIZE=20Gi
  LARGE_MANIFEST_DISK_SIZE=20Gi
  check_rhel_light_workload_fits || fail "guard ignored the larger root"
)

# The Makefile accepts the profile and still rejects unknown ones.
make -C "$ROOT_DIR" help VM_OS=rhel9-light >/dev/null 2>&1 || fail "make rejects VM_OS=rhel9-light"
if make -C "$ROOT_DIR" help VM_OS=rhel9-bogus >/dev/null 2>&1; then fail "make accepted a bogus VM_OS"; fi

printf 'PASS: rhel9-light profile\n'

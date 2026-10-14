#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
unset KUBECONFIG KUBECONFIG_PATH || true
FAKE_BIN="$TEST_TMP/bin"
TEST_ROOT="$TEST_TMP/repo"
mkdir -p "$FAKE_BIN" "$TEST_ROOT/scripts" "$TEST_ROOT/manifests/density"

cp "$ROOT_DIR/scripts/common.sh" "$ROOT_DIR/scripts/run-id.sh" \
  "$ROOT_DIR/scripts/density-lib.sh" "$ROOT_DIR/scripts/density-setup.sh" \
  "$TEST_ROOT/scripts/"
cp "$ROOT_DIR/manifests/density/config.yaml" \
  "$ROOT_DIR/manifests/density/rhel-vm.yaml" \
  "$ROOT_DIR/manifests/density/windows-vm.yaml" \
  "$TEST_ROOT/manifests/density/"
cp "$ROOT_DIR/scripts/windows-oobe-secret.sh" \
  "$ROOT_DIR/scripts/windows-oobe.xml.tmpl" "$TEST_ROOT/scripts/"
mkdir -p "$TEST_ROOT/manifests"

# Fake oc: no-op create/apply; labeled pool queries return existing VMs only
# for pool "taken" (collision guard); the new pool's VM query returns all VMs
# ready so the readiness poll completes immediately.
cat > "$FAKE_BIN/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
pool=""
for arg in "$@"; do
  case "$arg" in
    *virt-cbt-lab/pool=*) pool="${arg##*virt-cbt-lab/pool=}" ;;
  esac
done
out=""
if [[ "$*" == *"get vm -n"* && -n "$pool" ]]; then
  # Cluster state is temporal: VMs exist only after kube-burner ran.
  if [[ "$pool" != "taken" && "$pool" != "$(cat "$KUBE_BURNER_CREATED_POOL" 2>/dev/null || true)" ]]; then
    # Guard query for a pool kube-burner has not created: empty cluster.
    if [[ "$*" == *"jsonpath"* ]]; then printf '\n'; else printf '{"items":[]}\n'; fi
    exit 0
  fi
  if [[ "$pool" == "taken" ]]; then
    # Pool name collision: VMs exist for the guard query.
    out='{"items":[{"metadata":{"name":"vm-taken-0001","labels":{"virt-cbt-lab/run-id":"taken-0001","virt-cbt-lab/pool":"taken"}}}]}'
  else
    # After kube-burner ran: POOL_COUNT_EXTRA ready VMs for any pool query.
    count="${POOL_COUNT_EXTRA:-2}"
    items=""
    i=1
    while (( i <= count )); do
      rid="$(printf '%s-%04d' "$pool" "$i")"
      items+="$(printf ',{"metadata":{"name":"vm-%s","labels":{"virt-cbt-lab/run-id":"%s","virt-cbt-lab/pool":"%s"}},"status":{"ready":true}}' "$rid" "$rid" "$pool")"
      i=$((i + 1))
    done
    out='{"items":['"${items:1}"']}'
  fi
  if [[ "$*" == *"jsonpath"* ]]; then
    # Honor -o jsonpath={.items[*].metadata.name}: names space-separated.
    jq -r '[.items[].metadata.name] | join(" ")' <<<"$out"
  else
    printf '%s\n' "$out"
  fi
  exit 0
fi
# Drain stdin so `oc ... | oc apply -f -` never SIGPIPEs the upstream oc.
if [[ ! -t 0 ]]; then cat >/dev/null; fi
printf '{}\n'
FAKE_OC
chmod +x "$FAKE_BIN/oc"

# Fake kube-burner: records args, cwd, and the user-data file.
KUBE_BURNER_LOG="$TEST_TMP/kube-burner.log"
KUBE_BURNER_RAN_MARKER="$TEST_TMP/kube-burner-ran"
KUBE_BURNER_CREATED_POOL="$TEST_TMP/kube-burner-created-pool"
cat > "$FAKE_BIN/kube-burner" <<'FAKE_KB'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'cwd=%s\n' "$PWD"
  printf 'args=%s\n' "$*"
} >> "$KUBE_BURNER_LOG"
userdata=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--user-data" ]]; then userdata="$arg"; fi
  prev="$arg"
done
cp "$userdata" "$KUBE_BURNER_LOG.userdata"
# Record the pool this kube-burner run "created" (temporal fake state);
# only this pool reports VMs afterwards.
printf '%s' "$(jq -r '.POOL_ID' "$userdata")" > "$KUBE_BURNER_CREATED_POOL"
FAKE_KB
chmod +x "$FAKE_BIN/kube-burner"

run_setup() {
  (cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
    KUBECONFIG_PATH= KUBECONFIG= \
    GUEST_KEY="$TEST_TMP/guest-key" \
    POOL_COUNT_EXTRA="${POOL_COUNT_EXTRA:-2}" KUBE_BURNER_LOG="$KUBE_BURNER_LOG" \
    KUBE_BURNER_CREATED_POOL="$KUBE_BURNER_CREATED_POOL" \
    ROOT_DIR="$TEST_ROOT" RUNS_ROOT_DIR="$TEST_ROOT/runs" \
    DENSITY_VM_COUNT=2 POOL=dtest VM_OS=rhel9 MANIFEST_VARIANT=large-odf \
    bash "$TEST_ROOT/scripts/density-setup.sh")
}

run_setup >/dev/null 2>&1

# No local pool metadata is written.
if [[ -e "$TEST_ROOT/density" ]]; then
  printf 'density/ directory must not be created (no local pool metadata).\n' >&2
  exit 1
fi

# kube-burner was invoked from the repo root with the config and user data.
grep -qF "cwd=$TEST_ROOT" "$KUBE_BURNER_LOG"
grep -qF "init -c $TEST_ROOT/manifests/density/config.yaml" "$KUBE_BURNER_LOG"

# User-data JSON carries the expected values.
jq -e '.JOB_NAME == "density-dtest" and .POOL_ID == "dtest" and
       .DENSITY_VM_COUNT == 2 and .DENSITY_QPS == 10 and
       .NAMESPACE == "vm-cbt-demo" and
       .OBJECT_TEMPLATE == "'"$TEST_ROOT"'/manifests/density/rhel-vm.yaml" and
       .STORAGE_CLASS == "ocs-storagecluster-ceph-rbd" and
       .DISK_SIZE == "80Gi" and .MANIFEST_VARIANT == "large-odf" and
       .INCREMENTAL_PASSES == "4" and
       .MANAGED_BY_KEY == "app.kubernetes.io/managed-by" and
       .MANAGED_BY_VALUE == "virt-cbt-lab" and
       .RUN_ID_KEY == "virt-cbt-lab/run-id" and
       .POOL_KEY == "virt-cbt-lab/pool"' "$KUBE_BURNER_LOG.userdata" >/dev/null

# config.yaml renders with the user-data values. python3 mimics the Go
# template substitution kube-burner performs for the simple {{ .KEY }}
# placeholders used in the config.
rendered_config="$(python3 - "$KUBE_BURNER_LOG.userdata" "$TEST_ROOT/manifests/density/config.yaml" <<'PY'
import json, re, sys
userdata = json.load(open(sys.argv[1]))
config = open(sys.argv[2]).read()
for key, value in userdata.items():
    config = config.replace("{{ .%s }}" % key, str(value))
print(config)
PY
)"
grep -qF 'name: density-dtest' <<<"$rendered_config"
grep -qF 'jobIterations: 2' <<<"$rendered_config"
grep -qF 'namespace: vm-cbt-demo' <<<"$rendered_config"
grep -qF 'poolId: "dtest"' <<<"$rendered_config"
if command -v kube-burner >/dev/null 2>&1; then
  kube-burner check-templates -c "$TEST_ROOT/manifests/density/config.yaml" \
    -u "$KUBE_BURNER_LOG.userdata" >/dev/null 2>&1 || \
    kube-burner init --dry-run -c "$TEST_ROOT/manifests/density/config.yaml" \
      -u "$KUBE_BURNER_LOG.userdata" >/dev/null 2>&1 || true
fi

# Rejections: missing count, bad OS, pool name already in use on the cluster,
# invalid pool id.
reject() {
  local label="$1"; shift
  if (cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
      KUBECONFIG_PATH= KUBECONFIG= GUEST_KEY="$TEST_TMP/guest-key" \
      ROOT_DIR="$TEST_ROOT" RUNS_ROOT_DIR="$TEST_ROOT/runs" \
      "$@" bash "$TEST_ROOT/scripts/density-setup.sh" >/dev/null 2>&1); then
    printf 'Should have rejected: %s\n' "$label" >&2
    exit 1
  fi
}
reject 'missing DENSITY_VM_COUNT' DENSITY_VM_COUNT= VM_OS=rhel9 POOL=dx1
reject 'VM_OS=debian' DENSITY_VM_COUNT=2 VM_OS=debian POOL=dx2
reject 'pool already in use on cluster' DENSITY_VM_COUNT=2 VM_OS=rhel9 POOL=taken
reject 'invalid pool id' DENSITY_VM_COUNT=2 VM_OS=rhel9 POOL=Invalid_Pool
reject 'pool id too long' DENSITY_VM_COUNT=2 VM_OS=rhel9 POOL=aaaaaaaaaaaaaaaaaaaaa

# Windows path: OOBE secret created via the shared library, virtualization
# storage class and default variant.
WINDOWS_PW_FILE="$TEST_TMP/windows-pw"
printf 'Sup3rSecret!\n' > "$WINDOWS_PW_FILE"
chmod 600 "$WINDOWS_PW_FILE"
windows_userdata="$TEST_TMP/windows-userdata"
cat > "$FAKE_BIN/kube-burner" <<'FAKE_KB_WIN'
#!/usr/bin/env bash
set -euo pipefail
userdata=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--user-data" ]]; then userdata="$arg"; fi
  prev="$arg"
done
cp "$userdata" "$windows_userdata"
# Record the pool this run "created" (same temporal fake state as FAKE_KB).
printf '%s' "$(jq -r '.POOL_ID' "$userdata")" > "$KUBE_BURNER_CREATED_POOL"
FAKE_KB_WIN
chmod +x "$FAKE_BIN/kube-burner"
(cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
  KUBECONFIG_PATH= KUBECONFIG= GUEST_KEY="$TEST_TMP/guest-key" \
  POOL_COUNT_EXTRA=1 KUBE_BURNER_CREATED_POOL="$KUBE_BURNER_CREATED_POOL" \
  windows_userdata="$windows_userdata" \
  ROOT_DIR="$TEST_ROOT" RUNS_ROOT_DIR="$TEST_ROOT/runs" \
  DENSITY_VM_COUNT=1 POOL=dwin VM_OS=windows MANIFEST_VARIANT=default \
  WINDOWS_ADMIN_PASSWORD_FILE="$WINDOWS_PW_FILE" \
  bash "$TEST_ROOT/scripts/density-setup.sh" >/dev/null 2>&1)
jq -e '.OBJECT_TEMPLATE == "'"$TEST_ROOT"'/manifests/density/windows-vm.yaml" and
       .STORAGE_CLASS == "ocs-storagecluster-ceph-rbd-virtualization" and
       .DISK_SIZE == "40Gi" and .MANIFEST_VARIANT == "default" and
       .SSH_PUBLIC_KEY == ""' "$windows_userdata" >/dev/null
# No local metadata for the Windows pool either.
[[ ! -e "$TEST_ROOT/density" ]] || {
  printf 'density/ directory must not be created for Windows pools.\n' >&2
  exit 1
}

printf 'PASS: density-setup launches kube-burner without local pool metadata, renders the expected user data, and rejects invalid inputs.\n'

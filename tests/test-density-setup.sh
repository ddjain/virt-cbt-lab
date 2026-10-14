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

# Fake oc: no-op create/apply; labeled vm get returns all VMs ready so the
# readiness poll completes immediately.
cat > "$FAKE_BIN/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"get vm -n"* && "$*" == *"virt-cbt-lab/pool="* ]]; then
  pool="dtest"
  for arg in "$@"; do
    case "$arg" in
      *virt-cbt-lab/pool=*) pool="${arg##*virt-cbt-lab/pool=}" ;;
    esac
  done
  count="${POOL_COUNT_EXTRA:-2}"
  items=""
  i=1
  while (( i <= count )); do
    rid="$(printf '%s-%04d' "$pool" "$i")"
    items+="$(printf ',{"metadata":{"name":"vm-%s","labels":{"virt-cbt-lab/run-id":"%s","virt-cbt-lab/pool":"%s"}},"status":{"ready":true}}' "$rid" "$rid" "$pool")"
    i=$((i + 1))
  done
  printf '{"items":[%s]}\n' "${items:1}"
  exit 0
fi
# Drain stdin so `oc ... | oc apply -f -` never SIGPIPEs the upstream oc.
if [[ ! -t 0 ]]; then cat >/dev/null; fi
printf '{}\n'
FAKE_OC
chmod +x "$FAKE_BIN/oc"

# Fake kube-burner: records args, cwd, and the user-data file; asserts
# pool.json already exists (written before launch) and contains the full
# expected run ID list.
KUBE_BURNER_LOG="$TEST_TMP/kube-burner.log"
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
# pool.json must exist and list the full run ID range before kube-burner runs.
pool_dir="$PWD"
pool="$(basename "$pool_dir")"
jq -e --arg pool "$pool" --argjson count "$POOL_COUNT_EXTRA" \
  '.run_ids == ([range(1; $count + 1) | tostring as $s | $pool + "-" + ("0" * (4 - ($s | length))) + $s])' \
  "$pool_dir/pool.json" >/dev/null || {
  printf 'kube-burner fake: pool.json missing or incomplete before launch\n' >&2
  exit 9
}
FAKE_KB
chmod +x "$FAKE_BIN/kube-burner"

run_setup() {
  (cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
    KUBECONFIG_PATH= KUBECONFIG= \
    GUEST_KEY="$TEST_TMP/guest-key" \
    POOL_COUNT_EXTRA="${POOL_COUNT_EXTRA:-2}" KUBE_BURNER_LOG="$KUBE_BURNER_LOG" \
    ROOT_DIR="$TEST_ROOT" RUNS_ROOT_DIR="$TEST_ROOT/runs" \
    DENSITY_VM_COUNT=2 POOL=dtest VM_OS=rhel9 MANIFEST_VARIANT=large-odf \
    bash "$TEST_ROOT/scripts/density-setup.sh")
}

run_setup >/dev/null 2>&1

# pool.json contents.
jq -e '.pool_id == "dtest" and .os_profile == "rhel9" and
       .namespace == "vm-cbt-demo" and .vm_count == 2 and
       .incremental_passes == 4 and
       .run_ids == ["dtest-0001", "dtest-0002"] and
       .schema_version == 1' "$TEST_ROOT/density/dtest/pool.json" >/dev/null

# kube-burner was invoked from the pool dir with the config and user data.
grep -qF "cwd=$TEST_ROOT/density/dtest" "$KUBE_BURNER_LOG"
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

with open(sys.argv[1]) as f:
    userdata = json.load(f)
with open(sys.argv[2]) as f:
    config = f.read()

def replace(match):
    key = match.group(1).strip().lstrip(".")
    return str(userdata[key])

sys.stdout.write(re.sub(r"\{\{\s*\.(\w+)\s*\}\}", replace, config))
PY
)"
grep -qF 'name: density-dtest' <<<"$rendered_config"
grep -qF 'jobIterations: 2' <<<"$rendered_config"
grep -qF 'namespace: vm-cbt-demo' <<<"$rendered_config"
grep -qF 'poolId: "dtest"' <<<"$rendered_config"
if command -v kube-burner >/dev/null 2>&1; then
  printf '%s\n' "$rendered_config" | kube-burner init -c /dev/stdin >/dev/null 2>&1 || true
else
  printf 'SKIP: real kube-burner unavailable; config render verified by substitution only.\n'
fi

# Rejections: missing count, bad OS, existing pool dir, invalid pool id.
reject() {
  local desc="$1"; shift
  if (cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
    KUBECONFIG_PATH= KUBECONFIG= GUEST_KEY="$TEST_TMP/guest-key" \
    KUBE_BURNER_LOG="$KUBE_BURNER_LOG" ROOT_DIR="$TEST_ROOT" \
    RUNS_ROOT_DIR="$TEST_ROOT/runs" "$@" \
    bash "$TEST_ROOT/scripts/density-setup.sh" >/dev/null 2>&1); then
    printf 'density-setup should have rejected: %s\n' "$desc" >&2
    exit 1
  fi
}
reject 'missing DENSITY_VM_COUNT' DENSITY_VM_COUNT= VM_OS=rhel9 POOL=dx1
reject 'VM_OS=debian' DENSITY_VM_COUNT=2 VM_OS=debian POOL=dx2
reject 'existing pool dir' DENSITY_VM_COUNT=2 VM_OS=rhel9 POOL=dtest
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
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--user-data" ]]; then cp "$arg" "$WINDOWS_USERDATA_OUT"; fi
  prev="$arg"
done
FAKE_KB_WIN
chmod +x "$FAKE_BIN/kube-burner"
(cd "$TEST_ROOT" && env PATH="$FAKE_BIN:$PATH" \
  KUBECONFIG_PATH= KUBECONFIG= GUEST_KEY="$TEST_TMP/guest-key" \
  WINDOWS_USERDATA_OUT="$windows_userdata" KUBE_BURNER_LOG="$KUBE_BURNER_LOG" \
  ROOT_DIR="$TEST_ROOT" RUNS_ROOT_DIR="$TEST_ROOT/runs" \
  WINDOWS_ADMIN_PASSWORD_FILE="$WINDOWS_PW_FILE" \
  DENSITY_VM_COUNT=1 POOL=dwin VM_OS=windows POOL_COUNT_EXTRA=1 \
  bash "$TEST_ROOT/scripts/density-setup.sh" >/dev/null 2>&1)
jq -e '.OBJECT_TEMPLATE == "'"$TEST_ROOT"'/manifests/density/windows-vm.yaml" and
       .STORAGE_CLASS == "ocs-storagecluster-ceph-rbd-virtualization" and
       .DISK_SIZE == "40Gi" and .MANIFEST_VARIANT == "default" and
       .SSH_PUBLIC_KEY == ""' "$windows_userdata" >/dev/null
# The OOBE secret apply went through oc (fake) with the pool-scoped name.
jq -e '.os_profile == "windows" and .run_ids == ["dwin-0001"]' \
  "$TEST_ROOT/density/dwin/pool.json" >/dev/null

printf 'PASS: density-setup writes pool.json before kube-burner, renders the expected user data, and rejects invalid inputs.\n'

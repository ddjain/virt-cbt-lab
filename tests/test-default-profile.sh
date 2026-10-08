#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
FAKE_BIN="$TEST_TMP/bin"
MAKE_DIR="$TEST_TMP/make-defaults"
mkdir -p "$FAKE_BIN" "$MAKE_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/oc"
chmod +x "$FAKE_BIN/oc"
PATH="$FAKE_BIN:$PATH"
export PATH
unset KUBECONFIG KUBECONFIG_PATH VM_OS MANIFEST_VARIANT || true

(
  source "$ROOT_DIR/scripts/common.sh"
  [[ "$VM_OS" == rhel9 ]]
  [[ "$MANIFEST_VARIANT" == large-odf ]]
  [[ "$LARGE_MANIFEST_DISK_SIZE" == 80Gi ]]
  [[ "$(manifest_path vm)" == "$ROOT_DIR/manifests/vm-large-odf.yaml" ]]
)
(
  VM_OS=debian
  MANIFEST_VARIANT=odf
  source "$ROOT_DIR/scripts/common.sh"
  [[ "$VM_OS" == debian ]]
  [[ "$MANIFEST_VARIANT" == odf ]]
  [[ "$LARGE_MANIFEST_DISK_SIZE" == 48Gi ]]
  [[ "$(manifest_path vm)" == "$ROOT_DIR/manifests/vm-odf.yaml" ]]
)

cp "$ROOT_DIR/Makefile" "$MAKE_DIR/Makefile"
printf '%s\n' \
  '.PHONY: show-defaults' \
  'show-defaults:' \
  $'\t@printf "%s|%s|%s\\n" "$(VM_OS)" "$(MANIFEST_VARIANT)" "$(GUEST_INCREMENTAL_PASSES)"' \
  > "$MAKE_DIR/print-config.mk"
make_defaults="$(VM_OS= MANIFEST_VARIANT= GUEST_INCREMENTAL_PASSES= \
  make --silent -C "$MAKE_DIR" -f Makefile -f print-config.mk show-defaults)"
if [[ "$make_defaults" != 'rhel9|large-odf|1' ]]; then
  printf 'Unexpected Make defaults: %s\n' "$make_defaults" >&2
  exit 1
fi
printf 'PASS: RHEL 9/large-ODF are the default profile; Debian/ODF overrides resolve to their manifests and sizing.\n'

ALIAS_DIR="$TEST_TMP/incremental-alias"
mkdir -p "$ALIAS_DIR/scripts"
cp "$ROOT_DIR/Makefile" "$ALIAS_DIR/Makefile"
cat > "$ALIAS_DIR/scripts/e2e-stage.sh" <<'STAGE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "$TYPE" "$VM"
STAGE
chmod +x "$ALIAS_DIR/scripts/e2e-stage.sh"
alias_output="$(make --silent -C "$ALIAS_DIR" e2e-incremental \
  TYPE=full VM=vm-alias-test)"
if [[ "$alias_output" != 'incremental|vm-alias-test' ]]; then
  printf 'Semantic incremental target did not force TYPE=incremental or preserve VM.\n%s\n' \
    "$alias_output" >&2
  exit 1
fi
printf 'PASS: make e2e-incremental selects the incremental stage while preserving its VM.\n'

STAGE_DIR="$TEST_TMP/stage-checkout"
mkdir -p "$STAGE_DIR/scripts"
cp "$ROOT_DIR/scripts/e2e-stage.sh" "$STAGE_DIR/scripts/e2e-stage.sh"
cp "$ROOT_DIR/scripts/run-id.sh" "$STAGE_DIR/scripts/run-id.sh"
FAKE_MAKE="$TEST_TMP/fake-make"
cat > "$FAKE_MAKE" <<'FAKE_MAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MAKE_LOG"
FAKE_MAKE
chmod +x "$FAKE_MAKE"

default_calls="$TEST_TMP/default-stage-calls"
env MAKE_COMMAND="$FAKE_MAKE" MAKE_LOG="$default_calls" \
  TYPE=full NAME=default-profile \
  bash "$STAGE_DIR/scripts/e2e-stage.sh" > "$TEST_TMP/default-stage.log" 2>&1
default_make_calls="$(cat "$default_calls")"
if [[ "$default_make_calls" != *'VM_OS=rhel9'* ||
      "$default_make_calls" != *'MANIFEST_VARIANT=large-odf'* ]]; then
  printf 'Staged defaults were not propagated to Make targets.\n%s\n' "$default_make_calls" >&2
  exit 1
fi

override_calls="$TEST_TMP/override-stage-calls"
env MAKE_COMMAND="$FAKE_MAKE" MAKE_LOG="$override_calls" \
  TYPE=full NAME=debian-profile VM_OS=debian MANIFEST_VARIANT=odf \
  bash "$STAGE_DIR/scripts/e2e-stage.sh" > "$TEST_TMP/override-stage.log" 2>&1
override_make_calls="$(cat "$override_calls")"
if [[ "$override_make_calls" != *'VM_OS=debian'* ||
      "$override_make_calls" != *'MANIFEST_VARIANT=odf'* ]]; then
  printf 'Explicit profile overrides were not propagated to Make targets.\n%s\n' "$override_make_calls" >&2
  exit 1
fi
printf 'PASS: Make and staged workflows default to RHEL 9/large-ODF and propagate explicit profile overrides.\n'

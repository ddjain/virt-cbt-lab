#!/usr/bin/env bash
# Shared Windows OOBE Secret builder. Sourced library — no top-level code.
# Used by scripts/windows-vm-setup.sh (run-scoped secret) and
# scripts/density-setup.sh (pool-scoped secret).
# Requires common.sh (oc_cmd, RUN_LABEL_* constants) and a readable
# WINDOWS_ADMIN_PASSWORD_FILE; callers must check the latter first.

create_windows_oobe_secret() {
  local secret_name="$1" label_key="$2" label_value="$3"
  local oobe_file
  oobe_file="$(mktemp)"
  chmod 600 "$oobe_file"
  trap 'rm -f "$oobe_file"' RETURN
  python3 - "$WINDOWS_ADMIN_PASSWORD_FILE" "$ROOT_DIR/scripts/windows-oobe.xml.tmpl" "$oobe_file" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

password_path, template_path, output_path = map(pathlib.Path, sys.argv[1:])
password = password_path.read_text(encoding="utf-8")
if password.endswith("\n"):
    password = password[:-1]
if password.endswith("\r"):
    password = password[:-1]
if not password or "\n" in password or "\r" in password:
    raise SystemExit("WINDOWS_ADMIN_PASSWORD_FILE must contain one non-empty password line")
template = template_path.read_text(encoding="utf-8")
if template.count("__ADMIN_PASSWORD__") != 1:
    raise SystemExit("Windows OOBE template must contain exactly one password placeholder")
rendered = template.replace("__ADMIN_PASSWORD__", escape(password))
ET.fromstring(rendered)
output_path.write_text(rendered, encoding="utf-8")
PY
  workflow_action "Create labeled Secret $secret_name with key unattend.xml (password never logged)"
  oc_cmd delete secret "$secret_name" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true
  oc_cmd create secret generic "$secret_name" -n "$NAMESPACE" \
    --from-file=unattend.xml="$oobe_file" \
    --dry-run=client -o json |
    jq --arg managed_key "$RUN_LABEL_MANAGED_BY_KEY" \
       --arg managed_value "$RUN_LABEL_MANAGED_BY_VALUE" \
       --arg extra_key "$label_key" \
       --arg extra_value "$label_value" \
       '.metadata.labels = {($managed_key): $managed_value, ($extra_key): $extra_value}' |
    oc_cmd apply -f - >/dev/null
  trap - RETURN
}

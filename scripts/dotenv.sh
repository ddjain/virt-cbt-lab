#!/usr/bin/env bash
set -euo pipefail
# Read only supported KEY=value lines; never execute the dotenv file.
load_dotenv_defaults() {
  local file="$1" line key value
  [[ -r "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(DEBUG|NAMESPACE|KUBECONFIG_PATH|GUEST_KEY|REMOTE_HOST|REMOTE_DIR|VM_OS|RESTORE_HELPER_IMAGE|GUEST_BASE_FILE_COUNT|GUEST_INCREMENTAL_FILE_COUNT|GUEST_INCREMENTAL_PASSES|EXTEND_TO_PASS|GUEST_FILE_SIZE_MIN_MIB|GUEST_FILE_SIZE_MAX_MIB|MANIFEST_VARIANT|WINDOWS_ISO_PATH|WINDOWS_ADMIN_PASSWORD_FILE)[[:space:]]*= ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${line#*=}"
    value="${value##[[:space:]]}"
    value="${value%%[[:space:]]}"
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then value="${value:1:${#value}-2}"; fi
    if [[ "$value" == \'*\' && "$value" == *\' ]]; then value="${value:1:${#value}-2}"; fi
    if [[ -z "${!key:-}" ]]; then
      printf -v "$key" '%s' "$value"
    fi
  done < "$file"
}

#!/usr/bin/env bash
set -euo pipefail
# Read only supported KEY=value lines; never execute the dotenv file.
load_dotenv_defaults() {
  local file="$1" line key value
  [[ -r "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(KUBECONFIG_PATH|GUEST_KEY|REMOTE_HOST|REMOTE_DIR|VM_OS|WINDOWS_ISO_PATH|WINDOWS_ADMIN_PASSWORD_FILE)[[:space:]]*= ]] || continue
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

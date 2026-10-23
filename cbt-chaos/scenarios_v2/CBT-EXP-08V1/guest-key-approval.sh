#!/usr/bin/env bash

# Return only the approval-visible key mode and, for an existing readable
# pair, a fingerprint of its public half. Never open or copy the private key.
guest_key_approval_parameters() {
  local private_path="$1" public_path="${1}.pub" digest

  if [[ -e "$private_path" || -L "$private_path" ]]; then
    if [[ ! -f "$private_path" || ! -r "$private_path" ]]; then
      printf 'configured guest private key is unreadable or not a regular file\n' >&2
      return 2
    fi
    if [[ -e "$public_path" || -L "$public_path" ]]; then
      if [[ ! -f "$public_path" || ! -r "$public_path" ]]; then
        printf 'configured guest public key is unreadable or not a regular file\n' >&2
        return 2
      fi
      digest="$(sha256sum "$public_path")" || return $?
      jq -cn --arg fingerprint "${digest%% *}" \
        '{mode:"existing-pair",public_sha256:$fingerprint}'
      return
    fi
  fi

  jq -cn '{mode:"setup-managed",public_sha256:null}'
}

# Called only after vm-setup has run. Its public fingerprint is evidence, not
# an input to the already-approved effective-parameter object.
guest_key_capture_after_setup() {
  local private_path="$1" public_path="${1}.pub" digest

  if [[ ! -f "$private_path" || ! -r "$private_path" ||
        ! -f "$public_path" || ! -r "$public_path" ]]; then
    printf 'guest key pair is unreadable or incomplete after setup\n' >&2
    return 2
  fi
  digest="$(sha256sum "$public_path")" || return $?
  printf '%s\n' "${digest%% *}"
}

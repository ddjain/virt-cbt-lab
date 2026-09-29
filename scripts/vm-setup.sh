#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_command ssh
require_command ssh-keygen

printf '[vm-setup] Checking the Fedora source and preparing guest access.\n' >&2
oc_cmd get datasource fedora -n openshift-virtualization-os-images >/dev/null
public_key="$(ensure_guest_key)"
printf '[vm-setup] Applying the VM and SSH service manifests.\n' >&2
# Inject only the public key; the private key stays outside the manifest.
sed "s|__SSH_PUBLIC_KEY__|$public_key|g" "$ROOT_DIR/manifests/vm.yaml" | oc_cmd apply -f -
printf '[vm-setup] Waiting for the VM and disk import to become ready.\n' >&2
oc_cmd wait "vm/$VM_NAME" -n "$NAMESPACE" --for=jsonpath='{.status.ready}'=true --timeout=20m

cbt_state="$(oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o 'jsonpath={.status.changedBlockTracking.state}')"
if [[ "$cbt_state" != Enabled ]]; then
  printf 'CBT is not enabled for %s (state: %s). Check the cluster CBT feature gate and VM label selector.\n' "$VM_NAME" "$cbt_state" >&2
  exit 1
fi

printf '[vm-setup] CBT is enabled; writing hello.txt and printing its SHA-256.\n' >&2
guest_ssh 'printf "%s\n" "Hello from the VM CBT demo." > ~/hello.txt; sha256sum ~/hello.txt'
printf '[vm-setup] Setup complete.\n' >&2

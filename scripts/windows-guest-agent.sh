#!/usr/bin/env bash
# QEMU Guest Agent command transport for the Windows guest. Commands are
# invoked directly through PowerShell; no SSH service or guest password login
# is needed after OOBE.
# shellcheck disable=SC2034
GUEST_EXEC_POLL_INTERVAL=2
GUEST_EXEC_POLL_ATTEMPTS=150 # ~5 minutes per command

require_command jq
require_command python3

decode_guest_output() {
  printf '%s' "$1" | python3 -c 'import base64,sys; payload=b"".join(sys.stdin.buffer.read().split()); sys.stdout.buffer.write(base64.b64decode(payload, validate=True))'
}

# Prints the virt-launcher pod name for a running VMI.
virt_launcher_pod() {
  local vmi_name="$1" namespace="$2"
  oc_cmd get pod -n "$namespace" \
    -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$vmi_name" \
    -o jsonpath='{.items[0].metadata.name}'
}

# Runs one QEMU Guest Agent command inside the VMI's virt-launcher pod.
qemu_agent_command() {
  local vmi_name="$1" namespace="$2" qmp_json="$3"
  local pod domain
  pod="$(virt_launcher_pod "$vmi_name" "$namespace")"
  if [[ -z "$pod" ]]; then
    printf 'No virt-launcher pod found for VMI %s/%s.\n' "$namespace" "$vmi_name" >&2
    return 1
  fi
  domain="${namespace}_${vmi_name}"
  oc_cmd exec -n "$namespace" "$pod" -c compute -- \
    virsh --quiet qemu-agent-command "$domain" "$qmp_json" --timeout 30
}
guest_file_write() {
  local vmi_name="$1" namespace="$2" guest_path="$3" contents="$4"
  local encoded open_request open_reply handle write_request write_reply close_request written
  encoded="$(printf '%s' "$contents" | python3 -c 'import base64,sys; print(base64.b64encode(sys.stdin.buffer.read()).decode("ascii"))')"
  open_request="$(jq -nc --arg path "$guest_path" \
    '{execute:"guest-file-open",arguments:{path:$path,mode:"w"}}')"
  open_reply="$(qemu_agent_command "$vmi_name" "$namespace" "$open_request")"
  handle="$(printf '%s' "$open_reply" | jq -r '.return // empty')"
  if ! [[ "$handle" =~ ^[0-9]+$ ]]; then
    printf 'QEMU Guest Agent did not open guest file %s.\n' "$guest_path" >&2
    return 1
  fi

  write_request="$(jq -nc --argjson handle "$handle" --arg data "$encoded" \
    '{execute:"guest-file-write",arguments:{handle:$handle,"buf-b64":$data}}')"
  if ! write_reply="$(qemu_agent_command "$vmi_name" "$namespace" "$write_request")"; then
    close_request="$(jq -nc --argjson handle "$handle" \
      '{execute:"guest-file-close",arguments:{handle:$handle}}')"
    qemu_agent_command "$vmi_name" "$namespace" "$close_request" >/dev/null 2>&1 || true
    return 1
  fi
  written="$(printf '%s' "$write_reply" | jq -r '.return.count // 0')"
  close_request="$(jq -nc --argjson handle "$handle" \
    '{execute:"guest-file-close",arguments:{handle:$handle}}')"
  qemu_agent_command "$vmi_name" "$namespace" "$close_request" >/dev/null
  if ! [[ "$written" =~ ^[1-9][0-9]*$ ]]; then
    printf 'QEMU Guest Agent wrote no bytes to guest file %s.\n' "$guest_path" >&2
    return 1
  fi
}

# Copy a tracked PowerShell script into the guest, run it, and remove the
# temporary guest copy on success or failure.
guest_exec_script() {
  local vmi_name="$1" namespace="$2" host_script="$3" guest_path="$4"
  local contents remove_command
  contents="$(cat "$host_script")"
  guest_file_write "$vmi_name" "$namespace" "$guest_path" "$contents"
  remove_command="Remove-Item -LiteralPath '$guest_path' -Force -ErrorAction SilentlyContinue"
  if ! guest_exec "$vmi_name" "$namespace" "& '$guest_path'"; then
    guest_exec "$vmi_name" "$namespace" "$remove_command" >/dev/null 2>&1 || true
    return 1
  fi
  guest_exec "$vmi_name" "$namespace" "$remove_command" >/dev/null
}


# Start a non-interactive PowerShell command and print its guest process ID.
guest_exec_start() {
  local vmi_name="$1" namespace="$2" powershell="$3"
  local exec_request exec_reply pid
  exec_request="$(jq -nc --arg command "$powershell" \
    '{execute:"guest-exec",arguments:{path:"powershell.exe",arg:["-NoLogo","-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-Command",$command],"capture-output":true}}')"
  exec_reply="$(qemu_agent_command "$vmi_name" "$namespace" "$exec_request")"
  pid="$(printf '%s' "$exec_reply" | jq -r '.return.pid // empty')"
  if [[ -z "$pid" ]]; then
    printf 'guest-exec did not return a pid. Reply: %s\n' "$exec_reply" >&2
    return 1
  fi
  printf '%s' "$pid"
}

# Wait for an existing guest process. Keeping launch and wait separate lets
# sysprep shut down Windows without requiring the guest agent to stay online.
guest_exec_wait() {
  local vmi_name="$1" namespace="$2" pid="$3"
  local status_request status_reply exited=false exitcode out_b64 err_b64 attempt
  status_request="$(jq -nc --argjson pid "$pid" \
    '{execute:"guest-exec-status",arguments:{pid:$pid}}')"
  for ((attempt = 1; attempt <= GUEST_EXEC_POLL_ATTEMPTS; attempt++)); do
    status_reply="$(qemu_agent_command "$vmi_name" "$namespace" "$status_request")"
    exited="$(printf '%s' "$status_reply" | jq -r '.return.exited // false')"
    if [[ "$exited" == true ]]; then
      break
    fi
    sleep "$GUEST_EXEC_POLL_INTERVAL"
  done
  if [[ "$exited" != true ]]; then
    printf 'guest-exec timed out waiting for pid %s to exit.\n' "$pid" >&2
    return 1
  fi
  exitcode="$(printf '%s' "$status_reply" | jq -r '.return.exitcode // -1')"
  out_b64="$(printf '%s' "$status_reply" | jq -r '.return["out-data"] // empty')"
  err_b64="$(printf '%s' "$status_reply" | jq -r '.return["err-data"] // empty')"
  if [[ -n "$out_b64" ]]; then
    decode_guest_output "$out_b64"
  fi
  if [[ "$exitcode" != 0 ]]; then
    printf 'guest-exec PowerShell command failed (exit %s).\n' "$exitcode" >&2
    if [[ -n "$err_b64" ]]; then
      decode_guest_output "$err_b64" >&2
    fi
    return 1
  fi
}

guest_exec() {
  local pid
  pid="$(guest_exec_start "$1" "$2" "$3")"
  guest_exec_wait "$1" "$2" "$pid"
}

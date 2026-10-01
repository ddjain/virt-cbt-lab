#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="windows-golden-image"
require_command curl
require_command python3

WINDOWS_IMAGES_NAMESPACE="vm-cbt-images"
WINDOWS_ISO_PATH="${WINDOWS_ISO_PATH:-}"
WINDOWS_ADMIN_PASSWORD_FILE="${WINDOWS_ADMIN_PASSWORD_FILE:-}"
VIRTIO_IMAGE_FALLBACK="registry.redhat.io/container-native-virtualization/virtio-win-rhel9@sha256:cc98b37978b84b5fe7127c08d52a09c8c136c61ae51085a3f3180e3e11275497"


# A published image is reusable without ISO or password inputs.
if oc_cmd get datasource windows-server-2022 -n "$WINDOWS_IMAGES_NAMESPACE" >/dev/null 2>&1; then
  printf '[windows-golden-image] DataSource windows-server-2022 already exists in %s; nothing to do.\n' \
    "$WINDOWS_IMAGES_NAMESPACE" >&2
  printf 'Delete it first (oc delete datasource/windows-server-2022 dv/windows-golden -n %s) to rebuild.\n' \
    "$WINDOWS_IMAGES_NAMESPACE" >&2
  exit 0
fi

if [[ -z "$WINDOWS_ADMIN_PASSWORD_FILE" || ! -r "$WINDOWS_ADMIN_PASSWORD_FILE" ]]; then
  printf 'Set WINDOWS_ADMIN_PASSWORD_FILE to a readable local password file (see .env.example).\n' >&2
  exit 1
fi

# Reuse a previously uploaded ISO PVC; the local ISO is only needed when CDI
# still needs an upload.
iso_phase="$(oc_cmd get dv windows-iso -n "$WINDOWS_IMAGES_NAMESPACE" \
  -o 'jsonpath={.status.phase}' 2>/dev/null || true)"
if [[ "$iso_phase" != "Succeeded" && ( -z "$WINDOWS_ISO_PATH" || ! -r "$WINDOWS_ISO_PATH" ) ]]; then
  printf 'WINDOWS_ISO_PATH must be readable when DataVolume windows-iso is not Succeeded.\n' >&2
  exit 1
fi
INSTALLER_VMI_RUNNING=false
installer_phase="$(oc_cmd get vmi windows-installer -n "$WINDOWS_IMAGES_NAMESPACE" \
  -o 'jsonpath={.status.phase}' 2>/dev/null || true)"
if [[ "$installer_phase" == "Running" ]]; then
  if ! oc_cmd get secret windows-installer-answer -n "$WINDOWS_IMAGES_NAMESPACE" >/dev/null 2>&1; then
    printf 'windows-installer is already running but its answer Secret is missing; inspect the VM before continuing.\n' >&2
    exit 1
  fi
  INSTALLER_VMI_RUNNING=true
fi


TMP_ANSWER_FILE=
TMP_CURL_CONFIG=
cleanup() {
  trap - EXIT INT TERM
  if [[ -n "$TMP_ANSWER_FILE" && -f "$TMP_ANSWER_FILE" ]]; then
    rm -f "$TMP_ANSWER_FILE"
  fi
  if [[ -n "$TMP_CURL_CONFIG" && -f "$TMP_CURL_CONFIG" ]]; then
    rm -f "$TMP_CURL_CONFIG"
  fi
}
trap cleanup EXIT INT TERM

workflow_step "1/6 Stage the Windows installer ISO as a Filesystem PVC"
iso_phase="$(oc_cmd get dv windows-iso -n "$WINDOWS_IMAGES_NAMESPACE" \
  -o 'jsonpath={.status.phase}' 2>/dev/null || true)"
if [[ "$iso_phase" != "Succeeded" ]]; then
  workflow_action "oc apply -f manifests/windows-image.yaml (namespace $WINDOWS_IMAGES_NAMESPACE, DataVolume windows-iso)"
  oc_cmd apply -f "$ROOT_DIR/manifests/windows-image.yaml" >/dev/null

  workflow_action "oc wait dv/windows-iso -n $WINDOWS_IMAGES_NAMESPACE --for=jsonpath={.status.phase}=UploadReady --timeout=5m"
  oc_cmd wait dv/windows-iso -n "$WINDOWS_IMAGES_NAMESPACE" --for=jsonpath='{.status.phase}'=UploadReady --timeout=5m >/dev/null

  workflow_action "Request a short-lived cdi-uploadproxy token (oc create -f - kind: UploadTokenRequest)"
  # UploadTokenRequest is a virtual (non-persisted) resource: CDI's
  # apiserver computes and returns the token in the Create response itself,
  # and a later `oc get` on the same name 404s — the token must be read from
  # this call's own output, not fetched afterward.
  oc_cmd delete uploadtokenrequest windows-iso -n "$WINDOWS_IMAGES_NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true
  upload_token="$(printf 'apiVersion: upload.cdi.kubevirt.io/v1beta1\nkind: UploadTokenRequest\nmetadata:\n  name: windows-iso\n  namespace: %s\nspec:\n  pvcName: windows-iso\n' \
    "$WINDOWS_IMAGES_NAMESPACE" | oc_cmd create -f - -o 'jsonpath={.status.token}')"
  if [[ -z "$upload_token" ]]; then
    printf 'Could not obtain a CDI upload token for windows-iso.\n' >&2
    exit 1
  fi

  upload_host="$(oc_cmd get route cdi-uploadproxy -n openshift-cnv -o 'jsonpath={.spec.host}' 2>/dev/null || true)"
  if [[ -z "$upload_host" ]]; then
    printf 'Could not find the cdi-uploadproxy route (checked namespace openshift-cnv).\n' >&2
    exit 1
  fi

  workflow_action "curl -T $WINDOWS_ISO_PATH -X POST to https://$upload_host/v1beta1/upload (this can take several minutes)"
  # -k: the uploadproxy route serves CDI's own internal reencrypt certificate,
  # not one this client trusts; the bearer token, not TLS trust, is what
  # authorizes the upload, and CDI immediately invalidates the token after
  # use. The endpoint only accepts POST (curl's default --upload-file/-T is
  # PUT, which this route bounces with a bare 404, so -X POST overrides the
  # method while keeping -T's streamed-from-disk upload, unlike
  # --data-binary @file, which this curl build tries to load into memory in
  # one allocation and fails on a file this size).
  # A successful upload can still end the connection with a 502 (the
  # uploadserver pod tears down immediately after finishing) — the
  # DataVolume's own Succeeded phase, checked below, is the real signal.
  TMP_CURL_CONFIG="$(mktemp)"
  chmod 600 "$TMP_CURL_CONFIG"
  printf 'header = "Authorization: Bearer %s"\n' "$upload_token" > "$TMP_CURL_CONFIG"
  curl -sS -k \
    --config "$TMP_CURL_CONFIG" \
    -X POST \
    -T "$WINDOWS_ISO_PATH" \
    "https://$upload_host/v1beta1/upload" || true
  printf '\n' >&2

  workflow_action "oc wait dv/windows-iso -n $WINDOWS_IMAGES_NAMESPACE --for=jsonpath={.status.phase}=Succeeded --timeout=15m"
  oc_cmd wait dv/windows-iso -n "$WINDOWS_IMAGES_NAMESPACE" --for=jsonpath='{.status.phase}'=Succeeded --timeout=15m >/dev/null
fi
workflow_success "windows-iso Filesystem PVC is populated in $WINDOWS_IMAGES_NAMESPACE"

workflow_step "2/6 Render the sysprep answer file and installer VM"
if [[ "$INSTALLER_VMI_RUNNING" != true ]]; then
TMP_ANSWER_FILE="$(mktemp)"
chmod 600 "$TMP_ANSWER_FILE"
python3 - "$WINDOWS_ADMIN_PASSWORD_FILE" "$ROOT_DIR/scripts/windows-autounattend.xml.tmpl" "$TMP_ANSWER_FILE" <<'PY'
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
if template.count("__ADMIN_PASSWORD__") != 2:
    raise SystemExit("Windows autounattend template must contain exactly two password placeholders")
rendered = template.replace("__ADMIN_PASSWORD__", escape(password))
root = ET.fromstring(rendered)
unattend_ns = "{urn:schemas-microsoft-com:unattend}"
for settings in root.findall(unattend_ns + "settings"):
    if settings.get("pass") == "windowsPE":
        continue
    if any(component.get("name") == "Microsoft-Windows-PnpCustomizationsWinPE"
           for component in settings.findall(unattend_ns + "component")):
        raise SystemExit("Microsoft-Windows-PnpCustomizationsWinPE is only valid in the windowsPE pass")
install_to = None
for settings in root.findall(unattend_ns + "settings"):
    for component in settings.findall(unattend_ns + "component"):
        if component.get("name") == "Microsoft-Windows-Setup":
            image_install = component.find(unattend_ns + "ImageInstall")
            if image_install is not None:
                os_image = image_install.find(unattend_ns + "OSImage")
                if os_image is not None:
                    install_to = os_image.find(unattend_ns + "InstallTo")
if install_to is None:
    raise SystemExit("Windows autounattend must specify ImageInstall/OSImage/InstallTo")
for setting_name in ("DiskID", "PartitionID"):
    setting = install_to.find(unattend_ns + setting_name)
    if setting is None or not (setting.text or "").strip():
        raise SystemExit("Windows autounattend InstallTo must specify both DiskID and PartitionID")
output_path.write_text(rendered, encoding="utf-8")
PY
workflow_action "Create Secret windows-installer-answer from the validated local answer file (password never logged)"
oc_cmd delete secret windows-installer-answer -n "$WINDOWS_IMAGES_NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true
oc_cmd create secret generic windows-installer-answer -n "$WINDOWS_IMAGES_NAMESPACE" \
  --from-file=autounattend.xml="$TMP_ANSWER_FILE" >/dev/null
rm -f "$TMP_ANSWER_FILE"
TMP_ANSWER_FILE=

else
  workflow_action "Reuse the active installer VMI and its answer Secret without rebooting or sending another CD-boot key"
fi

workflow_action "Resolve the VirtIO guest-tools image from the installed OpenShift Virtualization CSV"
virtio_image="$(oc_cmd get csv -n openshift-cnv -o json 2>/dev/null |
  jq -r '[.items[].spec.relatedImages[]? | select(.name | test("virtio-win"; "i"))] | .[0].image // empty' \
    2>/dev/null || true)"
if [[ -z "$virtio_image" ]]; then
  virtio_image="$VIRTIO_IMAGE_FALLBACK"
  workflow_action "Use the pinned CNV VirtIO guest-tools fallback image"
fi

workflow_action "oc apply -f manifests/windows-installer.yaml (VM windows-installer)"
sed \
  -e "s|__SYSPREP_SECRET__|windows-installer-answer|g" \
  -e "s|__VIRTIO_IMAGE__|$virtio_image|g" \
  "$ROOT_DIR/manifests/windows-installer.yaml" | oc_cmd apply -f - >/dev/null
workflow_success "Installer VM applied; unattended Windows Server 2022 setup is starting"

workflow_step "3/6 Wait for the installer VM to boot and the guest agent to respond"
if [[ "$INSTALLER_VMI_RUNNING" != true ]]; then
workflow_action "Waiting for the windows-installer VMI and virt-launcher pod to start"
vmi_found=false
for ((attempt = 1; attempt <= 60; attempt++)); do
  if oc_cmd get vmi windows-installer -n "$WINDOWS_IMAGES_NAMESPACE" >/dev/null 2>&1; then
    vmi_found=true
    break
  fi
  sleep 2
done
if [[ "$vmi_found" != true ]]; then
  printf 'windows-installer VMI did not appear after 2 minutes.\n' >&2
  exit 1
fi
launcher_pod=
for ((attempt = 1; attempt <= 120; attempt++)); do
  launcher_pod="$(oc_cmd get pod -n "$WINDOWS_IMAGES_NAMESPACE" \
    -l kubevirt.io=virt-launcher,vm.kubevirt.io/name=windows-installer \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$launcher_pod" ]] && oc_cmd wait "pod/$launcher_pod" \
       -n "$WINDOWS_IMAGES_NAMESPACE" --for=condition=Ready --timeout=1s >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if [[ -z "$launcher_pod" ]] || ! oc_cmd wait "pod/$launcher_pod" \
     -n "$WINDOWS_IMAGES_NAMESPACE" --for=condition=Ready --timeout=1s >/dev/null 2>&1; then
  printf 'windows-installer virt-launcher pod did not become Ready.\n' >&2
  exit 1
fi
workflow_action "Wait for libvirt domain creation; the launcher Pod can become Ready first"
domain="${WINDOWS_IMAGES_NAMESPACE}_windows-installer"
domain_found=false
for ((attempt = 1; attempt <= 30; attempt++)); do
  if oc_cmd exec -n "$WINDOWS_IMAGES_NAMESPACE" "$launcher_pod" -c compute -- \
       virsh domstate "$domain" >/dev/null 2>&1; then
    domain_found=true
    break
  fi
  sleep 1
done
if [[ "$domain_found" != true ]]; then
  printf 'libvirt domain %s did not appear after the launcher pod became Ready.\n' "$domain" >&2
  exit 1
fi
workflow_action "Send one key to accept Windows media's brief UEFI CD-boot prompt"
oc_cmd exec -n "$WINDOWS_IMAGES_NAMESPACE" "$launcher_pod" -c compute -- \
  virsh send-key "$domain" --codeset linux KEY_SPACE
else
  workflow_action "The existing installer VMI is already running; waiting for installation/reboot to expose the QEMU Guest Agent channel"
fi
workflow_action "oc wait vmi/windows-installer -n $WINDOWS_IMAGES_NAMESPACE --for=condition=AgentConnected --timeout=45m"
oc_cmd wait vmi/windows-installer -n "$WINDOWS_IMAGES_NAMESPACE" --for=condition=AgentConnected --timeout=45m
workflow_action "Probe the QEMU Guest Agent socket before guest operations"
wait_for_guest_agent windows-installer "$WINDOWS_IMAGES_NAMESPACE"
workflow_success "QEMU Guest Agent is responding inside the installer VM"

# shellcheck source=scripts/windows-guest-agent.sh
source "$ROOT_DIR/scripts/windows-guest-agent.sh"

workflow_step "4/6 Prepare and sysprep the guest"
workflow_action "guest-exec: ensure C:\\cbt-data exists and disable hibernation"
guest_exec windows-installer "$WINDOWS_IMAGES_NAMESPACE" \
  "New-Item -ItemType Directory -Force -Path 'C:\\cbt-data' | Out-Null; powercfg.exe /hibernate off"
workflow_action "guest-script: install Python 3.12.4, register SYSTEM startup workloads, verify them, then clear generated data"
guest_exec_script windows-installer "$WINDOWS_IMAGES_NAMESPACE" \
  "$ROOT_DIR/scripts/windows-golden-workloads.ps1" \
  'C:\Windows\Temp\cbt-golden-workloads.ps1'

workflow_action "guest-exec: remove the per-user Microsoft Edge AppX package if present to avoid sysprep failure"
guest_exec windows-installer "$WINDOWS_IMAGES_NAMESPACE" \
  "Get-AppxPackage -AllUsers -Name '*MicrosoftEdge.Stable*' -ErrorAction SilentlyContinue | ForEach-Object { Remove-AppxPackage -Package \$_.PackageFullName -AllUsers -ErrorAction SilentlyContinue }"


workflow_action "oc patch vm/windows-installer -n $WINDOWS_IMAGES_NAMESPACE --type merge -p '{\"spec\":{\"runStrategy\":\"Manual\"}}'"
oc_cmd patch vm windows-installer -n "$WINDOWS_IMAGES_NAMESPACE" --type merge -p '{"spec":{"runStrategy":"Manual"}}' >/dev/null

workflow_action "guest-exec: start sysprep /generalize /oobe /shutdown"
sysprep_pid="$(guest_exec_start windows-installer "$WINDOWS_IMAGES_NAMESPACE" \
  '& "$env:SystemRoot\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown')"
[[ -n "$sysprep_pid" ]]

workflow_action "Wait for VMI/windows-installer deletion after sysprep shutdown (timeout 20m)"
if ! oc_cmd wait vmi/windows-installer -n "$WINDOWS_IMAGES_NAMESPACE" --for=delete --timeout=20m >/dev/null; then
  if oc_cmd get vmi windows-installer -n "$WINDOWS_IMAGES_NAMESPACE" >/dev/null 2>&1; then
    printf 'Sysprep did not stop windows-installer; VMI is still present. Inspect the guest before retrying.\n' >&2
    exit 1
  fi
fi
workflow_success "Installer VM reached a stopped state after sysprep"

workflow_step "5/6 Clone the generalized disk into the cached golden image"
workflow_action "oc apply -f manifests/windows-golden-datasource.yaml (DataVolume windows-golden, DataSource windows-server-2022)"
sed "s|__NAMESPACE__|$NAMESPACE|g" "$ROOT_DIR/manifests/windows-golden-datasource.yaml" | oc_cmd apply -f - >/dev/null
workflow_action "oc wait dv/windows-golden -n $WINDOWS_IMAGES_NAMESPACE --for=jsonpath={.status.phase}=Succeeded --timeout=30m"
oc_cmd wait dv/windows-golden -n "$WINDOWS_IMAGES_NAMESPACE" --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m >/dev/null
workflow_success "windows-golden DataVolume and windows-server-2022 DataSource are ready"

workflow_step "6/6 Delete installer-only resources"
workflow_action "Deleting windows-installer VM, windows-iso PVC, and windows-installer-answer secret"
oc_cmd delete vm windows-installer -n "$WINDOWS_IMAGES_NAMESPACE" --ignore-not-found=true --wait=true --timeout=10m
oc_cmd delete dv windows-installer-disk -n "$WINDOWS_IMAGES_NAMESPACE" --ignore-not-found=true --wait=true --timeout=10m
oc_cmd delete dv windows-iso -n "$WINDOWS_IMAGES_NAMESPACE" --ignore-not-found=true --wait=true --timeout=10m
oc_cmd delete secret windows-installer-answer -n "$WINDOWS_IMAGES_NAMESPACE" --ignore-not-found=true
workflow_success "Windows golden image is ready: DataSource $WINDOWS_IMAGES_NAMESPACE/windows-server-2022"

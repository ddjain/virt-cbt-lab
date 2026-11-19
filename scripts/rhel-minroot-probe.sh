#!/usr/bin/env bash
set -euo pipefail
# Standalone probe: how small can a RHEL 9 root disk be and still boot, run a
# workload, and complete CBT full + incremental backups?
#
# Isolation: creates ONE namespace (cbt-minroot-<id>) holding one VM, one root
# DataVolume imported straight from the RHEL guest-image registry reference,
# and its backup PVCs. It never writes to vm-cbt-demo, openshift-virtualization-os-images,
# runs/, state/, or any workflow-managed (virt-cbt-lab/managed-by) label.
# It only reads the stock rhel9 DataSource to learn the image reference.
#
#   scripts/rhel-minroot-probe.sh run                 # one probe
#   ROOT_SIZE_GI=8 scripts/rhel-minroot-probe.sh run
#   scripts/rhel-minroot-probe.sh cleanup <namespace> # deletes that probe namespace only
#
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PROBE_LABEL_KEY="virt-cbt-lab-minroot/probe"
ROOT_SIZE_GI="${ROOT_SIZE_GI:-10}"
ROOT_STORAGE_CLASS="${ROOT_STORAGE_CLASS:-cbt-demo-hpp}"
BACKUP_STORAGE_CLASS="${BACKUP_STORAGE_CLASS:-$ROOT_STORAGE_CLASS}"
BACKUP_SIZE_GI="${BACKUP_SIZE_GI:-$((ROOT_SIZE_GI + 2))}"
INCREMENTAL_SIZE_GI="${INCREMENTAL_SIZE_GI:-2}"
FILL_PCT_OF_FREE="${FILL_PCT_OF_FREE:-60}"
MUTATE_MIB="${MUTATE_MIB:-256}"
PROBE_MEMORY="${PROBE_MEMORY:-4Gi}"
IMAGE_URL="${IMAGE_URL:-}"
BOOT_TIMEOUT_SECONDS="${BOOT_TIMEOUT_SECONDS:-900}"
BACKUP_TIMEOUT_SECONDS="${BACKUP_TIMEOUT_SECONDS:-900}"

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
die() { printf 'rhel-minroot-probe: %s\n' "$*" >&2; exit 1; }

for c in oc jq virtctl ssh; do require_command "$c" || exit 1; done
validate_positive_integer ROOT_SIZE_GI "$ROOT_SIZE_GI"
validate_positive_integer BACKUP_SIZE_GI "$BACKUP_SIZE_GI"
validate_positive_integer INCREMENTAL_SIZE_GI "$INCREMENTAL_SIZE_GI"
validate_positive_integer FILL_PCT_OF_FREE "$FILL_PCT_OF_FREE"
validate_positive_integer MUTATE_MIB "$MUTATE_MIB"

cmd_cleanup() {
  local ns="${1:-}"
  [[ -n "$ns" ]] || die "usage: cleanup <namespace>"
  if ! oc_cmd get namespace "$ns" -o json | jq -e --arg k "$PROBE_LABEL_KEY" '.metadata.labels[$k] // empty' >/dev/null; then
    die "namespace $ns is not a minroot probe namespace (missing label $PROBE_LABEL_KEY); refusing"
  fi
  oc_cmd delete namespace "$ns" --wait=false
}

[[ "${1:-}" == cleanup ]] && { cmd_cleanup "${2:-}"; exit 0; }
[[ "${1:-}" == run ]] || die "usage: $0 run | cleanup <namespace>"

PUBKEY_FILE="${GUEST_KEY}.pub"
[[ -r "$GUEST_KEY" && -r "$PUBKEY_FILE" ]] || die "guest key pair not found at $GUEST_KEY(.pub)"
PROBE_ID="${PROBE_ID:-$(date +%m%d%H%M%S)}"
PROBE_NS="cbt-minroot-${PROBE_ID}"
VM="vm-minroot-${PROBE_ID}"
OUT_DIR="$ROOT_DIR/artifacts/rhel-minroot/${PROBE_ID}"
mkdir -p "$OUT_DIR"
RESULT="$OUT_DIR/result.json"
echo '{}' > "$RESULT"
record() { local tmp; tmp="$(mktemp)"; jq --arg k "$1" --arg v "$2" '.[$k]=$v' "$RESULT" > "$tmp" && mv "$tmp" "$RESULT"; }
record probe_id "$PROBE_ID"; record namespace "$PROBE_NS"; record root_size_gi "$ROOT_SIZE_GI"
record backup_size_gi "$BACKUP_SIZE_GI"; record incremental_size_gi "$INCREMENTAL_SIZE_GI"
record storage_class "$ROOT_STORAGE_CLASS"; record verdict "incomplete"

# Image reference: the same digest the stock rhel9 golden was imported from.
if [[ -z "$IMAGE_URL" ]]; then
  pvc="$(oc_cmd get datasource rhel9 -n openshift-virtualization-os-images -o jsonpath='{.spec.source.pvc.name}')"
  IMAGE_URL="$(oc_cmd get dv "$pvc" -n openshift-virtualization-os-images -o jsonpath='{.spec.source.registry.url}')"
  [[ -n "$IMAGE_URL" ]] || die "could not derive image URL from rhel9 golden; set IMAGE_URL=docker://..."
fi
record image_url "$IMAGE_URL"
log "probe $PROBE_ID: ns=$PROBE_NS root=${ROOT_SIZE_GI}Gi backup=${BACKUP_SIZE_GI}Gi inc=${INCREMENTAL_SIZE_GI}Gi sc=$ROOT_STORAGE_CLASS"

fail() { record verdict "FAIL: $*"; log "FAIL: $*"; log "evidence: $OUT_DIR ; cleanup: $0 cleanup $PROBE_NS"; exit 1; }

oc_cmd apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $PROBE_NS
  labels:
    $PROBE_LABEL_KEY: "$PROBE_ID"
EOF

# CBT is enabled for VMs labelled cbt-demo=enabled (KubeVirt CR selector).
oc_cmd apply -f - >/dev/null <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: $VM
  namespace: $PROBE_NS
  labels:
    cbt-demo: enabled
    $PROBE_LABEL_KEY: "$PROBE_ID"
spec:
  runStrategy: Always
  dataVolumeTemplates:
    - metadata:
        name: ${VM}-root
        labels:
          $PROBE_LABEL_KEY: "$PROBE_ID"
      spec:
        source:
          registry:
            pullMethod: node
            url: "$IMAGE_URL"
        storage:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: ${ROOT_SIZE_GI}Gi
          storageClassName: $ROOT_STORAGE_CLASS
          volumeMode: Filesystem
  template:
    metadata:
      labels:
        cbt-demo: enabled
    spec:
      evictionStrategy: None
      domain:
        cpu:
          cores: 1
        memory:
          guest: $PROBE_MEMORY
        resources:
          requests:
            memory: $PROBE_MEMORY
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: ${VM}-root
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              runcmd:
                - [systemctl, enable, --now, qemu-guest-agent]
                - [systemctl, enable, --now, sshd]
              ssh_pwauth: false
              users:
                - name: cbt-demo
                  groups: [wheel]
                  sudo: ["ALL=(ALL) NOPASSWD:ALL"]
                  shell: /bin/bash
                  lock_passwd: true
                  ssh_authorized_keys:
                    - $(cat "$PUBKEY_FILE")
EOF

log "waiting for root DataVolume import (${ROOT_SIZE_GI}Gi)"
deadline=$((SECONDS + BOOT_TIMEOUT_SECONDS))
while :; do
  dv_json="$(oc_cmd get dv "${VM}-root" -n "$PROBE_NS" -o json 2>/dev/null || echo '{}')"
  phase="$(jq -r '.status.phase // "Pending"' <<<"$dv_json")"
  [[ "$phase" == Succeeded ]] && break
  if [[ "$phase" == Failed ]] || jq -e '.status.conditions[]? | select(.type=="Running" and .status=="False" and ((.message // "")|test("larger|capacity|virtual size|too small|space";"i")))' <<<"$dv_json" >/dev/null; then
    jq '.status' <<<"$dv_json" > "$OUT_DIR/dv-status.json"
    fail "root DataVolume import rejected at ${ROOT_SIZE_GI}Gi (phase=$phase): $(jq -r '[.status.conditions[]?.message]|join(" | ")' <<<"$dv_json")"
  fi
  ((SECONDS < deadline)) || fail "root DataVolume not Succeeded within ${BOOT_TIMEOUT_SECONDS}s (phase=$phase)"
  sleep 5
done
record root_pvc_requested_bytes "$(oc_cmd get pvc "${VM}-root" -n "$PROBE_NS" -o jsonpath='{.spec.resources.requests.storage}')"
record root_pvc_capacity "$(oc_cmd get pvc "${VM}-root" -n "$PROBE_NS" -o jsonpath='{.status.capacity.storage}')"

log "waiting for VM ready + CBT Enabled"
while :; do
  vm_json="$(oc_cmd get vm "$VM" -n "$PROBE_NS" -o json)"
  if [[ "$(jq -r '.status.ready // false' <<<"$vm_json")" == true ]] \
    && [[ "$(jq -r '.status.changedBlockTracking.state // empty' <<<"$vm_json")" == Enabled ]]; then break; fi
  ((SECONDS < deadline)) || fail "VM not ready with CBT Enabled within ${BOOT_TIMEOUT_SECONDS}s"
  sleep 5
done

guest() {
  KUBECONFIG="${KUBECONFIG_PATH:-${KUBECONFIG:-}}" virtctl ssh --namespace "$PROBE_NS" --identity-file "$GUEST_KEY" \
    --local-ssh-opts="-o StrictHostKeyChecking=no" --local-ssh-opts="-o UserKnownHostsFile=/dev/null" \
    --local-ssh-opts="-o LogLevel=ERROR" --local-ssh-opts="-o ConnectTimeout=10" \
    --command "$1" "cbt-demo@vmi/$VM"
}
log "waiting for guest SSH"
until guest true >/dev/null 2>&1; do
  ((SECONDS < deadline)) || fail "guest SSH not usable within ${BOOT_TIMEOUT_SECONDS}s"
  sleep 5
done
until [[ "$(guest 'systemctl is-active qemu-guest-agent' 2>/dev/null || true)" == active ]]; do
  ((SECONDS < deadline)) || fail "qemu-guest-agent not active"
  sleep 3
done

log "guest baseline"
guest 'sudo bash -s' > "$OUT_DIR/guest-baseline.txt" <<'EOS'
echo "== df /"; df -B1 --output=size,used,avail,pcent /
echo "== lsblk"; lsblk -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
echo "== rpm count"; rpm -qa | wc -l
echo "== services"; systemctl is-active qemu-guest-agent sshd cloud-init
echo "== journal"; journalctl --disk-usage
EOS
read -r root_size root_used root_avail _ < <(guest "df -B1 --output=size,used,avail,pcent / | tail -1")
record guest_fs_size_bytes "$root_size"; record guest_fs_used_bytes "$root_used"; record guest_fs_avail_bytes "$root_avail"

fill_bytes=$((root_avail / 100 * FILL_PCT_OF_FREE))
fill_mib=$((fill_bytes / 1048576))
log "writing ${fill_mib} MiB workload (${FILL_PCT_OF_FREE}% of free) in guest"
guest "sudo bash -s" <<EOS
set -euo pipefail
install -d -m 0755 /var/lib/minroot
n=\$(( $fill_mib / 32 )); [ "\$n" -ge 1 ] || n=1
for i in \$(seq 1 "\$n"); do head -c 32M /dev/urandom > /var/lib/minroot/f\$i.bin; done
( cd /var/lib/minroot && sha256sum f*.bin > /var/lib/minroot.sha256 ); sync
df -B1 --output=used,avail / | tail -1
EOS
record workload_mib "$fill_mib"

backup_apply() { # kind name pvc size [tracker-create]
  oc_cmd apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $3
  namespace: $PROBE_NS
  labels:
    $PROBE_LABEL_KEY: "$PROBE_ID"
spec:
  storageClassName: $BACKUP_STORAGE_CLASS
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: ${4}Gi
---
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackup
metadata:
  name: $2
  namespace: $PROBE_NS
  labels:
    $PROBE_LABEL_KEY: "$PROBE_ID"
spec:
  source:
    apiGroup: backup.kubevirt.io
    kind: VirtualMachineBackupTracker
    name: ${VM}-tracker
  pvcName: $3
EOF
}
backup_wait() {
  local name="$1" d=$((SECONDS + BACKUP_TIMEOUT_SECONDS)) b
  while :; do
    b="$(oc_cmd get vmbackup "$name" -n "$PROBE_NS" -o json)"
    echo "$b" > "$OUT_DIR/vmbackup-$name.json"
    if jq -e '.status.conditions[]? | select(.type=="Done" and .status=="True")' <<<"$b" >/dev/null; then
      jq -e '.status.conditions[]? | select(.type=="Done" and (.reason|test("fail|error";"i")))' <<<"$b" >/dev/null \
        && fail "backup $name Done with failure reason: $(jq -c '.status.conditions' <<<"$b")"
      return 0
    fi
    ((SECONDS < d)) || fail "backup $name not Done within ${BACKUP_TIMEOUT_SECONDS}s"
    sleep 3
  done
}

oc_cmd apply -f - >/dev/null <<EOF
apiVersion: backup.kubevirt.io/v1alpha1
kind: VirtualMachineBackupTracker
metadata:
  name: ${VM}-tracker
  namespace: $PROBE_NS
  labels:
    $PROBE_LABEL_KEY: "$PROBE_ID"
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: $VM
EOF
log "full backup into ${BACKUP_SIZE_GI}Gi PVC"
backup_apply full "${VM}-full" "${VM}-full-pvc" "$BACKUP_SIZE_GI"
backup_wait "${VM}-full"
record full_backup "Done"

log "mutating ${MUTATE_MIB} MiB then incremental backup into ${INCREMENTAL_SIZE_GI}Gi PVC"
guest "sudo bash -s" <<EOS
set -euo pipefail
head -c ${MUTATE_MIB}M /dev/urandom > /var/lib/minroot/mutated.bin
( cd /var/lib/minroot && sha256sum f*.bin mutated.bin > /var/lib/minroot.sha256 ); sync
EOS
backup_apply inc "${VM}-inc1" "${VM}-inc1-pvc" "$INCREMENTAL_SIZE_GI"
backup_wait "${VM}-inc1"
record incremental_backup "Done"

log "guest integrity re-check"
guest "sudo bash -c 'cd /var/lib/minroot && sha256sum -c /var/lib/minroot.sha256 >/dev/null'" || fail "guest sha256 mismatch"
record verdict "PASS"
log "PASS root=${ROOT_SIZE_GI}Gi backup=${BACKUP_SIZE_GI}Gi inc=${INCREMENTAL_SIZE_GI}Gi; result: $RESULT"
log "cleanup when done: $0 cleanup $PROBE_NS"

#!/usr/bin/env bash
set -euo pipefail
# Build the golden DataSource for VM_OS=rhel9-light: import the RHEL 9 guest
# image (the same registry digest the stock rhel9 golden uses) into a small
# DataVolume. The stock rhel9 golden is ~32Gi, and CDI clones cannot be
# smaller than their source PVC, so a right-sized root needs its own golden.
# Idempotent: exits 0 when the DataSource already exists.
#
# Variables (all optional, see .env.example):
#   RHEL_LIGHT_DATA_SOURCE_NAME       DataSource name (default rhel9-light)
#   RHEL_LIGHT_DATA_SOURCE_NAMESPACE  namespace (default vm-cbt-images)
#   RHEL_LIGHT_GOLDEN_SIZE            golden PVC request (default 10Gi, the
#                                     image's native virtual size; smaller is
#                                     rejected by CDI at import)
#   RHEL_LIGHT_GOLDEN_STORAGE_CLASS   default follows MANIFEST_VARIANT:
#                                     odf|large-odf|odf-hpp -> ocs-storagecluster-ceph-rbd,
#                                     otherwise cbt-demo-hpp
#   RHEL_LIGHT_IMAGE_URL              docker://... image reference; default is
#                                     read from the stock rhel9 DataSource
export VM_OS=rhel9-light
# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
WORKFLOW_NAME="rhel-light-golden"

DS_NAME="$VM_DATA_SOURCE_NAME"
DS_NAMESPACE="$VM_DATA_SOURCE_NAMESPACE"
GOLDEN_DV="${DS_NAME}-golden"
GOLDEN_SIZE="${RHEL_LIGHT_GOLDEN_SIZE:-10Gi}"
if ! [[ "$GOLDEN_SIZE" =~ ^[1-9][0-9]*Gi$ ]]; then
  printf 'RHEL_LIGHT_GOLDEN_SIZE must look like 10Gi (got: %s)\n' "$GOLDEN_SIZE" >&2
  exit 1
fi
if [[ -n "${RHEL_LIGHT_GOLDEN_STORAGE_CLASS:-}" ]]; then
  GOLDEN_STORAGE_CLASS="$RHEL_LIGHT_GOLDEN_STORAGE_CLASS"
else
  case "$MANIFEST_VARIANT" in
    odf | large-odf | odf-hpp) GOLDEN_STORAGE_CLASS=ocs-storagecluster-ceph-rbd ;;
    *) GOLDEN_STORAGE_CLASS=cbt-demo-hpp ;;
  esac
fi

workflow_step "1/3 Check for an existing $DS_NAME DataSource"
if oc_cmd get datasource "$DS_NAME" -n "$DS_NAMESPACE" >/dev/null 2>&1; then
  workflow_success "DataSource $DS_NAME already exists in $DS_NAMESPACE; nothing to do (delete datasource/$DS_NAME and dv/$GOLDEN_DV in $DS_NAMESPACE to rebuild)"
  exit 0
fi
workflow_success "No $DS_NAME DataSource yet"

workflow_step "2/3 Resolve the RHEL 9 guest image reference"
image_url="${RHEL_LIGHT_IMAGE_URL:-}"
if [[ -z "$image_url" ]]; then
  workflow_action "Read the registry reference from the stock rhel9 DataSource (read-only)"
  stock_pvc="$(oc_cmd get datasource rhel9 -n openshift-virtualization-os-images -o 'jsonpath={.spec.source.pvc.name}')"
  image_url="$(oc_cmd get dv "$stock_pvc" -n openshift-virtualization-os-images -o 'jsonpath={.spec.source.registry.url}' 2>/dev/null || true)"
  if [[ -z "$image_url" ]]; then
    printf 'Could not derive the image from the stock rhel9 golden; set RHEL_LIGHT_IMAGE_URL=docker://registry.redhat.io/rhel9/rhel-guest-image@sha256:<digest>\n' >&2
    exit 1
  fi
fi
workflow_success "Image: $image_url"

workflow_step "3/3 Import into a ${GOLDEN_SIZE} DataVolume on $GOLDEN_STORAGE_CLASS and publish the DataSource"
workflow_action "oc apply DataVolume $GOLDEN_DV in $DS_NAMESPACE (pullMethod node, Filesystem)"
oc_cmd apply -f - >/dev/null <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: $GOLDEN_DV
  namespace: $DS_NAMESPACE
  labels:
    virt-cbt-lab/golden: $DS_NAME
spec:
  source:
    registry:
      pullMethod: node
      url: "$image_url"
  storage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: $GOLDEN_SIZE
    storageClassName: $GOLDEN_STORAGE_CLASS
    volumeMode: Filesystem
EOF
workflow_action "oc wait dv/$GOLDEN_DV -n $DS_NAMESPACE --for=jsonpath={.status.phase}=Succeeded --timeout=30m"
if ! oc_cmd wait "dv/$GOLDEN_DV" -n "$DS_NAMESPACE" --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m >/dev/null; then
  printf 'DataVolume %s did not reach Succeeded; inspect: oc describe dv/%s -n %s\n' "$GOLDEN_DV" "$GOLDEN_DV" "$DS_NAMESPACE" >&2
  exit 1
fi
oc_cmd apply -f - >/dev/null <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: $DS_NAME
  namespace: $DS_NAMESPACE
  labels:
    virt-cbt-lab/golden: $DS_NAME
spec:
  source:
    pvc:
      name: $GOLDEN_DV
      namespace: $DS_NAMESPACE
EOF
workflow_success "DataSource $DS_NAME published in $DS_NAMESPACE; use: make e2e VM_OS=rhel9-light"

#!/usr/bin/env bash
# contract-gen.sh — generate a run's task contracts from parameterized templates.
#
# Cloning r02's seven contracts into r03 by hand (sed) worked but cost ~30
# minutes and risked silent omissions; this generator makes contract issuance
# one command per run. Contracts remain immutable after acceptance and are
# still written per-run into the run root — only the authoring is templated.
#
# Usage: contract-gen.sh <scenario-id> <run-root>
#   Reads templates from cbt-chaos/contracts/ (one per role), substitutes:
#     __RUN_ID__ __VM_NAME__ __FULL_BACKUP__ __TRACKER__ __NAMESPACE__
#     __CTRL_NAMESPACE__ __HOST__ __REMOTE_DIR__ __SCENARIO_DIR__
#   and writes <run-root>/contracts/<role>.md
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'usage: %s <scenario-id> <run-root>\n' "$0" >&2
  exit 2
fi

SCENARIO_ID=$1
RUN_ROOT=$2
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/contracts" && pwd)"

# Derive run-scoped identifiers from the run id (framework convention).
RUN_ID="$(basename "$RUN_ROOT")"
VM_NAME="vm-${RUN_ID}"
FULL_BACKUP="vm-backup-${RUN_ID}"
TRACKER="vm-tracker-${RUN_ID}"
NAMESPACE="${NAMESPACE:-vm-cbt-demo}"
CTRL_NAMESPACE="${CTRL_NAMESPACE:-openshift-cnv}"
HOST="${REMOTE_HOST:-cloud05}"
REMOTE_DIR="${REMOTE_DIR:-/root/virt-cbt-lab}"
SCENARIO_DIR="cbt-chaos/scenarios_v2/${SCENARIO_ID}"

mkdir -p "$RUN_ROOT/contracts"
for template in "$TEMPLATE_DIR"/*.md; do
  role="$(basename "$template")"
  sed -e "s|__RUN_ID__|$RUN_ID|g" \
      -e "s|__VM_NAME__|$VM_NAME|g" \
      -e "s|__FULL_BACKUP__|$FULL_BACKUP|g" \
      -e "s|__TRACKER__|$TRACKER|g" \
      -e "s|__NAMESPACE__|$NAMESPACE|g" \
      -e "s|__CTRL_NAMESPACE__|$CTRL_NAMESPACE|g" \
      -e "s|__HOST__|$HOST|g" \
      -e "s|__REMOTE_DIR__|$REMOTE_DIR|g" \
      -e "s|__SCENARIO_DIR__|$SCENARIO_DIR|g" \
      "$template" > "$RUN_ROOT/contracts/$role"
done
printf 'contracts written to %s/contracts:\n' "$RUN_ROOT"
ls "$RUN_ROOT/contracts"

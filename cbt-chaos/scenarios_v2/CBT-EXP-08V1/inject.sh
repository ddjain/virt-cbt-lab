#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# CBT-EXP-08V1 fault action (Pattern C: documented oc/kubectl fault action).
#
# ONE concern: resolve the approved target operand, issue the single
# UID-preconditioned DELETE, and report that invocation's HTTP status and exit.
#
# run.sh owns everything else: the owned local `oc proxy` lifetime, the
# active-copy window, the same-instant revalidation, the fail-closed tracker
# GET, sampling, the controller-log window, and the recovery leg. This file
# performs no probe, no retry, no rollback, no recovery, and writes no
# provenance JSON — it only renders the DELETE's own request body, sends the
# one request, and reports what the API answered.
#
# Why not krknctl: the installed krknctl v0.14.2-beta exposes pod/container/VMI
# fault scenarios only (checked metadata is recorded by run.sh in
# execution/krkn-metadata.json); no installed scenario deletes a named custom
# resource on a condition, and the installed --triggers-on-timeout default is
# `skip`, which would silently skip the fault on a timeout.
#
# Required operands (environment, resolved before this file is invoked):
#   NAMESPACE     namespace of the run-owned tracker
#   TRACKER_NAME  the run's VirtualMachineBackupTracker (run.sh asserts name +
#                 virt-cbt-lab/run-id label + spec.source = the run's VM)
#   TRACKER_UID   that object's live metadata.uid — the DELETE precondition
#   API_BASE      base URL of the owned local oc proxy (http://127.0.0.1:<port>)
#   API_GROUP     backup.kubevirt.io/v1alpha1 (the approved group/version)
#   BODY_FILE     path where this file writes the exact DeleteOptions body
#
# Exit status:
#   0  the API accepted the DELETE (HTTP 200 or 202)
#   1  the API answered with any other status (409 precondition, 403, 404, ...)
#   2  a required operand is missing or malformed; nothing was sent
#   3  transport failure; the API may not have received the request
# =============================================================================
require_operand() {
  [[ -n "${!1:-}" ]] || { printf '%s is required\n' "$1" >&2; exit 2; }
}
require_operand NAMESPACE
require_operand TRACKER_NAME
require_operand TRACKER_UID
require_operand API_BASE
require_operand API_GROUP
require_operand BODY_FILE

# Target resolution guard: the operands must be the approved shapes, so a
# degraded value can never widen or redirect the one request.
[[ "$API_GROUP" == 'backup.kubevirt.io/v1alpha1' ]] ||
  { printf 'API_GROUP must be backup.kubevirt.io/v1alpha1 (got %s)\n' "$API_GROUP" >&2; exit 2; }
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
  { printf 'NAMESPACE is not a DNS label: %s\n' "$NAMESPACE" >&2; exit 2; }
[[ "$TRACKER_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
  { printf 'TRACKER_NAME is not a DNS label: %s\n' "$TRACKER_NAME" >&2; exit 2; }
[[ "$TRACKER_UID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
  { printf 'TRACKER_UID is not a UID: %s\n' "$TRACKER_UID" >&2; exit 2; }
[[ "$API_BASE" =~ ^http://127\.0\.0\.1:[0-9]{1,5}$ ]] ||
  { printf 'API_BASE must be the loopback oc proxy URL: %s\n' "$API_BASE" >&2; exit 2; }

path="/apis/${API_GROUP}/namespaces/${NAMESPACE}/virtualmachinebackuptrackers/${TRACKER_NAME}"
response_file="${BODY_FILE}.response"
stderr_file="${BODY_FILE}.stderr"

# The preconditioned request body. gracePeriodSeconds 0 keeps the delete
# immediate; preconditions.uid makes the API reject the request instead of
# deleting a replacement object if the tracker changed since revalidation.
jq -n --arg uid "$TRACKER_UID" \
  '{apiVersion:"v1",kind:"DeleteOptions",gracePeriodSeconds:0,preconditions:{uid:$uid}}' \
  > "$BODY_FILE"

if http_status="$(curl --noproxy '*' -sS --max-time 30 -X DELETE \
    -H 'Content-Type: application/json' --data-binary "@$BODY_FILE" \
    -o "$response_file" -w '%{http_code}' "$API_BASE$path" 2> "$stderr_file")"; then
  transport_rc=0
else
  transport_rc=$?
fi

printf 'delete_path=%s\nhttp_status=%s\ntransport_rc=%s\n' "$path" "${http_status:-none}" "$transport_rc"

(( transport_rc == 0 )) || exit 3
case "$http_status" in
  200|202) exit 0 ;;
  *) exit 1 ;;
esac

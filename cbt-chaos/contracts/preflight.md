# Task Contract: Preflight Worker — CBT-F-04 run __RUN_ID__

Role skill: `cbt-chaos-preflight-worker`. One job: GO or NO-GO. You execute
nothing live and mutate nothing.

## Run identity
- Scenario: CBT-F-04 (Restart the backup controller during the active disk copy)
- RUN_ID: `__RUN_ID__` (lifecycle NAME identical; VM `vm-__RUN_ID__`)
- Workflow: `TYPE=full` (new lifecycle) with same-VM `TYPE=incremental` follow-up
- Host: `__HOST__`, remote checkout `__REMOTE_DIR__` (git 9adb186)
- Local checkout: current working directory (git 88a7c30 + working tree)
- Namespace: `vm-cbt-demo` (default)

## Paths you may read (and nothing else)
- This contract: `__SCENARIO_DIR__/runs/__RUN_ID__/contracts/preflight.md`
- Scenario files: `__SCENARIO_DIR__/{jira-issue.md,scenario-spec.md,chaos-trigger.sh}`
- Local Makefile, `scripts/e2e-stage.sh`, `scripts/common.sh`, `.env.example`
- Read-only live cluster state on __HOST__ via `ssh __HOST__` with the host-local
  kubeconfig referenced by `KUBECONFIG_PATH` in `.env` (never print its contents)
- Remote checkout files at `__REMOTE_DIR__` for checksum comparison

## File you own (sole writer)
`__SCENARIO_DIR__/runs/__RUN_ID__/preflight.json` (write
locally; the Lead handles remote sync). Format per your skill:
`{"decision": "GO"|"NO-GO", "utc": "...", "checks": [{"name","result","evidence"}], "blockers": [...]}`.

## Checks required (all must pass for GO)
1. Spec↔trigger agreement: full-backup workflow, controller-leader deletion via
   Krkn pod-scenarios, `Backup started` launcher-log signal, Lease-holder
   identity verification, same-VM incremental follow-up.
2. Static trigger validation: `bash -n` on
   `__SCENARIO_DIR__/chaos-trigger.sh`; grep-verify every
   load-bearing variable referenced by the Krkn action (`RUN_ID`, `VM_NAME`,
   `FULL_BACKUP_NAME`, `leader`, `KUBECONFIG_PATH`, `SIGNAL_FILE`) is defined at
   its expected scope.
3. Trigger self-rehearsal: the trigger has NO `--plan`/dry-run mode. Substitute:
   run `RUN_ID=__RUN_ID__ bash -c` variable-resolution check that
   sources nothing and does NOT execute the script — e.g. extract and evaluate
   lines 4–23 (parameter resolution) in a subshell with the env set, confirming
   RUN_ID/VM_NAME/FULL_BACKUP_NAME resolve to the exact run values and the
   collision-guard resource names are well-formed. Record that the script lacks
   a native plan mode and whether your substitute check is sufficient; if you
   judge it insufficient for a safe GO, that is a NO-GO blocker.
4. Trigger checksum: sha256 of local
   `__SCENARIO_DIR__/chaos-trigger.sh` vs
   `__HOST__:__REMOTE_DIR__/__SCENARIO_DIR__/chaos-trigger.sh`.
   Report the checksum. (Lead already verified md5 parity
   `bbaf5623b61be752ea4ed42924c00be2`; re-verify with sha256.)
5. Krkn validation on __HOST__: `krknctl describe pod-scenarios` and
   `krknctl run pod-scenarios --dry-run` with the exact arguments from the
   trigger (namespace `__CTRL_NAMESPACE__`, name-pattern from the current Lease
   holder, disruption-count 1, execution serial, kill-timeout 180,
   expected-recovery-time 120). Resolve the current holder first:
   `oc get lease virt-controller -n __CTRL_NAMESPACE__ -o jsonpath='{.spec.holderIdentity}'`.
   Never run Krkn live.
6. Cluster readiness: `virt-controller` replicas Ready in `__CTRL_NAMESPACE__`,
   Lease holder exists, no other VirtualMachineBackup `Progressing` in
   `vm-cbt-demo` (excluding ones from unrelated finished runs — check
   conditions), storage backend health for the `large-odf` variant (ODF/ceph
   healthy if applicable), and `make help` on __HOST__ showing `e2e` with
   `TYPE` staged interface.
7. Capacity headroom (mandatory): destination storage class for the
   `large-odf` manifest variant must fit the planned full backup (8 × 1 GiB
   guest files ⇒ multi-GiB PVC plus snapshot overhead) AND the follow-up
   incremental. Inspect the storage class capacity/PV headroom (e.g. ceph
   `ceph df` equivalents via `oc` on the ODF cluster if available, or StorageCluster
   status) and the manifest's PVC request in `manifests/full-backup-large-odf.yaml`
   (and incremental equivalent) — verify requested sizes and that the backend
   has headroom. Prior incident: 8 GiB backup PVC exhausted by the Full so the
   incremental failed `No space left on device`. NO-GO on insufficient headroom.
8. Mode support: __HOST__ Makefile actually routes `TYPE=full`/`TYPE=incremental`
   through `scripts/e2e-stage.sh` (read the remote Makefile target source).
   Also confirm remote `runs/__RUN_ID__/` exists (Lead created it) and
   no run-scoped resources `vm-__RUN_ID__` etc. exist in the cluster.

## When done
Write `preflight.json` and reply to the Lead with the decision, blockers (if
any), the trigger sha256, and the capacity evidence in ≤15 lines.

## Never
- Run `make e2e`, the trigger, Krkn live, or any mutation of cluster/checkout state.
- Read other runs' artifacts, reports, historical results, or learnings files.
- Edit the spec, trigger, ledger, state, or any contract. You own only `preflight.json`.

# Working in this repository

## Purpose and architecture

This repository is a shell-driven KubeVirt CBT demonstration. `make e2e` runs setup, full backup, incremental backup, and API verification in that order. Kubernetes resources are in `manifests/`; operational details are in `docs/vm-cbt-workflow.md`.

## Important files

- `Makefile`: public workflow targets and optional `.env` loading.
- `scripts/common.sh`: shared constants, command/kubeconfig checks, guest-key creation, and temporary `oc port-forward` SSH handling.
- `scripts/vm-setup.sh`: VM, disk, service, and guest-file setup.
- `scripts/vm-backup.sh`: full backup creation and validation.
- `scripts/vm-cbt-backup.sh`: guest mutation and incremental backup.
- `scripts/vm-cbt-verify.sh`: end-state validation.
- `scripts/clean-all.sh`: namespace/PV/key cleanup.
- `scripts/monitor.sh <vm_name>`: read-only, watches a run's full/incremental `vmbackup` objects and prints real start/done timestamps and duration for each; run it alongside `make e2e` in a separate terminal.
- `sync.sh`: optional SSH/rsync helper; it reads `REMOTE_HOST` and `REMOTE_DIR` from the environment or local `.env`.
- `scripts/density-setup.sh`: creates a pool of bare VMs with kube-burner (`make density-setup`); pools VM, root DataVolume, and (RHEL) SSH Service named `vm-<pool>-NNNN` etc. (`POOL` defaults to an OS-prefixed timestamp, e.g. `rhel-<MMDDhhmmss>`), then polls VM readiness itself. No local pool metadata is written — pool state lives in the VMs' `virt-cbt-lab/*` labels and annotations.
- `scripts/density-status.sh` (+ `scripts/density-lib.sh`): read-only fleet view — every managed VM in the namespace grouped by pool, each group with a total/creating/created/full/incremental-pass funnel from cluster VM and `vmbackup` objects (`POOL=<id>` restricts to one pool).
- `scripts/windows-oobe-secret.sh`: sourced library that builds a labeled Windows OOBE Secret; shared by `windows-vm-setup.sh` (run-scoped) and `density-setup.sh` (pool-scoped).
- `scripts/archive-run.sh <run-id>`: optional, explicitly requested one-way archive of a closed run's local evidence into the gitignored `artifacts/` tree (scenario-keyed; refuses in-flight runs; `--index` regenerates `artifacts/INDEX.md`). General AI-generated reports, matrices, analyses and plans belong in `artifacts/`. Narrow exception: CBT chaos v2 reports, per-defect bugs and new proposed scenario drafts remain canonical under `cbt-chaos/scenarios_v2/<ID>/`, with attempt evidence in its `runs/<attempt-id>/`; lifecycle evidence remains in repository `runs/<lifecycle-id>/` and is referenced, not copied. Do not automatically archive v2 outputs or move/regrade historical evidence.

## Setup and validation

Copy `.env.example` to `.env`, set local paths, and run `make e2e`. `make` includes `.env`; direct script execution requires exporting it first:

```sh
cp .env.example .env
$EDITOR .env
set -a; . ./.env; set +a
make e2e
```

### Staged CBT lifecycle commands

Use the workflow stage that matches the scenario; do not start the full demo when the issue only needs one backup stage:

```sh
make e2e TYPE=full
make e2e TYPE=incremental VM=vm-my-existing-run
```

`TYPE=full` creates a new run ID when `NAME`/`VM` is omitted, sets up a new VM, and takes its full backup; the lifecycle remains incomplete until incremental passes are added. `TYPE=incremental` requires the existing managed VM (replace `vm-my-existing-run` with its exact name) and its valid `runs/<run-id>/run.json` in this checkout; it runs the next planned incremental pass without recreating the VM. The final planned pass performs verification. Do not copy a live VM name into permanent examples; resolve the exact VM/run ID from the active workflow state.

These modes are supported only when the active checkout's `Makefile`/workflow scripts implement `TYPE`. Check `make help` and the target source, especially when running from a remote checkout: an older `e2e` target may ignore `TYPE=incremental` and run the complete demo instead. `make e2e` with default `TYPE=all` remains the full lifecycle.

### Density pools and adopting a pool VM

`make density-setup VM_OS=rhel9|windows DENSITY_VM_COUNT=N [POOL=<id>] [DENSITY_INCREMENTAL_PASSES=n] [DENSITY_QPS=q] [DENSITY_WAIT_MINUTES=m]` creates bare, backup-eligible pool VMs (one OS per pool; Debian is not supported; `POOL` defaults to an OS-prefixed timestamp like `rhel-<MMDDhhmmss>`, and a `POOL` that already has VMs in the namespace is refused); `make density-status` prints the read-only fleet view (all pools plus un-pooled managed VMs; `POOL=<id>` restricts to one pool). Pool run IDs are fixed `<pool>-NNNN`, so a pool VM joins the normal pipeline without recreation:

```sh
make e2e EXISTING_VM=vm-<pool>-NNNN   # TYPE=all|full only; cannot combine with VM/NAME
```

Adoption rules: the VM must carry the density-pool labels; the pool's os-profile/manifest-variant/incremental-passes annotations override the environment; `runs/<pool>-NNNN/` is created only at adoption (re-adoption after artifacts exist fails — continue with `TYPE=incremental VM=...`). RHEL adoption requires the same checkout: the pool was created with this `$GUEST_KEY`'s public half. Workload sizing (`GUEST_*_FILE_COUNT`, file MiB range) still comes from the environment, not the pool. `ready` in density-status is VM-object-level only (`.status.ready==true`); guest-OS boot/SSH usability is verified at adoption — vm-setup re-waits on readiness, asserts CBT `Enabled`, and logs in via SSH to write the baseline, so an unusable VM fails loudly at adoption. Never use `make clean-all` for pool cleanup; delete by label: `oc delete vm,svc,secret -n "$NAMESPACE" -l virt-cbt-lab/pool=<pool>` plus `virt-cbt-lab/run-id=<pool>-NNNN`-labeled backups/PVCs/trackers.

`make clean-all` deletes the workflow-managed resources for all runs in the namespace. Do not run it for scenario triage, E2E/chaos validation, or post-run cleanup; use it only for an explicitly requested cleanup task.

Validation commands:

```sh
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
make help
make e2e
make clean-all
```

The last two commands require a compatible OpenShift Virtualization/KubeVirt cluster. Do not claim E2E success from syntax checks alone.

Run `./preflight` or `make preflight` before any individual workflow target. `make e2e` runs the same preflight automatically before starting `vm-cbt-demo`. It performs read-only local, kubeconfig, OpenShift access, KubeVirt capability, storage, permission, and guest-SSH checks. A failure blocks the workflow with exit 1; it never installs tools or changes cluster resources. Use `./preflight --help` for usage and `./preflight --verbose` for the safe diagnostic summary.

**Need a longer live backup-copy window** (e.g. for a chaos scenario that must land mid-copy)? The default demo sizing finishes the copy in a few seconds on `cbt-demo-hpp` because it's page-cache-absorbed at that scale — a bigger PVC alone does not help. Set `MANIFEST_VARIANT=large` plus a correspondingly large `GUEST_DATA_SIZE_MB`/`GUEST_INCREMENTAL_DATA_SIZE_MB` (see `.env.example` for measured values that produce a ~28s full / ~16s incremental backup); this swaps in `manifests/vm-large.yaml`, `manifests/full-backup-large.yaml`, and `manifests/incremental-backup-large.yaml` and does not change default `make e2e` behavior otherwise. Verify the actual window with `scripts/monitor.sh <vm_name>`, not by assumption — see `docs/vm-cbt-workflow.md` for the measured data points.


## Agent-operating contract

When an AI agent drives this workflow (interactively or in a chaos/test harness), follow this contract in addition to the human conventions below:

- Prefer the documented `make` targets (`preflight`, `vm-setup`, `vm-backup`, `vm-cbt-backup`, `vm-cbt-extend`, `vm-cbt-recover`, `vm-cbt-reconcile`, `vm-cbt-verify`, `vm-cbt-restore-test`, `run-summary`, `e2e`) over invoking `scripts/*.sh` directly; the stage scripts assume the identity resolution and preflight policy that `scripts/stage.sh` provides.
- When debugging, execute one lifecycle phase at a time (`make vm-setup`, then `make vm-backup`, …) and use `make e2e` for the final integrated check — not as the first diagnostic step for a narrow failure.
- Pass the same `RUN_ID`/`VM` and the same `VM_OS`/`MANIFEST_VARIANT`/`GUEST_*` configuration to every phase of a given lifecycle; do not let a later phase infer or guess identity from shell state left over from an earlier invocation.
- Read each phase's stdout/stderr and the run's `runs/<run-id>/run.json`, `report.json`, and `summary.json` instead of guessing resource names, checkpoint names, or lifecycle state.
- Use `STAGE_DRY_RUN=true` and `make preflight` before a risky or expensive mutating action, and `make stage-list` / `make -n <target>` to confirm a target's real behavior before relying on it.
- Never invent `make` targets, environment variables, resource names, API fields, or success criteria. Confirm them from `make help`, `make -n`, `make stage-list`, the actual script source, and `docs/vm-cbt-workflow.md` — not from memory or assumption.
- Never report success without checking the command's actual exit status and the relevant `report.json`/`summary.json` evidence; a `Done=True` condition or a zero exit status alone is not sufficient for backup/restore claims.
- On failure, preserve the run's evidence (`runs/<run-id>/`), identify the failing stage and its first meaningful error, and use the documented recovery path (`make vm-cbt-reconcile`, `make vm-cbt-recover`) rather than blindly rerunning the whole workflow or deleting state.
- Do not run multiple mutating stages concurrently against the same run or checkout; `scripts/stage.sh` and `scripts/e2e-stage.sh` share a single checkout lock (`state/e2e.lock`) and will refuse a second mutating invocation while one is active — treat that refusal as a signal to wait, not to force past it.
- Distinguish local/offline tests (`tests/*.sh`, no cluster contact), mocked/stubbed tests, and real-cluster tests in every summary; do not claim cluster behavior was verified when only a syntax or unit check ran.
- Do not change cluster-wide configuration or delete resources outside this workflow's ownership (its labeled VMs/DataVolumes/Services/backups/PVCs); `make clean-all` is an explicit, human-requested action, never a routine recovery step.

## Coding conventions

- Keep scripts Bash with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Quote expansions, use arrays for multi-word command arguments, and use `printf` rather than unportable `echo` behavior.
- Reuse `scripts/common.sh` constants and `oc_cmd`; do not duplicate resource names or kubeconfig logic.
- Check required commands and fail with a useful stderr message.
- Keep Kubernetes names and manifest/script behavior synchronized with `README.md` and `docs/vm-cbt-workflow.md`.
- Preserve executable bits on scripts. Keep YAML and shell changes small and reviewable.

## Shell-specific rules

- Use traps for temporary files and background port-forward cleanup.
- Never interpolate secrets into logs or committed manifests.
- Do not broaden SSH host-key exceptions beyond the existing ephemeral localhost port-forward.
- Treat cleanup as potentially destructive: namespace deletion is intentional and must remain explicit in documentation.
- New environment-dependent behavior requires a documented variable and a placeholder in `.env.example`.

## Files that must never contain secrets

Never commit credentials, tokens, API keys, passwords, private keys, kubeconfigs, logs containing sensitive output, or environment-specific internal hostnames/paths. This includes `.env`, manifests, shell scripts, documentation, examples, and test data. `.gitignore` protects common local artifacts, but review `git status` before every commit.

## Documentation expectations

Update `README.md` for user-visible setup, configuration, commands, outputs, or limitations. Update `docs/vm-cbt-workflow.md` for detailed workflow semantics. Keep examples sanitized and executable in principle; do not document private defaults.

## Change rules

1. Inspect the affected script, manifest, and all callers before editing.
2. Preserve the fixed resource contract unless the change explicitly includes a coordinated migration.
3. Run shell syntax checks after shell edits and execute the changed offline command where possible.
4. Review the diff and perform a secret scan before proposing a commit.
5. Do not commit or push automatically.

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
- `sync.sh`: optional SSH/rsync helper; it reads `REMOTE_HOST` and `REMOTE_DIR` from the environment or local `.env`.

## Setup and validation

Copy `.env.example` to `.env`, set local paths, and run `make e2e`. `make` includes `.env`; direct script execution requires exporting it first:

```sh
cp .env.example .env
$EDITOR .env
set -a; . ./.env; set +a
make e2e
```

Validation commands:

```sh
find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
make help
make e2e
make clean-all
```

The last two commands require a compatible OpenShift Virtualization/KubeVirt cluster. Do not claim E2E success from syntax checks alone.

Run `./preflight` or `make preflight` before any individual workflow target. `make e2e` runs the same preflight automatically before starting `vm-cbt-demo`. It performs read-only local, kubeconfig, OpenShift access, KubeVirt capability, storage, permission, and guest-SSH checks. A failure blocks the workflow with exit 1; it never installs tools or changes cluster resources. Use `./preflight --help` for usage and `./preflight --verbose` for the safe diagnostic summary.


# AI-agent context and evidence workflow

- Keep this file hot-path and stable: repository contract, safety boundaries, navigation, and verification only.
- Use `.agents/skills/cbt-diagnostics/SKILL.md` for on-demand CBT diagnosis procedure.
- Run `make ai-context` for a metadata-only inventory of `logs/` and `validation/`; it does not inspect log content for matches or emit it.
- Select evidence explicitly with `scripts/ai-context.sh --file PATH --snippets [--focus REGEX]`. Use `--raw-range PATH:S-E` only for exact local evidence; it is unredacted.
- Prefer the smallest relevant `oc get ... -o jsonpath=...` query and resource-scoped Warning events over dumping metrics or logs. Escalate to bounded logs only when status/events leave a causal gap.
- Preserve source artifacts. Report path/resource, query or expression, time/line range, and SHA-256; distinguish observed facts from inference.

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

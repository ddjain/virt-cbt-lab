# Density VM pool via kube-burner + e2e EXISTING_VM adoption

## Context

The repo currently runs one CBT lifecycle per invocation (`make e2e` creates a VM, takes a full backup, N incremental passes, verifies). The user wants a density mode: create a pool of RHEL or Windows CBT-enabled VMs at once using kube-burner, track pool progress with a `density-status` command (total VMs creating / created / full-backup done / incremental pass 1..N done), and then let the e2e pipeline consume pool VMs via a new `EXISTING_VM` argument that adopts an already-created VM and runs the normal lifecycle steps (baseline workload, full backup, incrementals, verify) against it.

Decisions taken (user-confirmed):
- Pool scope: kube-burner creates **VMs only**; the e2e pipeline with `EXISTING_VM` adopts each VM and runs the whole lifecycle.
- Per-VM lifecycles across the pool are driven with **bounded parallel workers** (`DENSITY_CONCURRENCY`, default 3).
- kube-burner runs as a **local binary from PATH** (`KUBE_BURNER_BIN` overrides the path).
- e2e takes a **new `EXISTING_VM=vm-<run-id>` variable** (does not overload `VM=`).

## Approach

### Step 1 — Density labels and `adopt_run_id()` in `scripts/common.sh`

Add constants next to the existing `RUN_LABEL_*` block (~line 28-34):

```bash
RUN_LABEL_DENSITY_POOL_KEY="virt-cbt-lab/density-pool"
RUN_LABEL_OS_PROFILE_KEY="virt-cbt-lab/os-profile"
```

Add a new function `adopt_run_id()` (place after `new_run_id()`, ~line 360). Signature/behavior:

- Requires `EXISTING_VM` in the form `vm-<run-id>`; derives `RUN_ID="${EXISTING_VM#vm-}"`, validates with `valid_run_id`, calls `set_resource_names`.
- Fails if `$RUN_DIR` already exists ("run artifacts exist; choose an unadopted pool VM").
- Reads the VM via `oc_cmd get vm "$VM_NAME" -n "$NAMESPACE" -o json` and fails unless labels match: `app.kubernetes.io/managed-by=virt-cbt-lab`, `$RUN_LABEL_DENSITY_POOL_KEY` non-empty, `$RUN_LABEL_OS_PROFILE_KEY == "$VM_OS"`.
- Verifies `vmbackuptracker/$TRACKER_NAME`, `vmbackup/$FULL_BACKUP_NAME`, and `pvc/$FULL_BACKUP_PVC_NAME` are absent in `$NAMESPACE` (same invariant `new_run_id` enforces for fresh runs).
- Calls `initialize_run_directory` and `workflow_action "Adopting existing pool VM $VM_NAME as run $RUN_ID"`.

### Step 2 — kube-burner config and VM templates (new `manifests/density/`)

**`manifests/density/kube-burner-config.yml`** — job config rendered by kube-burner from environment variables (kube-burner renders the config file with env vars as template input):

```yaml
global:
  timeout: {{ .DENSITY_TIMEOUT }}
  gc: false
  waitWhenFinished: false
jobs:
  - name: density-vm-pool
    jobType: create
    jobIterations: {{ .DENSITY_VM_COUNT }}
    namespace: "{{ .NAMESPACE }}"
    namespacedIterations: false
    cleanup: false
    preLoadImages: false
    verifyObjects: true
    errorOnVerify: true
    qps: 5
    burst: 5
    objects:
      - objectTemplate: manifests/density/vm-{{ .VM_OS }}.yml.tmpl
        replicas: 1
        wait: false
        inputVars:
          poolTag: "{{ .POOL_TAG }}"
          namespace: "{{ .NAMESPACE }}"
          sshPublicKey: "{{ .SSH_PUBLIC_KEY }}"
          dataSourceName: "{{ .DATA_SOURCE_NAME }}"
          dataSourceNamespace: "{{ .DATA_SOURCE_NAMESPACE }}"
          storageClass: "{{ .STORAGE_CLASS }}"
          rootDiskSize: "{{ .ROOT_DISK_SIZE }}"
          oobeSecret: "{{ .OOBE_SECRET }}"
```

Critical: `cleanup: false`, job `gc: false`, global `gc: false`, `preLoadImages: false` — kube-burner's namespace cleanup/garbage-collect would otherwise delete the **shared** namespace `vm-cbt-demo`; pre-pull has nothing to pull for VM objects. `wait: false` on the object: readiness is verified by `density-setup.sh` itself (Step 3).

**`manifests/density/vm-rhel9.yml.tmpl`** — go-template, structurally identical to `manifests/vm-large-odf.yaml` (VirtualMachine + SSH Service, two YAML documents), with:

```yaml
{{- $runId := printf "%s-%02d" .poolTag (add .Iteration 1) -}}
```

used for `vm-{{$runId}}`, `vm-disk-{{$runId}}`, `vm-ssh-{{$runId}}`, and the label `virt-cbt-lab/run-id: {{$runId}}`. Labels on VM and DataVolume: `cbt-demo: enabled`, `app.kubernetes.io/managed-by: virt-cbt-lab`, `virt-cbt-lab/run-id: {{$runId}}`, `virt-cbt-lab/density-pool: {{ .poolTag }}`, `virt-cbt-lab/os-profile: rhel9`. Spec mirrors vm-large-odf.yaml exactly (runStrategy Always, 1 core / 4Gi memory, masquerade + SSH port 22, cloud-init `cbt-demo` user with `ssh_authorized_keys: {{ .sshPublicKey }}`, qemu-guest-agent runcmd, `sourceRef` DataSource `{{ .dataSourceName }}` in `{{ .dataSourceNamespace }}`, storageClassName `{{ .storageClass }}`, storage `{{ .rootDiskSize }}`, volumeMode Filesystem). Service doc mirrors the existing SSH Service (selector `vm.kubevirt.io/name: vm-{{$runId}}`, port 22), carrying the same managed-by/run-id/density-pool labels.

**`manifests/density/vm-windows.yml.tmpl`** — mirrors `manifests/windows-vm.yaml` (VirtualMachine only, no Service): same `$runId` pattern, sysprep secret `{{ .oobeSecret }}`, DataSource `windows-server-2022` in `vm-cbt-images`, storageClassName `{{ .storageClass }}` (default `ocs-storagecluster-ceph-rbd-virtualization`), storage `{{ .rootDiskSize }}` (default `40Gi`), volumeMode Block, 4 cores / 8Gi, q35 EFI no secure boot, guest-agent channel. Labels as above with `virt-cbt-lab/os-profile: windows`. Does not reference `.sshPublicKey` (set to `""` for windows runs).

### Step 3 — `scripts/density-setup.sh` (new)

`#!/usr/bin/env bash`, `set -euo pipefail`, sources `common.sh`, `WORKFLOW_NAME="density-setup"` (the existing phase-label fallback in `common.sh` renders it as "DENSITY SETUP"). No equivalent exists today; this is the kube-burner entry point.

Variables (all with defaults, validated like `validate_positive_integer`):
- `DENSITY_VM_COUNT` (required, 1–99), `VM_OS` (must be `rhel9` or `windows` — reject `debian` with a clear message), `DENSITY_CONCURRENCY` (default 3), `DENSITY_VM_READY_TIMEOUT` (minutes; default 30 for rhel9, 60 for windows), `DENSITY_TIMEOUT` (kube-burner global timeout, default `2h`), `DENSITY_STORAGE_CLASS`, `DENSITY_ROOT_DISK_SIZE` (defaults per OS below), `KUBE_BURNER_BIN` (default `kube-burner`).

Flow (using `workflow_step`/`workflow_action`/`workflow_success`):
1. `require_command "$KUBE_BURNER_BIN"`, `require_command oc`, `require_command jq`; for rhel9 also `require_command ssh`.
2. Profile map (mirrors `set_vm_os_profile` + large-odf sizing; no equivalent reusable function covers all fields):
   - rhel9: DataSource `rhel9`/`openshift-virtualization-os-images`, storage `ocs-storagecluster-ceph-rbd`, disk `80Gi`.
   - windows: DataSource `windows-server-2022`/`vm-cbt-images`, storage `ocs-storagecluster-ceph-rbd-virtualization`, disk `40Gi`.
   - `DENSITY_STORAGE_CLASS`/`DENSITY_ROOT_DISK_SIZE` override the storage fields only.
3. Generate `POOL_TAG="den$(date -u +%y%m%d%H%M)-<2-hex>"` (2-hex via the same `od -An -N1 -tx1 /dev/urandom | tr -d ' \n'` pattern from `run-id.sh`; total ≤ 16 chars so `vm-<pool_tag>-NN` resource names stay under 63 chars and run IDs under 40). Fail if any VM already carries label `virt-cbt-lab/density-pool=<tag>` or any `runs/<tag>-*` directory exists.
4. rhel9: `public_key="$(ensure_guest_key)"` (also pre-creates the shared key before parallel workers run later). windows: verify DataSource `windows-server-2022` exists and `dv/windows-golden` is Succeeded (same checks as `windows-vm-setup.sh` step 1); require `WINDOWS_ADMIN_PASSWORD_FILE` readable; create the **shared pool OOBE secret** `windows-oobe-$POOL_TAG` by rendering `scripts/windows-oobe.xml.tmpl` with the same inline `python3` invocation used in `windows-vm-setup.sh` steps 29-74 (reuse the template file; do not refactor `windows-vm-setup.sh`), labeled `app.kubernetes.io/managed-by=virt-cbt-lab` + `virt-cbt-lab/density-pool=$POOL_TAG` so `clean-all.sh` reclaims it.
5. Export the template env vars (`POOL_TAG`, `NAMESPACE`, `VM_OS`, `DENSITY_VM_COUNT`, `SSH_PUBLIC_KEY` (contents of `$GUEST_KEY.pub`, empty for windows), `DATA_SOURCE_NAME`, `DATA_SOURCE_NAMESPACE`, `STORAGE_CLASS`, `ROOT_DISK_SIZE`, `OOBE_SECRET`, `DENSITY_TIMEOUT`) and run:
   `"$KUBE_BURNER_BIN" init -c manifests/density/kube-burner-config.yml --uuid "$POOL_TAG"`
   from `$ROOT_DIR` (kube-burner resolves the relative `objectTemplate` path against the working directory; it reads the same `KUBECONFIG` that `common.sh` exports).
6. Readiness with bounded parallel workers: for each index `01..N`, run a background subshell that runs `oc_cmd wait "vm/vm-$POOL_TAG-$idx" -n "$NAMESPACE" --for=jsonpath='{.status.ready}'=true --timeout=${DENSITY_VM_READY_TIMEOUT}m` then checks `.status.changedBlockTracking.state == Enabled`, writing `ok`/`fail` to a per-VM result file under a `mktemp -d` dir. Cap concurrency at `DENSITY_CONCURRENCY` with a `while (( $(jobs -rp | wc -l) >= DENSITY_CONCURRENCY )); do wait -n; done` loop; `wait` all; trap-cleanup the temp dir.
7. Print per-VM results and a summary (`created=N failed=M`). Exit 1 if any VM failed (failed VMs stay for triage; do not delete). On success print:
   `Pool $POOL_TAG ready: N VM(s). Next: make density-status POOL=$POOL_TAG · make density-run POOL=$POOL_TAG`

### Step 4 — `scripts/density-status.sh` (new)

`WORKFLOW_NAME="density-status"`. Usage: `density-status.sh [POOL] [--json]` (either order; `-h/--help` prints usage). Read-only.

1. `oc_cmd get vm -n "$NAMESPACE" -l "virt-cbt-lab/density-pool"` (append `=<POOL>` when given) `-o json`. If empty: print `No density-pool VMs found in namespace <ns>.` and exit 0.
2. Per VM compute:
   - `run_id` = name minus `vm-` prefix; `pool` / `os` from labels; `ready` = `.status.ready == true`; `cbt` = `.status.changedBlockTracking.state`.
   - Lifecycle from `runs/<run_id>/run.json` when present: `.status`, `.backups.full != null`, `.incremental_passes_completed`, `.incremental_passes_total`.
   - Stage precedence: `failed` (status in `full_failed`/`incremental_failed`/`cleaned`) → `complete` (status `complete`) → `creating` (not ready) → `created` (ready + CBT Enabled, no full backup yet) → `full_done` → `incr_<k>` (k = `incremental_passes_completed`).
3. Incremental columns = max of `$GUEST_INCREMENTAL_PASSES` (default 1) and the largest `incremental_passes_total` across the pool's run.json files.

Plain-text output (columns per user request — total/creating/created/full/incr-1..N):

```
Density pool den2610141203-a7f · namespace vm-cbt-demo
VM                          OS      STAGE     CREATING CREATED FULL INCR-1 INCR-2 COMPLETE
vm-den2610141203-a7f-01     rhel9   complete  -        -       ✓    ✓      ✓      ✓
vm-den2610141203-a7f-02     rhel9   incr_1    -        ✓       ✓    ✓      -      -
Summary: total=2 creating=0 created=0 full_done=2 incr1_done=2 incr2_done=1 complete=1 failed=0
```

`✓` = stage reached, `-` = not reached; `CREATING`/`CREATED` are exclusive per row (stage snapshot). `--json` prints a jq array: `[{vm, run_id, pool, os, stage, ready, cbt_enabled, full_backup_done, incremental_passes_completed, incremental_passes_total, lifecycle_status}]` plus a trailing summary object. Exit 0 unless the `oc` query itself fails.

### Step 5 — e2e `EXISTING_VM` adoption

**`scripts/e2e-stage.sh`:**
- Add `EXISTING_VM="${EXISTING_VM:-}"` to the defaults block (~line 8-19).
- Validation (before the TYPE case, ~line 278): `EXISTING_VM` is valid only with `TYPE=all` or `TYPE=full`; must be `vm-<run-id>`; `VM`/`NAME` must be empty or resolve to the same run ID. Fail with `[e2e] EXISTING_VM requires TYPE=all or TYPE=full (got: ...)` style messages via existing `fail()`.
- In `resolve_new_run_id()` (used by TYPE=all/full): when `EXISTING_VM` is set, derive `run_id` from it (skip random generation; keep the NAME/VM consistency checks). Cluster-side adopt validation stays in `vm-setup.sh` via `adopt_run_id()`.
- `profile_args()`: append `EXISTING_VM=$EXISTING_VM` so it reaches `vm-setup` through `vm-cbt-demo`/`vm-setup` targets.
- `print_pipeline_summary()` TYPE=all/full: when adopting, print `  Adopting existing density-pool VM: %s` instead of the "Namespace: ... VirtualMachine: ..." creation lines; keep backup/PVC plan lines.
- **Per-run lock**: change `lock_dir="$ROOT_DIR/state/e2e.lock"` (~line 309) to `lock_dir="$ROOT_DIR/state/e2e-$run_id.lock"`; update the conflict message to `"Another E2E operation is active for run $run_id (PID $lock_pid); density runs execute distinct runs in parallel."` This intentionally allows parallel e2e for **different** run IDs (required by `density-run`); same-run mutual exclusion is preserved.

**`scripts/vm-setup.sh`** (rhel9 path):
- Replace the bare `new_run_id` call (line 10) with: `if [[ -n "${EXISTING_VM:-}" ]]; then adopt_run_id; else new_run_id; fi`.
- Gate step 1 (image source prep) and step 3's `sed | oc apply` behind `if [[ -z "${EXISTING_VM:-}" ]]`; in the adopt branch verify instead: `oc_cmd get vm "$VM_NAME"` and `oc_cmd get service "$SSH_SERVICE"` exist (step 4's wait/CBT/uid logic already works unchanged on an existing VM).
- Step 2 (guest key), step 4 (wait ready + CBT + read uid), step 5 (baseline workload + `vm_info_initialize`) run unchanged.

**`scripts/windows-vm-setup.sh`:**
- Same `adopt_run_id` vs `new_run_id` switch (line 17).
- In the adopt branch skip steps 1–3 (DataSource wait, OOBE secret creation, manifest apply) — the pool secret `windows-oobe-$POOL_TAG` already exists and the VM references it; verify the VM exists. Steps 4–5 (agent wait, CBT/uid, baseline via guest exec, `vm_info_initialize`) run unchanged.

**`scripts/clean-all.sh`:**
- Replace the single `STATE_DIR/e2e.lock/pid` check (lines 6-12) with a loop over `"$STATE_DIR"/e2e-*.lock` directories, refusing cleanup if any live PID holds one. The final `rm -rf "$STATE_DIR"` (line 90) already removes all per-run locks.

### Step 6 — `scripts/density-run.sh` (new)

`WORKFLOW_NAME="density-run"`. Usage: `density-run.sh <POOL>` (POOL required; `-h/--help` prints usage). Drives every **unadopted** pool VM through the full lifecycle with bounded parallel workers.

1. List pool VMs by label `virt-cbt-lab/density-pool=<POOL>`; fail if none.
2. Partition: `pending` = VMs with no `runs/<run_id>/` directory; `in_progress_or_done` = the rest. Only `pending` VMs are processed — partially processed or failed VMs must be continued with the existing `make e2e TYPE=incremental|extend|recover VM=...` interface (print this hint in the summary; re-adoption is impossible because run IDs are immutable).
3. For each pending VM, spawn (bounded by `DENSITY_CONCURRENCY`, default 3, same `wait -n` pattern as Step 3): `make e2e TYPE=all EXISTING_VM=vm-<run_id>` with the current environment (Makefile exports forward `GUEST_*`, `NAMESPACE`, `DENSITY_CONCURRENCY`, etc.), stdout/stderr teed to `runs/<run_id>/logs/density-e2e.log` (`mkdir -p` first).
4. After all workers: per-VM PASS/FAIL lines and `Summary: total=N passed=P failed=F skipped(already adopted)=S`; exit 1 if any worker failed.

### Step 7 — Makefile, `.env.example`, docs

**`Makefile`:**
- Add to the `export` line (line 6): `EXISTING_VM DENSITY_VM_COUNT DENSITY_CONCURRENCY DENSITY_VM_READY_TIMEOUT DENSITY_STORAGE_CLASS DENSITY_ROOT_DISK_SIZE KUBE_BURNER_BIN POOL`.
- New targets (in `.PHONY` list too):

```make
density-setup:
	@./scripts/density-setup.sh

density-status:
	@./scripts/density-status.sh $(POOL)

density-run:
	@./scripts/density-run.sh $(POOL)
```

- `help`: add a `DENSITY` section:
  - `make density-setup VM_OS=rhel9 DENSITY_VM_COUNT=5` — create a kube-burner VM pool (rhel9 or windows).
  - `make density-status [POOL=den...]` — pool progress table (creating/created/full/incr-N/complete).
  - `make density-run POOL=den... DENSITY_CONCURRENCY=3` — run full e2e per unadopted pool VM in parallel.
  - `make e2e TYPE=all EXISTING_VM=vm-<run-id>` — adopt one pool VM and run its lifecycle.

**`.env.example`:** append a documented block (repo rule: every new environment-dependent variable gets a placeholder): `DENSITY_VM_COUNT=`, `DENSITY_CONCURRENCY=3`, `DENSITY_VM_READY_TIMEOUT=`, `DENSITY_STORAGE_CLASS=`, `DENSITY_ROOT_DISK_SIZE=`, `KUBE_BURNER_BIN=kube-burner` — with comments noting pool VMs land in the shared `NAMESPACE`, `density-run` only adopts VMs without existing run artifacts, and kube-burner must be installed (https://kube-burner.github.io/kube-burner/latest/).

**Docs** (repo rule: user-visible commands): `README.md` workflow section gets the four density commands and the `EXISTING_VM` e2e form; `docs/vm-cbt-workflow.md` gets a "Density VM pools" section documenting the pool label contract, the per-run e2e lock change (parallel e2e now allowed across distinct runs), the shared per-pool Windows OOBE secret, and the status-stage semantics from Step 4.

### Step 8 — Offline test `tests/test-density-status.sh` (new)

Follow the `tests/test-monitor-planned-backups.sh` pattern: `mktemp -d`, fake `oc` on `PATH` (returns a fixed `oc get vm -l ... -o json` list with 4 VMs across one pool: one not-ready, one ready without run.json, one with run.json `status=incremental_ready` + full + 1 incremental, one `status=complete` with 2 incrementals), run.json fixtures under `runs/<run-id>/`, `unset KUBECONFIG KUBECONFIG_PATH`. Assert:
- table contains the expected `STAGE` values (`creating`, `created`, `incr_1`, `complete`) and the exact `Summary: total=4 creating=1 created=1 full_done=2 incr1_done=2 incr2_done=1 complete=1 failed=0` line,
- `--json` output validates with `jq -e` on stage/full/incr fields,
- `POOL` filter narrows rows,
- empty pool prints the no-VMs message and exits 0.

Add `@bash tests/test-density-status.sh` to the `make test` target list.

## Critical files & anchors

- `scripts/common.sh` (~28-34 label constants; ~319-360 `new_run_id` — add `adopt_run_id` after): shared adoption/validation core.
- `scripts/e2e-stage.sh` (~94-114 `resolve_new_run_id`; ~240-252 `profile_args`; ~308-327 lock): `EXISTING_VM` plumbing and per-run lock.
- `scripts/vm-setup.sh` (line 10 `new_run_id`; steps 1/3 gating): rhel9 adopt branch.
- `scripts/windows-vm-setup.sh` (line 17; steps 1-3 gating): windows adopt branch.
- `manifests/vm-large-odf.yaml` and `manifests/windows-vm.yaml`: structural sources for the two kube-burner templates (reread before writing the templates).

## Verification

Offline (no cluster):
1. `find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n`
2. `make test` — all existing tests plus the new density-status test pass.
3. `make help` — density section renders.
4. `./scripts/density-status.sh --help` and `bash -n` on the three new scripts.

Cluster (requires OpenShift Virtualization with CBT feature gate, the rhel9 DataSource, and kube-burner ≥ v1.10 in PATH):
5. `make density-setup VM_OS=rhel9 DENSITY_VM_COUNT=2` — exits 0, prints pool tag, both VMs Ready with CBT Enabled.
6. `make density-status` — both rows `STAGE=created`; `--json` fields correct.
7. Single-VM adoption: on a fresh pool, `make e2e TYPE=all EXISTING_VM=vm-<pool>-01` — full lifecycle passes (baseline, full backup, incremental, verify), `runs/<run-id>/run.json` reaches `status=complete`.
8. `make density-run POOL=<tag> DENSITY_CONCURRENCY=2` — remaining pool VM completes in parallel; `make density-status` shows `complete` with full/incr checkmarks; exit 0.
9. Lock behavior: while one `density-run` worker holds `state/e2e-<run>.lock`, a second `make e2e TYPE=all EXISTING_VM=<same-vm>` fails with the per-run lock message; a different run proceeds.
10. Windows variant: `make density-setup VM_OS=windows DENSITY_VM_COUNT=1` (requires golden DataSource + `WINDOWS_ADMIN_PASSWORD_FILE`) then steps 6-8 for that pool.
11. `make clean-all` — deletes pool VMs, DVs, services, OOBE secret, and backup resources via the existing managed-by label selector.

## Assumptions & contingencies

- kube-burner ≥ v1.10 is installed (or `KUBE_BURNER_BIN` points at it); it renders the config from environment variables and reads `KUBECONFIG` — both documented behaviors. If env-based config templating does not work in the installed version, fall back to writing the same keys to a JSON file passed via `--user-data` (no other change).
- If `verifyObjects` reports false failures for VirtualMachine objects, set `verifyObjects: false` — `density-setup.sh`'s own readiness+CBT poll is the authoritative check.
- Pool VMs share the existing `NAMESPACE`; density does not create per-pool namespaces (preserves the fixed resource contract and `clean-all.sh` behavior).
- `density-run` only adopts VMs with no `runs/<run-id>/` artifacts; interrupted or failed pool lifecycles are continued with the existing `TYPE=incremental|extend|recover VM=...` commands (run IDs are immutable).
- Windows pool VMs share one OOBE secret per pool (`windows-oobe-<pool-tag>`); the Administrator password never appears in manifests, logs, or the repo.
- The e2e lock intentionally becomes per-run: parallel e2e for distinct runs is now allowed (required by `density-run`); same-run serialization is unchanged. If this proves unsafe in practice (e.g., shared-key races), the fallback is a `DENSITY_ALLOW_PARALLEL=true` gate that keeps the checkout-wide lock for non-density use.
- Default density sizing: rhel9 = 80Gi root on `ocs-storagecluster-ceph-rbd`; windows = 40Gi root on `ocs-storagecluster-ceph-rbd-virtualization` — overridable via `DENSITY_STORAGE_CLASS`/`DENSITY_ROOT_DISK_SIZE`. A large pool of windows VMs at 8Gi/4-core each should be sized against cluster capacity by the operator.

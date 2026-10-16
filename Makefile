SHELL := /bin/bash

-include .env
UTC_TIMESTAMP = $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

export DEBUG KUBECONFIG_PATH GUEST_KEY REMOTE_HOST REMOTE_DIR RESTORE_HELPER_IMAGE GUEST_BASE_FILE_COUNT GUEST_INCREMENTAL_FILE_COUNT GUEST_INCREMENTAL_PASSES EXTEND_TO_PASS GUEST_FILE_SIZE_MIN_MIB GUEST_FILE_SIZE_MAX_MIB GUEST_INVENTORY_VERIFY GUEST_INVENTORY_SAMPLE_STRIDE MANIFEST_VARIANT NAMESPACE WINDOWS_ISO_PATH WINDOWS_ADMIN_PASSWORD_FILE VM_OS TYPE VM NAME RUN_ID GUEST_EXEC_POLL_INTERVAL GUEST_EXEC_POLL_ATTEMPTS EXISTING_VM POOL DENSITY_VM_COUNT DENSITY_INCREMENTAL_PASSES DENSITY_QPS DENSITY_WAIT_MINUTES STAGE_DRY_RUN STAGE_SKIP_PREFLIGHT

ifeq ($(strip $(VM_OS)),)
VM_OS := rhel9
endif
ifeq ($(strip $(MANIFEST_VARIANT)),)
MANIFEST_VARIANT := large-odf
endif

# scripts/stage.sh picks the setup script from VM_OS (windows ->
# scripts/windows-vm-setup.sh, otherwise scripts/vm-setup.sh); the Makefile
# only rejects unsupported profiles early.
ifeq ($(filter $(VM_OS),debian rhel9 windows),)
$(error VM_OS must be either debian, rhel9, or windows, got '$(VM_OS)')
endif
ifeq ($(strip $(GUEST_INCREMENTAL_PASSES)),)
GUEST_INCREMENTAL_PASSES := 1
endif


# Optional fixed run name instead of the default random one.
NAME ?=
TYPE ?= all
EXISTING_VM ?=
POOL ?=
.PHONY: preflight vm-setup vm-backup vm-cbt-backup vm-cbt-extend vm-cbt-recover vm-cbt-reconcile vm-cbt-verify vm-cbt-restore-test vm-cbt-demo e2e e2e-incremental stage-list run-summary clean-all monitor windows-golden-image windows-vm-setup windows-e2e density-setup density-status sync resync pull-reports help test

preflight:
	@./scripts/stage.sh preflight

sync:
	@./sync.sh

resync: sync

pull-reports:
	@./sync.sh --pull-reports

# Individual stages funnel through scripts/stage.sh, the same code path make e2e
# uses (scripts/e2e-stage.sh sets E2E_STAGE_WRAPPED=true and calls these
# targets). Identity rules and the automatic preflight live in the dispatcher;
# the Makefile only keeps the DEBUG banner and passes the environment through.
vm-setup:
	@if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] [1/1] VM setup (%s): create the CBT-enabled VM and initialize the baseline file workload.\n' "$(UTC_TIMESTAMP)" "$(VM_OS)"; fi
	@./scripts/stage.sh setup

vm-backup:
	@if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] [1/1] Full backup: create the backup PVC, tracker, and full backup.\n' "$(UTC_TIMESTAMP)"; fi
	@./scripts/stage.sh full
vm-cbt-recover:
	@if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] [1/1] Same-VM recovery: force a new full backup through the existing tracker, verify it, then restore the baseline.\n' "$(UTC_TIMESTAMP)"; fi
	@./scripts/stage.sh recover

vm-cbt-backup:
	@if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] [1/1] Incremental backup: mutate guest data and create the CBT incremental backup.\n' "$(UTC_TIMESTAMP)"; fi
	@./scripts/stage.sh incremental
vm-cbt-extend:
	@if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] [1/1] Extend a completed VM lifecycle by one planned incremental pass.\n' "$(UTC_TIMESTAMP)"; fi
	@./scripts/stage.sh extend

vm-cbt-reconcile:
	@if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] [1/1] Reconcile a failed incremental pass back to incremental_ready after its resources are deleted and the tracker is verified.\n' "$(UTC_TIMESTAMP)"; fi
	@./scripts/stage.sh reconcile


vm-cbt-verify:
	@if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] [1/1] Verification: validate VM CBT state, backup types, completion, and checkpoints.\n' "$(UTC_TIMESTAMP)"; fi
	@./scripts/stage.sh verify

vm-cbt-restore-test:
	@if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] [1/1] Restore test: rebuild the guest disk through every incremental checkpoint and verify each file set.\n' "$(UTC_TIMESTAMP)"; fi
	@./scripts/stage.sh restore-test

stage-list:
	@./scripts/stage.sh list

run-summary:
	@if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] [1/1] Run summary: write runs/<run-id>/summary.json and print the lifecycle verdict.\n' "$(UTC_TIMESTAMP)"; fi
	@./scripts/stage.sh summary

vm-cbt-demo:
	@set -e; \
	  source ./scripts/run-id.sh; \
	  run_id="$${RUN_ID:-$$(generate_run_id)}"; \
	  run_timed_step() { \
	    step_name="$$1"; shift; \
	    start_epoch="$$(date +%s)"; \
	    if "$$@"; then step_status=0; else step_status=$$?; fi; \
	    end_epoch="$$(date +%s)"; \
	    timing_timestamp="$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	    timing_line="Step timing: $$step_name elapsed_seconds=$$((end_epoch - start_epoch))."; \
	    if [[ -d "runs/$$run_id/logs" ]]; then printf '[%s] [make] %s\n' "$$timing_timestamp" "$$timing_line" >> "runs/$$run_id/logs/workflow.log"; fi; \
	    if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] %s\n' "$$timing_timestamp" "$$timing_line" >&2; fi; \
	    return "$$step_status"; \
	  }; \
	  export STAGE_SKIP_PREFLIGHT=true; \
	  if [[ "$(E2E_STAGE_WRAPPED)" != true ]]; then \
	    if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] Preflight once for the whole demo pipeline; child stages skip it.\n' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi; \
	    $(MAKE) --no-print-directory preflight VM_OS=$(VM_OS); \
	  fi; \
	  if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] Demo: setup, full backup, and %s incremental pass(es).\n' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(GUEST_INCREMENTAL_PASSES)"; fi; \
	  run_timed_step 'VM setup and baseline workload' $(MAKE) --no-print-directory vm-setup VM_OS=$(VM_OS) RUN_ID=$$run_id; \
	  run_timed_step 'Full backup' $(MAKE) --no-print-directory vm-backup VM_OS=$(VM_OS) RUN_ID=$$run_id; \
	  for ((pass = 1; pass <= $(GUEST_INCREMENTAL_PASSES); pass++)); do \
	    if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] Incremental pass %d/%s for run %s.\n' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$pass" "$(GUEST_INCREMENTAL_PASSES)" "$$run_id"; fi; \
	    run_timed_step "Incremental backup pass $$pass/$(GUEST_INCREMENTAL_PASSES)" $(MAKE) --no-print-directory vm-cbt-backup VM_OS=$(VM_OS) RUN_ID=$$run_id; \
	  done; \
	  if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] Demo: verify checkpoint chain and restored prefixes.\n' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi; \
	  run_timed_step 'CBT verification and restore test' $(MAKE) --no-print-directory vm-cbt-verify VM_OS=$(VM_OS) RUN_ID=$$run_id
e2e:
	@MAKE_COMMAND="$(MAKE)" ./scripts/e2e-stage.sh

e2e-incremental: override TYPE = incremental
e2e-incremental: e2e
clean-all:
	@printf '[%s] [make] [1/1] Cleanup: delete demo resources, reclaim their PVs, and remove only the workflow-managed key.\n' "$(UTC_TIMESTAMP)"
	@./scripts/clean-all.sh

monitor:
	@if [[ "$(DEBUG)" == true ]]; then printf '[%s] [make] [1/1] Monitor: watch full/incremental backup start and completion times for VM=%s.\n' "$(UTC_TIMESTAMP)" "$${VM:-vm-$${RUN_ID:-}}"; fi
	@./scripts/stage.sh monitor

windows-golden-image:
	@printf '[%s] [make] [1/1] Windows golden image: install Windows and workloads, sysprep, and cache the DataSource (requires WINDOWS_ADMIN_PASSWORD_FILE; WINDOWS_ISO_PATH only if windows-iso is not Succeeded).\n' "$(UTC_TIMESTAMP)"
	@./scripts/windows-golden-image-setup.sh
windows-vm-setup:
	@VM_OS=windows ./scripts/stage.sh setup

windows-e2e:
	@$(MAKE) --no-print-directory e2e VM_OS=windows

density-setup:
	@$(MAKE) --no-print-directory preflight VM_OS=$(VM_OS)
	@./scripts/density-setup.sh

density-status:
	@./scripts/density-status.sh

help:
	@printf '%s\n' \
	  'Usage: make <target> [VAR=value]' \
	  '' \
	  'WORKFLOW' \
	  '  make e2e                         Full setup, backups, and verification.' \
	  '  make e2e TYPE=full               Start a lifecycle and take its full backup.' \
	  '  make e2e-incremental VM=vm-demo  Add the next pass; final pass verifies.' \
	  '  make e2e TYPE=incremental VM=vm-demo  Equivalent TYPE-based interface.' \
	  '  make e2e TYPE=recover VM=vm-demo  Take and restore-verify a new full on the existing VM.' \
	  '  make e2e TYPE=extend VM=vm-demo EXTEND_TO_PASS=4' \
	  '                                    Add one pass; value is the total planned passes.' \
	  '  make e2e TYPE=reconcile VM=vm-demo  Reset a failed incremental pass to incremental_ready' \
	  '                                    after deleting its failed backup/PVC (tracker verified).' \
	  '  make e2e TYPE=verify VM=vm-demo Re-run chain and restore verification.' \
	  '  make e2e GUEST_INCREMENTAL_PASSES=3 Run three sequential incremental passes.' \
	  '  make e2e EXISTING_VM=vm-<pool>-0001   Run the pipeline on a density-pool VM (TYPE=all|full).' \
	  '  make vm-cbt-demo                 Timed full demo pipeline.' \
	  '' \
	  'STAGES' \
	  '  Every stage below is the same code path make e2e uses; run any one alone.' \
	  '  Each stage takes RUN_ID=<id> or VM=vm-<id> (except vm-setup, which creates the run).' \
	  '  make stage-list                  Machine-readable stage table (stage, make target, args, purpose).' \
	  '  make vm-setup                    Create the VM and baseline workload.' \
	  '                                     e.g. make vm-setup RUN_ID=20261015-demo' \
	  '  make vm-backup RUN_ID=<id>       Full backup: backup PVC, tracker, and full backup.' \
	  '                                     e.g. make vm-backup RUN_ID=20261015-demo' \
	  '  make vm-cbt-backup RUN_ID=<id>   Incremental: mutate guest data, take the CBT incremental.' \
	  '                                     e.g. make vm-cbt-backup RUN_ID=20261015-demo' \
	  '  make vm-cbt-extend RUN_ID=<id> EXTEND_TO_PASS=N' \
	  '                                   Add one pass; value is the total planned passes.' \
	  '                                     e.g. make vm-cbt-extend RUN_ID=20261015-demo EXTEND_TO_PASS=4' \
	  '  make vm-cbt-recover RUN_ID=<id>  Same-VM recovery: new full backup through the tracker, verified.' \
	  '                                     e.g. make vm-cbt-recover RUN_ID=20261015-demo' \
	  '  make vm-cbt-reconcile RUN_ID=<id>  Reset a failed incremental pass to incremental_ready.' \
	  '                                     e.g. make vm-cbt-reconcile RUN_ID=20261015-demo' \
	  '  make vm-cbt-verify RUN_ID=<id>   Verify chain, backup types, completion, and checkpoints.' \
	  '                                     e.g. make vm-cbt-verify RUN_ID=20261015-demo' \
	  '  make vm-cbt-restore-test RUN_ID=<id>  Rebuild the guest disk through every checkpoint.' \
	  '                                     e.g. make vm-cbt-restore-test RUN_ID=20261015-demo' \
	  '  make monitor RUN_ID=<id>         Show backup timings (VM=vm-<id> works the same way).' \
	  '                                     e.g. make monitor RUN_ID=20261015-demo' \
	  '  make run-summary RUN_ID=<id>     Write runs/<id>/summary.json and print the lifecycle verdict.' \
	  '                                     e.g. make run-summary RUN_ID=20261015-demo' \
	  '  make preflight                   Read-only readiness check; also runs before every mutating stage.' \
	  '  Knobs: STAGE_SKIP_PREFLIGHT=true skips that automatic preflight; STAGE_DRY_RUN=true prints' \
	  '         the resolved run identity and the exact command without contacting the cluster.' \
	  '' \
	  'PROFILES' \
	  '  VM_OS: rhel9 (default), debian, windows.' \
	  '  make e2e VM_OS=debian           Use the Debian override.' \
	  '  make windows-e2e                 Alias for Windows E2E.' \
	  '  Windows targets: windows-vm-setup, windows-golden-image.' \
	  '' \
	  'DENSITY' \
	  '  make density-setup VM_OS=rhel9 DENSITY_VM_COUNT=10   Create a density VM pool with kube-burner.' \
	  '  make density-status [POOL=<pool>]  Fleet view of all density VMs; POOL= restricts to one pool.' \
	  '' \
	  'OPERATIONS' \
	  '  make preflight                   Read-only readiness check.' \
	  '  make monitor VM=vm-demo          Show backup timings.' \
	  '  make clean-all                   Delete managed resources; run artifacts remain.' \
	  '  make sync or make resync         Push working files; set REMOTE_HOST/REMOTE_DIR.' \
	  '  make pull-reports                Pull REMOTE_HOST:REMOTE_DIR/runs/ locally.' \
	  '  make test                        Run offline tests.' \
	  '' \
	  'DEFAULTS' \
	  '  TYPE=all; VM_OS=rhel9; MANIFEST_VARIANT=large-odf; NAMESPACE=vm-cbt-demo.' \
	  '  GUEST_BASE_FILE_COUNT=8; GUEST_INCREMENTAL_FILE_COUNT=4.' \
	  '  GUEST_INCREMENTAL_PASSES=1; file sizes=4-12 MiB; DEBUG=false.' \
	  '  Copy .env.example to .env; all variables and prerequisites: README.md.'

test:
	@bash tests/test-default-profile.sh
	@bash tests/test-incremental-passes.sh
	@bash tests/test-vm-cbt-extend.sh
	@bash tests/test-restore-timeout.sh
	@bash tests/test-restore-failure-propagation.sh
	@bash tests/test-workflow-evidence.sh
	@bash tests/test-monitor-planned-backups.sh
	@bash tests/test-monitor-timeout.sh
	@bash tests/test-run-summary.sh
	@bash tests/test-vm-cbt-recover.sh
	@bash tests/test-vm-backup-failure-recording.sh
	@bash tests/test-chaos-watch-resource.sh
	@bash tests/test-chaos-run-id.sh
	@bash tests/test-density-status.sh
	@bash tests/test-density-setup.sh
	@bash tests/test-existing-vm-adoption.sh
	@bash tests/test-stage-dispatch.sh
	@bash tests/test-scenario-verdict.sh
	@bash tests/test-cbt-f-01-driver.sh
	@bash tests/test-cbt-f-01-injection-evidence.sh
	@bash tests/test-trigger-plan-rehearsal.sh
	@bash tests/test-evidence-index.sh

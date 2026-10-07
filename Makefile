SHELL := /bin/bash

-include .env
UTC_TIMESTAMP = $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

export DEBUG KUBECONFIG_PATH GUEST_KEY REMOTE_HOST REMOTE_DIR RESTORE_HELPER_IMAGE GUEST_BASE_FILE_COUNT GUEST_INCREMENTAL_FILE_COUNT GUEST_INCREMENTAL_PASSES EXTEND_TO_PASS GUEST_FILE_SIZE_MIN_MIB GUEST_FILE_SIZE_MAX_MIB MANIFEST_VARIANT NAMESPACE WINDOWS_ISO_PATH WINDOWS_ADMIN_PASSWORD_FILE VM_OS TYPE VM NAME

ifeq ($(strip $(VM_OS)),)
VM_OS := debian
endif
ifeq ($(VM_OS),windows)
VM_SETUP_SCRIPT := scripts/windows-vm-setup.sh
else ifeq ($(VM_OS),debian)
VM_SETUP_SCRIPT := scripts/vm-setup.sh
else ifeq ($(VM_OS),rhel9)
VM_SETUP_SCRIPT := scripts/vm-setup.sh
else
$(error VM_OS must be either debian, rhel9, or windows, got '$(VM_OS)')
endif

# Optional fixed run name instead of the default random one.
NAME ?=
TYPE ?= all
VM ?=

.PHONY: preflight vm-setup vm-backup vm-cbt-backup vm-cbt-extend vm-cbt-verify vm-cbt-restore-test vm-cbt-demo e2e clean-all monitor windows-golden-image windows-vm-setup windows-e2e sync resync pull-reports help test

preflight:
	@printf '[%s] [make] [1/1] Preflight: check local tools and cluster access for VM_OS=%s (read-only).\n' "$(UTC_TIMESTAMP)" "$(VM_OS)"
	@./preflight

sync:
	@./sync.sh

resync: sync

pull-reports:
	@./sync.sh --pull-reports

vm-setup:
	@printf '[%s] [make] [1/1] VM setup (%s): create the CBT-enabled VM and initialize the baseline file workload.\n' "$(UTC_TIMESTAMP)" "$(VM_OS)"
	@./$(VM_SETUP_SCRIPT)

vm-backup:
	@printf '[%s] [make] [1/1] Full backup: create the backup PVC, tracker, and full backup.\n' "$(UTC_TIMESTAMP)"
	@./scripts/vm-backup.sh

vm-cbt-backup:
	@printf '[%s] [make] [1/1] Incremental backup: mutate guest data and create the CBT incremental backup.\n' "$(UTC_TIMESTAMP)"
	@./scripts/vm-cbt-backup.sh
vm-cbt-extend:
	@printf '[%s] [make] [1/1] Extend a completed VM lifecycle by one planned incremental pass.\n' "$(UTC_TIMESTAMP)"
	@./scripts/vm-cbt-extend.sh


vm-cbt-verify:
	@printf '[%s] [make] [1/1] Verification: validate VM CBT state, backup types, completion, and checkpoints.\n' "$(UTC_TIMESTAMP)"
	@./scripts/vm-cbt-verify.sh

vm-cbt-restore-test:
	@printf '[%s] [make] [1/1] Restore test: rebuild the guest disk through every incremental checkpoint and verify each file set.\n' "$(UTC_TIMESTAMP)"
	@./scripts/vm-cbt-restore-test.sh

vm-cbt-demo:
	@set -e; \
	  run_timed_step() { \
	    step_name="$$1"; shift; \
	    start_epoch="$$(date +%s)"; \
	    if "$$@"; then step_status=0; else step_status=$$?; fi; \
	    end_epoch="$$(date +%s)"; \
	    printf '[%s] [make] Step timing: %s elapsed_seconds=%s.\n' \
	      "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$step_name" "$$((end_epoch - start_epoch))" >&2; \
	    return "$$step_status"; \
	  }; \
	  printf '[%s] [make] [1/4] Demo setup: create and initialize the VM.\n' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	  run_timed_step 'VM setup and baseline workload' $(MAKE) --no-print-directory vm-setup VM_OS=$(VM_OS); \
	  printf '[%s] [make] [2/4] Demo full backup: establish the CBT checkpoint.\n' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	  run_timed_step 'Full backup' $(MAKE) --no-print-directory vm-backup VM_OS=$(VM_OS); \
	  printf '[%s] [make] [3/4] Demo incremental backups: run %s sequential pass(es) on the same VM.\n' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(GUEST_INCREMENTAL_PASSES)"; \
	  for ((pass=1; pass<=$(GUEST_INCREMENTAL_PASSES); pass++)); do \
	    printf '[%s] [make] Incremental pass %d/%s.\n' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$pass" "$(GUEST_INCREMENTAL_PASSES)"; \
	    run_timed_step "Incremental backup pass $$pass/$(GUEST_INCREMENTAL_PASSES)" $(MAKE) --no-print-directory vm-cbt-backup VM_OS=$(VM_OS); \
	  done; \
	  printf '[%s] [make] [4/4] Demo verification: confirm every incremental checkpoint and restore prefix.\n' "$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	  run_timed_step 'CBT verification and restore test' $(MAKE) --no-print-directory vm-cbt-verify VM_OS=$(VM_OS)
e2e:
	@MAKE_COMMAND="$(MAKE)" ./scripts/e2e-stage.sh

clean-all:
	@printf '[%s] [make] [1/1] Cleanup: delete demo resources, reclaim their PVs, and remove only the workflow-managed key.\n' "$(UTC_TIMESTAMP)"
	@./scripts/clean-all.sh

monitor:
	@printf '[%s] [make] [1/1] Monitor: watch full/incremental backup start and completion times for VM=%s.\n' "$(UTC_TIMESTAMP)" "$(VM)"
	@./scripts/monitor.sh "$(VM)"

windows-golden-image:
	@printf '[%s] [make] [1/1] Windows golden image: install Windows and workloads, sysprep, and cache the DataSource (requires WINDOWS_ADMIN_PASSWORD_FILE; WINDOWS_ISO_PATH only if windows-iso is not Succeeded).\n' "$(UTC_TIMESTAMP)"
	@./scripts/windows-golden-image-setup.sh
windows-vm-setup:
	@$(MAKE) --no-print-directory preflight VM_OS=windows
	@VM_OS=windows ./scripts/windows-vm-setup.sh

windows-e2e:
	@$(MAKE) --no-print-directory e2e VM_OS=windows

help:
	@printf '%s\n' \
	  'Usage: make <target> [VAR=value]' \
	  '' \
	  'WORKFLOW' \
	  '  make e2e                         Full setup, backups, and verification.' \
	  '  make e2e TYPE=full               Start a lifecycle and take its full backup.' \
	  '  make e2e TYPE=incremental VM=vm-demo' \
	  '                                    Add the next pass; final pass verifies.' \
	  '  make e2e TYPE=extend VM=vm-demo EXTEND_TO_PASS=4' \
	  '                                    Add one pass; value is the total planned passes.' \
	  '  make e2e TYPE=verify VM=vm-demo Re-run chain and restore verification.' \
	  '  make e2e GUEST_INCREMENTAL_PASSES=3 Run three sequential incremental passes.' \
	  '  make vm-cbt-demo                 Timed full demo pipeline.' \
	  '  Individual targets: vm-setup, vm-backup, vm-cbt-backup,' \
	  '                      vm-cbt-extend, vm-cbt-verify, vm-cbt-restore-test.' \
	  '' \
	  'PROFILES' \
	  '  VM_OS: debian (default), rhel9, windows.' \
	  '  make e2e VM_OS=rhel9             Use the RHEL 9 profile.' \
	  '  make windows-e2e                 Alias for Windows E2E.' \
	  '  Windows targets: windows-vm-setup, windows-golden-image.' \
	  '' \
	  'OPERATIONS' \
	  '  make preflight                   Read-only readiness check.' \
	  '  make monitor VM=vm-demo          Show backup timings.' \
	  '  make clean-all                   Delete managed resources; reports remain.' \
	  '  make sync or make resync         Push working files; set REMOTE_HOST/REMOTE_DIR.' \
	  '  make pull-reports                Pull REMOTE_HOST:REMOTE_DIR/report/ locally.' \
	  '  make test                        Run offline tests.' \
	  '' \
	  'DEFAULTS' \
	  '  TYPE=all; VM_OS=debian; MANIFEST_VARIANT=odf; NAMESPACE=vm-cbt-demo.' \
	  '  GUEST_BASE_FILE_COUNT=8; GUEST_INCREMENTAL_FILE_COUNT=4.' \
	  '  GUEST_INCREMENTAL_PASSES=1; file sizes=4-12 MiB; DEBUG=false.' \
	  '  Copy .env.example to .env; all variables and prerequisites: README.md.'

test:
	@bash tests/test-incremental-passes.sh
	@bash tests/test-vm-cbt-extend.sh
	@bash tests/test-monitor-planned-backups.sh

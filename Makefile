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

.PHONY: preflight vm-setup vm-backup vm-cbt-backup vm-cbt-extend vm-cbt-verify vm-cbt-restore-test vm-cbt-demo e2e clean-all monitor windows-golden-image windows-vm-setup windows-e2e sync resync help test

preflight:
	@printf '[%s] [make] [1/1] Preflight: check local tools and cluster access for VM_OS=%s (read-only).\n' "$(UTC_TIMESTAMP)" "$(VM_OS)"
	@./preflight

sync:
	@./sync.sh

resync: sync

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
	  'make preflight           Check the local tools and cluster prerequisites for VM_OS (read-only).' \
	  'make vm-setup            Create the selected guest VM and its baseline deterministic file workload.' \
	  'make vm-backup           Take the one full VM backup and establish the tracker checkpoint.' \
	  'make vm-cbt-backup       Add the next deterministic incremental pass to the active VM.' \
	  'make vm-cbt-verify       Verify all incremental backups, checkpoints, and restored pass prefixes.' \
	  'make vm-cbt-restore-test Reconstruct the full and cumulative incremental restore states.' \
	  'make vm-cbt-demo         Run setup, one full backup, all configured incremental passes, and verification.' \
	  'make e2e                 Run the complete workflow; GUEST_INCREMENTAL_PASSES defaults to 1.' \
	  'make e2e GUEST_INCREMENTAL_PASSES=3 Run one VM lifecycle with three sequential incremental passes.' \
	  'make e2e TYPE=full VM=vm-foo Start a managed VM lifecycle and take its full backup.' \
	  'make e2e TYPE=incremental VM=vm-foo Add the next pass to that lifecycle; final pass verifies the chain.' \
	  'make e2e TYPE=extend VM=vm-foo EXTEND_TO_PASS=4 Add one pass to a completed lifecycle; value is target total.' \
	  'make e2e TYPE=verify VM=vm-foo Re-run chain and restore verification for that lifecycle.' \
	  'make clean-all           Delete all virt-cbt-lab managed resources from the namespace; retain reports.' \
	  'make monitor VM=vm-foo   Read full and per-pass incremental backup timestamps/durations.' \
	  'make e2e VM_OS=windows   Run the Windows Server 2022 CBT E2E profile.' \
	  'make e2e VM_OS=rhel9     Run the RHEL 9 CBT E2E profile.' \
	  'make windows-e2e         Alias for make e2e VM_OS=windows.' \
	  'make windows-vm-setup    Clone a Windows VM, verify startup workloads, and initialize the baseline file workload.' \
	  'make test                Run deterministic offline multi-pass workload/state tests.' \
	  'make sync                Copy working files to REMOTE_HOST:REMOTE_DIR using sync.sh.' \
	  'make resync              Alias for make sync; copy working files to REMOTE_HOST:REMOTE_DIR.' \
	  'sync.sh --pull-reports   Pull REMOTE_HOST:REMOTE_DIR/report/ back into ./report/.' \
	  'Configuration: copy .env.example to .env, then edit the placeholders.' \
	  'Prerequisites: OpenShift Virtualization, CBT APIs, and profile-specific storage classes (Windows requires ODF).'

test:
	@bash tests/test-incremental-passes.sh
	@bash tests/test-vm-cbt-extend.sh
	@bash tests/test-monitor-planned-backups.sh

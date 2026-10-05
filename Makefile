SHELL := /bin/bash

-include .env

export KUBECONFIG_PATH GUEST_KEY REMOTE_HOST REMOTE_DIR RESTORE_HELPER_IMAGE GUEST_BASE_FILE_COUNT GUEST_INCREMENTAL_FILE_COUNT GUEST_FILE_SIZE_MIN_MIB GUEST_FILE_SIZE_MAX_MIB MANIFEST_VARIANT NAMESPACE WINDOWS_ISO_PATH WINDOWS_ADMIN_PASSWORD_FILE VM_OS

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

.PHONY: preflight vm-setup vm-backup vm-cbt-backup vm-cbt-verify vm-cbt-restore-test vm-cbt-demo e2e clean-all monitor windows-golden-image windows-vm-setup windows-e2e sync resync help

preflight:
	@printf '[make] [1/1] Preflight: check local tools and cluster access for VM_OS=%s (read-only).\n' "$(VM_OS)"
	@./preflight

sync:
	@./sync.sh

resync: sync

vm-setup:
	@printf '[make] [1/1] VM setup (%s): create the CBT-enabled VM and initialize the baseline file workload.\n' "$(VM_OS)"
	@./$(VM_SETUP_SCRIPT)

vm-backup:
	@printf '[make] [1/1] Full backup: create the backup PVC, tracker, and full backup.\n'
	@./scripts/vm-backup.sh

vm-cbt-backup:
	@printf '[make] [1/1] Incremental backup: mutate guest data and create the CBT incremental backup.\n'
	@./scripts/vm-cbt-backup.sh

vm-cbt-verify:
	@printf '[make] [1/1] Verification: validate VM CBT state, backup types, completion, and checkpoints.\n'
	@./scripts/vm-cbt-verify.sh

vm-cbt-restore-test:
	@printf '[make] [1/1] Restore test: rebuild the guest disk from the full and incremental backups and verify its data.\n'
	@./scripts/vm-cbt-restore-test.sh

vm-cbt-demo:
	@printf '[make] [1/4] Demo setup: create and initialize the VM.\n'
	@$(MAKE) --no-print-directory vm-setup
	@printf '[make] [2/4] Demo full backup: establish the CBT checkpoint.\n'
	@$(MAKE) --no-print-directory vm-backup
	@printf '[make] [3/4] Demo incremental backup: change guest data and capture the delta.\n'
	@$(MAKE) --no-print-directory vm-cbt-backup
	@printf '[make] [4/4] Demo verification: confirm the end-to-end CBT result.\n'
	@$(MAKE) --no-print-directory vm-cbt-verify

e2e: preflight
	@printf '[make] [1/1] End-to-end demo (%s): preflight passed; running setup, full backup, incremental backup, and verification.\n' "$(VM_OS)"
	@RUN_ID=$(NAME) $(MAKE) --no-print-directory vm-cbt-demo VM_OS=$(VM_OS)

clean-all:
	@printf '[make] [1/1] Cleanup: delete demo resources, reclaim their PVs, and remove only the workflow-managed key.\n'
	@./scripts/clean-all.sh

monitor:
	@printf '[make] [1/1] Monitor: watch full/incremental backup start and completion times for VM=%s.\n' "$(VM)"
	@./scripts/monitor.sh "$(VM)"

windows-golden-image:
	@printf '[make] [1/1] Windows golden image: install Windows and workloads, sysprep, and cache the DataSource (requires WINDOWS_ADMIN_PASSWORD_FILE; WINDOWS_ISO_PATH only if windows-iso is not Succeeded).\n'
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
	  'make vm-backup           Take the full VM backup.' \
	  'make vm-cbt-backup       Add deterministic workload files and take an incremental backup.' \
	  'make vm-cbt-verify       Verify CBT and full/incremental backup status, then run the restore test.' \
	  'make vm-cbt-restore-test Reconstruct the guest disk from the backups and verify its data (runs within vm-cbt-verify).' \
	  'make vm-cbt-demo         Run the complete workflow.' \
	  'make e2e NAME=foo        Use a fixed, deterministic run name instead of a random one.' \
	  'make clean-all           Delete all virt-cbt-lab managed resources (every run) from the namespace, and its generated guest key.' \
	  'make monitor VM=vm-foo   Watch the full/incremental backups for a run (read-only); run alongside make e2e NAME=foo.' \
	  'make e2e VM_OS=windows   Run the Windows Server 2022 CBT E2E profile.' \
	  'make e2e VM_OS=rhel9    Run the RHEL 9 CBT E2E profile.' \
	  'make windows-e2e        Alias for make e2e VM_OS=windows.' \
	  'make windows-vm-setup   Clone a Windows VM, verify startup workloads, and initialize the baseline file workload.' \
	  'make sync               Copy working files to REMOTE_HOST:REMOTE_DIR using sync.sh.' \
	  'make resync             Alias for make sync; copy working files to REMOTE_HOST:REMOTE_DIR.' \
	  'sync.sh --pull-reports  Pull REMOTE_HOST:REMOTE_DIR/report/ back into ./report/.' \
	  'Configuration: copy .env.example to .env, then edit the placeholders.' \
	  'Prerequisites: OpenShift Virtualization, CBT APIs, and profile-specific storage classes (Windows requires ODF).'

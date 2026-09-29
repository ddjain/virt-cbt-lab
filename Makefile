SHELL := /bin/bash

-include .env

export KUBECONFIG_PATH GUEST_KEY REMOTE_HOST REMOTE_DIR RESTORE_HELPER_IMAGE GUEST_DATA_SIZE_MB GUEST_INCREMENTAL_DATA_SIZE_MB

.PHONY: preflight vm-setup vm-backup vm-cbt-backup vm-cbt-verify vm-cbt-restore-test vm-cbt-demo e2e clean-all help

preflight:
	@printf '[make] [1/1] Preflight: check local tools, cluster access, and guest SSH prerequisites (read-only).\n'
	@./preflight

vm-setup:
	@printf '[make] [1/1] VM setup: create the CBT-enabled Fedora VM and initialize guest data.\n'
	@./scripts/vm-setup.sh

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
	@printf '[make] [1/1] End-to-end demo: preflight passed; running setup, full backup, incremental backup, and verification.\n'
	@$(MAKE) --no-print-directory vm-cbt-demo

clean-all:
	@printf '[make] [1/1] Cleanup: delete demo resources, reclaim their PVs, and remove only the workflow-managed key.\n'
	@./scripts/clean-all.sh

help:
	@printf '%s\n' \
	  'make preflight           Check local, cluster, and guest SSH prerequisites without changing cluster state.' \
	  'make vm-setup            Create the VM, write hello.txt, and print its hash.' \
	  'make vm-backup           Take the full VM backup.' \
	  'make vm-cbt-backup       Append to hello.txt, print its hash, and take an incremental backup.' \
	  'make vm-cbt-verify       Verify CBT and full/incremental backup status, then run the restore test.' \
	  'make vm-cbt-restore-test Reconstruct the guest disk from the backups and verify its data (runs within vm-cbt-verify).' \
	  'make vm-cbt-demo         Run the complete workflow.' \
	  'make clean-all           Delete this demo namespace and its generated guest key.' \
	  'sync.sh                  Copy the repository to REMOTE_HOST:REMOTE_DIR.' \
	  'Configuration: copy .env.example to .env, then edit the placeholders.' \
	  'Prerequisites: OpenShift Virtualization, cbt-demo-hpp, and the Fedora DataSource.'

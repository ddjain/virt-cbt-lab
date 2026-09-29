SHELL := /bin/bash

-include .env

export KUBECONFIG_PATH GUEST_KEY REMOTE_HOST REMOTE_DIR

.PHONY: preflight vm-setup vm-backup vm-cbt-backup vm-cbt-verify vm-cbt-restore vm-cbt-demo e2e clean-all help

preflight:
	@printf '[make] [1/1] Preflight: check local tools, cluster access, and guest SSH prerequisites (read-only).\n'
	@./preflight

vm-setup:
	@printf '[make] [1/1] VM setup: create the CBT-enabled Fedora VM and initialize /home/cbt-demo/hello.txt.\n'
	@./scripts/vm-setup.sh

vm-backup:
	@printf '[make] [1/1] Full backup: create the backup PVC, tracker, and full backup.\n'
	@./scripts/vm-backup.sh

vm-cbt-backup:
	@printf '[make] [1/1] Incremental backup: append to /home/cbt-demo/hello.txt and create the CBT incremental backup.\n'
	@./scripts/vm-cbt-backup.sh

vm-cbt-verify:
	@printf '[make] [1/1] Verification: validate VM CBT state, backup types, completion, and checkpoints.\n'
	@./scripts/vm-cbt-verify.sh

vm-cbt-restore:
	@printf '[make] [1/1] Restore: reconstruct and boot the backup chain, then verify /home/cbt-demo/hello.txt.\n'
	@./scripts/vm-cbt-restore.sh

vm-cbt-demo:
	@printf '[make] [1/5] Demo setup: create and initialize the VM.\n'
	@$(MAKE) --no-print-directory vm-setup
	@printf '[make] [2/5] Demo full backup: establish the CBT checkpoint.\n'
	@$(MAKE) --no-print-directory vm-backup
	@printf '[make] [3/5] Demo incremental backup: change guest data and capture the delta.\n'
	@$(MAKE) --no-print-directory vm-cbt-backup
	@printf '[make] [4/5] Demo verification: confirm the end-to-end CBT result.\n'
	@$(MAKE) --no-print-directory vm-cbt-verify
	@printf '[make] [5/5] Demo restore: reconstruct and boot the backup chain, then verify the restored guest.\n'
	@$(MAKE) --no-print-directory vm-cbt-restore
e2e: preflight
	@printf '[make] [1/1] End-to-end demo: preflight passed; running setup, full backup, incremental backup, API verification, and restore verification.\n'
	@$(MAKE) --no-print-directory vm-cbt-demo

clean-all:
	@printf '[make] [1/1] Cleanup: delete demo resources, reclaim their PVs, and remove only the workflow-managed key.\n'
	@./scripts/clean-all.sh

help:
	@printf '%s\n' \
	  'make preflight     Check local, cluster, and guest SSH prerequisites without changing cluster state.' \
	  'make vm-setup       Create the VM, write /home/cbt-demo/hello.txt, and print its hash.' \
	  'make vm-backup      Take the full VM backup.' \
	  'make vm-cbt-backup  Append to /home/cbt-demo/hello.txt, print its hash, and take an incremental backup.' \
	  'make vm-cbt-verify  Verify CBT and full/incremental backup status.' \
	  'make vm-cbt-restore Reconstruct and boot the backup chain, then verify the restored guest file.' \
	  'make vm-cbt-demo    Run setup, full backup, incremental backup, API verification, and restore verification.' \
	  'make e2e            Run preflight and the complete workflow including restore verification.' \
	  'make clean-all      Delete this demo namespace and its generated guest key.' \
	  'Configuration: copy .env.example to .env, then edit the placeholders.' \
	  'Prerequisites: OpenShift Virtualization, cbt-demo-hpp, and the Fedora DataSource.'

SHELL := /bin/bash

-include .env

export KUBECONFIG_PATH GUEST_KEY REMOTE_HOST REMOTE_DIR

.PHONY: preflight vm-setup vm-backup vm-cbt-backup vm-cbt-verify vm-cbt-demo e2e clean-all help

preflight:
	@./preflight

vm-setup:
	@./scripts/vm-setup.sh


vm-backup:
	@./scripts/vm-backup.sh

vm-cbt-backup:
	@./scripts/vm-cbt-backup.sh

vm-cbt-verify:
	@./scripts/vm-cbt-verify.sh

vm-cbt-demo:
	$(MAKE) vm-setup
	$(MAKE) vm-backup
	$(MAKE) vm-cbt-backup
	$(MAKE) vm-cbt-verify

e2e: preflight vm-cbt-demo

clean-all:
	@./scripts/clean-all.sh

help:
	@printf '%s\n' \
	  'make preflight     Check local, cluster, and guest SSH prerequisites without changing cluster state.' \
	  'make vm-setup       Create the VM, write hello.txt, and print its hash.' \
	  'make vm-backup      Take the full VM backup.' \
	  'make vm-cbt-backup  Append to hello.txt, print its hash, and take an incremental backup.' \
	  'make vm-cbt-verify  Verify CBT and full/incremental backup status.' \
	  'make vm-cbt-demo    Run the complete workflow.' \
	  'make clean-all      Delete this demo namespace and its generated guest key.' \
	  'sync.sh             Copy the repository to REMOTE_HOST:REMOTE_DIR.' \
	  'Configuration: copy .env.example to .env, then edit the placeholders.' \
	  'Prerequisites: OpenShift Virtualization, cbt-demo-hpp, and the Fedora DataSource.'

# KubeVirt CBT architecture knowledgebase

This file is the stable entry point for the CBT knowledgebase. The detailed material is split into small pages so a new engineer can learn the system progressively instead of reading one large reference document.

## Recommended reading order

1. [CBT overview and diagrams](cbt/01-overview.md)
2. [Components and dependencies](cbt/02-components.md)
3. [Network topology](cbt/03-network.md)
4. [Storage topology](cbt/04-storage.md)
5. [Full backup](cbt/05-full-backup.md)
6. [Incremental backup](cbt/06-incremental-backup.md)
7. [Restore verification](cbt/07-restore-verification.md)
8. [Operations and troubleshooting](cbt/08-operations.md)
9. [Limitations and production cautions](cbt/09-limitations.md)
10. [Chaos-test design](cbt/10-chaos-test-design.md)
11. [Cloud05 live audit](cbt/11-cloud05-audit.md)
12. [KubeVirt source reference](cbt/12-kubevirt-source-reference.md)

## One-page mental model

```text
VM root disk + persistent CBT state
              |
              +--> Full VirtualMachineBackup --> standalone qcow2
              |
       guest blocks change
              |
              +--> Incremental VirtualMachineBackup
                    --> qcow2 overlay based on tracker checkpoint

restore = full qcow2 + incremental overlay chain
```

## Diagrams

The overview page contains:

- an ASCII component/data-flow diagram;
- an ASCII repository workflow diagram;
- a control-plane versus data-plane explanation.

The full, incremental, and restore pages contain Mermaid sequence diagrams showing who creates, attaches, copies, updates, and verifies each artifact.

## Related procedural references

- [`docs/vm-cbt-workflow.md`](vm-cbt-workflow.md): exact Make/script behavior.
- [`docs/restore-verification.md`](restore-verification.md): manual restore cross-check.
- [`docs/cbt/README.md`](cbt/README.md): same documentation map with beginner-oriented descriptions.
- [`../README.md`](../README.md): setup and configuration.
- [`../cbt-chaos/chaos-plan.md`](../cbt-chaos/chaos-plan.md): resilience test hypotheses.

## Evidence status

The default cloud05 E2E passed full, incremental, checkpoint, and restore-data verification. A large-copy experiment measured 29 seconds for full and 15 seconds for incremental backup copies, but its final restore report was invalidated by concurrent workflows sharing one checkout's local state. The concurrency limitation is documented in [09. Limitations](cbt/09-limitations.md).

The later cloud05 audit also observed the installed API/runtime boundary directly: OpenShift 4.22.15, HCO 4.22.9/KubeVirt operator `v1.8.4`, `IncrementalBackup`, selector `cbt-demo=enabled`, a persistent-state qcow2 CBT layer, a real libvirt full-to-incremental checkpoint tree, and HPP storage pinned to one node. It found that the repository still needs independent `qemu-img info/map` assertions when a test claims physical delta preservation; semantic restore hashes alone are not sufficient for that claim.

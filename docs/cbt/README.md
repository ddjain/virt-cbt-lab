# CBT documentation

This is the beginner-friendly map of the KubeVirt Changed Block Tracking (CBT) demo. Read the pages in order if the feature is new to you; jump directly to a topic when troubleshooting.

## Start here

| Page | Answers |
|---|---|
| [01. Overview](01-overview.md) | What CBT is, what this repository does, and the end-to-end shape |
| [02. Components](02-components.md) | Which OpenShift, KubeVirt, CDI, storage, and guest components participate |
| [03. Network](03-network.md) | How operator, guest SSH, guest-agent, and backup traffic differ |
| [04. Storage](04-storage.md) | Where the root disk, CBT state, full image, and incremental overlay live |
| [05. Full backup](05-full-backup.md) | The first checkpoint and full-image lifecycle |
| [06. Incremental backup](06-incremental-backup.md) | Tracker-based delta capture and checkpoint chaining |
| [07. Restore verification](07-restore-verification.md) | How the repository proves the backup contains real guest data |
| [08. Operations](08-operations.md) | Commands, reports, monitoring, events, and troubleshooting |
| [09. Limitations](09-limitations.md) | Alpha status, storage constraints, concurrency, and untested failure paths |

## Related procedural documents

- [`docs/vm-cbt-workflow.md`](../vm-cbt-workflow.md): exact repository workflow and resource names.
- [`../../README.md`](../../README.md): setup, configuration, and Make targets.
- [`../../cbt-chaos/chaos-plan.md`](../../cbt-chaos/chaos-plan.md): failure-injection hypotheses and test matrix.

## Evidence labels

- **SOURCE**: repository manifest/script or installed CRD schema.
- **OBSERVED**: live cloud05 API, event, pod, PVC/PV, or log result.
- **INFERRED**: engineering conclusion from source and observations.
- **UNKNOWN**: not exercised by the normal workflow.

The default cloud05 E2E completed successfully, including full-only and full-plus-incremental restore verification. The large-copy timing experiment reached both backup completion states, but its final restore report was invalidated by concurrent workflow state overwriting; see [09. Limitations](09-limitations.md).

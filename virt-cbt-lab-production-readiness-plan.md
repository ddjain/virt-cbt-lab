# virt-cbt-lab Production-Grade CBT Test Utility Improvement Plan

## 1. Purpose

`virt-cbt-lab` is a **KubeVirt/OpenShift Virtualization CBT test and
validation utility**.

Its job is **not** to inject chaos.

External systems such as Krkn may inject chaos while this utility is
running, but this repository must remain completely independent of chaos
orchestration.

The utility's responsibility is to reliably execute and verify the CBT
backup pipeline:

``` text
Create/provision test VM
        ↓
Put known deterministic baseline data in VM
        ↓
Create CBT tracker/resources
        ↓
Full backup
        ↓
Modify data in VM
        ↓
Incremental CBT backup(s)
        ↓
Restore full + incremental chain
        ↓
Validate restored data and CBT state
        ↓
Produce concise result + machine-readable report
        ↓
Keep resources
```

The primary user experience is:

``` bash
make e2e
```

with sensible defaults and minimal configuration.

------------------------------------------------------------------------

# 2. Product Goals

The implementation must optimize for:

1.  **Reliable CBT validation**
2.  **Simple developer/QE usage**
3.  **Deterministic and reproducible tests**
4.  **Clean output**
5.  **Stable machine-readable results**
6.  **AI-agent-friendly results**
7.  **CI-friendly execution**
8.  **Good debugging evidence when a test fails**
9.  **Independent staged execution**
10. **Ability to run multiple incremental CBT passes**

The project should remain a **test harness**, not become a generic
production backup product.

------------------------------------------------------------------------

# 3. Explicit Non-Goals

Do **not** add the following to the core project:

-   Chaos injection
-   Krkn orchestration
-   Chaos scheduling
-   Chaos trigger management
-   Generic production backup scheduling
-   Backup retention policies
-   Generic object-storage backup destinations
-   Web UI
-   Central backup inventory
-   Multi-cluster backup management

External chaos may interrupt any stage of the test, but the test utility
only needs to:

-   execute the CBT workflow,
-   wait correctly,
-   detect failures,
-   verify correctness,
-   preserve evidence,
-   report the result.

------------------------------------------------------------------------

# 4. Required Default Behavior

The default:

``` bash
make e2e
```

must use:

``` text
VM OS:             RHEL9
Storage variant:   large-odf
Incremental runs:  1
```

The user should not need to configure these for the standard test.

The defaults may be overridden.

Examples:

``` bash
make e2e VM_OS=debian
```

``` bash
make e2e GUEST_INCREMENTAL_PASSES=3
```

``` bash
make e2e MANIFEST_VARIANT=odf
```

------------------------------------------------------------------------

# 5. Supported Staged Workflow

The project must support both an all-in-one workflow and staged
execution.

## All-in-one

``` bash
make e2e
```

Expected flow:

``` text
preflight
  ↓
VM setup
  ↓
baseline workload
  ↓
CBT tracker
  ↓
full backup
  ↓
data mutation
  ↓
incremental CBT backup
  ↓
restore verification
  ↓
summary
```

## Full backup against an existing VM

``` bash
make vm-backup VM=vm-existing-run
```

This must operate on the specified VM rather than depending on a
globally active `state/run-id`.

## Incremental CBT against an existing VM

The user-facing target is the semantic target:

``` bash
make e2e-incremental VM=vm-existing-run
```

The implementation may continue using an internal script named
`vm-cbt-backup.sh`.

------------------------------------------------------------------------

# 6. Historical Current-State Finding

At the time this plan was created, the repository documented
`GUEST_INCREMENTAL_PASSES`, staged `TYPE` modes, and lifecycle extension
before the Makefile/scripts fully implemented them. That gap motivated the
roadmap below. Documentation alone is not acceptance evidence; current
implementation and cluster-validation status are tracked in Section 56.

------------------------------------------------------------------------

# 7. Architecture Direction

Do **not** rewrite the project into a Go application as the first step.

The current Bash + Make architecture is usable for this project.

The immediate goal is to make the existing implementation:

-   deterministic,
-   state-safe,
-   easier to configure,
-   easier to operate,
-   easier to verify,
-   easier for CI/AI agents to consume.

Gradually refactor only the parts that are causing real complexity.

------------------------------------------------------------------------

# 8. Run-Centric State Model

## Problem

Before Action item 1, the implementation used shared checkout state:

``` text
state/run-id
state/report-id
```

Later stages depended on those global files, coupling unrelated runs to the
checkout. Action item 1 replaces them with `runs/<run-id>/run.json`; `state/`
is now limited to the checkout operation lock.

## Target

Every execution must have a run ID.

Recommended structure:

``` text
runs/
  <run-id>/
    run.json
    workload-manifest.json
    report.json
    fragments/
    logs/
    evidence/
    restore/
```

Example:

``` text
runs/
  calm-forest-a81c/
    run.json
    workload-manifest.json
    report.json
    fragments/
    logs/
    evidence/
    restore/
```

## `run.json`

The run metadata should contain at least:

``` json
{
  "schemaVersion": 1,
  "runId": "calm-forest-a81c",
  "namespace": "vm-cbt-demo",
  "vm": "vm-cbt-calm-forest-a81c",
  "vmUid": "...",
  "vmOs": "rhel9",
  "manifestVariant": "large-odf",
  "baseFileCount": 8,
  "incrementalFileCount": 4,
  "incrementalPasses": 1,
  "createdAt": "..."
}
```

The exact fields can evolve, but the principle is mandatory:

> Later stages should read immutable run metadata rather than
> reconstructing configuration from the current shell environment.

------------------------------------------------------------------------

# 9. VM Identity

A VM name alone must not be the only identity of a test run.

Use:

``` text
VM UID + Run ID
```

as the logical identity.

Kubernetes resources created by the utility should continue to use
run-scoped names and ownership labels.

Recommended labels:

``` text
app.kubernetes.io/managed-by=virt-cbt-lab
virt-cbt-lab/run-id=<run-id>
virt-cbt-lab/vm-uid=<vm-uid>
virt-cbt-lab/resource-role=<role>
virt-cbt-lab/pass=<pass-number>
```

Do not create an excessive label taxonomy.

------------------------------------------------------------------------

# 10. Resource Naming

Existing run-scoped naming is good and should be retained.

For multiple incremental passes, resources must become pass-aware.

Example:

``` text
full backup
incremental-p01
incremental-p02
incremental-p03
```

Corresponding PVCs and backup resources must also be uniquely
identified.

Do not reuse a single incremental resource name for all passes.

------------------------------------------------------------------------

# 11. Incremental Pass Model

Default:

``` bash
make e2e
```

means:

``` text
Full
  ↓
Incremental P01
```

Override:

``` bash
make e2e GUEST_INCREMENTAL_PASSES=3
```

means:

``` text
Full
  ↓
Incremental P01
  ↓
Incremental P02
  ↓
Incremental P03
```

Each pass must have:

-   its own workload mutation,
-   its own incremental backup resource,
-   its own checkpoint,
-   its own verification state,
-   its own report entry.

------------------------------------------------------------------------

# 12. Workload Manifest Model

The current deterministic workload generation is a strong foundation and
should be retained.

The workload must remain reproducible.

Each generated file should have deterministic:

-   filename,
-   size,
-   content,
-   SHA-256 hash.

The current filename/content/hash approach should not be replaced by
random data.

## Required evolution

The workload manifest must support multiple incremental passes.

Instead of a single mutable:

``` json
{
  "baseline": {...},
  "incremental": {...}
}
```

use a pass-aware model:

``` json
{
  "schema_version": 2,
  "baseline": {
    "files": [...]
  },
  "incrementals": [
    {
      "pass": 1,
      "files": [...],
      "files_modified": [...],
      "manifest_sha256": "..."
    },
    {
      "pass": 2,
      "files": [...],
      "files_modified": [...],
      "manifest_sha256": "..."
    }
  ]
}
```

The manifest appends exactly the next pass. `files` contains that pass's
additions, `files_modified` contains the expected baseline-file hashes, and
`manifest_sha256` represents the cumulative inventory after that pass.

------------------------------------------------------------------------

# 13. Workload Mutation

The workload should evolve beyond add-only mutation.

Target behavior:

``` text
Baseline:
  base-001
  base-002
  base-003

Pass 1:
  add incremental-001
  add incremental-002
  modify base-003

Pass 2:
  add incremental-003
  modify base-001
```

This gives CBT validation meaningful coverage for:

-   new blocks,
-   changed blocks,
-   unchanged blocks.

Do not make deletion support mandatory in the first refactor.

Deletion can be a future test scenario.

------------------------------------------------------------------------

# 14. Backup Chain

The utility must explicitly model:

``` text
Full backup
  checkpoint A
       ↓
Incremental P01
  parent A
  checkpoint B
       ↓
Incremental P02
  parent B
  checkpoint C
```

The utility must verify that the incremental chain is coherent.

At minimum:

-   full backup succeeds,
-   incremental backup succeeds,
-   checkpoint exists,
-   incremental checkpoint differs from the previous checkpoint,
-   tracker points to the expected current checkpoint,
-   incremental parent/base relationship is correct where observable.

Do not rely solely on:

``` text
Done=True
```

or:

``` text
type=Incremental
```

------------------------------------------------------------------------

# 15. Full Backup

The full backup stage must:

1.  Validate VM exists.
2.  Validate CBT is enabled/available.
3.  Create required CBT tracker resources.
4.  Create required backup destination resources.
5.  Create the full backup.
6.  Wait for terminal state.
7.  Correctly interpret success/failure conditions.
8.  Record checkpoint information.
9.  Persist structured result data.
10. Keep detailed Kubernetes state as evidence.

The terminal result must not be determined from `Done=True` alone.

------------------------------------------------------------------------

# 16. Incremental Backup

For each pass:

1.  Discover the correct run/VM.
2.  Load run metadata.
3.  Validate tracker state.
4.  Mutate deterministic workload.
5.  Record mutation manifest.
6.  Create incremental backup.
7.  Wait for terminal state.
8.  Validate completion reason.
9.  Validate checkpoint state.
10. Record pass result.
11. Continue to next pass if configured.

If state is ambiguous, fail safely rather than guessing.

------------------------------------------------------------------------

# 17. Restore Verification

Restore verification is mandatory.

Do not make restore verification optional for the standard E2E workflow.

The current approach of reconstructing:

``` text
Full
```

and:

``` text
Full + Incremental
```

and mounting the reconstructed disk to validate data is the correct
direction.

For N incremental passes, verification must become cumulative:

``` text
Full
        ↓
Full + P01
        ↓
Full + P01 + P02
        ↓
Full + P01 + P02 + P03
```

Each cumulative state should be validated.

For every state, compare expected workload data against restored data.

------------------------------------------------------------------------

# 18. Verification Layers

The test result should conceptually have these verification layers:

``` text
VM / CBT
    ↓
Full backup
    ↓
Incremental chain
    ↓
Checkpoint/tracker
    ↓
Restore
    ↓
Data correctness
```

Example:

``` json
{
  "verification": {
    "cbt": "PASS",
    "fullBackup": "PASS",
    "incrementalChain": "PASS",
    "checkpoint": "PASS",
    "restore": "PASS"
  }
}
```

------------------------------------------------------------------------

# 19. Future Artifact-Level Verification

The current restore validation proves semantic guest data correctness.

It does not necessarily prove that the physical incremental artifact is
actually a CBT delta.

This can be a future verification layer.

Potential future evidence:

``` text
qemu-img info
qemu-img map
backing relationship
allocated clusters
artifact sizes
```

Do not make this the first refactor.

------------------------------------------------------------------------

# 20. Report Architecture

The report must describe the **test result**, not dump Kubernetes API
objects.

Do not merge arbitrary JSON fragments into the main report.

The main report should have a stable schema.

Example:

``` json
{
  "schemaVersion": 1,
  "result": "PASS",

  "run": {
    "id": "calm-forest-a81c",
    "startedAt": "...",
    "completedAt": "...",
    "durationSeconds": 132
  },

  "vm": {
    "name": "cbt-rhel9-01",
    "namespace": "vm-cbt-demo",
    "os": "rhel9"
  },

  "workload": {
    "baseline": {
      "files": 8,
      "payloadBytes": 83886080,
      "manifestSha256": "..."
    },
    "passes": [
      {
        "pass": 1,
        "filesAdded": 4,
        "filesModified": 1,
        "payloadBytes": 41943040
      }
    ]
  },

  "backups": {
    "full": {
      "name": "...",
      "type": "Full",
      "status": "Succeeded",
      "checkpoint": "...",
      "durationSeconds": 31
    },
    "incremental": [
      {
        "pass": 1,
        "name": "...",
        "type": "Incremental",
        "status": "Succeeded",
        "checkpoint": "...",
        "durationSeconds": 17
      }
    ]
  },

  "verification": {
    "cbt": "PASS",
    "restore": "PASS"
  },

  "result": "PASS"
}
```

The exact schema can evolve, but it must remain stable and intentionally
designed.

------------------------------------------------------------------------

# 21. Evidence vs Result

Use two different concepts.

## `report.json`

Small, stable, machine-readable.

## `evidence/`

Large debugging information.

Suggested structure:

``` text
runs/<run-id>/
  report.json

  evidence/
    resources/
      vm.yaml
      tracker.yaml
      full-backup.yaml
      incremental-p01.yaml

    events/
      full-backup-events.txt
      incremental-p01-events.txt

    logs/
      virt-controller.log
      virt-launcher.log

    restore/
      full/
      incremental-p01/

  logs/
    orchestrator.log
```

Do not put large Kubernetes objects into `report.json`.

------------------------------------------------------------------------

# 22. Logging

Default output must be concise.

Target:

``` text
KubeVirt CBT E2E
────────────────────────────────────────

Environment
  VM OS          RHEL 9
  Storage        ODF large
  Namespace      vm-cbt-demo

Run
  ID             calm-forest-a81c
  VM             vm-cbt-calm-forest-a81c

[1/6] VM setup                  PASS   54s
[2/6] Baseline workload        PASS    8s
[3/6] Full backup              PASS   31s
[4/6] Data mutation            PASS    5s
[5/6] Incremental CBT backup   PASS   17s
[6/6] Restore verification     PASS   42s

────────────────────────────────────────
Result: PASS

Report:
  ./runs/calm-forest-a81c/report.json
```

Do not print:

-   raw `oc` commands,
-   raw JSON,
-   individual file records,
-   repeated Kubernetes conditions,
-   raw event streams,
-   unnecessary polling output.

------------------------------------------------------------------------

# 23. Debug Logging

Detailed information must still be available.

Use:

``` bash
DEBUG=true make e2e
```

or the project's existing debug mechanism.

Debug mode may show:

-   resource conditions,
-   tracker state,
-   backup status,
-   API operations,
-   polling/watch state,
-   detailed workload information.

Raw command tracing should be reserved for an even more verbose
troubleshooting mode if needed.

------------------------------------------------------------------------

# 24. Remove Guest Inventory Noise From Stdout

The current workflow emits file records such as:

``` text
FILE_RECORD=...
```

These should not appear in normal output.

They belong in:

``` text
workload-manifest.json
```

or evidence.

The terminal should say:

``` text
Data mutation             PASS
```

not print every file.

------------------------------------------------------------------------

# 25. Monitor Behavior

Monitoring should not be required to produce the primary result.

The main pipeline must collect its own meaningful timing/status
information.

A separate monitor target can remain for debugging:

``` bash
make monitor VM=...
```

But a monitor failure should not obscure whether the CBT test itself
succeeded.

------------------------------------------------------------------------

# 26. Heartbeats

Do not print periodic heartbeat messages in normal mode.

Instead:

``` text
Full backup ... running
```

should remain quiet until completion.

Debug mode may expose elapsed-time heartbeats.

------------------------------------------------------------------------

# 27. Event Handling

Events are evidence, not automatically the verdict.

A transient event such as:

``` text
Backup has failed
```

must not automatically cause the test to fail if the authoritative
resource status and restore validation prove successful.

Use:

``` text
Events
  = diagnostic evidence

CR conditions/status
  = lifecycle result

Restore/data verification
  = correctness proof
```

------------------------------------------------------------------------

# 28. Status Vocabulary

Individual checks should use:

``` text
PASS
FAIL
SKIP
ERROR
```

Overall test result should support:

``` text
PASS
FAIL
INCONCLUSIVE
```

`INCONCLUSIVE` is important when the test cannot establish whether CBT
itself is correct.

Example:

``` text
Chaos occurred externally.
Backup timed out.
Root cause cannot be established.

Result: INCONCLUSIVE
```

Do not incorrectly label every interrupted run as a CBT failure.

------------------------------------------------------------------------

# 29. Makefile UX

Keep Make as the primary interface.

Recommended public targets:

``` bash
make e2e
make e2e-incremental VM=<vm>
make vm-setup
make vm-backup VM=<vm>
make vm-cbt-verify VM=<vm>
make preflight
make clean-all
```

Implementation scripts can retain names such as:

``` text
scripts/vm-cbt-backup.sh
```

but the public Make target should be semantic.

------------------------------------------------------------------------

# 30. Default Configuration

Default:

``` text
VM_OS=rhel9
MANIFEST_VARIANT=large-odf
GUEST_INCREMENTAL_PASSES=1
```

Document alternative manifest variants in the README.

The standard user should not need to understand the manifest naming
scheme.

------------------------------------------------------------------------

# 31. Configuration Philosophy

Do not solve configuration complexity by adding more flags.

The desired UX is:

``` bash
make e2e
```

For common variations:

``` bash
make e2e VM_OS=debian
```

``` bash
make e2e GUEST_INCREMENTAL_PASSES=3
```

``` bash
make e2e MANIFEST_VARIANT=odf
```

Only expose a variable when it represents a meaningful test dimension.

------------------------------------------------------------------------

# 32. Existing VM Semantics

Support:

``` bash
make vm-backup VM=my-existing-vm
```

and:

``` bash
make e2e-incremental VM=my-existing-vm
```

These staged operations must discover the appropriate run/CBT state
safely.

If multiple ambiguous runs are associated with the VM, do not guess.

Return a clear error requesting explicit run selection.

------------------------------------------------------------------------

# 33. Cleanup

Keep the current philosophy:

``` text
Resources remain after the run.
```

Users explicitly clean them with:

``` bash
make clean-all
```

This is important for debugging external chaos failures.

Do not automatically destroy the VM or backup resources after a failed
test.

Future improvement:

``` bash
make clean RUN=<run-id>
```

but this is not P0.

------------------------------------------------------------------------

# 34. Storage

Default:

``` text
large-odf
```

Document other manifest variants.

Do not make storage auto-detection a requirement.

Keep the current explicit manifest approach because it is predictable
for a test harness.

The goal is:

``` text
simple default
+
documented overrides
```

not a sophisticated storage abstraction.

------------------------------------------------------------------------

# 35. Operating System Profiles

Default:

``` text
RHEL9
```

Override:

``` bash
make e2e VM_OS=debian
```

Windows remains supported but should not dictate the common
architecture.

Keep OS-specific setup isolated from the common CBT lifecycle.

------------------------------------------------------------------------

# 36. Preflight

Keep the comprehensive preflight capability.

But normal output should be concise:

``` text
Preflight: PASS
```

or:

``` text
Preflight: FAIL

✗ RHEL9 DataSource is not ready
  expected: Bound
  actual: Pending
```

Detailed diagnostics remain available through:

``` bash
make preflight DEBUG=true
```

Avoid requiring namespace creation privileges if the project can operate
in a pre-existing test namespace.

------------------------------------------------------------------------

# 37. RBAC Principle

The project should request only permissions required for the test.

Avoid broad cluster lifecycle permissions unless explicitly required.

The test namespace should normally be pre-existing.

------------------------------------------------------------------------

# 38. AI-Agent / CI Output

The result must be easy to consume programmatically.

Future support:

``` bash
make e2e OUTPUT=json
```

Example:

``` json
{
  "result": "PASS",
  "runId": "calm-forest-a81c",
  "vm": "cbt-rhel9-01",
  "fullBackup": "PASS",
  "incrementalBackup": "PASS",
  "restore": "PASS",
  "report": "./runs/calm-forest-a81c/report.json"
}
```

A future JUnit output mode is also recommended:

``` bash
make e2e OUTPUT=junit
```

This is P2.

------------------------------------------------------------------------

# 39. What Must Not Be Changed

Preserve these strong parts of the current project:

-   deterministic workload generation,
-   deterministic file hashes,
-   CBT tracker creation,
-   checkpoint validation,
-   backup completion reason validation,
-   restore verification,
-   run-scoped Kubernetes resource names,
-   ownership labels,
-   explicit `clean-all`,
-   comprehensive preflight,
-   RHEL9 profile,
-   ODF variants,
-   Windows support,
-   evidence collection.

Do not rewrite working behavior simply for architectural elegance.

------------------------------------------------------------------------

# 40. Recommended Implementation Order

## Phase 1 --- Run/state model

Implement:

-   run ID directory,
-   run metadata,
-   VM UID tracking,
-   removal of global run state as source of truth,
-   staged run discovery,
-   pass-aware resource identity.

### Acceptance criteria

``` text
make e2e
```

creates:

``` text
runs/<run-id>/
```

and the complete test can be understood from that directory.

------------------------------------------------------------------------

## Phase 2 --- Defaults and configuration

Implement:

``` text
RHEL9
large-ODF
1 incremental pass
```

as defaults.

Ensure overrides work.

### Acceptance criteria

``` bash
make e2e
make e2e VM_OS=debian
make e2e MANIFEST_VARIANT=odf
make e2e GUEST_INCREMENTAL_PASSES=3
```

all resolve configuration correctly.

------------------------------------------------------------------------

## Phase 3 --- Multi-pass incremental lifecycle

Implement:

``` text
P01
P02
P03
...
```

with unique resources and manifests.

### Acceptance criteria

``` bash
make e2e GUEST_INCREMENTAL_PASSES=3
```

creates:

``` text
Full
P01
P02
P03
```

and does not overwrite prior pass data.

------------------------------------------------------------------------

## Phase 4 --- Workload mutation

Implement:

-   add files,
-   modify existing files,
-   deterministic expected hashes.

### Acceptance criteria

Restore verification proves:

``` text
new files = correct
modified files = correct
unchanged files = correct
```

------------------------------------------------------------------------

## Phase 5 --- Restore verification

Implement cumulative verification:

``` text
Full
Full + P01
Full + P01 + P02
...
```

### Acceptance criteria

A failure in any cumulative restore must fail the test.

------------------------------------------------------------------------

## Phase 6 --- Report schema

Implement a stable `report.json`.

### Acceptance criteria

The report contains only intended test-level fields.

It must not contain arbitrary Kubernetes status blobs unless explicitly
placed under an evidence/diagnostic field.

------------------------------------------------------------------------

## Phase 7 --- Logging

Implement compact default output.

### Acceptance criteria

Normal `make e2e` output should fit on a screen for a successful run.

Detailed logs remain available on disk/debug mode.

------------------------------------------------------------------------

## Phase 8 --- Makefile/staged commands

Implement:

``` bash
make vm-backup VM=...
make e2e-incremental VM=...
```

### Acceptance criteria

Staged commands work without relying on manually edited state files.

------------------------------------------------------------------------

# 41. Verification Strategy

Every implementation change must be verified at three levels.

## Level 1 --- Static validation

Run:

``` bash
bash -n scripts/*.sh
```

for applicable shell scripts.

Run:

``` bash
make help
```

and confirm documented targets exist.

Validate JSON files:

``` bash
jq empty <file>
```

Validate generated report:

``` bash
jq empty runs/<run-id>/report.json
```

Check that no unintended debug output is produced.

------------------------------------------------------------------------

# 42. Level 2 --- Functional E2E Verification

Run the default test:

``` bash
make e2e
```

Expected:

``` text
VM setup                  PASS
Baseline workload         PASS
Full backup               PASS
Data mutation             PASS
Incremental CBT backup    PASS
Restore verification      PASS

Result: PASS
```

Then inspect:

``` text
runs/<run-id>/
```

and confirm:

``` text
run.json
workload-manifest.json
report.json
evidence/
logs/
```

exist.

------------------------------------------------------------------------

# 43. Verify Default Configuration

Run:

``` bash
make e2e
```

Confirm:

``` text
VM OS = RHEL9
Storage = large-ODF
Incremental passes = 1
```

Do not infer this from documentation.

Verify actual generated VM/manifests/resources.

------------------------------------------------------------------------

# 44. Verify Configuration Overrides

Run:

``` bash
make e2e VM_OS=debian
```

Verify the actual VM uses Debian.

Run:

``` bash
make e2e MANIFEST_VARIANT=odf
```

Verify the actual resources use the ODF manifest.

Run:

``` bash
make e2e GUEST_INCREMENTAL_PASSES=3
```

Verify exactly:

``` text
1 full backup
3 incremental backups
```

are created.

------------------------------------------------------------------------

# 45. Verify Multi-Pass Restore

For:

``` bash
make e2e GUEST_INCREMENTAL_PASSES=3
```

verify:

``` text
Full restore              PASS
Full + P01 restore        PASS
Full + P01 + P02 restore  PASS
Full + P01 + P02 + P03    PASS
```

The final restored filesystem must match the expected cumulative
workload manifest.

------------------------------------------------------------------------

# 46. Verify Report Correctness

Check:

``` bash
jq '.result' runs/<run-id>/report.json
```

Expected:

``` text
"PASS"
```

Check that:

``` bash
jq '.backups' runs/<run-id>/report.json
```

contains only structured backup information.

Ensure raw Kubernetes objects are not unnecessarily embedded in the main
report.

Verify:

``` bash
jq '.schemaVersion' runs/<run-id>/report.json
```

exists.

------------------------------------------------------------------------

# 47. Verify Logging

Run a successful test and inspect stdout.

It must not contain large:

``` text
FILE_RECORD=...
```

streams.

It must not continuously print raw:

``` text
oc ...
```

commands.

It must not print large Kubernetes JSON documents.

It should primarily contain:

``` text
stage
status
duration
summary
report path
```

Then run with:

``` bash
DEBUG=true make e2e
```

and confirm detailed diagnostic information is available.

------------------------------------------------------------------------

# 48. Verify Failure Handling

Intentionally cause a recoverable/terminal failure where practical.

Verify that:

``` text
Result: FAIL
```

is reported rather than:

``` text
Result: PASS
```

Also verify the report records:

-   failing stage,
-   reason,
-   resource name,
-   run ID,
-   evidence location.

Do not delete the resources.

------------------------------------------------------------------------

# 49. Verify External Chaos Compatibility

Do **not** add chaos logic to the utility.

Instead, validate that the pipeline remains independently executable
while external disruption occurs.

For example:

``` text
make e2e
```

runs normally while an external test system restarts a relevant
component.

The utility should:

-   continue waiting,
-   correctly observe final state,
-   perform restore verification when possible,
-   report PASS/FAIL/INCONCLUSIVE based on evidence.

It must not know that Krkn performed the disruption.

------------------------------------------------------------------------

# 50. Verify Cleanup

After a test:

``` bash
make e2e
```

resources must remain.

Verify the VM, tracker, backup resources and evidence still exist.

Then:

``` bash
make clean-all
```

Verify only resources owned by the test harness are removed.

Verify unrelated resources remain untouched.

------------------------------------------------------------------------

# 51. Verify Staged Execution

Test:

``` bash
make vm-setup
```

Then:

``` bash
make vm-backup VM=<vm-name>
```

Then:

``` bash
make e2e-incremental VM=<vm-name>
```

Confirm the incremental stage selects `runs/<run-id>/run.json` from the
specified VM, checks the current Kubernetes VM UID against saved run metadata,
and does not require any checkout-global pointer to be manually created or
modified.

------------------------------------------------------------------------

# 52. Verify AI-Agent Usability

An AI agent should be able to answer these questions from `report.json`
without reading logs:

``` text
Did the test pass?
What VM was tested?
Did full backup pass?
How many incremental backups ran?
Did restore pass?
What run ID was used?
Where is the evidence?
```

If the agent must parse shell logs to answer those questions, the report
schema is not sufficient.

------------------------------------------------------------------------

# 53. Verify CI Usability

A CI job should be able to:

``` bash
make e2e
```

and determine success from:

``` text
process exit code
+
report.json
```

The exit code must be non-zero for a failed test.

A test must not print:

``` text
Result: FAIL
```

and then exit `0`.

------------------------------------------------------------------------

# 54. Final Definition of Done

The improvement is complete only when:

-   `make e2e` works with no configuration.
-   Default VM OS is RHEL9.
-   Default storage is large-ODF.
-   Default incremental count is 1.
-   Incremental count can be overridden.
-   Full backup always precedes incremental backup.
-   CBT tracker resources are created automatically.
-   Existing VM staged execution works.
-   Multiple incremental passes have independent resources and
    manifests.
-   Workload mutations are deterministic.
-   Existing files can be modified.
-   Restore verification validates cumulative backup states.
-   Normal logs are concise.
-   Debug logs contain enough information to troubleshoot.
-   `report.json` has a stable schema.
-   Raw Kubernetes state is separated into evidence.
-   Test resources remain after completion.
-   `make clean-all` removes owned resources.
-   External chaos is not part of the utility.
-   The utility exits non-zero on a failed test.
-   An AI agent can understand the outcome from `report.json`.
-   CI can consume the result without parsing human logs.
-   Documentation matches the actual implementation.

------------------------------------------------------------------------

# 55. Implementation Rule for the LLM Agent

When implementing this plan:

1.  **Inspect the existing code before changing it.**
2.  **Do not rewrite working functionality unnecessarily.**
3.  **Do not introduce a new framework/language unless required.**
4.  **Do not add chaos functionality.**
5.  **Do not add configuration knobs unless they represent a real
    supported test dimension.**
6.  **Do not change CBT semantics without validating against the
    existing implementation and KubeVirt behavior.**
7.  **Preserve deterministic workload generation.**
8.  **Preserve restore verification.**
9.  **Preserve cleanup semantics.**
10. **Keep backward compatibility for existing useful Make targets where
    practical.**
11. **Update documentation whenever behavior changes.**
12. **After every meaningful change, run the relevant verification
    described above.**
13. **Never declare success based only on code inspection.**
14. **Prefer evidence from an actual E2E run.**

------------------------------------------------------------------------

# 56. Implementation Action Items and Progress

Track completed implementation separately from the live-cluster acceptance
checks. Offline tests and source review are not evidence of an E2E pass.

## Action items

- [x] **Action item 1 — Phase 1 run/state model:** store each lifecycle under `runs/<run-id>/`, persist VM identity/configuration in `run.json`, and remove checkout-global run/report pointers as workflow sources of truth. Verified locally with `make test` and with a live E2E that restored the baseline and incremental prefix.
- [x] **Action item 2 — Multi-pass restore timeout:** after a three-pass restore exceeded the earlier 10-minute wait while its pod was still `Running`, increased the terminal-state wait to 30 minutes and retained the actual pod phase in failure evidence. A live three-pass RHEL 9/large-ODF run restored every prefix with `overall_passed=true`.
- [x] **Action item 3 — Phase 2 profile defaults:** make RHEL 9/large-ODF the default while preserving explicit Debian/ODF overrides. Verified by `tests/test-default-profile.sh`.
- [x] **Action item 4 — Phases 4–5 workload and restore proof:** live RHEL one-shot, staged multi-pass/extension, Windows, and Debian runs verified cumulative prefixes. Each pass added deterministic files and modified one baseline file; all restore hashes passed. The first Windows attempt exposed a malformed PowerShell array; the corrected retry passed. `tests/test-restore-failure-propagation.sh` injects a failed pass-03 restore check and verifies `overall_passed=false`.
- [x] **Action item 5 — Phase 6 stable report schema:** keep test-level backup records curated; store matching VM backup-status snapshots under `evidence/` when exposed by the API and report `null` otherwise. A live RHEL report omitted raw status fields, retained `logs.workflow`, and passed all workload/restore checks.
- [x] **Action item 6 — Phase 7 compact logs:** a successful Debian compact-output smoke completed `make e2e` in 24 terminal lines with summary-only preflight. Successful per-script steps/actions/successes remain in `runs/<run-id>/logs/workflow.log`; `DEBUG=true` prints them, verified by the RHEL `TYPE=verify` run and `tests/test-workflow-evidence.sh`.
- [x] **Action item 7 — Phase 8 staged target:** `make e2e-incremental VM=vm-<run-id>` completed all staged passes and verified the final chain. README, workflow, restore, and pass-summary commands use the semantic alias.

------------------------------------------------------------------------

# 57. Core Principle

The project should become:

``` text
Easy to run
      +
Hard to get a false PASS
      +
Easy to diagnose when it fails
      +
Easy for CI/AI to understand
```

That is the definition of a **production-grade CBT test utility** for
this project.

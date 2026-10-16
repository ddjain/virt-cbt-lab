# [Bug | Improvement]: <one-line, observable problem — the symptom, not the guessed cause>

> **Standalone engineering ticket.** Write it so an engineer who has never seen this repository,
> this cluster, or this test harness can reproduce and triage it from the ticket alone.
>
> Fill rules:
> - Choose **Bug** only for a demonstrated violation of an established contract; choose
>   **Improvement** for an ambiguous contract, a requested behaviour, or a status/reporting gap.
> - Keep **product** defects and **test-harness** defects in separate tickets. Never mix them.
> - Every factual claim carries an evidence citation — a command output, an object field with its
>   UTC timestamp, or a sanitized short quote. Label anything beyond the artifacts as **inference**.
> - Never invent a Jira key or claim this was filed. Mark unproven causes as unproven.
> - Write `not recorded` (and say why) rather than guessing a value. Never fill a gap with a
>   plausible number.
> - Sanitize: no credentials, tokens, kubeconfig paths, private hostnames, absolute host paths,
>   broad selectors, or cluster-cleanup commands.
>
> **Writing style (the first screen must be readable by a non-specialist):**
> - Short sentences, active voice. Define every specialist term the first time it appears, in
>   parentheses — e.g. "dirty bitmap (the per-disk change-tracking map inside the running VM's QEMU)".
> - Prefer plain wording over insider wording: write "the error appears on the VM object while the
>   failing object is the backup" — not "the failure surface diverges from the origin".
> - Name the **disruption** explicitly: the chaos scenario or action that was applied, with the
>   exact object it touched. Say so when it is *not* a krknctl scenario, and why.
> - Concrete beats abstract: real object names, real commands, real timestamps. A reader must be
>   able to reproduce the scenario from this file alone, without this repository.
>
> Delete this preamble in the filed ticket; keep the structure below.

## What this is, in one paragraph

<2–4 short sentences: what breaks, for whom, and the consequence. Gloss every specialist term the
first time it is used. This paragraph is what a non-specialist reads first.>

**When → then → expected**

- **When** <the product action that must be in flight — product terms, naming the object kind and
  the state it must be in>.
- **And** the disruption **<scenario ID / script / operator action>** is applied: <the exact action
  on the exact object, one line — including whether this is a krknctl scenario, and if it is not,
  why no krkn scenario fits>.
- **Then (current behaviour):** <what is observed, 1–2 sentences>.
- **Expected behaviour:** <what should happen instead, 1–2 sentences>.

## At a glance

| Field | Value |
|---|---|
| Issue type | Bug \| Improvement |
| Priority (proposed) | High/Medium/Low + the impact that justifies it; say `unassigned pending triage` when the caller should decide |
| Severity class | availability \| data protection \| resource leak \| observability \| status truthfulness \| performance |
| Owning component (suspected) | the component this most likely belongs to, marked **suspected** |
| Component(s) proven involved | what the artifacts actually prove is in the path |
| Reproducibility | `deterministic (n/n)` \| `partial (n/m, rate)` \| `special case (requires …)` \| `single observation` |
| Status / confidence | confirmed behaviour \| contract question \| root cause unproven — plus what is certain vs inferred |
| Blast radius | scope: one VM / one namespace / one node / cluster-wide / cross-component |
| Data at risk? | yes/no + one line why (state explicitly when data is **not** at risk) |
| Related scenario / execution | every run label the ticket draws on, with its UTC date, plus the scenario ID |
| Affected versions | short pointer; the measured matrix is in **Environment** below |

## Context (for an engineer new to this area)

- **What the feature does** — describe the feature in product terms in a few lines, so the ticket
  does not depend on internal vocabulary: e.g. changed-block-tracking (CBT) push-mode backups;
  a *checkpoint* per backup; a *dirty bitmap* per disk inside the running QEMU; a *tracker*
  object holding the chain's latest checkpoint; a *destination volume* hot-plugged to the VM
  while the copy runs.
- **Where the failure sits** — the object/condition/event/status surface a user or operator
  observes (name the exact kind, field and condition).
- **Observed surface vs. origin** — when the surface that reports the problem is not the site
  that causes it (e.g. events land on the VMI while the failing object is the backup CR), say so
  explicitly; that mismatch is often the defect.
- **Why it matters** — the user-visible consequence in one paragraph.

## Environment (measured, not assumed)

Capture every layer that could plausibly matter, with the identifier used to obtain it. Write
`not recorded` where it was not captured — never infer a version.

| Layer | Component | Version / identifier | How obtained |
|---|---|---|---|
| Platform | OpenShift Container Platform (server, client) | | `oc version`, `oc get clusterversion version` |
| Platform | Kubernetes API | | `oc version` |
| Nodes | OS image, kernel, container runtime | | `oc get nodes -o wide` |
| Nodes | topology (how many, which role, which nodes are in scope) | | `oc get nodes` |
| Virtualization | CNV / HCO CSV (name + version) | | `oc get csv -A` |
| Virtualization | kubevirt (operator image digest or observed version) | | `oc get kubevirt -n <cnv-ns> -o jsonpath=…observedKubeVirtVersion` |
| Virtualization | virt-launcher image digest (per-guest image) | | `oc get pod <launcher> -o jsonpath='{.spec.containers[*].image}'` |
| Virtualization | libvirt / QEMU / QEMU API in the launcher | | `virsh version` in the launcher's compute container |
| Backup API | CRD group / version (e.g. `backup.kubevirt.io/v1alpha1`) | | `oc get crd <crd> -o jsonpath=…` |
| Storage (in use) | StorageClass + provisioner + pool | | `oc get sc -o custom-columns=…` |
| Storage (in use) | CSI driver image + version | | `oc get ds <driver-ds> -o jsonpath=…` |
| Storage (in use) | backing device / filesystem / free space at the time | | `df -B1 <pool-path>` from the driver pod, or the storage provider's own tool |
| Storage (present but not exercised) | ODF/OCS operators, Ceph image, health | | `oc get csv -n openshift-storage`, `oc get cephcluster -n openshift-storage -o jsonpath=…` |
| Guest | OS release, kernel | | `cat /etc/redhat-release`, `uname -r` inside the guest |
| Guest | guest agent package version | | `rpm -q qemu-guest-agent` (or the OS equivalent) |
| Guest | vCPU / memory as configured and as seen by the guest | | VM spec vs `nproc` / `free` in the guest |
| Harness (internal only) | workflow version / artifact checksum, if the repro used it | | as recorded in the run pack |

Add a one-line note for any version that is **load-bearing** for the diagnosis (e.g. "the missing
QMP sub-command made the first repro attempt fail closed — QEMU version matters here").

## Reproducibility

- **Classification**: deterministic / partial (state the rate and denominator) / special case
  (state the exact precondition) / single observation.
- **Attempts**: how many times, on how many runs, on which dates, by whom (independent observers
  or the reporter only).
- **Stability**: which parts are exact every time (strings, statuses, timings) and which vary.
- **Preconditions**: the state that must hold before the first step; what breaks the repro.
- **Second entry path**: if the same defect was reached by a different fault path, list it — a
  defect reachable two ways is usually not an artefact of one test.

## Steps to reproduce (exact commands and injection timing)

> Prerequisites, then copy-pasteable steps. Use a dedicated cluster and **new run-scoped names**;
> never reuse another run's object names. Replace `<ns>`, `<vm>`, `<backup>`, `<node>` placeholders
> with your own values. State how to identify the exact target and verify its identity before
> acting. Never include credentials, private hostnames/paths, or cleanup commands.
>
> A reader with cluster access but **without this repository** must be able to follow this section.
> Where the recorded run had concrete names, use them verbatim and say they are the recorded names.

**Concrete objects used in this report** — every object the repro touches, so the reader knows
exactly what to create, what to watch, and what the report deleted or kept:

| Kind | Name | UID | Created (UTC) | Fate |
|---|---|---|---|---|
| <VirtualMachine / DataVolume / VirtualMachineBackupTracker / VirtualMachineBackup / PVC / VMI / Pod> | | | | kept \| deleted by <who> at <UTC> \| never created (rejected) |

Then the numbered sequence. Each step carries: a fenced command block; a line **above** it saying
**when** to run it (the event or state that opens the window); and a line **below** it saying **what
you must see** (field names, not values). Include the fail-closed pre-check and the post-check
around any injection, then the read-only command that demonstrates the defect, then the recovery
sequence. Name any repository helper only as an optional accelerator, never as the sole path.

**Formatting so the steps are copy-paste runnable:** write steps as flush-left paragraphs of the
form `**Step N — <title>.**`, never as `N. **…**` ordered-list items, and put every fenced block at
column 0 — including every line inside it. A heredoc terminator such as `YAML` in
`oc apply -f - <<'YAML'` MUST be at column 0: an indented terminator is not recognized by bash and
silently breaks the block.

1. **Setup** — create the baseline state (exact commands), and the read-only commands that prove
   it holds.
2. **Injection (if any)** — the exact command(s) **and when to run them**: the event or state that
   opens the window (e.g. "after the full backup's `Done=True` transition and before the next
   backup object is created"), any dwell/hold time, and the fail-closed pre-check that must pass
   before the command runs, plus the post-check that confirms the effect.
3. **Trigger the defect** — the command or action that exposes the bug.
4. **Observe** — the read-only inspection commands with the expected output *shape* (fields, not
   values), and how long to wait before declaring it stuck.
5. **Recover** — the command sequence that restores a healthy state (also serves as the
   workaround); note what it does **not** restore.

## Current behaviour (observed)

- Exact condition/status **and reason**, `metadata.uid`, `resourceVersion` where useful, and UTC
  timestamps for first and last occurrence and for the duration.
- Verbatim short quotes of the decisive strings (error, event reason/message, condition reason).
- State per claim whether it is an **independent** artifact observation or an **inference**.

## Expected behaviour (contract)

- The established contract this violates, or the contract you are asking to be clarified.
- The acceptance check: the command a reviewer runs and the observable result that closes it.

## Impact, workaround and data safety

- **Functions lost**, how long, and how an operator notices (or fails to notice).
- **Blast radius**: which other objects/operations are blocked, per-VM vs cluster-wide.
- **Data safety**: say explicitly whether the data path is at risk or only availability/observability.
- **Workaround / operator runbook**, live-verified where possible, with what it costs and what it
  does not fix.
- **Frequency**: how often this will be hit in production (deterministic vs rare race).
- **Unknowns**: what this ticket deliberately does not claim.

## Evidence

- **Artifact index**: repository-relative (or attachment-relative) paths, each with its UTC
  timestamp and the field/line that matters; state which artifacts are raw captures vs summaries.
- **UTC timeline**: a compact ordered list (setup → precondition → injection → effect → failure →
  recovery) with each entry's source.
- **Retained state**: whether the live objects still exist (and which were deleted after the run,
  with the reason).

## Negative results and what would falsify this ticket

- **Refuted hypotheses** — the explanations already ruled out by experiment, with the artifact
  that ruled them out. This is often more valuable than the finding itself.
- **Falsifier** — the observation that would prove this ticket wrong or make it a non-issue.

## Additional feedback (reporter's notes)

- Hypotheses that remain open, with the smallest experiment that would settle each.
- Triage questions that decide scope (e.g. "is the guard meant to consult terminal-ness?").
- Anything environment-specific the next reproducer should know (quirks, timing, pitfalls).
- Cross-references: sibling tickets in this folder, the findings registry under `docs/findings/`,
  and — separately and clearly labelled — any harness/tooling gap this run filed elsewhere.

## Sanitisation checklist

- [ ] No credentials, tokens, kubeconfig contents or private keys
- [ ] No private hostnames or absolute host paths
- [ ] No broad selectors (names or run-scoped labels only)
- [ ] No destructive commands other than the documented, scoped workaround
- [ ] Commands are the ones actually validated (illustrative ones are labelled)

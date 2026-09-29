---
name: cbt-diagnostics
description: Triage this KubeVirt CBT demo with bounded, evidence-preserving reads. Use when diagnosing workflow failures, validation artifacts, OpenShift events, backups, checkpoints, or logs; prefer targeted status and event queries over loading whole metrics or log files.
compatibility: Requires Bash and the repository's scripts/ai-context.sh. Cluster checks additionally require oc and a configured kubeconfig.


# CBT diagnostics

Use an evidence ladder. Stop as soon as the current layer answers the question; do not collect unrelated telemetry.

1. **Repository map** — Read `AGENTS.md`, `README.md`, `Makefile`, the affected script, its manifest, and `docs/vm-cbt-workflow.md` sections relevant to the failing stage.
2. **Local artifact index** — Run `scripts/ai-context.sh`. This reports file names, byte/line counts, and SHA-256 hashes without scanning or emitting log content.
3. **Targeted artifact read** — Select the smallest relevant file and run `scripts/ai-context.sh --file PATH --snippets`. Use `--focus 'checkpoint|backup|error'` when the failure is known. Snippets are bounded and redacted; line numbers and the source hash preserve traceability.
4. **Exact evidence** — Use `--raw-range PATH:S-E` only when an exact local range is necessary. It is intentionally unredacted; never send its output to an AI service without checking it for secrets.
5. **Cluster state first** — Query the named resource and only the fields needed for the invariant, for example:

   ```sh
   oc get vmbackup hello-full -n vm-cbt-demo \
     -o jsonpath='type={.status.type} done={.status.conditions[?(@.type=="Done")].status} checkpoint={.status.checkpointName}{"\n"}'
   oc get vmbackuptracker hello-tracker -n vm-cbt-demo \
     -o jsonpath='latest={.status.latestCheckpoint.name}{"\n"}'
   oc events -n vm-cbt-demo --for virtualmachinebackup/hello-full --types=Warning
   ```

6. **Escalate narrowly** — Inspect controller or pod logs only after status and resource-scoped Warning events leave a causal gap. Bound live collection with the relevant resource, `--since-time` or `--tail`, and a single container when applicable.

## Evidence contract

- Never mutate, truncate, rotate, or overwrite source logs or validation files.
- Report the exact file/resource, query, time boundary, line range, and hash for evidence used.
- Separate observed facts from inference. A missing match is not proof that an event did not occur.
- Metrics answer capacity/performance questions; object status and events answer workflow state; logs explain causality; traces answer cross-component timing. Do not substitute one signal for another.
- Preserve a raw artifact locally when redaction or summarization is used. Send only the minimum redacted excerpts needed for the task.
- Do not print kubeconfig contents, private keys, tokens, passwords, or full environment dumps.

## Stage selectors

| Failure stage | First targeted evidence |
|---|---|
| preflight | `make preflight` result and the named failed check |
| VM setup | VM CBT state/Ready fields, VMI phase, DataVolume/PVC phase, Warning events |
| full backup | `hello-full` Done/type/checkpoint, tracker latest checkpoint, output PVC phase |
| incremental backup | full checkpoint vs tracker checkpoint, guest hash transition, incremental Done/type/checkpoint |
| verification | all five invariants from `docs/vm-cbt-workflow.md` |
| cleanup | namespace/PV/key ownership state; do not inspect unrelated cluster logs |

If these selectors do not identify the cause, state the missing evidence and escalate one layer only.

# AI-assisted workflow and evidence discipline

This repository is small enough that an AI agent should not build a broad metrics or log corpus before understanding the failing invariant. The default workflow is **map, index, select, query, escalate**.

## Why this layout

- `AGENTS.md` is the hot path: stable repository rules, architecture, safety boundaries, and the navigation contract.
- `.agents/skills/cbt-diagnostics/SKILL.md` is cold, reusable procedure: it activates for CBT diagnosis and keeps detailed triage instructions out of every session.
- `scripts/ai-context.sh` is a deterministic local tool call. It inventories artifacts without scanning or emitting their contents, then returns bounded, line-addressable, redacted snippets only for explicitly selected files.
- This document is the human-readable operating model and evidence contract.

The design follows progressive disclosure from the [Agent Skills specification](https://agentskills.io/specification): metadata first, full skill instructions only on activation, and supporting resources on demand. It also keeps the always-loaded project guidance small because the Codex agent loop includes prior tool outputs in later prompts and must manage context-window growth ([OpenAI](https://openai.com/index/unrolling-the-codex-agent-loop/)).

## Commands

Inventory generated evidence without scanning or emitting contents:

```sh
make ai-context
```

Select one artifact and inspect only bounded diagnostic windows:

```sh
scripts/ai-context.sh \
  --file logs/e2e-2026-09-29-success.log \
  --snippets \
  --focus 'error|fail|warn|checkpoint|backup'
```

Inspect a known exact range locally. This output is unredacted and must not be sent to an AI service without review:

```sh
scripts/ai-context.sh --raw-range logs/e2e-2026-09-29-success.log:120-135
```

The script never edits source artifacts. Every selected file reports byte count, line count, and SHA-256. Snippet output reports line numbers and omitted-match counts. The hash and line references make summarization auditable without copying the full file into the model context.

## Evidence ladder

1. **Workflow invariant** — identify the stage and the exact assertion that should hold.
2. **Structured object state** — use `oc get ... -o jsonpath=...` for only the fields needed.
3. **Resource-scoped events** — use `oc events -n vm-cbt-demo --for TYPE/NAME --types=Warning`.
4. **Bounded logs** — use one relevant component/container and a time or tail bound only when state/events do not explain the failure.
5. **Metrics/traces** — add them for capacity, latency, or cross-component timing questions; they are not substitutes for backup object status.

Kubernetes documents metrics, logs, and traces as complementary observability signals, and `kubectl events` supports filtering by resource and event type. OpenTelemetry's log model provides timestamps, severity, resource, and trace/span correlation fields; preserve those fields when exporting structured evidence rather than flattening everything into unindexed text.

## No-data-loss rules

- Never delete, truncate, rotate, or rewrite logs to make them smaller.
- Do not treat a bounded excerpt as the complete record. State the source path, hash, line range, time boundary, and selection expression.
- Keep original artifacts local and ignored. Redact only the copy sent to an AI service.
- A search miss means “not found in the selected artifact/range,” not “did not happen.”
- If the current layer is insufficient, fetch one narrower next layer; do not jump to all cluster logs.
- Avoid repeated searches that return the same evidence. Carry forward the file hash and line references.

## Retrieval guidance for agents

Use targeted file reads and symbol/caller navigation before textual search. The current repository contract is fixed: `scripts/common.sh` owns names and `oc_cmd`, workflow scripts own stages, manifests own resources, and docs describe semantics. Read the affected script, manifest, caller, and workflow section before proposing a change.

Do not create a vector index or MCP server for this repository yet. It is small, and the added dependency and stale-index risk outweigh the benefit. If the repository grows materially, add a searchable context resource with explicit URIs, caching, pagination, and update notifications rather than copying the whole tree into every request; these are supported concepts in the [MCP resources specification](https://modelcontextprotocol.io/specification/2026-07-28/server/resources). Benchmark retrieval quality before adopting embeddings: recent research finds no single retrieval family wins every coding-agent task and that selective retrieval still has calibration gaps ([Agent Retrieval Bench](https://arxiv.org/abs/2607.24882)).

## Reusable skill installation

Clients implementing the Agent Skills format can discover `.agents/skills/cbt-diagnostics/SKILL.md`. Other clients can use the same file as a manually selected procedure. The skill is intentionally repository-local: it contains cluster names and invariants that should not be installed globally or reused for unrelated projects.

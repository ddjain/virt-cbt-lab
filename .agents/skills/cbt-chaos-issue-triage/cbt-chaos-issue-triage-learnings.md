# CBT Chaos Issue Triage Learnings

Reusable, evidence-backed guidance for resolving CBT issues, designing scenario artifacts, and troubleshooting triage validation. This file is separate from run-execution learnings so each skill loads only the knowledge relevant to its task.

## How to maintain this file

- Read only when performing CBT issue triage or troubleshooting triage validation.
- Add a dated entry only when triage or validation establishes reusable, actionable guidance.
- Include the affected scenario/stage, observed issue, resolution or validated workaround, and sanitized repository-relative evidence path(s).
- Keep entries concise and generally applicable; keep issue-specific decisions and outcomes in that scenario's artifacts.
- Never include secrets, credential values, private hostnames, environment-specific absolute paths, or unsupported speculation.
- When newer evidence invalidates a lesson, correct or remove the stale guidance rather than accumulating contradictory advice.
- Add entries only after the triage closeout confirms an important, generalizable learning; check for duplicates first and prefer updating an existing entry.
- Do not create a new learning file. If no appropriate existing file exists, ask before creating one.
- If a learning implies changing a main skill, propose the exact change and get user confirmation before editing that skill.

## Learnings

### 2026-10-10 — Krkn pod-scenarios selector semantics

In the inspected registry, `--name-pattern` filters pods only when `--pod-label` is omitted. Combining them can leave the exact-name filter ineffective and broaden the eligible target set. For dynamic leader or node-handler targeting, resolve and verify labels/readiness/node on the host, then pass Krkn the exact name pattern (and `--node-names` where needed) without `--pod-label`; dry-run the final arguments.

Evidence: `cbt-chaos/scenarios_v2/CBT-F-03/scenario-spec.md` §§3–4, `cbt-chaos/scenarios_v2/CBT-F-04/scenario-spec.md` §3, and `cbt-chaos/scenarios_v2/CBT-F-05/scenario-spec.md` §4.

### 2026-10-12 — Destination-PVC-size scenarios need VM_OS=debian; Krkn's pvc-scenarios execs into an existing pod

For any scenario that needs to fill a backup destination PVC to a target percentage within a short chaos duration, check `scripts/common.sh`'s `set_manifest_variant_settings()` first: `VM_OS=rhel9` always resolves the full/root PVC to 80Gi regardless of `MANIFEST_VARIANT` (`default`/`large`/`odf`/`large-odf` all collapse to the same 80Gi request on RHEL 9). Only the small Debian profiles (`VM_OS=debian` with `MANIFEST_VARIANT=default` → 5Gi HPP, or `odf` → 6Gi Ceph RBD) give a destination PVC small enough for a 95%-style fill to be practically achievable in a ~2-minute window; `large`/`large-odf` are 40Gi/48Gi and are also too big. Confirm live PVC sizes with `oc get pvc` rather than assuming the `.env.example` comment applies uniformly across `VM_OS`.

Separately, Krkn's `pvc-scenarios` plugin (read directly from the installed krknctl image's `pvc_scenario_plugin.py` on the execution host), when given only `--pvc-name` (no `--pod-name`), discovers and `exec`s into one of the PVC's *existing* mounting pods rather than scheduling a new pod — it computes the fill size live from `df` on that pod's mount. This means a `ReadWriteOnce` destination PVC already attached to a hotplug/attachment pod is not a cross-node multi-attach risk for this scenario type: no second pod is ever scheduled.

Evidence: `cbt-chaos/scenarios_v2/CBT-F-08/scenario-spec.md` §2.

### 2026-10-12 — krknctl's pod-network-filter can't express "block all ports"; use --pod-selector for launcher pods

Krkn's underlying `network_chaos_ng` library (`pod_network_filter.py`/`utils_network_filter.py` inside
the pulled `workload-krkn-network-chaos` image) treats an empty `ports` list as "block all traffic on
all ports" — a true IP-level filter. `krknctl`'s CLI layer does not expose this: `--ports` is required
and format-validated, and live `--dry-run` testing confirmed blank, a range (`1-65535`), and `all` are
all rejected (`Network ports must be in the format: 8080 or a comma separated list ...`); only literal
comma-separated port numbers pass. When an issue asks for a true all-ports/all-protocols block, either
accept and document a representative port-list compromise, or fall back to a narrowly scoped
`oc debug node` + `nsenter`/`iptables -j DROP` (no `-p`/`--dport`) — but that reimplements Krkn's own
(already-tested) privileged-helper and pid-resolution logic, so prefer the compromise unless the issue
specifically requires a literal guarantee. Separately, `virt-launcher` pods' generated name suffix is
unknown ahead of a run, so target them with `--pod-selector vm.kubevirt.io/name=<vm>` rather than
`--pod-name`.

Evidence: `cbt-chaos/scenarios_v2/CBT-F-11/scenario-spec.md` §3.

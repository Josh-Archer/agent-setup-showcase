# Agent Architecture and Delegation

This repository defines the agent role maps and provides capabilities for delegating repository work from Codex to external agent runtimesâ€”specifically **Grok Build** (`grok` CLI) and **Antigravity** (`agy` CLI).

For operational details and setup, see [Grok/Antigravity Delegation Guide](docs/grok-agy-delegation.md).

---

## Layered project instructions

Instructions are intentionally layered. Do not hand-edit generated surfaces.

| Layer | Path | Who loads it |
| :--- | :--- | :--- |
| **Cross-provider contract** | Root `AGENTS.md` (this file) | Grok (via `agents_md: true` on generated agents); Codex/session rules; humans |
| **Canonical role definitions** | `.codex/agents/*.agent.md` | Codex; also referenced by Grok roles via `prompt_file` in `.grok/roles/*.toml` |
| **Codex agent index** | `.codex/agents/AGENTS.md` | Codex operators; links here and to the skill |
| **Generated Grok agents** | `.grok/agents/*.md`, `.grok/roles/*.toml` | `grok --agent <role>` |
| **Generated Antigravity plugin** | `.agents/plugins/home-codex-agents/` | `agy --agent <role>` |
| **Generated OMP agents** | `.omp/agents/*.md` | `omp` sessions / subagents |

### Grok `agents_md` behavior

`scripts/sync_agent_surfaces.py` sets `agents_md: true` on every generated
`.grok/agents/<role>.md` file. With that flag, Grok Build injects repository
project-rule files into the session (root `AGENTS.md` / `Agents.md`, and any
deeper directory rules when the working tree uses them). Role-specific behavior
still comes from the agent body.

Prefer one root file named `AGENTS.md`. On case-insensitive filesystems,
`Agents.md` and `AGENTS.md` are the same file; on case-sensitive volumes, keep a
single casing so discovery stays consistent.

### Antigravity

Antigravity does **not** auto-load root `AGENTS.md`. Sync generates
`.agents/plugins/home-codex-agents/rules/repo-agents.md` as a short constitution
pointer for agy sessions. Prefer putting durable cross-provider rules here in
root `AGENTS.md`, and regenerate the plugin after role changes.

### OMP (Oh My Pi)

OMP sessions automatically discover root `AGENTS.md` and `CLAUDE.md`, load
installed skills from `~/.omp/agent/skills/` and `.omp/skills/`, and resolve
agent definitions from `~/.omp/agent/agents/` and `.omp/agents/`.

### Regenerating surfaces

```bash
python3 scripts/sync_agent_surfaces.py
python3 scripts/sync_agent_surfaces.py --check   # exit non-zero if generated trees drift
python3 scripts/sync_agent_surfaces.py --prune   # also delete stale generated surfaces
```

**Prune warning:** default sync is safe and never deletes. After you **rename or
delete** a Codex agent under `.codex/agents/`, old files can remain in
`.grok/roles/`, `.grok/agents/`, `.agents/plugins/home-codex-agents/agents/`, and
`.omp/agents/`. Sync reports those orphans and only removes them when you pass
**`--prune`**. Review the listed paths before pruning — `--prune` is destructive
for unmatched generated surfaces only (not for hand-authored Codex sources).

CI enforces the same check via `.github/workflows/agent-surface-drift.yml`
(on PRs and pushes to `master`/`main`). After editing `.codex/agents/*.agent.md`,
run the sync script, commit the regenerated `.grok/`,
`.agents/plugins/home-codex-agents/`, and `.omp/` trees, and push — do not hand-edit generated files.

---

## Anti-AI Slop & Quality Standard (`unslop`)

All agents across all harnesses (Codex, Claude, Gemini/Antigravity, Grok, OMP, Copilot) must follow the **unslop** core contract ([`.codex/skills/unslop/SKILL.md`](.codex/skills/unslop/SKILL.md)):

1. **Direct & Concise**: Avoid conversational throat-clearing, sycophantic openers ("Certainly!"), and generic closing fluff. Deliver the substance immediately.
2. **No Inflated AI Vocabulary**: Eliminate overused marker buzzwords (*delve*, *tapestry*, *testament*, *pivotal*, *beacon*, *catalyst*, *streamline*, *harness*, *transformative*).
3. **No Code Slop**: Do not write commentary that merely narrates obvious syntax (e.g. `// Increment i by 1`). Avoid speculative over-engineering and unnecessary helper wrappers.
4. **Preserve Facts**: Always retain exact file paths, code syntax, technical precision, and domain details.
5. **Skill Invocations**: Triggered via `/unslop`, `@unslop`, or when reviewing and editing AI drafts to calibrate human tone.

---

## Agent Workflow

- **CI ownership:** Only agent validation workflows are active; see
  [CI ownership](docs/ci-ownership.md). Homelab workflow snapshots belong under
  `.github/archived-homelab-workflows/` and must not be restored wholesale.

- **PR CI Enforcement Hook:** When opening a PR, always wait for the GitHub Actions CI checks to pass (e.g., using `gh pr checks <id> --watch`) before finishing your task. If the checks fail, investigate the logs, push a fix, and verify it passes.
- **Commit Signing Workflow:** Ensure Git GPG/SSH commit signing is configured and uses the default global signing key (e.g., from Bitwarden/ssh-agent). Make sure your SSH agent/vault is unlocked when tasks are running so commits can be signed successfully without blocking.

---

## Canonical Role Map

Project agents are mapped across different provider surfaces. The canonical roles defined in this repository under `.codex/agents/` are mirrored into `.grok/agents/` and the Antigravity plugin under `.agents/plugins/home-codex-agents/`.

Active Codex roles use `gpt-6-astra` with separate effort settings:

| Role | Effort | Responsibility |
| --- | --- | --- |
| lead | medium | Requirements, implementation, integration, completion |
| investigator | medium | Evidence gathering and root-cause diagnosis |
| reviewer | high | Independent correctness, security, and operational review |
| validation-runner | low | Prescribed checks and failure reporting |

Follow [Astra agent policy](docs/astra-agent-policy.md). Old role names remain
compatibility aliases for external commands. Domain specialization uses skills.
Native Codex TOML agents are generated from the four active Markdown definitions.

---

## The Delegation Capability

The repository contains a specialized Codex delegation skill located in [.codex/skills/grok-agy-delegate/SKILL.md](.codex/skills/grok-agy-delegate/SKILL.md). This skill allows Codex to securely offload execution workloads.

```mermaid
graph TD
    Codex[Codex Agent Session] -->|Triggers delegation| SKILL[.codex/skills/grok-agy-delegate/SKILL.md]
    SKILL -->|Single-Agent| Delegate[.codex/skills/grok-agy-delegate/scripts/delegate.py]
    SKILL -->|Multi-Agent Plan| Orchestrate[.codex/skills/grok-agy-delegate/scripts/orchestrate.py]
    
    Delegate -->|CLI Invoke| Grok[Grok Build CLI]
    Delegate -->|CLI Invoke| agy[Antigravity CLI]
    
    Orchestrate -->|Spawns parallel| Delegate
```

### 1. The Single-Agent Wrapper (`.codex/skills/grok-agy-delegate/scripts/delegate.py`)
The delegation wrapper standardizes execution commands across providers. It maps generic roles to their provider-specific configurations and executes the corresponding CLI executable (`grok` or `agy`) locally.

- **Execution Mode**: Uses local user filesystem permissions and credentials.
- **Safety**: Integrates dry-run checks and enforces strict timeouts.

### 2. The Plan Orchestrator (`.codex/skills/grok-agy-delegate/scripts/orchestrate.py`)
For complex, multi-step operations, Codex creates a structured plan in JSON and executes it via the orchestrator. The orchestrator:
- Parses task dependencies and detects cycles at plan load time.
- Executes ready tasks concurrently (subject to `--max-parallel`).
- **Skips dependents** when a prerequisite fails, times out, or was itself skipped.
- Captures and logs outputs under `.agent-runs/<run-id>/`.
- Invokes a **manager** role to review task outputs, resolve conflicts, and output a final reconciled manifest.

Default provider when a plan omits `provider` is **`agy`**. Tasks and the manager may override provider/model.

### 3. The `.agent-runs` Handoff Directory
Coordinated multi-agent execution generates a run directory under `.agent-runs/<run-id>/` (e.g. `.agent-runs/20260710T124500Z-8b2a3c7d/`). This directory is listed in `.gitignore` because runs are local execution artifacts.

```
.agent-runs/<run-id>/
â”œâ”€â”€ plan.json                # Copy of the input orchestrator plan
â”œâ”€â”€ run.json                 # Reconciled execution manifest (status, exit codes, file paths)
â”œâ”€â”€ tasks/
â”‚   â”œâ”€â”€ <task-id-1>/
â”‚   â”‚   â”œâ”€â”€ prompt.txt       # Combined worker system prompt and context
â”‚   â”‚   â”œâ”€â”€ output.txt       # Worker stdout (durable handoff)
â”‚   â”‚   â””â”€â”€ stderr.txt       # Worker stderr logs
â”‚   â””â”€â”€ <task-id-2>/
â”‚       â”œâ”€â”€ prompt.txt
â”‚       â”œâ”€â”€ output.txt
â”‚       â””â”€â”€ stderr.txt
â””â”€â”€ manager/
    â”œâ”€â”€ prompt.txt           # Manager reconciliation instruction
    â”œâ”€â”€ output.txt           # Final manager summary
    â””â”€â”€ stderr.txt           # Manager CLI error logs
```

### 4. Cross-Provider Communication Protocol
Grok and Antigravity **do not share a direct network or API communication protocol**. They are decoupled runtimes. 

Instead, state and context are handed off strictly through **physical files in the `.agent-runs` directory**:
1. When a task completes, its stdout is persisted to `tasks/<task-id>/output.txt`.
2. Any downstream task that depends on it has the path of that `output.txt` injected into its prompt.
3. The downstream agent reads the dependency output from the local filesystem to capture context before executing.
4. If an upstream task is `failed`, `timed-out`, or `skipped`, dependents are marked `skipped` and are not executed.
5. Finally, the manager agent reads all generated output files to reconcile the final state.

### 5. Provider and Model Selection
Provider and model selection can be specified explicitly at the plan or task level. When not overridden, the orchestrator and wrapper apply mappings from the canonical matrix [`models/matrix.json`](models/matrix.json) (see [docs/model-matrix.md](docs/model-matrix.md)). Generated equivalence notes live in [.agents/plugins/home-codex-agents/rules/model-equivalence.md](.agents/plugins/home-codex-agents/rules/model-equivalence.md).

Promote a new generation with `python scripts/promote_model_matrix.py` after editing the matrix.

Current tier pins (matrix_version `2026.09.1`):

- **High-Complexity Roles** (e.g., `architecture`, `debugger`):
  - Grok: `grok-4.5`
  - Antigravity: `Claude Opus 4.6 (Thinking)`
- **Medium-Complexity Roles** (e.g., `development`, `testing`):
  - Grok: `grok-composer-2.5-fast`
  - Antigravity: `Gemini 3.5 Flash (Medium)`
- **Low-Risk Validation Roles** (e.g., `validation-runner`, `junior`):
  - Grok: `grok-composer-2.5-fast`
  - Antigravity: `Gemini 3.5 Flash (Low)`

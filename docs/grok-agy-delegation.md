# Grok & Antigravity (agy) Delegation Guide

This guide details the setup, configuration, safety protocols, and invocation options for delegating repository tasks from Codex to Grok Build (`grok`) and Antigravity (`agy`).

Cross-provider architecture and the role map live in the repository root [`AGENTS.md`](../AGENTS.md).

---

## Setup & Pre-requisites

### 1. CLI Executables
Both CLI tools must be installed and available on the system `PATH`.
```bash
# Verify CLI accessibility
command -v grok
command -v agy
```
If a CLI is missing or unauthenticated, the delegation scripts will exit immediately with an error rather than falling back silently.

### 2. Synchronizing Agent Surfaces
Agent definitions are authored under `.codex/agents/*.agent.md`. To update the provider roles, run the sync script:
```bash
python3 scripts/sync_agent_surfaces.py
```
This script generates:
- `.grok/roles/*.toml` and `.grok/agents/*.md` for Grok (each agent sets `agents_md: true`).
- `.agents/plugins/home-codex-agents/agents/*.md` plus `rules/model-equivalence.md` and `rules/repo-agents.md` for the Antigravity plugin.

After editing canonical agents, regenerate surfaces before committing. To fail when generated trees drift:
```bash
python3 scripts/sync_agent_surfaces.py --check
```

#### Stale surfaces after rename or delete

Default sync **writes/updates only** and never deletes generated files. If you
rename or remove a role under `.codex/agents/`, old Grok/agy surface files can
remain as orphans. Sync lists them and suggests an explicit prune:

```bash
# Safe: regenerate + report orphans (no deletes)
python3 scripts/sync_agent_surfaces.py

# Destructive: regenerate and delete unmatched generated surfaces
python3 scripts/sync_agent_surfaces.py --prune
```

**Warning:** `--prune` deletes generated files that no longer map to a Codex
agent (`.grok/roles/*.toml`, `.grok/agents/*.md`, plugin `agents/*.md`). It does
not touch `.codex/agents/` sources. Prefer inspecting the orphan list from a
safe run before pruning.

### 3. Layered `AGENTS.md` and Grok `agents_md`
| Layer | Path | Notes |
| :--- | :--- | :--- |
| Cross-provider contract | Root `AGENTS.md` | Role map, handoffs, safety; injected for Grok when `agents_md: true` |
| Canonical roles | `.codex/agents/*.agent.md` | Only hand-authored role source for Grok/agy sync |
| Codex index | `.codex/agents/AGENTS.md` | Codex-oriented pointer; not a second path authority |
| Generated Grok | `.grok/agents/`, `.grok/roles/` | Do not hand-edit |
| Generated agy plugin | `.agents/plugins/home-codex-agents/` | Do not hand-edit |

Grok named agents use `agents_md: true`, so root project rules are merged into the session with the role body. Prefer the filename `AGENTS.md` (one casing) so discovery is consistent on case-sensitive filesystems.

Antigravity does not auto-load root `AGENTS.md`; use the generated `rules/repo-agents.md` summary and put durable rules in root `AGENTS.md`.

---

## Invocation Examples

### Single Agent Handoff (`delegate.py`)
Run a single agent role on a target directory:
```bash
python3 .codex/skills/grok-agy-delegate/scripts/delegate.py \
  --provider grok \
  --role debugger \
  --cwd "$PWD" \
  --prompt "Investigate why the test suite fails on gitops config files."
```

#### CLI Arguments
- `--provider`: Choose `grok` or `agy` (Required).
- `--role`: The named agent role (e.g. `debugger`, `devops`, `testing`).
- `--model`: Explicit provider-specific model override (optional).
- `--cwd`: Working directory path for the delegated execution (default: `.`).
- `--prompt` / `--prompt-file`: The prompt text or path to a file containing the prompt (mutually exclusive, required).
- `--dry-run`: Prints the generated command instead of executing it.
- `--output-format`: Output mode (`plain` (default), `json`, or `streaming-json`).

### Coordinated Multi-Agent Plan (`orchestrate.py`)
Run a dependency-aware plan across multiple agents:
```bash
python3 .codex/skills/grok-agy-delegate/scripts/orchestrate.py \
  --plan-file /tmp/my-agent-plan.json \
  --cwd "$PWD" \
  --max-parallel 3
```

#### CLI Arguments
- `--plan-file`: Path to the plan JSON file (Required).
- `--provider`: Optional provider override for the plan (`grok` or `agy`).
- `--cwd`: Active working directory (default: `.`).
- `--run-dir`: Override the default output folder (default: `.agent-runs/<timestamp>-<shortuuid>`).
- `--max-parallel`: Maximum number of concurrent workers (default: `3`).
- `--task-timeout-seconds`: Default timeout for each worker and the manager (default: `600`). A task can override this with `timeout_seconds` in the plan. The manager can override with plan-level `manager_timeout_seconds`.
- `--dry-run`: Performs dry-run setup, writes prompt files, but runs no LLMs.

---

## JSON Plan Shape

Plans are loaded as JSON. Below is the schema structure and description:

```json
{
  "goal": "Reorganize the deployment manifests and test CI pipeline",
  "provider": "agy",
  "manager_role": "manager",
  "tasks": [
    {
      "id": "generate-manifests",
      "role": "gitops-architect",
      "prompt": "Create kustomize overlays for staging and production under grok-servaar/media."
    },
    {
      "id": "validate-linting",
      "role": "testing",
      "depends_on": ["generate-manifests"],
      "prompt": "Run yaml linting and validation on the newly generated overlays.",
      "provider": "grok"
    },
    {
      "id": "dry-run-deploy",
      "role": "devops",
      "depends_on": ["validate-linting"],
      "prompt": "Execute dry-run deploy checks on the target node."
    }
  ]
}
```

### JSON Fields Glossary
- **`goal`** *(string, required)*: The overall target outcome.
- **`provider`** *(string, optional)*: Default CLI provider (`grok` or `agy`) for tasks in the plan. **If omitted, the orchestrator defaults to `agy`.**
- **`manager_role`** *(string, optional)*: Reconciling agent role (default: `manager`).
- **`manager_provider`** *(string, optional)*: Override provider for the manager reconciliation phase (defaults to root `provider`, else `agy`).
- **`manager_model`** *(string, optional)*: Override model for the manager role.
- **`manager_timeout_seconds`** *(number, optional)*: Manager timeout; defaults to `--task-timeout-seconds`.
- **`tasks`** *(array, required)*: Chronological and dependency-linked tasks.
  - **`id`** *(string, required)*: Unique identifier within the plan.
  - **`role`** *(string, required)*: Agent role definition to load.
  - **`prompt`** *(string, required)*: Specific task instructions.
  - **`depends_on`** *(array, optional)*: Task IDs that must finish with status `completed` or `dry-run` before this task starts. Failed, timed-out, or skipped prerequisites cause this task to be **skipped** (not executed).
  - **`provider`** *(string, optional)*: Override default provider for this task.
  - **`model`** *(string, optional)*: Override default model for this task.
  - **`output_format`** *(string, optional)*: Override output format.
  - **`timeout_seconds`** *(number, optional)*: Execution timeout in seconds.

### Dependency failure semantics
- Worker statuses: `completed`, `failed`, `timed-out`, `skipped`, `dry-run`.
- A task becomes ready only when every `depends_on` entry has status `completed` or `dry-run`.
- If any dependency is `failed`, `timed-out`, or `skipped`, the dependent is marked `skipped` and is not invoked.
- Skipping cascades through the graph (A fails → B skipped → C skipped).
- The manager still runs so the run can be reconciled; the process exit code is non-zero if any task or the manager is not successful.

---

## Provider Model Overrides

Model selection is determined dynamically by the complexity of the requested agent role. Mappings are defined as follows:

| Role Complexity Tier | Codex Model Class | Grok Equivalent | Antigravity Equivalent |
| :--- | :--- | :--- | :--- |
| **High / Reasoning** | `gpt-5.6-sol`, `gpt-5.6-sol-high`, `gpt-5.6-sol-xhigh`, `gpt-5.6-sol-medium` | `grok-4.5` | `Claude Opus 4.6 (Thinking)` |
| **Medium / Fast** | `gpt-5.6-terra`, `gpt-5.6-terra-high`, `gpt-5.6-luna-high` | `grok-composer-2.5-fast` | `Gemini 3.5 Flash (Medium)` |
| **Low / Spark** | `gpt-5.6-luna` | `grok-composer-2.5-fast` | `Gemini 3.5 Flash (Low)` |

### How to Override Models
1. **At the CLI Level**: Pass the `--model` parameter to `.codex/skills/grok-agy-delegate/scripts/delegate.py`.
2. **At the Plan level**: Define a task-specific `"model"` key inside the plan JSON.

---

## Safety Boundaries

- **Local Permissions**: Execution operates under the active developer shell session permissions. The CLI has access to read and write files where the active shell does.
- **No Shared Secrets**: Never pass credentials, API keys, or browser sessions to delegation prompts.
- **Read-Only Safeties**: For tasks meant strictly for analysis (e.g. debugging, security scans), employ read-only roles like `security-auditor` or `gitops-architect` to prevent unintended code edits.
- **Code Change Inspection**: Delegated write operations are performed locally in the workspace. Run `git diff` to inspect changes before staging or committing them.
- **Run artifacts**: `.agent-runs/` is gitignored; do not commit handoff directories.

---

## Run Validation

### Exit Codes
The plan orchestrator yields:
- `0` if all tasks and the manager reconcile successfully (`completed` or `dry-run`).
- `1` if any task fails, times out, is skipped, or the manager reconciliation reports failure.

### Focused checks
```bash
# Generated surfaces match canonical agents
python3 scripts/sync_agent_surfaces.py --check

# Orchestrator / dependency unit tests
python3 -m unittest discover -s scripts/tests -v

# Dry-run plan without calling provider CLIs
python3 .codex/skills/grok-agy-delegate/scripts/orchestrate.py \
  --plan-file .codex/skills/grok-agy-delegate/references/example-plan.json \
  --cwd "$PWD" --dry-run
```

This showcase repository’s copied `.github/workflows/` trees target a larger home monorepo and are not the primary CI for these agent surfaces. Prefer the local checks above until a slim agent-only workflow is added on purpose.

### The Manifest (`run.json`)
At the end of an execution, a manifest JSON file is written to `.agent-runs/<run-id>/run.json` containing the metadata for audits:
```json
{
  "run_dir": "/path/to/repo/.agent-runs/20260710T124500Z-8b2a3c7d",
  "tasks": [
    {
      "id": "generate-manifests",
      "status": "completed",
      "returncode": 0,
      "output": "/path/to/repo/.agent-runs/20260710T124500Z-8b2a3c7d/tasks/generate-manifests/output.txt",
      "stderr": "/path/to/repo/.agent-runs/20260710T124500Z-8b2a3c7d/tasks/generate-manifests/stderr.txt",
      "started": "2026-07-10T16:45:00.123456Z"
    }
  ],
  "manager": {
    "status": "completed",
    "returncode": 0,
    "output": "/path/to/repo/.agent-runs/20260710T124500Z-8b2a3c7d/manager/output.txt",
    "stderr": "/path/to/repo/.agent-runs/20260710T124500Z-8b2a3c7d/manager/stderr.txt"
  }
}
```

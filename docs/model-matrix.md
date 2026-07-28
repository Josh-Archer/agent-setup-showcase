# Versioned model matrix

Canonical pins for agent models live in [`models/matrix.json`](../models/matrix.json).
That file is the **source of truth** for Codex, Claude, Gemini, Grok, and
Antigravity (agy) model assignments in this repository.

## Layout

| Field | Purpose |
|-------|---------|
| `schema_version` | Matrix JSON schema (currently `1`) |
| `matrix_version` | Human/generation id (bump when promoting pins) |
| `defaults` | Wrapper defaults when no named role is selected |
| `tiers` | Equivalence tier → provider model pins (`high` / `medium` / `low`) |
| `roles` | Codex role → `codex` model, `tier`, optional `claude` / `gemini` filenames |
| `extra_pins` | Surface-only agents or Claude/Gemini overrides that differ from the role tier |

### Surfaces

| Surface | Path | How pins apply |
|---------|------|----------------|
| Codex | `.codex/agents/*.agent.md` | Exact `roles.*.codex` model string |
| Claude | `.claude/agents/*.md` | Role mapping + `extra_pins.claude` overrides |
| Gemini | `.gemini/agents/*.md` | Role mapping + `extra_pins.gemini` |
| Grok | `.grok/roles/*.toml`, `.grok/agents/*.md` | Regenerated from Codex + tier |
| Antigravity | `.agents/plugins/home-codex-agents/` | Regenerated from Codex + tier |

Grok and Antigravity are **generated**. Do not hand-edit their model fields;
edit the matrix (and Codex role definitions via promote), then regenerate.

## Promote a new model generation

When a provider ships a new generation (for example Claude Opus 4.7, Grok 5,
or GPT-5.7 Sol), update the matrix and propagate:

1. **Edit** `models/matrix.json`
   - Bump `matrix_version` (for example `2026.07.1` → `2026.08.1`).
   - Update the relevant `tiers.*.{codex,grok,agy,claude,gemini}` pins.
   - Update any per-role `roles.*.codex` strings that encode the generation.
   - Update `extra_pins` for surface-specific overrides.
2. **Promote** (writes Codex/Claude/Gemini frontmatter and regenerates Grok/agy):

   ```bash
   python scripts/promote_model_matrix.py
   ```

3. **Check** (CI-safe drift detection):

   ```bash
   python scripts/promote_model_matrix.py --check
   python scripts/sync_agent_surfaces.py --check
   python -m unittest discover -s scripts/tests -v
   ```

4. **Review** `git diff` for intended model string changes only, then open a PR.

### Promote flags

```text
python scripts/promote_model_matrix.py              # apply pins + regen Grok/agy
python scripts/promote_model_matrix.py --check      # exit 1 on drift
python scripts/promote_model_matrix.py --print-version
python scripts/promote_model_matrix.py --skip-sync-check   # with --check
```

### Example: bump Grok high tier

```json
"tiers": {
  "high": {
    "grok": "grok-5",
    "agy": "Claude Opus 4.6 (Thinking)",
    "claude": "claude-opus-4-6",
    "gemini": "gemini-3.1-pro-preview"
  }
}
```

Then:

```bash
python scripts/promote_model_matrix.py
python scripts/promote_model_matrix.py --check
```

High-tier Grok roles (architecture, manager, …) pick up `grok-5`; Codex and
Claude pins are unchanged unless you edit those fields too.

## Relationship to surface sync

`scripts/sync_agent_surfaces.py` regenerates Grok and Antigravity agents from
`.codex/agents/*.agent.md` using **tier pins from the matrix** (role name →
tier → provider model). Heuristic token matching remains only as a fallback for
unknown Codex model strings.

Prefer:

```bash
python scripts/promote_model_matrix.py
```

over hand-editing generated trees. Use `sync_agent_surfaces.py` alone when you
changed role **bodies** but not models.

## Validation

Local:

```bash
python scripts/promote_model_matrix.py --check
python -m unittest discover -s scripts/tests -v
```

CI: `.github/workflows/model-matrix-check.yml` runs the check on pull requests
that touch agent surfaces or the matrix.

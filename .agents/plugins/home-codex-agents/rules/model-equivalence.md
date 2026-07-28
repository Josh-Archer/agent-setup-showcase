# Home agent model equivalence

Generated from `models/matrix.json` (matrix_version `2026.07.1`).

These mappings preserve role intent across local agent surfaces:

- High/extra-high Codex roles: Grok `grok-4.5`; Antigravity `Claude Opus 4.6 (Thinking)`.
- Medium Codex roles: Grok `grok-composer-2.5-fast`; Antigravity `Gemini 3.5 Flash (Medium)`.
- Spark/low-risk Codex roles: Grok `grok-composer-2.5-fast`; Antigravity `Gemini 3.5 Flash (Low)`.

Promote pins: edit `models/matrix.json`, then `python scripts/promote_model_matrix.py` (see `docs/model-matrix.md`).

# GitHub Copilot Instructions

## Core Repository Contract
- Follow the agent role architectures and workflows specified in [`AGENTS.md`](AGENTS.md).
- Keep changes concise, modular, and grounded in working code and verified tests.

## Anti-Slop & Quality Standards (`unslop`)
- Adhere to the `unslop` skill standards ([`.codex/skills/unslop/SKILL.md`](.codex/skills/unslop/SKILL.md)):
  - Eliminate robotic fluff, sycophantic greetings, and stock AI vocabulary (*delve*, *tapestry*, *testament*, *pivotal*, *streamline*, *harness*).
  - Avoid self-narrating comments that merely restate obvious syntax.
  - Write imperative conventional commit messages (`feat(mcp): ...`, `fix(agents): ...`).

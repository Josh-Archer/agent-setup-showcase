#!/usr/bin/env python3
"""Generate Grok and Antigravity agent definitions from the repo's Codex agents.

Provider model pins for Grok/Antigravity come from models/matrix.json (tiers +
roles). Heuristic fallbacks remain for unknown codex model strings.

Default sync is safe (no deletes). Pass --prune to remove generated surfaces
that no longer map to a Codex agent after rename/delete.
"""

from __future__ import annotations

import argparse
import filecmp
import json
import re
import shutil
import tempfile
from functools import lru_cache
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / ".codex" / "agents"
GROK_DIR = ROOT / ".grok" / "roles"
GROK_AGENT_DIR = ROOT / ".grok" / "agents"
AGY_PLUGIN_DIR = ROOT / ".agents" / "plugins" / "home-codex-agents"
AGY_AGENT_DIR = AGY_PLUGIN_DIR / "agents"
OMP_AGENT_DIR = ROOT / ".omp" / "agents"
MATRIX_PATH = ROOT / "models" / "matrix.json"


def frontmatter(text: str) -> tuple[dict[str, str], str]:
    match = re.match(r"\A---\n(.*?)\n---\n(.*)\Z", text, re.DOTALL)
    if not match:
        return {}, text
    values: dict[str, str] = {}
    for line in match.group(1).splitlines():
        key, sep, value = line.partition(":")
        if sep:
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values, match.group(2).lstrip()


def value(meta: dict[str, str], key: str, default: str = "") -> str:
    return meta.get(key, default)


@lru_cache(maxsize=4)
def load_matrix(path: str | None = None) -> dict[str, Any] | None:
    matrix_path = Path(path) if path else MATRIX_PATH
    if not matrix_path.is_file():
        return None
    return json.loads(matrix_path.read_text(encoding="utf-8"))


def clear_matrix_cache() -> None:
    load_matrix.cache_clear()


def role_tier_from_matrix(role: str, matrix: dict[str, Any] | None = None) -> str | None:
    matrix = matrix if matrix is not None else load_matrix()
    if not matrix:
        return None
    cfg = matrix.get("roles", {}).get(role)
    if not cfg:
        return None
    return str(cfg.get("tier") or "") or None


def tier_provider_model(
    tier: str,
    provider: str,
    matrix: dict[str, Any] | None = None,
) -> str | None:
    matrix = matrix if matrix is not None else load_matrix()
    if not matrix:
        return None
    models = matrix.get("tiers", {}).get(tier)
    if not models:
        return None
    pin = models.get(provider)
    return str(pin) if pin else None


def heuristic_tier(codex_model: str) -> str:
    """Legacy string-token tier inference when role is not in the matrix."""
    if "5.3-codex-spark" in codex_model or codex_model in {"gpt-5.6-luna", "gpt-5-mini"}:
        return "low"
    if any(token in codex_model for token in ("mini", "terra", "luna")):
        return "medium"
    return "high"


def resolve_provider_model(
    provider: str,
    *,
    role: str | None = None,
    codex_model: str = "",
    matrix: dict[str, Any] | None = None,
) -> str:
    matrix = matrix if matrix is not None else load_matrix()
    tier = role_tier_from_matrix(role, matrix) if role else None
    if not tier and codex_model:
        tier = heuristic_tier(codex_model)
    if tier:
        pin = tier_provider_model(tier, provider, matrix)
        if pin:
            return pin
    # Hardcoded last-resort defaults matching historical behavior.
    if provider == "grok":
        return "grok-composer-2.5-fast" if tier in {"medium", "low"} else "grok-4.5"
    if provider == "agy":
        if tier == "low":
            return "Gemini 3.5 Flash (Low)"
        if tier == "medium":
            return "Gemini 3.5 Flash (Medium)"
        return "Claude Opus 4.6 (Thinking)"
    if provider == "omp":
        pin = tier_provider_model(tier, "claude", matrix) if tier else None
        if pin:
            return pin
        return "claude-sonnet-4-6" if tier in {"medium", "low"} else "claude-opus-4-6"
    raise SystemExit(f"No model pin for provider={provider!r} role={role!r}")


def grok_model(codex_model: str, role: str | None = None) -> str:
    return resolve_provider_model("grok", role=role, codex_model=codex_model)


def agy_model(codex_model: str, role: str | None = None) -> str:
    return resolve_provider_model("agy", role=role, codex_model=codex_model)


def omp_models(
    codex_model: str,
    role: str | None = None,
    matrix: dict[str, Any] | None = None,
) -> list[str]:
    """
    Return ordered multi-model fallback chain for OMP subagents across providers:
    Claude pin -> Google Antigravity -> OpenAI Codex -> xAI Grok.
    """
    matrix = matrix if matrix is not None else load_matrix()
    tier = role_tier_from_matrix(role, matrix) if role else None
    if not tier:
        tier = heuristic_tier(codex_model)

    if role in {"builder", "development"}:
        return [
            "google-antigravity/gemini-3.8-flash:high",
            "xai-oauth/grok-4.6:high",
            "openai-codex/gpt-5.6-terra",
        ]
    if role == "junior":
        return [
            "google-antigravity/gemini-3.8-flash:medium",
            "xai-oauth/grok-4.6:medium",
            "openai-codex/gpt-5.6-luna",
        ]

    chain: list[str] = []

    # 1. Claude pin
    claude_pin = resolve_provider_model("omp", role=role, codex_model=codex_model, matrix=matrix)
    if claude_pin:
        chain.append(claude_pin)

    # 2. Google Antigravity pin
    if tier == "high":
        chain.append("google-antigravity/claude-opus-4-6")
    else:
        chain.append("google-antigravity/gemini-3.8-flash")

    # 3. OpenAI Codex pin
    codex_id = codex_model
    for suffix in ("-xhigh", "-high", "-medium", "-low"):
        if codex_id.endswith(suffix):
            codex_id = codex_id[: -len(suffix)]
            break
    chain.append(f"openai-codex/{codex_id}")

    # 4. xAI Grok pin
    grok_pin = resolve_provider_model("grok", role=role, codex_model=codex_model, matrix=matrix)
    if grok_pin:
        chain.append(f"xai-oauth/{grok_pin}")

    # Deduplicate preserving order
    dedup: list[str] = []
    for m in chain:
        if m and m not in dedup:
            dedup.append(m)
    return dedup


def omp_model(codex_model: str, role: str | None = None) -> str:
    return resolve_provider_model("omp", role=role, codex_model=codex_model)

def capability(tools: str) -> str:
    if "edit" in tools or "execute" in tools or "agent" in tools:
        return "all"
    return "read-only"


def agy_tools(tools: str) -> str:
    mapped: list[str] = ["read_file", "grep_search", "glob", "list_directory"]
    if "edit" in tools:
        mapped += ["write_file", "replace"]
    if "execute" in tools:
        mapped += ["run_shell_command"]
    if "todo" in tools:
        mapped += ["todo"]
    if "agent" in tools:
        mapped += ["invoke_subagent"]
    return "[" + ", ".join(mapped) + "]"


def omp_tools(tools: str) -> list[str]:
    mapped: list[str] = ["read", "grep", "glob", "bash", "lsp", "web_search"]
    if "edit" in tools:
        mapped += ["edit", "write"]
    if "todo" in tools:
        mapped += ["todo"]
    if "agent" in tools:
        mapped += ["task"]
    return mapped


def source_agent_names(root: Path) -> set[str]:
    """Canonical role names from `.codex/agents/*.agent.md`."""
    source_dir = root / ".codex" / "agents"
    if not source_dir.is_dir():
        return set()
    return {path.name.removesuffix(".agent.md") for path in source_dir.glob("*.agent.md")}


def expected_surface_files(root: Path, names: set[str] | None = None) -> set[Path]:
    """Absolute paths that sync should keep for the given role names."""
    if names is None:
        names = source_agent_names(root)
    paths: set[Path] = set()
    for name in names:
        paths.add(root / ".grok" / "roles" / f"{name}.toml")
        paths.add(root / ".grok" / "agents" / f"{name}.md")
        paths.add(root / ".agents" / "plugins" / "home-codex-agents" / "agents" / f"{name}.md")
        paths.add(root / ".omp" / "agents" / f"{name}.md")
    return paths


def find_orphan_surfaces(root: Path) -> list[Path]:
    """
    Return generated agent surface files that no longer map to a Codex agent.

    Only considers files with the shapes sync writes:
    - `.grok/roles/<role>.toml`
    - `.grok/agents/<role>.md`
    - `.agents/plugins/home-codex-agents/agents/<role>.md`
    - `.omp/agents/<role>.md`

    Non-matching files (e.g. plugin.json, rules/*) are left alone.
    """
    expected = expected_surface_files(root)
    orphans: list[Path] = []

    role_dir = root / ".grok" / "roles"
    if role_dir.is_dir():
        for path in sorted(role_dir.glob("*.toml")):
            if path not in expected:
                orphans.append(path)

    grok_agent_dir = root / ".grok" / "agents"
    if grok_agent_dir.is_dir():
        for path in sorted(grok_agent_dir.glob("*.md")):
            if path not in expected:
                orphans.append(path)

    agy_agent_dir = root / ".agents" / "plugins" / "home-codex-agents" / "agents"
    if agy_agent_dir.is_dir():
        for path in sorted(agy_agent_dir.glob("*.md")):
            if path not in expected:
                orphans.append(path)

    omp_agent_dir = root / ".omp" / "agents"
    if omp_agent_dir.is_dir():
        for path in sorted(omp_agent_dir.glob("*.md")):
            if path not in expected:
                orphans.append(path)

    return orphans


def prune_orphan_surfaces(orphans: list[Path], *, dry_run: bool = False) -> list[Path]:
    """Delete orphan surface files. Returns paths that were (or would be) removed."""
    removed: list[Path] = []
    for path in orphans:
        if dry_run:
            removed.append(path)
            continue
        if path.is_file() or path.is_symlink():
            path.unlink()
            removed.append(path)
    return removed


def _rel_to_root(path: Path, root: Path) -> str:
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except ValueError:
        return str(path)


def report_orphans(orphans: list[Path], root: Path, *, pruned: bool) -> None:
    if not orphans:
        return
    rel = [_rel_to_root(path, root) for path in orphans]
    if pruned:
        print(f"Pruned {len(orphans)} stale generated surface(s):")
        for item in rel:
            print(f"  - removed {item}")
        return
    print(f"WARNING: {len(orphans)} stale generated surface(s) left in place (safe mode).")
    print("These usually remain after renaming or deleting a Codex agent.")
    for item in rel:
        print(f"  - orphan: {item}")
    print("Re-run with --prune to delete them explicitly (destructive).")
    print("  python3 scripts/sync_agent_surfaces.py --prune")


def _equivalence_doc(matrix: dict[str, Any] | None) -> str:
    if matrix and matrix.get("tiers"):
        tiers = matrix["tiers"]
        version = matrix.get("matrix_version", "unknown")
        lines = [
            "# Home agent model equivalence\n",
            "\n",
            f"Generated from `models/matrix.json` (matrix_version `{version}`).\n",
            "\n",
            "These mappings preserve role intent across local agent surfaces:\n",
            "\n",
        ]
        for tier_name in ("high", "medium", "low"):
            tier = tiers.get(tier_name, {})
            if not tier:
                continue
            grok = tier.get("grok", "?")
            agy = tier.get("agy", "?")
            label = {
                "high": "High/extra-high Codex roles",
                "medium": "Medium Codex roles",
                "low": "Spark/low-risk Codex roles",
            }[tier_name]
            lines.append(f"- {label}: Grok `{grok}`; Antigravity `{agy}`.\n")
        lines.append(
            "\n"
            "Promote pins: edit `models/matrix.json`, then "
            "`python scripts/promote_model_matrix.py` "
            "(see `docs/model-matrix.md`).\n"
        )
        return "".join(lines)
    return (
        "# Home agent model equivalence\n\n"
        "These mappings preserve role intent across local agent surfaces:\n\n"
        "- High/extra-high Codex roles: Grok `grok-4.5`; Antigravity `Claude Opus 4.6 (Thinking)`.\n"
        "- Medium Codex roles: Grok `grok-composer-2.5-fast`; Antigravity `Gemini 3.5 Flash (Medium)`.\n"
        "- Spark/low-risk Codex roles: Grok `grok-composer-2.5-fast`; Antigravity `Gemini 3.5 Flash (Low)`.\n"
    )


def write_surfaces(root: Path, *, prune: bool = False) -> tuple[int, list[Path]]:
    """
    Write generated Grok and Antigravity surfaces under root.

    Returns (agent_count, orphans_after_write). When prune=True, orphans are deleted
    before returning (list is the set that was removed).
    """
    source_dir = root / ".codex" / "agents"
    grok_dir = root / ".grok" / "roles"
    grok_agent_dir = root / ".grok" / "agents"
    agy_plugin_dir = root / ".agents" / "plugins" / "home-codex-agents"
    agy_agent_dir = agy_plugin_dir / "agents"
    omp_agent_dir = root / ".omp" / "agents"
    matrix_path = root / "models" / "matrix.json"
    matrix = load_matrix(str(matrix_path)) if matrix_path.is_file() else load_matrix()

    grok_dir.mkdir(parents=True, exist_ok=True)
    grok_agent_dir.mkdir(parents=True, exist_ok=True)
    agy_agent_dir.mkdir(parents=True, exist_ok=True)
    omp_agent_dir.mkdir(parents=True, exist_ok=True)
    (agy_plugin_dir / "rules").mkdir(parents=True, exist_ok=True)

    agents = sorted(source_dir.glob("*.agent.md"))
    if not agents:
        raise SystemExit(f"No Codex agents found in {source_dir}")

    for source in agents:
        meta, body = frontmatter(source.read_text(encoding="utf-8"))
        name = source.name.removesuffix(".agent.md")
        description = value(meta, "description", name).replace('"', '\\"')
        model = value(meta, "model", "gpt-5.6-sol")
        reasoning = value(meta, "reasoning_effort", "medium")
        tools = value(meta, "tools", "")
        grok_pin = resolve_provider_model(
            "grok", role=name, codex_model=model, matrix=matrix
        )
        agy_pin = resolve_provider_model(
            "agy", role=name, codex_model=model, matrix=matrix
        )
        omp_pin = resolve_provider_model(
            "omp", role=name, codex_model=model, matrix=matrix
        )

        grok = (
            f'description = "{description}"\n'
            f'default_capability_mode = "{capability(tools)}"\n'
            f'model = "{grok_pin}"\n'
            f'reasoning_effort = "{("high" if reasoning == "extra high" else reasoning)}"\n'
            f'prompt_file = ".codex/agents/{source.name}"\n'
        )
        (grok_dir / f"{name}.toml").write_text(grok, encoding="utf-8")

        grok_agent = (
            "---\n"
            f"name: {name}\n"
            f"description: {description}\n"
            f"model: {grok_pin}\n"
            "prompt_mode: full\n"
            "permission_mode: default\n"
            "agents_md: true\n"
            "---\n"
            + body
        )
        (grok_agent_dir / f"{name}.md").write_text(grok_agent, encoding="utf-8")

        agy = (
            "---\n"
            f"name: {name}\n"
            f"description: {description}\n"
            f"model: {agy_pin}\n"
            f"tools: {agy_tools(tools)}\n"
            "---\n"
            + body
        )
        (agy_agent_dir / f"{name}.md").write_text(agy, encoding="utf-8")

        omp_models_list = omp_models(model, role=name, matrix=matrix)
        omp_models_yaml = "\n".join(f'  - "{m}"' for m in omp_models_list)
        omp_tools_yaml = "\n".join(f"  - {t}" for t in omp_tools(tools))
        omp_agent = (
            "---\n"
            f"name: {name}\n"
            f"description: {description}\n"
            f"model:\n"
            f"{omp_models_yaml}\n"
            f"tools:\n"
            f"{omp_tools_yaml}\n"
            "---\n\n"
            + body
        )
        (omp_agent_dir / f"{name}.md").write_text(omp_agent, encoding="utf-8")

    (agy_plugin_dir / "plugin.json").write_text(
        '{\n'
        '  "$schema": "https://antigravity.google/schemas/v1/plugin.json",\n'
        '  "name": "home-codex-agents",\n'
        '  "description": "Repository-specific agent roles synchronized from Codex."\n'
        '}\n',
        encoding="utf-8",
    )
    (agy_plugin_dir / "rules" / "model-equivalence.md").write_text(
        _equivalence_doc(matrix),
        encoding="utf-8",
    )
    (agy_plugin_dir / "rules" / "repo-agents.md").write_text(
        "# Repository agent constitution (Antigravity)\n\n"
        "Antigravity does not auto-load the repository root `AGENTS.md`. Use this rule "
        "together with the role body when working in this repo.\n\n"
        "## Source of truth\n\n"
        "- Canonical model pins: `models/matrix.json`\n"
        "- Canonical roles: `.codex/agents/*.agent.md`\n"
        "- Cross-provider contract: repository root `AGENTS.md`\n"
        "- Operational guide: `docs/grok-agy-delegation.md`\n"
        "- Promote model generation: `python scripts/promote_model_matrix.py` "
        "(see `docs/model-matrix.md`)\n"
        "- Regenerate Grok/agy surfaces: `python scripts/sync_agent_surfaces.py`\n"
        "- Drift check: `python scripts/promote_model_matrix.py --check` "
        "or `python scripts/sync_agent_surfaces.py --check`\n"
        "- Prune stale surfaces after rename/delete: "
        "`python3 scripts/sync_agent_surfaces.py --prune`\n\n"
        "## Delegation handoffs\n\n"
        "- Single-agent wrapper: `.codex/skills/grok-agy-delegate/scripts/delegate.py`\n"
        "- Plan orchestrator: `.codex/skills/grok-agy-delegate/scripts/orchestrate.py`\n"
        "- Multi-agent outputs: `.agent-runs/<run-id>/` (local, gitignored)\n"
        "- Dependents are not run when a prerequisite fails, times out, or is skipped\n\n"
        "## Safety\n\n"
        "- Do not put secrets into prompts or plan JSON\n"
        "- Prefer read-only roles for analysis-only work\n"
        "- Inspect `git diff` before treating delegated edits as accepted\n"
        "- Ensure Git commit GPG/SSH signing is enabled using the default global signing key "
        "(e.g. from Bitwarden/ssh-agent), and your SSH agent/Bitwarden vault is unlocked when "
        "tasks are running so commits can be signed successfully.\n"
        "- `--prune` deletes generated surface files that no longer map to a Codex agent; "
        "default sync never deletes without that flag.\n",
        encoding="utf-8",
    )

    orphans = find_orphan_surfaces(root)
    if prune and orphans:
        prune_orphan_surfaces(orphans)
    return len(agents), orphans


def _generated_trees(root: Path) -> list[Path]:
    return [
        root / ".grok" / "roles",
        root / ".grok" / "agents",
        root / ".agents" / "plugins" / "home-codex-agents",
        root / ".omp" / "agents",
    ]


def check_surfaces() -> int:
    """Regenerate into a temp tree and compare to committed generated surfaces."""
    with tempfile.TemporaryDirectory(prefix="agent-surface-check-") as tmp:
        tmp_root = Path(tmp)
        # Sync reads .codex/agents + models/matrix.json; copy both into the temp root.
        dest_source = tmp_root / ".codex" / "agents"
        dest_source.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(SOURCE_DIR, dest_source)
        if MATRIX_PATH.is_file():
            dest_matrix = tmp_root / "models" / "matrix.json"
            dest_matrix.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(MATRIX_PATH, dest_matrix)
        clear_matrix_cache()
        write_surfaces(tmp_root, prune=True)

        mismatches: list[str] = []
        for rel_root in _generated_trees(ROOT):
            tmp_tree = tmp_root / rel_root.relative_to(ROOT)
            if not rel_root.exists():
                mismatches.append(f"missing on disk: {rel_root.relative_to(ROOT)}")
                continue
            if not tmp_tree.exists():
                mismatches.append(f"missing in regenerated output: {rel_root.relative_to(ROOT)}")
                continue
            cmp = filecmp.dircmp(rel_root, tmp_tree)
            mismatches.extend(_collect_dircmp_diffs(cmp, rel_root.relative_to(ROOT)))

        if mismatches:
            print("Generated agent surfaces are out of sync with .codex/agents:")
            for item in mismatches:
                print(f"  - {item}")
            print("Run: python3 scripts/sync_agent_surfaces.py")
            print("If rename/delete left stale files: python3 scripts/sync_agent_surfaces.py --prune")
            return 1
        print("Generated agent surfaces match .codex/agents")
        return 0


def _collect_dircmp_diffs(cmp: filecmp.dircmp, prefix: Path) -> list[str]:
    found: list[str] = []
    for name in sorted(cmp.left_only):
        found.append(f"only on disk: {prefix / name}")
    for name in sorted(cmp.right_only):
        found.append(f"only in regenerated output: {prefix / name}")
    for name in sorted(cmp.diff_files):
        found.append(f"content differs: {prefix / name}")
    for name, sub in sorted(cmp.subdirs.items()):
        found.extend(_collect_dircmp_diffs(sub, prefix / name))
    return found


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit non-zero if generated Grok/Antigravity surfaces drift from .codex/agents",
    )
    parser.add_argument(
        "--prune",
        action="store_true",
        help=(
            "After regenerating surfaces, delete stale generated agent files that no longer "
            "map to a Codex agent (rename/delete orphans). Default is safe: report only, no deletes."
        ),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.check:
        if args.prune:
            print("error: --check is read-only; omit --prune (use plain --prune to delete orphans)")
            return 2
        return check_surfaces()

    count, orphans = write_surfaces(ROOT, prune=args.prune)
    print(f"Generated {count} Grok roles in {GROK_DIR}")
    print(f"Generated {count} Grok agents in {GROK_AGENT_DIR}")
    print(f"Generated {count} Antigravity agents in {AGY_PLUGIN_DIR}")
    print(f"Generated {count} OMP agents in {OMP_AGENT_DIR}")
    report_orphans(orphans, ROOT, pruned=args.prune)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

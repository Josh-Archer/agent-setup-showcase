#!/usr/bin/env python3
"""Generate Grok and Antigravity agent definitions from the repo's Codex agents."""

from __future__ import annotations

import argparse
import filecmp
import re
import shutil
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / ".codex" / "agents"
GROK_DIR = ROOT / ".grok" / "roles"
GROK_AGENT_DIR = ROOT / ".grok" / "agents"
AGY_PLUGIN_DIR = ROOT / ".agents" / "plugins" / "home-codex-agents"
AGY_AGENT_DIR = AGY_PLUGIN_DIR / "agents"


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


def grok_model(codex_model: str) -> str:
    if any(token in codex_model for token in ("5.3-codex-spark", "mini", "terra", "luna")):
        return "grok-composer-2.5-fast"
    return "grok-4.5"


def agy_model(codex_model: str) -> str:
    if "5.3-codex-spark" in codex_model or codex_model == "gpt-5.6-luna":
        return "Gemini 3.5 Flash (Low)"
    if any(token in codex_model for token in ("mini", "terra", "luna-high")):
        return "Gemini 3.5 Flash (Medium)"
    return "Claude Opus 4.6 (Thinking)"


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
    return paths


def find_orphan_surfaces(root: Path) -> list[Path]:
    """
    Return generated agent surface files that no longer map to a Codex agent.

    Only considers files with the shapes sync writes:
    - `.grok/roles/<role>.toml`
    - `.grok/agents/<role>.md`
    - `.agents/plugins/home-codex-agents/agents/<role>.md`

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

    grok_dir.mkdir(parents=True, exist_ok=True)
    grok_agent_dir.mkdir(parents=True, exist_ok=True)
    agy_agent_dir.mkdir(parents=True, exist_ok=True)
    (agy_plugin_dir / "rules").mkdir(parents=True, exist_ok=True)

    agents = sorted(source_dir.glob("*.agent.md"))
    if not agents:
        raise SystemExit(f"No Codex agents found in {source_dir}")

    for source in agents:
        meta, body = frontmatter(source.read_text())
        name = source.name.removesuffix(".agent.md")
        description = value(meta, "description", name).replace('"', '\\"')
        model = value(meta, "model", "gpt-5.6-sol")
        reasoning = value(meta, "reasoning_effort", "medium")
        tools = value(meta, "tools", "")

        grok = (
            f'description = "{description}"\n'
            f'default_capability_mode = "{capability(tools)}"\n'
            f'model = "{grok_model(model)}"\n'
            f'reasoning_effort = "{("high" if reasoning == "extra high" else reasoning)}"\n'
            f'prompt_file = ".codex/agents/{source.name}"\n'
        )
        (grok_dir / f"{name}.toml").write_text(grok)

        grok_agent = (
            "---\n"
            f"name: {name}\n"
            f"description: {description}\n"
            f"model: {grok_model(model)}\n"
            "prompt_mode: full\n"
            "permission_mode: default\n"
            "agents_md: true\n"
            "---\n"
            + body
        )
        (grok_agent_dir / f"{name}.md").write_text(grok_agent)

        agy = (
            "---\n"
            f"name: {name}\n"
            f"description: {description}\n"
            f"model: {agy_model(model)}\n"
            f"tools: {agy_tools(tools)}\n"
            "---\n"
            + body
        )
        (agy_agent_dir / f"{name}.md").write_text(agy)

    (agy_plugin_dir / "plugin.json").write_text(
        '{\n'
        '  "$schema": "https://antigravity.google/schemas/v1/plugin.json",\n'
        '  "name": "home-codex-agents",\n'
        '  "description": "Repository-specific agent roles synchronized from Codex."\n'
        '}\n'
    )
    (agy_plugin_dir / "rules" / "model-equivalence.md").write_text(
        "# Home agent model equivalence\n\n"
        "These mappings preserve role intent across local agent surfaces:\n\n"
        "- High/extra-high Codex roles: Grok `grok-4.5`; Antigravity `Claude Opus 4.6 (Thinking)`.\n"
        "- Medium Codex roles: Grok `grok-composer-2.5-fast`; Antigravity `Gemini 3.5 Flash (Medium)`.\n"
        "- Spark/low-risk Codex roles: Grok `grok-composer-2.5-fast`; Antigravity `Gemini 3.5 Flash (Low)`.\n"
    )
    (agy_plugin_dir / "rules" / "repo-agents.md").write_text(
        "# Repository agent constitution (Antigravity)\n\n"
        "Antigravity does not auto-load the repository root `AGENTS.md`. Use this rule "
        "together with the role body when working in this repo.\n\n"
        "## Source of truth\n\n"
        "- Canonical roles: `.codex/agents/*.agent.md`\n"
        "- Cross-provider contract: repository root `AGENTS.md`\n"
        "- Operational guide: `docs/grok-agy-delegation.md`\n"
        "- Regenerate Grok/agy surfaces: `python3 scripts/sync_agent_surfaces.py`\n"
        "- Drift check: `python3 scripts/sync_agent_surfaces.py --check`\n"
        "- Prune stale surfaces after rename/delete: `python3 scripts/sync_agent_surfaces.py --prune`\n\n"
        "## Delegation handoffs\n\n"
        "- Single-agent wrapper: `.codex/skills/grok-agy-delegate/scripts/delegate.py`\n"
        "- Plan orchestrator: `.codex/skills/grok-agy-delegate/scripts/orchestrate.py`\n"
        "- Multi-agent outputs: `.agent-runs/<run-id>/` (local, gitignored)\n"
        "- Dependents are not run when a prerequisite fails, times out, or is skipped\n\n"
        "## Safety\n\n"
        "- Do not put secrets into prompts or plan JSON\n"
        "- Prefer read-only roles for analysis-only work\n"
        "- Inspect `git diff` before treating delegated edits as accepted\n"
        "- Ensure Git commit GPG/SSH signing is enabled using the default global signing key (e.g. from Bitwarden/ssh-agent), and your SSH agent/Bitwarden vault is unlocked when tasks are running so commits can be signed successfully.\n"
        "- `--prune` deletes generated surface files that no longer map to a Codex agent; "
        "default sync never deletes without that flag.\n"
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
    ]


def check_surfaces() -> int:
    """Regenerate into a temp tree and compare to committed generated surfaces."""
    with tempfile.TemporaryDirectory(prefix="agent-surface-check-") as tmp:
        tmp_root = Path(tmp)
        # Sync reads only .codex/agents; copy that tree into the temp root.
        dest_source = tmp_root / ".codex" / "agents"
        dest_source.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(SOURCE_DIR, dest_source)
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
    report_orphans(orphans, ROOT, pruned=args.prune)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

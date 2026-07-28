#!/usr/bin/env python3
"""Promote or check the canonical versioned model matrix across agent surfaces.

Canonical source: models/matrix.json

Surfaces:
  - Codex  (.codex/agents/*.agent.md)
  - Claude (.claude/agents/*.md)
  - Gemini (.gemini/agents/*.md)
  - Grok + Antigravity (regenerated via scripts/sync_agent_surfaces.py)

Usage:
  python scripts/promote_model_matrix.py            # apply pins + regenerate
  python scripts/promote_model_matrix.py --check    # drift check (exit 1 on mismatch)
  python scripts/promote_model_matrix.py --print-version
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
MATRIX_PATH = ROOT / "models" / "matrix.json"
CODEX_DIR = ROOT / ".codex" / "agents"
CLAUDE_DIR = ROOT / ".claude" / "agents"
GEMINI_DIR = ROOT / ".gemini" / "agents"

# model: value  or  model: "value"
MODEL_LINE_RE = re.compile(
    r"^(?P<prefix>\s*model\s*:\s*)(?P<quote>[\"']?)(?P<value>.*?)(?P=quote)\s*$",
    re.MULTILINE,
)


def load_matrix(path: Path = MATRIX_PATH) -> dict[str, Any]:
    if not path.is_file():
        raise SystemExit(f"Model matrix not found: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if int(data.get("schema_version", 0)) != 1:
        raise SystemExit(f"Unsupported matrix schema_version: {data.get('schema_version')!r}")
    if "tiers" not in data or "roles" not in data:
        raise SystemExit("Matrix must define 'tiers' and 'roles'")
    return data


def tier_model(matrix: dict[str, Any], tier: str, provider: str) -> str:
    tiers = matrix["tiers"]
    if tier not in tiers:
        raise SystemExit(f"Unknown tier {tier!r} (known: {sorted(tiers)})")
    models = tiers[tier]
    if provider not in models:
        raise SystemExit(f"Tier {tier!r} missing provider pin for {provider!r}")
    return str(models[provider])


def role_tier(matrix: dict[str, Any], role: str) -> str:
    roles = matrix["roles"]
    if role not in roles:
        raise SystemExit(f"Unknown role {role!r}")
    return str(roles[role]["tier"])


def resolve_surface_model(
    matrix: dict[str, Any],
    surface: str,
    agent_name: str,
    *,
    tier: str | None = None,
) -> str:
    """Resolve pinned model for a Claude/Gemini agent file basename (no suffix)."""
    extras = matrix.get("extra_pins", {}).get(surface, {})
    if agent_name in extras:
        return str(extras[agent_name])
    if tier is None:
        raise SystemExit(
            f"No pin for {surface}/{agent_name}: not in extra_pins and no tier provided"
        )
    return tier_model(matrix, tier, surface)


def expected_pins(matrix: dict[str, Any]) -> list[tuple[str, Path, str]]:
    """Return list of (surface, path, expected_model) for all managed pins."""
    pins: list[tuple[str, Path, str]] = []
    roles: dict[str, Any] = matrix["roles"]

    for role, cfg in sorted(roles.items()):
        codex_model = str(cfg["codex"])
        tier = str(cfg["tier"])
        codex_path = CODEX_DIR / f"{role}.agent.md"
        pins.append(("codex", codex_path, codex_model))

        claude_name = cfg.get("claude")
        if claude_name:
            name = str(claude_name)
            model = resolve_surface_model(matrix, "claude", name, tier=tier)
            pins.append(("claude", CLAUDE_DIR / f"{name}.md", model))

        gemini_name = cfg.get("gemini")
        if gemini_name:
            name = str(gemini_name)
            model = resolve_surface_model(matrix, "gemini", name, tier=tier)
            pins.append(("gemini", GEMINI_DIR / f"{name}.md", model))

    # Surface-only extras (not already covered by a role mapping file name)
    covered: dict[str, set[str]] = {"claude": set(), "gemini": set()}
    for cfg in roles.values():
        if cfg.get("claude"):
            covered["claude"].add(str(cfg["claude"]))
        if cfg.get("gemini"):
            covered["gemini"].add(str(cfg["gemini"]))

    for surface, directory in (("claude", CLAUDE_DIR), ("gemini", GEMINI_DIR)):
        for name, model in sorted(matrix.get("extra_pins", {}).get(surface, {}).items()):
            if name in covered[surface]:
                continue
            pins.append((surface, directory / f"{name}.md", str(model)))

    return pins


def read_frontmatter_model(path: Path) -> str | None:
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8")
    match = MODEL_LINE_RE.search(text)
    if not match:
        return None
    return match.group("value").strip()


def set_frontmatter_model(path: Path, model: str, *, quote: bool) -> bool:
    """Update model line in place. Returns True if content changed."""
    if not path.is_file():
        raise SystemExit(f"Missing agent file: {path}")
    text = path.read_text(encoding="utf-8")
    match = MODEL_LINE_RE.search(text)
    if not match:
        raise SystemExit(f"No model: frontmatter line in {path}")

    if quote:
        replacement = f'{match.group("prefix")}"{model}"'
    else:
        # Preserve existing quote style when present; default unquoted for claude/gemini.
        existing_quote = match.group("quote")
        if existing_quote:
            replacement = f"{match.group('prefix')}{existing_quote}{model}{existing_quote}"
        else:
            replacement = f"{match.group('prefix')}{model}"

    new_text, count = MODEL_LINE_RE.subn(replacement, text, count=1)
    if count != 1:
        raise SystemExit(f"Failed to rewrite model line in {path}")
    if new_text == text:
        return False
    path.write_text(new_text, encoding="utf-8")
    return True


def check_matrix(matrix: dict[str, Any] | None = None, root: Path = ROOT) -> int:
    """Verify surface pins match the matrix. Returns process exit code."""
    matrix = matrix or load_matrix(root / "models" / "matrix.json")
    # Rebind dirs for testability when root is a temp tree.
    global CODEX_DIR, CLAUDE_DIR, GEMINI_DIR
    prev = (CODEX_DIR, CLAUDE_DIR, GEMINI_DIR)
    CODEX_DIR = root / ".codex" / "agents"
    CLAUDE_DIR = root / ".claude" / "agents"
    GEMINI_DIR = root / ".gemini" / "agents"
    try:
        pins = expected_pins(matrix)
        mismatches: list[str] = []
        for surface, path, expected in pins:
            rel = path.relative_to(root) if path.is_relative_to(root) else path
            actual = read_frontmatter_model(path)
            if actual is None:
                mismatches.append(f"{surface}: missing or unreadable model in {rel}")
            elif actual != expected:
                mismatches.append(
                    f"{surface}: {rel} has model={actual!r}, expected {expected!r}"
                )

        if mismatches:
            print("Model matrix drift detected:")
            for item in mismatches:
                print(f"  - {item}")
            print("Run: python scripts/promote_model_matrix.py")
            return 1

        print(
            f"Model matrix {matrix.get('matrix_version')} pins match "
            f"Codex/Claude/Gemini surfaces ({len(pins)} pins)"
        )
        return 0
    finally:
        CODEX_DIR, CLAUDE_DIR, GEMINI_DIR = prev


def check_surfaces_with_sync(root: Path = ROOT) -> int:
    """Run generated-surface drift check (Grok + Antigravity)."""
    import importlib.util

    sync_path = root / "scripts" / "sync_agent_surfaces.py"
    if not sync_path.is_file():
        print("skip: scripts/sync_agent_surfaces.py not found")
        return 0
    spec = importlib.util.spec_from_file_location("sync_agent_surfaces", sync_path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return int(mod.check_surfaces())


def promote(matrix: dict[str, Any] | None = None, root: Path = ROOT) -> int:
    """Apply matrix pins to Codex/Claude/Gemini and regenerate Grok/AGY."""
    matrix = matrix or load_matrix(root / "models" / "matrix.json")
    global CODEX_DIR, CLAUDE_DIR, GEMINI_DIR
    prev = (CODEX_DIR, CLAUDE_DIR, GEMINI_DIR)
    CODEX_DIR = root / ".codex" / "agents"
    CLAUDE_DIR = root / ".claude" / "agents"
    GEMINI_DIR = root / ".gemini" / "agents"
    try:
        changed = 0
        for surface, path, expected in expected_pins(matrix):
            quote = surface == "codex"
            if set_frontmatter_model(path, expected, quote=quote):
                rel = path.relative_to(root) if path.is_relative_to(root) else path
                print(f"updated {surface}: {rel} -> {expected}")
                changed += 1

        # Regenerate Grok + Antigravity from Codex + matrix tiers.
        import importlib.util

        sync_path = root / "scripts" / "sync_agent_surfaces.py"
        if sync_path.is_file():
            spec = importlib.util.spec_from_file_location("sync_agent_surfaces", sync_path)
            assert spec is not None and spec.loader is not None
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            # Prefer matrix-aware write when available.
            if hasattr(mod, "write_surfaces"):
                count = mod.write_surfaces(root)
                print(f"regenerated {count} Grok/Antigravity agents from matrix tiers")
        else:
            print("warning: sync_agent_surfaces.py missing; skipped Grok/AGY regen")

        print(
            f"Promoted matrix {matrix.get('matrix_version')}: "
            f"{changed} frontmatter pin(s) updated"
        )
        return 0
    finally:
        CODEX_DIR, CLAUDE_DIR, GEMINI_DIR = prev


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit non-zero if Codex/Claude/Gemini (and generated Grok/AGY) drift from the matrix",
    )
    parser.add_argument(
        "--print-version",
        action="store_true",
        help="Print matrix_version and exit",
    )
    parser.add_argument(
        "--matrix",
        type=Path,
        default=MATRIX_PATH,
        help="Path to matrix JSON (default: models/matrix.json)",
    )
    parser.add_argument(
        "--skip-sync-check",
        action="store_true",
        help="With --check, only verify Codex/Claude/Gemini pins (skip Grok/AGY regen compare)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    matrix = load_matrix(args.matrix)

    if args.print_version:
        print(matrix.get("matrix_version", "unknown"))
        return 0

    if args.check:
        # Point expected_pins at the matrix path's repo root when custom matrix is used.
        root = args.matrix.resolve().parents[1] if args.matrix != MATRIX_PATH else ROOT
        code = check_matrix(matrix, root=root)
        if code != 0:
            return code
        if not args.skip_sync_check and root == ROOT:
            sync_code = check_surfaces_with_sync(root)
            if sync_code != 0:
                return sync_code
        return 0

    root = args.matrix.resolve().parents[1] if args.matrix != MATRIX_PATH else ROOT
    return promote(matrix, root=root)


if __name__ == "__main__":
    raise SystemExit(main())

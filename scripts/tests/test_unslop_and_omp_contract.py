#!/usr/bin/env python3
"""Contract tests: unslop skill and OMP harness are fully integrated."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class UnslopSkillContractTests(unittest.TestCase):
    def test_unslop_skill_exists_in_all_harness_trees(self) -> None:
        skill_paths = [
            ROOT / ".codex" / "skills" / "unslop" / "SKILL.md",
            ROOT / ".claude" / "skills" / "unslop" / "SKILL.md",
            ROOT / ".gemini" / "skills" / "unslop" / "SKILL.md",
            ROOT / ".omp" / "skills" / "unslop" / "SKILL.md",
        ]
        for path in skill_paths:
            self.assertTrue(path.is_file(), f"Missing skill definition: {path}")
            content = path.read_text(encoding="utf-8")
            self.assertIn("name: unslop", content)
            self.assertIn("Core Anti-Slop Principles", content)
            self.assertIn("Slop Taxonomy", content)

    def test_instruction_files_reference_unslop(self) -> None:
        instruction_files = [
            ROOT / "AGENTS.md",
            ROOT / "CLAUDE.md",
            ROOT / "COPILOT.md",
            ROOT / ".github" / "copilot-instructions.md",
        ]
        for path in instruction_files:
            self.assertTrue(path.is_file(), f"Missing instruction file: {path}")
            content = path.read_text(encoding="utf-8")
            self.assertIn("unslop", content.lower(), f"{path} must reference unslop")


class OmpHarnessContractTests(unittest.TestCase):
    def test_omp_agents_generated_for_all_codex_roles(self) -> None:
        codex_roles = {
            p.name.removesuffix(".agent.md")
            for p in (ROOT / ".codex" / "agents").glob("*.agent.md")
        }
        omp_agents = {
            p.name.removesuffix(".md")
            for p in (ROOT / ".omp" / "agents").glob("*.md")
        }
        self.assertEqual(codex_roles, omp_agents)

    def test_omp_agents_have_valid_frontmatter_and_tools(self) -> None:
        for path in (ROOT / ".omp" / "agents").glob("*.md"):
            content = path.read_text(encoding="utf-8")
            self.assertTrue(content.startswith("---\n"), f"{path} must have YAML frontmatter")
            self.assertIn("tools:", content)
            self.assertIn("model:", content)


if __name__ == "__main__":
    unittest.main()

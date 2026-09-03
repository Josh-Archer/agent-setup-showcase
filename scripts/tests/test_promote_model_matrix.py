#!/usr/bin/env python3
"""Unit tests for the versioned model matrix promote/check workflow."""

from __future__ import annotations

import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROMOTE_PATH = ROOT / "scripts" / "promote_model_matrix.py"
SYNC_PATH = ROOT / "scripts" / "sync_agent_surfaces.py"
MATRIX_PATH = ROOT / "models" / "matrix.json"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MatrixFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.promote = load_module("promote_under_test", PROMOTE_PATH)
        cls.sync = load_module("sync_under_test_for_promote", SYNC_PATH)
        cls.matrix = json.loads(MATRIX_PATH.read_text(encoding="utf-8"))

    def test_matrix_schema_and_version(self) -> None:
        self.assertEqual(self.matrix["schema_version"], 1)
        self.assertTrue(self.matrix.get("matrix_version"))
        self.assertIn("high", self.matrix["tiers"])
        self.assertIn("medium", self.matrix["tiers"])
        self.assertIn("low", self.matrix["tiers"])
        self.assertIn("architect", self.matrix["roles"])
        self.assertEqual(self.matrix["roles"]["architect"]["tier"], "high")

    def test_expected_pins_cover_codex_roles(self) -> None:
        pins = self.promote.expected_pins(self.matrix)
        codex = {path.name: model for surface, path, model in pins if surface == "codex"}
        for role, cfg in self.matrix["roles"].items():
            self.assertIn(f"{role}.agent.md", codex)
            self.assertEqual(codex[f"{role}.agent.md"], cfg["codex"])

    def test_check_clean_on_repo(self) -> None:
        code = self.promote.check_matrix(self.matrix, root=ROOT)
        self.assertEqual(code, 0)

    def test_promote_is_idempotent_on_repo(self) -> None:
        code = self.promote.promote(self.matrix, root=ROOT)
        self.assertEqual(code, 0)
        code = self.promote.check_matrix(self.matrix, root=ROOT)
        self.assertEqual(code, 0)
        # Generated surfaces stay aligned after promote.
        self.sync.clear_matrix_cache()
        self.assertEqual(self.sync.check_surfaces(), 0)

    def test_check_detects_codex_drift(self) -> None:
        with tempfile.TemporaryDirectory(prefix="matrix-check-") as tmp:
            root = Path(tmp)
            # Minimal tree: one codex agent + matrix.
            (root / "models").mkdir(parents=True)
            (root / ".codex" / "agents").mkdir(parents=True)
            shutil.copy2(MATRIX_PATH, root / "models" / "matrix.json")
            agent = root / ".codex" / "agents" / "architecture.agent.md"
            agent.write_text(
                '---\ndescription: "x"\nmodel: "WRONG-MODEL"\ntools: [read]\n---\nbody\n',
                encoding="utf-8",
            )
            # Only check the architecture codex pin by using a stripped matrix.
            matrix = {
                "schema_version": 1,
                "matrix_version": "test",
                "tiers": self.matrix["tiers"],
                "roles": {
                    "architecture": {
                        "codex": "gpt-5.6-sol-xhigh",
                        "tier": "high",
                    }
                },
                "extra_pins": {},
            }
            code = self.promote.check_matrix(matrix, root=root)
            self.assertEqual(code, 1)

    def test_promote_rewrites_frontmatter(self) -> None:
        with tempfile.TemporaryDirectory(prefix="matrix-promote-") as tmp:
            root = Path(tmp)
            (root / "models").mkdir(parents=True)
            (root / ".codex" / "agents").mkdir(parents=True)
            (root / ".claude" / "agents").mkdir(parents=True)
            (root / ".gemini" / "agents").mkdir(parents=True)
            (root / "scripts").mkdir(parents=True)

            matrix = {
                "schema_version": 1,
                "matrix_version": "test-promote",
                "tiers": {
                    "high": {
                        "grok": "grok-4.5",
                        "agy": "Claude Opus 4.6 (Thinking)",
                        "claude": "claude-opus-4-6",
                        "gemini": "gemini-3.1-pro-preview",
                    }
                },
                "roles": {
                    "architecture": {
                        "codex": "gpt-5.6-sol-xhigh",
                        "tier": "high",
                        "claude": "architecture",
                        "gemini": "architect",
                    }
                },
                "extra_pins": {
                    "claude": {"planner": "claude-4.5-opus"},
                    "gemini": {"auditor": "gemini-3.1-pro-preview"},
                },
            }
            (root / "models" / "matrix.json").write_text(
                json.dumps(matrix, indent=2) + "\n", encoding="utf-8"
            )
            (root / ".codex" / "agents" / "architecture.agent.md").write_text(
                '---\ndescription: "x"\nmodel: "old-codex"\ntools: [read]\n---\nbody\n',
                encoding="utf-8",
            )
            (root / ".claude" / "agents" / "architecture.md").write_text(
                "---\nname: architecture\nmodel: old-claude\n---\nbody\n",
                encoding="utf-8",
            )
            (root / ".claude" / "agents" / "planner.md").write_text(
                "---\nname: planner\nmodel: old-planner\n---\nbody\n",
                encoding="utf-8",
            )
            (root / ".gemini" / "agents" / "architect.md").write_text(
                "---\nname: architect\nmodel: old-gemini\n---\nbody\n",
                encoding="utf-8",
            )
            (root / ".gemini" / "agents" / "auditor.md").write_text(
                "---\nname: auditor\nmodel: old-auditor\n---\nbody\n",
                encoding="utf-8",
            )

            code = self.promote.promote(matrix, root=root)
            self.assertEqual(code, 0)
            self.assertEqual(
                self.promote.read_frontmatter_model(
                    root / ".codex" / "agents" / "architecture.agent.md"
                ),
                "gpt-5.6-sol-xhigh",
            )
            self.assertEqual(
                self.promote.read_frontmatter_model(
                    root / ".claude" / "agents" / "architecture.md"
                ),
                "claude-opus-4-6",
            )
            self.assertEqual(
                self.promote.read_frontmatter_model(
                    root / ".claude" / "agents" / "planner.md"
                ),
                "claude-4.5-opus",
            )
            self.assertEqual(
                self.promote.read_frontmatter_model(
                    root / ".gemini" / "agents" / "architect.md"
                ),
                "gemini-3.1-pro-preview",
            )
            self.assertEqual(
                self.promote.read_frontmatter_model(
                    root / ".gemini" / "agents" / "auditor.md"
                ),
                "gemini-3.1-pro-preview",
            )
            self.assertEqual(self.promote.check_matrix(matrix, root=root), 0)

    def test_cli_print_version(self) -> None:
        code = self.promote.main(["--print-version"])
        self.assertEqual(code, 0)

    def test_cli_check(self) -> None:
        code = self.promote.main(["--check", "--skip-sync-check"])
        self.assertEqual(code, 0)

    def test_sync_uses_matrix_tiers_for_roles(self) -> None:
        self.sync.clear_matrix_cache()
        self.assertEqual(
            self.sync.grok_model("ignored", role="architect"),
            self.matrix["tiers"]["high"]["grok"],
        )
        self.assertEqual(
            self.sync.agy_model("ignored", role="validation-runner"),
            self.matrix["tiers"]["low"]["agy"],
        )
        self.assertEqual(
            self.sync.agy_model("ignored", role="builder"),
            self.matrix["tiers"]["medium"]["agy"],
        )


if __name__ == "__main__":
    unittest.main()

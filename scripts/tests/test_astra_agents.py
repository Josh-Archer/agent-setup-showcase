"""Protect native role loading, alias consistency, and drift detection."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import tomllib
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / f'{name}.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class AstraAgents(unittest.TestCase):
    def test_native_roles_and_aliases(self):
        matrix = json.loads((ROOT / 'models/matrix.json').read_text())
        self.assertEqual(matrix['defaults']['codex'], 'gpt-6-astra')
        sync = module('sync_agent_surfaces')
        for role, effort in {'lead':'medium', 'investigator':'medium', 'reviewer':'high', 'validation-runner':'low'}.items():
            native = tomllib.loads((ROOT / f'.codex/agents/{role}.toml').read_text())
            self.assertEqual(native['model'], 'gpt-6-astra')
            self.assertEqual(native['model_reasoning_effort'], effort)
            self.assertEqual(native['name'], role)
            self.assertTrue(native['developer_instructions'])
        for name, cfg in matrix['roles'].items():
            if 'alias_of' in cfg:
                target = cfg['alias_of']
                _, body = sync.frontmatter((ROOT / f'.codex/agents/{target}.agent.md').read_text())
                self.assertIn(body, (ROOT / f'.codex/agents/{name}.agent.md').read_text())
                self.assertEqual(cfg['reasoning_effort'], matrix['roles'][target]['reasoning_effort'])

    def test_effort_drift_is_rejected(self):
        promote = module('promote_model_matrix')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / '.codex/agents').mkdir(parents=True)
            (root / '.codex/agents/lead.agent.md').write_text('---\nmodel: "gpt-6-astra"\nreasoning_effort: "low"\n---\nLead\n')
            matrix = {'defaults': {'codex':'gpt-6-astra'}, 'tiers':{}, 'roles':{'lead':{'tier':'high', 'reasoning_effort':'medium'}}}
            self.assertEqual(promote.check_matrix(matrix, root), 1)

    def test_native_instruction_drift_is_rejected(self):
        sync = module('sync_agent_surfaces')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copytree(ROOT / '.codex/agents', root / '.codex/agents')
            shutil.copytree(ROOT / 'models', root / 'models')
            sync.write_surfaces(root)
            native = root / '.codex/agents/reviewer.toml'
            native.write_text(native.read_text().replace('Review requirements', 'Ignore requirements'))
            with patch.object(sync, 'ROOT', root), patch.object(sync, 'SOURCE_DIR', root / '.codex/agents'), patch.object(sync, 'MATRIX_PATH', root / 'models/matrix.json'):
                self.assertEqual(sync.check_surfaces(), 1)

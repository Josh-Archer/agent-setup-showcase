"""Guard against re-exporting executable homelab automation into agent-setup."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
OWNED_WORKFLOWS = {'agent-surface-drift.yml', 'model-matrix-check.yml'}


class CiOwnershipTests(unittest.TestCase):
    def test_only_owned_workflows_are_active(self):
        active = ROOT / '.github/workflows'
        workflows = {p.name for p in active.iterdir() if p.suffix in {'.yml', '.yaml'}}
        self.assertEqual(workflows, OWNED_WORKFLOWS,
                         'Review CI ownership before adding a workflow; keep homelab snapshots inactive.')
        for name in workflows:
            text = (active / name).read_text()
            self.assertNotIn('home-gh-runner', text)
            self.assertNotRegex(text, r'uses:\s*\./\.github/')
            self.assertIn('runs-on: ubuntu-latest', text)
            self.assertIn('scripts/promote_model_matrix.py --check', text)
            self.assertIn('unittest discover -s scripts/tests', text)

    def test_archived_snapshots_are_documented_outside_discovery(self):
        archive = ROOT / '.github/archived-homelab-workflows'
        self.assertTrue((archive / 'README.md').is_file())
        self.assertTrue((archive / 'deploy.yml').is_file())
        self.assertTrue((archive / 'uecb-broker-smoke.yml').is_file())

#!/usr/bin/env python3
"""Unit tests for MCP secret load precedence and stale-cache fail-loud behavior."""

from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "scripts" / "homelab_mcp_secret_load.py"


def load_module():
    name = "homelab_mcp_secret_load"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # dataclasses requires the module to be present in sys.modules during exec
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class SecretLoadPrecedenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.mod = load_module()

    def test_process_env_wins_over_user_cache_and_kubectl(self) -> None:
        result = self.mod.resolve_api_key(
            process_value="process-key-xxxxxxxx",
            user_value="user-key-xxxxxxxxxxxx",
            cache_value="cache-key-xxxxxxxxxxx",
            kubectl_value="kubectl-key-xxxxxxxx",
            kubectl_available=True,
        )
        self.assertTrue(result.ok)
        self.assertEqual(result.source, "process")
        self.assertEqual(result.key, "process-key-xxxxxxxx")
        self.assertFalse(result.refreshed_cache)

    def test_user_env_wins_over_cache_and_kubectl(self) -> None:
        result = self.mod.resolve_api_key(
            process_value=None,
            user_value="user-key-xxxxxxxxxxxx",
            cache_value="cache-key-xxxxxxxxxxx",
            kubectl_value="kubectl-key-xxxxxxxx",
            kubectl_available=True,
        )
        self.assertEqual(result.source, "user")
        self.assertEqual(result.key, "user-key-xxxxxxxxxxxx")

    def test_kubectl_wins_over_stale_cache(self) -> None:
        """Regression for #14: live cluster secret must not be shadowed by cache."""
        result = self.mod.resolve_api_key(
            process_value="",
            user_value="",
            cache_value="dead-stale-cache-key",
            kubectl_value="live-cluster-key-xx",
            kubectl_available=True,
        )
        self.assertEqual(result.source, "kubectl")
        self.assertEqual(result.key, "live-cluster-key-xx")
        self.assertTrue(result.refreshed_cache)
        self.assertTrue(
            any("refreshing cache" in w or "differed" in w for w in result.warnings)
        )

    def test_cache_not_preferred_even_if_order_puts_cache_first(self) -> None:
        result = self.mod.resolve_api_key(
            cache_value="dead-stale-cache-key",
            kubectl_value="live-cluster-key-xx",
            kubectl_available=True,
            source_order=("cache", "kubectl", "process", "user"),
        )
        self.assertEqual(result.source, "kubectl")
        self.assertTrue(
            any("kubectl before cache" in w for w in result.warnings)
        )

    def test_cache_offline_fallback_when_kubectl_unavailable(self) -> None:
        result = self.mod.resolve_api_key(
            cache_value="offline-cache-key-xx",
            kubectl_value="should-be-ignored-xx",
            kubectl_available=False,
        )
        self.assertEqual(result.source, "cache")
        self.assertEqual(result.key, "offline-cache-key-xx")
        self.assertTrue(any("kubectl unavailable" in w for w in result.warnings))

    def test_cache_with_kubectl_empty_warns_stale_risk(self) -> None:
        result = self.mod.resolve_api_key(
            cache_value="maybe-stale-cache-key",
            kubectl_value=None,
            kubectl_available=True,
        )
        self.assertEqual(result.source, "cache")
        self.assertTrue(any("may be stale" in w for w in result.warnings))

    def test_missing_key_fail_loud(self) -> None:
        result = self.mod.resolve_api_key(
            process_value="short",
            cache_value="",
            kubectl_available=False,
        )
        self.assertFalse(result.ok)
        self.assertIsNone(result.key)
        self.assertTrue(any("no usable API key" in w for w in result.warnings))

    def test_whitespace_and_newlines_stripped(self) -> None:
        result = self.mod.resolve_api_key(
            cache_value="  cache-key-xxxxxxxxxxx\r\n",
            kubectl_available=False,
        )
        self.assertEqual(result.key, "cache-key-xxxxxxxxxxx")


class StaleCacheProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.mod = load_module()

    def test_probe_rejects_dead_process_then_uses_kubectl(self) -> None:
        def probe(key: str) -> bool:
            return key.startswith("live-")

        result = self.mod.resolve_api_key(
            process_value="dead-process-key-xx",
            cache_value="dead-stale-cache-key",
            kubectl_value="live-cluster-key-xx",
            kubectl_available=True,
            probe=probe,
        )
        self.assertEqual(result.source, "kubectl")
        self.assertEqual(result.key, "live-cluster-key-xx")
        self.assertIn("process", result.rejected_sources)
        # Cache is never tried once kubectl succeeds (kubectl ranks above cache).
        self.assertNotIn("cache", result.rejected_sources)
        self.assertTrue(any("rejected by probe" in w for w in result.warnings))

    def test_stale_cache_never_selected_when_kubectl_live(self) -> None:
        """Even with cache-first order and a dead-only probe filter, live kubectl wins."""
        def probe(key: str) -> bool:
            return key.startswith("live-")

        result = self.mod.resolve_api_key(
            cache_value="dead-stale-cache-key",
            kubectl_value="live-cluster-key-xx",
            kubectl_available=True,
            source_order=("cache", "kubectl"),
            probe=probe,
        )
        self.assertEqual(result.source, "kubectl")
        self.assertEqual(result.key, "live-cluster-key-xx")

    def test_probe_rejects_all_sources_fail_loud(self) -> None:
        result = self.mod.resolve_api_key(
            process_value="process-key-xxxxxxxx",
            cache_value="cache-key-xxxxxxxxxxx",
            kubectl_value="kubectl-key-xxxxxxxx",
            kubectl_available=True,
            probe=lambda _k: False,
        )
        self.assertFalse(result.ok)
        # user source has no value, so only process/kubectl/cache are attempted
        self.assertEqual(
            set(result.rejected_sources),
            {"process", "kubectl", "cache"},
        )
        self.assertTrue(any("no usable API key" in w for w in result.warnings))

    def test_probe_exception_is_fail_loud_skip(self) -> None:
        def boom(_key: str) -> bool:
            raise RuntimeError("network down")

        result = self.mod.resolve_api_key(
            process_value="process-key-xxxxxxxx",
            kubectl_value="kubectl-key-xxxxxxxx",
            kubectl_available=True,
            probe=boom,
        )
        # Both process and kubectl probes raise → no key
        self.assertFalse(result.ok)
        self.assertTrue(any("probe error" in w for w in result.warnings))

    def test_lightweight_bearer_probe_accepts_2xx(self) -> None:
        class FakeResp:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def getcode(self):
                return 200

        opener = mock.Mock(return_value=FakeResp())
        self.assertTrue(
            self.mod.lightweight_bearer_probe(
                "good-key-xxxxxxxxxxxx",
                "http://example.test/docs",
                opener=opener,
            )
        )
        opener.assert_called_once()

    def test_lightweight_bearer_probe_rejects_errors(self) -> None:
        import urllib.error

        def opener(_req, timeout=2.0):
            raise urllib.error.HTTPError(
                "http://example.test/docs", 401, "nope", hdrs=None, fp=io.BytesIO()
            )

        self.assertFalse(
            self.mod.lightweight_bearer_probe(
                "dead-key-xxxxxxxxxxxx",
                "http://example.test/docs",
                opener=opener,
            )
        )


class CliHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.mod = load_module()

    def test_main_reports_source_without_printing_secret(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp) / "mcp-api-key"
            secret = "super-secret-value-zz"
            cache.write_text(secret, encoding="utf-8")
            buf = io.StringIO()
            with mock.patch.dict("os.environ", {}, clear=False):
                # Ensure process env does not leak a real key into the test.
                env = {
                    "HOMELAB_MCP_API_KEY": "",
                    "PATH": str(Path.cwd()),
                }
                with mock.patch.dict("os.environ", env, clear=False):
                    with mock.patch("sys.stdout", buf):
                        # Clear any inherited process key for the name under test
                        import os

                        os.environ.pop("HOMELAB_MCP_API_KEY", None)
                        rc = self.mod.main(
                            [
                                "--name",
                                "HOMELAB_MCP_API_KEY",
                                "--cache-file",
                                str(cache),
                            ]
                        )
            out = buf.getvalue()
            self.assertEqual(rc, 0)
            self.assertIn("source=cache", out)
            self.assertNotIn(secret, out)


if __name__ == "__main__":
    unittest.main()

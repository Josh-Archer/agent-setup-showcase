#!/usr/bin/env python3
"""Homelab MCP secret resolution policy (shared, testable).

Precedence (highest → lowest), documented for shell loaders and installers:

1. process environment (already exported in this shell)
2. user environment (Windows User scope; optional on Unix)
3. live kubectl secret (cluster source of truth; refreshes cache)
4. local cache file (offline fallback only)

Fail-loud rules:
- Prefer kubectl over a silent stale cache whenever kubectl can return a key.
- If a probe is provided and rejects a candidate, skip that source and try the next.
- If every source is empty or rejected, return no key with a loud warning.

Optional probe:
- Callers may pass ``probe(key) -> bool`` (e.g. lightweight HTTP 200 check).
- Shell loaders enable this when HOMELAB_MCP_KEY_PROBE=1.

This module does not print or return secret values to logs beyond source labels.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Iterable, List, Optional, Sequence, Tuple

# Sources in default precedence order (kubectl before cache).
DEFAULT_SOURCE_ORDER: Tuple[str, ...] = ("process", "user", "kubectl", "cache")

MIN_KEY_LENGTH = 8

ProbeFn = Callable[[str], bool]


@dataclass
class ResolveResult:
    """Outcome of resolving one env var name from multiple sources."""

    key: Optional[str]
    source: Optional[str]
    warnings: List[str] = field(default_factory=list)
    refreshed_cache: bool = False
    rejected_sources: List[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return bool(self.key) and len(self.key) >= MIN_KEY_LENGTH


def _normalize(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    cleaned = value.strip().replace("\r", "").replace("\n", "")
    if not cleaned or len(cleaned) < MIN_KEY_LENGTH:
        return None
    return cleaned


def resolve_api_key(
    *,
    process_value: Optional[str] = None,
    user_value: Optional[str] = None,
    cache_value: Optional[str] = None,
    kubectl_value: Optional[str] = None,
    kubectl_available: bool = False,
    probe: Optional[ProbeFn] = None,
    source_order: Sequence[str] = DEFAULT_SOURCE_ORDER,
    cache_warn: bool = True,
) -> ResolveResult:
    """Resolve one API key according to documented precedence.

    ``kubectl_available`` should be True when the kubectl binary is present.
    When True and kubectl returns a key, that key wins over cache even if a
    stale cache file also exists. When kubectl is unavailable or returns empty,
    cache is used as an offline fallback (with a warning).
    """
    warnings: List[str] = []
    rejected: List[str] = []

    values = {
        "process": _normalize(process_value),
        "user": _normalize(user_value),
        "kubectl": _normalize(kubectl_value) if kubectl_available else None,
        "cache": _normalize(cache_value),
    }

    # Explicit: if kubectl is available, never let cache shadow a live secret
    # even if a custom source_order puts cache first.
    effective_order = list(source_order)
    if kubectl_available and "kubectl" in effective_order and "cache" in effective_order:
        k_idx = effective_order.index("kubectl")
        c_idx = effective_order.index("cache")
        if c_idx < k_idx:
            effective_order[c_idx], effective_order[k_idx] = (
                effective_order[k_idx],
                effective_order[c_idx],
            )
            warnings.append(
                "adjusted source order: kubectl before cache (refuse silent stale cache)"
            )

    for source in effective_order:
        if source not in values:
            continue
        # Skip kubectl source entirely when binary is missing.
        if source == "kubectl" and not kubectl_available:
            continue
        candidate = values.get(source)
        if not candidate:
            continue

        if probe is not None:
            try:
                ok = bool(probe(candidate))
            except Exception as exc:  # noqa: BLE001 - probe failures are fail-loud
                ok = False
                warnings.append(f"{source}: probe error ({exc.__class__.__name__}); skipping")
            if not ok:
                rejected.append(source)
                warnings.append(
                    f"{source}: key rejected by probe; trying next source (fail-loud)"
                )
                continue

        refreshed = False
        if source == "kubectl":
            # Caller should write cache; we signal intent.
            refreshed = True
            if values.get("cache") and values["cache"] != candidate:
                warnings.append(
                    "cache differed from live kubectl secret; refreshing cache from cluster"
                )
        elif source == "cache" and cache_warn:
            if kubectl_available:
                warnings.append(
                    "using cache while kubectl is available but returned no key; "
                    "cache may be stale"
                )
            else:
                warnings.append(
                    "using local cache file (kubectl unavailable); key not revalidated"
                )

        return ResolveResult(
            key=candidate,
            source=source,
            warnings=warnings,
            refreshed_cache=refreshed,
            rejected_sources=rejected,
        )

    warnings.append(
        "no usable API key from process/user/kubectl/cache; MCP auth will fail until set"
    )
    return ResolveResult(
        key=None,
        source=None,
        warnings=warnings,
        refreshed_cache=False,
        rejected_sources=rejected,
    )


def format_warnings(name: str, result: ResolveResult) -> Iterable[str]:
    """Human-readable warning lines (never include the secret value)."""
    for w in result.warnings:
        yield f"[homelab-mcp] {name}: {w}"
    if result.ok and result.source:
        yield f"[homelab-mcp] {name}: loaded from {result.source}"


def lightweight_bearer_probe(
    key: str,
    url: str,
    *,
    timeout_sec: float = 2.0,
    opener=None,
) -> bool:
    """GET ``url`` with Authorization: Bearer <key>; succeed on HTTP 2xx.

    Uses urllib by default so tests can inject a fake opener. Returns False on
    any network/HTTP failure (fail-loud for that candidate).
    """
    import urllib.error
    import urllib.request

    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {key}", "User-Agent": "homelab-mcp-secret-load/1"},
        method="GET",
    )
    open_fn = opener or urllib.request.urlopen
    try:
        with open_fn(req, timeout=timeout_sec) as resp:
            code = getattr(resp, "status", None) or resp.getcode()
            return 200 <= int(code) < 300
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError, ValueError):
        return False


def main(argv: Optional[Sequence[str]] = None) -> int:
    """CLI helper for docs/debug: print resolution source only (never the key)."""
    import argparse
    import os

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--name",
        default="HOMELAB_MCP_API_KEY",
        help="Env var name to resolve (default HOMELAB_MCP_API_KEY)",
    )
    parser.add_argument(
        "--cache-file",
        default="",
        help="Optional cache file path",
    )
    parser.add_argument(
        "--kubectl-available",
        action="store_true",
        help="Pretend kubectl is available (still needs --kubectl-value for tests)",
    )
    parser.add_argument(
        "--kubectl-value",
        default="",
        help="Injected kubectl secret value (for dry-run / tests)",
    )
    parser.add_argument(
        "--probe-url",
        default="",
        help="If set, probe the selected candidate against this URL",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    process_value = os.environ.get(args.name)
    user_value = None  # User-scope is OS-specific; shell loaders handle it.
    cache_value = None
    if args.cache_file:
        try:
            with open(args.cache_file, encoding="utf-8") as fh:
                cache_value = fh.read()
        except OSError:
            cache_value = None

    probe = None
    if args.probe_url:
        probe = lambda k: lightweight_bearer_probe(k, args.probe_url)  # noqa: E731

    result = resolve_api_key(
        process_value=process_value,
        user_value=user_value,
        cache_value=cache_value,
        kubectl_value=args.kubectl_value or None,
        kubectl_available=bool(args.kubectl_available or args.kubectl_value),
        probe=probe,
    )
    for line in format_warnings(args.name, result):
        print(line)
    if not result.ok:
        return 1
    print(f"[homelab-mcp] {args.name}: ok source={result.source}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

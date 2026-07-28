# shellcheck shell=bash
# Homelab MCP env bootstrap (safe for .zshrc / .bashrc).
# - Never prints secret values
# - Never embeds secrets in this file
# - Loads HOMELAB_MCP_API_KEY (mcpo Bearer) and PAPERLESS_API_KEY (stdio MCP token)
#
# Sourced by: scripts/setup_agents.sh → appends:
#   source "$HOME/.config/homelab/homelab-mcp.env.sh"
#
# Secret load precedence (highest → lowest) — see scripts/homelab_mcp_secret_load.py
# and mcp/README.md:
#   1. process environment (already exported)
#   2. live kubectl secret (cluster source of truth; refreshes cache)
#   3. local cache file (offline fallback only; may warn)
#
# Fail-loud: missing keys and rejected probes print warnings to stderr.
# Optional probe: HOMELAB_MCP_KEY_PROBE=1 and HOMELAB_MCP_KEY_PROBE_URL
# (default http://paperless-mcp.archer.casa/docs) run a lightweight Bearer GET.

_homelab_mcp_warn() {
  # stderr only; never include secret material
  printf '%s\n' "[homelab-mcp] $*" >&2
}

_homelab_mcp_probe_ok() {
  # $1 = key value. Returns 0 if probe disabled or HTTP 2xx.
  local key="$1"
  case "${HOMELAB_MCP_KEY_PROBE:-0}" in
    1|true|TRUE|yes|YES) ;;
    *) return 0 ;;
  esac
  if ! command -v curl >/dev/null 2>&1; then
    _homelab_mcp_warn "probe requested but curl missing; skipping probe"
    return 0
  fi
  local url="${HOMELAB_MCP_KEY_PROBE_URL:-http://paperless-mcp.archer.casa/docs}"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 \
    -H "Authorization: Bearer ${key}" "$url" 2>/dev/null || true)"
  case "$code" in
    2??) return 0 ;;
    *)
      _homelab_mcp_warn "probe failed for candidate (HTTP ${code:-none}); trying next source"
      return 1
      ;;
  esac
}

_homelab_mcp_write_cache() {
  local cache="$1"
  local value="$2"
  mkdir -p "$(dirname "$cache")" 2>/dev/null || true
  if [ -d "$(dirname "$cache")" ]; then
    umask 077
    printf '%s' "$value" >"$cache"
    chmod 600 "$cache" 2>/dev/null || true
  fi
}

_homelab_mcp_from_kubectl() {
  # $1 = jsonpath → prints decoded secret to stdout; empty on failure
  local jsonpath="$1"
  local b64 cur
  if ! command -v kubectl >/dev/null 2>&1; then
    return 1
  fi
  b64="$(kubectl -n mcp get secret paperless-mcp-secret -o jsonpath="$jsonpath" 2>/dev/null || true)"
  if [ -z "$b64" ]; then
    return 1
  fi
  if command -v base64 >/dev/null 2>&1; then
    cur="$(printf '%s' "$b64" | base64 --decode 2>/dev/null || printf '%s' "$b64" | base64 -d 2>/dev/null || true)"
  else
    return 1
  fi
  cur="$(printf '%s' "$cur" | tr -d '\r\n')"
  if [ -z "$cur" ] || [ "${#cur}" -lt 8 ]; then
    return 1
  fi
  printf '%s' "$cur"
  return 0
}

_homelab_mcp_load_one() {
  # $1 = env var name, $2 = cache path, $3 = kubectl jsonpath for secret data key
  local name="$1"
  local cache="$2"
  local jsonpath="$3"
  local cur=""
  local source=""
  local kubectl_bin=0
  command -v kubectl >/dev/null 2>&1 && kubectl_bin=1

  # 1) process env
  cur="$(eval "echo \"\${$name:-}\"")"
  cur="$(printf '%s' "$cur" | tr -d '\r\n')"
  if [ -n "$cur" ] && [ "${#cur}" -ge 8 ]; then
    if _homelab_mcp_probe_ok "$cur"; then
      source="process"
      eval "export $name=\"\$cur\""
      return 0
    fi
    _homelab_mcp_warn "$name: process env key rejected by probe"
    # do not keep a dead process key exported if probe rejected it
    unset "$name" 2>/dev/null || true
    cur=""
  fi

  # 2) live kubectl BEFORE cache (refuse silent stale cache) — issue #14
  if [ "$kubectl_bin" -eq 1 ]; then
    if cur="$(_homelab_mcp_from_kubectl "$jsonpath")"; then
      if _homelab_mcp_probe_ok "$cur"; then
        source="kubectl"
        eval "export $name=\"\$cur\""
        if [ -f "$cache" ] && [ -r "$cache" ]; then
          local old
          old="$(tr -d '\r\n' <"$cache" 2>/dev/null || true)"
          if [ -n "$old" ] && [ "$old" != "$cur" ]; then
            _homelab_mcp_warn "$name: cache differed from live kubectl secret; refreshing cache"
          fi
        fi
        _homelab_mcp_write_cache "$cache" "$cur"
        return 0
      fi
      _homelab_mcp_warn "$name: kubectl key rejected by probe"
      cur=""
    fi
  fi

  # 3) cache file (offline fallback)
  if [ -f "$cache" ] && [ -r "$cache" ]; then
    cur="$(tr -d '\r\n' <"$cache" 2>/dev/null || true)"
    if [ -n "$cur" ] && [ "${#cur}" -ge 8 ]; then
      if _homelab_mcp_probe_ok "$cur"; then
        source="cache"
        eval "export $name=\"\$cur\""
        if [ "$kubectl_bin" -eq 1 ]; then
          _homelab_mcp_warn "$name: using cache while kubectl returned no key; cache may be stale"
        else
          _homelab_mcp_warn "$name: using local cache (kubectl unavailable); key not revalidated"
        fi
        return 0
      fi
      _homelab_mcp_warn "$name: cache key rejected by probe"
      cur=""
    fi
  fi

  _homelab_mcp_warn "$name: no usable key from process/kubectl/cache; MCP auth will fail until set"
  return 0
}

_homelab_mcp_load_one HOMELAB_MCP_API_KEY \
  "${HOMELAB_MCP_KEY_FILE:-$HOME/.config/homelab/mcp-api-key}" \
  '{.data.API_KEY}'

_homelab_mcp_load_one PAPERLESS_API_KEY \
  "${PAPERLESS_API_KEY_FILE:-$HOME/.config/homelab/paperless-api-key}" \
  '{.data.PAPERLESS_API_TOKEN}'

if [ -z "${PAPERLESS_URL:-}" ]; then
  export PAPERLESS_URL="${PAPERLESS_URL:-https://paperless.archer.casa}"
fi

unset -f _homelab_mcp_load_one _homelab_mcp_from_kubectl _homelab_mcp_write_cache \
  _homelab_mcp_probe_ok _homelab_mcp_warn

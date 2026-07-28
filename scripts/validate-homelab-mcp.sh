#!/usr/bin/env bash
# Validate Homelab MCP config + Immich endpoint reachability (no secrets printed).
# Failures are actionable and time-bounded (no silent MCP handshake hang).
set -euo pipefail

TIMEOUT_SEC="${HOMELAB_MCP_VALIDATE_TIMEOUT:-5}"
SKIP_NETWORK=0
SKIP_CLUSTER=0
FAILED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
    --skip-network) SKIP_NETWORK=1; shift ;;
    --skip-cluster) SKIP_CLUSTER=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: validate-homelab-mcp.sh [--timeout SEC] [--skip-network] [--skip-cluster]

Probes Immich /health and /mcp with a short timeout so unreachable edges fail
fast with remediation hints (LAN/Tailscale allowlist only; no edge API key).
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

ok() { printf 'OK  %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; FAILED=$((FAILED + 1)); }
info() { printf 'INFO %s\n' "$*"; }

# Optional env loader
if [ -f "${HOME}/.config/homelab/homelab-mcp.env.sh" ]; then
  # shellcheck disable=SC1091
  . "${HOME}/.config/homelab/homelab-mcp.env.sh"
fi

if [ -z "${HOMELAB_MCP_API_KEY:-}" ]; then
  bad "HOMELAB_MCP_API_KEY is not set in this process (Paperless mcpo Bearer)"
else
  ok "HOMELAB_MCP_API_KEY present (len=${#HOMELAB_MCP_API_KEY})"
fi

if [ -z "${PAPERLESS_API_KEY:-}" ]; then
  info "PAPERLESS_API_KEY not set (Grok stdio paperless MCP will fail until set)"
else
  ok "PAPERLESS_API_KEY present (len=${#PAPERLESS_API_KEY})"
fi

check_file_pattern() {
  local label="$1" file="$2" pattern="$3"
  if [ -f "$file" ] && grep -Eq "$pattern" "$file" 2>/dev/null; then
    ok "$label"
  else
    bad "$label missing — re-run scripts/setup_agents.sh or install-homelab-mcp.ps1"
  fi
}

check_file_pattern "codex paperless" "${HOME}/.codex/config.toml" 'mcp_servers\.paperless'
check_file_pattern "codex immich" "${HOME}/.codex/config.toml" 'mcp_servers\.immich'
check_file_pattern "grok paperless" "${HOME}/.grok/config.toml" 'mcp_servers\.paperless'
check_file_pattern "grok immich" "${HOME}/.grok/config.toml" 'mcp_servers\.immich'

if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PY'
import json, os, pathlib, sys
home = pathlib.Path.home()
failed = 0
def check(path, *keys):
    global failed
    p = home / path
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"FAIL {path}: {e}")
        failed += 1
        return
    servers = doc.get("mcpServers") or {}
    missing = [k for k in keys if k not in servers]
    if missing:
        print(f"FAIL {path} missing {', '.join(missing)}")
        failed += 1
    else:
        print(f"OK  {path} (paperless+immich)")
check(".gemini/settings.json", "paperless", "immich")
agy = home / ".gemini/antigravity/mcp_config.json"
if agy.exists():
    check(".gemini/antigravity/mcp_config.json", "paperless", "immich")
sys.exit(1 if failed else 0)
PY
  then
    :
  else
    FAILED=$((FAILED + 1))
  fi
else
  info "python3 not available; skipped Gemini/Antigravity JSON checks"
fi

immich_failure_hint() {
  local label="$1" status="$2" err="$3"
  if [ "$status" = "000" ] || printf '%s' "$err" | grep -Eqi 'timed out|timeout'; then
    cat <<EOF
Immich probe timed out ($label, ${TIMEOUT_SEC}s). Same hang class as MCP streamable-HTTP handshake.
Remediation:
  1. Confirm you are on home LAN (192.168.0.0/16) or Tailscale (100.64.0.0/10).
  2. Confirm DNS for immich-mcp.archer.casa (AdGuard / hosts / MagicDNS).
  3. Set HOMELAB_TRAEFIK_TS_IP and re-run install if DNS is broken.
  4. Do not wait on MCP handshake — fix network first.
EOF
    return
  fi
  if [ "$status" = "403" ]; then
    cat <<EOF
Immich returned HTTP 403 from $label — source IP outside Traefik allowlist
(LAN 192.168.0.0/16, Tailscale 100.64.0.0/10, loopback 127.0.0.1/32).
Connect via Tailscale or home LAN; do not publish Immich MCP publicly.
EOF
    return
  fi
  if printf '%s' "$err" | grep -Eqi 'Could not resolve|Name or service not known|nodename nor servname'; then
    echo "Hostname did not resolve for $label. Fix DNS or use Tailscale VIP + Host header (mcp/README.md)."
    return
  fi
  if printf '%s' "$err" | grep -Eqi 'Connection refused|Failed to connect'; then
    echo "Connection refused for $label — check: kubectl -n mcp get deploy,po,svc,ingress -l app=immich-mcp"
    return
  fi
  echo "Immich probe failed for $label (HTTP $status). $err"
}

probe_immich() {
  local health_url="$1" mcp_url="$2" label="$3" host_header="${4:-}"
  local curl_base=(curl -sS -m "$TIMEOUT_SEC" --connect-timeout "$TIMEOUT_SEC")
  if [ -n "$host_header" ]; then
    curl_base+=(-H "Host: $host_header")
  fi

  local body status err
  err=""
  body="$("${curl_base[@]}" -w '\n%{http_code}' "$health_url" 2>/tmp/immich-validate.err || true)"
  err="$(cat /tmp/immich-validate.err 2>/dev/null || true)"
  status="$(printf '%s' "$body" | tail -n1)"
  body="$(printf '%s' "$body" | sed '$d')"
  if [ "$status" = "200" ] || printf '%s' "$body" | grep -Eqi 'healthy|ok|UP'; then
    ok "immich /health via $label (HTTP ${status:-?})"
  else
    bad "$(immich_failure_hint "$label/health" "${status:-000}" "$err")"
  fi

  # Path reachability only — do not perform MCP initialize handshake.
  status="$("${curl_base[@]}" -o /dev/null -w '%{http_code}' "$mcp_url" 2>/tmp/immich-validate.err || true)"
  err="$(cat /tmp/immich-validate.err 2>/dev/null || true)"
  rm -f /tmp/immich-validate.err 2>/dev/null || true
  if [ -n "$status" ] && [ "$status" != "000" ]; then
    ok "immich /mcp path answers via $label (HTTP $status) — edge reachable (no handshake)"
  else
    bad "$(immich_failure_hint "$label/mcp" "${status:-000}" "$err")"
  fi
}

if [ "$SKIP_NETWORK" -eq 0 ]; then
  printf '\n'
  info "Probing Immich MCP reachability (timeout=${TIMEOUT_SEC}s; no full MCP handshake)..."
  HOST_NAME="immich-mcp.archer.casa"
  DNS_OK=0
  if getent hosts "$HOST_NAME" >/dev/null 2>&1 || host "$HOST_NAME" >/dev/null 2>&1 || nslookup "$HOST_NAME" >/dev/null 2>&1; then
    ok "DNS $HOST_NAME resolves"
    DNS_OK=1
    probe_immich "http://${HOST_NAME}/health" "http://${HOST_NAME}/mcp" "http://${HOST_NAME}"
  else
    bad "DNS resolve failed for $HOST_NAME. On LAN use AdGuard rewrites or /etc/hosts; on remote join Tailscale and re-run setup_agents (hosts block) or set HOMELAB_TRAEFIK_TS_IP."
  fi
  if [ "$DNS_OK" -eq 0 ]; then
    TS_VIP="${HOMELAB_TRAEFIK_TS_IP:-100.68.151.94}"
    info "Adding Tailscale Traefik fallback probe: $TS_VIP (Host: $HOST_NAME)"
    probe_immich "http://${TS_VIP}/health" "http://${TS_VIP}/mcp" "http://${TS_VIP} (Host: $HOST_NAME)" "$HOST_NAME"
  fi
else
  info "Skipping client-side network probes (--skip-network)"
fi

if [ "$SKIP_CLUSTER" -eq 0 ]; then
  if command -v kubectl >/dev/null 2>&1; then
    printf '\n'
    info "In-cluster smoke (kubectl)..."
    imm="$(kubectl --request-timeout=15s -n mcp exec deploy/immich-mcp -- curl -sS -m 5 http://127.0.0.1:5000/health 2>&1 || true)"
    if printf '%s' "$imm" | grep -Eqi 'healthy'; then
      ok "immich-mcp /health in-cluster"
    else
      bad "immich-mcp in-cluster health failed: $imm"
    fi
    if [ -n "${HOMELAB_MCP_API_KEY:-}" ]; then
      code="$(kubectl --request-timeout=30s -n mcp run "curl-pl-val-$(date +%s)" --rm -i --restart=Never --image=curlimages/curl:8.5.0 --quiet -- \
        curl -sS -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${HOMELAB_MCP_API_KEY}" \
        http://paperless-mcp.mcp.svc.cluster.local:8080/docs 2>/dev/null || true)"
      if printf '%s' "$code" | grep -q '200'; then
        ok "paperless-mcp /docs Bearer auth 200"
      else
        bad "paperless-mcp auth code=$code"
      fi
    fi
  else
    info "kubectl not available; skipped in-cluster smoke"
  fi
else
  info "Skipping in-cluster checks (--skip-cluster)"
fi

if command -v codex >/dev/null 2>&1; then
  list="$(codex mcp list 2>&1 || true)"
  if printf '%s' "$list" | grep -qi paperless && printf '%s' "$list" | grep -qi immich; then
    ok "codex mcp list has paperless+immich"
  else
    bad "codex mcp list missing paperless and/or immich"
  fi
fi
if command -v grok >/dev/null 2>&1; then
  list="$(grok mcp list 2>&1 || true)"
  if printf '%s' "$list" | grep -qi paperless && printf '%s' "$list" | grep -qi immich; then
    ok "grok mcp list has paperless+immich"
  else
    bad "grok mcp list missing paperless and/or immich"
  fi
fi

if [ "$FAILED" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$FAILED"
  echo "See mcp/README.md (LAN/Tailscale allowlist + failure modes)."
  exit 1
fi
printf '\nAll validation checks passed\n'
exit 0

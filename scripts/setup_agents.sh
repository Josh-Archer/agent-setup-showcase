#!/usr/bin/env bash
# Bootstrap agent definitions, skills, shell env, and Homelab MCP clients.
# Safe for public repos: no secret values written into git-tracked files.
set -euo pipefail

if [ "$EUID" -eq 0 ]; then
  printf '[setup_agents] Error: Please do not run this script as root or with sudo.\n'
  printf '[setup_agents] The script will prompt for sudo internally when updating /etc/hosts.\n'
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/homelab"
SHELL_SNIPPET_SRC="$REPO_ROOT/shell/homelab-mcp.env.sh"
SHELL_SNIPPET_DST="$CONFIG_DIR/homelab-mcp.env.sh"
KEY_CACHE="$CONFIG_DIR/mcp-api-key"

log() { printf '[setup_agents] %s\n' "$*"; }

ensure_link_or_copy() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ] || [ -e "$dst" ]; then
    if [ -L "$dst" ] && [ "$(readlink "$dst" 2>/dev/null || true)" = "$src" ]; then
      log "ok link $dst"
      return 0
    fi
    # Prefer replace symlink; back up foreign trees once
    if [ ! -L "$dst" ]; then
      local bak="${dst}.bak-setup-agents-$(date +%Y%m%d%H%M%S)"
      log "backing up $dst -> $bak"
      mv "$dst" "$bak"
    else
      rm -f "$dst"
    fi
  fi
  ln -s "$src" "$dst"
  log "linked $dst -> $src"
}

install_agent_trees() {
  # Project-style trees live in this repo; mirror into user global homes when useful.
  if [ -d "$REPO_ROOT/.codex/agents" ]; then
    mkdir -p "$HOME/.codex"
    # Copy agent defs (not full config.toml — user keeps local settings)
    rsync -a --delete "$REPO_ROOT/.codex/agents/" "$HOME/.codex/agents/" 2>/dev/null \
      || { mkdir -p "$HOME/.codex/agents"; cp -R "$REPO_ROOT/.codex/agents/." "$HOME/.codex/agents/"; }
    log "synced Codex agents -> ~/.codex/agents"
  fi
  if [ -d "$REPO_ROOT/.codex/skills" ]; then
    mkdir -p "$HOME/.codex/skills"
    rsync -a --delete "$REPO_ROOT/.codex/skills/" "$HOME/.codex/skills/" 2>/dev/null \
      || { mkdir -p "$HOME/.codex/skills"; cp -R "$REPO_ROOT/.codex/skills/." "$HOME/.codex/skills/"; }
    log "synced Codex skills -> ~/.codex/skills"
  fi
  if [ -d "$REPO_ROOT/.claude/agents" ]; then
    mkdir -p "$HOME/.claude"
    rsync -a --delete "$REPO_ROOT/.claude/agents/" "$HOME/.claude/agents/" 2>/dev/null \
      || { mkdir -p "$HOME/.claude/agents"; cp -R "$REPO_ROOT/.claude/agents/." "$HOME/.claude/agents/"; }
    log "synced Claude agents -> ~/.claude/agents"
  fi
  if [ -d "$REPO_ROOT/.claude/skills" ]; then
    mkdir -p "$HOME/.claude/skills"
    rsync -a --delete "$REPO_ROOT/.claude/skills/" "$HOME/.claude/skills/" 2>/dev/null \
      || { mkdir -p "$HOME/.claude/skills"; cp -R "$REPO_ROOT/.claude/skills/." "$HOME/.claude/skills/"; }
    log "synced Claude skills -> ~/.claude/skills"
  fi
  if [ -d "$REPO_ROOT/.gemini/agents" ]; then
    mkdir -p "$HOME/.gemini"
    rsync -a --delete "$REPO_ROOT/.gemini/agents/" "$HOME/.gemini/agents/" 2>/dev/null \
      || { mkdir -p "$HOME/.gemini/agents"; cp -R "$REPO_ROOT/.gemini/agents/." "$HOME/.gemini/agents/"; }
    log "synced Gemini agents -> ~/.gemini/agents"
  fi
  if [ -d "$REPO_ROOT/.gemini/skills" ]; then
    mkdir -p "$HOME/.gemini/skills"
    rsync -a --delete "$REPO_ROOT/.gemini/skills/" "$HOME/.gemini/skills/" 2>/dev/null \
      || { mkdir -p "$HOME/.gemini/skills"; cp -R "$REPO_ROOT/.gemini/skills/." "$HOME/.gemini/skills/"; }
    log "synced Gemini skills -> ~/.gemini/skills"
  fi
  if [ -d "$REPO_ROOT/.omp/agents" ]; then
    mkdir -p "$HOME/.omp/agent/agents"
    rsync -a --delete "$REPO_ROOT/.omp/agents/" "$HOME/.omp/agent/agents/" 2>/dev/null \
      || { mkdir -p "$HOME/.omp/agent/agents"; cp -R "$REPO_ROOT/.omp/agents/." "$HOME/.omp/agent/agents/"; }
    log "synced OMP agents -> ~/.omp/agent/agents"
  fi
  if [ -d "$REPO_ROOT/.omp/skills" ]; then
    mkdir -p "$HOME/.omp/agent/skills"
    rsync -a --delete "$REPO_ROOT/.omp/skills/" "$HOME/.omp/agent/skills/" 2>/dev/null \
      || { mkdir -p "$HOME/.omp/agent/skills"; cp -R "$REPO_ROOT/.omp/skills/." "$HOME/.omp/agent/skills/"; }
    log "synced OMP skills -> ~/.omp/agent/skills"
  fi
}

install_shell_snippet() {
  mkdir -p "$CONFIG_DIR"
  cp "$SHELL_SNIPPET_SRC" "$SHELL_SNIPPET_DST"
  chmod 644 "$SHELL_SNIPPET_DST"
  log "installed shell snippet $SHELL_SNIPPET_DST"

  local marker='# >>> homelab-mcp (agent-setup-showcase) >>>'
  local end_marker='# <<< homelab-mcp (agent-setup-showcase) <<<'
  local block
  block=$(cat <<EOF
$marker
# Homelab MCP env (Paperless/Immich). No secrets in this line.
[ -f "$SHELL_SNIPPET_DST" ] && . "$SHELL_SNIPPET_DST"
$end_marker
EOF
)

  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    touch "$rc"
    if grep -qF "$marker" "$rc" 2>/dev/null; then
      # Replace existing block
      local tmp
      tmp="$(mktemp)"
      awk -v m="$marker" -v e="$end_marker" '
        $0 == m {skip=1; next}
        $0 == e {skip=0; next}
        !skip {print}
      ' "$rc" >"$tmp"
      printf '%s\n' "$block" >>"$tmp"
      mv "$tmp" "$rc"
      log "refreshed MCP hook in $rc"
    else
      printf '\n%s\n' "$block" >>"$rc"
      log "appended MCP hook to $rc"
    fi
  done
}

refresh_key_cache() {
  if [ -n "${HOMELAB_MCP_API_KEY:-}" ]; then
    umask 077
    printf '%s' "$HOMELAB_MCP_API_KEY" >"$KEY_CACHE"
    chmod 600 "$KEY_CACHE"
    log "refreshed key cache from existing env (not printed)"
    return 0
  fi
  if command -v kubectl >/dev/null 2>&1; then
    local b64 key
    b64="$(kubectl -n mcp get secret paperless-mcp-secret -o jsonpath='{.data.API_KEY}' 2>/dev/null || true)"
    if [ -n "$b64" ]; then
      key="$(printf '%s' "$b64" | base64 --decode 2>/dev/null || printf '%s' "$b64" | base64 -d 2>/dev/null || true)"
      if [ -n "$key" ]; then
        umask 077
        printf '%s' "$key" >"$KEY_CACHE"
        chmod 600 "$KEY_CACHE"
        export HOMELAB_MCP_API_KEY="$key"
        log "loaded key from cluster into cache (not printed)"
        return 0
      fi
    fi
  fi
  log "warning: HOMELAB_MCP_API_KEY not available (Paperless MCP auth may fail until set)"
}

install_mcp_clients() {
  # Prefer PowerShell installer when available for Codex/Grok CLIs; else pure shell fragment merge.
  if command -v powershell.exe >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; then
    local ps
    ps="$(command -v pwsh 2>/dev/null || command -v powershell.exe 2>/dev/null)"
    # On pure Linux, use bash-side MCP install via grok/codex if present
    :
  fi

  # Source env so CLIs see the key
  # shellcheck disable=SC1090
  [ -f "$SHELL_SNIPPET_DST" ] && . "$SHELL_SNIPPET_DST"

  # Resolve Immich URL: hostname when DNS works, else Traefik Tailscale VIP + Host.
  local immich_host="immich-mcp.archer.casa"
  local immich_url="http://${immich_host}/mcp"
  local immich_use_host_header=0
  local ts_vip="${HOMELAB_TRAEFIK_TS_IP:-100.68.151.94}"
  if getent hosts "$immich_host" >/dev/null 2>&1 || host "$immich_host" >/dev/null 2>&1 || nslookup "$immich_host" >/dev/null 2>&1; then
    log "Immich DNS ok: $immich_host"
  else
    immich_url="http://${ts_vip}/mcp"
    immich_use_host_header=1
    log "warning: DNS for $immich_host failed; Immich MCP URL=$immich_url with Host: $immich_host"
  fi

  if command -v codex >/dev/null 2>&1; then
    codex mcp remove paperless >/dev/null 2>&1 || true
    codex mcp remove immich >/dev/null 2>&1 || true
    codex mcp add paperless --url 'http://paperless-mcp.archer.casa' --bearer-token-env-var HOMELAB_MCP_API_KEY
    codex mcp add immich --url "$immich_url"
    log "Codex MCP: paperless + immich ($immich_url)"
  else
    log "codex CLI not found; skip Codex MCP CLI registration"
  fi

  if command -v grok >/dev/null 2>&1; then
    grok mcp remove paperless >/dev/null 2>&1 || true
    grok mcp remove immich >/dev/null 2>&1 || true
    # Paperless: native stdio MCP (cluster mcpo is OpenAPI, not streamable HTTP MCP)
    local paperless_url="${PAPERLESS_URL:-https://paperless.archer.casa}"
    grok mcp add paperless \
      -e "PAPERLESS_URL=${paperless_url}" \
      -e 'PAPERLESS_API_KEY=${PAPERLESS_API_KEY}' \
      -e "PAPERLESS_PUBLIC_URL=${paperless_url}" \
      -- npx -y @baruchiro/paperless-mcp@latest
    if [ "$immich_use_host_header" -eq 1 ]; then
      grok mcp add --transport http immich "$immich_url" --header "Host: ${immich_host}"
    else
      grok mcp add --transport http immich "$immich_url"
    fi
    log "Grok MCP: paperless=stdio, immich=http ($immich_url)"
  else
    log "grok CLI not found; writing fragment to ~/.grok/config.toml if missing"
    mkdir -p "$HOME/.grok"
    if [ -f "$REPO_ROOT/mcp/fragments/grok.homelab-mcp.toml" ]; then
      # Append once
      if ! grep -q '\[mcp_servers.paperless\]' "$HOME/.grok/config.toml" 2>/dev/null; then
        printf '\n' >>"$HOME/.grok/config.toml"
        cat "$REPO_ROOT/mcp/fragments/grok.homelab-mcp.toml" >>"$HOME/.grok/config.toml"
      fi
      if [ "$immich_use_host_header" -eq 1 ] && [ -f "$HOME/.grok/config.toml" ]; then
        # Best-effort URL patch when DNS is broken
        if command -v sed >/dev/null 2>&1; then
          sed -i.bak-homelab-mcp "s|url = \"http://immich-mcp.archer.casa/mcp\"|url = \"${immich_url}\"|" "$HOME/.grok/config.toml" 2>/dev/null || true
        fi
      fi
    fi
  fi

  # Gemini / Antigravity JSON fragments via python for portability
  REPO_ROOT="$REPO_ROOT" python3 - <<'PY' || true
import json, os, pathlib
home = pathlib.Path.home()
repo = pathlib.Path(os.environ["REPO_ROOT"])
frag = json.loads((repo / "mcp/fragments/gemini.mcpServers.json").read_text(encoding="utf-8"))
settings_path = home / ".gemini" / "settings.json"
settings_path.parent.mkdir(parents=True, exist_ok=True)
settings = {}
if settings_path.exists():
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8") or "{}")
    except Exception:
        settings = {}
servers = settings.get("mcpServers") or {}
if not isinstance(servers, dict):
    servers = {}
servers.update(frag)
settings["mcpServers"] = servers
settings_path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
for sub_path in ["antigravity/mcp_config.json", "antigravity-cli/mcp_config.json"]:
    agy = home / ".gemini" / sub_path
    agy.parent.mkdir(parents=True, exist_ok=True)
    agy_doc = {"mcpServers": dict(frag)}
    if agy.exists():
        try:
            existing = json.loads(agy.read_text(encoding="utf-8") or "{}")
            base = existing.get("mcpServers") if isinstance(existing.get("mcpServers"), dict) else {}
            base.update(frag)
            existing["mcpServers"] = base
            agy_doc = existing
        except Exception:
            pass
    agy.write_text(json.dumps(agy_doc, indent=2) + "\n", encoding="utf-8")
print("[setup_agents] synced Gemini/Antigravity mcpServers")
omp_cfg = home / ".omp" / "agent" / "config.yml"
if (home / ".omp").exists() or omp_cfg.exists():
    try:
        try:
            import yaml
        except ImportError:
            yaml = None
        omp_cfg.parent.mkdir(parents=True, exist_ok=True)
        doc = {}
        if omp_cfg.exists():
            content = omp_cfg.read_text(encoding="utf-8")
            if yaml:
                doc = yaml.safe_load(content) or {}
            else:
                doc = json.loads(content or "{}")
        if not isinstance(doc, dict):
            doc = {}
        s = doc.get("mcpServers") or {}
        if not isinstance(s, dict):
            s = {}
        s.update(frag)
        doc["mcpServers"] = s
        if yaml:
            omp_cfg.write_text(yaml.dump(doc, sort_keys=False), encoding="utf-8")
        else:
            omp_cfg.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
        print("[setup_agents] synced OMP mcpServers -> ~/.omp/agent/config.yml")
    except Exception as e:
        print(f"[setup_agents] warning: could not sync OMP mcpServers: {e}")
PY
}

update_hosts_entry() {
  # Check if OS is macOS or Linux
  if [[ "$OSTYPE" != "darwin"* && "$OSTYPE" != "linux-gnu"* && "$OSTYPE" != "linux"* ]]; then
    log "OS is not macOS/Linux; skipping hosts file check"
    return 0
  fi

  if ! command -v kubectl >/dev/null 2>&1; then
    log "kubectl not found; skip hosts file check"
    return 0
  fi

  local ts_ip
  ts_ip="$(kubectl get svc -n kube-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [ -z "$ts_ip" ]; then
    log "could not find Traefik Tailscale IP; skip hosts file check"
    return 0
  fi

  log "found Traefik Tailscale IP: $ts_ip"
  local domains=("paperless-mcp.archer.casa" "immich-mcp.archer.casa")
  local needs_update=0

  for domain in "${domains[@]}"; do
    if ! grep -qE "[[:space:]]${domain}([[:space:]]|$)" /etc/hosts; then
      needs_update=1
      break
    fi
    local current_ip
    current_ip="$(grep -E "[[:space:]]${domain}([[:space:]]|$)" /etc/hosts | awk '{print $1}' | head -n1)"
    if [ "$current_ip" != "$ts_ip" ]; then
      needs_update=1
      break
    fi
  done

  if [ "$needs_update" -eq 1 ]; then
    local block
    block=$(cat <<EOF

# >>> homelab-mcp-hosts (agent-setup-showcase) >>>
$ts_ip paperless-mcp.archer.casa
$ts_ip immich-mcp.archer.casa
# <<< homelab-mcp-hosts (agent-setup-showcase) <<<
EOF
)
    # Check if we can run sudo without password, or if terminal is interactive
    if sudo -n true 2>/dev/null || [ -t 0 ]; then
      log "updating /etc/hosts with Tailscale MCP routes..."
      if grep -qF "# >>> homelab-mcp-hosts" /etc/hosts 2>/dev/null; then
        local tmp
        tmp="$(mktemp)"
        awk '
          /# >>> homelab-mcp-hosts/ {skip=1; next}
          /# <<< homelab-mcp-hosts/ {skip=0; next}
          !skip {print}
        ' /etc/hosts >"$tmp"
        printf '%s\n' "$block" >>"$tmp"
        sudo mv "$tmp" /etc/hosts
      else
        printf '%s\n' "$block" | sudo tee -a /etc/hosts >/dev/null
      fi
      log "successfully updated /etc/hosts"
    else
      log "warning: /etc/hosts needs update but sudo requires a password and terminal is non-interactive."
      log "Please run the following command manually to update your hosts file:"
      log "  sudo sh -c 'printf \"\\\n# Tailscale MCP routes\\\n$ts_ip paperless-mcp.archer.casa\\\n$ts_ip immich-mcp.archer.casa\\\n\" >> /etc/hosts'"
    fi
  else
    log "/etc/hosts already up-to-date for MCP domains"
  fi
}

main() {
  export REPO_ROOT
  log "repo=$REPO_ROOT"
  install_agent_trees
  install_shell_snippet
  refresh_key_cache
  install_mcp_clients
  update_hosts_entry
  log "done. Open a new shell (or: source ~/.zshrc) and restart Codex/Claude/Gemini/Grok/Antigravity/OMP."
}

main "$@"

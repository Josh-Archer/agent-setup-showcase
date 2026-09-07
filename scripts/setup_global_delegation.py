#!/usr/bin/env python3
"""Install this repository's delegation surfaces for local agent harnesses."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
from pathlib import Path


SKILL_NAME = "grok-agy-delegate"
MARKER = "# >>> agent-setup-showcase delegation >>>"
END_MARKER = "# <<< agent-setup-showcase delegation <<<"


def shell_block(repo_root: Path) -> str:
    return f'''{MARKER}
# Keep the global Codex delegation skill tied to this checkout.
export CODEX_DELEGATION_REPO={repo_root}
# Link any new repository skills when a new zsh starts.
python3 "$CODEX_DELEGATION_REPO/scripts/setup_global_delegation.py" --sync-skills --quiet 2>/dev/null || true
{END_MARKER}'''


def create_link(source: Path, destination: Path, label: str) -> Path:
    if not source.exists():
        raise SystemExit(f"{label} source not found: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    is_link = destination.is_symlink() or (hasattr(destination, "is_junction") and destination.is_junction())
    if is_link or destination.exists():
        try:
            if is_link and destination.resolve() == source.resolve():
                return destination
        except OSError:
            pass
        if destination.is_symlink() or destination.is_file():
            destination.unlink()
        elif destination.is_dir():
            shutil.rmtree(destination)
    if os.name == "nt" and source.is_dir():
        subprocess.run(["cmd", "/c", "mklink", "/J", str(destination), str(source)], check=True, stdout=subprocess.DEVNULL)
    else:
        destination.symlink_to(source, target_is_directory=source.is_dir())
    return destination


def install_skill(repo_root: Path, codex_home: Path) -> Path:
    return create_link(repo_root / ".codex" / "skills" / SKILL_NAME, codex_home / "skills" / SKILL_NAME, "Delegation skill")


def install_link(source: Path, destination: Path, label: str) -> Path:
    return create_link(source, destination, label)


def sync_skills(repo_root: Path, codex_home: Path) -> list[Path]:
    source_root = repo_root / ".codex" / "skills"
    destination_root = codex_home / "skills"
    destination_root.mkdir(parents=True, exist_ok=True)
    installed: list[Path] = []
    for source in sorted(source_root.iterdir()):
        if source.is_dir() and not source.name.startswith("."):
            installed.append(install_link(source, destination_root / source.name, "Codex skill"))
    # Also sync skills to Claude, Gemini, and OMP when present
    home = Path.home()
    for extra_dest, label in [
        (home / ".claude" / "skills", "Claude skill"),
        (home / ".gemini" / "skills", "Gemini skill"),
        (home / ".omp" / "agent" / "skills", "OMP skill"),
    ]:
        if extra_dest.parent.exists():
            extra_dest.mkdir(parents=True, exist_ok=True)
            for source in sorted(source_root.iterdir()):
                if source.is_dir() and not source.name.startswith("."):
                    try:
                        installed.append(install_link(source, extra_dest / source.name, label))
                    except SystemExit:
                        pass
    return installed


def install_harness_surfaces(repo_root: Path, home: Path) -> list[Path]:
    """Expose generated role/plugin surfaces to Grok CLI, Antigravity, and OMP."""
    links = [
        (repo_root / ".grok" / "agents", home / ".grok" / "agents", "Grok agents"),
        (repo_root / ".grok" / "roles", home / ".grok" / "roles", "Grok roles"),
        (
            repo_root / ".agents" / "plugins" / "home-codex-agents",
            home / ".agents" / "plugins" / "home-codex-agents",
            "Antigravity plugin",
        ),
        (repo_root / ".omp" / "agents", home / ".omp" / "agent" / "agents", "OMP agents"),
    ]
    return [install_link(source, destination, label) for source, destination, label in links]


def install_shell_hook(shell_file: Path, repo_root: Path) -> None:
    existing = shell_file.read_text(encoding="utf-8") if shell_file.exists() else ""
    block = f'''{MARKER}
$env:CODEX_DELEGATION_REPO="{repo_root}"
try {{ python3 "$env:CODEX_DELEGATION_REPO/scripts/setup_global_delegation.py" --sync-skills --quiet 2>$null }} catch {{}}
{END_MARKER}''' if shell_file.suffix == ".ps1" else shell_block(repo_root)

    if MARKER in existing:
        start = existing.index(MARKER)
        end = existing.find(END_MARKER, start)
        if end < 0:
            raise SystemExit(f"Found incomplete delegation block in {shell_file}")
        end += len(END_MARKER)
        existing = existing[:start] + block + existing[end:]
    else:
        separator = "\n" if existing and not existing.endswith("\n") else ""
        existing += separator + "\n" + block + "\n"
    shell_file.parent.mkdir(parents=True, exist_ok=True)
    shell_file.write_text(existing, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--codex-home", type=Path, default=Path(os.environ.get("CODEX_HOME", "~/.codex")).expanduser())
    default_shell = Path("~/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1").expanduser() if os.name == "nt" else Path("~/.zshrc").expanduser()
    parser.add_argument("--shell-file", type=Path, default=default_shell)
    parser.add_argument("--sync-skills", action="store_true", help="Link all repository skills and exit")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--sync-codex-agents", action="store_true", help="Link generated native Codex agents and exit")
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    if args.sync_codex_agents:
        sources = sorted((repo_root / ".codex" / "agents").glob("*.toml"))
        if not sources:
            raise SystemExit("No native Codex agents; run scripts/sync_agent_surfaces.py first")
        for source in sources:
            destination = args.codex_home.expanduser() / "agents" / source.name
            if destination.exists() and not destination.is_symlink():
                raise SystemExit(f"Existing personal agent needs backup before replacement: {destination}")
            install_link(source, destination, "Native Codex agent")
        return 0
    if args.sync_skills:
        sync_skills(repo_root, args.codex_home.expanduser())
        return 0
    destination = install_skill(repo_root, args.codex_home.expanduser())
    harness_links = install_harness_surfaces(repo_root, Path.home())
    install_shell_hook(args.shell_file.expanduser(), repo_root)
    print(f"Installed global Codex skill: {destination} -> {repo_root / '.codex/skills' / SKILL_NAME}")
    for link in harness_links:
        print(f"Installed global harness surface: {link} -> {link.resolve()}")
    print(f"Updated shell startup: {args.shell_file.expanduser()}")
    print("Restart the shell or open a new Codex/ChatGPT session to load it.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

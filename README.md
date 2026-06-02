# OCI Instance Setup

Bootstrap script for a freshly provisioned **OCI Ubuntu (Ampere A1 / ARM64)** instance.

## What it installs

| Item | Method | Notes |
|------|--------|-------|
| Base packages | `apt` | curl, git, build-essential, unzip, gnupg, … |
| GitHub CLI (`gh`) | official apt repo | arm64 supported |
| Node.js LTS | NodeSource | For MCP servers / npm tooling |
| Emacs | `apt` | `emacs-nox` by default (headless); set `EMACS_GUI=1` for full |
| Default editor | env + alternatives | Emacs set as `EDITOR`/`VISUAL`, git `core.editor`, system `editor` |
| Claude Code | official native installer | ARM64 supported, auto-updates |
| OpenAI Codex CLI | official installer (npm fallback) | aarch64 musl binary |
| Antigravity CLI | official installer | `antigravity.google/cli/install.sh`; linux-arm supported |
| zsh | `apt` + `chsh` | set as default shell, with oh-my-zsh |

The script is **idempotent** (safe to re-run) and **does not touch the firewall**, SSH, or networking — per your setup.

## Usage

```bash
# Copy to the instance, then:
chmod +x setup.sh
./setup.sh
```

Run as the normal `ubuntu` user (not root) so the AI CLIs install into your home dir.

### Options (env vars)

```bash
SKIP_OHMYZSH=1 ./setup.sh     # skip oh-my-zsh
EMACS_GUI=1 ./setup.sh        # full Emacs instead of emacs-nox
```

## After running

1. `exec zsh` (or log out/in) to pick up zsh + PATH changes.
2. Authenticate:
   - `claude` → browser login
   - `codex` → ChatGPT/OpenAI login
   - `antigravity` → follow its login flow
3. Verify: `claude --version`, `codex --version`, `antigravity --version`, `emacs --version`

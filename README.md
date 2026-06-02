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

## Quick install (one-liner)

This repo is **private**, so a plain `curl … | bash` won't work — the fetch must
be authenticated with a GitHub token that has read access to the repo.

**1. Create a token** (one of):
- Fine-grained PAT: <https://github.com/settings/tokens?type=beta> → only this repo → `Contents: Read-only`
- Classic PAT: scope `repo`

**2. On the fresh instance**, paste (replace `ghp_xxxx`):

```bash
GITHUB_TOKEN=ghp_xxxx bash -c 'curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://raw.githubusercontent.com/jay-jang/dev-server-setup/main/setup.sh | bash'
```

If you already have an authenticated `gh` on the box, no token needed:

```bash
gh api repos/jay-jang/dev-server-setup/contents/setup.sh \
  -H "Accept: application/vnd.github.raw" | bash
```

> **If you make the repo public**, the clean tokenless one-liner works:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/jay-jang/dev-server-setup/main/setup.sh | bash
> ```

> ⚠️ `curl … | bash` runs remote code immediately. Inspect the script first
> (open the raw URL in a browser) before piping it to a shell.

## Usage (clone)

```bash
gh repo clone jay-jang/dev-server-setup
cd dev-server-setup
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
   - `agy` → Antigravity CLI login flow
   - `gh auth login` → GitHub CLI
3. Verify: `git --version`, `gh --version`, `claude --version`, `codex --version`, `agy --version`, `emacs --version`, `echo $EDITOR`

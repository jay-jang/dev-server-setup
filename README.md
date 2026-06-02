# OCI Instance Setup

Bootstrap script for a freshly provisioned **OCI Ubuntu (Ampere A1 / ARM64)** instance.

## What it installs

| Item | Method | Notes |
|------|--------|-------|
| Base packages | `apt` | curl, git, build-essential, unzip, gnupg, tmux, … |
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

On a fresh instance:

```bash
curl -fsSL https://raw.githubusercontent.com/jay-jang/dev-server-setup/main/setup.sh | bash
```

> ⚠️ `curl … | bash` runs remote code immediately. Inspect the script first
> (open the [raw URL](https://raw.githubusercontent.com/jay-jang/dev-server-setup/main/setup.sh)
> in a browser) before piping it to a shell.

Pass options inline, e.g. skip oh-my-zsh:

```bash
curl -fsSL https://raw.githubusercontent.com/jay-jang/dev-server-setup/main/setup.sh | SKIP_OHMYZSH=1 bash
```

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

## Uninstall

One-liner (prompts for confirmation, reading your terminal even through the pipe):

```bash
curl -fsSL https://raw.githubusercontent.com/jay-jang/dev-server-setup/main/uninstall.sh | bash
```

Or from a clone:

```bash
./uninstall.sh
```

Conservative by default — base/system packages (curl, git, build-essential, …)
are kept, and app data dirs are removed. Options (work with either form, e.g.
`curl -fsSL …/uninstall.sh | ASSUME_YES=1 bash`):

```bash
ASSUME_YES=1 ./uninstall.sh   # no confirmation prompt (required for unattended runs)
KEEP_DATA=1  ./uninstall.sh   # keep ~/.claude, ~/.codex, Antigravity logins/config
KEEP_NODE=1  ./uninstall.sh   # keep Node.js + NodeSource repo
REMOVE_BASE=1 ./uninstall.sh  # also purge base packages (keeps curl + ca-certificates)
```

It reverts the default shell to bash and the default editor to the system auto
choice, and does not touch firewall/SSH/networking.

## After running

1. `exec zsh` (or log out/in) to pick up zsh + PATH changes.
2. Authenticate:
   - `claude` → browser login
   - `codex` → ChatGPT/OpenAI login
   - `agy` → Antigravity CLI login flow
   - `gh auth login` → GitHub CLI
3. Verify: `git --version`, `gh --version`, `claude --version`, `codex --version`, `agy --version`, `emacs --version`, `echo $EDITOR`

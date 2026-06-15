# OCI Instance Setup

Bootstrap script for a freshly provisioned **OCI Ubuntu (Ampere A1 / ARM64)** instance.

## What it installs

| Item | Method | Notes |
|------|--------|-------|
| Base packages | `apt` | curl, git, build-essential, unzip, gnupg, tmux, … |
| tmux persistence | tpm + resurrect + continuum + systemd | Sessions auto-save and are restored after a **reboot** |
| GitHub CLI (`gh`) | official apt repo | arm64 supported |
| Node.js LTS | NodeSource | For MCP servers / npm tooling |
| Emacs | `apt` | `emacs-nox` by default (headless); set `EMACS_GUI=1` for full |
| Default editor | env + alternatives | Emacs set as `EDITOR`/`VISUAL`, git `core.editor`, system `editor` |
| Claude Code | official native installer | ARM64 supported, auto-updates |
| OpenAI Codex CLI | official installer (npm fallback) | aarch64 musl binary |
| Antigravity CLI | official installer | `antigravity.google/cli/install.sh`; linux-arm supported |
| zsh | `apt` + `chsh` | set as default shell, with oh-my-zsh |
| Shell aliases | `.zshrc` / `.bashrc` | `e`=emacs, `ll`=`ls -al`, `ucc`=`claude --dangerously-skip-permissions` |

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

## tmux survives reboot

Your tmux sessions are saved and come back automatically after the instance
reboots. Two pieces make that work:

- **Restore session contents** — [tmux-resurrect] + [tmux-continuum] (installed
  via [tpm]). Continuum auto-saves every 15 min and restores the last saved
  environment whenever the tmux server starts (`@continuum-restore on`).
- **Restart the server at boot** — a systemd *user* service
  (`~/.config/systemd/user/tmux.service`) plus user lingering, so the tmux
  server (and therefore the continuum restore) comes back at boot without anyone
  logging in. On a clean reboot the service also saves once on stop, so you get
  the latest state rather than only the last 15-min auto-save.

On a real instance the service is enabled during setup. If systemd wasn't
reachable at setup time (e.g. you ran inside a container), enable it once on the
box:

```bash
systemctl --user enable --now tmux.service
```

Verify after a reboot: `tmux ls` should list your previous sessions.

[tpm]: https://github.com/tmux-plugins/tpm
[tmux-resurrect]: https://github.com/tmux-plugins/tmux-resurrect
[tmux-continuum]: https://github.com/tmux-plugins/tmux-continuum

## Testing

The `test/` scripts spin up a fresh-OCI-like arm64 Ubuntu container and run the
real `setup.sh` inside it. `test/run.sh` is the host-side launcher (needs Docker):

```bash
./test/run.sh                       # default: setup smoke test (docker-test.sh)
./test/run.sh tmux-reboot-test.sh   # prove tmux sessions survive a reboot
./test/run.sh uninstall-test.sh     # setup → uninstall round-trip
```

The reboot test creates a tmux session, lets resurrect save it, kills the whole
tmux server (the part of a reboot that matters to tmux), brings the server back
up the way the boot service does, and asserts the session/window are restored.

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

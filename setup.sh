#!/usr/bin/env bash
#
# setup.sh — Fresh OCI (Ubuntu / Ampere ARM64) instance bootstrap
#
# Installs: Claude Code, OpenAI Codex CLI, Antigravity CLI (best-effort),
#           Emacs, and sets zsh as the default shell. Adds shell aliases
#           (e=emacs, ll='ls -al', ucc=claude --dangerously-skip-permissions).
#
# Design goals:
#   - Idempotent: safe to re-run; each step skips work already done.
#   - Non-destructive: does NOT touch firewall (iptables/firewalld), SSH, or
#     any networking config.
#   - Target: Ubuntu on OCI Ampere A1 (aarch64). Will warn on other platforms.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh                 # run as the normal 'ubuntu' user (uses sudo)
#
# Optional env vars:
#   SKIP_OHMYZSH=1             # don't install oh-my-zsh
#   EMACS_GUI=1                # install full 'emacs' instead of 'emacs-nox'
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'; C_RESET=$'\033[0m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

log()  { printf "%s==>%s %s\n" "$C_BLUE"  "$C_RESET" "$*"; }
ok()   { printf "%s ✓ %s%s\n" "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf "%s ! %s%s\n" "$C_YELLOW" "$*" "$C_RESET"; }
err()  { printf "%s ✗ %s%s\n" "$C_RED" "$*" "$C_RESET" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  warn "Running as root. It's recommended to run as the normal 'ubuntu' user."
  warn "User-level tools (Claude Code, Codex) will be installed into /root."
  SUDO=""
else
  if ! have sudo; then
    err "sudo not found and not running as root. Cannot continue."
    exit 1
  fi
  SUDO="sudo"
fi

ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
  warn "Detected arch '$ARCH' (expected aarch64). Continuing anyway."
fi

if ! have apt-get; then
  err "apt-get not found. This script targets Ubuntu/Debian."
  exit 1
fi

# Ensure ~/.local/bin exists and is on PATH for this run (native installers use it)
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
install_base_packages() {
  log "Updating apt and installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  preseed_postfix
  $SUDO apt-get update -y
  $SUDO apt-get install -y --no-install-recommends \
    ca-certificates curl wget git unzip xz-utils \
    build-essential gnupg tmux
  ok "Base packages installed."
}

# Postfix can be pulled in transitively (e.g. emacs-nox -> mailutils -> an MTA),
# which triggers the interactive "Postfix Configuration" debconf screen. Preseed
# it to "Local only" (mail stays on this box, no internet relay) so installs run
# unattended and never block on that prompt. Combined with DEBIAN_FRONTEND above.
preseed_postfix() {
  # debconf-set-selections lives in /usr/sbin (not always on a user's PATH), so
  # run it through sudo, which resolves sbin. Tolerate failure — even without
  # the preseed, DEBIAN_FRONTEND=noninteractive suppresses the prompt.
  {
    printf 'postfix postfix/main_mailer_type select Local only\n'
    printf 'postfix postfix/mailname string %s\n' "$(hostname -f 2>/dev/null || hostname)"
  } | $SUDO debconf-set-selections 2>/dev/null || \
    warn "Could not preseed postfix (debconf-set-selections unavailable); relying on noninteractive frontend."
}

# ---------------------------------------------------------------------------
# 1b. git + GitHub CLI (gh)
#     git comes from base packages; gh uses the official GitHub apt repo (arm64
#     supported via arch=$(dpkg --print-architecture)).
# ---------------------------------------------------------------------------
install_git_gh() {
  if have git; then
    ok "git already installed ($(git --version))."
  else
    log "Installing git..."
    $SUDO apt-get install -y git
    ok "git installed ($(git --version))."
  fi

  if have gh; then
    ok "GitHub CLI already installed ($(gh --version | head -n1))."
    return
  fi
  log "Installing GitHub CLI (gh) from official apt repo..."
  $SUDO install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y gh
  ok "GitHub CLI installed ($(gh --version | head -n1))."
}

# ---------------------------------------------------------------------------
# 2. Node.js LTS (via NodeSource) — useful for MCP servers / npm-based tooling
# ---------------------------------------------------------------------------
install_node() {
  if have node; then
    ok "Node.js already installed ($(node --version))."
    return
  fi
  log "Installing Node.js LTS (NodeSource)..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash -
  $SUDO apt-get install -y nodejs
  ok "Node.js installed ($(node --version), npm $(npm --version))."
}

# ---------------------------------------------------------------------------
# 3. Emacs
# ---------------------------------------------------------------------------
install_emacs() {
  if have emacs; then
    ok "Emacs already installed ($(emacs --version | head -n1))."
    return
  fi
  if [[ "${EMACS_GUI:-0}" == "1" ]]; then
    log "Installing full Emacs (GUI)..."
    $SUDO apt-get install -y emacs
  else
    log "Installing emacs-nox (terminal/headless)..."
    $SUDO apt-get install -y emacs-nox
  fi
  ok "Emacs installed ($(emacs --version | head -n1))."
}

# ---------------------------------------------------------------------------
# 3b. Make Emacs the default editor
#     - system 'editor' alternative (sudoedit, etc.)
#     - EDITOR / VISUAL env vars for both shells
#     - git core.editor
# ---------------------------------------------------------------------------
set_default_editor() {
  if ! have emacs; then
    warn "Emacs not found; skipping default-editor setup."
    return
  fi
  local emacs_bin; emacs_bin="$(command -v emacs)"
  log "Setting Emacs as the default editor..."

  if have update-alternatives; then
    $SUDO update-alternatives --install /usr/bin/editor editor "$emacs_bin" 100 >/dev/null 2>&1 || true
    $SUDO update-alternatives --set editor "$emacs_bin" >/dev/null 2>&1 || true
  fi

  ensure_editor_env "$HOME/.zshenv"
  ensure_editor_env "$HOME/.bashrc"

  if have git; then
    git config --global core.editor "emacs"
  fi

  ok "Default editor set to Emacs (EDITOR/VISUAL, git core.editor, system 'editor')."
}

# ---------------------------------------------------------------------------
# 4. Claude Code (official native installer; arm64 supported, auto-updates)
# ---------------------------------------------------------------------------
install_claude_code() {
  if have claude; then
    ok "Claude Code already installed ($(claude --version 2>/dev/null || echo present))."
    return
  fi
  log "Installing Claude Code (native installer)..."
  curl -fsSL https://claude.ai/install.sh | bash
  if [[ -x "$HOME/.local/bin/claude" ]] || have claude; then
    ok "Claude Code installed. Run 'claude' and log in via browser."
  else
    err "Claude Code install did not produce a 'claude' binary; check output above."
  fi
}

# ---------------------------------------------------------------------------
# 5. OpenAI Codex CLI (official installer; aarch64 musl binary supported)
# ---------------------------------------------------------------------------
install_codex() {
  if have codex; then
    ok "Codex already installed ($(codex --version 2>/dev/null || echo present))."
    return
  fi
  log "Installing OpenAI Codex CLI (official installer)..."
  if curl -fsSL https://chatgpt.com/codex/install.sh | sh; then
    if have codex || [[ -x "$HOME/.local/bin/codex" ]]; then
      ok "Codex installed. Run 'codex' to authenticate."
    else
      warn "Codex installer ran but 'codex' not on PATH yet (re-login may be needed)."
    fi
  else
    warn "Official installer failed; falling back to npm (@openai/codex)..."
    if have npm; then
      npm install -g @openai/codex && ok "Codex installed via npm."
    else
      err "npm not available for fallback. Skipping Codex."
    fi
  fi
}

# ---------------------------------------------------------------------------
# 6. Antigravity CLI (official installer; auto-detects platform, incl. linux-arm)
#    NOTE: the installed command is 'agy' (binary at ~/.local/bin/agy).
# ---------------------------------------------------------------------------
install_antigravity() {
  if have agy || [[ -x "$HOME/.local/bin/agy" ]]; then
    ok "Antigravity (agy) already installed ($("$HOME/.local/bin/agy" --version 2>/dev/null || echo present))."
    return
  fi
  log "Installing Antigravity CLI (official installer)..."
  if curl -fsSL https://antigravity.google/cli/install.sh | bash; then
    if have agy || [[ -x "$HOME/.local/bin/agy" ]]; then
      ok "Antigravity CLI installed (command: 'agy')."
    else
      warn "Antigravity installer ran but 'agy' not found; re-login or check ~/.local/bin."
    fi
  else
    err "Antigravity install failed; see https://antigravity.google/download#antigravity-cli"
  fi
}

# ---------------------------------------------------------------------------
# 7. zsh + default shell + sane PATH
# ---------------------------------------------------------------------------
install_zsh() {
  if ! have zsh; then
    log "Installing zsh..."
    $SUDO apt-get install -y zsh
  else
    ok "zsh already installed ($(zsh --version))."
  fi

  local zshrc="$HOME/.zshrc"
  [[ -f "$zshrc" ]] || touch "$zshrc"

  # oh-my-zsh (optional, unattended)
  if [[ "${SKIP_OHMYZSH:-0}" != "1" ]]; then
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
      log "Installing oh-my-zsh (unattended)..."
      RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
        && ok "oh-my-zsh installed."
    else
      ok "oh-my-zsh already installed."
    fi
  fi

  # Ensure ~/.local/bin is on PATH for the binaries the native installers drop
  # there (claude, codex, agy). .zshenv covers every zsh context — interactive
  # SSH logins AND non-interactive `ssh host 'cmd'` runs (.zshrc only covers
  # interactive). .bashrc covers bash sessions.
  ensure_path_line "$HOME/.zshenv"
  ensure_path_line "$HOME/.bashrc"

  # Make zsh the default login shell
  local zsh_path; zsh_path="$(command -v zsh)"
  if [[ "${SHELL:-}" != "$zsh_path" ]]; then
    log "Setting zsh as the default shell for $USER..."
    if $SUDO chsh -s "$zsh_path" "$USER"; then
      ok "Default shell set to zsh (effective on next login)."
    else
      warn "Could not chsh automatically. Run: chsh -s $zsh_path"
    fi
  else
    ok "zsh is already the default shell."
  fi
}

# ---------------------------------------------------------------------------
# 7b. Shell aliases (e=emacs, ll='ls -al', ucc=claude --dangerously-skip-permissions)
#     Runs after install_zsh so oh-my-zsh has already settled ~/.zshrc.
#     Aliases only matter in interactive shells, so they go in .zshrc/.bashrc
#     (not .zshenv, which also runs for non-interactive `ssh host 'cmd'`).
# ---------------------------------------------------------------------------
setup_aliases() {
  log "Adding shell aliases (e, ll, ucc)..."
  ensure_alias_lines "$HOME/.zshrc"
  ensure_alias_lines "$HOME/.bashrc"
  ok "Aliases added: e=emacs, ll='ls -al', ucc='claude --dangerously-skip-permissions'."
}

setup_prompt() {
  log "Setting terminal prompt to account@directory format..."
  ensure_prompt_lines "$HOME/.zshrc" 'zsh'
  ensure_prompt_lines "$HOME/.bashrc" 'bash'
  ok "Prompt configured."
}

ensure_prompt_lines() {
  local rc="$1"
  local shell_type="$2"
  [[ -f "$rc" ]] || touch "$rc"
  if ! grep -qs 'oci-setup: custom prompt' "$rc"; then
    {
      echo ''
      echo '# Added by oci-setup: custom prompt'
      if [[ "$shell_type" == "zsh" ]]; then
        echo "PROMPT='%n@%~%% '"
      else
        echo "PS1='\u@\w\$ '"
      fi
    } >> "$rc"
  fi
}

ensure_alias_lines() {
  local rc="$1"
  [[ -f "$rc" ]] || touch "$rc"
  if ! grep -qs 'oci-setup: aliases' "$rc"; then
    {
      echo ''
      echo '# Added by oci-setup: aliases'
      echo 'alias e="emacs"'
      echo 'alias ll="ls -al"'
      echo 'alias ucc="claude --dangerously-skip-permissions"'
    } >> "$rc"
  fi
}

ensure_path_line() {
  local rc="$1"
  [[ -f "$rc" ]] || touch "$rc"
  if ! grep -qs 'HOME/.local/bin' "$rc"; then
    {
      echo ''
      echo '# Added by oci-setup: user-local binaries (claude, codex, etc.)'
      echo 'export PATH="$HOME/.local/bin:$PATH"'
    } >> "$rc"
  fi
}

ensure_editor_env() {
  local rc="$1"
  [[ -f "$rc" ]] || touch "$rc"
  if ! grep -qs 'oci-setup: default editor' "$rc"; then
    {
      echo ''
      echo '# Added by oci-setup: default editor'
      echo 'export EDITOR="emacs"'
      echo 'export VISUAL="emacs"'
    } >> "$rc"
  fi
}

# ---------------------------------------------------------------------------
# 7c. tmux session persistence (survives reboot)
#     Two parts:
#       (a) Restore session *contents* — tmux-resurrect (manual save/restore)
#           plus tmux-continuum, which auto-saves on a timer and auto-restores
#           the last environment whenever the tmux server starts.
#       (b) Restart the tmux *server at boot* — a systemd user service plus
#           linger, so the server (and therefore the continuum restore) comes
#           back automatically after a reboot without anyone logging in.
# ---------------------------------------------------------------------------
setup_tmux() {
  if ! have tmux; then
    warn "tmux not installed; skipping tmux persistence setup."
    return
  fi
  log "Configuring tmux session persistence (survives reboot)..."

  # (a) plugins: tpm (loader) + resurrect (save/restore) + continuum (auto)
  install_tmux_plugin tpm            https://github.com/tmux-plugins/tpm
  install_tmux_plugin tmux-resurrect https://github.com/tmux-plugins/tmux-resurrect
  install_tmux_plugin tmux-continuum https://github.com/tmux-plugins/tmux-continuum
  ensure_tmux_conf

  # (b) bring the server back at boot
  install_tmux_boot_service

  ok "tmux persistence configured (resurrect + continuum + boot service)."
}

install_tmux_plugin() {  # install_tmux_plugin <name> <git-url>
  local name="$1" url="$2" dir="$HOME/.tmux/plugins/$1"
  if [[ -d "$dir/.git" ]]; then
    ok "tmux plugin '$name' already present."
    return
  fi
  # A previous run interrupted mid-clone can leave a non-empty dir without
  # .git; git refuses to clone into it. Clear that partial state first.
  [[ -d "$dir" ]] && rm -rf "$dir"
  if git clone --depth 1 "$url" "$dir" >/dev/null 2>&1; then
    ok "tmux plugin '$name' installed."
  else
    warn "Could not clone tmux plugin '$name' from $url."
  fi
}

ensure_tmux_conf() {
  local conf="$HOME/.tmux.conf"
  [[ -f "$conf" ]] || touch "$conf"
  if grep -qs 'oci-setup tmux persistence' "$conf"; then
    ok "~/.tmux.conf already has the persistence block."
    return
  fi
  cat >> "$conf" <<'EOF'

# >>> oci-setup tmux persistence >>>
# Save/restore tmux sessions across restarts and full reboots.
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @resurrect-capture-pane-contents 'on'
set -g @continuum-restore 'on'
set -g @continuum-save-interval '15'
run '~/.tmux/plugins/tpm/tpm'
# <<< oci-setup tmux persistence <<<
EOF
  ok "Added persistence block to ~/.tmux.conf."
}

install_tmux_boot_service() {
  local unit_dir="$HOME/.config/systemd/user" unit
  unit="$unit_dir/tmux.service"
  local tmux_bin; tmux_bin="$(command -v tmux)"
  mkdir -p "$unit_dir"
  # Notes on the unit:
  #   - No `After=network-online.target`: that is a *system* target and is not
  #     visible to the per-user `systemd --user` manager, so it would be inert.
  #     tmux needs no network anyway.
  #   - ExecStart uses a default session name (not `-s main`): tmux-resurrect's
  #     restore cleans up the bootstrap session only when it is the default "0",
  #     so a named session would linger empty after the restore.
  #   - ExecStop saves first (best-effort, `-` prefix), so a clean reboot keeps
  #     the very latest state instead of only the last 15-min continuum auto-save.
  cat > "$unit" <<EOF
[Unit]
Description=tmux server (oci-setup: start at boot, restore last session)
Documentation=man:tmux(1)

[Service]
Type=forking
ExecStart=$tmux_bin new-session -d
ExecStop=-$tmux_bin run-shell '%h/.tmux/plugins/tmux-resurrect/scripts/save.sh'
ExecStop=$tmux_bin kill-server
Restart=on-failure
KillMode=none

[Install]
WantedBy=default.target
EOF
  ok "Wrote systemd user unit: $unit"

  # Enable lingering so the user service runs at boot without an active login,
  # then enable the unit. Best-effort: a container without systemd as PID 1
  # rejects these — that's fine, the unit file is in place for a real OCI boot.
  # Record a marker ONLY when we flip linger off->on, so uninstall can reverse
  # exactly what we changed (linger is account-level shared state).
  if have loginctl; then
    local linger_prior
    linger_prior="$($SUDO loginctl show-user "$USER" --property=Linger --value 2>/dev/null || echo unknown)"
    if $SUDO loginctl enable-linger "$USER" >/dev/null 2>&1; then
      ok "Enabled linger for '$USER' (user services run at boot)."
      if [[ "$linger_prior" == "no" ]]; then
        mkdir -p "$HOME/.config/oci-setup"
        : > "$HOME/.config/oci-setup/linger.marker"
      fi
    else
      warn "Could not enable linger now (no systemd here?); applies on a real OCI boot."
    fi
  fi
  if have systemctl; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if systemctl --user enable tmux.service >/dev/null 2>&1; then
      ok "Enabled tmux.service (user)."
    else
      warn "Could not enable tmux.service now (no systemd here?); on the server run: systemctl --user enable --now tmux.service"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "Starting OCI instance setup (arch: $ARCH)"
  install_base_packages
  install_git_gh
  install_node
  install_emacs
  set_default_editor
  install_claude_code
  install_codex
  install_antigravity
  install_zsh
  setup_aliases
  setup_prompt
  setup_tmux

  echo
  ok "Setup complete."
  echo
  log "Next steps:"
  echo "  1. Log out and back in (or run 'exec zsh') to pick up zsh + PATH."
  echo "  2. Authenticate the tools:"
  echo "       claude        # opens browser login flow"
  echo "       codex         # opens ChatGPT/OpenAI login flow"
  echo "       agy           # Antigravity CLI — follow its login flow"
  echo "       gh auth login # authenticate GitHub CLI"
  echo "  3. Verify: git --version ; gh --version ; tmux -V ; claude --version ; codex --version ; agy --version ; emacs --version"
  echo "       echo \$EDITOR   # -> emacs (default editor)"
  echo "  4. tmux now survives reboot: the systemd user service restarts the"
  echo "       server at boot and continuum restores your last session."
  echo "       Enable it now without a reboot: systemctl --user enable --now tmux.service"
}

main "$@"

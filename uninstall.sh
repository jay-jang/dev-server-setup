#!/usr/bin/env bash
#
# uninstall.sh — Reverse what setup.sh installed on an OCI Ubuntu instance.
#
# Removes: Claude Code, OpenAI Codex, Antigravity (agy), Emacs, GitHub CLI,
#          Node.js (NodeSource), tmux, zsh + oh-my-zsh; reverts the default
#          shell to bash and the default editor to the system auto choice;
#          strips the PATH/EDITOR/alias lines setup.sh added to your shell rc files.
#
# Conservative by default:
#   - Base/system packages (curl, wget, git, ca-certificates, gnupg, unzip,
#     xz-utils, build-essential) are KEPT unless REMOVE_BASE=1.
#   - App data dirs (~/.claude, ~/.codex, Antigravity cache) are REMOVED;
#     set KEEP_DATA=1 to keep your logins/config.
#   - Does NOT touch firewall, SSH, or networking.
#
# Usage:
#   chmod +x uninstall.sh
#   ./uninstall.sh                 # prompts for confirmation
#
# Options (env vars):
#   ASSUME_YES=1   skip the confirmation prompt
#   KEEP_DATA=1    keep ~/.claude(.json), ~/.codex, Antigravity cache/config
#   REMOVE_BASE=1  also apt-remove the base/system packages listed above
#   KEEP_NODE=1    keep Node.js (and the NodeSource apt repo)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers (match setup.sh)
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
# Pre-flight
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  SUDO=""
else
  have sudo || { err "sudo not found and not running as root."; exit 1; }
  SUDO="sudo"
fi
have apt-get || { err "apt-get not found. This script targets Ubuntu/Debian."; exit 1; }
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if [[ "${ASSUME_YES:-0}" != "1" ]]; then
  warn "This will uninstall the dev tools set up by setup.sh for user '$USER'."
  [[ "${KEEP_DATA:-0}" == "1" ]] || warn "App data (~/.claude, ~/.codex, Antigravity cache) will also be removed."
  # Read the answer from the terminal even when the script itself arrives on
  # stdin (e.g. `curl … | bash`). If there is no terminal at all, refuse rather
  # than silently destroying things — pass ASSUME_YES=1 for unattended runs.
  if [[ -t 0 ]]; then
    read -r -p "Proceed? [y/N] " ans
  elif { exec 3</dev/tty; } 2>/dev/null; then
    read -r -p "Proceed? [y/N] " ans <&3
    exec 3<&-
  else
    err "No terminal for confirmation. Re-run with ASSUME_YES=1 to proceed unattended."
    exit 1
  fi
  case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "Aborted."; exit 0 ;; esac
fi

apt_remove() {  # apt_remove <pkg...> — purge if installed
  local to_go=()
  local p
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 && to_go+=("$p")
  done
  if [[ ${#to_go[@]} -gt 0 ]]; then
    $SUDO apt-get purge -y "${to_go[@]}"
  fi
}

# ---------------------------------------------------------------------------
# 1. AI CLIs (user-local: claude, codex, agy)
# ---------------------------------------------------------------------------
remove_ai_clis() {
  log "Removing Claude Code, Codex, and Antigravity (agy)..."
  rm -f "$HOME/.local/bin/claude" "$HOME/.local/bin/codex" "$HOME/.local/bin/agy"
  rm -rf "$HOME/.local/share/claude"
  if [[ "${KEEP_DATA:-0}" != "1" ]]; then
    rm -rf "$HOME/.claude" "$HOME/.claude.json" \
           "$HOME/.codex" \
           "$HOME/.cache/antigravity" "$HOME/.config/antigravity" "$HOME/.antigravity"
    ok "AI CLIs and their data removed."
  else
    ok "AI CLI binaries removed (data kept: KEEP_DATA=1)."
  fi
}

# ---------------------------------------------------------------------------
# 2. Revert default editor (undo set_default_editor)
# ---------------------------------------------------------------------------
revert_editor() {
  log "Reverting default editor..."
  if have update-alternatives; then
    $SUDO update-alternatives --auto editor >/dev/null 2>&1 || true
  fi
  if have git; then
    git config --global --get core.editor >/dev/null 2>&1 \
      && git config --global --unset core.editor || true
  fi
  ok "Editor reverted (EDITOR/VISUAL rc lines stripped below; 'editor' alt -> auto)."
}

# ---------------------------------------------------------------------------
# 3. Emacs
# ---------------------------------------------------------------------------
remove_emacs() {
  log "Removing Emacs..."
  apt_remove emacs emacs-nox emacs-gtk emacs-common
  ok "Emacs removed."
}

# ---------------------------------------------------------------------------
# 4. GitHub CLI (gh) + apt repo/keyring
# ---------------------------------------------------------------------------
remove_github_cli() {
  log "Removing GitHub CLI (gh) and its apt repo..."
  apt_remove gh
  $SUDO rm -f /etc/apt/sources.list.d/github-cli.list \
              /etc/apt/keyrings/githubcli-archive-keyring.gpg
  ok "GitHub CLI removed."
}

# ---------------------------------------------------------------------------
# 5. Node.js (NodeSource) + apt repo/keyring
# ---------------------------------------------------------------------------
remove_nodejs() {
  if [[ "${KEEP_NODE:-0}" == "1" ]]; then
    ok "Keeping Node.js (KEEP_NODE=1)."
    return
  fi
  log "Removing Node.js (NodeSource) and its apt repo..."
  apt_remove nodejs
  $SUDO rm -f /etc/apt/sources.list.d/nodesource.list \
              /etc/apt/keyrings/nodesource.gpg
  ok "Node.js removed."
}

# ---------------------------------------------------------------------------
# 6. tmux
# ---------------------------------------------------------------------------
remove_tmux() {
  log "Removing tmux and its persistence setup..."

  # Boot service + linger (best-effort; no-op without systemd as PID 1).
  systemctl --user disable --now tmux.service >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/tmux.service"
  # Only disable linger if *we* turned it on (marker written by setup). Linger
  # is account-level shared state; other user services may rely on it.
  if [[ -f "$HOME/.config/oci-setup/linger.marker" ]]; then
    have loginctl && $SUDO loginctl disable-linger "$USER" >/dev/null 2>&1 || true
    rm -f "$HOME/.config/oci-setup/linger.marker"
    rmdir "$HOME/.config/oci-setup" 2>/dev/null || true
  fi

  # Plugins (tpm + resurrect + continuum); drop ~/.tmux/plugins if now empty.
  rm -rf "$HOME/.tmux/plugins/tpm" \
         "$HOME/.tmux/plugins/tmux-resurrect" \
         "$HOME/.tmux/plugins/tmux-continuum"
  rmdir "$HOME/.tmux/plugins" 2>/dev/null || true

  # Strip the persistence block from ~/.tmux.conf; remove the file if empty.
  if [[ -f "$HOME/.tmux.conf" ]] && grep -qs 'oci-setup tmux persistence' "$HOME/.tmux.conf"; then
    sed -i '/>>> oci-setup tmux persistence >>>/,/<<< oci-setup tmux persistence <<</d' "$HOME/.tmux.conf"
    grep -q '[^[:space:]]' "$HOME/.tmux.conf" || rm -f "$HOME/.tmux.conf"
  fi

  # Saved session state (treat like other app data).
  if [[ "${KEEP_DATA:-0}" != "1" ]]; then
    rm -rf "$HOME/.local/share/tmux/resurrect" "$HOME/.tmux/resurrect"
  fi
  rmdir "$HOME/.tmux" 2>/dev/null || true

  apt_remove tmux
  ok "tmux and persistence setup removed."
}

# ---------------------------------------------------------------------------
# 7. Revert shell to bash, remove oh-my-zsh, remove zsh
# ---------------------------------------------------------------------------
revert_shell_and_zsh() {
  log "Reverting default shell to bash and removing zsh/oh-my-zsh..."
  # Prefer the conventional /bin/bash (Ubuntu's default login shell path).
  local bash_path
  if [[ -x /bin/bash ]]; then bash_path=/bin/bash; else bash_path="$(command -v bash || echo /bin/bash)"; fi
  if [[ "$(getent passwd "$USER" | cut -d: -f7)" != "$bash_path" ]]; then
    $SUDO chsh -s "$bash_path" "$USER" \
      && ok "Default shell reverted to bash (effective next login)." \
      || warn "Could not chsh; run: chsh -s $bash_path"
  fi
  rm -rf "$HOME/.oh-my-zsh"
  # oh-my-zsh backs up the prior .zshrc as .zshrc.pre-oh-my-zsh — restore if present
  if [[ -f "$HOME/.zshrc.pre-oh-my-zsh" ]]; then
    mv -f "$HOME/.zshrc.pre-oh-my-zsh" "$HOME/.zshrc"
  fi
  apt_remove zsh
  ok "zsh and oh-my-zsh removed."
}

# ---------------------------------------------------------------------------
# 8. Strip the PATH / EDITOR / alias lines setup.sh appended to shell rc files
# ---------------------------------------------------------------------------
strip_rc_lines() {
  log "Stripping oci-setup lines from shell rc files..."
  local rc
  for rc in "$HOME/.zshenv" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [[ -f "$rc" ]] || continue
    local tmp; tmp="$(mktemp)"
    grep -vF \
      -e '# Added by oci-setup: user-local binaries (claude, codex, etc.)' \
      -e 'export PATH="$HOME/.local/bin:$PATH"' \
      -e '# Added by oci-setup: default editor' \
      -e 'export EDITOR="emacs"' \
      -e 'export VISUAL="emacs"' \
      -e '# Added by oci-setup: aliases' \
      -e 'alias e="emacs"' \
      -e 'alias ll="ls -al"' \
      -e 'alias ucc="claude --dangerously-skip-permissions"' \
      -e '# Added by oci-setup: custom prompt' \
      -e "PROMPT='%n@%~%% '" \
      -e "PS1='\u@\w\$ '" \
      "$rc" > "$tmp" && mv "$tmp" "$rc"
  done
  ok "rc files cleaned."
}

# ---------------------------------------------------------------------------
# 9. Optionally remove base/system packages
# ---------------------------------------------------------------------------
maybe_remove_base() {
  if [[ "${REMOVE_BASE:-0}" != "1" ]]; then
    warn "Keeping base packages (curl, git, build-essential, …). Set REMOVE_BASE=1 to purge."
    return
  fi
  log "Removing base/system packages (REMOVE_BASE=1)..."
  apt_remove build-essential gnupg unzip xz-utils wget git
  warn "Kept ca-certificates and curl (removing them can break apt/TLS)."
  ok "Base packages removed."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "Starting uninstall for user '$USER'"
  remove_ai_clis
  revert_editor
  remove_emacs
  remove_github_cli
  remove_nodejs
  remove_tmux
  revert_shell_and_zsh
  strip_rc_lines
  maybe_remove_base

  log "Running apt autoremove..."
  $SUDO apt-get autoremove -y || true
  $SUDO apt-get update -y || true

  echo
  ok "Uninstall complete."
  echo
  log "Notes:"
  echo "  - Open a new shell (or log out/in) so the reverted shell/PATH take effect."
  echo "  - ~/.local/bin is left in place (it may hold other tools)."
  [[ "${KEEP_DATA:-0}" == "1" ]] && echo "  - App data was kept (KEEP_DATA=1)."
  [[ "${REMOVE_BASE:-0}" == "1" ]] || echo "  - Base packages were kept (run with REMOVE_BASE=1 to purge)."
}

main "$@"

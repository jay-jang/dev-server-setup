#!/usr/bin/env bash
# Round-trip test: mimic a fresh OCI Ubuntu instance, run setup.sh, then
# uninstall.sh, then assert the dev tools are gone and shell/editor reverted.
# Run INSIDE an arm64 ubuntu container with the repo mounted at /setup.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq sudo passwd ca-certificates curl >/dev/null

id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu
[ -d /home/ubuntu ] || { mkdir -p /home/ubuntu && chown ubuntu:ubuntu /home/ubuntu; }
echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-ubuntu
chmod 0440 /etc/sudoers.d/90-ubuntu

cp /setup/setup.sh /home/ubuntu/setup.sh
cp /setup/uninstall.sh /home/ubuntu/uninstall.sh
chown ubuntu:ubuntu /home/ubuntu/setup.sh /home/ubuntu/uninstall.sh
chmod +x /home/ubuntu/setup.sh /home/ubuntu/uninstall.sh

echo "=== STEP 1: setup.sh ==="
su - ubuntu -c 'cd ~ && ./setup.sh'

echo
echo "=== STEP 2: uninstall.sh (ASSUME_YES) ==="
su - ubuntu -c 'cd ~ && ASSUME_YES=1 ./uninstall.sh'

echo
echo "=== STEP 3: assert clean state ==="
su - ubuntu -c '
fail=0
check_gone() {  # check_gone <label> <cmd>
  if command -v "$2" >/dev/null 2>&1 || [ -x "$HOME/.local/bin/$2" ]; then
    echo "  ✗ $1 still present"; fail=1
  else
    echo "  ✓ $1 removed"
  fi
}
check_gone "claude" claude
check_gone "codex"  codex
check_gone "agy"    agy
check_gone "emacs"  emacs
check_gone "gh"     gh
check_gone "node"   node
check_gone "tmux"   tmux
check_gone "zsh"    zsh

echo "  --- tmux persistence removed ---"
check_path_gone() {  # check_path_gone <label> <path>
  if [ -e "$2" ]; then echo "  ✗ $1 remains ($2)"; fail=1; else echo "  ✓ $1 removed"; fi
}
check_path_gone "tmux.conf block / file" "$HOME/.tmux.conf"
check_path_gone "tmux plugins dir"       "$HOME/.tmux/plugins"
check_path_gone "tmux systemd user unit" "$HOME/.config/systemd/user/tmux.service"
check_path_gone "resurrect saved state"  "$HOME/.local/share/tmux/resurrect"

echo "  --- reverted state ---"
sh="$(getent passwd ubuntu | cut -d: -f7)"
case "$sh" in /bin/bash|/usr/bin/bash) echo "  ✓ login shell back to bash ($sh)" ;; *) echo "  ✗ login shell is $sh"; fail=1 ;; esac
[ -d "$HOME/.oh-my-zsh" ] && { echo "  ✗ ~/.oh-my-zsh remains"; fail=1; } || echo "  ✓ oh-my-zsh removed"
ed="$(git config --global --get core.editor || echo unset)"
[ "$ed" = "unset" ] && echo "  ✓ git core.editor unset" || echo "  ✗ git core.editor=$ed"

echo "  --- data dirs (default: removed) ---"
for d in .claude .codex .cache/antigravity; do
  [ -e "$HOME/$d" ] && { echo "  ✗ ~/$d remains"; fail=1; } || echo "  ✓ ~/$d removed"
done

echo "  --- rc lines stripped ---"
if grep -rqsF "Added by oci-setup" "$HOME/.zshenv" "$HOME/.bashrc" "$HOME/.zshrc" 2>/dev/null; then
  echo "  ✗ oci-setup rc lines remain"; fail=1
else
  echo "  ✓ oci-setup rc lines stripped"
fi

echo
[ "$fail" = 0 ] && echo "ROUND-TRIP RESULT: PASS" || echo "ROUND-TRIP RESULT: FAIL"
exit $fail
'

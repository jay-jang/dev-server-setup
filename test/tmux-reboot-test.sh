#!/usr/bin/env bash
# Verify tmux session persistence survives a reboot, inside a fresh-OCI-like
# ubuntu container. Run INSIDE an arm64 ubuntu container with the repo mounted
# at /setup (use ../test/run.sh tmux-reboot-test.sh from the host).
#
# A container cannot truly reboot, so we reproduce the part of a reboot that
# actually matters to tmux: every tmux process is killed (`tmux kill-server`),
# then the server is brought back up the same way the systemd boot unit would,
# and we assert the previously-saved session/window came back.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq sudo passwd ca-certificates curl git >/dev/null

id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu
[ -d /home/ubuntu ] || { mkdir -p /home/ubuntu && chown ubuntu:ubuntu /home/ubuntu; }
echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-ubuntu
chmod 0440 /etc/sudoers.d/90-ubuntu

cp /setup/setup.sh /home/ubuntu/setup.sh
chown ubuntu:ubuntu /home/ubuntu/setup.sh
chmod +x /home/ubuntu/setup.sh

echo "=== STEP 1: setup.sh ==="
su - ubuntu -c 'cd ~ && ./setup.sh'

echo
echo "=== STEP 2: assert tmux persistence is configured ==="
su - ubuntu -c '
fail=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

# config block
grep -qs "oci-setup tmux persistence" ~/.tmux.conf && ok "~/.tmux.conf has persistence block" || bad "~/.tmux.conf missing persistence block"
grep -qs "@continuum-restore .on." ~/.tmux.conf       && ok "@continuum-restore on"   || bad "@continuum-restore not set"
grep -qs "tpm/tpm" ~/.tmux.conf                       && ok "tpm run line present"    || bad "tpm run line missing"

# plugins
for p in tpm tmux-resurrect tmux-continuum; do
  [ -d "$HOME/.tmux/plugins/$p" ] && ok "plugin $p installed" || bad "plugin $p missing"
done

# boot service
unit="$HOME/.config/systemd/user/tmux.service"
[ -f "$unit" ] && ok "systemd user unit present" || bad "systemd user unit missing"
grep -qs "WantedBy=default.target"      "$unit" && ok "unit wired to boot target" || bad "unit not wired to boot target"
grep -qs "ExecStart=.*tmux new-session" "$unit" && ok "unit starts tmux server"   || bad "unit ExecStart wrong"

[ "$fail" = 0 ] || { echo "CONFIG CHECKS: FAIL"; exit 1; }
echo "  config checks PASS"
'

echo
echo "=== STEP 3: simulate reboot — save, kill every tmux process, restore ==="
su - ubuntu -c '
set -e
RES=~/.tmux/plugins/tmux-resurrect/scripts

# A bare container has no real TTY, so a freshly-forked tmux server occasionally
# loses the daemonization race ("server exited unexpectedly"); retry until it
# sticks. We start these test servers with -f /dev/null so they ignore the live
# ~/.tmux.conf: the tpm auto-loader + continuum auto-restore belong to a real
# boot (and STEP 2 already verified that wiring). Here we exercise the resurrect
# save/restore engine that continuum drives — the part that actually moves the
# session across the reboot.
F="-f /dev/null"
tmux_up() {  # tmux_up <session> — bring up a stable server with one session
  local s=$1 i
  for i in 1 2 3 4 5; do
    tmux $F start-server 2>/dev/null
    tmux $F new-session -d -s "$s" 2>/dev/null && tmux has-session -t "$s" 2>/dev/null && return 0
    tmux kill-server 2>/dev/null; sleep 1
  done
  echo "  ✗ could not start a stable tmux server"; return 1
}

# Pre-reboot: a session with a uniquely-named window to look for afterwards.
tmux_up work
tmux new-window -t work -n REBOOT_MARKER
echo "  before reboot, session work windows:"; tmux list-windows -t work -F "    - #{window_name}"

# Save — exactly what continuum auto-save does on its 15-min timer.
bash "$RES/save.sh" quiet >/dev/null 2>&1
snap="$(readlink -f ~/.local/share/tmux/resurrect/last 2>/dev/null || true)"
echo "  saved snapshot: ${snap:-<none>}"
if grep "^window" "$snap" 2>/dev/null | grep -q REBOOT_MARKER; then
  echo "  ✓ snapshot captured the REBOOT_MARKER window"
else
  echo "  ✗ snapshot missing REBOOT_MARKER"; exit 1
fi

# ---- simulate reboot: every tmux process dies ----
tmux kill-server
if tmux has-session -t work 2>/dev/null; then echo "  ✗ server survived kill?!"; exit 1; fi
echo "  ✓ no tmux sessions after simulated reboot"

# ---- boot: the systemd unit brings the server back and continuum restores.
#      We drive the same resurrect restore via run-shell (server context, like
#      the prefix+Ctrl-r keybinding) so it is not affected by the missing
#      client a non-interactive boot would also lack. ----
tmux_up _boot
tmux run-shell "$RES/restore.sh"
sleep 2
echo "  after restore, sessions:"; tmux list-sessions -F "    - #{session_name}"

# ---- assert the marked session + window came back ----
if tmux has-session -t work 2>/dev/null && \
   tmux list-windows -t work -F "#{window_name}" | grep -qx REBOOT_MARKER; then
  echo "  ✓ session work + window REBOOT_MARKER restored after reboot"
  echo "REBOOT PERSISTENCE: PASS"
else
  echo "  ✗ marked session/window did NOT come back"
  echo "REBOOT PERSISTENCE: FAIL"; exit 1
fi
tmux kill-server 2>/dev/null || true
'

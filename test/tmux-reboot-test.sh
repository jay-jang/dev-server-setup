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
# uses a default-named session so resurrect can clean up the bootstrap session
grep -q -- "new-session -d -s main" "$unit" && bad "unit still hardcodes -s main (resurrect cleanup will leave it)" || ok "unit uses default session name"
# saves the latest state on stop, not just the last 15-min continuum auto-save
grep -qs "ExecStop=.*save.sh" "$unit" && ok "unit saves session state on stop" || bad "unit has no save-on-stop"
# network-online.target is a system target, inert in a --user manager
grep -qs "network-online.target" "$unit" && bad "unit references inert network-online.target" || ok "no inert network-online.target dependency"

[ "$fail" = 0 ] || { echo "CONFIG CHECKS: FAIL"; exit 1; }
echo "  config checks PASS"
'

echo
echo "=== STEP 3: simulate reboot — save, kill every tmux process, auto-restore ==="
su - ubuntu -c '
set -e
RES=~/.tmux/plugins/tmux-resurrect/scripts

# A bare container has no real TTY, so a freshly-forked tmux server occasionally
# loses the daemonization race ("server exited unexpectedly"); retry until it
# sticks. $TCONF selects the config: "-f /dev/null" for the throwaway server
# that just seeds a snapshot, and "" (the real ~/.tmux.conf) for the boot server
# so tpm + continuum load and trigger the real auto-restore.
TCONF=""
up() {  # up [session-name] — bring up a stable server (named, or default "0")
  local i name="${1:-}"
  for i in 1 2 3 4 5 6 7 8; do
    tmux $TCONF start-server 2>/dev/null
    if [ -n "$name" ]; then tmux $TCONF new-session -d -s "$name" 2>/dev/null
    else                    tmux $TCONF new-session -d 2>/dev/null; fi
    tmux list-sessions >/dev/null 2>&1 && return 0
    tmux kill-server 2>/dev/null; sleep 1
  done
  echo "  ✗ could not start a stable tmux server"; return 1
}

# ---- pre-reboot: seed a snapshot on a throwaway server (ignore live config) ----
TCONF="-f /dev/null"
up work
tmux new-window -t work -n REBOOT_MARKER
tmux set-option -g @resurrect-capture-pane-contents off
echo "  before reboot, session work windows:"; tmux list-windows -t work -F "    - #{window_name}"
bash "$RES/save.sh" quiet >/dev/null 2>&1   # what continuum auto-save writes on its timer
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

# ---- boot: start the server EXACTLY as the systemd unit does — default session
#      name, real ~/.tmux.conf, NO attached client, NO manual restore. continuum
#      must auto-restore on server start by itself. ----
TCONF=""
up   # default-named bootstrap session, like ExecStart=tmux new-session -d
restored=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 2
  tmux has-session -t work 2>/dev/null && { restored=1; break; }
done
echo "  sessions after headless boot: [$(tmux list-sessions -F "#{session_name}" 2>/dev/null | tr "\n" " ")]"

if [ "$restored" = 1 ] && tmux list-windows -t work -F "#{window_name}" 2>/dev/null | grep -qx REBOOT_MARKER; then
  echo "  ✓ continuum AUTO-restored work+REBOOT_MARKER headlessly (no client, no manual restore)"
else
  echo "  ✗ continuum did not auto-restore on headless boot"
  echo "REBOOT PERSISTENCE: FAIL"; exit 1
fi

# resurrect cleans up the default bootstrap session ("0") during restore; with a
# default-named ExecStart it should be gone, leaving only the restored sessions.
if tmux has-session -t 0 2>/dev/null; then
  echo "  ✗ leftover empty bootstrap session 0 remains"
  echo "REBOOT PERSISTENCE: FAIL"; exit 1
else
  echo "  ✓ bootstrap session cleaned up (no leftover empty session)"
fi

echo "REBOOT PERSISTENCE: PASS"
tmux kill-server 2>/dev/null || true
'

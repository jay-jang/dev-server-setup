#!/usr/bin/env bash
# Container bootstrap: mimic a fresh OCI Ubuntu instance (non-root 'ubuntu'
# user with passwordless sudo), then run ../setup.sh as that user.
# Intended to be run INSIDE an arm64 ubuntu container with the repo mounted
# at /setup. See test/run.sh for the host-side launcher.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq sudo passwd ca-certificates curl >/dev/null

# Ubuntu 24.04 base images ship a pre-created 'ubuntu' user (UID 1000); reuse it.
id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu
[ -d /home/ubuntu ] || { mkdir -p /home/ubuntu && chown ubuntu:ubuntu /home/ubuntu; }
echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-ubuntu
chmod 0440 /etc/sudoers.d/90-ubuntu

cp /setup/setup.sh /home/ubuntu/setup.sh
chown ubuntu:ubuntu /home/ubuntu/setup.sh
chmod +x /home/ubuntu/setup.sh

echo "=== running setup.sh as user 'ubuntu' ==="
su - ubuntu -c 'cd ~ && ./setup.sh'

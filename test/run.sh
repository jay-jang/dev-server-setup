#!/usr/bin/env bash
# Host-side launcher: run one of the in-container test scripts inside a fresh
# arm64 Ubuntu container with the repo mounted read-only at /setup.
#
#   ./test/run.sh                      # default: docker-test.sh
#   ./test/run.sh tmux-reboot-test.sh  # pick a specific in-container script
#   ./test/run.sh uninstall-test.sh
#   IMAGE=ubuntu:22.04 ./test/run.sh   # override base image
#   PLATFORM=linux/amd64 ./test/run.sh # override platform (default linux/arm64)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
script="${1:-docker-test.sh}"
image="${IMAGE:-ubuntu:24.04}"
platform="${PLATFORM:-linux/arm64}"

[ -f "$here/$script" ] || { echo "no such test script: $here/$script" >&2; exit 1; }

echo "=== running test/$script in $image ($platform) ==="
exec docker run --rm --platform "$platform" \
  -v "$repo":/setup:ro \
  "$image" \
  bash "/setup/test/$script"

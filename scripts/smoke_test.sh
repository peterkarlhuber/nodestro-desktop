#!/usr/bin/env bash
# Clean-machine smoke test: the packaged app in a fresh Ubuntu 24.04 container that has no Python, Node.js,
# Rust or Docker, only WebKitGTK and a virtual display.
#
#   scripts/smoke_test.sh <nodestro-linux-x86_64.tar.gz>
#
# Passes when the window opened the studio with the launch secret (launch answered, studio API calls 200,
# no 401/403), the token is not in the log, other clients are refused, and quitting leaves no process.
set -euo pipefail
archive=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
here=$(cd "$(dirname "$0")" && pwd)
docker run --rm ${DOCKER_NETWORK:+--network "$DOCKER_NETWORK"} -e http_proxy -e https_proxy -e HTTP_PROXY -e HTTPS_PROXY \
  -v "$archive:/tmp/nodestro.tar.gz:ro" -v "$here/smoke_inside.sh:/tmp/smoke_inside.sh:ro" \
  ubuntu:24.04 bash /tmp/smoke_inside.sh

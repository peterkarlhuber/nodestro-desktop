#!/usr/bin/env bash
# Runs inside the clean container of smoke_test.sh (as root first, the app as an ordinary user).
set -euo pipefail
if [ "${1:-}" = as-user ]; then
  cd ~
  start=$(date +%s)
  # NODESTRO_APP and NODESTRO_SMOKE_DISPLAY (xvfb or wayland: an existing Wayland session) let the VM tests reuse this.
  launcher=(xvfb-run -a)
  if [ "${NODESTRO_SMOKE_DISPLAY:-xvfb}" = wayland ]; then launcher=(); fi
  NODESTRO_DESKTOP_QUIT_AFTER_MS=20000 "${launcher[@]}" "${NODESTRO_APP:-/opt/nodestro/nodestro-desktop}" >app.out 2>&1 &
  app=$!
  log=~/.local/share/org.nodestro.desktop/logs/backend.log
  until grep -q "backend ready on port" app.out 2>/dev/null; do
    sleep 0.2
    if [ $(( $(date +%s) - start )) -gt 120 ]; then echo "backend not ready"; cat app.out "$log" || true; exit 1; fi
  done
  port=$(sed -n "s/.*backend ready on port \([0-9]*\).*/\1/p" app.out)
  # A failed check below ends the script silently (set -e): show which one and the backend log.
  # shellcheck disable=SC2329 # invoked by the EXIT trap
  show_log() {
    local status=$?
    if [ "$status" != 0 ]; then echo "smoke check failed; backend log:"; cat "$log" || true; fi
  }
  trap show_log EXIT
  # Another program on this computer: no session, no launch.
  test "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port/api/workflows")" = 401
  test "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port/api/health")" = 200
  wait "$app"
  cat app.out
  grep -q "backend stopped" app.out
  grep -q "GET /api/launch?token=\[redacted\] HTTP/1.1\" 200" "$log"
  grep -q "GET /api/settings HTTP/1.1\" 200" "$log"
  grep -q "GET /api/workflows HTTP/1.1\" 200" "$log"
  # Only the curl probe above may have been refused.
  test "$(grep -c "\" 401" "$log")" = 1
  if grep -q "\" 403" "$log"; then echo "a request was refused with 403"; exit 1; fi
  if grep -Eq "token=[0-9a-f]{64}" "$log"; then echo "the launch token is in the log"; exit 1; fi
  if grep -q Traceback "$log"; then echo "the backend logged a traceback"; exit 1; fi
  grep -q "Application shutdown complete" "$log"
  exit 0
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends libwebkit2gtk-4.1-0 xvfb xauth curl procps ca-certificates >/dev/null
for tool in python3 node cargo docker; do
  if command -v "$tool" >/dev/null; then
    echo "not a clean machine: $tool is installed" >&2
    exit 1
  fi
done
useradd --create-home person
tar -xzf /tmp/nodestro.tar.gz -C /opt
su person -s /bin/bash -c "bash /tmp/smoke_inside.sh as-user"
if pgrep -f nodestro_studio >/dev/null; then
  echo "a backend process was left behind" >&2
  exit 1
fi
echo "smoke test passed"

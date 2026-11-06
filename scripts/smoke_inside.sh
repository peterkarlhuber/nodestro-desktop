#!/usr/bin/env bash
# Runs inside the clean container of smoke_test.sh (as root first, the app as an ordinary user).
set -euo pipefail

# Amazon Bedrock on a computer without AWS credentials: Settings lists it as not configured, and no AWS endpoint is
# contacted. The bundled backend is started directly with a launch secret of this script (the window's secret never
# leaves the shell), its outgoing HTTPS goes to a listener that records every connection, and the studio's Settings
# are read with the session of that secret.
bedrock_check() {
  local python=/opt/nodestro/backend/python/bin/python3 secret port data listener calls cookies settings
  [ -n "${NODESTRO_APP:-}" ] && python="$(dirname "$NODESTRO_APP")/backend/python/bin/python3"
  secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  port=$("$python" -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  data=$(mktemp -d) calls=$(mktemp) cookies=$(mktemp) settings=$(mktemp)
  "$python" -I -c 'import socket, sys
server = socket.socket(); server.bind(("127.0.0.1", 0)); server.listen(16)
print(server.getsockname()[1], flush=True)
with open(sys.argv[1], "a") as calls:
    while True:
        connection, _ = server.accept()
        calls.write(connection.recv(512).split(b"\r\n", 1)[0].decode(errors="replace") + "\n"); calls.flush()
        connection.close()' "$calls" > "$data/listener.port" &
  listener=$!
  until [ -s "$data/listener.port" ]; do sleep 0.1; done
  printf '{"launch_secret":"%s","vault_key":null}' "$secret" | env -u AWS_PROFILE -u AWS_REGION -u AWS_ACCESS_KEY_ID \
    -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN HOME="$data" AWS_EC2_METADATA_DISABLED=true \
    HTTPS_PROXY="http://127.0.0.1:$(cat "$data/listener.port")" HTTP_PROXY="http://127.0.0.1:$(cat "$data/listener.port")" \
    NO_PROXY=127.0.0.1,localhost \
    "$python" -I -m nodestro_studio --no-browser --host 127.0.0.1 --port "$port" --secrets-fd 0 --data-dir "$data/nodestro" \
    > "$data/backend.log" 2>&1 &
  local backend=$! waited=0
  until curl -fs "http://127.0.0.1:$port/api/health" >/dev/null; do
    sleep 0.5; waited=$((waited + 1))
    if [ "$waited" -gt 120 ]; then echo "bedrock check: backend not ready"; cat "$data/backend.log"; return 1; fi
  done
  curl -fs -c "$cookies" -o /dev/null "http://127.0.0.1:$port/api/launch?token=$secret"
  curl -fs -b "$cookies" "http://127.0.0.1:$port/api/settings" > "$settings"
  kill -INT "$backend"; wait "$backend" || true
  kill "$listener" 2>/dev/null || true
  "$python" -I - "$settings" "$calls" <<'PY'
import json, sys
providers = {item["id"]: item for item in json.load(open(sys.argv[1]))["providers"]}
bedrock = providers.get("bedrock")
assert bedrock, f"Settings lists no Amazon Bedrock: {sorted(providers)}"
assert bedrock["configured"] is False, bedrock
state = (bedrock.get("verification") or {}).get("state", "not_configured")
assert state == "not_configured" and (bedrock.get("verification") or {}).get("checked_at") is None, bedrock
calls = [line for line in open(sys.argv[2]).read().splitlines() if line.strip()]
aws = [line for line in calls if "amazonaws.com" in line or "169.254.169.254" in line]
assert not aws, f"the backend contacted AWS: {aws}"
hosts = sorted({line.split()[1] for line in calls if len(line.split()) > 1})
print(f"bedrock check passed: not_configured, no AWS call (other outgoing requests: {', '.join(hosts) or 'none'})")
PY
}

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
  # The studio rendered a page: the workflow list, or the welcome page a fresh installation opens on.
  grep -Eq "GET /(api/workflows|assets/WelcomePage-[^ ]*\.js) HTTP/1.1\" 200" "$log"
  # Only the curl probe above may have been refused.
  test "$(grep -c "\" 401" "$log")" = 1
  if grep -q "\" 403" "$log"; then echo "a request was refused with 403"; exit 1; fi
  if grep -Eq "token=[0-9a-f]{64}" "$log"; then echo "the launch token is in the log"; exit 1; fi
  if grep -q Traceback "$log"; then echo "the backend logged a traceback"; exit 1; fi
  grep -q "Application shutdown complete" "$log"
  bedrock_check
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
# The bundled local model runtime runs on the clean machine (its client prints the version; it starts no server).
/opt/nodestro/backend/ollama/bin/ollama --version 2>&1 | grep -q "0\.40\.14" || { echo "the bundled Ollama does not run" >&2; exit 1; }
su person -s /bin/bash -c "bash /tmp/smoke_inside.sh as-user"
if pgrep -f nodestro_studio >/dev/null; then
  echo "a backend process was left behind" >&2
  exit 1
fi
echo "smoke test passed"

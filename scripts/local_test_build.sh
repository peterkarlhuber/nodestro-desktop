#!/usr/bin/env bash
# A local, unsigned TEST build of Nodestro Desktop from the pinned state, and its smoke check (macOS and Linux).
#
#   scripts/local_test_build.sh [work-dir]               build the shell and the backend, stage the app, test it
#   scripts/local_test_build.sh --test-only [work-dir]   test the app already staged in work-dir
#   scripts/local_test_build.sh --build-only [work-dir]  build and stage only (CI builds with a token, tests without)
#
# work-dir defaults to ./local-test (ignored by git). It never signs, notarizes, uploads or publishes anything and
# never touches ~/.nodestro or the keychain: the tests use their own data directories in work-dir, and the app gets a
# random test vault key (a canary, not a credential) through NODESTRO_VAULT_KEY instead of the keychain.
# Prerequisites and the expected results are in docs/testing.md.
#
# Part 1, the app: the window starts the bundled backend (on Linux without a display under xvfb-run), quits by itself
# after QUIT_AFTER_MS (default 30000), and the backend's command line, environment and standard input, the log, the
# access checks and the shutdown are checked.
# Part 2, the backend's API (the same bundled interpreter, started the way the shell starts it, with a secret this
# script hands over on standard input): the sandbox status, Docker detection and self-test, a tool a person wrote (runs
# on the host), then the same tool after a backup restore, where it counts as untrusted (like AI-generated code): it
# must run only in an approved sandbox and otherwise be refused (fail closed).
# Results and diagnostics (no credentials; checked for the test secrets) go to work-dir/diagnostics.
# DOCKER_HOST=unix:///nonexistent tests the case without Docker.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
build=1
test=1
if [ "${1:-}" = --test-only ]; then
  build=0
  shift
elif [ "${1:-}" = --build-only ]; then
  test=0
  shift
fi
work=${1:-$here/local-test}
# The script deletes folders inside work-dir (backend, nodestro, data-*, tmp, diagnostics), so it uses only a missing or
# empty folder or one it made itself (the marker file), never an arbitrary folder such as the home folder.
if [ -d "$work" ] && [ ! -e "$work/.nodestro-local-test" ] && [ -n "$(ls -A "$work" 2>/dev/null)" ]; then
  echo "work-dir $work is not empty and was not made by this script; choose another one" >&2
  exit 2
fi
mkdir -p "$work"
touch "$work/.nodestro-local-test"
work=$(cd "$work" && pwd)
app="$work/nodestro"
diag="$work/diagnostics"
os=$(uname -s)

if [ "$build" = 1 ]; then
  for tool in cargo uv node npm git python3 curl; do
    command -v "$tool" >/dev/null || { echo "missing prerequisite: $tool (see docs/testing.md)" >&2; exit 1; }
  done
  echo "== build the shell (cargo build --release --locked)"
  (cd "$here/app" && cargo build --release --locked)
  echo "== build the backend from studio $(sed -n 's/.*"nodestro-studio": "\([0-9a-f]*\)".*/\1/p' "$here/studio.json")"
  "$here/scripts/build_backend.sh" "$work/backend"
  echo "== stage the app in $app"
  rm -rf "$app"
  mkdir -p "$app/backend"
  cp "$here/app/target/release/nodestro-desktop" "$app/nodestro-desktop"
  cp -a "$work/backend/python" "$app/backend/python"
  echo "local-test-$(git -C "$here" rev-parse --short HEAD)" >"$app/VERSION"
  # The token that read the private components (CI) must not end up in the app, e.g. in a direct_url.json.
  if grep -rIl -e "x-access-token" "$app" >/dev/null 2>&1; then
    echo "the staged app contains 'x-access-token' (a clone credential): not used" >&2
    exit 1
  fi
fi
py="$app/backend/python/bin/python3"
[ -x "$app/nodestro-desktop" ] && [ -x "$py" ] || { echo "no staged app in $app (run without --test-only)" >&2; exit 1; }
if [ "$test" = 0 ]; then
  echo "staged in $app (test with --test-only)"
  exit 0
fi

rm -rf "$diag" "$work/data-app" "$work/data-api" "$work/tmp"
mkdir -p "$diag" "$work/tmp"
chmod 700 "$work/tmp"
passed=0
failed=0
check() { # $1: what, $2: 0 for passed
  if [ "$2" = 0 ]; then
    passed=$((passed + 1))
    echo "  PASS  $1"
  else
    failed=$((failed + 1))
    echo "  FAIL  $1"
  fi
}
ok() { if "$@"; then echo 0; else echo 1; fi; } # 0 when the command succeeds
http() { curl -s -o /dev/null -w "%{http_code}" "$@" || true; }
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() { [ -n "${api_pid:-}" ] && kill "$api_pid" 2>/dev/null; rm -rf "$work/tmp"; }
trap cleanup EXIT

case "$os" in
  Darwin) log_dir="$HOME/Library/Logs/org.nodestro.desktop" ;;
  *) log_dir="${XDG_DATA_HOME:-$HOME/.local/share}/org.nodestro.desktop/logs" ;;
esac
log="$log_dir/backend.log"
# Process details of the backend: its command line, its initial environment, what its standard input is.
proc_args() { if [ -r "/proc/$1/cmdline" ]; then tr '\0' ' ' <"/proc/$1/cmdline"; else ps -ww -o command= -p "$1"; fi; }
proc_env() { if [ -r "/proc/$1/environ" ]; then tr '\0' '\n' <"/proc/$1/environ"; else ps -E -ww -o command= -p "$1"; fi; }
proc_stdin() { if [ -e "/proc/$1/fd/0" ]; then readlink "/proc/$1/fd/0"; else lsof -a -p "$1" -d 0 -Fn 2>/dev/null | sed -n 's/^n//p'; fi; }
docker_containers() { { docker ps -aq --no-trunc 2>/dev/null || true; } | sort; }

{
  echo "system: $(uname -srm)"
  if [ "$os" = Darwin ]; then sw_vers 2>/dev/null || true; else grep -E '^(PRETTY_NAME)=' /etc/os-release 2>/dev/null || true; fi
  echo "app: $(cat "$app/VERSION" 2>/dev/null || echo unknown), desktop commit $(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "studio pin: $(sed -n 's/.*"nodestro-studio": "\([0-9a-f]*\)".*/\1/p' "$here/studio.json")"
  echo "user: uid $(id -u)"
  echo "DOCKER_HOST: ${DOCKER_HOST:-(not set)}"
  if command -v docker >/dev/null; then
    docker version --format 'docker client {{.Client.Version}}, server {{.Server.Version}} ({{.Server.Os}}/{{.Server.Arch}})' 2>&1 | head -n 3 || true
    docker info --format 'cgroup {{.CgroupVersion}}, driver {{.CgroupDriver}}, security {{.SecurityOptions}}' 2>&1 | head -n 3 || true
  else
    echo "docker: no docker command"
  fi
} >"$diag/system.txt"
cat "$diag/system.txt"
containers_before=$(docker_containers)
touch "$work/tmp/started"

echo "== part 1: the app window and its backend"
canary=$("$py" -I -c 'import base64, os; print(base64.b64encode(os.urandom(32)).decode())')
# 1 (failed) when $1 holds the test vault key or a 64-hex value (the launch secret's form) that is not already in
# this script's own environment (which the shell and the backend inherit).
inherited=$(env | grep -Eo '[0-9a-f]{64}' || true)
holds_secret() {
  local new
  new=$(grep -Eo '[0-9a-f]{64}' <<<"$1" | grep -vxF -e "${inherited:-none}" || true)
  if grep -Fq -- "$canary" <<<"$1" || [ -n "$new" ]; then
    echo 1
  else
    echo 0
  fi
}
mkdir -p "$log_dir"
offset=1
if [ -f "$log" ]; then offset=$(($(wc -l <"$log") + 1)); fi
launcher=()
if [ "$os" = Linux ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then launcher=(xvfb-run -a); fi
start=$(date +%s)
NODESTRO_DATA_DIR="$work/data-app" NODESTRO_VAULT_KEY="$canary" NODESTRO_DESKTOP_QUIT_AFTER_MS="${QUIT_AFTER_MS:-30000}" \
  ${launcher[@]+"${launcher[@]}"} "$app/nodestro-desktop" >"$diag/app.out" 2>&1 &
app_pid=$!
until grep -q "backend ready on port" "$diag/app.out" 2>/dev/null; do
  sleep 0.2
  if ! kill -0 "$app_pid" 2>/dev/null || [ $(($(date +%s) - start)) -gt 120 ]; then
    echo "the backend did not become ready:"
    cat "$diag/app.out"
    exit 1
  fi
done
port=$(sed -n "s/.*backend ready on port \([0-9]*\).*/\1/p" "$diag/app.out")
sed -n 's/.*\(backend ready on port .*\)/  \1/p' "$diag/app.out"
backend_pid=$(pgrep -f -- "nodestro_studio --no-browser --host 127.0.0.1 --port $port" | head -n 1 || true)
check "the backend process runs (pid ${backend_pid:-none})" "$(ok [ -n "$backend_pid" ])"
args=$(proc_args "$backend_pid")
environment=$(proc_env "$backend_pid")
echo "  backend command line: $args"
check "the backend was started with --secrets-fd 0" "$(ok grep -q -e "--secrets-fd 0" <<<"$args")"
check "no secret on the backend's command line (no 64-hex value, not the vault key)" "$(holds_secret "$args")"
check "no secret in the backend's environment (no NODESTRO_LAUNCH_SECRET or NODESTRO_VAULT_KEY, no value)" \
  "$(if grep -Eq "NODESTRO_(LAUNCH_SECRET|VAULT_KEY)" <<<"$environment"; then echo 1; else holds_secret "$environment"; fi)"
stdin=$(proc_stdin "$backend_pid")
check "the backend's standard input is the null device after the handoff ($stdin)" "$(ok [ "$stdin" = /dev/null ])"
check "another program gets 401 from the studio API" "$(ok [ "$(http "http://127.0.0.1:$port/api/workflows")" = 401 ])"
check "/api/health answers 200" "$(ok [ "$(http "http://127.0.0.1:$port/api/health")" = 200 ])"
wait "$app_pid" || true
tail -n +"$offset" "$log" >"$diag/backend-app.log" 2>/dev/null || true
check "the window closed and stopped the backend" "$(grep -q "backend stopped" "$diag/app.out"; echo $?)"
check "no backend process left behind" "$(pgrep -f -- "nodestro_studio --no-browser --host 127.0.0.1 --port $port" >/dev/null && echo 1 || echo 0)"
check "the window opened the studio with the launch secret (launch 200, token redacted)" \
  "$(grep -q 'GET /api/launch?token=\[redacted\] HTTP/1.1" 200' "$diag/backend-app.log"; echo $?)"
check "the studio called its API (GET /api/settings 200)" "$(grep -q 'GET /api/settings HTTP/1.1" 200' "$diag/backend-app.log"; echo $?)"
check "only the probe above was refused (one 401, no 403)" \
  "$([ "$(grep -c '" 401' "$diag/backend-app.log")" = 1 ] && ! grep -q '" 403' "$diag/backend-app.log"; echo $?)"
check "the backend shut down cleanly (Application shutdown complete)" \
  "$(grep -q "Application shutdown complete" "$diag/backend-app.log"; echo $?)"
check "no traceback in the backend log" "$(grep -q Traceback "$diag/backend-app.log" && echo 1 || echo 0)"

echo "== part 2: sandbox, Docker detection and tools (backend API)"
api_port=$("$py" -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
secret=$("$py" -I -c 'import secrets; print(secrets.token_hex(32))')
api="http://127.0.0.1:$api_port/api"
jar="$work/tmp/cookies"
# printf is a shell builtin: the secret is never on a command line; curl reads its URL from standard input.
printf '{"launch_secret":"%s","vault_key":null}' "$secret" |
  "$py" -I -m nodestro_studio --no-browser --host 127.0.0.1 --port "$api_port" --secrets-fd 0 \
    --data-dir "$work/data-api" >"$diag/backend-api.log" 2>&1 &
api_pid=$!
start=$(date +%s)
until [ "$(http "$api/health")" = 200 ]; do
  sleep 0.3
  if ! kill -0 "$api_pid" 2>/dev/null || [ $(($(date +%s) - start)) -gt 120 ]; then
    echo "the backend did not start:"
    cat "$diag/backend-api.log"
    exit 1
  fi
done
launch=$(printf 'url = "%s/launch?token=%s"\n' "$api" "$secret" | curl -s -K - -c "$jar" -o /dev/null -w "%{http_code}" || true)
check "launch with the handed-over secret gives a session (HTTP $launch)" "$(ok [ "$launch" = 200 ])"
check "the handed-over secret is not in that backend's command line or environment" \
  "$(if grep -Fq -- "$secret" <<<"$(proc_args "$api_pid"; proc_env "$api_pid")"; then echo 1; else echo 0; fi)"
check "that backend's standard input is the null device ($(proc_stdin "$api_pid"))" "$(ok [ "$(proc_stdin "$api_pid")" = /dev/null ])"
get() { curl -s -b "$jar" "$@"; }
json() { "$py" -I -c "import json, sys; d = json.load(open(sys.argv[1])); $2" "$1"; }
get "$api/sandbox/status?wait=5" >"$diag/sandbox-status.json"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ "$(json "$diag/sandbox-status.json" 'print(d.get("state"))')" = checking ] || break
  get "$api/sandbox/status?wait=5" >"$diag/sandbox-status.json"
done
json "$diag/sandbox-status.json" '
print("  docker:", d["state"], "reason:", d.get("reason") or "-", "engine:", d.get("engine"), "cgroup:", d.get("cgroup_version"),
      "rootless:", d.get("rootless"))
for c in d.get("checks") or []:
    print("    check", c["name"], "ok" if c["ok"] else "FAILED", c.get("detail") or "")
print("  detail:", d.get("detail"))'
check "the Docker status settled (not still checking)" "$(ok [ "$(json "$diag/sandbox-status.json" 'print(d.get("state"))')" != checking ])"
get -X POST "$api/sandbox/self-test" >"$diag/sandbox-self-test.json"
json "$diag/sandbox-self-test.json" 'print("  self-test again:", d.get("state"), d.get("reason") or "-")'
get "$api/settings" >"$work/tmp/settings.json"
"$py" -I -c 'import json, sys; d = json.load(open(sys.argv[1]))
json.dump({k: d.get(k) for k in ("sandbox", "sandbox_selection", "builtin_sandbox")}, open(sys.argv[2], "w"), indent=1)' \
  "$work/tmp/settings.json" "$diag/settings-sandbox.json"
json "$diag/settings-sandbox.json" '
s = d["sandbox_selection"]
print("  selection:", "mode", s["mode"], "os", s["os"], s["arch"], "| AI-generated code:", s["untrusted"] or "BLOCKED",
      "| user-authored code:", s["user_authored"] or "-")
print("  reason:", s.get("reason") or "-", "|", s.get("detail") or "")
b = d.get("builtin_sandbox") or {}
print("  built-in Linux sandbox:", "available" if b.get("available") else "not available", b.get("reason") or "")'
blocked=$(json "$diag/settings-sandbox.json" 'print("yes" if d["sandbox_selection"]["blocked"] else "no")')
get "$api/tools/template" >"$work/tmp/tool.json"
saved=$(get -H "content-type: application/json" -d @"$work/tmp/tool.json" "$api/tools" | "$py" -I -c 'import json, sys; d = json.load(sys.stdin); print(d["check"]["ok"], (d.get("tool") or {}).get("trust"))')
check "a tool written in the editor is saved and its tests pass ($saved)" "$(ok [ "$saved" = "True user-authored" ])"
run() { get -H "content-type: application/json" -d '{"input": {"celsius": 100}}' -w '\n%{http_code}' "$api/tools/celsius_to_fahrenheit/run"; }
answer=$(run)
echo "  user-authored run: $(echo "$answer" | tr '\n' ' ')"
check "the user-authored tool runs (100 C = 212.0 F)" "$(echo "$answer" | grep -q '"output":"212.0"'; echo $?)"
# A restored backup can come from anywhere: its tools count as untrusted, exactly like AI-generated ones (ADR-0006).
get -o "$work/tmp/backup.zip" "$api/backup"
backup_id=$(get -F file=@"$work/tmp/backup.zip" "$api/backup/inspect" | "$py" -I -c 'import json, sys; print(json.load(sys.stdin)["id"])')
get -H "content-type: application/json" -d "{\"id\": \"$backup_id\", \"confirm\": true}" "$api/backup/restore" >/dev/null
trust=$(get "$api/tools/celsius_to_fahrenheit" | "$py" -I -c 'import json, sys; print(json.load(sys.stdin)["trust"])')
check "after the restore the tool counts as untrusted ($trust)" "$(ok [ "$trust" = untrusted ])"
answer=$(run)
echo "$answer" >"$diag/untrusted-run.txt"
echo "  untrusted run: $(echo "$answer" | tr '\n' ' ')"
if [ "$blocked" = yes ]; then
  check "AI-generated (untrusted) code is refused without an approved sandbox (400 sandbox.isolation_required)" \
    "$(echo "$answer" | tail -n 1 | grep -q 400 && echo "$answer" | grep -q '"code":"sandbox.isolation_required"'; echo $?)"
else
  check "untrusted code runs in the approved sandbox (212.0)" "$(echo "$answer" | grep -q '"output":"212.0"'; echo $?)"
fi
kill -INT "$api_pid"
for _ in $(seq 1 50); do kill -0 "$api_pid" 2>/dev/null || break; sleep 0.2; done
check "the backend stops on SIGINT within 10 s" "$(kill -0 "$api_pid" 2>/dev/null && echo 1 || echo 0)"
api_pid=
sleep 1
check "the API backend shut down cleanly" "$(grep -q "Application shutdown complete" "$diag/backend-api.log"; echo $?)"
new_containers=$(docker_containers | grep -vxF -e "${containers_before:-none}" || true)
check "no Docker container left behind ${new_containers:+($new_containers)}" "$(ok [ -z "$new_containers" ])"
leftovers=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'nodestro-*' -newer "$work/tmp/started" 2>/dev/null | head -n 5)
# macOS: WebKit (the window's WKWebView) creates $TMPDIR/<executable>/WebKit/... itself. Such a directory holding
# only empty WebKit directories is the system's, not ours; anything else in it (a file) still fails the check.
if [ "$os" = Darwin ] && [ -n "$leftovers" ]; then
  kept=""
  while IFS= read -r item; do
    if [ "$(basename "$item")" = nodestro-desktop ] && [ -z "$(find "$item" -type f 2>/dev/null | head -n 1)" ] &&
      [ -z "$(find "$item" -mindepth 1 -maxdepth 1 ! -name WebKit 2>/dev/null | head -n 1)" ]; then
      echo "  info  $item holds only WebKit's own empty directories (created by macOS for the window)"
    else
      kept="${kept:+$kept
}$item"
    fi
  done <<<"$leftovers"
  leftovers=$kept
fi
if [ -n "$leftovers" ]; then
  # Name, size and age only, never contents: enough to tell what created them.
  while IFS= read -r item; do find "$item" -maxdepth 2 -exec ls -ld {} \; 2>/dev/null; done <<<"$leftovers" |
    head -n 20 | sed 's/^/    /'
fi
check "no temporary nodestro-* files left in ${TMPDIR:-/tmp} ${leftovers:+($leftovers)}" "$(ok [ -z "$leftovers" ])"
check "the diagnostics hold neither test secret" \
  "$(grep -rqF -e "$secret" -e "$canary" "$diag" && echo 1 || echo 0)"
echo "== $passed passed, $failed failed; diagnostics in $diag"
[ "$failed" = 0 ]

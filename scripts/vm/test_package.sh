#!/usr/bin/env bash
# Inside the test machine, as the normal user: test the packaged desktop app (the release archive as built by CI).
#
#   bash test_package.sh sandbox   unpack ~/nodestro-linux-x86_64.tar.gz into ~/nodestro, then run the built-in
#                                  sandbox's security probes and compatibility checks with the app's own bundled
#                                  interpreter and runtime (nothing from the system); prints the report to probes.json
#   bash test_package.sh gui       start the app in a virtual X display (Xvfb) and check the studio opened
#   bash test_package.sh gnome     start the app in a headless GNOME Shell (Wayland) session and check the same
#   bash test_package.sh keychain  start the app twice in a D-Bus session with an unlocked GNOME Keyring and check
#                                  that the MCP token vault key is created there once and reused (never printed)
#
# The sandbox step needs ~/test-wheels (numpy for the compiled-library check, pydantic for the tool runner, and a
# pip wheel used only to fill the test environment: the app ships no pip).
set -euo pipefail
cd "$HOME"
app="$HOME/nodestro"
py="$app/backend/python/bin/python3"

smoke() { # $1: how the window is shown
  rm -f "$HOME/.local/share/org.nodestro.desktop/logs/backend.log" # the checks count this start's requests only
  NODESTRO_APP="$app/nodestro-desktop" NODESTRO_SMOKE_DISPLAY="$1" bash "$HOME/smoke_inside.sh" as-user
  if pgrep -u "$(id -u)" -f nodestro_studio >/dev/null; then
    echo "a backend process was left behind" >&2
    exit 1
  fi
  echo "packaged app ($1): passed"
}

case "${1:-}" in
  sandbox)
    rm -rf "$app" && tar -xzf nodestro-linux-x86_64.tar.gz -C "$HOME"
    cat "$app/VERSION"
    for tool in python3 python node nodejs rustc cargo docker bwrap; do
      printf 'on PATH: %-8s %s\n' "$tool" "$(command -v "$tool" || echo no)"
    done
    rm -rf "$HOME/env"
    "$py" -I -m venv --without-pip "$HOME/env"
    pip_wheel=$(ls "$HOME"/test-wheels/pip-*.whl)
    install=("$HOME/env/bin/python" "$pip_wheel/pip" install --quiet --no-index --find-links "$HOME/test-wheels")
    "${install[@]}" --require-hashes -r "$HOME/test-wheels/compiled-library.txt"
    "${install[@]}" pydantic typing-extensions
    set +e
    "$py" -I -m nodestro_runtime.sandbox_probes --env-python "$HOME/env/bin/python" --json >probes.json
    code=$?
    "$py" -I -c '
import json
d = json.load(open("probes.json"))
print(json.dumps(d["status"]))
for r in d["results"]:
    print(("PASS" if r["passed"] else "FAIL"), r["area"], r["name"], r["error"])
    if not r["passed"] or r["area"] == "performance" or r["name"] == "compiled-library":
        for k, v in r["detail"].items():
            print("      ", k, v)
print(sum(r["passed"] for r in d["results"]), "of", len(d["results"]), "passed")
'
    exit $code
    ;;
  gui)
    smoke xvfb
    # No Secret Service on this machine: the app must say that MCP tokens are kept for the session only (D-3).
    grep -q "keychain not usable" app.out
    echo "without a keychain: MCP tokens are kept for the session only"
    ;;
  keychain)
    # shellcheck disable=SC2016 # expanded by the inner shell
    exec dbus-run-session -- bash -c '
      eval "$(printf "vm\n" | gnome-keyring-daemon --unlock --components=secrets)"
      bash "$0" keychain-inside
    ' "$0"
    ;;
  keychain-inside)
    lookup() { secret-tool lookup service Nodestro username mcp-token-vault-key 2>/dev/null || true; }
    test -z "$(lookup)" # a fresh keyring holds no key yet
    smoke xvfb
    if grep -q "keychain not usable" app.out; then echo "the app did not use the unlocked keychain"; cat app.out; exit 1; fi
    first=$(lookup | sha256sum)
    test "$(lookup | wc -c)" -ge 32 # a key was stored (its value is never printed)
    smoke xvfb
    if grep -q "keychain not usable" app.out; then echo "the second start did not use the keychain"; exit 1; fi
    test "$(lookup | sha256sum)" = "$first" # the same key is reused
    echo "with an unlocked keychain: the vault key is stored once and reused"
    ;;
  gnome)
    export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    # shellcheck disable=SC2016 # expanded by the inner shell
    exec dbus-run-session -- bash -c '
      gnome-shell --headless --wayland --no-x11 --virtual-monitor 1280x800 >"$HOME/gnome-shell.log" 2>&1 &
      shell=$!
      for _ in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break; sleep 0.3; done
      if [ ! -S "$XDG_RUNTIME_DIR/wayland-0" ]; then echo "GNOME Shell did not start"; tail -30 "$HOME/gnome-shell.log"; exit 1; fi
      echo "GNOME Shell $(gnome-shell --version 2>/dev/null) is running (Wayland, headless)"
      export WAYLAND_DISPLAY=wayland-0 XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME
      set +e
      bash "$0" gnome-inside
      code=$?
      kill "$shell" 2>/dev/null
      exit $code
    ' "$0"
    ;;
  gnome-inside)
    smoke wayland
    ;;
  *)
    echo "usage: test_package.sh sandbox|gui|gnome|keychain" >&2; exit 2 ;;
esac

# Local test builds

How to build an **unsigned local test app** of Nodestro Desktop from the pinned state (`app/` and `studio.json` at
the checked-out commit) and check it by hand or with `scripts/local_test_build.sh`. Nothing here signs, notarizes,
uploads or publishes anything; the result is for testing on the machine that built it. Releases are described in the
README.

## Which platform can be built where

| Target | Where it can be built | State |
| --- | --- | --- |
| Linux x86_64 | Linux x86_64 (CI: Ubuntu 24.04) | built and tested in CI (`ci.yml`, `systems.yml`) and by `local_test_build.sh` |
| macOS arm64 (Apple silicon) | on a Mac with Apple silicon | never built; `local_test_build.sh` is written for it, not yet run on a Mac |
| macOS x86_64 (Intel) | on an Intel Mac (each Mac builds its own architecture) | never built |
| Windows x64, ARM64 | on Windows (MSVC toolchain) | never built; no script (see [Windows](#windows-not-run)) |

Cross-building is not a way around this:

- **macOS from Linux** does not work: even `cargo check --target aarch64-apple-darwin` fails on Linux, because the
  shell's dependencies compile Objective-C (`objc2-exception-helper`) with Apple's toolchain and the macOS SDK, which
  are only available on a Mac. The backend is a macOS build of CPython plus macOS wheels, and the app has to run on
  macOS to be tested anyway.
- **Windows from Linux**: `cargo check --target x86_64-pc-windows-msvc` passes (the shell type-checks for Windows),
  but linking needs the MSVC libraries and Windows SDK, `scripts/build_backend.sh` assumes the POSIX layout of the
  interpreter (`python/bin/python3`), and the result can only be tested on Windows.
- **CI** builds only Linux. No workflow builds a macOS or Windows bundle, not even as an unpublished artifact
  (`runs-on` is `ubuntu-*` in every workflow; DSK-004).

## macOS and Linux: `scripts/local_test_build.sh`

### Prerequisites

| | macOS | Linux (Debian, Ubuntu) |
| --- | --- | --- |
| Compiler, SDK | Xcode Command Line Tools: `xcode-select --install` | `build-essential`, `libwebkit2gtk-4.1-dev`, `libssl-dev`, `librsvg2-dev`, `libxdo-dev` |
| Rust (stable, with cargo) | `rustup` from <https://rustup.rs> | same |
| Node.js 22 with npm (build-time only) | for example `brew install node@22` | same version |
| uv (CI uses 0.13.1) | `brew install uv` or `pip3 install --user uv==0.13.1` | same |
| git, curl, python3 | from the Command Line Tools (any python3 3.9 or newer; it only reads `studio.json`) | system packages |
| Display | a logged-in desktop session (the window opens for about 30 s) | a session, or `xvfb-run` (package `xvfb`) |
| Docker (optional) | Docker Desktop, OrbStack, Colima or Podman | Docker Engine |
| Disk, time | about 4 GB (Rust build directory, npm, backend), 10 to 25 minutes the first time | same |

The backend gets its own CPython 3.13 from uv (python-build-standalone); the Python on the build machine is not
bundled. The studio and every component are fetched at the commits `studio.json` pins (public repositories).

### Commands

```sh
git clone https://github.com/peterkarlhuber/nodestro-desktop.git
cd nodestro-desktop
git checkout <commit or branch to test>
scripts/local_test_build.sh                 # build, stage in ./local-test, test (with Docker if it runs)
DOCKER_HOST=unix:///nonexistent scripts/local_test_build.sh --test-only   # the same app, Docker unreachable
local-test/nodestro/nodestro-desktop        # start the test app by hand (uses ~/.nodestro)
```

`--test-only` tests the app already staged in `local-test/` without building again. The tests use their own data
directories in `local-test/` (never `~/.nodestro`) and give the app a random test vault key through
`NODESTRO_VAULT_KEY`, so the keychain is not touched. To test the keychain as well, start the app by hand (see the
table, item 3). The script ends with `N passed, 0 failed` and exit code 0 when everything passed.

Behind a TLS-inspecting proxy, Docker's sandbox image build needs the proxy's certificate authority:
`NODESTRO_BUILD_CA_FILE=<ca.pem>` (or `SSL_CERT_FILE`), otherwise the Docker status says `docker-image`.

### What is tested and what to expect

| # | Test item | How | Expected on Linux (run) | Expected on macOS (not run yet) |
| --- | --- | --- | --- | --- |
| 1 | App start | part 1: the window starts, its log says `backend ready on port <n> after <ms> ms`, it quits by itself after 30 s (`QUIT_AFTER_MS`) | passes under `xvfb-run` | the window opens for 30 s and closes; same checks |
| 2 | Embedded backend | part 1: the backend is `backend/python/bin/python3 -I -m nodestro_studio … --secrets-fd 0`; `/api/health` 200; the window's launch is `200` with the token `[redacted]` in the log, `GET /api/settings` 200 | passes | same |
| 3 | Secret handover | part 1: no `NODESTRO_LAUNCH_SECRET`/`NODESTRO_VAULT_KEY` and no secret value in the backend's command line (`/proc/<pid>/cmdline`; macOS `ps -ww`) or environment (`/proc/<pid>/environ`; macOS `ps -E`), its standard input is `/dev/null` after the handoff; another program gets 401. Part 2: the exact secret is in neither. The diagnostics are searched for both test secrets | passes | same (`ps -E` and `lsof` instead of `/proc`). Keychain by hand: start the app twice; the login keychain then holds one entry "Nodestro" / `mcp-token-vault-key` (Keychain Access), macOS may ask to allow access for the unsigned binary, and the app's output must not say "keychain not usable" |
| 4 | Docker detection | part 2: `GET /api/sandbox/status`: state, reason and the checks `cli`, `daemon`, `preflight`, `image`, `self-test` | with Docker: `daemon ok`, `preflight ok` | Docker Desktop: `engine docker`, `cgroup 2` expected; not verified (only Linux Docker Engine and Podman are verified in CI, ADR-0009) |
| 5 | Sandbox self-test status | part 2: the status after `POST /api/sandbox/self-test`, and `sandbox_selection` of `/api/settings` (what the Settings page shows) | on a cgroup v1 host: `unavailable`, reason `docker-selftest` ("the container is not on cgroup v2 …"), AI-generated code `BLOCKED` | `approved` if the engine passes; otherwise `unavailable` with the failed check named |
| 6 | Running an AI-generated tool | part 2: a tool written in the editor runs on the host (`212.0`); after a backup restore the same tool counts as `untrusted` (like AI-generated code, ADR-0006) and must run only in an approved sandbox, otherwise be refused with 400 `sandbox.isolation_required` | refused (fail closed) without an approved Docker | with an approved Docker engine: runs in a container (`212.0`); otherwise refused |
| 7 | Without Docker | the run with `DOCKER_HOST=unix:///nonexistent` (or Docker stopped) | reason `docker-unreachable`, AI-generated code refused, the studio itself works | same |
| 8 | Shutdown and cleanup | part 1: the shell logs `backend stopped`, no backend process remains, `Application shutdown complete`, no traceback, no 403; part 2: SIGINT stops the backend within 10 s; no new Docker container, no new `nodestro-*` entry in `$TMPDIR` | passes | same |

The built-in Linux sandbox is not used in automatic mode (Docker first, ADR-0009); `settings-sandbox.json` reports
whether it would be available. A generation job with a real model (Settings, a provider key) is not part of the
script: it needs credentials. To try it by hand, start the app, add a provider in Settings, let the assistant create
a tool, approve it, and run it from the tool editor.

### Diagnostics to send

`local-test/diagnostics/` holds everything needed and no credentials (the script fails if it finds either test
secret there): `system.txt` (OS, architecture, Docker version and cgroup version), `app.out` (the shell's output),
`backend-app.log` (this run's part of the backend log; tokens are redacted), `backend-api.log`,
`sandbox-status.json`, `sandbox-self-test.json`, `settings-sandbox.json` (only the sandbox part of the settings),
`untrusted-run.txt`, plus the script's own output. Do not send `~/.nodestro`, `~/.aws`, the keychain or screenshots
of Settings with keys. The backend log of the app is `~/Library/Logs/org.nodestro.desktop/backend.log` on macOS and
`~/.local/share/org.nodestro.desktop/logs/backend.log` on Linux.

## Windows (not run)

There is no Windows script: `scripts/build_backend.sh` assumes the POSIX interpreter layout, and nothing has been
built or run on Windows. The steps below are what a first Windows test build needs; they are **untested**.

Prerequisites: Visual Studio Build Tools with "Desktop development with C++" (MSVC, Windows SDK), WebView2 runtime
(part of Windows 11), Rust (`rustup`, target `x86_64-pc-windows-msvc` or `aarch64-pc-windows-msvc`), Node.js 22, uv,
Git for Windows, PowerShell 7.

```powershell
cd nodestro-desktop
cargo build --release --locked --manifest-path app\Cargo.toml
$studio = (Get-Content studio.json | ConvertFrom-Json).'nodestro-studio'
$work = "$PWD\local-test"; $env:PYTHONNOUSERSITE = "1"
uv python install 3.13 --install-dir "$work\pythons" --no-bin
$py = Get-ChildItem "$work\pythons" -Directory -Filter "cpython-*" | Select-Object -First 1
New-Item -ItemType Directory -Force "$work\nodestro\backend" | Out-Null
Move-Item $py.FullName "$work\nodestro\backend\python"
git clone --filter=blob:none https://github.com/peterkarlhuber/nodestro-studio.git "$work\studio"
git -C "$work\studio" checkout $studio
Push-Location "$work\studio\frontend"; npm ci; npm run build; Pop-Location
$python = "$work\nodestro\backend\python\python.exe"
& $python -m pip install build
& $python -m build --wheel --outdir "$work\dist" "$work\studio"
& $python -m pip install (Get-ChildItem "$work\dist\*.whl").FullName
& $python -I -c "import nodestro_api.launch, nodestro_studio.app"
Copy-Item app\target\release\nodestro-desktop.exe "$work\nodestro\"
$env:NODESTRO_DATA_DIR = "$work\data-app"; $env:NODESTRO_DESKTOP_QUIT_AFTER_MS = "30000"
& "$work\nodestro\nodestro-desktop.exe"
```

Check by hand while the window is open: `Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Select
ProcessId, CommandLine` shows `--secrets-fd 0` and no 64-character hex value; the log is
`%LOCALAPPDATA%\org.nodestro.desktop\logs\backend.log` (launch 200 with `[redacted]`). After the window closed, no
`python.exe` of the bundle may remain. Known from the code, to be confirmed: the backend is a console program and
may open a console window next to the app (it is started without `CREATE_NO_WINDOW`); on Windows the shell stops it
with `TerminateProcess` right away (no SIGINT), so `Application shutdown complete` is not logged and processes the
backend started are not stopped by the shell.

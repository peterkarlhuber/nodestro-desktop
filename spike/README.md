# Packaging spike (plan PR-5)

This spike measures how the Nodestro desktop app can ship without a separate Python, Node.js, PostgreSQL or
Docker installation (ADR-0005 in `nodestro-studio/docs/adr`). It is not a product: there is no launch secret, no
installer, no signing, no updater, and the shells start an unauthenticated loopback backend. The decision is
recorded in ADR-0005.

Measured on 2026-10-31 on Linux x86_64 only: Ubuntu 24.04 in a cloud container with 4 CPUs and 15 GB of memory,
Xvfb as the display, and the studio at `d9ee2d6`. **macOS and Windows were not measured.** Times are wall-clock times
of single runs after a first warm-up. They show the order of magnitude and are not benchmarks.

## What was built

| Part | How | Files |
| --- | --- | --- |
| Backend | `uv python install 3.13` (python-build-standalone 3.13.14, relocatable), studio checked out at a commit, interface built with `npm ci && npm run build`, wheel built and installed into that interpreter, pip removed | `backend/build_backend.sh` |
| Tauri 2 shell | Rust, starts the backend on a free loopback port, waits for `/api/health`, opens a system web view (WebKitGTK 4.1 on Linux), stops the backend with SIGINT on exit (kill after 10 s) | `tauri/` |
| Electron shell | the same process model in `main.js` | `electron/` |
| pywebview | installed only (`pywebview[qt]` 6.1) to measure its size and dependencies | none |

## Measurements

| Measurement | Result |
| --- | --- |
| Backend bundle (CPython 3.13 + all components + interface) | 295 MB on disk, 16,435 files; 82 MB as `tar.gz` |
| Backend start to `/api/health` 200 (bundled interpreter, empty data directory) | 1.2 to 1.8 s; 74 to 76 MB RSS |
| Backend stop with SIGINT | exit code 0, "Application shutdown complete", no process left |
| Tauri shell binary (release, stripped, LTO) | 4.3 MB (1.6 MB gzip); needs the system's WebKitGTK 4.1 (93 MB installed on Ubuntu 24.04) |
| Tauri: launch to window, including backend start | 1.8 to 1.9 s; the studio renders correctly (screenshot checked) |
| Tauri: quit | backend stopped, exit code 0, no process left |
| Tauri: release build time (cold, 4 CPUs) | 3 min 49 s |
| Electron 38.2 runtime | 286 MB on disk (110 MB `tar.gz`), bundles Chromium |
| Electron: launch to page loaded, including backend start | 1.8 to 3.0 s |
| Electron: quit | backend stopped, exit code 0, no process left |
| pywebview with Qt | 557 MB of Python packages (PyQt6 with Qt WebEngine: 538 MB); PyQt6 is GPL or commercial |
| pywebview with GTK | not built: needs PyGObject compiled against the system's GTK and WebKitGTK |

## Findings

- **A plain `pip install git+https://...nodestro-studio` has no interface:** the built frontend is not in the
  repository. The desktop build must build the frontend from the studio commit (Node.js at build time only) or use
  the wheel the studio CI uploads (`package` job, artifact `dist`). `build_backend.sh` builds it.
- The backend is the same size whatever the shell is; the shell decides the remaining size: Tauri adds 4 MB plus the
  system web view, Electron adds 286 MB.
- On Linux, Tauri depends on WebKitGTK being installed. A `.deb` can declare it as a dependency; an AppImage would
  have to bundle it (not measured). On macOS (WKWebView) and Windows (WebView2, preinstalled on Windows 10/11) the
  web view is part of the system.
- The studio's browser tests already run on WebKit (`E2E_BROWSER=webkit`); WebKitGTK rendered the studio in this
  spike, but the full suites were not run in the Tauri window.
- uvicorn's SIGTERM ends with exit code 143 after a complete application shutdown; the shells use SIGINT (exit 0).
- The private component repositories need read access at build time only (`NODESTRO_READ` in CI).

## Decision input for ADR-0005

| Criterion | Tauri 2 | Electron | pywebview |
| --- | --- | --- | --- |
| Size added to the 82 MB backend archive | ~2 MB (+ system web view) | ~110 MB | ~200 MB+ compressed (Qt) |
| Start (Linux) | 1.8 s | 1.8 to 3.0 s | not measured |
| Child process control | explicit, in Rust | explicit, in Node.js | backend in the same Python process or a subprocess |
| Rendering uniformity | system web view (differs per OS) | one Chromium everywhere | system web view (GTK) or Qt WebEngine |
| Signing, updater | built-in updater with signatures | electron-updater | none built in |
| License | MIT/Apache-2.0 | MIT | BSD; PyQt6 GPL/commercial |
| Build tooling | Rust toolchain (CI) | Node.js (CI) | Python |

Recommendation (taken into ADR-0005): **Tauri 2**, because the backend is a separate process anyway, the shell adds
almost nothing to the download, and its updater verifies signatures. Electron stays the fallback for a platform where
the system web view fails the studio's browser suites.

## Not done in the spike

Installers (`.deb`, AppImage, `.dmg`, `.msi`), code signing and notarization (no certificates), the per-launch secret
(PR-6), measurements on macOS and Windows, and running the browser suites inside the shells.

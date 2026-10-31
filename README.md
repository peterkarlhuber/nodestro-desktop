# Nodestro Desktop

Nodestro as a desktop application: the studio and its runtime with a bundled Python, without a separate Python,
Node.js, PostgreSQL or Docker installation. The architecture and plan are in
`nodestro-studio/docs/desktop-server/` (ADR-0005: desktop packaging).

Status: **Linux x86_64 preview (plan PR-6), no release yet.** macOS and Windows are not built or tested; there are no
signed builds and no installer. `spike/` holds the packaging spike (plan PR-5) and its measurements.

## How it works

| Part | Where |
| --- | --- |
| Shell (Tauri 2, Rust): window, backend start and stop, navigation guard | `app/` |
| Backend: relocatable CPython 3.13 with the studio at the commit in `studio.json` | `scripts/build_backend.sh` |
| Archive `nodestro-linux-x86_64.tar.gz` | `scripts/package_linux.sh` |
| Clean-machine smoke test (Ubuntu 24.04 container without Python, Node.js, Rust or Docker) | `scripts/smoke_test.sh` |

1. The window shows its own start page and starts `backend/python/bin/python3 -I -m nodestro_studio` on a free
   loopback port with a new 256-bit secret in `NODESTRO_LAUNCH_SECRET` (never on the command line).
2. When `/api/health` answers, the window opens `/api/launch?token=…` once. The backend exchanges it for an
   `HttpOnly`, `SameSite=Strict` session cookie (`nodestro_api.launch`); every other request without that cookie is
   refused, so other programs, other users of the computer and web pages cannot use the studio API. The token is
   redacted in the backend log.
3. The window stays on the backend's origin; links to other sites open in the system browser. The studio page gets
   no Tauri commands (`app/capabilities/default.json` grants none).
4. Closing the window stops the backend with SIGINT (the application shuts down cleanly), killed after 10 s. If the
   backend ends on its own, the window says so and names the log file.

Data stays in `~/.nodestro` (or `NODESTRO_DATA_DIR`), shared with the `nodestro` command; only one of them can use a
data directory at a time. The backend log is `~/.local/share/org.nodestro.desktop/logs/backend.log`.

## Restrictions of this preview

- Linux x86_64 only; WebKitGTK 4.1 must be installed (`libwebkit2gtk-4.1-0`).
- Not signed, no installer, no updater, no desktop menu entry.
- Without Docker, AI-generated tools cannot run (ADR-0006); the studio explains it where it matters.
- The secret reaches the backend through its environment: a process of the same OS user could read the initial
  environment, but the secret is useless once the window has used it.
- A process of the same OS user can still read the data directory itself; the launch secret protects the API, not
  the files.

## Build

```sh
(cd app && cargo build --release --locked)       # needs libwebkit2gtk-4.1-dev
scripts/build_backend.sh /tmp/backend            # needs uv, Node.js and read access to the private repositories
scripts/package_linux.sh app/target/release/nodestro-desktop /tmp/backend nodestro-linux-x86_64.tar.gz
scripts/smoke_test.sh nodestro-linux-x86_64.tar.gz   # needs Docker
```

For development, `NODESTRO_BACKEND=<path of a nodestro command>` replaces the bundled backend.

## License

MIT, see `LICENSE`.

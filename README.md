# Nodestro Desktop

Nodestro as a desktop application: the studio and its runtime with a bundled Python, without a separate Python,
Node.js, PostgreSQL or Docker installation. The architecture and plan are in
`nodestro-studio/docs/desktop-server/` (ADR-0005: desktop packaging).

Status: **Linux x86_64 unsigned preview; release candidate `v0.2.0-preview.1`, not published.** macOS and Windows are not built or tested; there are no
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

## System requirements (tested)

| Requirement | Why | Evidence |
| --- | --- | --- |
| Linux x86_64 | the only architecture built | CI and release candidate builds |
| glibc 2.39 or newer | the shell is built on Ubuntu 24.04 and needs `GLIBC_2.39` symbols | `objdump -T` of the shell |
| WebKitGTK 4.1 (`libwebkit2gtk-4.1-0` on Debian and Ubuntu), with GTK 3, libsoup 3 and their dependencies | the window | `readelf -d` of the shell, smoke test |
| A graphical session (X11 or Wayland) | the window | the smoke test uses a virtual X display (`xvfb-run`) |
| Docker (optional) | AI-generated tools run only in Docker containers (ADR-0006) | |
| About 260 MB of disk for the unpacked archive (74 MB download), plus the data directory | the bundled Python and the studio | `du` of the `v0.2.0-preview.1` candidate |

Not needed: Python, Node.js, Rust, PostgreSQL. The bundled CPython 3.13 is relocatable.

| System | State |
| --- | --- |
| Ubuntu 24.04 | clean-container smoke test in CI and in every release candidate |
| Debian 13 | clean-container smoke test, run by hand for `v0.2.0-preview.1` |
| Ubuntu 22.04 (glibc 2.35) | does not start: `GLIBC_2.39 not found` (run by hand) |
| Debian 12 (glibc 2.36) and other systems with glibc older than 2.39 | cannot start the shell (same reason; not run) |
| Fedora, Arch and other distributions | not tested |
| A real desktop session (GNOME, KDE, …), GPU drivers, HiDPI | not tested: the smoke test runs under a virtual display |
| macOS, Windows, Linux arm64 | not built |

## Restrictions of this preview

- **Licenses**: `LICENSES/` in the archive holds Nodestro's license and the license texts of the Rust crates and
  npm packages it contains; Python packages keep theirs in their `*.dist-info` directories. 5 crates and 2 npm
  packages ship no license file; their declared licenses (MIT, BSD-3-Clause, Apache-2.0 OR MIT, MPL-2.0) are listed.
- **Unsigned preview**: no build is signed; the window title and `README.txt` in the archive name the preview
  version. Not for production data.
- No installer, no updater, no desktop menu entry.
- Without Docker, AI-generated tools cannot run (ADR-0006); the studio explains it where it matters. The built-in
  sandbox prototype (nodestro-runtime `builtin_sandbox`) is not isolating and not used.
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

## Releases

A release has three separate steps. Only the last two publish anything, and each is started by a person.

1. **Candidate** (`.github/workflows/release.yml`, run by hand with the version, which must equal `app/Cargo.toml`):
   it builds and smoke-tests the archive as CI does, writes `release-manifest.json` and `SHA256SUMS` with
   `scripts/release_manifest.py`, and scans the release files for secrets with `scripts/scan_secrets.py`
   (credential formats and the build token's exact value). The run's `release-candidate` artifact holds the files.
   It creates no tag and no release, and its token can only read.
2. **Publish** (`.github/workflows/publish.yml`, run by hand with the candidate's run ID, the version and the
   confirmation `publish <version>`): it checks that the run is a passed candidate on master, the checksums and the
   manifest's version and commit, and creates a **draft pre-release** with exactly those files. Required reviewers
   for the `release` environment (repository settings) add a second approval.
3. **Release**: a person reviews the draft and publishes it; that creates the tag.

The manifest holds:

- the desktop and studio commits;
- every component pin;
- checksums;
- the license inventory of the bundled Python packages, the studio's npm packages and the shell's Rust crates;
- the channel (`preview` for a version with a pre-release part) and the signing state.

CI writes the manifest and runs the secret scan on every change (dry run).

Builds are **not signed**: no signing certificate is configured, and the manifest says so. Verify the archive with
`sha256sum -c SHA256SUMS`. Update: unpack the new archive in place of the old one; the data directory stays where it
is, and migrations back it up first. Rollback: unpack the previous archive. A data directory that a newer version
already migrated is refused by an older one (`storage.schema_too_new`); restore the pre-migration backup from
`~/.nodestro/backups/pre-migration-*.db` in that case.

## License

MIT, see `LICENSE`.

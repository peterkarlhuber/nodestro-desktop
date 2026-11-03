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
| Local model runtime: Ollama of the pinned release, checked by SHA-256 (CPU and Vulkan, no CUDA libraries) | `scripts/fetch_ollama.py` |
| Archive `nodestro-linux-x86_64.tar.gz` | `scripts/package_linux.sh` |
| Clean-machine smoke test (Ubuntu 24.04 container without Python, Node.js, Rust or Docker) | `scripts/smoke_test.sh` |
| Tests of the archive on real Ubuntu 24.04 and Debian 13 machines (KVM): built-in sandbox, window under Xvfb and in a GNOME Shell session | `.github/workflows/systems.yml`, `scripts/vm/` |

1. The window shows its own start page and starts `backend/python/bin/python3 -I -m nodestro_studio --secrets-fd 0`
   on a free loopback port with a new 256-bit secret. The secret goes through a pipe on the backend's standard input,
   never into its environment or onto its command line, which every process of the same OS user can read
   (`/proc/<pid>/environ` on Linux, `sysctl` `KERN_PROCARGS2` on macOS): the shell writes one JSON object
   `{"launch_secret": …, "vault_key": … | null}` and closes the pipe; the backend reads it first, replaces its standard
   input by the null device and keeps the values in memory only (`nodestro_api.handoff`), so no process it starts
   inherits them. `NODESTRO_LAUNCH_SECRET` and `NODESTRO_VAULT_KEY` are removed from the backend's environment.
2. When `/api/health` answers, the window opens `/api/launch?token=…` once. The backend exchanges it for an
   `HttpOnly`, `SameSite=Strict` session cookie (`nodestro_api.launch`); every other request without that cookie is
   refused, so other programs, other users of the computer and web pages cannot use the studio API. The token is
   redacted in the backend log.
3. The window stays on the backend's origin; links to other sites open in the system browser. The studio page gets
   no Tauri commands (`app/capabilities/default.json` grants none).
4. Closing the window stops the backend with SIGINT (the application shuts down cleanly), killed after 10 s. If the
   backend ends on its own, the window says so and names the log file.

**Tokens of connected MCP services** are sealed with a key from the operating system's keychain (ADR-0007 D-3; Secret
Service such as GNOME Keyring or KWallet on Linux). The first start creates the key (32 random bytes, entry
"Nodestro" / `mcp-token-vault-key`); the shell hands it to the backend in the same pipe as the launch secret, never
in its environment, on the command line, in a file or in a log (`app/src/vault.rs`). Without a usable keychain within 15 s (none
running, access refused, an unlock prompt left open) the backend gets no key and keeps tokens for the current session
only; there is no plain-text fallback. A `NODESTRO_VAULT_KEY` set by the operator for the shell takes precedence (and is handed over through the pipe as
well). If the keychain
entry is deleted, stored tokens become unreadable and have to be entered again. The packaged-app tests on Ubuntu 24.04 and Debian 13
check both cases: without a keychain (session only) and with an unlocked GNOME Keyring (key stored once, reused).

Data stays in `~/.nodestro` (or `NODESTRO_DATA_DIR`), shared with the `nodestro` command; only one of them can use a
data directory at a time. The backend log is `~/.local/share/org.nodestro.desktop/logs/backend.log`.

**Local models** run on the computer without an API key, through the bundled Ollama (`backend/ollama`, the
release pinned in `scripts/fetch_ollama.py`, the same as `orkexa.local`). `build_backend.sh` downloads its archive
(or takes `NODESTRO_OLLAMA_ARCHIVE` for an offline build), refuses it unless its SHA-256 is the pinned value from the
release's `sha256sum.txt`, and leaves out the NVIDIA CUDA libraries (about 2.4 GB; the bundle keeps the CPU and
Vulkan backends, about 120 MB). The shell passes the executable's path to the backend as `NODESTRO_OLLAMA_BINARY`
(a path, not a secret; an operator's own value is kept). nodestro-runtime starts it as a managed child process on a
free loopback port with its own home, its models in `~/.nodestro/local-models` and `OLLAMA_NO_CLOUD=1`, and never
touches an Ollama the user runs already (nodestro-runtime `docs/local-models.md`). Models are downloaded or imported
in the studio.

**Amazon Bedrock (AWS)** has no API key in Nodestro. The backend uses the AWS credentials of the user's computer:
the default chain (environment, `~/.aws/config` and `~/.aws/credentials`, AWS IAM Identity Center (SSO) after
`aws sso login`, `credential_process`) or a named profile from `~/.aws/config`, chosen in Settings together with the
region. Nodestro stores only the region, the profile name and the data residency choice, never AWS keys. When the app
is started from a desktop launcher, variables exported in a shell profile (`~/.bashrc`: `AWS_PROFILE`, `AWS_REGION`)
are not set, so choose an explicit profile name in Settings instead of relying on `AWS_PROFILE`. AI-generated tools
cannot read `~/.aws` (the built-in sandbox forbids the home directory). Network access needed: `bedrock-runtime.<region>`,
`bedrock.<region>` and `sts.<region>.amazonaws.com`, and for SSO `oidc.<region>` and `portal.sso.<region>.amazonaws.com`.
Behind a TLS-inspecting proxy, set `AWS_CA_BUNDLE` to its certificate bundle: the AWS SDK ignores `SSL_CERT_FILE`.

## System requirements (tested)

| Requirement | Why | Evidence |
| --- | --- | --- |
| Linux x86_64 | the only architecture built | CI and release candidate builds |
| glibc 2.39 or newer | the shell is built on Ubuntu 24.04 and needs `GLIBC_2.39` symbols | `objdump -T` of the shell |
| WebKitGTK 4.1 (`libwebkit2gtk-4.1-0` on Debian and Ubuntu), with GTK 3, libsoup 3 and their dependencies | the window | `readelf -d` of the shell, smoke test |
| A graphical session (X11 or Wayland) | the window | the smoke test uses a virtual X display (`xvfb-run`) |
| Linux 6.7 or newer with Landlock (ABI 4) and seccomp, started as a normal user (not root) | the built-in sandbox for AI-generated tools (ADR-0006) | `systems.yml`: Ubuntu 24.04 (kernel 6.8, Landlock ABI 4, AppArmor restricts user namespaces) and Debian 13 (kernel 6.12, ABI 6) |
| Docker (optional) | AI-generated tools on systems where the built-in sandbox is not available | |
| About 260 MB of disk for the unpacked archive (74 MB download), plus the data directory | the bundled Python and the studio | `du` of the `v0.2.0-preview.1` candidate |
| About 120 MB more for the local model runtime, plus several GB per local model; RAM for the model (8 GB or more for the smallest suggested one) | local models | `fetch_ollama.py` output; model sizes in nodestro-runtime `local_models.CATALOG` |

Not needed: Python, Node.js, Rust, PostgreSQL. The bundled CPython 3.13 is relocatable.

| System | State |
| --- | --- |
| Ubuntu 24.04 | clean-container smoke test; real machine (official cloud image in KVM, own kernel, AppArmor as shipped, normal user, Python and bubblewrap removed): built-in sandbox probes, window under Xvfb and in GNOME Shell 46 (headless Wayland); in CI and in every release candidate |
| Debian 13 | real machine as for Ubuntu 24.04 (kernel 6.12): built-in sandbox probes, window under Xvfb and in a headless GNOME Shell session; in CI and in every release candidate |
| Ubuntu 22.04 (glibc 2.35) | does not start: `GLIBC_2.39 not found` (run by hand) |
| Debian 12 (glibc 2.36) and other systems with glibc older than 2.39 | cannot start the shell (same reason; not run) |
| Fedora, Arch and other distributions | not tested |
| A desktop session on a physical screen, KDE, GPU drivers, HiDPI | not tested: GNOME Shell runs headless (virtual monitor, software rendering); KDE not tried |
| macOS, Windows, Linux arm64 | not built |

## Restrictions of this preview

- **Licenses**: `LICENSES/` in the archive holds Nodestro's license and the license texts of the Rust crates and
  npm packages it contains; Python packages keep theirs in their `*.dist-info` directories. 5 crates and 2 npm
  packages ship no license file; their declared licenses (MIT, BSD-3-Clause, Apache-2.0 OR MIT, MPL-2.0) are listed.
- **Unsigned preview**: no build is signed; the window title and `README.txt` in the archive name the preview
  version. Not for production data.
- No installer, no updater, no desktop menu entry.
- AI-generated tools run in the built-in Linux sandbox of nodestro-runtime (Landlock, seccomp and resource limits,
  applied by the tool's own process before its code is read; no network, no access to files outside the call, the
  data directory, keys or other processes). It counts as isolation only on Ubuntu 24.04 and Debian 13 (x86_64) as a
  normal user; elsewhere AI-generated tools need Docker or stay blocked, with the reason in Settings. There is no
  fallback to an unprotected process. Each tool call starts a new interpreter (about 0.13 to 0.19 s on the test
  machines).
- A process of the same OS user can still read the data directory and, with debugging rights (`ptrace`), the
  backend's memory; the secrets are no longer in any process's environment or command line, and the launch secret
  protects the API, not the files. The handoff pipe works the same on Windows (standard input), but only the Linux
  build exists and is tested.
- The keychain key is not stored next to the sealed tokens in the data directory; like the launch secret, it reaches
  the backend only through the handoff pipe (see "How it works").

## Build

```sh
(cd app && cargo build --release --locked)       # needs libwebkit2gtk-4.1-dev
scripts/build_backend.sh /tmp/backend            # needs uv, Node.js and git (the component repositories are public);
                                                 # also fetches Ollama (zstd or the Python package zstandard on Linux)
scripts/package_linux.sh app/target/release/nodestro-desktop /tmp/backend nodestro-linux-x86_64.tar.gz
scripts/smoke_test.sh nodestro-linux-x86_64.tar.gz   # needs Docker
```

For development, `NODESTRO_BACKEND=<path of a nodestro command>` replaces the bundled backend.

**Local test builds** (unsigned, never published) on Linux and macOS: `scripts/local_test_build.sh` builds the shell
and the backend from the pinned state, stages the app in `local-test/` and checks the start, the secret handover,
Docker detection, the sandbox status, refusing AI-generated code without an approved sandbox and the shutdown.
Prerequisites, expected results, the untested Windows steps and which diagnostics to send are in
[docs/testing.md](docs/testing.md).

**Logo and icons.** `branding/` holds the official Nodestro logo masters (`nodestro-logo-transparent.png`,
`nodestro-logo-white.png`, kept unchanged). `scripts/build_branding.sh` derives everything else from them with
`scripts/derive_branding.py` (the shared brand kit's script, vendored unchanged): the Tauri icons in `app/icons/`
(`32x32.png`, `128x128.png`, `128x128@2x.png`, `icon.png`, `icon.ico`, `icon.icns`, listed in `bundle.icon` of
`app/tauri.conf.json`) and the start page's logo in light and dark (`app/ui/nodestro-logo.png`,
`nodestro-logo-on-dark.png`). `icons/icon.png` (512 px) comes first in `bundle.icon` because Tauri uses the first PNG
there as the window icon on Linux. Do not edit the derived files by hand.

## Releases

A release has three separate steps. Only the last two publish anything, and each is started by a person.

1. **Candidate** (`.github/workflows/release.yml`, run by hand with the version, which must equal `app/Cargo.toml`):
   it builds and smoke-tests the archive as CI does, writes `release-manifest.json` and `SHA256SUMS` with
   `scripts/release_manifest.py`, and scans the release files for secrets with `scripts/scan_secrets.py`
   (credential formats and the build token's exact value). Then `systems.yml` tests the candidate archive, checked
   against its `SHA256SUMS`, on real Ubuntu 24.04 and Debian 13 machines. The run's `release-candidate` artifact
   holds the files. It creates no tag and no release, and its token can only read.
2. **Publish** (`.github/workflows/publish.yml`, run by hand with the candidate's run ID, the version and the
   confirmation `publish <version>`): it checks that the run is a passed candidate on master that also passed the real-system tests and is not a
   withdrawn candidate (runs 41212112554 and 41212693919, built before the built-in sandbox), the checksums and the
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

## Open work

Known gaps, follow-ups and untested platforms are listed in [docs/TODO.md](docs/TODO.md).

## License

MIT, see `LICENSE`.

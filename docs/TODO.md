# TODO: nodestro-desktop

> Open work for this repository: release blockers, known bugs, security follow-ups, technical debt and planned improvements.
> GitHub issues are the source of truth for details; this file is the entry point and summary.
>
> **Last full review:** 2026-11-07 against `master` at `5d1f35a` (TODO abatement round 6).

## Summary

| Priority | Count |
|---|---|
| P0 Critical | 0 |
| P1 High | 1 |
| P2 Medium | 3 |
| P3 Low | 7 |
| P4 Optional | 1 |

**Release blockers:** DSK-001 (no Go for the next preview without a new candidate and Go/No-Go). Every other entry
is not a release blocker.

The Linux x86_64 shell, bundle, built-in sandbox integration and real-system tests (Ubuntu 24.04, Debian 13) are
in place. The frozen candidate `v0.2.0-preview.1` stays NO-GO (owner decision 2026-10-31) and is not published; since
the owner's Docker-first decision of 2026-11-02 (ADR-0009 in nodestro-studio) a new candidate has to be built and
evaluated with Docker as the sandbox for AI-generated tools, and none has been built yet. macOS, Windows, signing,
installers and updates do not exist yet.

## Priorities and statuses

- **P0 Critical**: data loss, security exposure, or broken core function; blocks any release.
- **P1 High**: blocks a planned release or a promised capability, or a significant risk.
- **P2 Medium**: real defect or gap with a workaround; schedule soon.
- **P3 Low**: minor defect, polish, or small debt.
- **P4 Optional**: improvement idea; not a defect.

Statuses: `Open`, `In progress` (PR linked), `Blocked` (names the blocker), `Needs decision` (owner decision pending),
`Needs external review`, `Accepted risk` (deliberately not fixed; reason stated).

## Release blockers and critical items

### DSK-001 · New desktop release candidate and Go/No-Go after the built-in sandbox

- **Priority:** P1 High · **Status:** Needs decision · **Refs:** #16, release decision 2026-10-31, Docker-first
  decision 2026-11-02 (ADR-0009 in nodestro-studio)
- **What:** The candidate `v0.2.0-preview.1` (runs 41212112554, 41212693919, built 2026-10-31 before the built-in
  sandbox) is frozen and NO-GO by the owner's decision of 2026-10-31; `publish.yml` refuses both runs. The built-in
  Linux sandbox has since been integrated and tested on real machines (desktop #6), and the owner's Docker-first
  decision of 2026-11-02 made Docker the sandbox for AI-generated tools in automatic mode (the built-in sandbox is not
  used there, [docs/testing.md](testing.md)). No new candidate has been built or evaluated. The README still names
  `v0.2.0-preview.1` as the (unpublished) candidate, and nodestro-studio `platform/versions.json` `products` still
  lists it (ST-027).
- **Next step:** From the current pins (`studio.json`; studio `9d24565` since 2026-11-08), rebuild with `release.yml`, run
  `systems.yml`, write a new Go/No-Go against the Docker-first behavior, update the README status. Publishing needs
  the owner's explicit approval.

## Security

### DSK-003 · Code signing and notarization

- **Priority:** P2 Medium · **Status:** Needs decision · **Refs:** README "Restrictions of this preview", backend audit D-09
- **What:** No build is signed and there is no provenance attestation; only `SHA256SUMS` exists. macOS
  notarization and Windows Authenticode will be required as soon as those platforms are built.
- **Next step:** Owner decides on certificates and key custody; then sign in `publish.yml` and record it in the manifest.

## Bugs and reliability

### DSK-017 · Windows: starting and stopping the backend

- **Priority:** P3 Low · **Status:** Open · **Refs:** `app/src/backend.rs` (`Backend::command`, `stop`), docs/testing.md
- **What:** Found by reading the code; Windows is not built (DSK-004). Since 2026-11-07 the shell starts
  `python.exe` with `CREATE_NO_WINDOW` (the release shell is a GUI program, so a console window would open next to
  the app), and CI cross-checks the Windows code with clippy; neither has run on Windows. `stop` still has no
  graceful path off Unix: `TerminateProcess` right away, so the backend's shutdown does not run. The managed Ollama
  ends with the killed backend through orkexa's job object (orkexa #60); that path has not run on Windows.
- **Next step:** On the first Windows test build, confirm that no console window opens; then add a graceful stop
  (a shutdown request on the loopback API or a console control event, which needs the backend in
  nodestro-api/nodestro-studio to handle it), killed after the timeout.

## Architecture and modularity

None known.

## Performance

None known. (Each tool call starts a new interpreter, about 0.13 to 0.19 s; documented.)

## Features and enhancements

### DSK-004 · macOS and Windows builds

- **Priority:** P2 Medium · **Status:** Needs decision · **Refs:** README status, ADR-0005 in nodestro-studio
- **What:** Only Linux x86_64 is built. The shell and the keychain code already target macOS and Windows, but there
  are no runners and no bundle. Since 2026-11-02 the runtime and the studio start on macOS (arm64, x86-64) and
  Windows (x64, ARM64) in CI, and the studio's `auto` sandbox mode uses Docker there for AI-generated tools and
  explains when they are blocked (ADR-0009 in nodestro-studio). The macOS sandbox of Orkexa is experimental and not
  used; Windows has no native sandbox. Without Docker, AI-generated tools stay blocked on both.
- **Local test builds (2026-11-02):** `scripts/local_test_build.sh` builds an unsigned test app from the pinned state
  on macOS or Linux and checks start, secret handover, Docker detection, sandbox status, the refusal of untrusted
  code and the shutdown ([docs/testing.md](testing.md)). It ran on Linux x86_64 only; it has not run on a Mac.
  Windows has documented, untested steps (`build_backend.sh` assumes `python/bin/python3`). Cross-building is not
  possible: `cargo check --target aarch64-apple-darwin` fails on Linux (Objective-C needs Apple's toolchain and SDK);
  `cargo check --target x86_64-pc-windows-msvc` passes (CI runs clippy for that target since 2026-11-07), but
  linking and the backend need Windows.
- **Next step:** Run `scripts/local_test_build.sh` on an Apple-silicon and an Intel Mac and record the results; owner
  decides on platforms and runners; then add build and smoke jobs. Depends on DSK-003 for anything distributed.

### DSK-005 · Updates

- **Priority:** P3 Low · **Status:** Needs decision · **Refs:** README "Restrictions of this preview"
- **What:** No updater; users unpack a new archive by hand. The Tauri updater requires a signing key (DSK-003).
- **Next step:** Decide on an update channel after signing exists.

### DSK-006 · Installer, distribution packages and menu entry

- **Priority:** P3 Low · **Status:** Open · **Refs:** `app/tauri.conf.json` (`"bundle": {"active": false}`)
- **What:** Only a tar.gz exists: no `.deb`, AppImage or Flatpak, no desktop menu entry. A `.deb` could declare the
  WebKitGTK dependency.
- **Next step:** Choose the Linux package formats and enable Tauri bundling for them.

### DSK-007 · Support for systems with glibc older than 2.39

- **Priority:** P3 Low · **Status:** Open · **Refs:** README "System requirements (tested)"
- **What:** The shell is built on Ubuntu 24.04 and does not start on Ubuntu 22.04 or Debian 12. The built-in sandbox
  needs Linux 6.7+ anyway, so such systems would need Docker for AI-generated tools.
- **Next step:** Decide whether older systems matter; if so, build the shell on an older base.

## Tests and quality assurance

### DSK-009 · Smoke and window test gaps

- **Priority:** P3 Low · **Status:** Open · **Refs:** Bedrock deployment analysis section 6, `spike/README.md`
- **What:** The studio's browser suites have never run in the WebKitGTK window itself (only in Playwright WebKit).
  Since 2026-11-06 the smoke test checks that the bundled backend reports Amazon Bedrock as `not_configured` and
  contacts no AWS host (all outgoing requests go through a logging proxy).
- **Next step:** Consider one WebKitGTK run of the studio smoke suite (for example through WebKitGTK's WebDriver).

## Platform coverage

### DSK-010 · Untested Linux environments

- **Priority:** P2 Medium · **Status:** Open · **Refs:** README "System requirements (tested)"
- **What:** Only Ubuntu 24.04 and Debian 13 (x86_64, KVM, headless GNOME and Xvfb) are tested. Untested: Fedora,
  Arch and other distributions, KDE, a physical screen, GPU drivers, HiDPI, Linux arm64 (not built), screen
  readers in the window, and real model providers including Amazon Bedrock with SSO. The built-in sandbox counts as
  isolation only on the two tested systems.
- **Next step:** Add at least Fedora to `systems.yml` and run one manual session on real hardware.

## Documentation

None known beyond DSK-001.

## Technical debt

None known.

## Later optimizations

### DSK-020 · GPU libraries for the bundled local model runtime

- **Priority:** P3 Low · **Status:** Open · **Refs:** `scripts/fetch_ollama.py`, nodestro-runtime `docs/local-models.md`
- **What:** The Linux bundle leaves out Ollama's NVIDIA CUDA libraries (about 2.4 GB), so NVIDIA GPUs are not used
  (Vulkan and the CPU are). Inference speed on real desktops with and without a GPU was not measured, and the macOS
  bundle (Metal) is built only by the macOS test build.
- **Next step:** Decide between an optional GPU download in the studio (orkexa's `install_runtime(gpu=True)` into the
  data directory) and a separate GPU archive; measure on real hardware.


## Accepted risks

### DSK-015 · Same-user processes can read the data directory

- **Priority:** P3 Low · **Status:** Accepted risk · **Refs:** README "Restrictions of this preview", review MS-1
- **What:** The data directory is readable by the same OS user, and a same-user process with debugging rights
  (`ptrace`) can read the backend's memory. The launch secret and the vault key no longer reach the backend through its
  environment (readable via `/proc/<pid>/environ` or macOS `KERN_PROCARGS2`): they go through a pipe on its standard
  input (`--secrets-fd 0`) and stay in memory. Accepted because such a process already runs with the user's rights.
- **Next step:** Re-evaluate with OS-level app sandboxing (macOS, Flatpak). Verify the pipe handoff on macOS and
  Windows once those builds exist (only Linux is built and tested).

### DSK-016 · Electron spike lockfile with advisories

- **Priority:** P4 Optional · **Status:** Accepted risk · **Refs:** backend audit D-19, `spike/electron/`
- **What:** The packaging spike's Electron lockfile has known advisories. Accepted because the spike is neither built
  nor shipped (Tauri was chosen, ADR-0005).
- **Next step:** Remove `spike/electron/` when the spike's measurements are no longer needed.

## Cross-repository dependencies

| This repo item | Other repo | Other item | Relation |
|---|---|---|---|
| (open, TABRION MIG-NOD-9) | nodestro-api, nodestro-studio, nodestro-runtime | api and studio branch `claude/project-thread-bjlq25-nod9ui`, runtime #176 | The shell starts the backend again when it ends with 75 (after the confirmed repair of the database's permissions) or 76 (the diagnosis asked for the repair: the next start gets `NODESTRO_RECOVERY=database-permissions`, every other start has it removed); at most 3 restarts in 2 minutes, then the window shows "stopped". The start page says "restarting" meanwhile (`#restart=1`, six languages). Takes effect once `studio.json` pins a studio whose backend has recovery mode; until then nothing ends with these codes |
| (pointer) | nodestro-studio | ST-052 (Dependabot policy: weekly groups, cooldown, manual merge; auto-merge prerequisites) | Full entry in studio |
| DSK-001 | nodestro-studio | ST-027 (`platform/versions.json` `products` still names the withdrawn candidate), ST-018 (RELEASES.md and IMPLEMENTATION_STATUS.md not updated after the sandbox) | Update together |
| (pointer) | nodestro-server | `scripts/` (source copies of the release scripts and `pin_distance.py`) | `scripts/check_server_copies.py` compares them with server master in CI; change there first |
| DSK-020 | nodestro-runtime, orkexa | `local_service.py`, `orkexa.local.install` (same Ollama pin, checked by `fetch_ollama.py --check-against`) | Keep the pins equal |
| DSK-010 | nodestro-runtime | RT-018 (built-in sandbox `TESTED_SYSTEMS`) | New systems must be validated there first |

## CI access to private repositories

Keep the repository secret `NODESTRO_READ`; do not delete it. CI currently installs the sibling repositories anonymously
because they are public, and does not need the secret. When the repositories become private, CI authenticates again
with this read-only secret, passed only in the environment of the install steps (never in a global Git configuration,
a log or an image layer).

## Maintaining this file

- Add an entry when work is identified but not done in the current PR. Use the next free ID; IDs are never reused.
- Link a GitHub issue for anything concrete enough to be picked up; keep details in the issue, not here.
- When an item is finished, delete its entry in the PR that completes it and mention the ID in the PR description.
  Git history is the record; do not keep ticked checklists.
- Accepted risks stay listed with their reason until the risk is removed or re-evaluated.
- Re-review the whole file before each release and update the "Last full review" line.
- Security issues that are not yet fixed are described only in general terms here. Report details privately
  (GitHub private vulnerability reporting), never in this file or in public issues.

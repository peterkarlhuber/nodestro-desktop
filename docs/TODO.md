# TODO: nodestro-desktop

> Open work for this repository: release blockers, known bugs, security follow-ups, technical debt and planned improvements.
> GitHub issues are the source of truth for details; this file is the entry point and summary.
>
> **Last full review:** 2026-11-01 against `master` at `80df14d`.

## Summary

| Priority | Count |
|---|---|
| P0 Critical | 0 |
| P1 High | 1 |
| P2 Medium | 4 |
| P3 Low | 9 |
| P4 Optional | 2 |

**Release blockers:** DSK-001.

The Linux x86_64 shell, bundle, built-in sandbox integration and real-system tests (Ubuntu 24.04, Debian 13) are
in place. The desktop `v0.2.0-preview.1` decision is still NO-GO: the sandbox work it waited for is merged, but no
new candidate has been built or re-evaluated. macOS, Windows, signing, installers and updates do not exist yet.

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

- **Priority:** P1 High · **Status:** Needs decision · **Refs:** #16, release decision 2026-10-31
- **What:** `v0.2.0-preview.1` was NO-GO until the built-in Linux sandbox was finished. It is now integrated and
  tested on real machines (desktop #6), but the only candidates (runs 41212112554, 41212693919) are withdrawn and no
  new one exists. The README still presents `v0.2.0-preview.1` as the current candidate.
- **Next step:** After the next pin cascade, rebuild with `release.yml`, run `systems.yml`, write a new Go/No-Go,
  update the README status. Publishing needs the owner's explicit approval.

## Security

### DSK-002 · CI must not require the `NODESTRO_READ` secret

- **Priority:** P2 Medium · **Status:** Open · **Refs:** #17, backend audit D-08; same change in runtime #75 (RT-029)
- **What:** `ci.yml` and `release.yml` fail without the secret although all component repositories are public, so
  Dependabot PRs #10 and #11 can never pass. README, `build_backend.sh` and CI comments still say "private".
- **Next step:** Make the token optional and correct the texts (see #17).

### DSK-003 · Code signing and notarization

- **Priority:** P2 Medium · **Status:** Needs decision · **Refs:** README "Restrictions of this preview", backend audit D-09
- **What:** No build is signed and there is no provenance attestation; only `SHA256SUMS` exists. macOS
  notarization and Windows Authenticode will be required as soon as those platforms are built.
- **Next step:** Owner decides on certificates and key custody; then sign in `publish.yml` and record it in the manifest.

## Bugs and reliability

None known.

## Architecture and modularity

None known.

## Performance

None known. (Each tool call starts a new interpreter, about 0.13 to 0.19 s; documented.)

## Features and enhancements

### DSK-004 · macOS and Windows builds

- **Priority:** P2 Medium · **Status:** Needs decision · **Refs:** README status, ADR-0005 in nodestro-studio
- **What:** Only Linux x86_64 is built. The shell and the keychain code already target macOS and Windows, but there
  are no runners, no bundle and no sandbox story for them (AI-generated tools would need Docker there).
- **Next step:** Owner decides on platforms and runners; then add build and smoke jobs. Depends on DSK-003.

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

### DSK-008 · Dependabot updates (getrandom 0.4, GitHub Actions group)

- **Priority:** P3 Low · **Status:** Blocked (on DSK-002) · **Refs:** #10, #11
- **What:** #10 is a breaking-version bump of `getrandom` (0.3 to 0.4) used for the launch secret; #11 updates four
  actions. Both fail only in the `app` job because the secret is missing.
- **Next step:** Re-run after DSK-002; review the getrandom API change and the actions' release notes; merge if green.

### DSK-009 · Smoke and window test gaps

- **Priority:** P3 Low · **Status:** Open · **Refs:** Bedrock deployment analysis section 6, `spike/README.md`
- **What:** The smoke test does not check that Settings lists Amazon Bedrock as `not_configured` (no AWS call), and
  the studio's browser suites have never run in the WebKitGTK window itself (only in Playwright WebKit).
- **Next step:** Extend `scripts/smoke_inside.sh`; consider one WebKitGTK run of the studio smoke suite.

## Platform coverage

### DSK-010 · Untested Linux environments

- **Priority:** P2 Medium · **Status:** Open · **Refs:** README "System requirements (tested)"
- **What:** Only Ubuntu 24.04 and Debian 13 (x86_64, KVM, headless GNOME and Xvfb) are tested. Untested: Fedora,
  Arch and other distributions, KDE, a physical screen, GPU drivers, HiDPI, Linux arm64 (not built), screen
  readers in the window, and real model providers including Amazon Bedrock with SSO. The built-in sandbox counts as
  isolation only on the two tested systems.
- **Next step:** Add at least Fedora to `systems.yml` and run one manual session on real hardware.

## Documentation

None known beyond DSK-001 and DSK-002.

## Technical debt

### DSK-011 · Release scripts copied from nodestro-server without a sync check

- **Priority:** P3 Low · **Status:** Open · **Refs:** #18, backend audit D-15
- **What:** Four scripts are byte-identical copies of nodestro-server's; nothing keeps them in sync.
- **Next step:** Fetch them from the pinned server commit or compare checksums in CI (see #18).

### DSK-012 · Committed bytecode cache

- **Priority:** P3 Low · **Status:** Open · **Refs:** `scripts/__pycache__/scan_secrets.cpython-313.pyc`
- **What:** A `.pyc` file is tracked in git, and `.gitignore` has no `__pycache__/` entry.
- **Next step:** Remove it and add `__pycache__/` to `.gitignore`.

### DSK-013 · Pin hygiene: merge commits and pin distance

- **Priority:** P3 Low · **Status:** Open · **Refs:** backend audit D-01
- **What:** `studio.json` pins `b8c6d48`, a studio branch head, although its comment promises a master merge commit;
  CI does not warn when the pin falls behind the latest studio platform commit.
- **Next step:** Re-pin to a merge commit in the next cascade; add a CI warning for pin distance.

## Later optimizations

### DSK-014 · Bundle size budget

- **Priority:** P4 Optional · **Status:** Open · **Refs:** Bedrock deployment analysis section 1
- **What:** The bundle is about 260 MB unpacked (botocore alone adds about 31 MB) and no size budget is enforced;
  `package_linux.sh` only prints `du`.
- **Next step:** Add a warning threshold to CI.

## Accepted risks

### DSK-015 · Same-user processes can read the launch secret, keychain key and data directory

- **Priority:** P3 Low · **Status:** Accepted risk · **Refs:** README "Restrictions of this preview"
- **What:** The launch secret and the vault key reach the backend through its environment, and the data directory
  is readable by the same OS user. Accepted because such a process already runs with the user's rights; the launch
  secret is useless after first use.
- **Next step:** Re-evaluate with OS-level app sandboxing (macOS, Flatpak).

### DSK-016 · Electron spike lockfile with advisories

- **Priority:** P4 Optional · **Status:** Accepted risk · **Refs:** backend audit D-19, `spike/electron/`
- **What:** The packaging spike's Electron lockfile has known advisories. Accepted because the spike is neither built
  nor shipped (Tauri was chosen, ADR-0005).
- **Next step:** Remove `spike/electron/` when the spike's measurements are no longer needed.

## Cross-repository dependencies

| This repo item | Other repo | Other item | Relation |
|---|---|---|---|
| DSK-001 | nodestro-studio | ST-027 (`platform/versions.json` `products` still names the withdrawn candidate), ST-018 (RELEASES.md and IMPLEMENTATION_STATUS.md not updated after the sandbox) | Update together |
| DSK-011 | nodestro-server | `scripts/` (source copies) | Sync with |
| DSK-013 | nodestro-server, nodestro-local-docker | SRV-016, LD-009 (pins at branch heads) | Re-pin in the same cascade |
| DSK-010 | nodestro-runtime | RT-018 (built-in sandbox `TESTED_SYSTEMS`) | New systems must be validated there first |
| DSK-002 | all component repositories | `NODESTRO_READ` CI change (runtime RT-029) | Same change everywhere |

## Maintaining this file

- Add an entry when work is identified but not done in the current PR. Use the next free ID; IDs are never reused.
- Link a GitHub issue for anything concrete enough to be picked up; keep details in the issue, not here.
- When an item is finished, delete its entry in the PR that completes it and mention the ID in the PR description.
  Git history is the record; do not keep ticked checklists.
- Accepted risks stay listed with their reason until the risk is removed or re-evaluated.
- Re-review the whole file before each release and update the "Last full review" line.
- Security issues that are not yet fixed are described only in general terms here. Report details privately
  (GitHub private vulnerability reporting), never in this file or in public issues.

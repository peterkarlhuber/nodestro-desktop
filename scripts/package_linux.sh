#!/usr/bin/env bash
# Put the shell and the backend into one directory and archive it (Linux x86_64, no installer yet).
#
#   scripts/package_linux.sh <shell-binary> <backend-dir> <output.tar.gz> [version]
#
# Layout: nodestro/nodestro-desktop, nodestro/backend/python/..., nodestro/backend/ollama/... (the local model
# runtime, scripts/fetch_ollama.py), nodestro/README.txt, nodestro/VERSION,
# nodestro/LICENSES/ (Nodestro's license and the license texts of the Rust crates and npm packages it contains; the
# Python packages keep theirs in their *.dist-info directories). Needs cargo for the crate list.
# The README names the version, says the build is an unsigned preview and lists the system requirements.
#
# Size budget: prints the archive, the unpacked tree and its parts in MiB, and warns (a GitHub
# `::warning::`, never a failure) when the archive is over NODESTRO_ARCHIVE_BUDGET_MIB (default 175) or the unpacked
# tree over NODESTRO_UNPACKED_BUDGET_MIB (default 512). The defaults are about 10 % over a build of studio 58bb17d
# with Ollama (2026-11-06: 159 MiB archive, 465 MiB unpacked, of which Python 341 and Ollama 115); raise them on
# purpose, in the same change that makes the bundle larger.
set -euo pipefail
shell=$1
backend=$2
archive=$3
version=${4:-dev}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/nodestro/backend"
cp "$shell" "$stage/nodestro/nodestro-desktop"
chmod 755 "$stage/nodestro/nodestro-desktop"
cp -a "$backend/python" "$stage/nodestro/backend/python"
test -x "$backend/ollama/bin/ollama" || { echo "no local model runtime in $backend/ollama (scripts/fetch_ollama.py)" >&2; exit 1; }
cp -a "$backend/ollama" "$stage/nodestro/backend/ollama"
echo "$version" >"$stage/nodestro/VERSION"
here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$stage/nodestro/LICENSES"
cp "$here/LICENSE" "$stage/nodestro/LICENSES/LICENSE-nodestro.txt"
python3 "$here/scripts/cargo_licenses.py" "$here/app/Cargo.toml" >"$stage/nodestro/LICENSES/THIRD-PARTY-rust.txt"
cp "$backend/meta/npm-licenses.txt" "$stage/nodestro/LICENSES/THIRD-PARTY-npm.txt"
cat >"$stage/nodestro/LICENSES/README.txt" <<'TEXT'
Nodestro is MIT licensed (LICENSE-nodestro.txt). It contains third-party software under its own licenses:
- THIRD-PARTY-rust.txt: the Rust crates of the window (nodestro-desktop);
- THIRD-PARTY-npm.txt: the npm packages built into the studio interface;
- backend/ollama/LICENSE: Ollama (MIT), the local model runtime; the licenses of the libraries it contains
  (llama.cpp, ggml and others) are in backend/ollama/lib/ollama/*LICENSE*;
- backend/python/lib/python3.13/LICENSE.txt: CPython; each Python package's license is in its
  backend/python/lib/python3.13/site-packages/*.dist-info directory.
The complete list with declared licenses is in release-manifest.json of the release.
TEXT
cat >"$stage/nodestro/README.txt" <<TEXT
Nodestro Desktop $version (Linux x86_64)

UNSIGNED PREVIEW BUILD: not signed by anyone, not for production data. Verify the archive with
sha256sum -c SHA256SUMS against the checksums of the release you downloaded it from.

Start: ./nodestro-desktop
Needs: Linux x86_64 with glibc 2.39 or newer (tested: Ubuntu 24.04, Debian 13), a graphical session,
and WebKitGTK 4.1 (Ubuntu/Debian: sudo apt install libwebkit2gtk-4.1-0).
Data: ~/.nodestro (or NODESTRO_DATA_DIR); backend log: ~/.local/share/org.nodestro.desktop/logs/backend.log
AI-generated tools run in the built-in Linux sandbox (Landlock and seccomp; needs Linux 6.7 or newer with
Landlock enabled and a normal user, not root; tested on Ubuntu 24.04 and Debian 13). Nothing else to install.
On other systems AI-generated tools are blocked unless Docker is available; they never run unprotected.
See the user documentation, chapter "Tools".
Local models: the bundled Ollama $(sed -n 's/^version=//p' "$backend/ollama/OLLAMA-RELEASE") (backend/ollama, CPU and Vulkan; no
NVIDIA CUDA libraries) runs models on this computer without an API key. Models are downloaded or imported in the
studio (Settings, local models) and stored in ~/.nodestro/local-models.
TEXT
tar -C "$stage" -czf "$archive" nodestro
du -h "$archive"
mib() { echo $(( ($1 + 1048575) / 1048576 )); }
archive_mib=$(mib "$(stat -c %s "$archive")")
unpacked_mib=$(mib "$(du -sb "$stage/nodestro" | cut -f1)")
echo "size: archive ${archive_mib} MiB, unpacked ${unpacked_mib} MiB" \
  "(python $(mib "$(du -sb "$stage/nodestro/backend/python" | cut -f1)") MiB," \
  "ollama $(mib "$(du -sb "$stage/nodestro/backend/ollama" | cut -f1)") MiB)"
archive_budget=${NODESTRO_ARCHIVE_BUDGET_MIB:-175}
unpacked_budget=${NODESTRO_UNPACKED_BUDGET_MIB:-512}
if [ "$archive_mib" -gt "$archive_budget" ]; then
  echo "::warning::the archive is ${archive_mib} MiB, over its budget of ${archive_budget} MiB"
fi
if [ "$unpacked_mib" -gt "$unpacked_budget" ]; then
  echo "::warning::the unpacked bundle is ${unpacked_mib} MiB, over its budget of ${unpacked_budget} MiB"
fi

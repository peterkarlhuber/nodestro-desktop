#!/usr/bin/env bash
# Put the shell and the backend into one directory and archive it (Linux x86_64, no installer yet).
#
#   scripts/package_linux.sh <shell-binary> <backend-dir> <output.tar.gz> [version]
#
# Layout: nodestro/nodestro-desktop, nodestro/backend/python/..., nodestro/README.txt, nodestro/VERSION.
# The README names the version, says the build is an unsigned preview and lists the system requirements.
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
echo "$version" >"$stage/nodestro/VERSION"
cat >"$stage/nodestro/README.txt" <<TEXT
Nodestro Desktop $version (Linux x86_64)

UNSIGNED PREVIEW BUILD: not signed by anyone, not for production data. Verify the archive with
sha256sum -c SHA256SUMS against the checksums of the release you downloaded it from.

Start: ./nodestro-desktop
Needs: Linux x86_64 with glibc 2.39 or newer (tested: Ubuntu 24.04, Debian 13), a graphical session,
and WebKitGTK 4.1 (Ubuntu/Debian: sudo apt install libwebkit2gtk-4.1-0).
Data: ~/.nodestro (or NODESTRO_DATA_DIR); backend log: ~/.local/share/org.nodestro.desktop/logs/backend.log
AI-generated tools run only with Docker; see the user documentation, chapter "Tools".
TEXT
tar -C "$stage" -czf "$archive" nodestro
du -h "$archive"

#!/usr/bin/env bash
# Put the shell and the backend into one directory and archive it (Linux x86_64, no installer yet).
#
#   scripts/package_linux.sh <shell-binary> <backend-dir> <output.tar.gz>
#
# Layout: nodestro/nodestro-desktop, nodestro/backend/python/..., nodestro/README.txt.
# The system needs WebKitGTK 4.1 (Ubuntu/Debian: libwebkit2gtk-4.1-0).
set -euo pipefail
shell=$1
backend=$2
archive=$3
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/nodestro/backend"
cp "$shell" "$stage/nodestro/nodestro-desktop"
chmod 755 "$stage/nodestro/nodestro-desktop"
cp -a "$backend/python" "$stage/nodestro/backend/python"
cat >"$stage/nodestro/README.txt" <<'TEXT'
Nodestro Desktop (Linux x86_64, unsigned preview build)

Start: ./nodestro-desktop
Needs: WebKitGTK 4.1 (Ubuntu/Debian: sudo apt install libwebkit2gtk-4.1-0)
Data: ~/.nodestro (or NODESTRO_DATA_DIR); backend log: ~/.local/share/org.nodestro.desktop/logs/backend.log
AI-generated tools run only with Docker; see the user documentation, chapter "Tools".
TEXT
tar -C "$stage" -czf "$archive" nodestro
du -h "$archive"

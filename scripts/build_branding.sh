#!/bin/sh
# Regenerate every Nodestro logo and icon in this repository from the official masters in branding/.
# scripts/derive_branding.py is the brand kit's derivation script, vendored unchanged; never edit its outputs by hand.
# Needs Python 3 with Pillow and NumPy, for example: uv run --with pillow --with numpy scripts/build_branding.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
python=${PYTHON:-python3}
derive() { "$python" -I "$root/scripts/derive_branding.py" --product nodestro --masters "$root/branding" "$@"; }

derive --check
# Tauri bundle and window icons.
derive --out "$root/app/icons" --sets desktop >/dev/null
# The start page's lockups (light and dark color scheme); the other web files are not used.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
derive --out "$tmp" --sets web >/dev/null
cp "$tmp/nodestro-logo.png" "$tmp/nodestro-logo-on-dark.png" "$root/app/ui/"

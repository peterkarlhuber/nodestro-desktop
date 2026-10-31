#!/usr/bin/env bash
# Build a small, relocatable bundle for the sandbox system tests: python-build-standalone CPython 3.13 (the same
# interpreter the desktop app bundles) with nodestro-runtime at <runtime-ref> installed, plus a folder of hash-pinned
# wheels for the compiled-library check. The bundle runs on a machine without any Python.
#
#   scripts/vm/build_probe_bundle.sh <runtime-ref> <out-dir>
set -euo pipefail
ref="$1"; out="$2"
mkdir -p "$out"
uv python install 3.13 --install-dir "$out/.pythons" --no-bin >/dev/null
mv "$(find "$out/.pythons" -mindepth 1 -maxdepth 1 -type d -name 'cpython-*' ! -type l | head -n 1)" "$out/python"
rm -rf "$out/.pythons" "$out"/python/lib/python3.*/EXTERNALLY-MANAGED
"$out/python/bin/python3" -m pip install --quiet --no-warn-script-location --root-user-action=ignore \
  "nodestro-runtime @ git+https://github.com/peterkarlhuber/nodestro-runtime.git@$ref"
curl -fsSL -o "$out/compiled-library.txt" \
  "https://raw.githubusercontent.com/peterkarlhuber/nodestro-runtime/$ref/tests/data/compiled-library.txt"
"$out/python/bin/python3" -m pip download --quiet --only-binary=:all: --no-deps --require-hashes \
  -r "$out/compiled-library.txt" -d "$out/wheels"
"$out/python/bin/python3" -m pip download --quiet --only-binary=:all: -d "$out/wheels" pydantic typing-extensions
find "$out/python" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
tar -C "$out" -czf "$out.tar.gz" .
du -sh "$out" "$out.tar.gz"

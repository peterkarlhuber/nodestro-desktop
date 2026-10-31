#!/usr/bin/env bash
# Packaging spike (plan PR-5): a relocatable backend for the desktop shell.
#
#   spike/backend/build_backend.sh <studio-commit-or-path> <output-dir>
#
# 1. uv fetches a python-build-standalone CPython 3.13 (the build uv pins, with checksums).
# 2. The studio (`nodestro`, which pins every component by full commit SHA) is checked out at the
#    commit, its interface is built (Node.js is a build-time tool only: a plain `pip install git+...`
#    gives a wheel without the interface), and its wheel is installed into that interpreter. pip
#    clones the private component repositories, so the build needs read access (in CI: the
#    NODESTRO_READ secret, never printed). Nothing is fetched at run time.
# 3. pip and caches are removed; the result runs with `<output-dir>/python/bin/nodestro`.
set -euo pipefail
source_ref=$1
out=$2
python_version=${PYTHON_VERSION:-3.13}
rm -rf "$out"
mkdir -p "$out"
uv python install "$python_version" --install-dir "$out/.pythons" --no-bin >/dev/null
interpreter_dir=$(find "$out/.pythons" -mindepth 1 -maxdepth 1 -type d -name "cpython-*" ! -type l | head -n 1)
mv "$interpreter_dir" "$out/python"
rm -rf "$out/.pythons"
rm -f "$out"/python/lib/python3.*/EXTERNALLY-MANAGED  # this interpreter belongs to the bundle
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ -d "$source_ref" ]; then
  git -C "$source_ref" archive --format=tar HEAD | tar -x -C "$work"
else
  git clone --quiet --filter=blob:none https://github.com/peterkarlhuber/nodestro-studio.git "$work"
  git -C "$work" checkout --quiet "$source_ref"
fi
(cd "$work/frontend" && npm ci --silent && npm run build --silent >/dev/null)
"$out/python/bin/python3" -m pip install --quiet --root-user-action=ignore build
"$out/python/bin/python3" -m build --wheel --outdir "$work/dist" "$work" >/dev/null
"$out/python/bin/python3" -m pip uninstall --quiet --yes build pyproject_hooks packaging || true
"$out/python/bin/python3" -m pip install --quiet --no-warn-script-location --root-user-action=ignore "$work"/dist/*.whl
test -f "$out"/python/lib/python3.*/site-packages/nodestro_studio/static/index.html
"$out/python/bin/python3" -m pip uninstall --quiet --yes pip
find "$out/python" -name "__pycache__" -path "*/test*" -prune -exec rm -rf {} + 2>/dev/null || true
du -sh "$out/python"

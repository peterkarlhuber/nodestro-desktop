#!/usr/bin/env bash
# Build the backend the desktop app bundles: a relocatable CPython with the studio installed.
#
#   scripts/build_backend.sh <output-dir> [studio-commit-or-checkout]
#
# The studio commit defaults to the one in studio.json. The studio pins every component by full commit SHA.
# 1. uv fetches a python-build-standalone CPython 3.13 (the build uv pins, with checksums).
# 2. The studio is checked out, its interface is built (Node.js is a build-time tool only), and its wheel
#    is installed into that interpreter. pip clones the private component repositories, so the build
#    needs read access (in CI: the NODESTRO_READ secret, never printed). Nothing is fetched at run time.
# 3. pip, build tools and caches are removed. The app starts `python/bin/python3 -I -m nodestro_studio`,
#    never the generated `nodestro` script (it names the interpreter by its build-time path).
set -euo pipefail
out=$1
here=$(cd "$(dirname "$0")/.." && pwd)
source_ref=${2:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nodestro-studio"])' "$here/studio.json")}
python_version=${PYTHON_VERSION:-3.13}
rm -rf "$out"
mkdir -p "$out"
uv python install "$python_version" --install-dir "$out/.pythons" --no-bin >/dev/null
interpreter_dir=$(find "$out/.pythons" -mindepth 1 -maxdepth 1 -type d -name "cpython-*" ! -type l | head -n 1)
mv "$interpreter_dir" "$out/python"
rm -rf "$out/.pythons"
rm -f "$out"/python/lib/python3.*/EXTERNALLY-MANAGED # this interpreter belongs to the bundle
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
"$out/python/bin/python3" -m pip uninstall --quiet --yes --root-user-action=ignore build pyproject_hooks packaging || true
"$out/python/bin/python3" -m pip install --quiet --no-warn-script-location --root-user-action=ignore "$work"/dist/*.whl
test -f "$out"/python/lib/python3.*/site-packages/nodestro_studio/static/index.html
"$out/python/bin/python3" -m pip uninstall --quiet --yes --root-user-action=ignore pip
find "$out/python" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
"$out/python/bin/python3" -I -c "import nodestro_api.launch, nodestro_studio.app"
du -sh "$out/python"

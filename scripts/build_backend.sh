#!/usr/bin/env bash
# Build the backend the desktop app bundles: a relocatable CPython with the studio installed.
#
#   scripts/build_backend.sh <output-dir> [studio-commit-or-checkout]
#
# The studio commit defaults to the one in studio.json. The studio pins every component by full commit SHA.
# 1. uv fetches a python-build-standalone CPython 3.13 (the build uv pins, with checksums).
# 2. The studio is checked out, its interface is built (Node.js is a build-time tool only), and its wheel
#    is installed into that interpreter. pip clones the public component repositories anonymously (no token).
#    Nothing is fetched at run time.
# 3. The studio commit, its versions.json and package-lock.json go to <output-dir>/meta for the release manifest,
#    and the license texts of the interface's npm packages to <output-dir>/meta/npm-licenses.txt for the archive.
#    pip installs the third-party packages as uploaded before the studio's platform/uploaded-prior-to (kept as
#    meta/uploaded-prior-to); meta/pip-freeze.txt records what was installed.
# 4. The studio's scripts/lock_check.py checks the installed components against its versions.json (the build fails
#    on a mismatch). pip, build tools and caches are removed; import checks prove the studio and the Amazon Bedrock
#    provider (boto3, botocore's service models) are in the bundle. The app starts
#    `python/bin/python3 -I -m nodestro_studio`, never the generated `nodestro` script (it names the interpreter by its
#    build-time path).
# 5. The local model runtime: Ollama of the pinned release (scripts/fetch_ollama.py: SHA-256 against the release's
#    pinned checksum, CPU and Vulkan backends without the CUDA libraries) in <output-dir>/ollama. The app passes its
#    executable to the backend as NODESTRO_OLLAMA_BINARY. NODESTRO_OLLAMA_ARCHIVE and NODESTRO_OLLAMA_LICENSE name
#    local files for an offline build; NODESTRO_BUNDLE_OLLAMA=0 leaves it out (development builds only).
set -euo pipefail
out=$1
here=$(cd "$(dirname "$0")/.." && pwd)
source_ref=${2:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nodestro-studio"])' "$here/studio.json")}
python_version=${PYTHON_VERSION:-3.13}
# pip must see only the bundle: packages in the builder's user site (~/.local/lib/python3.13 on Linux,
# ~/Library/Python/3.13 on macOS) or on PYTHONPATH would count as installed and be left out of the bundle.
export PYTHONNOUSERSITE=1
unset PYTHONPATH PYTHONHOME
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
# Release metadata (not shipped in the archive): the studio commit, its component pins and its npm lock file.
mkdir -p "$out/meta"
if [ -d "$source_ref" ]; then git -C "$source_ref" rev-parse HEAD >"$out/meta/studio-commit"; else git -C "$work" rev-parse HEAD >"$out/meta/studio-commit"; fi
cp "$work/platform/versions.json" "$work/frontend/package-lock.json" "$out/meta/"
(cd "$work/frontend" && npm ci --silent && npm run build --silent >/dev/null)
node "$here/scripts/npm_licenses.mjs" "$work/frontend" >"$out/meta/npm-licenses.txt"
# Third-party packages as uploaded before the studio's shared cutoff (platform/uploaded-prior-to, pip
# --uploaded-prior-to): the set the studio's platform workflow tests. The studio's scripts/pip_cutoff.py checks the
# file and that the bundle's pip is 26.0 or newer (the build fails otherwise). A studio commit from before the cutoff
# (studio.json pinned 6755c7a when this was written) gets a warning and no cutoff.
cutoff_args=()
if [ -f "$work/platform/uploaded-prior-to" ]; then
  cutoff=$("$out/python/bin/python3" -I "$work/scripts/pip_cutoff.py")
  cutoff_args=(--uploaded-prior-to "$cutoff")
  echo "$cutoff" >"$out/meta/uploaded-prior-to"
else
  echo "WARNING pip_cutoff: NOT USED, the studio $(cat "$out/meta/studio-commit") has no platform/uploaded-prior-to;" \
    "the third-party packages are not bound to an upload cutoff" >&2
fi
"$out/python/bin/python3" -m pip install --quiet --root-user-action=ignore ${cutoff_args[@]+"${cutoff_args[@]}"} build
# The build front end installs the build backend (hatchling) into its own isolated environment with that pip; it takes
# no pip options, so the cutoff reaches it as PIP_UPLOADED_PRIOR_TO (the pip version is checked above).
PIP_UPLOADED_PRIOR_TO=${cutoff:-} "$out/python/bin/python3" -m build --wheel --outdir "$work/dist" "$work" >/dev/null
"$out/python/bin/python3" -m pip uninstall --quiet --yes --root-user-action=ignore build pyproject_hooks packaging || true
"$out/python/bin/python3" -m pip install --quiet --no-warn-script-location --root-user-action=ignore \
  ${cutoff_args[@]+"${cutoff_args[@]}"} "$work"/dist/*.whl
test -f "$out"/python/lib/python3.*/site-packages/nodestro_studio/static/index.html
# Every component at exactly the repository, commit and version the studio pins, and no other commit declared: the
# studio's scripts/lock_check.py, offline, before pip goes (a red check fails the build). A studio commit from before
# the script (nodestro-studio scripts/lock_check.py) has nothing to run.
if [ -f "$work/scripts/lock_check.py" ]; then
  "$out/python/bin/python3" -I "$work/scripts/lock_check.py" --profile studio --versions "$work/platform/versions.json"
else
  echo "lock_check: not run, the studio $(cat "$out/meta/studio-commit") has no scripts/lock_check.py"
fi
# The third-party packages actually installed, for the record (not shipped in the archive).
"$out/python/bin/python3" -m pip freeze --disable-pip-version-check >"$out/meta/pip-freeze.txt"
"$out/python/bin/python3" -m pip uninstall --quiet --yes --root-user-action=ignore pip
find "$out/python" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
"$out/python/bin/python3" -I -c "import nodestro_api.launch, nodestro_studio.app"
# The Amazon Bedrock provider and botocore's service models (its data files) are in the bundle (-B: no byte code).
"$out/python/bin/python3" -I -B -c "import boto3, botocore.session, orkexa.providers.bedrock; s = botocore.session.get_session(); [s.get_service_model(n) for n in ('bedrock-runtime', 'bedrock', 'sts')]"
du -sh "$out/python"
if [ "${NODESTRO_BUNDLE_OLLAMA:-1}" != 0 ]; then
  fetch=(python3 -I "$here/scripts/fetch_ollama.py" "$out" --check-against "$out/python/bin/python3")
  if [ -n "${NODESTRO_OLLAMA_ARCHIVE:-}" ]; then fetch+=(--archive "$NODESTRO_OLLAMA_ARCHIVE"); fi
  if [ -n "${NODESTRO_OLLAMA_LICENSE:-}" ]; then fetch+=(--license "$NODESTRO_OLLAMA_LICENSE"); fi
  "${fetch[@]}"
  du -sh "$out/ollama"
fi

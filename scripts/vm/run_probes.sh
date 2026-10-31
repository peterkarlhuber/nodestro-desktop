#!/usr/bin/env bash
# Inside the test machine, as the normal user: unpack the probe bundle, create a Python environment with the
# compiled library offline (the bundle's venv and pip, local wheels only, no index), then run the
# built-in sandbox's security probes and compatibility checks. Prints the JSON report to probes.json.
set -euo pipefail
cd "$HOME"
rm -rf bundle && mkdir bundle && tar -C bundle -xzf probe-bundle.tar.gz
py="$HOME/bundle/python/bin/python3"
for tool in python3 python node nodejs rustc cargo docker bwrap; do
  printf 'on PATH: %-8s %s\n' "$tool" "$(command -v "$tool" || echo no)"
done
"$py" -I -m venv --without-pip "$HOME/env"
pip_env=("$py" -I -m pip --python "$HOME/env/bin/python" install --quiet --no-index --find-links bundle/wheels)
"${pip_env[@]}" --require-hashes -r bundle/compiled-library.txt
"${pip_env[@]}" pydantic typing-extensions
set +e
"$py" -I -m nodestro_runtime.sandbox_probes --env-python "$HOME/env/bin/python" --json >probes.json
code=$?
"$py" -I -c '
import json
d = json.load(open("probes.json"))
print(json.dumps(d["status"]))
for r in d["results"]:
    print(("PASS" if r["passed"] else "FAIL"), r["area"], r["name"], r["error"])
    if not r["passed"] or r["area"] == "performance" or r["name"] == "compiled-library":
        for k, v in r["detail"].items():
            print("      ", k, v)
print(sum(r["passed"] for r in d["results"]), "of", len(d["results"]), "passed")
'
exit $code

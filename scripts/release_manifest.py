#!/usr/bin/env python3
"""Write the release manifest and checksums of a Nodestro product build (plan M6).

    scripts/release_manifest.py --product nodestro-desktop --version v0.3.0 --out DIR \
        --studio-meta DIR [--python PATH] [--cargo-manifest PATH] ARTIFACT...

The manifest (``DIR/release-manifest.json``) records:

- the product commit and the studio commit it was built from, and every component pin of that studio
  (``platform/versions.json``);
- each artifact's file name, size and SHA-256 (also written to ``DIR/SHA256SUMS``);
- the license inventory: the Python distributions in the bundled interpreter, the npm packages built into the studio
  interface (``package-lock.json``), and the Rust crates of the shell (``cargo metadata``). Packages without a
  declared license are listed under ``licenses.unknown``, so a release reviewer sees them;
- the signing state. Nothing is signed until a signing certificate is configured, and the manifest says so instead of
  claiming otherwise.

Standard library only; it never prints secrets.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from typing import Any

# Runs inside the bundled interpreter: name, version and declared license of every installed distribution.
_PYTHON_INVENTORY = r"""
import importlib.metadata as m, json
rows = {}
for dist in m.distributions():
    meta = dist.metadata
    name = meta.get("Name") or ""
    if not name:
        continue
    license = meta.get("License-Expression") or ""
    if not license:
        classifiers = [c.split(" :: ")[-1] for c in (meta.get_all("Classifier") or []) if c.startswith("License ::")]
        license = " OR ".join(c for c in classifiers if c not in ("OSI Approved",))
    if not license:
        text = (meta.get("License") or "").strip()
        license = text.splitlines()[0][:80] if text else ""
    rows[name.lower()] = {"name": name, "version": dist.version, "license": license}
print(json.dumps(sorted(rows.values(), key=lambda r: r["name"].lower())))
"""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def git_commit(directory: Path) -> str:
    return subprocess.run(
        ["git", "-C", str(directory), "rev-parse", "HEAD"], capture_output=True, text=True, check=True
    ).stdout.strip()


def python_inventory(python: str) -> list[dict[str, str]]:
    output = subprocess.run([python, "-I", "-c", _PYTHON_INVENTORY], capture_output=True, text=True, check=True)
    return [dict(row, ecosystem="python") for row in json.loads(output.stdout)]


def npm_inventory(lock_file: Path) -> list[dict[str, str]]:
    """Runtime (non-dev) packages of an npm v2/v3 lock file."""
    lock = json.loads(lock_file.read_text(encoding="utf-8"))
    rows = []
    for path, entry in sorted(lock.get("packages", {}).items()):
        if not path or entry.get("dev") or entry.get("devOptional"):
            continue
        name = entry.get("name") or path.rsplit("node_modules/", 1)[-1]
        rows.append({"ecosystem": "npm", "name": name, "version": entry.get("version", ""), "license": entry.get("license", "")})
    return rows


def cargo_inventory(manifest: Path) -> list[dict[str, str]]:
    output = subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--locked", "--manifest-path", str(manifest)],
        capture_output=True,
        text=True,
        check=True,
    )
    metadata = json.loads(output.stdout)
    workspace = set(metadata.get("workspace_members", []))
    return [
        {"ecosystem": "cargo", "name": p["name"], "version": p["version"], "license": p.get("license") or ""}
        for p in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"]))
        if p["id"] not in workspace
    ]


def build_manifest(args: argparse.Namespace) -> dict[str, Any]:
    repository = Path(__file__).resolve().parents[1]
    studio_meta = Path(args.studio_meta)
    versions = json.loads((studio_meta / "versions.json").read_text(encoding="utf-8"))
    studio_commit = (studio_meta / "studio-commit").read_text(encoding="utf-8").strip()
    packages: list[dict[str, str]] = []
    if args.python:
        packages += python_inventory(args.python)
    lock = studio_meta / "package-lock.json"
    if lock.is_file():
        packages += npm_inventory(lock)
    if args.cargo_manifest:
        packages += cargo_inventory(Path(args.cargo_manifest))
    artifacts = [
        {"name": Path(a).name, "size": Path(a).stat().st_size, "sha256": sha256(Path(a))} for a in args.artifacts
    ]
    return {
        "product": args.product,
        "version": args.version,
        "commit": git_commit(repository),
        "studio": studio_commit,
        "platform": versions.get("platform"),
        "components": {name: entry["commit"] for name, entry in versions.get("components", {}).items()},
        "artifacts": artifacts,
        "platforms": args.platform,
        "signing": {
            "status": "unsigned",
            "reason": "no signing certificate is configured for this product; verify the SHA-256 checksums instead",
        },
        "licenses": {
            "packages": packages,
            "unknown": sorted(f"{p['ecosystem']}:{p['name']}" for p in packages if not p["license"]),
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--product", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--studio-meta", required=True, help="directory with versions.json, studio-commit, package-lock.json")
    parser.add_argument("--python", help="the bundled interpreter, for the Python license inventory")
    parser.add_argument("--cargo-manifest", help="Cargo.toml of the shell, for the Rust license inventory")
    parser.add_argument("--platform", action="append", default=[], help="a platform this release was tested on")
    parser.add_argument("artifacts", nargs="+")
    args = parser.parse_args(argv)
    manifest = build_manifest(args)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    sums = "".join(f"{a['sha256']}  {a['name']}\n" for a in manifest["artifacts"])
    (args.out / "SHA256SUMS").write_text(sums, encoding="utf-8")
    print(
        f"{args.product} {args.version}: {len(manifest['artifacts'])} artifact(s), "
        f"{len(manifest['licenses']['packages'])} packages, {len(manifest['licenses']['unknown'])} without a license"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

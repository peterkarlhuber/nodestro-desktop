#!/usr/bin/env python3
"""Print the license texts of the Rust crates linked into the desktop shell (release notices).

    scripts/cargo_licenses.py app/Cargo.toml

Takes every non-workspace crate that `cargo metadata` resolves for x86_64 Linux and prints its name, version,
declared license and the text of each LICENSE, LICENCE, COPYING or NOTICE file in its source directory (or the file
its `license-file` names). A crate without such a file is listed with "no license file", so a release reviewer sees
it. Standard library only.
"""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys

FILES = re.compile(r"^(licen[cs]e|copying|notice)([.-]|$)", re.IGNORECASE)


def main(manifest: str) -> int:
    metadata = json.loads(
        subprocess.run(
            ["cargo", "metadata", "--format-version", "1", "--locked", "--manifest-path", manifest,
             "--filter-platform", "x86_64-unknown-linux-gnu"],
            capture_output=True, text=True, check=True,
        ).stdout
    )
    workspace = set(metadata["workspace_members"])
    used = {node["id"] for node in metadata["resolve"]["nodes"]}
    packages = sorted(
        (p for p in metadata["packages"] if p["id"] in used and p["id"] not in workspace),
        key=lambda p: (p["name"], p["version"]),
    )
    missing = 0
    out: list[str] = []
    for package in packages:
        source = Path(package["manifest_path"]).parent
        files = sorted(f for f in source.iterdir() if f.is_file() and FILES.match(f.name))
        if package.get("license_file"):
            files.append(source / package["license_file"])
        texts = [f.read_text(encoding="utf-8", errors="replace").strip() for f in files if f.is_file()]
        texts = list(dict.fromkeys(texts))
        declared = package.get("license") or "no declared license"
        out += ["=" * 80, f"{package['name']} {package['version']} (cargo) — {declared}", ""]
        if not texts:
            missing += 1
            out += ["(no license file in the crate)", ""]
        for text in texts:
            out += [text, ""]
    sys.stdout.write("\n".join(out) + "\n")
    print(f"cargo licenses: {len(packages)} crates, {missing} without a license file", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))

#!/usr/bin/env python3
"""Check the release scripts this repository copies from nodestro-server (backend audit D-15, issue #18).

    scripts/check_server_copies.py [--repository URL] [--root DIR]

The copies (``SHARED``) must be byte-identical to a version of the same file on nodestro-server's master: a change
that exists only here fails the check (exit 1), because the server's copy is the source and changes are made there
first. A copy that is an older version of the server's file is only a warning (``::warning::``, exit 0): sync it from
nodestro-server master. Compares git blob IDs, so only commits and trees are fetched (no file contents); no token.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

#: The files that are byte-identical copies of nodestro-server's (same path there).
SHARED = (
    "scripts/release_manifest.py",
    "scripts/test_release_manifest.py",
    "scripts/scan_secrets.py",
    "scripts/test_scan_secrets.py",
    "scripts/npm_licenses.mjs",
    "scripts/pin_distance.py",
    "scripts/test_pin_distance.py",
)
SERVER = "https://github.com/peterkarlhuber/nodestro-server.git"


def git(directory: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(directory), *args], check=True, capture_output=True, text=True).stdout


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repository", default=SERVER)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args(argv)
    failed = False
    with tempfile.TemporaryDirectory() as directory:
        server = Path(directory)
        git(server, "init", "-q")
        git(server, "remote", "add", "origin", args.repository)
        git(server, "fetch", "-q", "--filter=blob:none", "origin", "master")
        for path in SHARED:
            local = args.root / path
            if not local.is_file():
                print(f"::error::{path} is missing")
                failed = True
                continue
            mine = git(server, "hash-object", "--no-filters", str(local)).strip()
            current = git(server, "rev-parse", f"origin/master:{path}").strip()
            if mine == current:
                print(f"{path}: same as nodestro-server master")
                continue
            history = git(server, "log", "--format=%H", "origin/master", "--", path).split()
            versions: dict[str, str] = {}
            for commit in history:  # newest first; a commit that deleted the file has no blob
                found = subprocess.run(
                    ["git", "-C", str(server), "rev-parse", "-q", "--verify", f"{commit}:{path}"],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if found.returncode == 0:
                    versions.setdefault(found.stdout.strip(), commit)
            if mine in versions:
                print(
                    f"::warning::{path} is the version of nodestro-server {versions[mine][:7]}, not of master: "
                    "copy the file from nodestro-server master"
                )
            else:
                print(
                    f"::error::{path} differs from every version on nodestro-server master: change it there first, "
                    "then copy it here unchanged"
                )
                failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

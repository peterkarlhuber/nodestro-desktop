#!/usr/bin/env python3
"""Warn when a pinned Nodestro commit falls behind its repository's master (backend audit D-01, OPS3-06).

    scripts/pin_distance.py PIN_FILE [--grace-days DAYS] [--repository-url URL_TEMPLATE]

PIN_FILE is a JSON object (``studio.json``, ``components.json``) whose ``nodestro-*`` keys name full commit SHAs of
the public repositories ``https://github.com/peterkarlhuber/<key>.git``. For each pin it fetches that repository's
master (commits only, no file contents) and counts the first-parent commits of master after the pin, which are the
merge commits a pin cascade would move to. Commits younger than ``--grace-days`` (default 3) are not counted, so a
pull request right after a merge on master is not flagged before a cascade could have happened.

The result is a GitHub Actions ``::warning::`` annotation per lagging pin and a summary line; the exit code is 0
whether pins lag or not (the check never blocks a change). It is 2 when a pin is not a full SHA, cannot be fetched,
or is not on master, which CI reports as a failed (non-blocking) step. Standard library and git only; no token.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

REPOSITORY_URL = "https://github.com/peterkarlhuber/{name}.git"


def git(directory: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(directory), *args], check=True, capture_output=True, text=True
    ).stdout.strip()


def pins(path: Path) -> dict[str, str]:
    data = json.loads(path.read_text())
    found = {key: value for key, value in data.items() if key.startswith("nodestro-") and isinstance(value, str)}
    if not found:
        raise SystemExit(f"{path} names no nodestro-* pin")
    return found


def lag(directory: Path, name: str, sha: str, url: str, grace: dt.timedelta, now: dt.datetime) -> dict[str, object]:
    """The first-parent commits of master after ``sha`` that are older than ``grace``."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError(f"{name}: not a full commit SHA: {sha!r}")
    work = directory / name
    git(directory, "init", "-q", str(work))
    git(work, "remote", "add", "origin", url)
    git(work, "fetch", "-q", "--filter=blob:none", "origin", "master")
    if subprocess.run(
        ["git", "-C", str(work), "merge-base", "--is-ancestor", sha, "origin/master"], check=False
    ).returncode:
        raise ValueError(f"{name}: {sha} is not on master")
    rows = git(work, "log", "--first-parent", "--format=%H %ct", f"{sha}..origin/master").splitlines()
    newer = [(commit, dt.datetime.fromtimestamp(int(stamp), dt.UTC)) for commit, stamp in (r.split() for r in rows)]
    counted = [(commit, when) for commit, when in newer if now - when >= grace]
    pinned_at = dt.datetime.fromtimestamp(int(git(work, "log", "-1", "--format=%ct", sha)), dt.UTC)
    return {
        "name": name,
        "pin": sha,
        "master": git(work, "rev-parse", "origin/master"),
        "behind": len(counted),
        "behind_including_grace": len(newer),
        "oldest_missing": counted[-1][1].date().isoformat() if counted else None,
        "pin_date": pinned_at.date().isoformat(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pin_file", type=Path)
    parser.add_argument("--grace-days", type=float, default=3.0)
    parser.add_argument("--repository-url", default=REPOSITORY_URL, help="URL template with {name} (tests)")
    parser.add_argument("--now", help=argparse.SUPPRESS)  # tests: ISO time instead of the current time
    args = parser.parse_args(argv)
    now = dt.datetime.fromisoformat(args.now) if args.now else dt.datetime.now(dt.UTC)
    grace = dt.timedelta(days=args.grace_days)
    failed = False
    with tempfile.TemporaryDirectory() as directory:
        for name, sha in pins(args.pin_file).items():
            try:
                found = lag(Path(directory), name, sha, args.repository_url.format(name=name), grace, now)
            except (ValueError, subprocess.CalledProcessError) as error:
                detail = getattr(error, "stderr", "") or ""
                print(f"::error::pin {name}: {error} {detail}".strip())
                failed = True
                continue
            if found["behind"]:
                print(
                    f"::warning::{args.pin_file.name} pins {name} {sha[:7]} ({found['pin_date']}), "
                    f"{found['behind']} merge commit(s) behind master {str(found['master'])[:7]} "
                    f"(the oldest missing one is from {found['oldest_missing']}): run the pin cascade"
                )
            else:
                print(
                    f"{name} {sha[:7]} is current (master {str(found['master'])[:7]}; "
                    f"{found['behind_including_grace']} newer commit(s) within the {args.grace_days:g}-day grace)"
                )
    return 2 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

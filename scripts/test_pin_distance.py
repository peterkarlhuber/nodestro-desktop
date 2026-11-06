#!/usr/bin/env python3
"""Tests of pin_distance.py against local git repositories: a current pin, a lagging pin (warning, exit 0), the grace
period, and a pin that is not on master (exit 2). Run: python3 -I scripts/test_pin_distance.py"""

from __future__ import annotations

import contextlib
import datetime as dt
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pin_distance

DAY = 86400
NOW = 1_800_000_000  # a fixed "now" (2027-01-15) for the commit dates and --now


def git(directory: Path, *args: str, when: int | None = None) -> str:
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@example.com",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@example.com",
    }
    if when is not None:
        env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = f"@{when} +0000"
    return subprocess.run(
        ["git", "-C", str(directory), *args], check=True, capture_output=True, text=True, env=env
    ).stdout.strip()


class PinDistance(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "nodestro-studio"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "master")
        self.commits = []
        for days_ago in (30, 20, 10, 1):  # four merge commits on master, the last one yesterday
            git(self.repo, "commit", "-q", "--allow-empty", "-m", f"{days_ago} days ago", when=NOW - days_ago * DAY)
            self.commits.append(git(self.repo, "rev-parse", "HEAD"))
        git(self.repo, "checkout", "-q", "-b", "side", self.commits[0])
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "not on master", when=NOW - 5 * DAY)
        self.side = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "checkout", "-q", "master")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def run_check(self, sha: str, *extra: str) -> tuple[int, str]:
        pin_file = self.tmp / "studio.json"
        pin_file.write_text(json.dumps({"comment": "x", "nodestro-studio": sha}))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = pin_distance.main(
                [str(pin_file), "--repository-url", f"file://{self.tmp}/{{name}}", "--now", _iso(NOW), *extra]
            )
        return code, out.getvalue()

    def test_the_head_of_master_is_current(self) -> None:
        code, out = self.run_check(self.commits[-1])
        self.assertEqual(code, 0)
        self.assertNotIn("::warning::", out)
        self.assertIn("is current", out)

    def test_a_lagging_pin_warns_but_does_not_fail(self) -> None:
        code, out = self.run_check(self.commits[0])
        self.assertEqual(code, 0)
        # Three commits after the pin; the one from yesterday is within the default grace of 3 days.
        self.assertIn("::warning::studio.json pins nodestro-studio", out)
        self.assertIn("2 merge commit(s) behind master", out)

    def test_commits_within_the_grace_period_are_not_counted(self) -> None:
        code, out = self.run_check(self.commits[2])
        self.assertEqual(code, 0)
        self.assertNotIn("::warning::", out)
        code, out = self.run_check(self.commits[2], "--grace-days", "0")
        self.assertIn("1 merge commit(s) behind master", out)

    def test_a_pin_that_is_not_on_master_is_an_error(self) -> None:
        code, out = self.run_check(self.side)
        self.assertEqual(code, 2)
        self.assertIn("is not on master", out)

    def test_a_short_sha_is_an_error(self) -> None:
        code, out = self.run_check(self.commits[0][:12])
        self.assertEqual(code, 2)
        self.assertIn("not a full commit SHA", out)


def _iso(stamp: int) -> str:
    return dt.datetime.fromtimestamp(stamp, dt.UTC).isoformat()


if __name__ == "__main__":
    unittest.main()

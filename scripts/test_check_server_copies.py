#!/usr/bin/env python3
"""Tests of check_server_copies.py against a local stand-in for nodestro-server: identical copies pass, an older
version of the server's file warns (exit 0), a change that exists only here fails (exit 1), and a missing copy or
one the server does not have fails.
Run: python3 -I scripts/test_check_server_copies.py"""

from __future__ import annotations

import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_server_copies

ENV = {
    **os.environ,
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@example.com",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.com",
}


def git(directory: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(directory), *args], check=True, capture_output=True, env=ENV)


class ServerCopies(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.server = self.tmp / "server"
        self.desktop = self.tmp / "desktop"
        for path in check_server_copies.SHARED:
            for root in (self.server, self.desktop):
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_text(f"v1 of {path}\n")
        git(self.server, "init", "-q", "-b", "master")
        git(self.server, "add", "-A")
        git(self.server, "commit", "-q", "-m", "v1")

    def check(self) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = check_server_copies.main(["--repository", f"file://{self.server}", "--root", str(self.desktop)])
        return code, out.getvalue()

    def test_identical_copies_pass(self) -> None:
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertNotIn("::", out)

    def test_an_older_server_version_only_warns(self) -> None:
        first = check_server_copies.SHARED[0]
        (self.server / first).write_text("v2\n")
        git(self.server, "commit", "-q", "-am", "v2")
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertIn(f"::warning::{first} is the version of nodestro-server", out)

    def test_a_change_made_only_here_fails(self) -> None:
        first = check_server_copies.SHARED[0]
        (self.desktop / first).write_text("edited in the desktop repository\n")
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn(f"::error::{first} differs from every version", out)

    def test_a_file_the_server_deleted_and_restored_is_still_known(self) -> None:
        first = check_server_copies.SHARED[0]
        git(self.server, "rm", "-q", first)
        git(self.server, "commit", "-q", "-m", "removed")
        (self.server / first).write_text("v3\n")
        git(self.server, "add", first)
        git(self.server, "commit", "-q", "-m", "back")
        code, out = self.check()
        self.assertEqual(code, 0, out)
        self.assertIn("::warning::", out)

    def test_a_missing_copy_fails(self) -> None:
        (self.desktop / check_server_copies.SHARED[-1]).unlink()
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn("is missing", out)

    def test_a_copy_the_server_does_not_have_fails(self) -> None:
        last = check_server_copies.SHARED[-1]
        git(self.server, "rm", "-q", last)
        git(self.server, "commit", "-q", "-m", "not on the server")
        code, out = self.check()
        self.assertEqual(code, 1, out)
        self.assertIn(f"::error::{last} is not on nodestro-server master", out)


if __name__ == "__main__":
    unittest.main()

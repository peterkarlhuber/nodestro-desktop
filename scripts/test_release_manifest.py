#!/usr/bin/env python3
"""Tests of release_manifest.py: the manifest lists bundled binaries from their release files (and in the license
inventory), refuses an incomplete release file, and writes the checksums.
Run: python3 -I scripts/test_release_manifest.py"""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_manifest


class ReleaseManifest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        meta = self.tmp / "meta"
        meta.mkdir()
        (meta / "studio-commit").write_text("a" * 40 + "\n")
        (meta / "versions.json").write_text(
            json.dumps({"platform": "0.2.0", "components": {"nodestro-runtime": {"commit": "b" * 40}}})
        )
        self.meta = meta
        self.artifact = self.tmp / "app.tar.gz"
        self.artifact.write_bytes(b"archive")

    def write(self, *extra: str) -> dict:
        out = self.tmp / "out"
        argv = ["--product", "p", "--version", "v1.0.0-preview.1", "--out", str(out), "--studio-meta", str(self.meta)]
        argv += ["--commit", "c" * 40, *extra, str(self.artifact)]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(release_manifest.main(argv), 0)
        self.assertIn("app.tar.gz", (out / "SHA256SUMS").read_text())
        return json.loads((out / "release-manifest.json").read_text())

    def test_bundled_binaries_come_from_their_release_files(self) -> None:
        release = self.tmp / "OLLAMA-RELEASE"
        release.write_text("version=0.40.14\narchive=ollama-linux-amd64.tar.zst\nsha256=" + "d" * 64 + "\ngpu=no\n")
        cli = self.tmp / "docker-cli.release"
        cli.write_text(
            "version=29.9.2\nsource=https://download.docker.com/x.tgz\nsha256=" + "e" * 64 + "\nlicense=Apache-2.0\n"
        )
        manifest = self.write("--bundled", f"ollama={release}", "--bundled", f"docker-cli={cli}")
        self.assertEqual(
            manifest["bundled"],
            [
                {"name": "ollama", "version": "0.40.14", "sha256": "d" * 64, "source": "ollama-linux-amd64.tar.zst",
                 "license": ""},
                {"name": "docker-cli", "version": "29.9.2", "sha256": "e" * 64,
                 "source": "https://download.docker.com/x.tgz", "license": "Apache-2.0"},
            ],
        )  # fmt: skip
        # In the license inventory; one without a declared license is listed for the reviewer.
        self.assertIn({"ecosystem": "binary", "name": "docker-cli", "version": "29.9.2", "license": "Apache-2.0"},
                      manifest["licenses"]["packages"])  # fmt: skip
        self.assertEqual(manifest["licenses"]["unknown"], ["binary:ollama"])
        self.assertEqual(manifest["channel"], "preview")

    def test_without_bundled_binaries_the_list_is_empty(self) -> None:
        self.assertEqual(self.write()["bundled"], [])

    def test_an_incomplete_release_file_is_refused(self) -> None:
        release = self.tmp / "BROKEN"
        release.write_text("archive=x\n")
        with self.assertRaises(SystemExit) as refused:
            self.write("--bundled", f"thing={release}")
        self.assertIn("names no version, sha256", str(refused.exception))
        with self.assertRaises(SystemExit):
            self.write("--bundled", str(release))  # no NAME=


if __name__ == "__main__":
    unittest.main()

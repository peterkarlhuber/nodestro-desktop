#!/usr/bin/env python3
"""Tests of fetch_ollama.py without the network: a wrong checksum is refused before unpacking, unsafe archive members
are refused, the CUDA libraries are left out, and the release's sha256sum.txt is read correctly.
Run: python3 -I scripts/test_fetch_ollama.py"""

from __future__ import annotations

import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fetch_ollama

SCRIPT = Path(__file__).resolve().parent / "fetch_ollama.py"


def tgz(path: Path, members: list[tuple[str, bytes | None, str | None]]) -> None:
    """``(name, data, link)``: a file with data, a directory (``None``, ``None``) or a symbolic link."""
    with tarfile.open(path, "w:gz") as archive:
        for name, data, link in members:
            info = tarfile.TarInfo(name)
            if link is not None:
                info.type, info.linkname = tarfile.SYMTYPE, link
                archive.addfile(info)
            elif data is None:
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
            else:
                info.size, info.mode = len(data), 0o755
                archive.addfile(info, io.BytesIO(data))


class FetchOllama(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())

    def test_the_release_checksum_list_is_read_by_name(self) -> None:
        sums = "aaa  ./ollama-darwin.tgz\nbbb  ./ollama-linux-amd64.tar.zst\n"
        self.assertTrue(fetch_ollama.listed(sums, "ollama-linux-amd64.tar.zst", "bbb"))
        self.assertFalse(fetch_ollama.listed(sums, "ollama-linux-amd64.tar.zst", "aaa"))
        self.assertFalse(fetch_ollama.listed(sums, "ollama-linux-arm64.tar.zst", "bbb"))

    def test_a_wrong_checksum_is_refused_before_anything_is_unpacked(self) -> None:
        archive = self.dir / "fake.tgz"
        tgz(archive, [("ollama", b"#!/bin/sh\n", None)])
        license_file = self.dir / "LICENSE"
        license_file.write_text("not the license")
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), str(self.dir / "out"), "--platform", "darwin",
             "--archive", str(archive), "--license", str(license_file)],
            capture_output=True, text=True, check=False,
        )  # fmt: skip
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the pinned", result.stderr)
        self.assertFalse((self.dir / "out").exists())

    def test_unsafe_members_are_refused(self) -> None:
        for members in (
            [("../evil", b"x", None)],
            [("/etc/evil", b"x", None)],
            [("lib", None, None), ("lib/out", None, "../../outside")],
            [("lib", None, None), ("lib/abs", None, "/etc/passwd")],
        ):
            archive = self.dir / "bad.tgz"
            tgz(archive, members)
            target = self.dir / "t"
            target.mkdir(exist_ok=True)
            with self.assertRaises(SystemExit, msg=str(members)):
                fetch_ollama.unpack(archive, "bad.tgz", target, ())

    def test_the_gpu_libraries_are_left_out_with_their_links(self) -> None:
        archive = self.dir / "ok.tgz"
        tgz(
            archive,
            [
                ("bin/ollama", b"binary", None),
                ("lib/ollama/libggml-cpu.so", b"cpu", None),
                ("lib/ollama/cuda_v12/libcudart.so.12.8", b"cuda", None),
                ("lib/ollama/cuda_v12/libcudart.so.12", None, "libcudart.so.12.8"),
                ("lib/ollama/libggml.so", None, "libggml-cpu.so"),
            ],
        )
        target = self.dir / "unpacked"
        target.mkdir()
        fetch_ollama.unpack(archive, "ok.tgz", target, ("lib/ollama/cuda_v12",))
        self.assertEqual(fetch_ollama.find_binary(target), target / "bin" / "ollama")
        self.assertFalse((target / "lib/ollama/cuda_v12").exists())
        self.assertEqual((target / "lib/ollama/libggml.so").read_bytes(), b"cpu")

    def test_the_pins_are_sha256_values(self) -> None:
        for name, digest, _ in fetch_ollama.ARCHIVES.values():
            self.assertRegex(digest, r"^[0-9a-f]{64}$", name)
        self.assertEqual(len(hashlib.sha256(b"").hexdigest()), len(fetch_ollama.LICENSE_SHA256))


if __name__ == "__main__":
    unittest.main()

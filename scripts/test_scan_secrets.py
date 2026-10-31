#!/usr/bin/env python3
"""Tests of scan_secrets.py: real-looking secrets are found in files, nested archives and gzip layers; the
placeholders of third-party documentation are not. Run: python3 -I scripts/test_scan_secrets.py"""

from __future__ import annotations

import gzip
import io
import os
from pathlib import Path
import secrets
import string
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scan_secrets


def random_text(size: int, alphabet: str = string.ascii_letters + string.digits) -> str:
    return "".join(secrets.choice(alphabet) for _ in range(size))


def tar_bytes(files: dict[str, bytes], compress: bool = False) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    raw = buffer.getvalue()
    return gzip.compress(raw) if compress else raw


class ScanTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        os.environ.pop("NODESTRO_SCAN_SECRETS", None)

    def scan(self, *paths: Path) -> set[tuple[str, str]]:
        values = scan_secrets.exact_values()
        found = set()
        for path in paths:
            for name, rule in scan_secrets.scan_path(path, values):
                found.add((name.replace(str(self.dir), ""), rule))
        return found

    def test_finds_secrets_in_plain_files(self) -> None:
        cases = {
            "github-token": "ghp_" + random_text(36),
            "anthropic-key": "sk-ant-api03-" + random_text(60),
            "openai-key": "sk-proj-" + random_text(48),
            "aws-access-key": "AKIA" + random_text(16, string.ascii_uppercase + string.digits),
            "x-access-token-url": f"https://x-access-token:{random_text(40)}@github.com/o/r",
            "credential-url": f"https://deploy:{random_text(20)}@registry.internal/simple",
            "private-key": "-----BEGIN RSA PRIVATE KEY-----\n" + random_text(64) + "\n",
        }
        (self.dir / "service-account.json").write_text(
            '{"private_key": "-----BEGIN PRIVATE KEY-----\\n' + random_text(64) + '\\n"}'
        )
        for rule, value in cases.items():
            (self.dir / f"{rule}.txt").write_text(f"config = {value}\n")
        found = {rule for _, rule in self.scan(self.dir)}
        self.assertEqual(found, set(cases))

    def test_finds_secrets_in_nested_archives_and_gzip_layers(self) -> None:
        token = "ghp_" + random_text(36)
        layer = tar_bytes({"opt/app/settings.py": f"TOKEN = '{token}'\n".encode()}, compress=True)
        image = tar_bytes({"blobs/sha256/abc": layer, "index.json": b"{}"})
        (self.dir / "image.tar").write_bytes(image)
        (self.dir / "archive.tar.gz").write_bytes(tar_bytes({"inner.tar": image}, compress=True))
        found = self.scan(self.dir)
        self.assertIn(("/image.tar!blobs/sha256/abc!opt/app/settings.py", "github-token"), found)
        self.assertIn(("/archive.tar.gz!inner.tar!blobs/sha256/abc!opt/app/settings.py", "github-token"), found)

    def test_finds_exact_build_values_and_credential_files(self) -> None:
        value = random_text(30)
        os.environ["NODESTRO_SCAN_SECRETS"] = f"\n{value}\nshort\n"
        (self.dir / "build.log").write_text(f"cloned with {value}\n")
        (self.dir / ".git-credentials").write_text("anything\n")
        (self.dir / ".npmrc").write_text("//registry.npmjs.org/:_authToken=abc\n")
        found = {rule for _, rule in self.scan(self.dir)}
        self.assertEqual(found, {"build-secret", "credential-file", "npm-token"})

    def test_a_secret_across_a_read_boundary_is_found(self) -> None:
        token = "ghp_" + random_text(36)
        data = b" " * (scan_secrets.CHUNK - 10) + token.encode() + b"\n"
        (self.dir / "big.bin").write_bytes(data)
        self.assertEqual({rule for _, rule in self.scan(self.dir)}, {"github-token"})

    def test_ignores_documentation_placeholders(self) -> None:
        (self.dir / "docs.py").write_text(
            "\n".join(
                [
                    "token = 'ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'",
                    "url = 'https://username:password@host.com'",
                    "url = 'https://jo%40email.com:a%20secret@www.example.com'",
                    "url = 'https://x-access-token:${NODESTRO_READ}@github.com/'",
                    '_SK_START = b"-----BEGIN OPENSSH PRIVATE KEY-----"',
                    '"private_key": "-----BEGIN EC PRIVATE KEY-----\\n<key bytes>\\n"',
                ]
            )
        )
        self.assertEqual(self.scan(self.dir), set())

    def test_zstd_layers_are_reported_as_not_scanned(self) -> None:
        (self.dir / "image.tar").write_bytes(tar_bytes({"blobs/sha256/z": b"\x28\xb5\x2f\xfd" + b"\0" * 100}))
        self.assertEqual({rule for _, rule in self.scan(self.dir)}, {"not-scanned-zstd"})


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Refuse a release artifact that contains a secret (release checklist).

    scripts/scan_secrets.py [--allow FILE] PATH...

Each PATH is a directory, a file, or a tar archive (``.tar``, ``.tar.gz``, a ``docker save`` image). Archives are
read member by member, also archives inside archives (image layers), so nothing is unpacked to disk.

A file fails the scan when:

- its content matches a known credential format: GitHub, Anthropic, OpenAI, AWS and Slack tokens, private keys,
  URLs with a user name and password, or ``x-access-token`` URLs;
- its content holds one of the exact values in the environment variable ``NODESTRO_SCAN_SECRETS`` (one per line;
  CI passes the tokens it used for the build, so a leaked build token is found in any form it was written);
- its name is a typical credential file (``.netrc``, ``.git-credentials``, ``.env``, SSH private keys, ``.pypirc``,
  ``.npmrc`` with a token).

Findings name the file and the rule, never the matched text. ``--allow`` names a file of ``<glob> <rule>`` lines
(``#`` starts a reason) for known test fixtures of third-party packages; every allowed finding is still listed.
Standard library only.
"""

from __future__ import annotations

import argparse
from collections.abc import Iterator
import fnmatch
import io
import os
from pathlib import Path
import re
import sys
import tarfile
from typing import IO, Any
import zlib

RULES: dict[str, re.Pattern[bytes]] = {
    "github-token": re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})"),
    "anthropic-key": re.compile(rb"\bsk-ant-(?:api|admin)\d{2}-[A-Za-z0-9_-]{40,}"),
    "openai-key": re.compile(rb"\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{40,}"),
    "aws-access-key": re.compile(rb"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
    "slack-token": re.compile(rb"\bxox[abprs]-[0-9]{6,}-[A-Za-z0-9-]{10,}"),
    # A key needs its body: the marker alone is how parsers and documentation name the format. JSON files write
    # the line breaks as "\n".
    "private-key": re.compile(
        rb"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY(?: BLOCK)?-----(?:\r?\n|\\n)"
        rb"(?:[A-Za-z-]+: [^\r\n\\]*(?:\r?\n|\\n))*(?:\r?\n|\\n)?[A-Za-z0-9+/]{60,}"
    ),
    "x-access-token-url": re.compile(rb"x-access-token:([^@\s'\"]{8,})@"),
    "credential-url": re.compile(rb"\bhttps?://[A-Za-z0-9._~%-]{1,64}:([A-Za-z0-9._~%!$&*+,;=-]{8,})@[A-Za-z0-9.-]+"),
}
CREDENTIAL_FILES = (".netrc", ".git-credentials", ".env", ".pypirc", "id_rsa", "id_ecdsa", "id_ed25519", "id_dsa")
NPMRC_TOKEN = re.compile(rb"_authToken\s*=\s*[^\s$]")
CHUNK = 16 * 1024 * 1024
OVERLAP = 4096
# Documentation and tests write placeholders where a value would be: "ghp_xxxx...", "user:password@host".
PLACEHOLDER = re.compile(rb"(?i)pass|secret|token|example|changeme|dummy|placeholder|x{4}|\*{3}|<|\{|\$")


def plausible(rule: str, match: re.Match[bytes]) -> bool:
    if rule == "private-key":
        return True
    text = match.group(1 if match.re.groups else 0)  # the secret part of a URL rule
    return len(set(text)) >= 8 and not PLACEHOLDER.search(text)


def exact_values() -> list[bytes]:
    values = [v.strip() for v in os.environ.get("NODESTRO_SCAN_SECRETS", "").splitlines()]
    return [v.encode() for v in values if len(v) >= 8]


def chunks(handle: IO[bytes]) -> Iterator[bytes]:
    tail = b""
    while True:
        block = handle.read(CHUNK)
        if not block:
            return
        yield tail + block
        tail = block[-OVERLAP:]


def scan_stream(name: str, handle: IO[bytes], values: list[bytes]) -> set[str]:
    found: set[str] = set()
    base = name.rsplit("/", 1)[-1].rsplit("!", 1)[-1]
    if base in CREDENTIAL_FILES:
        found.add("credential-file")
    for data in chunks(handle):
        for rule, pattern in RULES.items():
            if rule not in found and any(plausible(rule, m) for m in pattern.finditer(data)):
                found.add(rule)
        if base == ".npmrc" and NPMRC_TOKEN.search(data):
            found.add("npm-token")
        if any(v in data for v in values):
            found.add("build-secret")
    return found


class Peeked(io.RawIOBase):
    """A forward-only stream whose first bytes were already read to recognize its format."""

    def __init__(self, head: bytes, rest: IO[bytes]) -> None:
        self.head, self.rest = head, rest

    def readable(self) -> bool:
        return True

    def readinto(self, buffer: Any) -> int:
        if self.head:
            size = min(len(buffer), len(self.head))
            buffer[:size], self.head = self.head[:size], self.head[size:]
            return size
        data = self.rest.read(len(buffer))
        buffer[: len(data)] = data
        return len(data)


def kind_of(head: bytes) -> str:
    """Return "tar", "tar.gz", "zstd" (layers this scanner cannot read) or "" for any other file."""
    if head[257:262] == b"ustar":
        return "tar"
    if head[:2] == b"\x1f\x8b":
        try:
            inner = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(head, 512)
        except zlib.error:
            return ""
        return "tar.gz" if inner[257:262] == b"ustar" else ""
    if head[:4] == b"\x28\xb5\x2f\xfd":
        return "zstd"
    return ""


def scan_any(name: str, handle: IO[bytes], values: list[bytes]) -> Iterator[tuple[str, str]]:
    head = handle.read(64 * 1024)
    stream = io.BufferedReader(Peeked(head, handle), CHUNK)
    kind = kind_of(head)
    if kind == "zstd":
        yield name, "not-scanned-zstd"
    elif kind:
        with tarfile.open(fileobj=stream, mode="r|gz" if kind == "tar.gz" else "r|") as archive:
            for member in archive:
                inner = archive.extractfile(member) if member.isfile() else None
                if inner is not None:
                    yield from scan_any(f"{name}!{member.name}", inner, values)
    else:
        for rule in scan_stream(name, stream, values):
            yield name, rule


def scan_path(path: Path, values: list[bytes]) -> Iterator[tuple[str, str]]:
    files = sorted(p for p in path.rglob("*") if p.is_file() and not p.is_symlink()) if path.is_dir() else [path]
    for file in files:
        with file.open("rb") as handle:
            yield from scan_any(str(file), handle, values)


def load_allow(path: str | None) -> list[tuple[str, str]]:
    if not path:
        return []
    rows = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            glob, rule = line.split()
            rows.append((glob, rule))
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--allow", help="file of '<glob> <rule>' lines for known third-party test fixtures")
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args(argv)
    allow = load_allow(args.allow)
    values = exact_values()
    failed = allowed = 0
    for path in args.paths:
        for name, rule in scan_path(path, values):
            if rule != "build-secret" and any(r == rule and fnmatch.fnmatch(name, g) for g, r in allow):
                allowed += 1
                print(f"allowed  {rule}: {name}")
            else:
                failed += 1
                print(f"SECRET   {rule}: {name}")
    print(f"secret scan: {failed} finding(s), {allowed} allowed, {len(values)} exact build value(s) checked")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

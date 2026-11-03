#!/usr/bin/env python3
"""Fetch the local model runtime (Ollama) that the desktop app bundles, and check it against the pinned release.

    python3 scripts/fetch_ollama.py <backend-dir> [--platform linux-x86_64] [--archive FILE] [--gpu]
                                    [--check-against PYTHON]

The archive of the pinned Ollama release is downloaded from its GitHub release (or taken from ``--archive``, for an
offline build) and must have the SHA-256 pinned below before anything is unpacked. The pins are the values of the
release's ``sha256sum.txt``; a download also fetches that file and refuses a pin it does not list. Unpacking refuses
absolute paths, ``..``, links that leave the target, hard links and device files. The result is
``<backend-dir>/ollama/`` (the archive's own layout; the executable is ``bin/ollama``, ``ollama`` or ``ollama.exe``)
with ``OLLAMA-RELEASE`` (version, archive, SHA-256) and Ollama's ``LICENSE`` (MIT, also pinned by SHA-256).

The NVIDIA CUDA libraries of the Linux x86_64 archive (about 2.4 GB) are left out unless ``--gpu``: the bundle keeps
the CPU and Vulkan backends (about 110 MB). The app passes the executable to the backend as ``NODESTRO_OLLAMA_BINARY``
(nodestro-runtime ``docs/local-models.md``), which runs it as a managed child process.

``--check-against PYTHON`` compares the pins with ``orkexa.local.install`` in that interpreter (the bundled backend):
the desktop app and the runtime must name the same release. It is skipped when that Orkexa has no ``orkexa.local``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

VERSION = "0.40.14"
RELEASE = f"https://github.com/ollama/ollama/releases/download/v{VERSION}"
#: platform -> (archive, SHA-256 from the release's sha256sum.txt, directories left out without --gpu)
ARCHIVES: dict[str, tuple[str, str, tuple[str, ...]]] = {
    "linux-x86_64": (
        "ollama-linux-amd64.tar.zst",
        "993e83d08c3d13d17c55009a3e2664c8a25445e644aec3a68bef5abb6abce67d",
        ("lib/ollama/cuda_v12", "lib/ollama/cuda_v13"),
    ),
    "linux-arm64": (
        "ollama-linux-arm64.tar.zst",
        "39bb333b7b4c0bafcdd7fad35eab1ae9aaf4518ea0f2c731de4376e3a29c94d0",
        (),
    ),
    "darwin": ("ollama-darwin.tgz", "f3bf9a528e908da0da5a2b3a4ad3252a369d62186501dc4880261e8d9023bff5", ()),
    "windows-x86_64": (
        "ollama-windows-amd64.zip",
        "65d68cade6cf6375f398b518224f8c8a15e062387f38cf477abfc848de7e7e29",
        ("lib/ollama/cuda_v12", "lib/ollama/cuda_v13"),
    ),
    "windows-arm64": (
        "ollama-windows-arm64.zip",
        "df8a4e954587ac65ba52ec26b453490a21cd58f80b55f75cf0d706f1506764a8",
        (),
    ),
}
LICENSE_URL = f"https://raw.githubusercontent.com/ollama/ollama/v{VERSION}/LICENSE"
LICENSE_SHA256 = "5934ed2ce0d15154bcdb9c85203210abac0da4314af34081e36df4599f90b226"
MAX_ARCHIVE = 4 * 1024**3
MAX_UNPACKED = 8 * 1024**3
MAX_MEMBERS = 20_000


def fail(message: str) -> None:
    sys.exit(f"fetch_ollama: {message}")


def this_platform() -> str:
    system = platform.system().lower()
    machine = {"amd64": "x86_64", "x64": "x86_64", "aarch64": "arm64"}.get(
        platform.machine().lower(), platform.machine().lower()
    )
    return "darwin" if system == "darwin" else f"{system}-{machine}"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(4 * 1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def download(url: str, target: Path, limit: int) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "nodestro-desktop-build"})
    with urllib.request.urlopen(request, timeout=120) as response, target.open("wb") as out:
        if not response.geturl().startswith("https://"):
            fail(f"{url} was redirected to a non-https address")
        done = 0
        while block := response.read(1024 * 1024):
            done += len(block)
            if done > limit:
                fail(f"{url} is larger than allowed")
            out.write(block)


def listed(sums: str, name: str, expected: str) -> bool:
    for line in sums.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].removeprefix("./") == name:
            return parts[0] == expected
    return False


def safe(name: str) -> PurePosixPath:
    path = PurePosixPath(name.replace("\\", "/"))
    if path.is_absolute() or ".." in path.parts or not path.parts or ":" in path.parts[0]:
        fail(f"refusing archive member {name!r}")
    return path


def inside(base: Path, target: Path) -> bool:
    try:
        target.resolve().relative_to(base.resolve())
    except ValueError:
        return False
    return True


def tar_stream(archive: Path, name: str) -> tuple[tarfile.TarFile, subprocess.Popen[bytes] | None]:
    if not name.endswith(".tar.zst"):
        return tarfile.open(archive, mode="r:gz"), None
    try:
        import zstandard  # type: ignore[import-not-found]
    except ImportError:
        if shutil.which("zstd") is None:
            fail("unpacking .tar.zst needs the zstd command or the Python package zstandard")
        process = subprocess.Popen(["zstd", "-dc", str(archive)], stdout=subprocess.PIPE)
        assert process.stdout is not None
        return tarfile.open(fileobj=process.stdout, mode="r|"), process
    return tarfile.open(fileobj=zstandard.ZstdDecompressor().stream_reader(archive.open("rb")), mode="r|"), None


def unpack(archive: Path, name: str, target: Path, skip: tuple[str, ...]) -> None:
    unpacked = members = 0

    def counted(size: int) -> None:
        nonlocal unpacked, members
        members += 1
        unpacked += size
        if members > MAX_MEMBERS or unpacked > MAX_UNPACKED:
            fail("the archive unpacks to more than allowed")

    def skipped(path: PurePosixPath) -> bool:
        return any(str(path) == prefix or str(path).startswith(prefix + "/") for prefix in skip)

    if name.endswith(".zip"):
        with zipfile.ZipFile(archive) as bundle:
            for info in bundle.infolist():
                path = safe(info.filename)
                counted(info.file_size)
                if skipped(path):
                    continue
                if stat.S_ISLNK(info.external_attr >> 16):
                    fail(f"refusing link {info.filename!r} in a zip archive")
                destination = target / path
                if info.is_dir():
                    destination.mkdir(parents=True, exist_ok=True)
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(info) as source, destination.open("wb") as out:
                    shutil.copyfileobj(source, out)
        return
    links: list[tuple[Path, str]] = []
    bundle, process = tar_stream(archive, name)
    with bundle:
        for member in bundle:
            path = safe(member.name)
            counted(member.size if member.isfile() else 0)
            if skipped(path):
                continue
            destination = target / path
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            elif member.issym():
                link = PurePosixPath(member.linkname)
                if link.is_absolute() or not inside(target, destination.parent / link):
                    fail(f"refusing link {member.name!r} -> {member.linkname!r}")
                links.append((destination, member.linkname))
            elif member.isfile():
                destination.parent.mkdir(parents=True, exist_ok=True)
                extracted = bundle.extractfile(member)
                if extracted is None:
                    fail(f"unreadable member {member.name!r}")
                with destination.open("wb") as out:
                    shutil.copyfileobj(extracted, out)
                os.chmod(destination, 0o755 if member.mode & 0o111 else 0o644)
            else:
                fail(f"refusing special file {member.name!r}")
    if process is not None and process.wait() != 0:
        fail("zstd could not unpack the archive")
    for destination, linkname in links:
        if skipped(PurePosixPath(os.path.relpath(destination.parent / linkname, target))):
            continue  # a link into a left-out directory
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.symlink_to(linkname)


def find_binary(root: Path) -> Path | None:
    for candidate in (root / "bin" / "ollama", root / "ollama", root / "ollama.exe"):
        if candidate.is_file():
            return candidate
    return None


def check_against(python: str) -> None:
    script = (
        "import importlib.util, json\n"
        "try:\n    present = importlib.util.find_spec('orkexa.local') is not None\n"
        "except ModuleNotFoundError:\n    present = False\n"
        "if not present:\n    print('null')\n"
        "else:\n    from orkexa.local import install\n"
        "    print(json.dumps({'version': install.OLLAMA_VERSION,"
        " 'archives': {a.name: a.sha256 for a in install.RUNTIME_ARTIFACTS}}))\n"
    )
    found = json.loads(subprocess.run([python, "-I", "-c", script], capture_output=True, text=True, check=True).stdout)
    if found is None:
        print("fetch_ollama: this Orkexa has no orkexa.local yet; pins not compared", file=sys.stderr)
        return
    ours = {archive: digest for archive, digest, _ in ARCHIVES.values()}
    if found["version"] != VERSION or found["archives"] != ours:
        fail(f"the pins differ from orkexa.local.install (Ollama {found['version']}): update this script")
    print(f"fetch_ollama: pins agree with orkexa.local.install (Ollama {VERSION})")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("backend_dir", type=Path)
    parser.add_argument("--platform", default=this_platform(), choices=sorted(ARCHIVES))
    parser.add_argument("--archive", type=Path, help="a release archive on this computer (offline build)")
    parser.add_argument("--license", type=Path, help="Ollama's LICENSE file on this computer (offline build)")
    parser.add_argument("--gpu", action="store_true", help="keep the NVIDIA CUDA libraries")
    parser.add_argument("--check-against", metavar="PYTHON", help="compare the pins with orkexa.local in PYTHON")
    options = parser.parse_args()
    if options.check_against:
        check_against(options.check_against)
    name, expected, gpu_dirs = ARCHIVES[options.platform]
    target = options.backend_dir / "ollama"
    with tempfile.TemporaryDirectory(prefix="nodestro-ollama-") as scratch:
        work = Path(scratch)
        archive = options.archive
        if archive is None:
            sums = work / "sha256sum.txt"
            download(f"{RELEASE}/sha256sum.txt", sums, 1024 * 1024)
            if not listed(sums.read_text(encoding="utf-8"), name, expected):
                fail(f"the release's sha256sum.txt does not list {name} with the pinned SHA-256")
            archive = work / name
            download(f"{RELEASE}/{name}", archive, MAX_ARCHIVE)
        if not archive.is_file() or archive.stat().st_size > MAX_ARCHIVE:
            fail(f"{archive} is not a file or larger than allowed")
        actual = sha256(archive)
        if actual != expected:
            fail(f"{archive.name}: SHA-256 {actual} does not match the pinned {expected} of Ollama {VERSION}")
        license_file = options.license
        if license_file is None:
            license_file = work / "LICENSE"
            download(LICENSE_URL, license_file, 64 * 1024)
        if sha256(license_file) != LICENSE_SHA256:
            fail("Ollama's LICENSE does not match its pinned SHA-256")
        unpacked = work / "ollama"
        unpacked.mkdir()
        unpack(archive, name, unpacked, () if options.gpu else gpu_dirs)
        binary = find_binary(unpacked)
        if binary is None:
            fail("the archive contains no ollama executable")
        binary.chmod(binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        shutil.copyfile(license_file, unpacked / "LICENSE")
        (unpacked / "OLLAMA-RELEASE").write_text(
            f"version={VERSION}\narchive={name}\nsha256={expected}\ngpu={'yes' if options.gpu else 'no'}\n",
            encoding="utf-8",
        )
        if target.exists():
            shutil.rmtree(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(unpacked), target)
    binary = find_binary(target)
    assert binary is not None
    if options.platform == this_platform():
        # The client prints its own version (and a warning that no server runs); it starts nothing.
        shown = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=60, check=False)
        if VERSION not in shown.stdout + shown.stderr:
            fail(f"{binary} --version does not name {VERSION}: {shown.stdout}{shown.stderr}")
    size = sum(path.stat().st_size for path in target.rglob("*") if path.is_file() and not path.is_symlink())
    print(
        f"fetch_ollama: Ollama {VERSION} ({name}, {size / 1e6:.0f} MB) in {target}; executable {binary.relative_to(options.backend_dir)}"
    )


if __name__ == "__main__":
    main()

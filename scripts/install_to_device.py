#!/usr/bin/env python3
"""Transfer and install an audited BeanBao .tar release over paired root SSH."""

from __future__ import annotations

import argparse
import hashlib
import io
import re
import shlex
import subprocess
import sys
import tarfile
from pathlib import Path


PACKAGES = (
    "dev.beanbao.bridge",
    "dev.beanbao.agent",
    "dev.beanbao.deliverybrowser",
    "dev.beanbao.app",
)
MAX_ARCHIVE_BYTES = 100 * 1024 * 1024
REMOTE_PREFLIGHT = """set -eu
work=$(mktemp -d /tmp/beanbao-install.XXXXXXXX)
trap 'rm -r "$work"' EXIT
cat > "$work/release.tar"
cd "$work"
tar -xf release.tar
sh install.sh --dry-run
"""


def validate_archive(data: bytes, expected_sha256: str | None) -> str:
    if not data or len(data) > MAX_ARCHIVE_BYTES:
        raise ValueError("Release archive is empty or exceeds 100 MiB")
    digest = hashlib.sha256(data).hexdigest()
    if expected_sha256 and digest != expected_sha256.lower():
        raise ValueError("Release archive SHA-256 does not match --sha256")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
        members = archive.getmembers()
        names = [member.name for member in members]
        if len(names) != len(set(names)) or any(not member.isfile() or "/" in member.name
                                               or member.name.startswith(".") for member in members):
            raise ValueError("Release archive has duplicate, nested, or non-file members")
        package_names = [name for name in names if name.endswith(".deb")]
        if set(names) != set(package_names) | {"SHA256SUMS", "install.sh", "INSTALL.md"}:
            raise ValueError("Release archive has missing or unexpected members")
        if len(package_names) != len(PACKAGES) or any(
                len([name for name in package_names if re.fullmatch(
                    re.escape(package) + r"_[0-9][A-Za-z0-9.+~:-]*_iphoneos-arm64e\.deb", name)]) != 1
                for package in PACKAGES):
            raise ValueError("Release archive does not contain exactly four RootHide packages")
        manifest = archive.extractfile("SHA256SUMS")
        if manifest is None:
            raise ValueError("Release archive is missing SHA256SUMS")
        lines = manifest.read().decode("ascii").splitlines()
        checksums: dict[str, str] = {}
        for line in lines:
            match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
            if not match or match.group(2) in checksums:
                raise ValueError("Release checksum manifest is malformed")
            checksums[match.group(2)] = match.group(1)
        if set(checksums) != set(package_names):
            raise ValueError("Release checksum manifest does not match packages")
        for name in package_names:
            item = archive.extractfile(name)
            if item is None or hashlib.sha256(item.read()).hexdigest() != checksums[name]:
                raise ValueError(f"Package checksum mismatch: {name}")
    return digest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="Uncompressed BeanBao release .tar")
    parser.add_argument("--host", required=True, help="Paired SSH host or forwarded address")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--identity", required=True, type=Path, help="Root SSH private key")
    parser.add_argument("--known-hosts", required=True, type=Path)
    parser.add_argument("--sha256", required=True, help="Expected published archive SHA-256")
    parser.add_argument("--check-only", action="store_true", help="Transfer and run phone preflight only")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9.\-:\[\]]+", args.host) or not 1 <= args.port <= 65535:
        parser.error("Invalid SSH host or port")
    if args.sha256 and not re.fullmatch(r"[0-9a-fA-F]{64}", args.sha256):
        parser.error("--sha256 must contain exactly 64 hexadecimal characters")
    if not args.identity.is_file() or not args.known_hosts.is_file():
        parser.error("SSH identity and known-hosts file must exist")
    try:
        archive_data = args.archive.read_bytes()
        digest = validate_archive(archive_data, args.sha256)
    except (OSError, ValueError, tarfile.TarError, UnicodeError) as error:
        parser.error(str(error))
    remote_script = REMOTE_PREFLIGHT + ("sh install.sh\n" if not args.check_only else "")
    ssh = ["ssh", "-T", "-i", str(args.identity), "-p", str(args.port),
           "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
           "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={args.known_hosts}",
           f"root@{args.host}", "sh -c " + shlex.quote(remote_script)]
    print(f"Release SHA-256: {digest}", flush=True)
    result = subprocess.run(ssh, input=archive_data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=180)
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())

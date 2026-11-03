#!/usr/bin/env python3
"""Check the desktop transfer boundary without connecting to a phone."""

from __future__ import annotations

import hashlib
import io
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts import install_to_device


def release_archive(*, bad_package=False, extra_name=None, symlink=False) -> bytes:
    files = {f"{name}_1.0_iphoneos-arm64e.deb": name.encode()
             for name in install_to_device.PACKAGES}
    manifest = "".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n"
                       for name, data in files.items()).encode()
    if bad_package:
        files[next(iter(files))] = b"changed"
    files.update({"SHA256SUMS": manifest, "install.sh": b"#!/bin/sh\n",
                  "INSTALL.md": b"Test release\n"})
    if extra_name:
        files[extra_name] = b"extra"
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as archive:
        for name, data in files.items():
            item = tarfile.TarInfo(name)
            item.size = len(data)
            if symlink and name == "install.sh":
                item.type = tarfile.SYMTYPE
                item.linkname = "/tmp/other"
                item.size = 0
                archive.addfile(item)
            else:
                archive.addfile(item, io.BytesIO(data))
    return output.getvalue()


class DeviceTransferTests(unittest.TestCase):
    def test_valid_release_and_published_digest(self):
        data = release_archive()
        digest = hashlib.sha256(data).hexdigest()
        self.assertEqual(install_to_device.validate_archive(data, digest), digest)
        with self.assertRaisesRegex(ValueError, "archive SHA-256"):
            install_to_device.validate_archive(data, "0" * 64)

    def test_rejects_bad_package_and_tar_tricks(self):
        for data in (release_archive(bad_package=True),
                     release_archive(extra_name="../outside"),
                     release_archive(symlink=True)):
            with self.subTest(data=hashlib.sha256(data).hexdigest()):
                with self.assertRaises(ValueError):
                    install_to_device.validate_archive(data, None)

    def test_check_only_streams_validated_bytes_with_strict_host_key(self):
        data = release_archive()
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / "release.tar"
            archive.write_bytes(data)
            identity = Path(folder) / "key"
            known_hosts = Path(folder) / "known_hosts"
            identity.write_bytes(b"test key")
            known_hosts.write_bytes(b"test host")
            with patch.object(sys, "argv", ["install_to_device.py", str(archive),
                                           "--host", "127.0.0.1", "--port", "22326",
                                           "--identity", str(identity),
                                           "--known-hosts", str(known_hosts),
                                           "--sha256", hashlib.sha256(data).hexdigest(),
                                           "--check-only"]), patch.object(
                                               install_to_device.subprocess, "run") as run:
                run.return_value.returncode = 0
                run.return_value.stdout = b""
                run.return_value.stderr = b""
                self.assertEqual(install_to_device.main(), 0)
                args, kwargs = run.call_args
                self.assertEqual(kwargs["input"], data)
                command = args[0]
                self.assertIn("StrictHostKeyChecking=yes", command)
                self.assertIn("root@127.0.0.1", command)
                self.assertIn("sh install.sh --dry-run", command[-1])
                self.assertNotIn("\nsh install.sh\n", command[-1])


if __name__ == "__main__":
    unittest.main()

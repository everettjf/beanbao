#!/usr/bin/env python3
"""Reject forbidden helper names and routes in a BeanBao roothide deb."""
import argparse
import io
import lzma
import subprocess
import tarfile
from pathlib import Path

FORBIDDEN = ("appsync", "appinst", "roothelper", "mcp-root", "mcp-ldid",
             "paddle", "onnx", "upload_file", "download_file", "install_app",
             "uninstall_app", "run_command")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("package", type=Path)
    args = parser.parse_args()
    members = subprocess.check_output(["ar", "t", str(args.package)], text=True).splitlines()
    data_name = next(name for name in members if name.startswith("data.tar."))
    data = subprocess.check_output(["ar", "p", str(args.package), data_name])
    if data_name.endswith(".lzma"):
        data = lzma.decompress(data)
    elif data_name.endswith(".gz"):
        import gzip
        data = gzip.decompress(data)
    else:
        raise SystemExit(f"unsupported archive: {data_name}")
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        files = [member for member in archive.getmembers() if member.isfile()]
        paths = [member.name for member in files]
        if any(term in path.lower() for path in paths for term in FORBIDDEN):
            raise SystemExit("forbidden path in package")
        dylibs = [member for member in files if member.name.endswith(".dylib")]
        if len(dylibs) != 1 or not dylibs[0].name.endswith("BeanBaoBridge.dylib"):
            raise SystemExit("unexpected dynamic libraries")
        expected = {"Library/MobileSubstrate/DynamicLibraries/BeanBaoBridge.dylib",
                    "Library/MobileSubstrate/DynamicLibraries/BeanBaoBridge.plist",
                    "usr/bin/beanbaoctl",
                    "usr/share/doc/beanbao/ios-mcp-LICENSE",
                    "usr/share/doc/beanbao/ios-mcp-NOTICE"}
        if set(paths) != expected:
            raise SystemExit(f"unexpected package paths: {set(paths) - expected}")
        binaries = [member for member in files if member.name.endswith(".dylib") or member.name.endswith("/beanbaoctl")]
        present = [term for term in FORBIDDEN if any(term.encode() in archive.extractfile(member).read().lower() for member in binaries)]
        if present:
            raise SystemExit(f"forbidden binary markers: {present}")
    print("PASS: package contains only the restricted bridge and no install/shell/file routes")
    for path in paths:
        print(path)


if __name__ == "__main__":
    main()

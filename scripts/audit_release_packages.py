#!/usr/bin/env python3
"""Verify the three RootHide packages form the intended BeanBao release."""

import argparse
import gzip
import io
import lzma
import plistlib
import re
import struct
import subprocess
import tarfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
AGENT_FILES = {
    "Library/LaunchDaemons/dev.beanbao.agent.plist",
    "usr/bin/beanbaoagentctl",
    "usr/bin/beanbaod",
    "usr/share/doc/beanbao/palmino-harness-LICENSE",
    "usr/share/doc/beanbao/palmino-harness-NOTICE",
    "usr/share/doc/beanbao/palmino-harness-UPSTREAM.md",
}
ICON_SIZES = {
    "BeanBaoIcon29.png": 29,
    "BeanBaoIcon29@2x.png": 58,
    "BeanBaoIcon29@3x.png": 87,
    "BeanBaoIcon60.png": 60,
    "BeanBaoIcon60@2x.png": 120,
    "BeanBaoIcon60@3x.png": 180,
}
APP_BASE = "Applications/BeanBao.app/"
APP_FILES = {APP_BASE + name for name in ("BeanBao", "Info.plist", *ICON_SIZES)}


def fail(message: str) -> None:
    raise SystemExit(message)


def archive_members(package: Path, prefix: str) -> dict[str, tuple[tarfile.TarInfo, bytes]]:
    names = subprocess.check_output(["ar", "t", str(package)], text=True).splitlines()
    matches = [name for name in names if name.startswith(prefix + ".tar.")]
    if len(matches) != 1:
        fail(f"{package.name}: expected one {prefix} archive")
    name = matches[0]
    data = subprocess.check_output(["ar", "p", str(package), name])
    if name.endswith(".gz"):
        data = gzip.decompress(data)
    elif name.endswith(".lzma"):
        data = lzma.decompress(data)
    else:
        fail(f"{package.name}: unsupported {name}")
    result = {}
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive:
            path = member.name.removeprefix("./")
            if path in ("", ".") or member.isdir():
                continue
            if not member.isfile() or path.startswith("/") or ".." in Path(path).parts:
                fail(f"{package.name}: unsafe archive member {member.name}")
            if path in result:
                fail(f"{package.name}: duplicate archive member {path}")
            result[path] = (member, archive.extractfile(member).read())
    return result


def fields(data: bytes) -> dict[str, str]:
    result = {}
    for line in data.decode("utf-8").splitlines():
        if ": " in line:
            key, value = line.split(": ", 1)
            result[key] = value
    return result


def audit_package(package: Path, source_control: Path, expected_name: str,
                  expected_files: set[str] | None) -> tuple[dict[str, str], dict]:
    control = archive_members(package, "control")
    if set(control) != {"control"}:
        fail(f"{package.name}: unexpected maintainer script or control file")
    packaged = fields(control["control"][1])
    source = fields(source_control.read_bytes())
    for key in ("Package", "Version", "Depends"):
        if packaged.get(key) != source.get(key):
            fail(f"{package.name}: {key} differs from source control")
    if packaged.get("Package") != expected_name or packaged.get("Architecture") != "iphoneos-arm64e":
        fail(f"{package.name}: wrong package identity or architecture")
    files = archive_members(package, "data")
    if expected_files is not None and set(files) != expected_files:
        fail(f"{package.name}: unexpected files {sorted(set(files) ^ expected_files)}")
    for path, (member, _) in files.items():
        if member.mode & 0o6000:
            fail(f"{package.name}: setuid or setgid file {path}")
    return packaged, files


def minimum_dependency(metadata: dict[str, str], name: str) -> tuple[int, ...]:
    match = re.fullmatch(rf"{re.escape(name)} \(>= (\d+(?:\.\d+)*)\)", metadata.get("Depends", ""))
    if not match:
        fail(f"{metadata.get('Package')}: unexpected dependency")
    return tuple(map(int, match.group(1).split(".")))


def version(metadata: dict[str, str]) -> tuple[int, ...]:
    value = metadata.get("Version", "")
    if not re.fullmatch(r"\d+(?:\.\d+)*", value):
        fail(f"{metadata.get('Package')}: invalid version")
    return tuple(map(int, value.split(".")))


def check_icon(name: str, data: bytes, expected: int) -> None:
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        fail(f"{name}: invalid PNG")
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) != (expected, expected):
        fail(f"{name}: expected {expected}x{expected}, got {width}x{height}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bridge", type=Path)
    parser.add_argument("agent", type=Path)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    bridge, _ = audit_package(args.bridge, ROOT / "bridge/control", "dev.beanbao.bridge", None)
    agent, agent_files = audit_package(args.agent, ROOT / "agent-native/control",
                                       "dev.beanbao.agent", AGENT_FILES)
    app, app_files = audit_package(args.app, ROOT / "app/control",
                                   "dev.beanbao.app", APP_FILES)
    for path in ("usr/bin/beanbaod", "usr/bin/beanbaoagentctl"):
        if not agent_files[path][0].mode & 0o111:
            fail(f"{path}: Agent executable bit is missing")
    if not app_files[APP_BASE + "BeanBao"][0].mode & 0o111:
        fail("BeanBao app executable bit is missing")
    if agent.get("Depends") != f"dev.beanbao.bridge (>= {bridge['Version']})":
        fail("Agent does not require this Bridge version")
    if version(agent) < minimum_dependency(app, "dev.beanbao.agent"):
        fail("App requires a newer Agent than this bundle provides")
    launch = plistlib.loads(agent_files["Library/LaunchDaemons/dev.beanbao.agent.plist"][1])
    if launch.get("Label") != "dev.beanbao.agent" or launch.get("UserName") != "mobile" or \
            launch.get("GroupName") != "mobile" or launch.get("RunAtLoad") is not True or \
            launch.get("KeepAlive") is not True or \
            launch.get("ProgramArguments") != ["/usr/bin/beanbaod", "--serve"]:
        fail("Agent launch daemon has unexpected execution settings")
    info = plistlib.loads(app_files[APP_BASE + "Info.plist"][1])
    if info.get("CFBundleIdentifier") != "dev.beanbao.app" or \
            info.get("CFBundleExecutable") != "BeanBao" or \
            info.get("CFBundleShortVersionString") != app["Version"] or \
            info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconFiles") != \
            ["BeanBaoIcon29", "BeanBaoIcon60"]:
        fail("App Info.plist does not match its package or icon files")
    for name, size in ICON_SIZES.items():
        check_icon(name, app_files[APP_BASE + name][1], size)
    print("PASS: Agent/App file manifests, dependency chain, mobile service, icon assets, and no maintainer scripts")


if __name__ == "__main__":
    main()

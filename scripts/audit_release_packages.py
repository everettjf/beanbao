#!/usr/bin/env python3
"""Verify the four RootHide packages form the intended BeanBao release."""

import argparse
import gzip
import io
import lzma
import plistlib
import re
import struct
import subprocess
import tarfile
import tempfile
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
BROWSER_BASE = "Applications/BeanBaoDelivery.app/"
BROWSER_FILES = {BROWSER_BASE + name for name in ("BeanBaoDelivery", "Info.plist", *ICON_SIZES)}
MACHO_FILES = {
    "Library/MobileSubstrate/DynamicLibraries/BeanBaoBridge.dylib": 6,
    "usr/bin/beanbaoctl": 2,
    "usr/bin/beanbaod": 2,
    "usr/bin/beanbaoagentctl": 2,
    APP_BASE + "BeanBao": 2,
    BROWSER_BASE + "BeanBaoDelivery": 2,
}


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
    dependencies = [item.strip() for item in metadata.get("Depends", "").split(",")]
    matches = [re.fullmatch(rf"{re.escape(name)} \(>= (\d+(?:\.\d+)*)\)", item)
               for item in dependencies]
    match = next((item for item in matches if item), None)
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


def check_macho(name: str, data: bytes, expected_type: int) -> None:
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        fail(f"{name}: expected a 64-bit little-endian Mach-O file")
    cpu, subtype, file_type, commands, command_bytes, _, _ = struct.unpack_from("<7I", data, 4)
    if cpu != 0x0100000C or subtype & 0x00FFFFFF != 2 or file_type != expected_type:
        fail(f"{name}: wrong Mach-O architecture or file type")
    command_end = 32 + command_bytes
    if commands == 0 or commands > 256 or command_end > len(data):
        fail(f"{name}: invalid Mach-O load commands")
    offset = 32
    signature = False
    for _ in range(commands):
        if offset + 8 > command_end:
            fail(f"{name}: truncated Mach-O load command")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > command_end:
            fail(f"{name}: invalid Mach-O load command size")
        if command == 0x1D:
            if size < 16 or signature:
                fail(f"{name}: invalid code signature command")
            signature_offset, signature_size = struct.unpack_from("<II", data, offset + 8)
            if signature_size < 12 or signature_offset < command_end or \
                    signature_offset + signature_size > len(data):
                fail(f"{name}: invalid embedded code signature range")
            magic, blob_size = struct.unpack_from(">II", data, signature_offset)
            if magic != 0xFADE0CC0 or blob_size < 12 or blob_size > signature_size:
                fail(f"{name}: invalid embedded code signature structure")
            signature = True
        offset += size
    if offset != command_end or not signature:
        fail(f"{name}: missing or malformed code signature load command")


def check_agent_binary_version(binary: bytes, expected: str) -> None:
    if expected.encode("ascii") + b"\x00" not in binary:
        fail("Agent binary was not compiled with the packaged version")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bridge", type=Path)
    parser.add_argument("agent", type=Path)
    parser.add_argument("app", type=Path)
    parser.add_argument("browser", type=Path)
    args = parser.parse_args()
    bridge, bridge_files = audit_package(args.bridge, ROOT / "bridge/control", "dev.beanbao.bridge", None)
    agent, agent_files = audit_package(args.agent, ROOT / "agent-native/control",
                                       "dev.beanbao.agent", AGENT_FILES)
    app, app_files = audit_package(args.app, ROOT / "app/control",
                                   "dev.beanbao.app", APP_FILES)
    browser, browser_files = audit_package(args.browser, ROOT / "delivery-browser/control",
        "dev.beanbao.deliverybrowser", BROWSER_FILES)
    if browser.get("Name") != "BeanBao Helper":
        fail("Browser package must use the BeanBao Helper display name")
    for path in ("usr/bin/beanbaod", "usr/bin/beanbaoagentctl"):
        if not agent_files[path][0].mode & 0o111:
            fail(f"{path}: Agent executable bit is missing")
    if not app_files[APP_BASE + "BeanBao"][0].mode & 0o111:
        fail("BeanBao app executable bit is missing")
    if not browser_files[BROWSER_BASE + "BeanBaoDelivery"][0].mode & 0o111:
        fail("Delivery browser executable bit is missing")
    binaries = {**bridge_files, **agent_files, **app_files, **browser_files}
    for path, file_type in MACHO_FILES.items():
        if path not in binaries:
            fail(f"Missing Mach-O file {path}")
        check_macho(path, binaries[path][1], file_type)
    check_agent_binary_version(agent_files["usr/bin/beanbaod"][1], agent["Version"])
    if agent.get("Depends") != f"dev.beanbao.bridge (>= {bridge['Version']})":
        fail("Agent does not require this Bridge version")
    if version(agent) < minimum_dependency(app, "dev.beanbao.agent"):
        fail("App requires a newer Agent than this bundle provides")
    if version(agent) < minimum_dependency(browser, "dev.beanbao.agent") or \
            version(browser) < minimum_dependency(app, "dev.beanbao.deliverybrowser"):
        fail("Delivery browser dependencies do not match this bundle")
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
        check_icon(name, browser_files[BROWSER_BASE + name][1], size)
    if app_files[APP_BASE + "BeanBaoIcon60@3x.png"][1] == \
            browser_files[BROWSER_BASE + "BeanBaoIcon60@3x.png"][1]:
        fail("BeanBao and BeanBao Helper must have distinct Home Screen icons")
    browser_info = plistlib.loads(browser_files[BROWSER_BASE + "Info.plist"][1])
    if browser_info.get("CFBundleIdentifier") != "dev.beanbao.deliverybrowser" or \
            browser_info.get("CFBundleExecutable") != "BeanBaoDelivery" or \
            browser_info.get("CFBundleDisplayName") != "BeanBao Helper" or \
            browser_info.get("CFBundleShortVersionString") != browser["Version"] or \
            browser_info.get("CFBundleURLTypes", [{}])[0].get("CFBundleURLSchemes") != ["beanbaodelivery"]:
        fail("Delivery browser identity or URL scheme is invalid")
    with tempfile.TemporaryDirectory() as directory:
        executable = Path(directory) / "BeanBaoDelivery"
        executable.write_bytes(browser_files[BROWSER_BASE + "BeanBaoDelivery"][1])
        entitlements = subprocess.run(["ldid", "-e", str(executable)], capture_output=True, check=True).stdout
        signed = plistlib.loads(entitlements)
        if signed != {"application-identifier": "dev.beanbao.deliverybrowser"}:
            fail("Delivery browser has unexpected signing privileges")
    print("PASS: four release packages, dependencies, service, sandboxed browser, icons, Mach-O/signatures, and no maintainer scripts")


if __name__ == "__main__":
    main()

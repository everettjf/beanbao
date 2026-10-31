#!/usr/bin/env python3
"""Collect the audited RootHide packages into an offline transfer archive."""

import argparse
import gzip
import hashlib
import io
import os
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
COMPONENTS = (
    ("bridge", "dev.beanbao.bridge"),
    ("agent-native", "dev.beanbao.agent"),
    ("app", "dev.beanbao.app"),
)


def source_version(component: str) -> str:
    for line in (ROOT / component / "control").read_text().splitlines():
        if line.startswith("Version: "):
            return line.removeprefix("Version: ").strip()
    raise SystemExit(f"{component}: missing Version in control")


def package_paths() -> tuple[list[Path], list[str]]:
    versions = [source_version(component) for component, _ in COMPONENTS]
    packages = [ROOT / component / "packages" / f"{name}_{version}_iphoneos-arm64e.deb"
                for (component, name), version in zip(COMPONENTS, versions)]
    missing = [str(package) for package in packages if not package.is_file()]
    if missing:
        raise SystemExit("Missing built package(s): " + ", ".join(missing))
    return packages, versions


def audit(packages: list[Path]) -> None:
    subprocess.run([sys.executable, str(ROOT / "scripts/audit_bridge_package.py"),
                    str(packages[0])], check=True)
    subprocess.run([sys.executable, str(ROOT / "scripts/audit_release_packages.py"),
                    *(str(package) for package in packages)], check=True)


def install_notes(packages: list[Path], versions: list[str]) -> bytes:
    names = [package.name for package in packages]
    return (f"# BeanBao RootHide 候选包\n\n"
            f"Bridge {versions[0]} / Agent {versions[1]} / App {versions[2]}。"
            "此候选组合尚未在目标 iPhone 完成真机验收；仅适用于已具备兼容 Relaxin / RootHide 环境的设备。\n\n"
            "先在电脑上运行 `shasum -a 256 -c SHA256SUMS` 核对三个包。"
            "取得设备 root shell 后按顺序安装：\n\n"
            "```sh\n"
            + "\n".join(f"dpkg -i {name}" for name in names)
            + "\ndpkg-query -W dev.beanbao.bridge dev.beanbao.agent dev.beanbao.app\n```\n\n"
            "首次安装或更新 Bridge 后，重新加载 SpringBoard 才能启用注入。"
            "确认 Agent 已由 launchd 以 mobile 身份运行，再解锁打开 BeanBao，"
            "选择“模拟模型”测试“打开地图”。步骤和限制见仓库 docs/install-and-configure.md。"
            "此归档不含模型 Key、SSH 凭据或设备数据。\n").encode("utf-8")


def add_bytes(archive: tarfile.TarFile, name: str, data: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o644
    info.mtime = 0
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    archive.addfile(info, io.BytesIO(data))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    packages, versions = package_paths()
    audit(packages)
    name = f"BeanBao-RootHide-b{versions[0]}-a{versions[1]}-app{versions[2]}.tar.gz"
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / name
    checksums = "".join(f"{hashlib.sha256(package.read_bytes()).hexdigest()}  {package.name}\n"
                        for package in packages).encode("ascii")
    fd, temporary = tempfile.mkstemp(prefix=f".{name}.", dir=output_dir)
    try:
        with os.fdopen(fd, "wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as archive:
                    for package in packages:
                        add_bytes(archive, package.name, package.read_bytes())
                    add_bytes(archive, "SHA256SUMS", checksums)
                    add_bytes(archive, "INSTALL.md", install_notes(packages, versions))
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Ready: {output}")
    print(f"SHA-256: {hashlib.sha256(output.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()

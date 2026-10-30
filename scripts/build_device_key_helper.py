#!/usr/bin/env python3
"""Build a reversible, device-specific root SSH key provisioning package.

Fila installs this package as root. It adds the public half of an existing
mobile SSH key to root's authorized_keys. Purging the package removes only
that exact key. No private key is copied into the package.
"""
import argparse
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile


def tar_bytes(files: dict[str, tuple[bytes, int]]) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        for name, (data, mode) in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = mode
            info.uid = 0
            info.gid = 0
            archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output = args.output.resolve()
    key = subprocess.check_output(["ssh-keygen", "-y", "-f", str(args.identity)], text=True).strip()
    if not key.startswith("ssh-ed25519 ") or "\n" in key or "'" in key:
        raise SystemExit("Expected a single Ed25519 public key")
    control = b"Package: dev.beanbao.device-key\nName: BeanBao Device SSH Key\nVersion: 0.1.1\nArchitecture: iphoneos-arm64e\nDescription: Authorize the existing paired Mac key for root SSH.\nMaintainer: BeanBao contributors\nSection: Administration\n"
    postinst = f"""#!/bin/sh
set -eu
key='{key}'
directory=/var/root/.ssh
file="$directory/authorized_keys"
umask 077
mkdir -p "$directory"
chown root:wheel "$directory"
chmod 700 "$directory"
touch "$file"
if ! grep -Fqx "$key" "$file"; then
    printf '%s\\n' "$key" >> "$file"
fi
chown root:wheel "$file"
chmod 600 "$file"
""".encode()
    postrm = f"""#!/bin/sh
set -eu
if [ "${{1:-}}" = purge ]; then
    file=/var/root/.ssh/authorized_keys
    key='{key}'
    if [ -f "$file" ]; then
        grep -Fvx "$key" "$file" > "$file.beanbao.tmp" || true
        cat "$file.beanbao.tmp" > "$file"
        rm -f "$file.beanbao.tmp"
        chmod 600 "$file"
    fi
fi
""".encode()
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        (base / "debian-binary").write_bytes(b"2.0\n")
        (base / "control.tar.gz").write_bytes(tar_bytes({"./control": (control, 0o644), "./postinst": (postinst, 0o755), "./postrm": (postrm, 0o755)}))
        (base / "data.tar.gz").write_bytes(tar_bytes({}))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.unlink(missing_ok=True)
        with args.output.open("wb") as package:
            package.write(b"!<arch>\n")
            for name in ("debian-binary", "control.tar.gz", "data.tar.gz"):
                data = (base / name).read_bytes()
                header = f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n".encode()
                if len(header) != 60:
                    raise AssertionError("Invalid ar header")
                package.write(header)
                package.write(data)
                if len(data) % 2:
                    package.write(b"\n")
    os.chmod(args.output, 0o600)
    print(args.output)


if __name__ == "__main__":
    main()

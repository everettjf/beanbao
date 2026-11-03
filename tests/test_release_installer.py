"""Check the offline installer's ordering and preflight without changing a phone."""

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PACKAGES = (
    "dev.beanbao.bridge",
    "dev.beanbao.agent",
    "dev.beanbao.deliverybrowser",
    "dev.beanbao.app",
)
VERSION = "1.0"
FAKE_TOOL = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
state_path = pathlib.Path(os.environ["FAKE_DPKG_STATE"])
log_path = pathlib.Path(os.environ["FAKE_DPKG_LOG"])
state = json.loads(state_path.read_text())
def package(path):
    stem = pathlib.Path(path).name
    name, rest = stem.split("_", 1)
    return name, rest.rsplit("_", 1)[0]
if tool == "sha256sum":
    if args != ["-c", "SHA256SUMS"]: sys.exit(2)
    good = True
    for line in pathlib.Path("SHA256SUMS").read_text().splitlines():
        digest, name = line.split("  ", 1)
        match = pathlib.Path(name).is_file() and hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() == digest
        print(name + (": OK" if match else ": FAILED"))
        good &= match
    sys.exit(0 if good else 1)
if tool == "id":
    if args == ["-u"]: print("0"); sys.exit(0)
if tool == "dpkg-deb":
    if len(args) == 3 and args[0] == "-f":
        name, version = package(args[1])
        print({"Package": name, "Version": version, "Architecture": "iphoneos-arm64e"}[args[2]])
        sys.exit(0)
if tool == "dpkg-query":
    if len(args) == 3 and args[:2] == ["-W", "-f=${Version}"]:
        if args[2] in state: print(state[args[2]], end=""); sys.exit(0)
        sys.exit(1)
if tool == "dpkg":
    if args == ["--print-architecture"]: print("iphoneos-arm64e"); sys.exit(0)
    if len(args) == 4 and args[0] == "--compare-versions" and args[2] == "gt":
        def parts(v): return tuple(int(p) for p in v.split("."))
        sys.exit(0 if parts(args[1]) > parts(args[3]) else 1)
    if len(args) == 2 and args[0] == "-i":
        name, version = package(args[1])
        state[name] = version
        state_path.write_text(json.dumps(state))
        with log_path.open("a") as log: log.write("install " + name + "\n")
        sys.exit(0)
if tool == "launchctl" and args == ["kickstart", "-k", "user/501/dev.beanbao.agent"]:
    marker = pathlib.Path(os.environ["FAKE_DPKG_STATE"] + ".kickstart_failed")
    if os.environ.get("FAKE_KICKSTART_FAIL_ONCE") and not marker.exists():
        marker.write_text("")
        sys.exit(1)
    with log_path.open("a") as log: log.write("restart agent\n")
    sys.exit(0)
if tool == "launchctl" and args == ["bootstrap", "user/501", "/Library/LaunchDaemons/dev.beanbao.agent.plist"]:
    with log_path.open("a") as log: log.write("bootstrap agent\n")
    sys.exit(0)
if tool == "uicache" and args == ["-a"]:
    with log_path.open("a") as log: log.write("refresh icons\n")
    sys.exit(0)
sys.exit(2)
'''


class ReleaseInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        fake = self.bin / "fake-tool"
        fake.write_text(FAKE_TOOL)
        fake.chmod(0o755)
        for name in ("sha256sum", "id", "dpkg", "dpkg-deb", "dpkg-query", "launchctl", "uicache"):
            (self.bin / name).symlink_to(fake)
        shutil.copy(ROOT / "scripts/install_release.sh", self.base / "install.sh")
        self.files = []
        for name in PACKAGES:
            path = self.base / f"{name}_{VERSION}_iphoneos-arm64e.deb"
            path.write_bytes(name.encode())
            self.files.append(path)
        (self.base / "SHA256SUMS").write_text("".join(
            f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
            for path in self.files))
        self.state = self.base / "state.json"
        self.log = self.base / "actions.log"
        self.log.write_text("")

    def run_installer(self, *args, extra_env=None):
        return subprocess.run(["sh", "install.sh", *args], cwd=self.base, text=True,
                              capture_output=True, env={**os.environ,
                                  "PATH": f"{self.bin}:/usr/bin:/bin",
                                  "FAKE_DPKG_STATE": str(self.state),
                                  "FAKE_DPKG_LOG": str(self.log), **(extra_env or {})})

    def test_dry_run_and_matching_versions_do_not_install_or_restart(self):
        self.state.write_text(json.dumps(dict.fromkeys(PACKAGES, VERSION)))
        self.assertEqual(self.run_installer("--dry-run").returncode, 0)
        self.assertEqual(self.run_installer().returncode, 0)
        self.assertEqual(self.log.read_text(), "")

    def test_changed_packages_install_in_dependency_order(self):
        self.state.write_text(json.dumps(dict.fromkeys(PACKAGES, "0.9")))
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(),
                         [*("install " + name for name in PACKAGES), "restart agent", "refresh icons"])
        self.assertEqual(json.loads(self.state.read_text()), dict.fromkeys(PACKAGES, VERSION))
        self.assertIn("Reload SpringBoard when convenient", result.stdout)

    def test_newer_installed_package_rejects_before_any_install(self):
        self.state.write_text(json.dumps({PACKAGES[0]: "0.9", PACKAGES[-1]: "1.1"}))
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("newer than release", result.stderr)
        self.assertEqual(self.log.read_text(), "")

    def test_first_install_bootstraps_agent_if_not_loaded(self):
        self.state.write_text("{}")
        result = self.run_installer(extra_env={"FAKE_KICKSTART_FAIL_ONCE": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(),
                         [*("install " + name for name in PACKAGES),
                          "bootstrap agent", "restart agent", "refresh icons"])

    def test_bad_digest_rejects_before_any_install(self):
        self.state.write_text("{}")
        self.files[-1].write_bytes(b"changed")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum verification failed", result.stderr)
        self.assertEqual(self.log.read_text(), "")

    def test_missing_checksum_rejects_before_any_install(self):
        self.state.write_text("{}")
        manifest = self.base / "SHA256SUMS"
        manifest.write_text("\n".join(manifest.read_text().splitlines()[:-1]) + "\n")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected four package checksums", result.stderr)
        self.assertEqual(self.log.read_text(), "")


if __name__ == "__main__":
    unittest.main()

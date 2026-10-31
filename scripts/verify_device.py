#!/usr/bin/env python3
"""Read-only G1 smoke check after the user installs the BeanBao deb."""
import argparse
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
COMPONENTS = (
    ("bridge", "dev.beanbao.bridge"),
    ("agent-native", "dev.beanbao.agent"),
    ("app", "dev.beanbao.app"),
)


def expected_version(component: str) -> str:
    for line in (ROOT / component / "control").read_text().splitlines():
        if line.startswith("Version: "):
            return line.removeprefix("Version: ").strip()
    raise SystemExit(f"{component}: no version in control file")


def verify_bundle(remote) -> None:
    for component, name in COMPONENTS:
        expected = expected_version(component)
        reported = remote(f"dpkg-query -W -f='${{Status}} ${{Version}}' {name}").strip()
        print(f"{name}: {reported}")
        if reported != f"install ok installed {expected}":
            raise SystemExit(f"{name}: installed version does not match local candidate {expected}")
    status = json.loads(remote("beanbaoagentctl status"))
    if status.get("ok") is not True or not isinstance(status.get("service_id"), str) or \
            not status["service_id"] or not isinstance(status.get("task_id"), str) or \
            status.get("phase") not in {"idle", "running", "stopping", "stopped", "done", "error"} or \
            not isinstance(status.get("running"), bool):
        raise SystemExit("Agent status protocol is unavailable or incompatible")
    print("agent:", json.dumps({"phase": status["phase"], "running": status["running"],
                                "service_id_present": True, "task_id_present": bool(status["task_id"])},
                               ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True, help="paired device SSH host or USB-forwarded localhost")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--identity", required=True, help="private key path; never stored in this repo")
    parser.add_argument("--known-hosts", help="paired device known_hosts file")
    parser.add_argument("--expect-bundle", action="store_true",
                        help="require installed Bridge/Agent/App versions and Agent protocol to match this checkout")
    args = parser.parse_args()
    ssh = ["ssh", "-i", args.identity, "-p", str(args.port), "-o", "IdentitiesOnly=yes",
           "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=yes",
           f"mobile@{args.host}"]
    if args.known_hosts:
        ssh[1:1] = ["-o", f"UserKnownHostsFile={args.known_hosts}"]

    def remote(command: str) -> str:
        return subprocess.check_output([*ssh, command], text=True, timeout=20)

    package = remote("dpkg-query -W -f='${Status} ${Version}' dev.beanbao.bridge")
    print("package:", package.strip())
    if not package.startswith("install ok installed"):
        raise SystemExit("bridge package is not installed")
    if args.expect_bundle:
        verify_bundle(remote)
    base = "/rootfs/private/var/mobile/Library/Caches/BeanBao"
    permissions = remote(f"stat -c '%U %a %n' {base} {base}/bridge.sock {base}/bridge.token")
    print("local files:\n" + permissions.strip())
    report = json.loads(remote("beanbaoctl '{\"op\":\"observe\"}'"))
    if not report.get("ok"):
        raise SystemExit("bridge observation failed: " + str(report.get("error")))
    state = report.get("device_state", {})
    app = report.get("frontmost_app", {})
    screen = report.get("screen", {})
    print("bridge observation:", json.dumps({
        "locked_known": state.get("locked_known"),
        "locked": state.get("locked"),
        "screen_on_known": state.get("screen_on_known"),
        "screen_on": state.get("screen_on"),
        "frontmost_bundle_id": app.get("bundleId"),
        "screen_points": [screen.get("width"), screen.get("height")],
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()

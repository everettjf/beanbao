#!/usr/bin/env python3
"""Read-only G1 smoke check after the user installs the BeanBao deb."""
import argparse
import json
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True, help="paired device SSH host or USB-forwarded localhost")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--identity", required=True, help="private key path; never stored in this repo")
    parser.add_argument("--known-hosts", help="paired device known_hosts file")
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
